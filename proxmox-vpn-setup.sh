#!/bin/bash

# Check if the script is run with root privileges
if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

# Update system and install necessary packages
apt update && apt install -y tor nginx apache2-utils nodejs npm pve-manager pve-cluster qemu-server proxmox-ve postfix open-iscsi

# Configuration parameters for LXC
VMID=100
OSTEMPLATE="local:vztmpl/ubuntu-20.04-standard_20.04-1_amd64.tar.gz"  # Adjust based on available templates
STORAGE="local"
HOSTNAME="mylxc"
MEMORY=1024
CPUS=1
NET0="name=eth0,bridge=vmbr0,ip=dhcp"

# Create LXC container with network configuration
echo "Creating LXC container..."
pct create $VMID $OSTEMPLATE --storage $STORAGE --hostname $HOSTNAME --memory $MEMORY --cpus $CPUS --net0 $NET0

# Start the LXC container
echo "Starting LXC container..."
pct start $VMID

# Wait for LXC to start
sleep 10  # Give some time for the container to fully initialize

# Configure Tor Hidden Service
cat <<EOF > /etc/tor/torrc
HiddenServiceDir /var/lib/tor/proxmox_hidden_service/
HiddenServicePort 80 127.0.0.1:8080
EOF

systemctl restart tor && systemctl enable tor

# Fetch the .onion address
sleep 5  # Allow Tor to generate address
ONION_ADDR=$(cat /var/lib/tor/proxmox_hidden_service/hostname)
echo "Tor Hidden Service Address: $ONION_ADDR"

# Set up WebRTC P2P over Tor
mkdir -p /opt/webrtc-tor

cat <<EOF > /opt/webrtc-tor/server.js
const { createServer } = require('http');
const { Server } = require('socket.io');
const QRCode = require('qrcode');
const speakeasy = require('speakeasy');
const crypto = require('crypto');

const httpServer = createServer();
const io = new Server(httpServer, { cors: { origin: '*' } });

let users = {};
let peers = {};

