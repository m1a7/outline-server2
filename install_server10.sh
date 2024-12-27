#!/bin/bash

# Проверка прав
if [[ $EUID -ne 0 ]]; then
    echo "Этот скрипт должен быть запущен с правами root." >&2
    exit 1
fi

echo "Обновление системы..."
apt update && apt upgrade -y

echo "Установка необходимых пакетов..."
apt install -y apt-transport-https ca-certificates curl software-properties-common net-tools ufw jq

echo "Установка Docker..."
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

echo "Настройка брандмауэра (ufw)..."
ufw default allow incoming
ufw default allow outgoing
ufw allow 443
ufw allow 8443
ufw allow 8843
ufw --force enable

echo "Создание конфигурации для Shadowsocks с обфускацией..."
# Генерация ключа для Shadowsocks
SS_PASSWORD=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
echo "Пароль Shadowsocks: $SS_PASSWORD"

# Создание docker-compose.yml
cat > /opt/outline/docker-compose.yml <<EOF
version: '3.3'
services:
  shadowbox:
    image: quay.io/outline/shadowbox:stable
    ports:
      - "443:443/tcp"
      - "443:443/udp"
      - "8843:8843/tcp"
      - "8443:8443/tcp"
    environment:
      - SHADOWSOCKS_METHOD=aes-256-gcm
      - SHADOWSOCKS_PASSWORD=$SS_PASSWORD
      - SB_PUBLIC_IP=$(curl -s ifconfig.me)
      - SB_API_PREFIX=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)
    volumes:
      - ./persisted-state:/opt/outline/persisted-state
  v2ray-plugin:
    image: teddysun/v2ray-plugin
    ports:
      - "80:80"
      - "443:443"
    command: "-server"
EOF

echo "Запуск Docker Compose..."
docker-compose -f /opt/outline/docker-compose.yml up -d

echo "Настройка обфускации с использованием v2ray-plugin..."
cat > /opt/outline/shadowsocks.json <<EOF
{
    "server": "0.0.0.0",
    "server_port": 443,
    "password": "$SS_PASSWORD",
    "method": "aes-256-gcm",
    "plugin": "v2ray-plugin",
    "plugin_opts": "server;tls;host=$(curl -s ifconfig.me)"
}
EOF

echo "Проверка работы Shadowsocks..."
docker ps | grep -q shadowbox && echo "Shadowsocks запущен успешно." || echo "Ошибка запуска Shadowsocks."

echo "Конфигурация для клиента Outline Manager:"
echo "{apiUrl:https://$(curl -s ifconfig.me):8443/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16),certSha256:$(openssl x509 -fingerprint -sha256 -in /opt/outline/persisted-state/shadowbox-selfsigned.crt | awk -F= '{print $2}' | tr -d ':')}"

echo "Установка Watchtower для автоматического обновления контейнеров..."
docker run -d --name watchtower --restart unless-stopped -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower --cleanup

echo "Установка завершена. Ваш сервер готов к использованию с включенной обфускацией."
