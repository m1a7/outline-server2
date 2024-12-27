#!/bin/bash
set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # Сброс цвета

# Обновление системы
echo -e "${CYAN}Обновление системы...${NC}"
apt update && apt upgrade -y
apt install -y apt-transport-https ca-certificates curl software-properties-common net-tools ufw

# Установка Docker
echo -e "${CYAN}Проверка и установка Docker...${NC}"
if ! command -v docker &> /dev/null; then
  curl -fsSL https://get.docker.com | bash
else
  apt install -y docker-ce docker-ce-cli containerd.io
fi
systemctl enable --now docker

# Настройка брандмауэра
echo -e "${CYAN}Настройка брандмауэра для открытия всех соединений...${NC}"
ufw --force enable
ufw default allow incoming
ufw default allow outgoing
ufw allow 8843/tcp
ufw allow 1024:65535/tcp
ufw allow 1024:65535/udp
ufw reload
# Настройка брандмауэра
echo -e "${CYAN}Настройка брандмауэра для открытия всех соединений...${NC}"
ufw --force enable
ufw default allow incoming
ufw default allow outgoing
ufw allow 8843/tcp
ufw allow 1024:65535/tcp
ufw allow 1024:65535/udp
ufw reload