# OpenVPN X-UI

OpenVPN X-UI is a modern, lightweight, and fully automated OpenVPN management panel designed to simplify VPN deployment and administration on Linux servers.

The project provides a complete web-based dashboard for managing OpenVPN users, certificates, connected devices, bandwidth quotas, backups, and server configuration while offering a powerful REST API for automation and third-party integrations.

Unlike traditional OpenVPN deployments that require manual certificate generation and command-line management, OpenVPN X-UI automates the entire VPN lifecycle through a clean and intuitive interface.

---
<img width="1778" height="885" alt="OpenVPN X-UI" src="https://github.com/miladmim/OpenVPN-X-UI/blob/main/646546.png?raw=true" />

## Features

### 🚀 One-Command Installation

- Automatic dependency installation
- OpenVPN server configuration
- Easy-RSA PKI initialization
- Certificate Authority generation
- Server certificate creation
- TLS-Crypt configuration
- Firewall configuration
- IP forwarding
- NAT configuration
- Systemd service setup

---

### 👥 User Management

- Create and delete VPN users
- Automatic client certificate generation
- Automatic `.ovpn` configuration generation
- Enable or disable users
- Expiration management
- Unlimited or fixed expiration
- Bandwidth quota management
- Unlimited quota support
- Device limit management
- Unlimited device mode
- User notes
- User search
- Bulk user operations

---

### 📱 Device Management

Advanced device tracking system including:

- Real-time connected devices
- Device fingerprinting
- Device blocking
- Device limits
- Platform detection
- IP tracking
- Connection history
- First seen / Last seen
- Data usage per device
- Automatic session synchronization
- Automatic cleanup of inactive sessions

---

### 📊 Live Session Monitoring

Monitor every connected VPN client in real time.

Features include:

- Online users
- Connected devices
- Real IP address
- Virtual IP address
- Connection duration
- Upload usage
- Download usage
- Live session termination
- OpenVPN Management Interface integration

---

### ⚡ Automatic Quota Enforcement

The panel continuously monitors active users and automatically:

- Disconnects users exceeding their bandwidth quota
- Blocks expired accounts
- Enforces device limits
- Prevents unauthorized devices
- Synchronizes online status

---

### 🔌 REST API

Built-in REST API for automation and external integrations.

API capabilities include:

- Create users
- Delete users
- Renew users
- Enable or disable users
- Download client configurations
- Retrieve online users
- System statistics
- Backup management

Authentication is secured using Bearer Tokens.

---

### 💾 Backup & Restore

Professional backup system including:

- Panel configuration
- SQLite database
- User accounts
- Device database
- PKI
- Certificates
- Private keys
- OpenVPN configuration
- Client configuration files
- Automatic metadata
- One-click restore

---

### 🔒 Security

- TLS-Crypt
- AES-256-GCM encryption
- SHA-256 authentication
- Certificate Revocation List (CRL)
- Certificate revocation
- Automatic session termination
- Device fingerprint verification
- Token-based REST API
- Secure random credential generation

---

### 📈 Dashboard

Modern responsive dashboard featuring:

- VPN server status
- User statistics
- Online users
- Device statistics
- User search
- User management
- Backup management
- API documentation
- Settings management
- System health monitoring

---

### ⚙️ Automatic Installer

The installer automatically configures:

- OpenVPN
- Easy-RSA
- PKI
- Certificates
- Firewall
- NAT
- IP forwarding
- Flask web panel
- System services
- Connection hooks
- OpenVPN Management Interface

No manual configuration is required.

---

## Technologies

- Python
- Flask
- OpenVPN
- Easy-RSA
- SQLite
- Bash
- HTML
- CSS
- REST API
- Systemd
- iptables

---

## Requirements

- Ubuntu 20.04 or later
- Debian 11 or later
- Root access
- Python 3
- OpenVPN

---

## Highlights

- Fully automated installation
- Lightweight architecture
- Modern responsive interface
- REST API support
- Live device monitoring
- Automatic certificate management
- Automatic backup and restore
- Device limitation
- User quota management
- Expiration control
- Production-ready
- Easy to maintain
- Suitable for personal and commercial VPN deployments

---

## License

This project is intended for educational, research, and production environments. Please ensure compliance with your local regulations when deploying VPN services.
