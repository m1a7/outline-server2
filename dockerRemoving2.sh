#!/bin/bash

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

print_msg $BLUE "Starting Docker cleanup script..."

# Step 1: Stop Docker and related processes
print_msg $BLUE "Stopping Docker and related processes..."
sudo systemctl stop docker docker.socket containerd.service && \
    print_msg $GREEN "Docker and related services stopped successfully." || \
    print_msg $RED "Failed to stop Docker services. Please check manually."

# Step 2: Kill all Docker-related processes
print_msg $BLUE "Killing all Docker-related processes..."
sudo pkill -f docker 2>/dev/null && \
    print_msg $GREEN "Docker-related processes killed successfully." || \
    print_msg $RED "Failed to kill some Docker-related processes."

# Step 3: Remove all containers
print_msg $BLUE "Removing all Docker containers..."
sudo docker container stop $(sudo docker container ls -aq) 2>/dev/null
sudo docker container rm $(sudo docker container ls -aq) 2>/dev/null && \
    print_msg $GREEN "All containers removed successfully." || \
    print_msg $RED "Failed to remove some containers."

# Step 4: Uninstall Docker
print_msg $BLUE "Uninstalling Docker..."
sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin && \
    print_msg $GREEN "Docker uninstalled successfully." || \
    print_msg $RED "Failed to uninstall Docker. Please check manually."

# Step 5: Remove residual files and directories
print_msg $BLUE "Cleaning up residual files and directories..."
sudo rm -rf /var/lib/docker /var/lib/containerd /etc/docker /run/docker* /run/containerd* && \
    print_msg $GREEN "Residual files removed successfully." || \
    print_msg $RED "Failed to remove some residual files."

# Step 6: Remove old certificates and keys
print_msg $BLUE "Removing old certificates and keys..."
sudo rm -rf /etc/docker/certs.d /var/lib/docker/certs.d && \
    print_msg $GREEN "Old certificates and keys removed successfully." || \
    print_msg $RED "Failed to remove some certificates or keys."

# Step 7: Remove Docker-related dependencies and packages
print_msg $BLUE "Removing Docker-related dependencies..."
sudo apt-get autoremove -y && sudo apt-get autoclean -y && \
    print_msg $GREEN "Dependencies and cache cleaned successfully." || \
    print_msg $RED "Failed to clean dependencies or cache."

# Step 8: Verify system is clean
print_msg $BLUE "Verifying system cleanup..."
if ! command -v docker &> /dev/null; then
    print_msg $GREEN "Docker command not found. Cleanup verified."
else
    print_msg $RED "Docker command still exists. Manual cleanup required."
fi

print_msg $BLUE "Docker cleanup script completed."
