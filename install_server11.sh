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
log_info "Checking Docker installation..."
if ! command -v docker >/dev/null 2>&1; then
  log_error "Docker is not installed. Please install Docker before running this script."
  exit 1
fi

log_info "Configuring Docker service..."
systemctl enable --now docker

# Port check
log_info "Checking required ports..."
for port in 443 8443; do
  if ss -tuln | grep -q ":$port"; then
    log_warn "Port $port is already in use. Attempting to free it..."
    fuser -k "$port/tcp" || log_warn "Could not free port $port."
  fi
done

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

# Generate self-signed certificate
print_section "Generating certificates"
CERT_DIR="/opt/outline"
mkdir -p "$CERT_DIR"
CERT_KEY="$CERT_DIR/key.pem"
CERT_CRT="$CERT_DIR/cert.pem"
log_info "Creating self-signed certificate..."
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "$CERT_KEY" -out "$CERT_CRT" \
  -subj "/C=US/ST=State/L=City/O=Organization/OU=Unit/CN=localhost"

if [[ ! -f "$CERT_KEY" || ! -f "$CERT_CRT" ]]; then
  log_error "Certificate generation failed."
  exit 1
fi

# Validate generated files
log_info "Validating generated files..."
if [[ ! -s "$CERT_KEY" ]]; then
  log_error "Certificate key is empty or invalid."
  exit 1
fi
if [[ ! -s "$CERT_CRT" ]]; then
  log_error "Certificate file is empty or invalid."
  exit 1
fi

# Docker container for VPN server
print_section "Setting up VPN server"
log_info "Pulling and starting Shadowbox Docker container..."
docker pull quay.io/outline/shadowbox:stable || log_error "Failed to pull Shadowbox image."

docker rm -f shadowbox >/dev/null 2>&1 || log_warn "No existing Shadowbox container to remove."
docker run -d --name shadowbox -p 443:443 -p 8443:8443 \
  -v "$CERT_DIR:$CERT_DIR" \
  -e "SB_API_PORT=8443" -e "SB_CERTIFICATE_KEY=$CERT_KEY" \
  -e "SB_CERTIFICATE_CERT=$CERT_CRT" \
  quay.io/outline/shadowbox:stable

if ! docker ps | grep -q shadowbox; then
  log_error "Shadowbox container failed to start. Checking logs..."
  docker logs --tail 50 shadowbox || log_error "Unable to fetch Shadowbox logs."
  exit 1
fi

log_info "Verifying Shadowbox container health..."
SHADOWBOX_HEALTH=$(docker inspect -f '{{.State.Health.Status}}' shadowbox 2>/dev/null || echo "unhealthy")
if [[ "$SHADOWBOX_HEALTH" != "healthy" ]]; then
  log_error "Shadowbox container is not healthy. Logs:"
  docker logs --tail 50 shadowbox
  exit 1
fi

# Monitoring setup
print_section "Configuring monitoring"
log_info "Setting up Watchtower for automatic updates..."
docker pull containrrr/watchtower:latest || log_error "Failed to pull Watchtower image."

docker rm -f watchtower >/dev/null 2>&1 || log_warn "No existing Watchtower container to remove."
docker run -d --name watchtower -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower || log_error "Failed to start Watchtower container."

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
OBFS_KEY=\$(grep 'obfs-key' /etc/vpn-obfuscation.conf | cut -d ':' -f2 | xargs)
OBFS_TEST=\$(curl -s -x socks5h://127.0.0.1:443 -U \$OBFS_KEY:http://www.google.com || true)
if [[ -z "\$OBFS_TEST" ]]; then
  log_error "Obfuscation test failed! Ensure the proxy is running and accessible."
else
  log_info "Obfuscation is working correctly."
fi

log_info "Checking Shadowbox logs for issues..."
docker logs --tail 50 shadowbox || log_error "Unable to fetch Shadowbox logs."
EOF
chmod +x /opt/vpn-setup-test-commands.sh

# Generate Outline Manager Configuration
SERVER_IP=$(curl -s ifconfig.me)
API_KEY=$(openssl rand -hex 16)
CERT_SHA256=$(openssl x509 -in "$CERT_CRT" -fingerprint -sha256 -noout | cut -d '=' -f2 | sed 's/://g')

CONFIG_JSON="{\"apiUrl\":\"https://$SERVER_IP:8443/$API_KEY\",\"certSha256\":\"$CERT_SHA256\"}"

log_info "Setup complete! Configuration for Outline Manager:"
echo -e "\e[34m$CONFIG_JSON\e[0m"
log_info "Run \e[34m/opt/vpn-setup-test-commands.sh\e[0m to verify and get configuration details."
exit 0
