#!/bin/bash
set -euo pipefail

# Update and install dependencies
apt update && apt upgrade -y
apt install -y apt-transport-https ca-certificates curl software-properties-common net-tools ufw

# Install or update Docker
if ! command -v docker &> /dev/null; then
  curl -fsSL https://get.docker.com | bash
else
  apt install -y docker-ce docker-ce-cli containerd.io
fi
systemctl enable --now docker

# Configure firewall
ufw allow 443/tcp
ufw allow 1024:65535/tcp
ufw allow 1024:65535/udp
ufw reload

# Create directories and certificates
SHADOWBOX_DIR="/opt/outline"
STATE_DIR="${SHADOWBOX_DIR}/persisted-state"
mkdir -p "${STATE_DIR}"
openssl req -x509 -nodes -days 36500 -newkey rsa:4096 \
  -subj "/CN=$(curl -s https://icanhazip.com/)" \
  -keyout "${STATE_DIR}/shadowbox-selfsigned.key" -out "${STATE_DIR}/shadowbox-selfsigned.crt"

# Generate API key prefix
SB_API_PREFIX=$(head -c 16 /dev/urandom | base64 | tr '/+' '_-' | tr -d '=')

# Write server config
cat <<EOF > "${STATE_DIR}/shadowbox_server_config.json"
{
  "portForNewAccessKeys": 443,
  "hostname": "$(curl -s https://icanhazip.com/)",
  "name": "Outline Server"
}
EOF

# Start Outline
docker run -d --name shadowbox --restart always \
  --net host \
  -v "${STATE_DIR}:${STATE_DIR}" \
  -e "SB_STATE_DIR=${STATE_DIR}" \
  -e "SB_API_PORT=443" \
  -e "SB_API_PREFIX=${SB_API_PREFIX}" \
  -e "SB_CERTIFICATE_FILE=${STATE_DIR}/shadowbox-selfsigned.crt" \
  -e "SB_PRIVATE_KEY_FILE=${STATE_DIR}/shadowbox-selfsigned.key" \
  quay.io/outline/shadowbox:stable

# Output API URL
echo "Outline Server API URL:"
echo "https://$(curl -s https://icanhazip.com/):443/${SB_API_PREFIX}"
echo "Cert SHA256: $(openssl x509 -in ${STATE_DIR}/shadowbox-selfsigned.crt -noout -sha256 -fingerprint | cut -d'=' -f2 | tr -d ':')"
