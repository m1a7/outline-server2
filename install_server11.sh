#!/bin/bash

# ===========================
# VPN Installation with Advanced Obfuscation
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

print_section() {
  echo -e "\e[34m===== $1 =====\e[0m"
}

# Pre-flight checks
print_section "Pre-flight checks"
log_info "Checking for root permissions..."
if [[ "$EUID" -ne 0 ]]; then
  log_error "This script must be run as root. Use sudo."
  exit 1
fi

log_info "Updating system packages..."
apt-get update -qq && apt-get upgrade -y -qq

# Install required dependencies
print_section "Installing dependencies"
log_info "Installing necessary packages..."
apt-get install -y -qq apt-transport-https ca-certificates curl \
  software-properties-common net-tools ufw docker.io openssl

# Docker setup
print_section "Setting up Docker"
log_info "Configuring Docker service..."
systemctl enable --now docker
if ! docker --version >/dev/null 2>&1; then
  log_error "Docker installation failed."
  exit 1
fi

# Firewall setup
print_section "Configuring firewall"
log_info "Setting up firewall rules..."
ufw allow 22
ufw allow 443
ufw allow 8443
ufw --force enable

# Obfuscation setup
print_section "Setting up obfuscation"
log_info "Creating obfuscation configuration..."
OBFS_KEY=$(openssl rand -base64 32)
echo "obfs-key: $OBFS_KEY" > /etc/vpn-obfuscation.conf

# Docker container for VPN server
print_section "Setting up VPN server"
log_info "Pulling and starting Shadowbox Docker container..."
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

# Monitoring setup
print_section "Configuring monitoring"
log_info "Setting up Watchtower for automatic updates..."
docker run -d --name watchtower -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower

# Finalization
print_section "Finalizing setup"
log_info "Generating test script..."
cat <<EOF > /opt/vpn-setup-test-commands.sh
#!/bin/bash
set -euo pipefail

log_info() {
  echo -e "\e[32m[INFO]\e[0m \$1"
}

log_error() {
  echo -e "\e[31m[ERROR]\e[0m \$1"
}

log_info "Checking ports..."
nc -zv 127.0.0.1 8443 || log_error "Port 8443 is not accessible."

log_info "Checking Docker containers..."
docker ps || log_error "Docker is not running correctly."

log_info "Displaying configuration details..."
cat /etc/vpn-obfuscation.conf

log_info "Testing obfuscation..."
OBFS_TEST=$(curl -s -x socks5h://127.0.0.1:443 http://www.google.com || true)
if [[ -z "\$OBFS_TEST" ]]; then
  log_error "Obfuscation test failed! Ensure the proxy is running and accessible."
else
  log_info "Obfuscation is working correctly."
fi
EOF
chmod +x /opt/vpn-setup-test-commands.sh

# Generate Outline Manager Configuration
SERVER_IP=$(curl -s ifconfig.me)
API_KEY=$(openssl rand -hex 16)
CERT_SHA256=$(openssl x509 -in /opt/outline/cert.pem -fingerprint -sha256 -noout | cut -d '=' -f2 | sed 's/://g')

CONFIG_JSON="{\"apiUrl\":\"https://$SERVER_IP:8443/$API_KEY\",\"certSha256\":\"$CERT_SHA256\"}"

log_info "Setup complete! Configuration for Outline Manager:"
echo -e "\e[34m$CONFIG_JSON\e[0m"
log_info "Run \e[34m/opt/vpn-setup-test-commands.sh\e[0m to verify and get configuration details."
exit 0
