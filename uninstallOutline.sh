#!/bin/bash

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to print logs with colors
print_log() {
    case "$1" in
        success)
            echo -e "\033[32m[SUCCESS]\033[0m $2"
            ;;
        warning)
            echo -e "\033[33m[WARNING]\033[0m $2"
            ;;
        error)
            echo -e "\033[31m[ERROR]\033[0m $2"
            ;;
        info)
            echo -e "\033[34m[INFO]\033[0m $2"
            ;;
        *)
            echo "$2"
            ;;
    esac
}

# Stop and remove Docker containers related to Outline Server
print_log info "Stopping and removing Outline Server containers..."
if command_exists docker; then
    CONTAINERS=$(docker ps -a --filter "ancestor=outline-server" --format "{{.ID}}")
    if [ -n "$CONTAINERS" ]; then
        docker stop $CONTAINERS && print_log success "Docker containers stopped."
        docker rm $CONTAINERS && print_log success "Docker containers removed."
    else
        print_log warning "No Outline Server containers found."
    fi

    # Remove Docker images related to Outline Server
    IMAGES=$(docker images "outline-server" --format "{{.ID}}")
    if [ -n "$IMAGES" ]; then
        docker rmi $IMAGES && print_log success "Docker images removed."
    else
        print_log warning "No Outline Server images found."
    fi
else
    print_log error "Docker is not installed or not running. Skipping Docker cleanup."
fi

# Remove Outline Manager binary and configuration files
print_log info "Removing Outline Manager and related files..."
if rm -f /usr/local/bin/outline-ss-server && rm -rf /var/lib/outline; then
    print_log success "Outline Manager binary and configuration files removed."
else
    print_log warning "Failed to remove some Outline Manager files."
fi

# Remove Outline-related certificates, keys, and logs
print_log info "Removing certificates, keys, and logs..."
if rm -rf /etc/outline && rm -rf /var/log/outline; then
    print_log success "Certificates, keys, and logs removed."
else
    print_log warning "Failed to remove some certificates, keys, or logs."
fi

# Clean up temporary files
print_log info "Cleaning up temporary files..."
if rm -rf /tmp/outline_installation; then
    print_log success "Temporary files cleaned up."
else
    print_log warning "Failed to clean up temporary files."
fi

# Final checks
print_log info "Performing final checks..."
if command_exists docker && [ -z "$(docker ps -a --filter \"ancestor=outline-server\" --format \"{{.ID}}\")" ] && [ -z "$(docker images \"outline-server\" --format \"{{.ID}}\")" ]; then
    print_log success "Docker cleanup verified."
else
    print_log warning "Docker cleanup verification failed."
fi

if [ ! -f /usr/local/bin/outline-ss-server ] && [ ! -d /var/lib/outline ] && [ ! -d /etc/outline ] && [ ! -d /var/log/outline ] && [ ! -d /tmp/outline_installation ]; then
    print_log success "All files and directories successfully removed."
else
    print_log warning "Some files or directories were not fully removed."
fi

print_log info "Outline Server removal process completed."
