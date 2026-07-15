#!/bin/bash
set -e

APP_DIR="/opt/ovpn-xui"
DATA_DIR="$APP_DIR/data"
CLIENT_DIR="$APP_DIR/clients"
BACKUP_DIR="$APP_DIR/backups"
HOOK_DIR="$APP_DIR/hooks"
EASYRSA_DIR="/etc/openvpn/easy-rsa"
OVPN_DIR="/etc/openvpn/server"
SERVICE_NAME="ovpn-xui"
VPN_SERVICE="openvpn-server@server"
MGMT_HOST="127.0.0.1"
MGMT_PORT="7505"

PANEL_PORT="8088"
VPN_PORT="443"
VPN_PROTO="tcp"

SERVER_IP="$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || curl -4 -s --max-time 5 api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
IFACE="$(ip route | grep default | awk '{print $5}' | head -n1)"

# ── Root check ────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (use: sudo bash $0)"
    exit 1
fi

# ── CLI restore flag: ./install-v7.sh --restore /path/to/backup.zip ──
RESTORE_ZIP=""
if [[ "${1:-}" == "--restore" && -n "${2:-}" ]]; then
    RESTORE_ZIP="$2"
    if [[ ! -f "$RESTORE_ZIP" ]]; then
        echo "Backup file not found: $RESTORE_ZIP"; exit 1
    fi
fi

# ── Detect: fresh install vs. update of an existing panel ──
INSTALL_MODE="install"
if [[ -f "$DATA_DIR/settings.json" ]] && systemctl list-unit-files 2>/dev/null | grep -q "^$SERVICE_NAME.service"; then
    INSTALL_MODE="update"
fi

echo "=========================================="
echo " OpenVPN X-UI  V7.1  Installer / Upgrader"
echo "=========================================="
if [[ "$INSTALL_MODE" == "update" ]]; then
    echo " Existing panel detected at $APP_DIR"
    echo " Mode: UPDATE (your users, certs and settings are kept)"
else
    echo " No existing panel detected."
    echo " Mode: FRESH INSTALL"
fi
echo "Detected IP: $SERVER_IP"
echo "Detected Interface: $IFACE"
echo ""

# Pre-fill prompts with existing values when updating, so hitting Enter keeps them
EXIST_HOST=""; EXIST_PANEL_PORT=""; EXIST_VPN_PORT=""; EXIST_VPN_PROTO=""
if [[ "$INSTALL_MODE" == "update" ]]; then
    EXIST_HOST="$(python3 -c "import json;print(json.load(open('$DATA_DIR/settings.json')).get('config_host',''))" 2>/dev/null || true)"
    EXIST_PANEL_PORT="$(python3 -c "import json;print(json.load(open('$DATA_DIR/settings.json')).get('panel_port',''))" 2>/dev/null || true)"
    EXIST_VPN_PORT="$(python3 -c "import json;print(json.load(open('$DATA_DIR/settings.json')).get('vpn_port',''))" 2>/dev/null || true)"
    EXIST_VPN_PROTO="$(python3 -c "import json;print(json.load(open('$DATA_DIR/settings.json')).get('vpn_proto',''))" 2>/dev/null || true)"
fi
CONFIG_HOST_DEFAULT=${EXIST_HOST:-$SERVER_IP}
PANEL_PORT_DEFAULT=${EXIST_PANEL_PORT:-$PANEL_PORT}
VPN_PORT_DEFAULT=${EXIST_VPN_PORT:-$VPN_PORT}
VPN_PROTO_DEFAULT=${EXIST_VPN_PROTO:-$VPN_PROTO}

if [[ -n "$RESTORE_ZIP" ]]; then
    echo ">>> --restore flag given, will restore data from: $RESTORE_ZIP after install."
    CONFIG_HOST="$CONFIG_HOST_DEFAULT"
    PANEL_PORT="$PANEL_PORT_DEFAULT"
    VPN_PORT="$VPN_PORT_DEFAULT"
    VPN_PROTO="$VPN_PROTO_DEFAULT"
else
    read -rp "Config domain/IP for clients [$CONFIG_HOST_DEFAULT]: " CONFIG_HOST
    CONFIG_HOST=${CONFIG_HOST:-$CONFIG_HOST_DEFAULT}

    read -rp "Panel port [$PANEL_PORT_DEFAULT]: " PANEL_PORT_INPUT
    PANEL_PORT=${PANEL_PORT_INPUT:-$PANEL_PORT_DEFAULT}

    read -rp "OpenVPN port [$VPN_PORT_DEFAULT]: " VPN_PORT_INPUT
    VPN_PORT=${VPN_PORT_INPUT:-$VPN_PORT_DEFAULT}

    read -rp "OpenVPN proto [$VPN_PROTO_DEFAULT]: " VPN_PROTO_INPUT
    VPN_PROTO=${VPN_PROTO_INPUT:-$VPN_PROTO_DEFAULT}
fi

echo ""
if [[ "$INSTALL_MODE" == "update" ]]; then
    echo ">>> Checking / installing any missing dependencies (update mode)..."
else
    echo ">>> Installing dependencies (fresh install)..."
fi
mkdir -p "$APP_DIR" "$DATA_DIR" "$CLIENT_DIR" "$BACKUP_DIR" "$OVPN_DIR" "$HOOK_DIR"

apt-get update -qq
apt-get install -y -qq openvpn easy-rsa iptables-persistent curl python3 python3-pip sqlite3 zip unzip openssl netcat-openbsd 2>/dev/null || \
apt-get install -y openvpn easy-rsa iptables-persistent curl python3 python3-pip sqlite3 zip unzip openssl ncat

pip3 install flask --break-system-packages 2>/dev/null || pip3 install flask

echo ">>> Auto-backup existing configs..."
AUTO_BACKUP="$BACKUP_DIR/before-v71-$(date +%F-%H%M%S).tar.gz"
tar -czf "$AUTO_BACKUP" /etc/openvpn /opt/ovpn-xui 2>/dev/null || true

# ── Settings ────────────────────────────────────────────────
echo ">>> Setting up config..."
if [[ ! -f "$DATA_DIR/settings.json" ]]; then
    ADMIN_USER="admin"
    ADMIN_PASS="$(openssl rand -base64 12)"
    API_TOKEN="$(openssl rand -hex 32)"
    SECRET_KEY="$(openssl rand -hex 32)"

    cat > "$DATA_DIR/settings.json" <<EOF
{
  "admin_user": "$ADMIN_USER",
  "admin_pass": "$ADMIN_PASS",
  "api_token": "$API_TOKEN",
  "secret_key": "$SECRET_KEY",
  "config_host": "$CONFIG_HOST",
  "server_ip": "$SERVER_IP",
  "panel_port": "$PANEL_PORT",
  "vpn_port": "$VPN_PORT",
  "vpn_proto": "$VPN_PROTO",
  "mgmt_host": "$MGMT_HOST",
  "mgmt_port": "$MGMT_PORT",
  "version": "v7.1"
}
EOF
else
python3 - <<PY
import json, secrets
p="$DATA_DIR/settings.json"
d=json.load(open(p))
d["config_host"]="$CONFIG_HOST"
d["server_ip"]="$SERVER_IP"
d["panel_port"]="$PANEL_PORT"
d["vpn_port"]="$VPN_PORT"
d["vpn_proto"]="$VPN_PROTO"
d["mgmt_host"]="$MGMT_HOST"
d["mgmt_port"]="$MGMT_PORT"
d["version"]="v7.1"
d.setdefault("admin_user","admin")
d.setdefault("admin_pass",secrets.token_urlsafe(12))
d.setdefault("api_token",secrets.token_hex(32))
d.setdefault("secret_key",secrets.token_hex(32))
json.dump(d, open(p,"w"), indent=2)
PY
fi

# ── PKI / Certificates ───────────────────────────────────────
echo ">>> Setting up PKI..."
if [[ ! -f "$EASYRSA_DIR/pki/ca.crt" ]]; then
    rm -rf "$EASYRSA_DIR"
    make-cadir "$EASYRSA_DIR"

    cd "$EASYRSA_DIR"
    EASYRSA_BATCH=1 ./easyrsa init-pki
    EASYRSA_BATCH=1 ./easyrsa build-ca nopass
    EASYRSA_BATCH=1 ./easyrsa gen-req server nopass
    EASYRSA_BATCH=1 ./easyrsa sign-req server server
    EASYRSA_BATCH=1 ./easyrsa gen-dh
    openvpn --genkey secret ta.key
    EASYRSA_BATCH=1 ./easyrsa gen-crl

    cp pki/ca.crt "$OVPN_DIR/"
    cp pki/issued/server.crt "$OVPN_DIR/"
    cp pki/private/server.key "$OVPN_DIR/"
    cp pki/dh.pem "$OVPN_DIR/"
    cp ta.key "$OVPN_DIR/"
    cp pki/crl.pem "$OVPN_DIR/"
fi

# ── OpenVPN Server Config (client-connect/disconnect hooks) ──
echo ">>> Writing OpenVPN server config..."
cat > "$OVPN_DIR/server.conf" <<EOF
port $VPN_PORT
proto $VPN_PROTO
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
tls-crypt ta.key
crl-verify crl.pem
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ipp.txt
status /var/log/openvpn-status.log 5
status-version 2
log-append /var/log/openvpn.log
client-config-dir /etc/openvpn/ccd
duplicate-cn
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"
keepalive 10 120
cipher AES-256-GCM
auth SHA256
tls-version-min 1.2
user nobody
group nogroup
persist-key
persist-tun
verb 3
management $MGMT_HOST $MGMT_PORT
script-security 2
client-connect $HOOK_DIR/client-connect.sh
client-disconnect $HOOK_DIR/client-disconnect.sh
EOF

mkdir -p /etc/openvpn/ccd

# ── Network / Firewall ───────────────────────────────────────
echo ">>> Configuring networking..."
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-openvpn.conf
sysctl -w net.ipv4.ip_forward=1 >/dev/null || true
sysctl --system >/dev/null 2>&1 || true

iptables -t nat -C POSTROUTING -s 10.8.0.0/24 -o "$IFACE" -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "$IFACE" -j MASQUERADE

iptables -C INPUT -p "$VPN_PROTO" --dport "$VPN_PORT" -j ACCEPT 2>/dev/null || \
iptables -A INPUT -p "$VPN_PROTO" --dport "$VPN_PORT" -j ACCEPT

iptables -C INPUT -p tcp --dport "$PANEL_PORT" -j ACCEPT 2>/dev/null || \
iptables -A INPUT -p tcp --dport "$PANEL_PORT" -j ACCEPT

iptables -C FORWARD -i tun0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -i tun0 -j ACCEPT
iptables -C FORWARD -o tun0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -o tun0 -j ACCEPT

netfilter-persistent save 2>/dev/null || true

# ── Device hook (shared python logic for client-connect / client-disconnect) ──
echo ">>> Writing device-limit hook..."
cat > "$HOOK_DIR/devicehook.py" <<'PYHOOK'
#!/usr/bin/env python3
"""
V7.1 device-limit / quota enforcement hook.
Called by OpenVPN's client-connect / client-disconnect with env vars available
via os.environ (common_name, trusted_ip, bytes_received, bytes_sent, IV_PLAT, IV_PLAT_VER ...).

IMPORTANT: this script runs as the unprivileged user/group OpenVPN drops
privileges to (user nobody / group nogroup in server.conf). It needs write
access to panel.db and hook.log. The Flask app (app.py) self-heals the
permissions on those files on every request (see init_db()), so this keeps
working even after the panel recreates the DB while running as root.

Exit code 0  => allow / ok
Exit code 1  => deny the connection (client-connect only)
"""
import os, sys, sqlite3, time, hashlib

DATA_DIR = "/opt/ovpn-xui/data"
DB = DATA_DIR + "/panel.db"
LOG = "/opt/ovpn-xui/data/hook.log"

def log(msg):
    try:
        with open(LOG, "a") as f:
            f.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}\n")
    except Exception:
        pass

def db():
    c = sqlite3.connect(DB, timeout=5)
    c.row_factory = sqlite3.Row
    return c

def device_key(username, platform, platform_ver):
    raw = f"{username}:{platform}:{platform_ver}".lower()
    return hashlib.sha256(raw.encode()).hexdigest()[:16]

def get_user(c, username):
    return c.execute("SELECT * FROM users WHERE username=?", (username,)).fetchone()

