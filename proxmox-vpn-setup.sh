#!/bin/bash

# Update and install required packages
apt update && apt install -y tor nginx apache2-utils nodejs npm

# Configure Tor Hidden Service
cat <<EOF > /etc/tor/torrc
HiddenServiceDir /var/lib/tor/proxmox_hidden_service/
HiddenServicePort 80 127.0.0.1:8080
HiddenServiceAuthorizeClient stealth auth-client
EOF

systemctl restart tor && systemctl enable tor

# Fetch the .onion address
sleep 5  # Allow Tor to generate address
ONION_ADDR=$(cat /var/lib/tor/proxmox_hidden_service/hostname)
echo "Tor Hidden Service Address: $ONION_ADDR"

# Set up NGINX Reverse Proxy with Authentication
htpasswd -cb /etc/nginx/.htpasswd admin password123  # Change credentials

cat <<EOF > /etc/nginx/sites-available/proxmox
server {
    listen 8080;
    server_name _;

    auth_basic "Restricted";
    auth_basic_user_file /etc/nginx/.htpasswd;

    location / {
        proxy_pass http://127.0.0.1:8006;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -s /etc/nginx/sites-available/proxmox /etc/nginx/sites-enabled/
systemctl restart nginx && systemctl enable nginx

# Create a systemd service to maintain the Tor tunnel
cat <<EOF > /etc/systemd/system/tor-tunnel.service
[Unit]
Description=Tor Tunnel Maintainer
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/tor
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable tor-tunnel.service && systemctl start tor-tunnel.service

# Set up WebRTC VPN
mkdir -p /opt/webrtc-vpn

cat <<EOF > /opt/webrtc-vpn/server.js
import { createServer } from 'http';
import { Server } from 'socket.io';
import { generateQRCode, verifyQRCode } from './qr_auth';
import { setupWebRTC } from './webrtc_vpn';
import { authenticateUser } from './mfa_auth';

const httpServer = createServer();
const io = new Server(httpServer, { cors: { origin: '*' } });

const peers = {};

io.on('connection', (socket) => {
    console.log(\`New connection: \${socket.id}\`);

    socket.on('request-qr', async (data, callback) => {
        const qrCode = await generateQRCode(data.userId);
        callback(qrCode);
    });

    socket.on('verify-qr', async (token, callback) => {
        const isValid = await verifyQRCode(token);
        callback(isValid);
    });

    socket.on('authenticate', async (data, callback) => {
        const isAuthenticated = await authenticateUser(data.userId, data.mfaCode);
        callback(isAuthenticated);
    });

    socket.on('webrtc-signal', (data) => {
        if (peers[data.target]) {
            io.to(data.target).emit('webrtc-signal', { from: socket.id, signal: data.signal });
        }
    });

    socket.on('disconnect', () => {
        delete peers[socket.id];
        console.log(\`Disconnected: \${socket.id}\`);
    });
});

httpServer.listen(3000, () => {
    console.log('Self-hosted WebRTC VPN server running on port 3000');
});
EOF

# Install WebRTC dependencies
cd /opt/webrtc-vpn
npm init -y
npm install socket.io qr-image express

# Create a systemd service for the WebRTC VPN
cat <<EOF > /etc/systemd/system/webrtc-vpn.service
[Unit]
Description=WebRTC VPN Signaling Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/node /opt/webrtc-vpn/server.js
Restart=always
RestartSec=10s
User=root
WorkingDirectory=/opt/webrtc-vpn

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable webrtc-vpn.service && systemctl start webrtc-vpn.service

# Auto-start on Proxmox Boot
pct set \$(hostname) -onboot 1

# Output Final Instructions
echo "✅ Setup Complete! Access Proxmox via: http://$ONION_ADDR (Tor required)"
echo "✅ WebRTC VPN Server running on port 3000"
