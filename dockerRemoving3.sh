#!/bin/bash

# Enable strict mode
set -euo pipefail

# Define colors for logs
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print messages in color
print_msg() {
    COLOR=$1
    MESSAGE=$2
    echo -e "${COLOR}${MESSAGE}${NC}"
}

# Error handler
error_handler() {
    print_msg $RED "An error occurred in the script. Continuing with the next steps..."
}
trap error_handler ERR

print_msg $BLUE "Starting Docker cleanup script..."

# Step 1: Stop Docker and related services
print_msg $BLUE "Stopping Docker and related processes..."
if sudo systemctl stop docker docker.socket containerd.service; then
    print_msg $GREEN "Docker and related services stopped successfully."
else
    print_msg $RED "Failed to stop Docker services. Please check manually."
fi

# Step 2: Ensure Docker processes are stopped
print_msg $BLUE "Ensuring all Docker-related processes are stopped..."
if pgrep -f docker &> /dev/null; then
    print_msg $RED "Warning: Some Docker-related processes are still running. Consider restarting the machine."
else
    print_msg $GREEN "No Docker-related processes running."
fi

# Step 3: Remove all containers
print_msg $BLUE "Removing all Docker containers..."
if containers=$(sudo docker container ls -aq 2>/dev/null); then
    sudo docker container stop $containers 2>/dev/null || true
    sudo docker container rm $containers 2>/dev/null || true
    print_msg $GREEN "All containers removed successfully."
else
    print_msg $GREEN "No containers to remove."
fi

# Step 4: Uninstall Docker
print_msg $BLUE "Uninstalling Docker..."
if sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin; then
    print_msg $GREEN "Docker uninstalled successfully."
else
    print_msg $RED "Failed to uninstall Docker. Please check manually."
fi

# Step 5: Remove residual files and directories
print_msg $BLUE "Cleaning up residual files and directories..."
sudo rm -rf /var/lib/docker /var/lib/containerd /etc/docker /run/docker* /run/containerd* || true
print_msg $GREEN "Residual files removed successfully."

# Step 6: Remove old certificates and keys
print_msg $BLUE "Removing old certificates and keys..."
sudo rm -rf /etc/docker/certs.d /var/lib/docker/certs.d || true
print_msg $GREEN "Old certificates and keys removed successfully."

# Step 7: Remove Docker-related dependencies and packages
print_msg $BLUE "Removing Docker-related dependencies..."
if sudo apt-get autoremove -y && sudo apt-get autoclean -y; then
    print_msg $GREEN "Dependencies and cache cleaned successfully."
else
    print_msg $RED "Failed to clean dependencies or cache."
fi

# Step 8: Verify system is clean
print_msg $BLUE "Verifying system cleanup..."
if ! command -v docker &> /dev/null; then
    print_msg $GREEN "Docker command not found. Cleanup verified."
else
    print_msg $RED "Docker command still exists. Manual cleanup required."
fi

print_msg $BLUE "Docker cleanup script completed."
