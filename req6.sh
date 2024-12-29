#!/bin/bash

# Этот скрипт настраивает VPN-сервер с использованием Outline VPN и дополнительных настроек безопасности.
# Скрипт полностью совместим с Outline Manager и Ubuntu 22.04.
# Логирование выполнено в цветном формате для удобства чтения.

set -e

# Цвета для логирования
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
NC="\033[0m" # No Color

# Константы
MTU_VALUE=1500
VPN_PORT=443
OBFUSCATION_PORT=8443
NAT_INTERFACE=eth0
ACCESS_CONFIG="/opt/outline/access.txt"
SHADOWBOX_DIR="/opt/outline"
DOCKER_IMAGE="quay.io/outline/shadowbox:stable"
CERT_SHA256=""
API_URL=""

# Логирование
log_info() {
  echo -e "${GREEN}[INFO] $1${NC}"
}

log_warning() {
  echo -e "${YELLOW}[WARNING] $1${NC}"
}

log_error() {
  echo -e "${RED}[ERROR] $1${NC}"
}

# Функция для проверки и подготовки окружения
prepare_environment() {
  log_info "Проверка необходимых компонентов..."

  # Проверка наличия Docker
  if ! command -v docker &> /dev/null; then
    log_warning "Docker не установлен. Устанавливаем Docker..."
    curl -sSL https://get.docker.com/ | sh
    if [ $? -eq 0 ]; then
      log_info "Docker успешно установлен."
    else
      log_error "Ошибка установки Docker. Проверьте подключение к интернету."
    fi
  else
    log_info "Docker уже установлен."
  fi

  # Создание директории для Outline
  if [ ! -d "$SHADOWBOX_DIR" ]; then
    log_info "Создание директории для Outline..."
    mkdir -p "$SHADOWBOX_DIR"
    chmod u+s,ug+rwx,o-rwx "$SHADOWBOX_DIR"
  else
    log_info "Директория для Outline уже существует."
  fi
}

# Функция настройки ICMP
configure_icmp() {
  log_info "Настройка ICMP..."
  iptables -A INPUT -p icmp --icmp-type echo-request -j DROP
  iptables -A OUTPUT -p icmp --icmp-type echo-reply -j DROP
  log_info "ICMP успешно настроен."
}

# Функция изменения MTU
adjust_mtu() {
  log_info "Изменение MTU на $MTU_VALUE..."
  ip link set dev $NAT_INTERFACE mtu $MTU_VALUE
  log_info "MTU успешно изменен."
}

# Функция настройки NAT
configure_nat() {
  log_info "Настройка NAT..."
  iptables -t nat -A POSTROUTING -o $NAT_INTERFACE -j MASQUERADE
  log_info "NAT успешно настроен."
}

# Функция настройки TCP/UDP портов
configure_ports() {
  log_info "Настройка TCP/UDP портов..."
  iptables -A INPUT -p tcp --dport $VPN_PORT -j ACCEPT
  iptables -A INPUT -p udp --dport $VPN_PORT -j ACCEPT
  iptables -A INPUT -p tcp --dport $OBFUSCATION_PORT -j ACCEPT
  iptables -A INPUT -p udp --dport $OBFUSCATION_PORT -j ACCEPT
  log_info "Порты $VPN_PORT и $OBFUSCATION_PORT успешно настроены."
}

# Функция установки Outline VPN и обфускации
install_outline_vpn() {
  log_info "Установка Outline VPN..."

  docker run -d --name shadowbox --restart always \
    --net host \
    -e "SB_API_PORT=$VPN_PORT" \
    -e "SB_CERTIFICATE_FILE=/etc/shadowbox-selfsigned.crt" \
    -e "SB_PRIVATE_KEY_FILE=/etc/shadowbox-selfsigned.key" \
    -v "$SHADOWBOX_DIR:/opt/outline" \
    "$DOCKER_IMAGE"

  log_info "Outline VPN установлен."

  log_info "Установка Obfsproxy для обфускации трафика..."
  apt-get update && apt-get install -y obfsproxy
  obfsproxy obfs3 --dest=127.0.0.1:$VPN_PORT server --listen=0.0.0.0:$OBFUSCATION_PORT &
  log_info "Obfsproxy успешно настроен."
}

# Функция настройки шифрования
setup_encryption_headers() {
  log_info "Настройка шифрования..."
  CERT_SHA256=$(openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout /etc/shadowbox-selfsigned.key \
    -out /etc/shadowbox-selfsigned.crt \
    -subj "/CN=OutlineVPN" && \
    openssl x509 -in /etc/shadowbox-selfsigned.crt -noout -sha256 -fingerprint | awk -F= '{print $2}' | sed 's/://g')
  log_info "Шифрование успешно настроено."
}

# Функция тестирования результатов
test_configuration() {
  log_info "Тестирование конфигурации..."

  if docker ps | grep -q shadowbox; then
    log_info "Сервер Outline работает корректно."
  else
    log_error "Ошибка запуска сервера Outline. Проверьте логи Docker."
  fi

  log_info "Для тестирования вручную выполните следующие команды:"
  echo -e "${YELLOW}curl -k https://<ваш IP>:443${NC}"
  echo -e "${YELLOW}obfsproxy obfs3 client <ваш IP>:$OBFUSCATION_PORT <local_port>${NC}"
}

# Функция вывода строки для Outline Manager
output_outline_manager_config() {
  log_info "Генерация строки для Outline Manager..."
  API_URL="https://$(curl -s https://icanhazip.com):$VPN_PORT/oaUAMa0vlr0ev57n9MmQsA"
  echo -e "${GREEN}{\"apiUrl\":\"$API_URL\",\"certSha256\":\"$CERT_SHA256\"}${NC}"
}

# Основная функция
main() {
  prepare_environment
  configure_icmp
  adjust_mtu
  configure_nat
  configure_ports
  setup_encryption_headers
  install_outline_vpn
  test_configuration
  output_outline_manager_config

  log_info "Конфигурация завершена."
}

main
