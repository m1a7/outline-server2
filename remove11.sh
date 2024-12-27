#!/bin/bash

# =========================
# VPN Cleanup Script
# =========================
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

# Remove Docker containers
print_section "Removing Docker containers"
log_info "Stopping and removing Shadowbox container..."
docker rm -f shadowbox >/dev/null 2>&1 || log_warn "Shadowbox container does not exist."

log_info "Stopping and removing Watchtower container..."
docker rm -f watchtower >/dev/null 2>&1 || log_warn "Watchtower container does not exist."

# Remove Docker images
print_section "Removing Docker images"
log_info "Removing Shadowbox image..."
docker rmi quay.io/outline/shadowbox:stable >/dev/null 2>&1 || log_warn "Shadowbox image does not exist."

log_info "Removing Watchtower image..."
docker rmi containrrr/watchtower:latest >/dev/null 2>&1 || log_warn "Watchtower image does not exist."

# Remove certificates and keys
print_section "Removing certificates and keys"
CERT_DIR="/opt/outline"
log_info "Deleting certificate directory $CERT_DIR..."
rm -rf "$CERT_DIR" || log_warn "Certificate directory does not exist."

# Remove obfuscation configuration
print_section "Removing obfuscation configuration"
OBFS_CONF="/etc/vpn-obfuscation.conf"
log_info "Deleting obfuscation configuration file $OBFS_CONF..."
rm -f "$OBFS_CONF" || log_warn "Obfuscation configuration file does not exist."

# Remove firewall rules
print_section "Restoring firewall settings"
log_info "Deleting VPN-related firewall rules..."
ufw delete allow 443 >/dev/null 2>&1 || log_warn "Firewall rule for port 443 does not exist."
ufw delete allow 8443 >/dev/null 2>&1 || log_warn "Firewall rule for port 8443 does not exist."

# Remove test script
print_section "Removing test script"
TEST_SCRIPT="/opt/vpn-setup-test-commands.sh"
log_info "Deleting test script $TEST_SCRIPT..."
rm -f "$TEST_SCRIPT" || log_warn "Test script does not exist."

# Final cleanup
print_section "Final cleanup"
log_info "Removing unused Docker volumes and networks..."
docker system prune -f --volumes || log_warn "Docker cleanup failed."

log_info "VPN cleanup completed successfully!"
exit 0
