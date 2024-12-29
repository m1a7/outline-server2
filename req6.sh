#!/bin/bash

# Этот скрипт настраивает VPN-сервер с использованием Outline VPN и дополнительных настроек безопасности.
# Скрипт полностью совместим с Outline Manager и Ubuntu 22.04.
# Логирование выполнено в цветном формате для удобства чтения.

set +e

# Цвета для логирования
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
CYAN="\033[0;36m"
NC="\033[0m" # No Color

# Константы
MTU_VALUE=1500
VPN_PORT=443
OBFUSCATION_PORT=8443
NAT_INTERFACE=eth0
SHADOWBOX_DIR="/opt/outline"
DOCKER_IMAGE="quay.io/outline/shadowbox:stable"
CERT_SHA256=""
API_URL=""
CURRENT_STEP=""

# Логирование
log_info() {
  echo -e "${CYAN}[INFO] $1${NC}"
}

log_success() {
  echo -e "${GREEN}[OK] $1${NC}"
}

log_warning() {
  echo -e "${YELLOW}[WARNING] $1${NC}"
}

log_error() {
  local errmsg="$1"
  echo -e "${RED}[ERROR] $errmsg${NC}"
  echo -e "${RED}[ERROR] Вопрос для ChatGPT: 'Почему в процессе выполнения шага "${CURRENT_STEP}" возникла ошибка: "${errmsg}"?'${NC}"
}

run_command() {
  local step_description="$1"
  shift
  CURRENT_STEP="$step_description"

  log_info "Начало шага: '$step_description'"
  if "$@"; then
    log_success "Шаг '$step_description' завершён успешно."
  else
    log_error "Не удалось выполнить шаг '$step_description'."
  fi
}

# Функция для проверки и подготовки окружения
prepare_environment() {
  run_command "Проверка наличия Docker" bash -c '
    if ! command -v docker &>/dev/null; then
      echo "Docker не найден. Устанавливаем..."
      curl -fsSL https://get.docker.com | sh
      if [[ $? -eq 0 ]]; then
        echo "Docker установлен успешно."
      else
        echo "Не удалось установить Docker!"
        exit 1
      fi
    else
      echo "Docker уже установлен."
    fi
  '

  run_command "Проверка, что Docker запущен" bash -c '
    if ! systemctl is-active --quiet docker; then
      echo "Docker не запущен. Попытаюсь запустить..."
      systemctl enable docker
      systemctl start docker
      if ! systemctl is-active --quiet docker; then
        echo "Не удалось запустить Docker!"
        exit 1
      fi
    fi
  '

  run_command "Создание директории для Outline" bash -c '
    mkdir -p "$SHADOWBOX_DIR"
    chmod 700 "$SHADOWBOX_DIR"
  '
}

configure_icmp() {
  run_command "Настройка ICMP" bash -c '
    iptables -A INPUT -p icmp --icmp-type echo-request -j DROP
    iptables -A OUTPUT -p icmp --icmp-type echo-reply -j DROP
  '
}

adjust_mtu() {
  run_command "Изменение MTU на $MTU_VALUE" bash -c '
    ip link set dev $NAT_INTERFACE mtu $MTU_VALUE
  '
}

configure_nat() {
  run_command "Настройка NAT" bash -c '
    iptables -t nat -A POSTROUTING -o $NAT_INTERFACE -j MASQUERADE
  '
}

configure_ports() {
  run_command "Настройка портов $VPN_PORT и $OBFUSCATION_PORT" bash -c '
    iptables -A INPUT -p tcp --dport $VPN_PORT -j ACCEPT
    iptables -A INPUT -p udp --dport $VPN_PORT -j ACCEPT
    iptables -A INPUT -p tcp --dport $OBFUSCATION_PORT -j ACCEPT
    iptables -A INPUT -p udp --dport $OBFUSCATION_PORT -j ACCEPT
  '
}

install_outline_vpn() {
  run_command "Установка Outline VPN" bash -c '
    docker run -d --name shadowbox --restart always \
      --net host \
      -e "SB_API_PORT=$VPN_PORT" \
      -e "SB_CERTIFICATE_FILE=/etc/shadowbox-selfsigned.crt" \
      -e "SB_PRIVATE_KEY_FILE=/etc/shadowbox-selfsigned.key" \
      -v "$SHADOWBOX_DIR:/opt/outline" \
      "$DOCKER_IMAGE"
  '

  run_command "Установка Obfsproxy в Docker" bash -c '
    docker run -d --name obfsproxy \
      -p $OBFUSCATION_PORT:$OBFUSCATION_PORT \
      quay.io/outline/obfsproxy obfs3 --dest=127.0.0.1:$VPN_PORT server --listen=0.0.0.0:$OBFUSCATION_PORT
  '
}

setup_encryption_headers() {
  run_command "Настройка шифрования" bash -c '
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
      -keyout /etc/shadowbox-selfsigned.key \
      -out /etc/shadowbox-selfsigned.crt \
      -subj "/CN=OutlineVPN"
  '
}

test_configuration() {
  run_command "Тестирование конфигурации" bash -c '
    if ! docker ps | grep -q shadowbox; then
      echo "Ошибка запуска сервера Outline. Проверьте логи Docker."
      exit 1
    fi
  '
}

output_outline_manager_config() {
  run_command "Генерация строки для Outline Manager" bash -c '
    API_URL="https://$(curl -s https://icanhazip.com):$VPN_PORT/oaUAMa0vlr0ev57n9MmQsA"
    echo "{\"apiUrl\":\"$API_URL\",\"certSha256\":\"$CERT_SHA256\"}"
  '
}

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

  log_success "Конфигурация завершена."
}

main
