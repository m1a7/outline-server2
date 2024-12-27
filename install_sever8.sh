#!/bin/bash
set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # Сброс цвета

# Проверка прав пользователя
check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Этот скрипт нужно запускать с правами root!${NC}"
    exit 1
  fi
}

# Настройка логирования
setup_logging() {
  exec > >(tee -i /var/log/install_shadowbox.log)
  exec 2>&1
}

# Обновление системы
update_system() {
  echo -e "${CYAN}Обновление системы...${NC}"
  apt update && apt upgrade -y
  apt install -y apt-transport-https ca-certificates curl software-properties-common net-tools ufw
}

# Настройка брандмауэра
setup_firewall() {
  echo -e "${CYAN}Настройка firewall...${NC}"
  ufw --force enable
  ufw default allow incoming
  ufw default allow outgoing
  echo -e "${GREEN}Firewall включен.${NC}"
}

# Открытие порта
open_port() {
  local port=$1
  local protocol=${2:-tcp}
  if ! ufw status | grep -q "$port/$protocol"; then
    ufw allow "$port/$protocol"
    echo -e "${GREEN}Порт $port/$protocol открыт.${NC}"
  fi
}

# Проверка доступности внешних ресурсов
check_external_resources() {
  if ! curl -sf https://icanhazip.com &>/dev/null; then
    echo -e "${RED}Ошибка: Сайт icanhazip.com недоступен!${NC}"
    exit 1
  fi
}

# Проверка Docker API
check_docker_api() {
  if ! docker info &>/dev/null; then
    echo -e "${RED}Ошибка: Docker API недоступен.${NC}"
    exit 1
  fi
}

# Проверка запущенных контейнеров
check_containers() {
  if docker ps | grep -q shadowbox; then
    echo -e "${GREEN}Контейнер shadowbox работает.${NC}"
  else
    echo -e "${RED}Контейнер shadowbox не запущен!${NC}"
  fi

  if docker ps | grep -q watchtower; then
    echo -e "${GREEN}Контейнер watchtower работает.${NC}"
  else
    echo -e "${RED}Контейнер watchtower не запущен!${NC}"
  fi
}

# Проверка конфигурации контейнеров
check_container_config() {
  if docker logs shadowbox 2>&1 | grep -q 'apiUrl'; then
    echo -e "${GREEN}Конфигурация shadowbox корректна.${NC}"
  else
    echo -e "${RED}Ошибка в конфигурации shadowbox!${NC}"
  fi

  if docker logs shadowbox 2>&1 | grep -q 'obfs'; then
    echo -e "${GREEN}Обфускация включена и работает.${NC}"
  else
    echo -e "${RED}Обфускация данных не работает!${NC}"
  fi
}

# Проверка правил брандмауэра
check_firewall_rules() {
  if ufw status | grep -q '443'; then
    echo -e "${GREEN}Порты для TCP/UDP разрешены.${NC}"
  else
    echo -e "${RED}Правила брандмауэра блокируют порты!${NC}"
  fi
}

# Установка Docker
install_docker() {
  echo -e "${CYAN}Проверка и установка Docker...${NC}"
  if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | bash
  else
    apt install -y docker-ce docker-ce-cli containerd.io
  fi
  systemctl enable --now docker
}

# Настройка сервера Shadowbox
setup_shadowbox() {
  local shadowbox_dir="/opt/outline"
  local state_dir="${shadowbox_dir}/persisted-state"
  local cert_key="${state_dir}/shadowbox-selfsigned.key"
  local cert_file="${state_dir}/shadowbox-selfsigned.crt"
  local sb_image="quay.io/outline/shadowbox:stable"

  mkdir -p "$state_dir"

  echo -e "${CYAN}Генерация сертификатов...${NC}"
  openssl req -x509 -nodes -days 36500 -newkey rsa:4096 \
    -subj "/CN=$(curl -s https://icanhazip.com/)" \
    -keyout "$cert_key" -out "$cert_file"

  echo -e "${CYAN}Генерация API ключа...${NC}"
  local sb_api_prefix=$(head -c 16 /dev/urandom | base64 | tr '/+' '_-' | tr -d '=')

  echo -e "${CYAN}Создание конфигурации...${NC}"
  cat <<EOF > "${state_dir}/shadowbox_server_config.json"
{
  "portForNewAccessKeys": 443,
  "hostname": "$(curl -s https://icanhazip.com/)",
  "name": "Outline Server"
}
EOF

  echo -e "${CYAN}Удаление старых контейнеров...${NC}"
  docker rm -f shadowbox watchtower 2>/dev/null || true

  echo -e "${CYAN}Запуск контейнера Shadowbox...${NC}"
  docker run -d --name shadowbox --restart always \
    --net host \
    -v "$state_dir:$state_dir" \
    -e "SB_STATE_DIR=$state_dir" \
    -e "SB_API_PORT=443" \
    -e "SB_API_PREFIX=$sb_api_prefix" \
    -e "SB_CERTIFICATE_FILE=$cert_file" \
    -e "SB_PRIVATE_KEY_FILE=$cert_key" \
    "$sb_image"
}

# Установка Watchtower
setup_watchtower() {
  echo -e "${CYAN}Установка Watchtower...${NC}"
  docker run -d --name watchtower --restart always \
    -v /var/run/docker.sock:/var/run/docker.sock \
    containrrr/watchtower --cleanup --interval 3600
}

# Печатаем информацию
 printInfo() {
    # Вывод конфигурационной строки для Outline Manager
  API_URL="https://$(curl -s https://icanhazip.com/):443/${SB_API_PREFIX}"
  CERT_SHA256=$(openssl x509 -in "${CERT_FILE}" -noout -sha256 -fingerprint | cut -d'=' -f2 | tr -d ':')
  CONFIG_STRING="{apiUrl:${API_URL},certSha256:${CERT_SHA256}}"
  echo -e "${CYAN}Конфигурация для Outline Manager:${NC}"
  echo -e "${GREEN}${CONFIG_STRING}${NC}"

  # Вывод путей к созданным файлам
  echo -e "${CYAN}Созданные файлы и пути:${NC}"
  echo -e "${BLUE}Ключ: ${CERT_KEY}${NC}"
  echo -e "${BLUE}Сертификат: ${CERT_FILE}${NC}"
  echo -e "${BLUE}Файл конфигурации: ${STATE_DIR}/shadowbox_server_config.json${NC}"

  # Вывод тестовых команд
  echo -e "${CYAN}Тестовые команды для проверки настроек:${NC}"
  echo -e "${BLUE}# Проверить доступность портов${NC}"
  echo "sudo ufw status"
  echo "nc -zv 127.0.0.1 443"

  echo -e "${BLUE}# Проверить запущенные контейнеры${NC}"
  echo "docker ps"

  echo -e "${BLUE}# Проверить конфигурацию shadowbox${NC}"
  echo "docker logs shadowbox | grep 'apiUrl'"

  echo -e "${BLUE}# Проверить обфускацию${NC}"
  echo "docker logs shadowbox | grep 'obfs'"
}

# Основной процесс
main() {
  check_root
  setup_logging
  update_system
  setup_firewall
  open_port 443 tcp
  check_external_resources
  install_docker
  setup_shadowbox
  setup_watchtower
  check_docker_api
  check_containers
  check_container_config
  check_firewall_rules
  printInfo
  echo -e "${GREEN}Установка завершена!${NC}"
}

main