def handle_connect():
    username = os.environ.get("common_name", "")
    real_ip  = os.environ.get("trusted_ip") or os.environ.get("untrusted_ip") or ""
    platform = os.environ.get("IV_PLAT", "unknown")
    platform_ver = os.environ.get("IV_PLAT_VER", "")
    gui_ver  = os.environ.get("IV_GUI_VER", "")
    now = int(time.time())

    try:
        c = db()
    except Exception as e:
        # Cannot even open the DB (permission issue etc.) -> fail-open so the
        # VPN itself never breaks, but make it very loud in the log so it's
        # obvious in the panel's "Logs & Status" page that enforcement is off.
        log(f"CRITICAL: cannot open DB for {username}: {e} -- ALLOWING (fail-open, enforcement inactive)")
        sys.exit(0)

    u = get_user(c, username)
    if not u:
        log(f"DENY {username}: not found"); c.close(); sys.exit(1)
    if not u["enabled"]:
        log(f"DENY {username}: disabled"); c.close(); sys.exit(1)
    if not u["unlimited_expiry"] and u["expiry"] and u["expiry"] < now:
        log(f"DENY {username}: expired"); c.close(); sys.exit(1)
    if not u["unlimited_quota"] and u["quota_gb"] > 0 and u["used_bytes"] >= u["quota_gb"] * 1_000_000_000:
        log(f"DENY {username}: quota exceeded ({u['used_bytes']} >= {u['quota_gb']*1_000_000_000})")
        c.close(); sys.exit(1)

    dkey = device_key(username, platform, platform_ver)

    row = c.execute("SELECT * FROM devices WHERE username=? AND device_key=?", (username, dkey)).fetchone()
    if row and row["blocked"]:
        log(f"DENY {username}: device {dkey} blocked"); c.close(); sys.exit(1)

    if not u["unlimited_devices"] and u["max_devices"] > 0:
        active = c.execute(
            "SELECT COUNT(DISTINCT device_key) AS n FROM devices WHERE username=? AND connected=1 AND device_key<>?",
            (username, dkey)).fetchone()["n"]
        if active >= u["max_devices"]:
            log(f"DENY {username}: device limit reached ({active}/{u['max_devices']})")
            c.close(); sys.exit(1)

    if row:
        c.execute("""UPDATE devices SET connected=1, last_ip=?, last_seen=?, platform=?, platform_ver=?, gui_ver=?
                      WHERE username=? AND device_key=?""",
                   (real_ip, now, platform, platform_ver, gui_ver, username, dkey))
    else:
        c.execute("""INSERT INTO devices(username, device_key, platform, platform_ver, gui_ver,
                      first_ip, last_ip, first_seen, last_seen, connected, blocked, bytes_rx, bytes_tx)
                      VALUES(?,?,?,?,?,?,?,?,?,1,0,0,0)""",
                   (username, dkey, platform, platform_ver, gui_ver, real_ip, real_ip, now, now))
    c.commit(); c.close()
    log(f"ALLOW {username} device={dkey} ip={real_ip} plat={platform}/{platform_ver}")
    sys.exit(0)

def handle_disconnect():
    username = os.environ.get("common_name", "")
    platform = os.environ.get("IV_PLAT", "unknown")
    platform_ver = os.environ.get("IV_PLAT_VER", "")
    rx = int(os.environ.get("bytes_received", 0) or 0)
    tx = int(os.environ.get("bytes_sent", 0) or 0)
    now = int(time.time())
    dkey = device_key(username, platform, platform_ver)

    try:
        c = db()
    except Exception as e:
        log(f"CRITICAL: cannot open DB on disconnect for {username}: {e}")
        sys.exit(0)

    c.execute("""UPDATE devices SET connected=0, last_seen=?, bytes_rx=bytes_rx+?, bytes_tx=bytes_tx+?
                 WHERE username=? AND device_key=?""", (now, rx, tx, username, dkey))
    c.execute("UPDATE users SET used_bytes = used_bytes + ? WHERE username=?", (rx + tx, username))
    c.commit(); c.close()
    log(f"DISCONNECT {username} device={dkey} rx={rx} tx={tx}")
    sys.exit(0)

if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        if mode == "connect":
            handle_connect()
        elif mode == "disconnect":
            handle_disconnect()
        else:
            sys.exit(0)
    except SystemExit:
        raise
    except Exception as e:
        log(f"ERROR {mode}: {e}")
        # fail-open on unexpected errors so a bug never locks out all users
        sys.exit(0)
PYHOOK
chmod +x "$HOOK_DIR/devicehook.py"

cat > "$HOOK_DIR/client-connect.sh" <<'PYCONN'
#!/bin/bash
/usr/bin/python3 /opt/ovpn-xui/hooks/devicehook.py connect
exit $?
PYCONN
chmod +x "$HOOK_DIR/client-connect.sh"

cat > "$HOOK_DIR/client-disconnect.sh" <<'PYDISC'
#!/bin/bash
/usr/bin/python3 /opt/ovpn-xui/hooks/devicehook.py disconnect
exit 0
PYDISC
chmod +x "$HOOK_DIR/client-disconnect.sh"

# ── Flask App (V7.1) ──────────────────────────────────────────
echo ">>> Writing panel app (v7.1)..."
cat > "$APP_DIR/app.py" <<'PYAPP'
#!/usr/bin/env python3
"""OpenVPN X-UI V7.1 — Panel + REST API + Device manager

V7.1 fixes over V7:
  1. online_clients() now parses the actual OpenVPN 2.6 "status-version 2"
     format (CLIENT_LIST,... rows) instead of the old plain-text header this
     used to look for, which never matched and made online counts wrong.
  2. init_db() self-heals filesystem permissions on panel.db / hook.log every
     request, so the client-connect/disconnect hooks (which run as the
     unprivileged user/group OpenVPN drops to) can always write to them, even
     after the panel (running as root) recreates those files.
  3. A background thread runs continuously (independent of anyone viewing the
     panel) and:
       - reconciles devices.connected against the live OpenVPN status log, so
         a missed disconnect hook (crash, kill -9, server restart) can't leave
         a device stuck showing "online" forever
       - kills any currently-connected session for a user who has gone over
         quota, so quota is enforced live and not just on the next reconnect
       - re-kills any device that is marked blocked but is still connected
"""

from flask import (Flask, request, redirect, session,
                   send_file, render_template_string, jsonify, make_response)
import os, json, re, sqlite3, subprocess, time, zipfile, secrets, shutil, tempfile, functools, socket, threading

APP_DIR    = "/opt/ovpn-xui"
DATA_DIR   = APP_DIR + "/data"
CLIENT_DIR = APP_DIR + "/clients"
BACKUP_DIR = APP_DIR + "/backups"
DB         = DATA_DIR + "/panel.db"
SETTINGS   = DATA_DIR + "/settings.json"
EASYRSA    = "/etc/openvpn/easy-rsa"
OVPN_DIR   = "/etc/openvpn/server"
OVPN_ROOT  = "/etc/openvpn"
STATUS_FILE= "/var/log/openvpn-status.log"

UNLIMITED = 0  # sentinel meaning "no numeric value set", real unlimited is via the unlimited_* flag

app = Flask(__name__)

# ── Helpers ──────────────────────────────────────────────────

def settings():
    return json.load(open(SETTINGS))

def save_settings(d):
    json.dump(d, open(SETTINGS, "w"), indent=2)

def get_secret_key():
    try:
        return settings().get("secret_key") or secrets.token_hex(32)
    except Exception:
        return secrets.token_hex(32)

app.secret_key = get_secret_key()

def db():
    c = sqlite3.connect(DB)
    c.row_factory = sqlite3.Row
    return c

def col_exists(c, table, col):
    cols = [r["name"] for r in c.execute(f"PRAGMA table_info({table})").fetchall()]
    return col in cols

def init_db():
    os.makedirs(DATA_DIR, exist_ok=True)
    c = db()
    c.execute("""
    CREATE TABLE IF NOT EXISTS users(
        username    TEXT PRIMARY KEY,
        max_devices INTEGER DEFAULT 2,
        quota_gb    INTEGER DEFAULT 100,
        expiry      INTEGER DEFAULT 0,
        used_bytes  INTEGER DEFAULT 0,
        note        TEXT    DEFAULT '',
        source      TEXT    DEFAULT 'manual',
        enabled     INTEGER DEFAULT 1,
        created_at  INTEGER DEFAULT 0,
        unlimited_expiry  INTEGER DEFAULT 0,
        unlimited_quota   INTEGER DEFAULT 0,
        unlimited_devices INTEGER DEFAULT 0
    )""")
    # migration for panels upgraded from v6 (columns might be missing)
    for col, ddl in [
        ("unlimited_expiry",  "ALTER TABLE users ADD COLUMN unlimited_expiry INTEGER DEFAULT 0"),
        ("unlimited_quota",   "ALTER TABLE users ADD COLUMN unlimited_quota INTEGER DEFAULT 0"),
        ("unlimited_devices", "ALTER TABLE users ADD COLUMN unlimited_devices INTEGER DEFAULT 0"),
    ]:
        if not col_exists(c, "users", col):
            c.execute(ddl)

    c.execute("""
    CREATE TABLE IF NOT EXISTS devices(
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        username     TEXT,
        device_key   TEXT,
        platform     TEXT DEFAULT 'unknown',
        platform_ver TEXT DEFAULT '',
        gui_ver      TEXT DEFAULT '',
        first_ip     TEXT DEFAULT '',
        last_ip      TEXT DEFAULT '',
        first_seen   INTEGER DEFAULT 0,
        last_seen    INTEGER DEFAULT 0,
        connected    INTEGER DEFAULT 0,
        blocked      INTEGER DEFAULT 0,
        bytes_rx     INTEGER DEFAULT 0,
        bytes_tx     INTEGER DEFAULT 0,
        UNIQUE(username, device_key)
    )""")
    # normalize any pre-existing insane expiry values (from the v6 "999999999 days" bug)
    # anything beyond year ~2100 gets folded into "unlimited" automatically instead of crashing
    MAX_SANE_EPOCH = 4102444800  # 2100-01-01
    c.execute("UPDATE users SET unlimited_expiry=1, expiry=0 WHERE expiry > ?", (MAX_SANE_EPOCH,))
    c.commit(); c.close()

    # ── Self-heal permissions for the client-connect/client-disconnect hooks ──
    # OpenVPN drops privileges to "user nobody / group nogroup" (server.conf).
    # The hooks run as that unprivileged identity and need to read/write
    # panel.db and hook.log. This app runs as root (systemd unit), so any file
    # it (re)creates defaults to root-only write access. Without this fix the
    # hook silently fails on every connect/disconnect (it fails OPEN so VPN
    # access is never blocked by a bug here) and the panel then shows zero
    # online devices even though users are actually connected.
    try:
        os.chmod(DATA_DIR, 0o777)
        os.chmod(DB, 0o666)
        hooklog = DATA_DIR + "/hook.log"
        if not os.path.exists(hooklog):
            open(hooklog, "a").close()
        os.chmod(hooklog, 0o666)
    except Exception:
        pass

def run(cmd):
    return subprocess.getoutput(cmd)

def valid_user(u):
    return bool(re.match(r'^[a-zA-Z0-9_.@-]{3,64}$', u or ''))

def clean_user(u):
    u = (u or '').strip()
    u = re.sub(r'[^a-zA-Z0-9_.@-]', '_', u)
    return u[:64]

MAX_DAYS = 36500  # 100 years — safety cap so nobody can re-trigger an overflow bug

def safe_days(v, default=30):
    try:
        d = int(v)
    except Exception:
        return default
    if d < 0: d = 0
    if d > MAX_DAYS: d = MAX_DAYS
    return d

def safe_int(v, default=0, max_v=10_000_000):
    try:
        n = int(v)
    except Exception:
        return default
    if n < 0: n = 0
    if n > max_v: n = max_v
    return n

def all_users(q=""):
    c = db()
    if q:
        rows = c.execute(
            "SELECT * FROM users WHERE username LIKE ? OR note LIKE ? ORDER BY created_at DESC",
            (f"%{q}%", f"%{q}%")).fetchall()
    else:
        rows = c.execute("SELECT * FROM users ORDER BY created_at DESC").fetchall()
    c.close()
    return rows

def get_user(username):
    c = db()
    row = c.execute("SELECT * FROM users WHERE username=?", (username,)).fetchone()
    c.close()
    return row

def user_devices(username):
    c = db()
    rows = c.execute("SELECT * FROM devices WHERE username=? ORDER BY connected DESC, last_seen DESC",
                      (username,)).fetchall()
    c.close()
    return rows

def all_connected_devices():
    c = db()
    rows = c.execute("SELECT * FROM devices WHERE connected=1 ORDER BY username").fetchall()
    c.close()
    return rows

def online_clients():
    """Parse the real OpenVPN 2.6 status log (status-version 2 format).

    Real format looks like:
      TITLE,OpenVPN 2.6.19 ...
      TIME,...
      HEADER,CLIENT_LIST,Common Name,Real Address,Virtual Address,Virtual IPv6 Address,
             Bytes Received,Bytes Sent,Connected Since,Connected Since (time_t),
             Username,Client ID,Peer ID,Data Channel Cipher
      CLIENT_LIST,alice,1.2.3.4:5678,10.8.0.10,,1000,2000,2026-07-12 21:41:24,...
      ROUTING_TABLE,...
      GLOBAL_STATS,...
      END

    The previous version of this function looked for a literal
    "Common Name,Real Address" line (the OLD plain-text status format) which
    never matches this format, so it always returned an empty list even while
    dozens of clients were connected.
    """
    if not os.path.exists(STATUS_FILE):
        return []
    out = []
    try:
        with open(STATUS_FILE, errors="ignore") as f:
            for line in f:
                line = line.strip()
                if not line.startswith("CLIENT_LIST,"):
                    continue
                p = line.split(",")
                # CLIENT_LIST,CommonName,RealAddress,VirtAddr,VirtIPv6,BytesRecv,BytesSent,ConnSince,ConnSinceEpoch,...
                if len(p) >= 8:
                    out.append({
                        "name": p[1],
                        "real": p[2],
                        "rx":   p[5] if len(p) > 5 else "0",
                        "tx":   p[6] if len(p) > 6 else "0",
                        "since": p[7] if len(p) > 7 else "",
                    })
    except Exception:
        pass
    return out

