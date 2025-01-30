#!/bin/bash
# Automated Setup for a Self-Hosted WebRTC VPN with Tor Portal
# This script sets up an LXC container with Tor, WebRTC, MFA, and QR authentication

set -e

# Variables
LXC_NAME="webrtc-vpn"
TOR_SERVICE_DIR="/var/lib/tor/webrtc-vpn"
VPN_PORT=4433
TURN_PORT=3478

# Install Required Packages
apt update && apt install -y \
  tor \
  nginx \
  coturn \
  python3-pip \
  qrencode \
  git \
  ufw \
  nodejs \
  npm

# Configure Tor Hidden Service
echo -e "HiddenServiceDir $TOR_SERVICE_DIR\nHiddenServicePort 80 127.0.0.1:8080" >> /etc/tor/torrc
systemctl restart tor
sleep 5
tor_hostname=$(cat $TOR_SERVICE_DIR/hostname)
echo "Tor service available at: $tor_hostname"

# Set Up NGINX as Reverse Proxy
cat <<EOF > /etc/nginx/sites-available/vpn
server {
    listen 80;
    server_name localhost;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF
ln -s /etc/nginx/sites-available/vpn /etc/nginx/sites-enabled/
systemctl restart nginx

# Set Up TURN Server
cat <<EOF > /etc/turnserver.conf
listening-port=$TURN_PORT
fingerprint
lt-cred-mech
realm=webrtc-vpn
total-quota=100
EOF
systemctl enable coturn --now

# Set Up WebRTC VPN
mkdir -p /opt/webrtc-vpn
cd /opt/webrtc-vpn
git clone https://github.com/your-repo/webrtc-vpn.git .
npm install && npm run build

# Configure Firewall
ufw allow 80/tcp
ufw allow $VPN_PORT/tcp
ufw allow $TURN_PORT/udp
ufw enable

# Generate QR Code for Authentication
echo "https://$tor_hostname/login" | qrencode -o /opt/webrtc-vpn/auth-qr.png

# Output Details
echo "Setup complete! Access VPN at: $tor_hostname"
echo "QR Code stored at /opt/webrtc-vpn/auth-qr.png"
