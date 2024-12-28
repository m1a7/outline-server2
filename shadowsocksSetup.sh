#!/bin/bash

# Update and install dependencies
apt-get update && apt-get upgrade -y
apt-get install -y shadowsocks-libev obfs4proxy ufw

# Configure Shadowsocks server
cat <<EOF > /etc/shadowsocks-libev/config.json
{
    "server": "0.0.0.0",
    "server_port": 443,
    "password": "Auth777Key$DO",
    "method": "aes-256-gcm",
    "plugin": "obfs-server",
    "plugin_opts": "obfs=http"
}
EOF

# Enable and start Shadowsocks service
systemctl enable shadowsocks-libev
systemctl start shadowsocks-libev

# Configure firewall (UFW) to allow port 443
ufw allow 443/tcp
ufw allow 443/udp
ufw enable

# Ensure traffic is routed through Shadowsocks
iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-ports 443
iptables -t nat -A PREROUTING -p udp --dport 443 -j REDIRECT --to-ports 443

# Install and configure obfs4proxy (if needed)
if ! command -v obfs4proxy &> /dev/null
then
    apt-get install -y obfs4proxy
fi

cat <<EOF > /etc/shadowsocks-libev/obfs4-bridge.json
{
    "server": "0.0.0.0",
    "server_port": 443,
    "password": "Auth777Key$DO",
    "method": "aes-256-gcm",
    "plugin": "obfs4",
    "plugin_opts": "cert=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA;iat-mode=0"
}
EOF

# Restart Shadowsocks with the new configuration
systemctl restart shadowsocks-libev

# Output client configuration
cat <<EOF > /root/shadowsocks-client-config.json
{
    "server": "68.183.234.156",
    "server_port": 443,
    "password": "Auth777Key$DO",
    "method": "aes-256-gcm",
    "plugin": "obfs-client",
    "plugin_opts": "obfs=http;obfs-host=www.bing.com"
}
EOF

# Test the server setup and log results
echo "Testing Shadowsocks service..." > /root/shadowsocks-setup.log
if systemctl status shadowsocks-libev | grep -q 'active (running)'; then
    echo "Shadowsocks is running." >> /root/shadowsocks-setup.log
else
    echo "Shadowsocks is not running. Check the service logs." >> /root/shadowsocks-setup.log
fi

iptables -L -t nat -v -n | grep 443 >> /root/shadowsocks-setup.log
ufw status >> /root/shadowsocks-setup.log

# Display completion message
clear
echo "Shadowsocks VPN with obfuscation is installed and running on port 443."
echo "Client configuration is saved at /root/shadowsocks-client-config.json."
echo "Setup log is saved at /root/shadowsocks-setup.log."