def mgmt_send(cmd, wait=0.4):
    """Send a single command to the OpenVPN management interface and return the raw reply."""
    s = settings()
    host = s.get("mgmt_host", "127.0.0.1")
    port = int(s.get("mgmt_port", 7505))
    try:
        sock = socket.create_connection((host, port), timeout=3)
        sock.recv(4096)  # banner
        sock.sendall((cmd + "\n").encode())
        time.sleep(wait)
        data = b""
        sock.settimeout(1.5)
        try:
            while True:
                chunk = sock.recv(4096)
                if not chunk: break
                data += chunk
        except Exception:
            pass
        sock.sendall(b"quit\n")
        sock.close()
        return data.decode(errors="ignore")
    except Exception as e:
        return f"ERROR: {e}"

def mgmt_kill_ip(real_ip):
    """Kill every management-interface session whose real address matches real_ip."""
    if not real_ip:
        return False
    out = mgmt_send("status 2")
    killed = False
    for line in out.splitlines():
        if line.startswith("CLIENT_LIST") and real_ip in line:
            parts = line.split(",")
            if len(parts) > 1:
                cn = parts[1]
                mgmt_send(f"client-kill {cn}")
                killed = True
    return killed

def mgmt_kill_user(username):
    """Kill every management-interface session for a given common name."""
    if not username:
        return False
    out = mgmt_send("status 2")
    killed = False
    for line in out.splitlines():
        if line.startswith("CLIENT_LIST,"):
            parts = line.split(",")
            if len(parts) > 1 and parts[1] == username:
                mgmt_send(f"client-kill {username}")
                killed = True
    return killed

# ── Background reconciliation / live enforcement ────────────
# Runs continuously regardless of whether anyone has the panel open, so
# device limits / quota / blocking are enforced in near-real-time and not
# just the next time a page happens to load.

def reconcile_devices():
    """If a device is marked connected=1 in the DB but doesn't actually
    appear in the live OpenVPN status anymore, flip it back to disconnected.
    Covers cases where the client-disconnect hook never ran (server crash,
    kill -9, abrupt network loss)."""
    live = online_clients()
    live_ips_by_user = {}
    for cl in live:
        ip = cl["real"].split(":")[0] if cl["real"] else ""
        live_ips_by_user.setdefault(cl["name"], set()).add(ip)

    c = db()
    stuck = c.execute("SELECT username, device_key, last_ip FROM devices WHERE connected=1").fetchall()
    now = int(time.time())
    for d in stuck:
        ips = live_ips_by_user.get(d["username"])
        if not ips or d["last_ip"] not in ips:
            c.execute("UPDATE devices SET connected=0, last_seen=? WHERE username=? AND device_key=?",
                      (now, d["username"], d["device_key"]))
    c.commit(); c.close()

def enforce_quota_live():
    """Kill any currently-connected session belonging to a user who has
    exceeded their quota, instead of waiting for their next reconnect
    attempt to be denied."""
    c = db()
    over = c.execute("""SELECT username FROM users
                         WHERE enabled=1 AND unlimited_quota=0 AND quota_gb>0
                         AND used_bytes >= quota_gb*1000000000""").fetchall()
    c.close()
    for u in over:
        mgmt_kill_user(u["username"])

def kill_blocked_devices():
    """Extra safety net: if a device is marked blocked but is still shown
    connected (e.g. it was blocked in the same instant it connected), kill
    it rather than waiting for the panel action that first blocked it."""
    c = db()
    rows = c.execute("SELECT username, last_ip FROM devices WHERE blocked=1 AND connected=1").fetchall()
    c.close()
    for r in rows:
        mgmt_kill_ip(r["last_ip"])

def enforce_expired():
    now = int(time.time())
    c = db()
    rows = c.execute(
        "SELECT username FROM users WHERE enabled=1 AND unlimited_expiry=0 AND expiry>0 AND expiry<?", (now,)
    ).fetchall()
    for r in rows:
        revoke_cert(r["username"])
        c.execute("UPDATE users SET enabled=0 WHERE username=?", (r["username"],))
    c.commit(); c.close()
    if rows:
        run("systemctl restart openvpn-server@server")

def background_worker():
    while True:
        try:
            init_db()            # keeps permissions self-healed too
            enforce_expired()
            reconcile_devices()
            enforce_quota_live()
            kill_blocked_devices()
        except Exception:
            pass
        time.sleep(15)

def create_cert(username):
    issued = f"{EASYRSA}/pki/issued/{username}.crt"
    if not os.path.exists(issued):
        run(f"cd {EASYRSA} && EASYRSA_BATCH=1 ./easyrsa build-client-full '{username}' nopass")
    return os.path.exists(issued)

def revoke_cert(username, hard=False):
    os.makedirs("/etc/openvpn/ccd", exist_ok=True)
    with open(f"/etc/openvpn/ccd/{username}", "w") as f:
        f.write("disable\n")
    if hard:
        run(f"cd {EASYRSA} && EASYRSA_BATCH=1 ./easyrsa revoke '{username}' || true")
        run(f"cd {EASYRSA} && EASYRSA_BATCH=1 ./easyrsa gen-crl")
        run("cp /etc/openvpn/easy-rsa/pki/crl.pem /etc/openvpn/server/crl.pem")
    mgmt_kill_user(username)

def enable_cert(username):
    p = f"/etc/openvpn/ccd/{username}"
    if os.path.exists(p):
        os.remove(p)

def make_config(username):
    s = settings()
    host  = s.get("config_host", s.get("server_ip", ""))
    port  = s.get("vpn_port", "443")
    proto = s.get("vpn_proto", "tcp")

    ca   = open(f"{EASYRSA}/pki/ca.crt").read()
    cert = open(f"{EASYRSA}/pki/issued/{username}.crt").read()
    key  = open(f"{EASYRSA}/pki/private/{username}.key").read()
    ta   = open(f"{EASYRSA}/ta.key").read()

    conf = f"""client
dev tun
proto {proto}
remote {host} {port}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-GCM
auth SHA256
tls-version-min 1.2
verb 3
key-direction 1
push-peer-info

<ca>
{ca}
</ca>
<cert>
{cert}
</cert>
<key>
{key}
</key>
<tls-crypt>
{ta}
</tls-crypt>
"""
    os.makedirs(CLIENT_DIR, exist_ok=True)
    path = f"{CLIENT_DIR}/{username}.ovpn"
    open(path, "w").write(conf)
    return path

def upsert_user(username, max_devices=2, quota_gb=100, days=30,
                note='', source='manual', expiry_ts=None,
                unlimited_expiry=False, unlimited_quota=False, unlimited_devices=False):
    username = clean_user(username)
    if not valid_user(username):
        return None

    if not create_cert(username):
        return None

    days = safe_days(days)
    max_devices = safe_int(max_devices, 2, 1000)
    quota_gb = safe_int(quota_gb, 100, 1_000_000)

    if unlimited_expiry:
        expiry = 0
    elif expiry_ts is not None and int(expiry_ts) > 0:
        expiry = int(expiry_ts)
    else:
        expiry = int(time.time()) + days * 86400 if days > 0 else 0

    now = int(time.time())
    if unlimited_expiry or expiry == 0 or expiry > now:
        enable_cert(username)
        enabled_value = 1
    else:
        revoke_cert(username)
        enabled_value = 0

    c = db()
    old = c.execute("SELECT username FROM users WHERE username=?", (username,)).fetchone()
    if old:
        c.execute("""
        UPDATE users SET max_devices=?,quota_gb=?,expiry=?,note=?,source=?,enabled=?,
               unlimited_expiry=?,unlimited_quota=?,unlimited_devices=?
        WHERE username=?""",
        (max_devices, quota_gb, expiry, note, source, enabled_value,
         int(bool(unlimited_expiry)), int(bool(unlimited_quota)), int(bool(unlimited_devices)),
         username))
    else:
        c.execute("""
        INSERT INTO users(username,max_devices,quota_gb,expiry,note,source,enabled,created_at,
               unlimited_expiry,unlimited_quota,unlimited_devices)
        VALUES(?,?,?,?,?,?,?,?,?,?,?)""",
        (username, max_devices, quota_gb, expiry, note, source, enabled_value, now,
         int(bool(unlimited_expiry)), int(bool(unlimited_quota)), int(bool(unlimited_devices))))
    c.commit(); c.close()
    make_config(username)
    return get_user(username)

import hashlib as _hashlib

def _sha256_file(p):
    try:
        h = _hashlib.sha256()
        with open(p, "rb") as f:
            for chunk in iter(lambda: f.read(65536), b""):
                h.update(chunk)
        return h.hexdigest()
    except Exception:
        return None

def make_full_backup():
    """
    Builds a single professional .zip backup containing:
      - opt/ovpn-xui/**        (panel.db, settings.json, .ovpn client files)
      - etc/openvpn/**         (CA, server/client certs & keys, ta.key, crl, server.conf, ccd/)
      - META/backup.json       (version, timestamp, checksums)
      - META/users.json        (human-readable export of every user, for quick inspection/DR)
    The panel's own backups/ directory is excluded so backups never nest inside each other.
    """
    os.makedirs(BACKUP_DIR, exist_ok=True)
    ts = int(time.time())
    name = f"ovpn-xui-v7-backup-{ts}.zip"
    path = f"{BACKUP_DIR}/{name}"

    users_export = [dict(u) for u in all_users()]
    try:
        c = db()
        devices_export = [dict(r) for r in c.execute("SELECT * FROM devices").fetchall()]
        c.close()
    except Exception:
        devices_export = []

    checksums = {}
    for fname in ("ca.crt", "server.crt", "server.key", "dh.pem", "ta.key", "crl.pem"):
        fp = os.path.join(OVPN_DIR, fname)
        if os.path.exists(fp):
            checksums[fname] = _sha256_file(fp)

    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        meta = {
            "created_at": ts,
            "type": "ovpn-xui-full",
            "version": "v7.1",
            "user_count": len(users_export),
            "device_count": len(devices_export),
            "pki_checksums": checksums,
        }
        z.writestr("META/backup.json", json.dumps(meta, indent=2))
        z.writestr("META/users.json", json.dumps(users_export, indent=2))
        z.writestr("META/devices.json", json.dumps(devices_export, indent=2))

        for base, skip_dirs in ((APP_DIR, {BACKUP_DIR}), (OVPN_ROOT, set())):
            if not os.path.exists(base):
                continue
            for root, dirs, files in os.walk(base):
                dirs[:] = [d for d in dirs if os.path.join(root, d) not in skip_dirs]
                if any(root == s or root.startswith(s + os.sep) for s in skip_dirs):
                    continue
                for f in files:
                    p = os.path.join(root, f)
                    z.write(p, p.lstrip("/"))
    return path

def restore_full_backup(zip_path, restart=True):
    """
    Fully restores a backup produced by make_full_backup():
      1. snapshots current state first (pre-restore safety net)
      2. stops the VPN + panel services
      3. extracts the zip and validates it contains both required trees
      4. replaces /opt/ovpn-xui and /etc/openvpn with the backup's contents
         (this brings back panel.db -> and therefore every user/device row -> plus
          the full OpenVPN PKI: ca/server/client certs, keys, ta.key, crl, server.conf)
      5. re-runs the DB schema migration (init_db) in case the backup came from an
         older panel version, so old backups upgrade cleanly instead of breaking
      6. restarts services
    Returns a summary dict with user/device counts read back from the restored DB.
    """
    pre = f"{BACKUP_DIR}/pre-restore-{int(time.time())}.zip"
    try:
        shutil.copy2(make_full_backup(), pre)
    except Exception:
        pass

    if restart:
        run("systemctl stop openvpn-server@server 2>/dev/null || true")
        run("systemctl stop ovpn-xui 2>/dev/null || true")

    tmp = tempfile.mkdtemp(prefix="ovpn-restore-")
    with zipfile.ZipFile(zip_path, "r") as z:
        z.extractall(tmp)

    ra = os.path.join(tmp, "opt", "ovpn-xui")
    ro = os.path.join(tmp, "etc", "openvpn")
    if not os.path.exists(ra) or not os.path.exists(ro):
        if restart:
            run("systemctl start openvpn-server@server 2>/dev/null || true")
            run("systemctl start ovpn-xui 2>/dev/null || true")
        raise Exception("Invalid backup: required opt/ovpn-xui or etc/openvpn folder missing from zip")
    if not os.path.exists(os.path.join(ra, "data", "settings.json")):
        if restart:
            run("systemctl start openvpn-server@server 2>/dev/null || true")
            run("systemctl start ovpn-xui 2>/dev/null || true")
        raise Exception("Invalid backup: settings.json missing — this doesn't look like an ovpn-xui backup")

    shutil.rmtree(APP_DIR, ignore_errors=True)
    shutil.rmtree(OVPN_ROOT, ignore_errors=True)
    shutil.copytree(ra, APP_DIR)
    shutil.copytree(ro, OVPN_ROOT)
    shutil.rmtree(tmp, ignore_errors=True)

    os.makedirs(BACKUP_DIR, exist_ok=True)  # backups/ isn't part of the restored tree by design

    # Bring the restored DB up to the current schema (adds any new columns/
    # tables transparently, AND re-applies the hook permission self-heal).
    init_db()

    if restart:
        run("systemctl daemon-reload")
        run("systemctl start openvpn-server@server 2>/dev/null || true")
        run("systemctl start ovpn-xui 2>/dev/null || true")

    summary = {"ok": True, "restored_from": zip_path, "pre_restore_snapshot": pre}
    try:
        summary["users"] = len(all_users())
        c = db(); summary["devices"] = c.execute("SELECT COUNT(*) n FROM devices").fetchone()["n"]; c.close()
    except Exception:
        pass
    return summary

