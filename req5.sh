#!/usr/bin/env bash

# ========================== ОФОРМЛЕНИЕ ВЫВОДА (ЦВЕТА) ===========================
COLOR_RED="\033[0;31m"
COLOR_GREEN="\033[0;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_CYAN="\033[0;36m"
COLOR_NONE="\033[0m"

# ============================= ПОДГОТОВКА ПАРАМЕТРОВ ============================
# Замените эту переменную на ваш реальный домен
DOMAIN="vpn.example.com"

# Порт для Nginx (HTTPS)
NGINX_PORT=443

# Внутренние порты
OUTLINE_PORT=5000
SHADOWSOCKS_PORT=8388

# Имя контейнеров Docker
OUTLINE_CONTAINER_NAME="outline-server"
SHADOWSOCKS_CONTAINER_NAME="shadowsocks-obfs4"

# ============================= УСТАНОВКА ЗАВИСИМОСТЕЙ ===========================
apt-get update -y
apt-get install -y docker.io certbot python3-certbot-nginx iptables

# ============================= УСТАНОВКА OUTLINE ================================
echo -e "${COLOR_CYAN}Установка Outline Server...${COLOR_NONE}"
docker run -d --name "$OUTLINE_CONTAINER_NAME" \
  -p 127.0.0.1:$OUTLINE_PORT:5000 \
  quay.io/outline/shadowbox:stable

# ============================= УСТАНОВКА SHADOWSOCKS ============================
echo -e "${COLOR_CYAN}Установка Shadowsocks + obfs4proxy...${COLOR_NONE}"
docker run -d --name "$SHADOWSOCKS_CONTAINER_NAME" \
  -p 127.0.0.1:$SHADOWSOCKS_PORT:8388 \
  shadowsocks/shadowsocks-libev \
  ss-server -s 0.0.0.0 -p 8388 -k "StrongPassword" -m aes-256-gcm --plugin obfs-server --plugin-opts "obfs=tls"

# ============================= УСТАНОВКА NGINX ==================================
apt-get install -y nginx
cat <<EOL > /etc/nginx/sites-available/vpn
server {
    listen $NGINX_PORT ssl;
    server_name $DOMAIN;

    # Прокси на Outline Server
    location /outline/ {
        proxy_pass http://127.0.0.1:$OUTLINE_PORT/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    # Прокси на Shadowsocks (TLS обфускация)
    location /shadowsocks/ {
        proxy_pass http://127.0.0.1:$SHADOWSOCKS_PORT/;
    }

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
}
EOL
ln -s /etc/nginx/sites-available/vpn /etc/nginx/sites-enabled/
nginx -t && systemctl restart nginx

# ============================= НАСТРОЙКА LET'S ENCRYPT ==========================
echo -e "${COLOR_CYAN}Настройка Let's Encrypt...${COLOR_NONE}"
certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN

# ============================= ГЕНЕРАЦИЯ API-LINK ===============================
echo -e "${COLOR_CYAN}Генерация строки конфигурации Outline Manager...${COLOR_NONE}"
CERT_HASH=$(openssl x509 -noout -fingerprint -sha256 -inform pem -in /etc/letsencrypt/live/$DOMAIN/fullchain.pem | awk -F= '{print $2}' | sed 's/://g')
API_URL="https://$DOMAIN:$NGINX_PORT/outline/"
CONFIG_STRING="{\"apiUrl\":\"$API_URL\",\"certSha256\":\"$CERT_HASH\"}"

echo -e "\n${COLOR_GREEN}Outline Manager Config:${COLOR_NONE}"
echo "$CONFIG_STRING"