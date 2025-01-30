#!/bin/bash

# Ensure script runs as root
if [[ $EUID -ne 0 ]]; then
    echo "❌ Please run as root" 
    exit 1
fi

echo "🚀 Updating system and installing dependencies..."
apt update && apt install -y \
    tor nginx apache2-utils nodejs npm curl gnupg lsb-release ca-certificates \
    software-properties-common

# Add NodeSource for Node.js (skip redundant install later)
curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
apt update && apt install -y nodejs

# Verify installation
if ! command -v node &> /dev/null || ! command -v npm &> /dev/null; then
    echo "❌ Node.js installation failed!" 
    exit 1
fi

echo "✅ Node.js installed successfully"

# LXC Configuration
VMID=100
OSTEMPLATE="local:vztmpl/debian-12.9.0-amd64-netinst.iso"
STORAGE="local"
HOSTNAME="mylxc"
MEMORY=1024
CPUS=1
NET0="name=eth0,bridge=vmbr0,ip=dhcp"

echo "🛠 Creating LXC container..."
pct create $VMID $OSTEMPLATE --storage $STORAGE --hostname $HOSTNAME --memory $MEMORY --cpus $CPUS --net0 $NET0

if [ $? -ne 0 ]; then
    echo "❌ Failed to create LXC container"
    exit 1
fi

echo "✅ LXC container created successfully"

echo "🔄 Starting LXC container..."
pct start $VMID && sleep 10

# Configure Tor Hidden Service
echo "🛡 Configuring Tor hidden service..."
mkdir -p /var/lib/tor/proxmox_hidden_service
cat <<EOF > /etc/tor/torrc
HiddenServiceDir /var/lib/tor/proxmox_hidden_service/
HiddenServicePort 80 127.0.0.1:8080
Sandbox 1
EOF

systemctl restart tor && systemctl enable tor

# Wait for Tor to generate .onion address
sleep 5
ONION_ADDR=$(cat /var/lib/tor/proxmox_hidden_service/hostname 2>/dev/null)

if [[ -z "$ONION_ADDR" ]]; then
    echo "❌ Tor Hidden Service address generation failed"
    exit 1
fi

echo "✅ Tor Hidden Service Address: $ONION_ADDR"

# Set up WebRTC P2P over Tor
mkdir -p /opt/webrtc-tor
cat <<EOF > /opt/webrtc-tor/server.js
const { createServer } = require('http');
const { Server } = require('socket.io');
const QRCode = require('qrcode');
const speakeasy = require('speakeasy');

const httpServer = createServer();
const io = new Server(httpServer, { cors: { origin: '*' } });

let users = {};

io.on('connection', (socket) => {
    console.log(\`New connection: \${socket.id}\`);

    socket.on('register-2fa', (username, callback) => {
        if (!users[username]) {
            const secret = speakeasy.generateSecret();
            const qrCode = \`otpauth://totp/\${username}?secret=\${secret.base32}&issuer=WebRTCTorVPN\`;
            
            QRCode.toDataURL(qrCode, (err, qrUrl) => {
                if (err) return callback({ error: 'Failed to generate QR code' });

                users[username] = { secret: secret.base32 };
                callback({ qr: qrUrl });
            });
        } else {
            callback({ error: 'Username already exists' });
        }
    });

    socket.on('verify-2fa', (username, token, callback) => {
        if (users[username]) {
            const verified = speakeasy.totp.verify({
                secret: users[username].secret,
                encoding: 'base32',
                token: token
            });
            callback({ success: verified });
        } else {
            callback({ error: 'User not found' });
        }
    });

    socket.on('disconnect', () => {
        console.log(\`Disconnected: \${socket.id}\`);
    });
});

httpServer.listen(8080, () => console.log('WebRTC Tor server running on 8080'));
EOF

# Install WebRTC dependencies
cd /opt/webrtc-tor
npm init -y
npm install socket.io qrcode speakeasy

# Create systemd service
cat <<EOF > /etc/systemd/system/webrtc-tor.service
[Unit]
Description=WebRTC over Tor Server
After=network.target

[Service]
Type=simple
User=nobody
ExecStart=/usr/bin/node /opt/webrtc-tor/server.js
Restart=on-failure
WorkingDirectory=/opt/webrtc-tor

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable webrtc-tor && systemctl start webrtc-tor

# Configure NGINX for WebRTC
cat <<EOF > /etc/nginx/sites-available/webrtc
server {
    listen 8080;
    server_name localhost;

    location / {
        root /var/www/html/webrtc;
        index index.html;
    }

    location /socket.io/ {
        proxy_pass http://localhost:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOF

ln -sf /etc/nginx/sites-available/webrtc /etc/nginx/sites-enabled/
systemctl restart nginx

# Auto-start LXC on Proxmox boot
pct set $VMID -onboot 1

# Output success messages
echo "✅ Setup Complete!"
echo "🌍 Access Proxmox via Tor: http://$ONION_ADDR"
echo "🎥 WebRTC over Tor with 2FA running on port 8080"