io.on('connection', (socket) => {
    console.log(`New connection: ${socket.id}`);

    socket.on('register-2fa', (username, callback) => {
        if (!users[username]) {
            const secret = speakeasy.generateSecret();
            const qrCode = `otpauth://totp/${username}?secret=${secret.base32}&issuer=WebRTCTorVPN&webRTCUrl=https://${ONION_ADDR}:8080/webrtc`;
            
            QRCode.toDataURL(qrCode, async (err, qrUrl) => {
                if (err) return callback({ error: 'Failed to generate QR code' });

                users[username] = { 
                    secret: secret.base32, 
                    connectedSocket: socket.id
                };

                peers[socket.id] = username; // Assuming username is unique for room ID

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

    socket.on('webrtc-signal', (data) => {
        // Since we're not using rooms, just broadcast to all connected clients
        socket.broadcast.emit('webrtc-signal', { from: socket.id, signal: data.signal });
    });

    socket.on('disconnect', () => {
        for (const [username, data] of Object.entries(users)) {
            if (data.connectedSocket === socket.id) {
                delete users[username];
                break;
            }
        }
        if (peers[socket.id]) {
            delete peers[socket.id];
        }
        console.log(`Disconnected: ${socket.id}`);
    });
});

httpServer.listen(8080, () => {
    console.log('Self-hosted WebRTC over Tor server with 2FA running on port 8080');
});
EOF

# Install WebRTC and 2FA dependencies
cd /opt/webrtc-tor
npm init -y
npm install socket.io qrcode speakeasy

# Create a systemd service for the WebRTC over Tor
cat <<EOF > /etc/systemd/system/webrtc-tor.service
[Unit]
Description=WebRTC over Tor Signaling Server with 2FA
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/node /opt/webrtc-tor/server.js
Restart=always
RestartSec=10s
User=root
WorkingDirectory=/opt/webrtc-tor

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable webrtc-tor.service && systemctl start webrtc-tor.service

# Auto-start on Proxmox Boot
pct set $VMID -onboot 1

# Output Final Instructions
echo "✅ Setup Complete! Access Proxmox via: http://$ONION_ADDR (Tor required)"
echo "✅ WebRTC over Tor Server with 2FA running on port 8080"
echo "✅ LXC Container with ID $VMID created, started, and configured to auto-start"
echo "Note: Clients need to scan the QR code for setup and connection."

# Host the WebRTC client page
mkdir -p /var/www/html/webrtc
cat <<EOF > /var/www/html/webrtc/index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>WebRTC over Tor</title>
</head>
<body>
    <h1>WebRTC over Tor Connection</h1>
    <div id="status">Status: Waiting...</div>
    <button id="startButton">Start Connection</button>

    <script>
    const startButton = document.getElementById('startButton');
    const statusDiv = document.getElementById('status');

    let peerConnection;
    let localStream;

    const configuration = {
        iceServers: [
            { urls: "stun:stun.l.google.com:19302" },
        ]
    };

    function createPeerConnection() {
        peerConnection = new RTCPeerConnection(configuration);

        peerConnection.onicecandidate = (event) => {
            if (event.candidate) {
                socket.emit('webrtc-signal', {
                    type: 'candidate',
                    label: event.candidate.sdpMLineIndex,
                    id: event.candidate.sdpMid,
                    candidate: event.candidate.candidate
                });
            }
        };

        peerConnection.ontrack = (event) => {
            statusDiv.innerHTML = 'Connected and receiving stream.';
        };

        peerConnection.oniceconnectionstatechange = () => {
            statusDiv.innerHTML = `Connection state: ${peerConnection.iceConnectionState}`;
        };

        if (localStream) {
            localStream.getTracks().forEach(track => peerConnection.addTrack(track, localStream));
        }
    }

    const socket = io();

    socket.on('connect', () => {
        statusDiv.innerHTML = 'Connected to signaling server.';
        createPeerConnection();
        startButton.addEventListener('click', startWebRTC);
    });

    socket.on('webrtc-signal', (data) => {
        if (data.from !== socket.id) {
            if (data.signal.type === 'offer') {
                peerConnection.setRemoteDescription(new RTCSessionDescription(data.signal))
                    .then(() => peerConnection.createAnswer())
                    .then(answer => peerConnection.setLocalDescription(answer))
                    .then(() => {
                        socket.emit('webrtc-signal', {
                            type: 'answer',
                            sdp: peerConnection.localDescription.sdp
                        });
                    });
            } else if (data.signal.type === 'answer') {
                peerConnection.setRemoteDescription(new RTCSessionDescription(data.signal));
            } else if (data.signal.type === 'candidate') {
                peerConnection.addIceCandidate(new RTCIceCandidate(data.signal));
            }
        }
    });

    function startWebRTC() {
        startButton.disabled = true;
        navigator.mediaDevices.getUserMedia({ video: true, audio: true })
            .then(stream => {
                localStream = stream;
                createPeerConnection();
                peerConnection.createOffer()
                    .then(offer => peerConnection.setLocalDescription(offer))
                    .then(() => {
                        socket.emit('webrtc-signal', {
                            type: 'offer',
                            sdp: peerConnection.localDescription.sdp
                        });
                    });
            })
            .catch(error => {
                statusDiv.innerHTML = `Error accessing media devices: ${error.message}`;
            });
    }
    </script>
    <script src="/socket.io/socket.io.js"></script>
</body>
</html>
EOF

# Adjust NGINX to serve the WebRTC client page
cat <<EOF > /etc/nginx/sites-available/default
server {
    listen 8080;
    server_name localhost;

    location / {
        root /var/www/html;
        index index.html;
    }

    location /socket.io {
        proxy_pass http://localhost:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOF

ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/
systemctl restart nginx

echo "WebRTC client page hosted at /webrtc/"