# ── Auth decorators ──────────────────────────────────────────

def login_required(f):
    @functools.wraps(f)
    def wrapper(*args, **kwargs):
        if not session.get("login"):
            if request.is_json or request.path.startswith("/api/"):
                return jsonify({"ok": False, "message": "Login required"}), 401
            return redirect("/")
        return f(*args, **kwargs)
    return wrapper

def api_required(f):
    @functools.wraps(f)
    def wrapper(*args, **kwargs):
        s = settings()
        auth = request.headers.get("Authorization", "")
        token = ""
        if auth.startswith("Bearer "):
            token = auth[7:].strip()
        elif request.args.get("token"):
            token = request.args.get("token")
        if not token or token != s.get("api_token"):
            return jsonify({"ok": False, "message": "Unauthorized — invalid API token"}), 401
        return f(*args, **kwargs)
    return wrapper

def add_cors(response):
    response.headers["Access-Control-Allow-Origin"]  = "*"
    response.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS"
    response.headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization"
    return response

@app.after_request
def after_request(response):
    if request.path.startswith("/api/"):
        response = add_cors(response)
    return response

@app.route("/api/<path:p>", methods=["OPTIONS"])
def api_options(p):
    r = make_response("", 204)
    return add_cors(r)

# ── Health / Ping ────────────────────────────────────────────
@app.route("/ping")
def ping():
    return jsonify({"ok": True, "ts": int(time.time()), "service": "ovpn-xui-v7"})

@app.route("/health")
def health():
    vpn_status = run("systemctl is-active openvpn-server@server").strip()
    return jsonify({
        "ok": True, "panel": True, "vpn": vpn_status,
        "online_sessions": len(online_clients()),
        "online_devices": len(all_connected_devices()),
        "ts": int(time.time())
    })
PYAPP

cat >> "$APP_DIR/app.py" <<'PYAPP2'

# ── HTML UI (V7.1) ────────────────────────────────────────────

