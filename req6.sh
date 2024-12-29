#!/bin/bash

set -euo pipefail

LOG_FILE="/var/log/outline_install.log"
touch "$LOG_FILE"

function log() {
  local MESSAGE=$1
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $MESSAGE" | tee -a "$LOG_FILE"
}

function test_command() {
  local COMMAND=$1
  local SUCCESS_MESSAGE=$2
  local FAILURE_MESSAGE=$3

  if eval "$COMMAND"; then
    log "$SUCCESS_MESSAGE"
  else
    log "$FAILURE_MESSAGE"
    exit 1
  fi
}

function configure_icmp() {
  log "Configuring ICMP settings..."
  test_command \
    "sysctl -w net.ipv4.icmp_echo_ignore_all=0" \
    "ICMP echo requests enabled." \
    "Failed to enable ICMP echo requests."
  test_command \
    "sysctl -w net.ipv4.icmp_echo_ignore_broadcasts=1" \
    "ICMP broadcast suppression enabled." \
    "Failed to enable ICMP broadcast suppression."
}

function configure_mtu() {
  log "Configuring MTU..."
  INTERFACE=$(ip route | grep default | awk '{print $5}')
  MTU_VALUE=1400
  test_command \
    "ip link set dev $INTERFACE mtu $MTU_VALUE" \
    "MTU set to $MTU_VALUE on interface $INTERFACE." \
    "Failed to set MTU on interface $INTERFACE."
}

function configure_nat() {
  log "Configuring NAT..."
  test_command \
    "sysctl -w net.ipv4.ip_forward=1" \
    "IP forwarding enabled." \
    "Failed to enable IP forwarding."
  test_command \
    "iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE" \
    "NAT configuration applied." \
    "Failed to configure NAT."
}

function install_docker() {
  if ! command -v docker &>/dev/null; then
    log "Docker not found. Installing..."
    test_command \
      "curl -fsSL https://get.docker.com | sh" \
      "Docker installed successfully." \
      "Failed to install Docker."
  else
    log "Docker is already installed."
  fi
}

function install_outline() {
  log "Installing Outline server..."
  SHADOWBOX_DIR="/opt/outline"
  mkdir -p "$SHADOWBOX_DIR"
  test_command \
    "docker run -d \
      --name shadowbox \
      --restart always \
      --net host \
      -v $SHADOWBOX_DIR:$SHADOWBOX_DIR \
      -e SB_STATE_DIR=$SHADOWBOX_DIR \
      quay.io/outline/shadowbox:stable" \
    "Outline server installed successfully." \
    "Failed to install Outline server."
}

function generate_outline_config() {
  log "Generating Outline configuration..."
  API_URL="https://$(curl -s ifconfig.me):443/$(head -c 16 /dev/urandom | base64 | tr '/+' '_-' | tr -d '=')"
  CERT_SHA256=$(openssl x509 -noout -fingerprint -sha256 -inform pem -in "$SHADOWBOX_DIR/shadowbox-selfsigned.crt" | awk -F'=' '{print $2}' | tr -d ':')

  if [[ -z "$CERT_SHA256" || -z "$API_URL" ]]; then
    log "Failed to generate configuration string."
    exit 1
  fi

  CONFIG_STRING="{\"apiUrl\":\"$API_URL\",\"certSha256\":\"$CERT_SHA256\"}"
  log "Configuration string generated: $CONFIG_STRING"
  echo "$CONFIG_STRING"
}

function main() {
  log "Starting Outline server setup..."
  install_docker
  configure_icmp
  configure_mtu
  configure_nat
  install_outline
  generate_outline_config
  log "Setup complete. Check the log at $LOG_FILE for details."
}

main
