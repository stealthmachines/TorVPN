✅ Fully Automated Installation
✅ Tor Hidden Service for Proxmox
✅ NGINX Reverse Proxy with Authentication
✅ WebRTC VPN with QR Authentication & MFA
✅ Persistent Systemd Services for Tunnel Maintenance & VPN

Installation Instructions
Create an LXC container in Proxmox

Template: Debian 12 or Ubuntu 22.04
CPU: 1-2 cores
RAM: 1GB+
Storage: 5GB+
Network: Attach to vmbr0 or your LAN bridge
Run the Script in the LXC Container

```
apt update && apt install -y curl
curl -fsSL https://github.com/stealthmachines/TorVPN/blob/main/proxmox-vpn-setup.sh | bash
```

Access Proxmox Securely

Tor Browser: http://your-onion-address.onion
WebRTC VPN: Scan the QR code and connect