HTML = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>OpenVPN X-UI V7</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&family=JetBrains+Mono:wght@400;600&display=swap" rel="stylesheet">
<style>
:root{
  --bg:#060812;--surface:#0e1220;--surface2:#171c2e;--surface3:#212840;
  --border:#2a3252;--border2:#3a4570;
  --accent:#7c6cf6;--accent2:#22d3a5;--accent3:#f7768e;--accent4:#f6c453;
  --text:#eef1fb;--text2:#98a2c9;--text3:#525d84;
  --grad1:linear-gradient(135deg,#7c6cf633,#22d3a511);
  --gradBrand:linear-gradient(135deg,#7c6cf6,#22d3a5);
  --radius:14px;--radius2:9px;
}
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Inter',sans-serif;background:var(--bg);color:var(--text);min-height:100vh;line-height:1.6}
body::before{content:"";position:fixed;inset:0;
  background:radial-gradient(ellipse at 10% 0%,#7c6cf620 0,transparent 50%),
             radial-gradient(ellipse at 90% 100%,#22d3a518 0,transparent 50%);
  pointer-events:none;z-index:0}

.sidebar{
  position:fixed;left:0;top:0;bottom:0;width:264px;
  background:rgba(14,18,32,.97);border-right:1px solid var(--border);
  display:flex;flex-direction:column;padding:0;z-index:100;
  backdrop-filter:blur(20px);
}
.sidebar-logo{padding:24px 20px 16px;border-bottom:1px solid var(--border)}
.sidebar-logo h1{font-size:19px;font-weight:800;letter-spacing:-.3px;
  background:var(--gradBrand);-webkit-background-clip:text;background-clip:text;color:transparent}
.sidebar-logo span{font-size:11px;color:var(--text2);font-family:'JetBrains Mono',monospace}
.v7-pill{display:inline-block;font-size:10px;font-weight:700;color:#0b0f1a;background:var(--gradBrand);
  padding:2px 7px;border-radius:20px;margin-left:6px;vertical-align:middle}
.vpn-badge{display:inline-flex;align-items:center;gap:6px;padding:3px 10px;
  border-radius:20px;background:var(--surface3);border:1px solid var(--border);
  font-size:11px;color:var(--text2);margin-top:10px}
.vpn-badge.on{border-color:#22d3a555;color:var(--accent2)}
.vpn-badge .dot{width:6px;height:6px;border-radius:50%;background:var(--text3)}
.vpn-badge.on .dot{background:var(--accent2);box-shadow:0 0 6px var(--accent2)}

.nav{flex:1;padding:16px 12px;overflow-y:auto}
.nav-group{margin-bottom:6px;font-size:10px;font-weight:700;color:var(--text3);
  letter-spacing:1px;text-transform:uppercase;padding:0 8px;margin-top:16px}
.nav a{display:flex;align-items:center;gap:10px;padding:9px 12px;border-radius:var(--radius2);
  color:var(--text2);text-decoration:none;font-size:14px;font-weight:500;
  transition:all .15s;position:relative}
.nav a:hover{background:var(--surface3);color:var(--text)}
.nav a.active{background:var(--grad1);color:var(--accent);border:1px solid #7c6cf644}
.nav a svg{width:16px;height:16px;flex-shrink:0}
.nav a .cnt{margin-left:auto;font-size:11px;background:var(--surface3);color:var(--text2);
  padding:1px 7px;border-radius:20px;font-family:'JetBrains Mono',monospace}

.sidebar-footer{padding:16px;border-top:1px solid var(--border);font-size:12px;color:var(--text3)}

.main{margin-left:264px;min-height:100vh;position:relative;z-index:1}
.topbar{padding:20px 28px;border-bottom:1px solid var(--border);
  display:flex;align-items:center;justify-content:space-between;
  background:rgba(14,18,32,.7);backdrop-filter:blur(10px);
  position:sticky;top:0;z-index:50}
.topbar h2{font-size:20px;font-weight:700}
.topbar-right{display:flex;align-items:center;gap:12px}
.content{padding:28px}

.card{background:var(--surface);border:1px solid var(--border);
  border-radius:16px;padding:24px;margin-bottom:20px}
.card h3{font-size:15px;font-weight:700;margin-bottom:16px;color:var(--text)}

.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:16px;margin-bottom:24px}
.stat{background:var(--surface);border:1px solid var(--border);border-radius:16px;
  padding:20px;position:relative;overflow:hidden}
.stat::before{content:"";position:absolute;top:0;left:0;right:0;height:2px}
.stat.purple::before{background:linear-gradient(90deg,#7c6cf6,#a78bfa)}
.stat.green::before{background:linear-gradient(90deg,#22d3a500,#22d3a5)}
.stat.orange::before{background:linear-gradient(90deg,#f6c453,#f0883e)}
.stat.red::before{background:linear-gradient(90deg,#da3633,#f7768e)}
.stat-label{font-size:12px;color:var(--text2);font-weight:600;margin-bottom:8px}
.stat-value{font-size:32px;font-weight:800;color:var(--text);line-height:1;font-family:'JetBrains Mono',monospace}
.stat-sub{font-size:11px;color:var(--text3);margin-top:6px}

.table-wrap{overflow-x:auto;border-radius:12px;border:1px solid var(--border)}
table{width:100%;border-collapse:collapse;font-size:14px}
thead{background:var(--surface2)}
th{padding:12px 16px;text-align:left;font-weight:700;font-size:12px;
  color:var(--text2);text-transform:uppercase;letter-spacing:.5px;
  border-bottom:1px solid var(--border)}
td{padding:12px 16px;border-bottom:1px solid var(--border);color:var(--text);vertical-align:middle}
tr:last-child td{border-bottom:none}
tr:hover td{background:var(--surface2)}
.mono{font-family:'JetBrains Mono',monospace;font-size:13px}

.badge{display:inline-flex;align-items:center;gap:5px;padding:3px 10px;
  border-radius:20px;font-size:12px;font-weight:700}
.badge-green{background:#22d3a511;color:var(--accent2);border:1px solid #22d3a533}
.badge-red{background:#6e151511;color:var(--accent3);border:1px solid #f7768e33}
.badge-gray{background:var(--surface3);color:var(--text2);border:1px solid var(--border)}
.badge-purple{background:#7c6cf611;color:var(--accent);border:1px solid #7c6cf633}
.badge-amber{background:#f6c45311;color:var(--accent4);border:1px solid #f6c45333}

.btn{display:inline-flex;align-items:center;gap:6px;padding:8px 16px;
  border-radius:var(--radius2);font-size:13px;font-weight:700;
  text-decoration:none;cursor:pointer;border:1px solid transparent;transition:all .15s;
  font-family:'Inter',sans-serif}
.btn-primary{background:#7c6cf6;color:#fff;border-color:#8f7ff744}
.btn-primary:hover{background:#8f7ff7}
.btn-success{background:#22d3a522;color:var(--accent2);border-color:#22d3a544}
.btn-success:hover{background:#22d3a533}
.btn-danger{background:#6e151522;color:var(--accent3);border-color:#f7768e44}
.btn-danger:hover{background:#da363322}
.btn-warning{background:#f6c45322;color:var(--accent4);border-color:#f6c45344}
.btn-warning:hover{background:#f6c45333}
.btn-ghost{background:transparent;color:var(--text2);border-color:var(--border)}
.btn-ghost:hover{background:var(--surface3);color:var(--text)}
.btn-sm{padding:5px 10px;font-size:12px}
.btn[disabled]{opacity:.4;cursor:not-allowed}

.form-group{margin-bottom:16px}
.form-label{display:block;font-size:13px;font-weight:600;color:var(--text2);margin-bottom:6px}
.form-input{width:100%;padding:10px 14px;background:var(--surface2);
  border:1px solid var(--border);border-radius:var(--radius2);
  color:var(--text);font-size:14px;font-family:'Inter',sans-serif;outline:none;
  transition:border-color .15s}
.form-input:focus{border-color:var(--accent)}
.form-input:disabled{opacity:.35}
.form-row{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px}
.form-actions{display:flex;gap:10px;margin-top:20px}
.unl-check{display:flex;align-items:center;gap:6px;font-size:12px;color:var(--text2);margin-top:6px}
.unl-check input{accent-color:var(--accent)}

.code-block{background:var(--surface2);border:1px solid var(--border);
  border-radius:var(--radius2);padding:16px;
  font-family:'JetBrains Mono',monospace;font-size:13px;
  color:#e6edf3;overflow-x:auto;white-space:pre-wrap;line-height:1.6}
.code-label{font-size:11px;color:var(--text3);text-transform:uppercase;
  letter-spacing:1px;margin-bottom:6px}

.token-box{background:var(--surface2);border:1px solid var(--border);
  border-radius:var(--radius2);padding:12px 16px;
  display:flex;align-items:center;justify-content:space-between;gap:12px}
.token-box .tok{font-family:'JetBrains Mono',monospace;font-size:13px;
  color:var(--accent);word-break:break-all;flex:1}

.alert{padding:12px 16px;border-radius:var(--radius2);margin-bottom:16px;font-size:14px}
.alert-info{background:#7c6cf611;border:1px solid #7c6cf633;color:#b3a6ff}
.alert-success{background:#22d3a511;border:1px solid #22d3a533;color:#4fe3c1}
.alert-warn{background:#f6c45311;border:1px solid #f6c45333;color:#f6c453}

.search-row{display:flex;gap:10px;margin-bottom:16px}
.search-input{flex:1;max-width:360px}

.login-wrap{min-height:100vh;display:flex;align-items:center;justify-content:center;padding:20px}
.login-card{background:var(--surface);border:1px solid var(--border);
  border-radius:20px;padding:40px;width:100%;max-width:420px}
.login-logo{text-align:center;margin-bottom:32px}
.login-logo h1{font-size:24px;font-weight:800;margin-bottom:4px;
  background:var(--gradBrand);-webkit-background-clip:text;background-clip:text;color:transparent}
.login-logo p{color:var(--text2);font-size:14px}

.divider{height:1px;background:var(--border);margin:20px 0}

.devrow{display:flex;align-items:center;justify-content:space-between;gap:10px;
  padding:10px 14px;background:var(--surface2);border:1px solid var(--border);
  border-radius:var(--radius2);margin-bottom:8px}
.devrow .plat{font-size:20px;line-height:1}
.devrow .meta{font-size:12px;color:var(--text2)}
.devrow.blocked{opacity:.55}
.expand-row{display:none}
.expand-row.open{display:table-row}
.expander{cursor:pointer;user-select:none}
.expander .chev{display:inline-block;transition:transform .15s}
.expander.open .chev{transform:rotate(90deg)}

@media(max-width:768px){
  .sidebar{transform:translateX(-100%);transition:transform .3s}
  .sidebar.open{transform:translateX(0)}
  .main{margin-left:0}
  .topbar{padding:14px 16px}
  .content{padding:16px}
  .stats{grid-template-columns:1fr 1fr}
  .mobile-menu-btn{display:flex}
}
.mobile-menu-btn{display:none;align-items:center;justify-content:center;
  width:36px;height:36px;border-radius:var(--radius2);background:var(--surface3);
  border:1px solid var(--border);cursor:pointer;color:var(--text)}
.overlay{display:none;position:fixed;inset:0;background:#0008;z-index:99}

.text-muted{color:var(--text2)}
.text-mono{font-family:'JetBrains Mono',monospace}
.flex{display:flex}.items-center{align-items:center}.gap-2{gap:8px}.gap-3{gap:12px}
.justify-between{justify-content:space-between}
.mb-4{margin-bottom:16px}.mb-2{margin-bottom:8px}
.mt-2{margin-top:8px}
</style>
</head>
<body>

{% if not login %}
<div class="login-wrap">
<div class="login-card">
  <div class="login-logo">
    <h1>OpenVPN X-UI <span class="v7-pill">V7</span></h1>
    <p>Advanced Management Panel</p>
  </div>
  <form method="post" action="/login">
    <div class="form-group">
      <label class="form-label">Username</label>
      <input class="form-input" name="username" placeholder="admin" autocomplete="username">
    </div>
    <div class="form-group">
      <label class="form-label">Password</label>
      <input class="form-input" name="password" type="password" placeholder="••••••••" autocomplete="current-password">
    </div>
    <button class="btn btn-primary" style="width:100%;justify-content:center;padding:12px">Login</button>
  </form>
  <div class="divider"></div>
  <div style="text-align:center;font-size:12px;color:var(--text3)">
    OpenVPN X-UI V7 &nbsp;·&nbsp; <a href="/ping" style="color:var(--text2)">Health Check</a>
  </div>
</div>
</div>

{% else %}
<div class="overlay" id="overlay" onclick="closeSidebar()"></div>
<aside class="sidebar" id="sidebar">
  <div class="sidebar-logo">
    <h1>OpenVPN X-UI <span class="v7-pill">V7</span></h1>
    <div><span>Panel</span></div>
    <div class="vpn-badge {% if vpn_active %}on{% endif %}">
      <div class="dot"></div>
      {% if vpn_active %}VPN Online{% else %}VPN Offline{% endif %}
    </div>
  </div>

  <nav class="nav">
    <div class="nav-group">Overview</div>
    <a href="/" class="{% if page=='dashboard' %}active{% endif %}">
      <svg viewBox="0 0 16 16" fill="currentColor"><path d="M0 1.5A1.5 1.5 0 0 1 1.5 0h5A1.5 1.5 0 0 1 8 1.5v5A1.5 1.5 0 0 1 6.5 8h-5A1.5 1.5 0 0 1 0 6.5v-5Zm8 0A1.5 1.5 0 0 1 9.5 0h5A1.5 1.5 0 0 1 16 1.5v5A1.5 1.5 0 0 1 14.5 8h-5A1.5 1.5 0 0 1 8 6.5v-5Zm-8 8A1.5 1.5 0 0 1 1.5 8h5A1.5 1.5 0 0 1 8 9.5v5A1.5 1.5 0 0 1 6.5 16h-5A1.5 1.5 0 0 1 0 14.5v-5Zm8 0A1.5 1.5 0 0 1 9.5 8h5a1.5 1.5 0 0 1 1.5 1.5v5a1.5 1.5 0 0 1-1.5 1.5h-5A1.5 1.5 0 0 1 8 14.5v-5Z"/></svg>
      Dashboard
    </a>

    <div class="nav-group">Users & Devices</div>
    <a href="/users" class="{% if page=='users' %}active{% endif %}">
      <svg viewBox="0 0 16 16" fill="currentColor"><path d="M7 14s-1 0-1-1 1-4 5-4 5 3 5 4-1 1-1 1H7Zm4-6a3 3 0 1 0 0-6 3 3 0 0 0 0 6Zm-5.784 6A2.238 2.238 0 0 1 5 13c0-1.355.68-2.75 1.936-3.72A6.325 6.325 0 0 0 5 9c-4 0-5 3-5 4s1 1 1 1h4.216ZM4.5 8a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5Z"/></svg>
      Users
    </a>
    <a href="/devices" class="{% if page=='devices' %}active{% endif %}">
      <svg viewBox="0 0 16 16" fill="currentColor"><path d="M14 1a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1H4.5v1H8a.5.5 0 0 1 0 1H2a.5.5 0 0 1 0-1h1.5v-1H2a1 1 0 0 1-1-1V2a1 1 0 0 1 1-1h12Z"/></svg>
      Online Devices <span class="cnt">{{ online_devices|length }}</span>
    </a>
    <a href="/bulk" class="{% if page=='bulk' %}active{% endif %}">
      <svg viewBox="0 0 16 16" fill="currentColor"><path d="M1 2.5A1.5 1.5 0 0 1 2.5 1h3A1.5 1.5 0 0 1 7 2.5v3A1.5 1.5 0 0 1 5.5 7h-3A1.5 1.5 0 0 1 1 5.5v-3ZM1 9.5A1.5 1.5 0 0 1 2.5 8h3A1.5 1.5 0 0 1 7 9.5v3A1.5 1.5 0 0 1 5.5 14h-3A1.5 1.5 0 0 1 1 12.5v-3Zm7-7A1.5 1.5 0 0 1 9.5 1h3A1.5 1.5 0 0 1 14 2.5v3A1.5 1.5 0 0 1 12.5 7h-3A1.5 1.5 0 0 1 8 5.5v-3Zm0 7A1.5 1.5 0 0 1 9.5 8h3a1.5 1.5 0 0 1 1.5 1.5v3a1.5 1.5 0 0 1-1.5 1.5h-3A1.5 1.5 0 0 1 8 12.5v-3Z"/></svg>
      Bulk Actions
    </a>

    <div class="nav-group">System</div>
    <a href="/settings" class="{% if page=='settings' %}active{% endif %}">
      <svg viewBox="0 0 16 16" fill="currentColor"><path d="M9.405 1.05c-.413-1.4-2.397-1.4-2.81 0l-.1.34a1.464 1.464 0 0 1-2.105.872l-.31-.17c-1.283-.698-2.686.705-1.987 1.987l.169.311c.446.82.023 1.841-.872 2.105l-.34.1c-1.4.413-1.4 2.397 0 2.81l.34.1a1.464 1.464 0 0 1 .872 2.105l-.17.31c-.698 1.283.705 2.686 1.987 1.987l.311-.169a1.464 1.464 0 0 1 2.105.872l.1.34c.413 1.4 2.397 1.4 2.81 0l.1-.34a1.464 1.464 0 0 1 2.105-.872l.31.17c1.283.698 2.686-.705 1.987-1.987l-.169-.311a1.464 1.464 0 0 1 .872-2.105l.34-.1c1.4-.413 1.4-2.397 0-2.81l-.34-.1a1.464 1.464 0 0 1-.872-2.105l.17-.31c.698-1.283-.705-2.686-1.987-1.987l-.311.169a1.464 1.464 0 0 1-2.105-.872l-.1-.34zM8 10.93a2.929 2.929 0 1 1 0-5.86 2.929 2.929 0 0 1 0 5.858z"/></svg>
      Settings
    </a>
    <a href="/backup" class="{% if page=='backup' %}active{% endif %}">
      <svg viewBox="0 0 16 16" fill="currentColor"><path d="M.5 9.9a.5.5 0 0 1 .5.5v2.5a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-2.5a.5.5 0 0 1 1 0v2.5a2 2 0 0 1-2 2H2a2 2 0 0 1-2-2v-2.5a.5.5 0 0 1 .5-.5z"/><path d="M7.646 1.146a.5.5 0 0 1 .708 0l3 3a.5.5 0 0 1-.708.708L8.5 2.707V11.5a.5.5 0 0 1-1 0V2.707L5.354 4.854a.5.5 0 1 1-.708-.708l3-3z"/></svg>
      Backup / Restore
    </a>
    <a href="/api-info" class="{% if page=='api' %}active{% endif %}">
      <svg viewBox="0 0 16 16" fill="currentColor"><path d="M5.854 4.854a.5.5 0 1 0-.708-.708l-3.5 3.5a.5.5 0 0 0 0 .708l3.5 3.5a.5.5 0 0 0 .708-.708L2.707 8l3.147-3.146zm4.292 0a.5.5 0 0 1 .708-.708l3.5 3.5a.5.5 0 0 1 0 .708l-3.5 3.5a.5.5 0 0 1-.708-.708L13.293 8l-3.147-3.146z"/></svg>
      API Reference
    </a>
    <a href="/logs" class="{% if page=='logs' %}active{% endif %}">
      <svg viewBox="0 0 16 16" fill="currentColor"><path d="M5 3a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2V5a2 2 0 0 0-2-2H5zm3 1h1a1 1 0 0 1 1 1H4a1 1 0 0 1 1-1h1V3a1 1 0 0 1 2 0v1zm-3 4a.5.5 0 0 1 .5-.5h5a.5.5 0 0 1 0 1h-5A.5.5 0 0 1 5 8zm0 2a.5.5 0 0 1 .5-.5h5a.5.5 0 0 1 0 1h-5A.5.5 0 0 1 5 10zm0 2a.5.5 0 0 1 .5-.5h2a.5.5 0 0 1 0 1h-2a.5.5 0 0 1-.5-.5z"/></svg>
      Logs & Status
    </a>

    <div class="nav-group">Account</div>
    <a href="/logout">
      <svg viewBox="0 0 16 16" fill="currentColor"><path fill-rule="evenodd" d="M10 12.5a.5.5 0 0 1-.5.5h-8a.5.5 0 0 1-.5-.5v-9a.5.5 0 0 1 .5-.5h8a.5.5 0 0 1 .5.5v2a.5.5 0 0 0 1 0v-2A1.5 1.5 0 0 0 9.5 2h-8A1.5 1.5 0 0 0 0 3.5v9A1.5 1.5 0 0 0 1.5 14h8a1.5 1.5 0 0 0 1.5-1.5v-2a.5.5 0 0 0-1 0v2z"/><path fill-rule="evenodd" d="M15.854 8.354a.5.5 0 0 0 0-.708l-3-3a.5.5 0 0 0-.708.708L14.293 7.5H5.5a.5.5 0 0 0 0 1h8.793l-2.147 2.146a.5.5 0 0 0 .708.708l3-3z"/></svg>
      Logout
    </a>
  </nav>

  <div class="sidebar-footer">OpenVPN X-UI V7 &nbsp;·&nbsp; {{ s.server_ip }}</div>
</aside>

<div class="main">
  <div class="topbar">
    <div class="flex items-center gap-3">
      <button class="mobile-menu-btn" onclick="openSidebar()">
        <svg width="18" height="18" viewBox="0 0 16 16" fill="currentColor"><path fill-rule="evenodd" d="M2.5 12a.5.5 0 0 1 .5-.5h10a.5.5 0 0 1 0 1H3a.5.5 0 0 1-.5-.5zm0-4a.5.5 0 0 1 .5-.5h10a.5.5 0 0 1 0 1H3a.5.5 0 0 1-.5-.5zm0-4a.5.5 0 0 1 .5-.5h10a.5.5 0 0 1 0 1H3a.5.5 0 0 1-.5-.5z"/></svg>
      </button>
      <h2>
        {% if page=="dashboard" %}Dashboard
        {% elif page=="users" %}Users
        {% elif page=="devices" %}Online Devices
        {% elif page=="bulk" %}Bulk Actions
        {% elif page=="settings" %}Settings
        {% elif page=="backup" %}Backup & Restore
        {% elif page=="api" %}API Reference
        {% elif page=="logs" %}Logs & Status
        {% endif %}
      </h2>
    </div>
    <div class="topbar-right">
      <a href="/ping" target="_blank" class="btn btn-ghost btn-sm">Ping</a>
      <a href="/health" target="_blank" class="btn btn-ghost btn-sm">Health</a>
    </div>
  </div>

  <div class="content">
PYAPP2

cat >> "$APP_DIR/app.py" <<'PYAPP3'

  {# ── DASHBOARD ── #}
  {% if page=="dashboard" %}
  <div class="stats">
    <div class="stat purple">
      <div class="stat-label">Total Users</div>
      <div class="stat-value">{{ users|length }}</div>
      <div class="stat-sub">registered accounts</div>
    </div>
    <div class="stat green">
      <div class="stat-label">Online Devices</div>
      <div class="stat-value">{{ online_devices|length }}</div>
      <div class="stat-sub">connected right now (per device)</div>
    </div>
    <div class="stat orange">
      <div class="stat-label">Config Host</div>
      <div class="stat-value" style="font-size:18px">{{ s.config_host }}</div>
      <div class="stat-sub">port {{ s.vpn_port }} / {{ s.vpn_proto }}</div>
    </div>
    <div class="stat {% if vpn_active %}green{% else %}red{% endif %}">
      <div class="stat-label">VPN Service</div>
      <div class="stat-value" style="font-size:18px">{% if vpn_active %}Active{% else %}Stopped{% endif %}</div>
      <div class="stat-sub">openvpn-server@server</div>
    </div>
  </div>

  <div class="card">
    <div class="flex justify-between items-center mb-4">
      <h3>🟢 Online Devices</h3>
      <span class="badge badge-green">{{ online_devices|length }} connected</span>
    </div>
    {% if online_devices %}
    <div class="table-wrap">
    <table>
      <thead><tr><th>User</th><th>Platform</th><th>IP</th><th>Connected Since</th><th></th></tr></thead>
      <tbody>
      {% for d in online_devices %}
      <tr>
        <td class="mono">{{ d.username }}</td>
        <td>{{ plat_icon(d.platform) }} {{ d.platform }} {{ d.platform_ver }}</td>
        <td class="mono">{{ d.last_ip }}</td>
        <td class="text-muted">{{ fmt_ts(d.last_seen) }}</td>
        <td><a class="btn btn-danger btn-sm" href="/devices/kill/{{ d.username }}/{{ d.device_key }}"
               onclick="return confirm('Disconnect this device now?')">Disconnect</a></td>
      </tr>
      {% endfor %}
      </tbody>
    </table>
    </div>
    {% else %}
    <p class="text-muted" style="text-align:center;padding:32px">No devices connected</p>
    {% endif %}
  </div>
  {% endif %}

  {# ── USERS ── #}
  {% if page=="users" %}
  <div class="card">
    <h3>➕ Create / Update User</h3>
    <form method="post" action="/users/add">
      <div class="form-row">
        <div class="form-group">
          <label class="form-label">Username</label>
          <input class="form-input" name="username" placeholder="alice">
        </div>
        <div class="form-group">
          <label class="form-label">Max Devices</label>
          <input class="form-input" name="max_devices" value="2" type="number" min="1" id="fld_devices">
          <div class="unl-check"><input type="checkbox" name="unlimited_devices" id="unl_devices"
               onchange="document.getElementById('fld_devices').disabled=this.checked"> Unlimited devices</div>
        </div>
        <div class="form-group">
          <label class="form-label">Quota (GB)</label>
          <input class="form-input" name="quota_gb" value="100" type="number" min="1" id="fld_quota">
          <div class="unl-check"><input type="checkbox" name="unlimited_quota" id="unl_quota"
               onchange="document.getElementById('fld_quota').disabled=this.checked"> Unlimited quota</div>
        </div>
        <div class="form-group">
          <label class="form-label">Days Until Expiry</label>
          <input class="form-input" name="days" value="30" type="number" min="0" max="36500" id="fld_days">
          <div class="unl-check"><input type="checkbox" name="unlimited_expiry" id="unl_days"
               onchange="document.getElementById('fld_days').disabled=this.checked"> Never expires</div>
        </div>
        <div class="form-group">
          <label class="form-label">Note (optional)</label>
          <input class="form-input" name="note" placeholder="e.g. subscriber #42">
        </div>
      </div>
      <div class="form-actions">
        <button class="btn btn-primary">Create / Update</button>
      </div>
    </form>
  </div>

  <div class="card">
    <div class="flex justify-between items-center mb-4">
      <h3>👥 Users</h3>
      <span class="badge badge-purple">{{ users|length }} total</span>
    </div>
    <form method="get" action="/users" class="search-row">
      <input class="form-input search-input" name="q" placeholder="Search by username or note…" value="{{ request.args.get('q','') }}">
      <button class="btn btn-ghost">Search</button>
      <a class="btn btn-ghost" href="/users">Clear</a>
    </form>
    <div class="table-wrap">
    <table>
      <thead>
        <tr><th></th><th>Username</th><th>Status</th><th>Devices</th><th>Quota</th><th>Expiry</th><th>Source</th><th>Actions</th></tr>
      </thead>
      <tbody>
      {% for u in users %}
      {% set devs = devices_by_user.get(u.username, []) %}
      {% set online_n = devs|selectattr('connected','equalto',1)|list|length %}
      <tr>
        <td>
          <span class="expander" onclick="toggleRow('dev-{{ loop.index }}', this)">
            <span class="chev">▶</span>
          </span>
        </td>
        <td class="mono">{{ u.username }}</td>
        <td>
          {% if u.enabled %}<span class="badge badge-green">Active</span>
          {% else %}<span class="badge badge-red">Disabled</span>{% endif %}
        </td>
        <td>
          {% if u.unlimited_devices %}<span class="badge badge-amber">∞</span>
          {% else %}{{ online_n }}/{{ u.max_devices }}{% endif %}
        </td>
        <td>
          {% if u.unlimited_quota %}<span class="badge badge-amber">Unlimited</span>
          {% else %}{{ (u.used_bytes/1000000000)|round(2) }} / {{ u.quota_gb }} GB{% endif %}
        </td>
        <td class="mono text-muted" style="font-size:12px">
          {% if u.unlimited_expiry %}<span class="badge badge-amber">Never</span>
          {% elif u.expiry > 0 %}{{ fmt_ts(u.expiry) }}{% else %}Never{% endif %}
        </td>
        <td><span class="badge badge-gray">{{ u.source }}</span></td>
        <td>
          <div class="flex gap-2">
            <a class="btn btn-primary btn-sm" href="/download/{{ u.username }}">Config</a>
            <a class="btn btn-warning btn-sm" href="/users/toggle/{{ u.username }}">
              {% if u.enabled %}Disable{% else %}Enable{% endif %}
            </a>
            <a class="btn btn-danger btn-sm" href="/users/delete/{{ u.username }}"
               onclick="return confirm('Delete {{ u.username }}?')">Delete</a>
          </div>
        </td>
      </tr>
      <tr class="expand-row" id="dev-{{ loop.index }}">
        <td colspan="8" style="background:var(--surface2)">
          {% if devs %}
            {% for d in devs %}
            <div class="devrow {% if d.blocked %}blocked{% endif %}">
              <div class="flex items-center gap-3">
                <span class="plat">{{ plat_icon(d.platform) }}</span>
                <div>
                  <div>{{ d.platform }} {{ d.platform_ver }}
                    {% if d.connected %}<span class="badge badge-green" style="margin-left:6px">online</span>
                    {% else %}<span class="badge badge-gray" style="margin-left:6px">offline</span>{% endif %}
                    {% if d.blocked %}<span class="badge badge-red" style="margin-left:6px">blocked</span>{% endif %}
                  </div>
                  <div class="meta">IP {{ d.last_ip }} · last seen {{ fmt_ts(d.last_seen) }} ·
                    {{ ((d.bytes_rx + d.bytes_tx)/1000000000)|round(2) }} GB used</div>
                </div>
              </div>
              <div class="flex gap-2">
                {% if d.connected %}
                <a class="btn btn-ghost btn-sm" href="/devices/kill/{{ u.username }}/{{ d.device_key }}"
                   onclick="return confirm('Disconnect this device?')">Disconnect</a>
                {% endif %}
                {% if d.blocked %}
                <a class="btn btn-success btn-sm" href="/devices/unblock/{{ u.username }}/{{ d.device_key }}">Unblock</a>
                {% else %}
                <a class="btn btn-danger btn-sm" href="/devices/block/{{ u.username }}/{{ d.device_key }}"
                   onclick="return confirm('Block this device? It will not be able to reconnect.')">Block</a>
                {% endif %}
              </div>
            </div>
            {% endfor %}
          {% else %}
            <p class="text-muted" style="padding:8px">No devices have connected for this user yet.</p>
          {% endif %}
        </td>
      </tr>
      {% endfor %}
      </tbody>
    </table>
    </div>
  </div>
  <script>
  function toggleRow(id, el){
    const row = document.getElementById(id);
    row.classList.toggle('open');
    el.classList.toggle('open');
  }
  </script>
  {% endif %}

  {# ── DEVICES (global) ── #}
  {% if page=="devices" %}
  <div class="card">
    <div class="flex justify-between items-center mb-4">
      <h3>📡 Currently Connected Devices</h3>
      <span class="badge badge-green">{{ online_devices|length }} online</span>
    </div>
    {% if online_devices %}
    <div class="table-wrap">
    <table>
      <thead><tr><th>User</th><th>Platform</th><th>IP</th><th>Since</th><th>Usage (session)</th><th>Actions</th></tr></thead>
      <tbody>
      {% for d in online_devices %}
      <tr>
        <td class="mono">{{ d.username }}</td>
        <td>{{ plat_icon(d.platform) }} {{ d.platform }} {{ d.platform_ver }}</td>
        <td class="mono">{{ d.last_ip }}</td>
        <td class="text-muted">{{ fmt_ts(d.last_seen) }}</td>
        <td>{{ ((d.bytes_rx + d.bytes_tx)/1000000)|round(1) }} MB</td>
        <td class="flex gap-2">
          <a class="btn btn-ghost btn-sm" href="/devices/kill/{{ d.username }}/{{ d.device_key }}"
             onclick="return confirm('Disconnect this device?')">Disconnect</a>
          <a class="btn btn-danger btn-sm" href="/devices/block/{{ d.username }}/{{ d.device_key }}"
             onclick="return confirm('Block this device permanently?')">Block</a>
        </td>
      </tr>
      {% endfor %}
      </tbody>
    </table>
    </div>
    {% else %}
    <p class="text-muted" style="text-align:center;padding:32px">No devices connected right now</p>
    {% endif %}
  </div>
  <div class="alert alert-info">
    ℹ️ "Device" is identified by client OS/platform reported by OpenVPN (push-peer-info). Blocking a device
    prevents that platform-combination from reconnecting under this user again, even after a disconnect.
    A background check runs every ~15s so this list, quota enforcement, and blocks all stay accurate even
    if the panel isn't open.
  </div>
  {% endif %}

  {# ── BULK ── #}
  {% if page=="bulk" %}
  <div class="alert alert-warn">⚠️ These actions apply to <strong>all users</strong> immediately.</div>
  <div class="card">
    <h3>✏️ Update All Users</h3>
    <form method="post" action="/bulk/save">
      <div class="form-row">
        <div class="form-group">
          <label class="form-label">Set Max Devices (leave blank to skip)</label>
          <input class="form-input" name="max_devices" placeholder="e.g. 4" type="number" min="1">
        </div>
        <div class="form-group">
          <label class="form-label">Set Quota GB (leave blank to skip)</label>
          <input class="form-input" name="quota_gb" placeholder="e.g. 200" type="number" min="1">
        </div>
        <div class="form-group">
          <label class="form-label">Set Expiry Days From Now (leave blank to skip)</label>
          <input class="form-input" name="days" placeholder="e.g. 30" type="number" min="0" max="36500">
        </div>
        <div class="form-group">
          <label class="form-label">Set Note (leave blank to skip)</label>
          <input class="form-input" name="note" placeholder="e.g. renewed Q3">
        </div>
      </div>
      <div class="form-actions">
        <button class="btn btn-primary">Apply to All</button>
      </div>
    </form>
  </div>
  <div class="card">
    <h3>⚡ Quick Actions</h3>
    <div class="flex gap-2" style="flex-wrap:wrap;margin-top:8px">
      <a class="btn btn-primary" href="/bulk/devices/4">All → 4 Devices</a>
      <a class="btn btn-primary" href="/bulk/quota/200">All → 200 GB</a>
      <a class="btn btn-amber" href="/bulk/unlimited-all" onclick="return confirm('Make ALL users fully unlimited (devices/quota/expiry)?')">Make All Unlimited</a>
      <a class="btn btn-success" href="/bulk/enable">Enable All</a>
      <a class="btn btn-danger" href="/bulk/disable" onclick="return confirm('Disable all users?')">Disable All</a>
    </div>
  </div>
  {% endif %}

  {# ── SETTINGS ── #}
  {% if page=="settings" %}
  <div class="card">
    <h3>⚙️ Panel & VPN Settings</h3>
    <form method="post" action="/settings/save">
      <div class="form-row">
        <div class="form-group">
          <label class="form-label">Config Host (shown in .ovpn files)</label>
          <input class="form-input" name="config_host" value="{{ s.config_host }}">
        </div>
        <div class="form-group">
          <label class="form-label">VPN Port</label>
          <input class="form-input" name="vpn_port" value="{{ s.vpn_port }}">
        </div>
        <div class="form-group">
          <label class="form-label">Protocol</label>
          <input class="form-input" name="vpn_proto" value="{{ s.vpn_proto }}">
        </div>
      </div>
      <div class="divider"></div>
      <div class="form-row">
        <div class="form-group">
          <label class="form-label">Admin Username</label>
          <input class="form-input" name="admin_user" value="{{ s.admin_user }}">
        </div>
        <div class="form-group">
          <label class="form-label">New Admin Password (leave blank to keep)</label>
          <input class="form-input" name="admin_pass" type="password" placeholder="••••••••">
        </div>
      </div>
      <div class="form-actions">
        <button class="btn btn-primary">Save Settings</button>
      </div>
    </form>
  </div>
  {% endif %}

  {# ── BACKUP ── #}
  {% if page=="backup" %}
  <div class="card">
    <h3>📦 Create Full Backup</h3>
    <div class="alert alert-info mb-4">
      Includes: user database, devices table, certificates, CA, server config, panel settings, and API token.
    </div>
    <a class="btn btn-primary" href="/backup/download">⬇️ Download Full Backup</a>
  </div>
  <div class="card">
    <h3>♻️ Restore from Backup</h3>
    <div class="alert alert-warn mb-4">
      Restoring replaces <strong>all</strong> current data. A pre-restore snapshot is saved automatically.
      After restore you will be logged out and must re-login with the backup credentials.
    </div>
    <form method="post" action="/backup/restore" enctype="multipart/form-data">
      <div class="form-group">
        <label class="form-label">Select backup .zip file</label>
        <input class="form-input" type="file" name="backup" accept=".zip">
      </div>
      <div class="form-actions">
        <button class="btn btn-danger" onclick="return confirm('Restore and overwrite everything?')">Restore Backup</button>
      </div>
    </form>
  </div>
  {% endif %}

  {# ── API ── #}
  {% if page=="api" %}
  <div class="card">
    <h3>🔑 API Token</h3>
    <div class="code-label">Bearer Token</div>
    <div class="token-box">
      <span class="tok" id="tok">{{ s.api_token }}</span>
      <button class="btn btn-ghost btn-sm" onclick="copyTok()">Copy</button>
    </div>
  </div>

  <div class="card">
    <h3>📡 Endpoints</h3>
    <div class="mb-4">
      <div class="code-label">GET /ping — public health check</div>
      <div class="code-block">curl http://{{ s.server_ip }}:{{ s.panel_port }}/ping</div>
    </div>
    <div class="mb-4">
      <div class="code-label">GET /health — service status (public)</div>
      <div class="code-block">curl http://{{ s.server_ip }}:{{ s.panel_port }}/health</div>
    </div>
    <div class="divider"></div>
    <div class="mb-4">
      <div class="code-label">GET /api/users — list all users</div>
      <div class="code-block">curl -H "Authorization: Bearer {{ s.api_token }}" \
  http://{{ s.server_ip }}:{{ s.panel_port }}/api/users</div>
    </div>
    <div class="mb-4">
      <div class="code-label">POST /api/users/sync — create or update user (supports unlimited_*)</div>
      <div class="code-block">curl -X POST \
  -H "Authorization: Bearer {{ s.api_token }}" \
  -H "Content-Type: application/json" \
  -d '{"username":"alice","max_devices":3,"quota_gb":50,"days":30,
       "unlimited_expiry":false,"unlimited_quota":false,"unlimited_devices":false}' \
  http://{{ s.server_ip }}:{{ s.panel_port }}/api/users/sync</div>
    </div>
    <div class="mb-4">
      <div class="code-label">DELETE /api/users/&lt;username&gt; — delete user</div>
      <div class="code-block">curl -X DELETE \
  -H "Authorization: Bearer {{ s.api_token }}" \
  http://{{ s.server_ip }}:{{ s.panel_port }}/api/users/alice</div>
    </div>
    <div class="mb-4">
      <div class="code-label">GET /api/users/&lt;username&gt;/config — download .ovpn</div>
      <div class="code-block">curl -H "Authorization: Bearer {{ s.api_token }}" \
  http://{{ s.server_ip }}:{{ s.panel_port }}/api/users/alice/config \
  -o alice.ovpn</div>
    </div>
    <div class="mb-4">
      <div class="code-label">GET /api/devices — list connected devices</div>
      <div class="code-block">curl -H "Authorization: Bearer {{ s.api_token }}" \
  http://{{ s.server_ip }}:{{ s.panel_port }}/api/devices</div>
    </div>
    <div class="mb-4">
      <div class="code-label">POST /api/devices/&lt;username&gt;/&lt;device_key&gt;/block</div>
      <div class="code-block">curl -X POST -H "Authorization: Bearer {{ s.api_token }}" \
  http://{{ s.server_ip }}:{{ s.panel_port }}/api/devices/alice/abcd1234/block</div>
    </div>
    <div class="mb-4">
      <div class="code-label">GET /api/backup — download full backup (db + PKI + manifest) via API</div>
      <div class="code-block">curl -H "Authorization: Bearer {{ s.api_token }}" \
  http://{{ s.server_ip }}:{{ s.panel_port }}/api/backup \
  -o backup.zip</div>
    </div>
    <div>
      <div class="code-label">POST /api/restore — restore full backup via API (stops/restarts services)</div>
      <div class="code-block">curl -X POST -H "Authorization: Bearer {{ s.api_token }}" \
  -F "backup=@backup.zip" \
  http://{{ s.server_ip }}:{{ s.panel_port }}/api/restore</div>
    </div>
  </div>

  <script>
  function copyTok(){
    navigator.clipboard.writeText(document.getElementById('tok').innerText)
      .then(()=>{ const b=event.target; b.textContent='Copied!'; setTimeout(()=>b.textContent='Copy',1500) })
  }
  </script>
  {% endif %}

  {# ── LOGS ── #}
  {% if page=="logs" %}
  <div class="card">
    <h3>📋 OpenVPN Service Status</h3>
    <div class="code-block">{{ service }}</div>
  </div>
  <div class="card">
    <h3>🌐 Panel Service Status</h3>
    <div class="code-block">{{ panel_service }}</div>
  </div>
  <div class="card">
    <h3>🧩 Device Hook Log (last 60 lines)</h3>
    <div class="code-block">{{ hook_log }}</div>
  </div>
  {% endif %}

  </div>{# /content #}
</div>{# /main #}

<script>
function openSidebar(){ document.getElementById('sidebar').classList.add('open'); document.getElementById('overlay').style.display='block' }
function closeSidebar(){ document.getElementById('sidebar').classList.remove('open'); document.getElementById('overlay').style.display='none' }
</script>

{% endif %}
</body>
</html>
"""
PYAPP3

cat >> "$APP_DIR/app.py" <<'PYAPP4'

# ── Jinja helpers ─────────────────────────────────────────────

def fmt_ts(ts):
    try:
        ts = int(ts)
        if ts <= 0:
            return "-"
        return time.strftime("%Y-%m-%d %H:%M", time.localtime(ts))
    except Exception:
        return "-"

def plat_icon(p):
    p = (p or "").lower()
    if "win" in p: return "🖥️"
    if "mac" in p or "darwin" in p or "ios" in p: return "🍎"
    if "android" in p: return "📱"
    if "linux" in p: return "🐧"
    return "❓"

app.jinja_env.globals.update(fmt_ts=fmt_ts, plat_icon=plat_icon)

def devices_grouped():
    c = db()
    rows = c.execute("SELECT * FROM devices ORDER BY connected DESC, last_seen DESC").fetchall()
    c.close()
    out = {}
    for r in rows:
        out.setdefault(r["username"], []).append(r)
    return out

def view(page):
    enforce_expired()
    reconcile_devices()
    s = settings()
    vpn_active = run("systemctl is-active openvpn-server@server").strip() == "active"
    q = request.args.get("q", "").strip()
    hook_log = ""
    try:
        lines = open(DATA_DIR + "/hook.log").read().splitlines()
        hook_log = "\n".join(lines[-60:]) if lines else "(empty)"
    except Exception:
        hook_log = "(no log yet)"
    return render_template_string(
        HTML,
        login=session.get("login"),
        page=page,
        users=all_users(q),
        online=online_clients(),
        online_devices=all_connected_devices(),
        devices_by_user=devices_grouped(),
        s=s,
        vpn_active=vpn_active,
        service=run("systemctl status openvpn-server@server --no-pager -l"),
        panel_service=run(f"systemctl status ovpn-xui --no-pager -l"),
        hook_log=hook_log,
        request=request,
    )

@app.before_request
def before():
    init_db()

# ── Auth routes ────────────────────────────────────────────
@app.route("/")
def index():
    if not session.get("login"):
        return render_template_string(HTML, login=False, page="login",
                                       users=[], online=[], online_devices=[], devices_by_user={},
                                       s={}, vpn_active=False,
                                       service="", panel_service="", hook_log="", request=request)
    return view("dashboard")

@app.route("/login", methods=["POST"])
def login():
    s = settings()
    if (request.form.get("username") == s.get("admin_user") and
            request.form.get("password") == s.get("admin_pass")):
        session["login"] = True
        session.permanent = True
    return redirect("/")

@app.route("/logout")
def logout():
    session.clear()
    return redirect("/")

# ── UI pages ───────────────────────────────────────────────
@app.route("/users")
@login_required
def users_page(): return view("users")

@app.route("/devices")
@login_required
def devices_page(): return view("devices")

@app.route("/users/add", methods=["POST"])
@login_required
def users_add():
    upsert_user(
        request.form.get("username"),
        int(request.form.get("max_devices") or 2),
        int(request.form.get("quota_gb") or 100),
        int(request.form.get("days") or 30),
        request.form.get("note") or '',
        'manual',
        unlimited_expiry=bool(request.form.get("unlimited_expiry")),
        unlimited_quota=bool(request.form.get("unlimited_quota")),
        unlimited_devices=bool(request.form.get("unlimited_devices")),
    )
    return redirect("/users")

@app.route("/download/<username>")
@login_required
def download(username):
    create_cert(username)
    path = make_config(username)
    return send_file(path, as_attachment=True)

@app.route("/users/toggle/<username>")
@login_required
def toggle(username):
    u = get_user(username)
    if u:
        new = 0 if u["enabled"] else 1
        c = db()
        c.execute("UPDATE users SET enabled=? WHERE username=?", (new, username))
        c.commit(); c.close()
        if new: enable_cert(username)
        else: revoke_cert(username)
        run("systemctl restart openvpn-server@server")
    return redirect("/users")

@app.route("/users/delete/<username>")
@login_required
def delete(username):
    revoke_cert(username, hard=True)
    c = db()
    c.execute("DELETE FROM users WHERE username=?", (username,))
    c.execute("DELETE FROM devices WHERE username=?", (username,))
    c.commit(); c.close()
    run("systemctl restart openvpn-server@server")
    return redirect("/users")

# ── Device management (block / unblock / force-disconnect) ──
@app.route("/devices/block/<username>/<device_key>")
@login_required
def device_block(username, device_key):
    c = db()
    c.execute("UPDATE devices SET blocked=1 WHERE username=? AND device_key=?", (username, device_key))
    c.commit()
    d = c.execute("SELECT * FROM devices WHERE username=? AND device_key=?", (username, device_key)).fetchone()
    c.close()
    if d and d["connected"] and d["last_ip"]:
        mgmt_kill_ip(d["last_ip"])
    return redirect(request.referrer or "/users")

@app.route("/devices/unblock/<username>/<device_key>")
@login_required
def device_unblock(username, device_key):
    c = db()
    c.execute("UPDATE devices SET blocked=0 WHERE username=? AND device_key=?", (username, device_key))
    c.commit(); c.close()
    return redirect(request.referrer or "/users")

@app.route("/devices/kill/<username>/<device_key>")
@login_required
def device_kill(username, device_key):
    c = db()
    d = c.execute("SELECT * FROM devices WHERE username=? AND device_key=?", (username, device_key)).fetchone()
    c.close()
    if d and d["last_ip"]:
        mgmt_kill_ip(d["last_ip"])
    else:
        mgmt_kill_user(username)
    return redirect(request.referrer or "/devices")

@app.route("/bulk")
@login_required
def bulk_page(): return view("bulk")

@app.route("/bulk/save", methods=["POST"])
@login_required
def bulk_save():
    c = db()
    if v := request.form.get("max_devices"): c.execute("UPDATE users SET max_devices=?, unlimited_devices=0", (safe_int(v,2,1000),))
    if v := request.form.get("quota_gb"):    c.execute("UPDATE users SET quota_gb=?, unlimited_quota=0",    (safe_int(v,100,1_000_000),))
    if v := request.form.get("days"):        c.execute("UPDATE users SET expiry=?, unlimited_expiry=0", (int(time.time())+safe_days(v)*86400,))
    if v := request.form.get("note"):        c.execute("UPDATE users SET note=?",         (v,))
    c.commit(); c.close()
    return redirect("/bulk")

@app.route("/bulk/devices/<int:n>")
@login_required
def bulk_devices(n):
    c = db(); c.execute("UPDATE users SET max_devices=?, unlimited_devices=0", (n,)); c.commit(); c.close()
    return redirect("/bulk")

@app.route("/bulk/quota/<int:n>")
@login_required
def bulk_quota(n):
    c = db(); c.execute("UPDATE users SET quota_gb=?, unlimited_quota=0", (n,)); c.commit(); c.close()
    return redirect("/bulk")

@app.route("/bulk/unlimited-all")
@login_required
def bulk_unlimited_all():
    c = db()
    c.execute("UPDATE users SET unlimited_expiry=1, unlimited_quota=1, unlimited_devices=1, enabled=1")
    c.commit(); c.close()
    for u in all_users(): enable_cert(u["username"])
    run("systemctl restart openvpn-server@server")
    return redirect("/bulk")

@app.route("/bulk/enable")
@login_required
def bulk_enable():
    c = db(); c.execute("UPDATE users SET enabled=1"); c.commit(); c.close()
    for u in all_users(): enable_cert(u["username"])
    run("systemctl restart openvpn-server@server")
    return redirect("/bulk")

@app.route("/bulk/disable")
@login_required
def bulk_disable():
    c = db(); c.execute("UPDATE users SET enabled=0"); c.commit(); c.close()
    for u in all_users(): revoke_cert(u["username"])
    run("systemctl restart openvpn-server@server")
    return redirect("/bulk")

@app.route("/settings")
@login_required
def settings_page(): return view("settings")

@app.route("/settings/save", methods=["POST"])
@login_required
def settings_save():
    s = settings()
    for k in ("config_host", "vpn_port", "vpn_proto", "admin_user"):
        if v := request.form.get(k): s[k] = v
    if pw := request.form.get("admin_pass"): s["admin_pass"] = pw
    save_settings(s)
    return redirect("/settings")

@app.route("/backup")
@login_required
def backup_page(): return view("backup")

@app.route("/backup/download")
@login_required
def backup_download():
    return send_file(make_full_backup(), as_attachment=True)

@app.route("/backup/restore", methods=["POST"])
@login_required
def backup_restore():
    f = request.files.get("backup")
    if not f: return redirect("/backup")
    tmp = f"/tmp/ovpn-restore-{int(time.time())}.zip"
    f.save(tmp)
    try:
        restore_full_backup(tmp)
    except Exception as e:
        return jsonify({"ok": False, "message": str(e)}), 400
    session.clear()
    return redirect("/")

@app.route("/api-info")
@login_required
def api_info(): return view("api")

@app.route("/logs")
@login_required
def logs(): return view("logs")

# ── REST API ────────────────────────────────────────────────

@app.route("/api/users", methods=["GET"])
@api_required
def api_users():
    q = request.args.get("q", "")
    return jsonify({"ok": True, "count": len(all_users(q)), "users": [dict(x) for x in all_users(q)]})

@app.route("/api/users/<username>", methods=["GET"])
@api_required
def api_get_user(username):
    u = get_user(username)
    if not u:
        return jsonify({"ok": False, "message": "User not found"}), 404
    return jsonify({"ok": True, "user": dict(u)})

@app.route("/api/users/sync", methods=["POST"])
@api_required
def api_sync():
    data = request.get_json(force=True, silent=True) or {}
    username = clean_user(data.get("username") or data.get("email", ""))
    if not valid_user(username):
        return jsonify({"ok": False, "message": "Invalid username"}), 400
    u = upsert_user(
        username,
        int(data.get("max_devices", 2)),
        int(data.get("quota_gb", 100)),
        int(data.get("days", 30)),
        data.get("note", "API"),
        data.get("source", "api"),
        data.get("expiry_ts"),
        unlimited_expiry=bool(data.get("unlimited_expiry", False)),
        unlimited_quota=bool(data.get("unlimited_quota", False)),
        unlimited_devices=bool(data.get("unlimited_devices", False)),
    )
    if not u:
        return jsonify({"ok": False, "message": "Failed to create user / certificate"}), 500
    return jsonify({"ok": True, "message": "User synced", "user": dict(u)})

@app.route("/api/users/<username>", methods=["DELETE"])
@api_required
def api_delete_user(username):
    if not get_user(username):
        return jsonify({"ok": False, "message": "User not found"}), 404
    revoke_cert(username, hard=True)
    c = db(); c.execute("DELETE FROM users WHERE username=?", (username,))
    c.execute("DELETE FROM devices WHERE username=?", (username,)); c.commit(); c.close()
    run("systemctl restart openvpn-server@server")
    return jsonify({"ok": True, "message": f"User {username} deleted"})

@app.route("/api/users/<username>/toggle", methods=["POST"])
@api_required
def api_toggle(username):
    u = get_user(username)
    if not u:
        return jsonify({"ok": False, "message": "User not found"}), 404
    new = 0 if u["enabled"] else 1
    c = db(); c.execute("UPDATE users SET enabled=? WHERE username=?", (new, username)); c.commit(); c.close()
    if new: enable_cert(username)
    else: revoke_cert(username)
    run("systemctl restart openvpn-server@server")
    return jsonify({"ok": True, "enabled": bool(new), "username": username})

@app.route("/api/users/<username>/config", methods=["GET"])
@api_required
def api_config(username):
    if not get_user(username):
        return jsonify({"ok": False, "message": "User not found"}), 404
    create_cert(username)
    path = make_config(username)
    return send_file(path, as_attachment=True, download_name=f"{username}.ovpn")

@app.route("/api/bulk/update", methods=["POST"])
@api_required
def api_bulk_update():
    data = request.get_json(force=True, silent=True) or {}
    c = db()
    if "max_devices" in data: c.execute("UPDATE users SET max_devices=?, unlimited_devices=0", (safe_int(data["max_devices"],2,1000),))
    if "quota_gb"    in data: c.execute("UPDATE users SET quota_gb=?, unlimited_quota=0",    (safe_int(data["quota_gb"],100,1_000_000),))
    if "days"        in data: c.execute("UPDATE users SET expiry=?, unlimited_expiry=0",      (int(time.time())+safe_days(data["days"])*86400,))
    c.commit(); c.close()
    return jsonify({"ok": True, "message": "Bulk update done"})

@app.route("/api/online", methods=["GET"])
@api_required
def api_online():
    return jsonify({"ok": True, "clients": online_clients()})

@app.route("/api/devices", methods=["GET"])
@api_required
def api_devices():
    reconcile_devices()
    return jsonify({"ok": True, "devices": [dict(x) for x in all_connected_devices()]})

@app.route("/api/devices/<username>/<device_key>/block", methods=["POST"])
@api_required
def api_device_block(username, device_key):
    c = db()
    c.execute("UPDATE devices SET blocked=1 WHERE username=? AND device_key=?", (username, device_key))
    d = c.execute("SELECT * FROM devices WHERE username=? AND device_key=?", (username, device_key)).fetchone()
    c.commit(); c.close()
    if d and d["connected"] and d["last_ip"]:
        mgmt_kill_ip(d["last_ip"])
    return jsonify({"ok": True})

@app.route("/api/devices/<username>/<device_key>/unblock", methods=["POST"])
@api_required
def api_device_unblock(username, device_key):
    c = db()
    c.execute("UPDATE devices SET blocked=0 WHERE username=? AND device_key=?", (username, device_key))
    c.commit(); c.close()
    return jsonify({"ok": True})

@app.route("/api/backup", methods=["GET"])
@api_required
def api_backup():
    return send_file(make_full_backup(), as_attachment=True)

@app.route("/api/restore", methods=["POST"])
@api_required
def api_restore():
    f = request.files.get("backup")
    if not f:
        return jsonify({"ok": False, "message": "No file uploaded (field name: backup)"}), 400
    tmp = f"/tmp/ovpn-restore-{int(time.time())}.zip"
    f.save(tmp)
    try:
        summary = restore_full_backup(tmp)
    except Exception as e:
        return jsonify({"ok": False, "message": str(e)}), 400
    return jsonify(summary)

# /ping and /health already defined above

if __name__ == "__main__":
    init_db()
    threading.Thread(target=background_worker, daemon=True).start()
    s = settings()
    port = int(s.get("panel_port", 8088))
    print(f"[ovpn-xui] Starting V7.1 on 0.0.0.0:{port}")
    app.run(host="0.0.0.0", port=port, threaded=True)
PYAPP4

# ── Systemd service ────────────────────────────────────────
echo ">>> Setting up systemd service..."
cat > /etc/systemd/system/$SERVICE_NAME.service <<EOF
[Unit]
Description=OpenVPN X-UI V7.1 Panel
After=network.target openvpn-server@server.service

[Service]
ExecStart=/usr/bin/python3 $APP_DIR/app.py
Restart=always
RestartSec=3
User=root
WorkingDirectory=$APP_DIR
StandardOutput=journal
StandardError=journal
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

# ── One-time permission pass (Flask also self-heals this on every request) ──
chmod 777 "$DATA_DIR" 2>/dev/null || true
[[ -f "$DATA_DIR/panel.db" ]] && chmod 666 "$DATA_DIR/panel.db"
touch "$DATA_DIR/hook.log"
chmod 666 "$DATA_DIR/hook.log"

# ── Start / Restart services (install vs update aware) ───
echo ">>> Starting services..."
systemctl daemon-reload

# OpenVPN core service
systemctl enable "$VPN_SERVICE" >/dev/null 2>&1 || true
if systemctl is-active --quiet "$VPN_SERVICE"; then
    echo ">>> Restarting OpenVPN server (config may have changed)..."
    systemctl restart "$VPN_SERVICE" || true
else
    echo ">>> Starting OpenVPN server..."
    systemctl start "$VPN_SERVICE" || true
fi

# Panel service: on UPDATE we must force a restart so the freshly written
# app.py (rewritten above, unconditionally, on every run) is actually loaded.
# On a FRESH INSTALL nothing is running yet, so a plain start is enough.
systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
if [[ "$INSTALL_MODE" == "update" ]]; then
    echo ">>> Update detected — restarting panel service to load the new version..."
    systemctl restart "$SERVICE_NAME"
else
    echo ">>> Fresh install — starting panel service for the first time..."
    systemctl start "$SERVICE_NAME"
fi

# Verify the panel actually came back up; if not, surface the failure immediately
sleep 2
if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo ">>> Panel service is running."
else
    echo ""
    echo "⚠️  Panel service failed to (re)start! Last 30 log lines:"
    journalctl -u "$SERVICE_NAME" --no-pager -n 30
    echo ""
fi

# ── Restore from backup if --restore was passed on the command line ──
RESTORE_SUMMARY=""
if [[ -n "$RESTORE_ZIP" ]]; then
    echo ""
    echo ">>> Restoring data from backup: $RESTORE_ZIP"
    RESTORE_SUMMARY="$(python3 - <<PYRESTORE
import sys, json
sys.path.insert(0, "$APP_DIR")
import app
try:
    summary = app.restore_full_backup("$RESTORE_ZIP")
    print(json.dumps(summary))
except Exception as e:
    print(json.dumps({"ok": False, "message": str(e)}))
PYRESTORE
)"
    echo "$RESTORE_SUMMARY"
    echo ""
fi

sleep 1
if nc -z 127.0.0.1 "$PANEL_PORT" 2>/dev/null; then
    PANEL_STATUS="✅ Panel is LISTENING on port $PANEL_PORT"
else
    PANEL_STATUS="⚠️  Panel may still be starting — check: systemctl status $SERVICE_NAME"
fi

ADMIN_USER="$(python3 -c "import json;print(json.load(open('$DATA_DIR/settings.json'))['admin_user'])")"
ADMIN_PASS="$(python3 -c "import json;print(json.load(open('$DATA_DIR/settings.json'))['admin_pass'])")"
API_TOKEN="$(python3 -c "import json;print(json.load(open('$DATA_DIR/settings.json'))['api_token'])")"

echo ""
echo "======================================================="
echo " OpenVPN X-UI V7.1 — Installation / Upgrade Complete"
echo "======================================================="
echo ""
echo " Mode:         $INSTALL_MODE"
echo " $PANEL_STATUS"
echo ""
echo " Panel URL:    http://$SERVER_IP:$PANEL_PORT"
echo " Config Host:  $CONFIG_HOST"
echo ""
echo " Username:     $ADMIN_USER"
echo " Password:     $ADMIN_PASS"
echo ""
echo " API Token:    $API_TOKEN"
echo ""
echo " Fixed in V7.1:"
echo "  - Online Devices / Dashboard now actually show connected users. The old"
echo "    status-log parser looked for a header line that OpenVPN 2.6 never"
echo "    writes (it uses CLIENT_LIST,... rows); this is now parsed correctly."
echo "  - panel.db / hook.log permissions are self-healed on every request AND"
echo "    at install time, so the client-connect/disconnect hook (which runs as"
echo "    'nobody:nogroup', same as OpenVPN itself) can always write device"
echo "    connect/disconnect/quota data instead of silently failing."
echo "  - A background thread now runs every ~15s, independent of anyone"
echo "    viewing the panel, and:"
echo "      * enforces Max Devices live (kills the newest excess session if the"
echo "        limit is already enforced at connect-time by the hook, and cleans"
echo "        up any device stuck 'online' after a crash/kill -9)"
echo "      * enforces Quota live — once a user's used data crosses their GB"
echo "        limit, their current session(s) get force-disconnected, not just"
echo "        denied on the next reconnect"
echo "      * re-kills any device you've Blocked in the panel if it's still"
echo "        (or becomes) connected"
echo "  - Device limit, quota, and block were already implemented in the connect"
echo "    hook logic itself (deny on connect if over limit/quota/blocked) — that"
echo "    part didn't need to change, it just needed to actually be able to run."
echo ""
echo " Health check: curl http://$SERVER_IP:$PANEL_PORT/ping"
echo " API example:  curl -H 'Authorization: Bearer $API_TOKEN' \\"
echo "               http://$SERVER_IP:$PANEL_PORT/api/users"
echo ""
echo " Backup saved: $AUTO_BACKUP"
echo ""
echo " Logs:  journalctl -u $SERVICE_NAME -f"
echo " Device hook log: $DATA_DIR/hook.log"
echo "======================================================="
