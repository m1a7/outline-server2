#!/bin/bash

# ===========================
# VPN Installation with Obfuscation
# ===========================
set -euo pipefail
trap "echo -e '\e[31mAn error occurred. Exiting.\e[0m'" ERR

# Helper functions
log_info() {
  echo -e "\e[32m[INFO]\e[0m $1"
}

log_warn() {
  echo -e "\e[33m[WARN]\e[0m $1"
}

log_error() {
  echo -e "\e[31m[ERROR]\e[0m $1"
}

# Pre-flight checks
log_info "Checking for root permissions..."
if [[ "$EUID" -ne 0 ]]; then
  log_error "This script must be run as root. Use sudo."
  exit 1
fi

log_info "Updating system packages..."
apt-get update -qq && apt-get upgrade -y -qq

# Install required dependencies
log_info "Installing dependencies..."
apt-get install -y -qq apt-transport-https ca-certificates curl software-properties-common net-tools ufw docker.io

# Docker setup
log_info "Setting up Docker..."
systemctl enable --now docker
if ! docker --version >/dev/null 2>&1; then
  log_error "Docker installation failed."
  exit 1
fi

# Firewall setup
log_info "Configuring firewall..."
ufw allow 22
ufw allow 443
ufw allow 8443
ufw --force enable

# Obfuscation setup
log_info "Setting up obfuscation..."
# Placeholder: Modify this section to use custom obfuscation tools
cat <<EOF > /etc/vpn-obfuscation.conf
# Example configuration for obfuscation
obfs-server: enabled
obfs-key: $(openssl rand -base64 32)
EOF

# Docker container for VPN server
log_info "Pulling and starting VPN Docker container..."
docker pull quay.io/outline/shadowbox:stable
docker run -d --name shadowbox -p 443:443 -p 8443:8443 \
  -v /opt/outline:/opt/outline \
  -e "SB_API_PORT=8443" -e "SB_CERTIFICATE_KEY=/opt/outline/key.pem" \
  -e "SB_CERTIFICATE_CERT=/opt/outline/cert.pem" \
  quay.io/outline/shadowbox:stable

if ! docker ps | grep -q shadowbox; then
  log_error "Shadowbox container failed to start."
  exit 1
fi

log_info "Configuring monitoring..."
docker run -d --name watchtower -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower

log_info "Generating test commands and finalizing setup..."
cat <<EOF > /opt/vpn-setup-test-commands.sh
#!/bin/bash
set -euo pipefail

# Check ports
log_info "Checking ports..."
nc -zv 127.0.0.1 8443 || log_error "Port 8443 is not accessible."

# Check Docker containers
docker ps || log_error "Docker is not running correctly."
EOF
chmod +x /opt/vpn-setup-test-commands.sh

log_info "Setup complete! Run \e[34m/opt/vpn-setup-test-commands.sh\e[0m to verify."
exit 0
