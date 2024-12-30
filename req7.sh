#!/bin/bash
# Полный скрипт настройки Outline VPN сервера с учетом минимизации следов туннельного соединения
# Работает на Ubuntu 22.04

# ============================= ОФОРМЛЕНИЕ ВЫВОДА =============================
COLOR_RED="\033[0;31m"
COLOR_GREEN="\033[0;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_CYAN="\033[0;36m"
COLOR_NONE="\033[0m"

log_info() {
  echo -e "[${COLOR_CYAN}INFO${COLOR_NONE}] $1"
}

log_success() {
  echo -e "[${COLOR_GREEN}SUCCESS${COLOR_NONE}] $1"
}

log_warn() {
  echo -e "[${COLOR_YELLOW}WARNING${COLOR_NONE}] $1"
}

log_error() {
  echo -e "[${COLOR_RED}ERROR${COLOR_NONE}] $1"
  exit 1
}

run_command() {
  local step_description="$1"
  shift
  log_info "$step_description"
  "$@" || log_error "Шаг '$step_description' не выполнен."
  log_success "Шаг '$step_description' выполнен."
}

# ========================== ПЕРЕМЕННЫЕ ==========================
OUTLINE_API_PORT=8443
OUTLINE_CONTAINER_NAME="shadowbox"
WATCHTOWER_CONTAINER_NAME="watchtower"
SHADOWBOX_DIR="/opt/outline"
ACCESS_CONFIG="$SHADOWBOX_DIR/access.txt"
MTU_VALUE=1500
DOCKER_IMAGE="quay.io/outline/shadowbox:stable"
WATCHTOWER_IMAGE="containrrr/watchtower"
NETWORK_INTERFACE="eth0"
ALL_KEYS=()

# ========================== ПРОВЕРКА СИСТЕМЫ ==========================
log_info "Проверка прав root"
[[ $EUID -ne 0 ]] && log_error "Скрипт должен быть запущен с правами root"

log_info "Обновление системы и установка необходимых пакетов"
apt-get update && apt-get upgrade -y
apt-get install -y curl iptables-persistent docker.io ufw jq net-tools

log_info "Проверка наличия Docker"
if ! command -v docker &>/dev/null; then
  log_info "Docker не найден. Устанавливаю..."
  curl -fsSL https://get.docker.com | sh
fi

log_info "Проверка запуска Docker"
if ! systemctl is-active --quiet docker; then
  log_info "Docker не запущен. Запускаю..."
  systemctl enable docker
  systemctl start docker
fi

# ========================== НАСТРОЙКА СЕТИ ==========================
log_info "Настройка MTU для минимизации следов туннеля"
ifconfig $NETWORK_INTERFACE mtu $MTU_VALUE

log_info "Настройка правил NAT"
iptables -t nat -A POSTROUTING -o $NETWORK_INTERFACE -j MASQUERADE

log_info "Сохранение настроек iptables"
netfilter-persistent save

log_info "Блокировка ICMP (ping) на сервере"
iptables -A INPUT -p icmp --icmp-type echo-request -j DROP
iptables -A OUTPUT -p icmp --icmp-type echo-reply -j DROP
ip6tables -A INPUT -p icmpv6 --icmpv6-type echo-request -j DROP
ip6tables -A OUTPUT -p icmpv6 --icmp-type echo-reply -j DROP
netfilter-persistent save

log_info "Открытие стандартных портов для VPN"
ufw allow 443/tcp
ufw allow 80/tcp
ufw reload

# ========================== УСТАНОВКА OUTLINE ==========================
log_info "Создание каталога для Outline"
mkdir -p "$SHADOWBOX_DIR" && chmod 700 "$SHADOWBOX_DIR"

log_info "Загрузка Docker-образа Outline Server"
docker pull $DOCKER_IMAGE

log_info "Запуск Shadowbox в Docker"
docker run -d \
  --name $OUTLINE_CONTAINER_NAME \
  --restart always \
  --net host \
  -v "$SHADOWBOX_DIR:/opt/outline" \
  -e "SB_API_PORT=$OUTLINE_API_PORT" \
  $DOCKER_IMAGE

log_info "Установка Watchtower для автообновления"
docker pull $WATCHTOWER_IMAGE
docker run -d \
  --name $WATCHTOWER_CONTAINER_NAME \
  --restart always \
  -v /var/run/docker.sock:/var/run/docker.sock \
  $WATCHTOWER_IMAGE --cleanup --interval 3600

# ========================== НАСТРОЙКА БЕЗОПАСНОСТИ ==========================
log_info "Создание самоподписанного сертификата"
CERT_FILE="$SHADOWBOX_DIR/persisted-state/shadowbox-selfsigned.crt"
KEY_FILE="$SHADOWBOX_DIR/persisted-state/shadowbox-selfsigned.key"
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -subj "/CN=$(curl -s ifconfig.me)" \
  -keyout "$KEY_FILE" \
  -out "$CERT_FILE"

log_info "Настройка конфигурационного файла доступа"
API_URL="https://$(curl -s ifconfig.me):$OUTLINE_API_PORT"
CERT_SHA256=$(openssl x509 -in "$CERT_FILE" -noout -sha256 -fingerprint | cut -d= -f2 | tr -d ':')
echo "{"apiUrl":"$API_URL","certSha256":"$CERT_SHA256"}" > "$ACCESS_CONFIG"

# ========================== ПРОВЕРКА СОЕДИНЕНИЯ ==========================
log_info "Проверка доступности VPN сервера"
if curl -sk --max-time 10 "$API_URL" > /dev/null; then
  log_success "Outline VPN успешно запущен."
else
  log_error "Не удалось подключиться к серверу Outline. Проверьте настройки."
fi

# ========================== УСТАНОВКА КЛЮЧЕЙ ДОСТУПА ==========================
log_info "Добавление первого ключа доступа"
ACCESS_KEY=$(curl -sSk --request POST "$API_URL/access-keys" | jq -r .id)
if [ -n "$ACCESS_KEY" ]; then
  ALL_KEYS+=("$ACCESS_KEY")
  log_success "Ключ доступа успешно создан: $ACCESS_KEY"
else
  log_error "Ошибка создания ключа доступа."
fi

log_info "Установка описания ключа доступа"
ACCESS_DESCRIPTION="Default Access Key"
curl -sSk --request PUT "$API_URL/access-keys/$ACCESS_KEY/name" \
  --header "Content-Type: application/json" \
  --data "{"name":"$ACCESS_DESCRIPTION"}"

log_info "Добавление второго ключа доступа (тест)"
ACCESS_KEY_2=$(curl -sSk --request POST "$API_URL/access-keys" | jq -r .id)
if [ -n "$ACCESS_KEY_2" ]; then
  ALL_KEYS+=("$ACCESS_KEY_2")
  log_success "Ключ доступа успешно создан: $ACCESS_KEY_2"
else
  log_error "Ошибка создания второго ключа доступа."
fi

log_info "Установка описания второго ключа доступа"
ACCESS_DESCRIPTION_2="Additional Access Key"
curl -sSk --request PUT "$API_URL/access-keys/$ACCESS_KEY_2/name" \
  --header "Content-Type: application/json" \
  --data "{"name":"$ACCESS_DESCRIPTION_2"}"

# ========================== ВЫВОД ИТОГОВЫХ ДАННЫХ ==========================
log_info "Вывод всех ключей доступа"
echo "Список созданных ключей доступа:"
for key in "${ALL_KEYS[@]}"; do
  echo "- $key"
done

log_info "Вывод информации для подключения Outline Manager"
cat "$ACCESS_CONFIG"

# ========================== ТЕСТИРОВАНИЕ ==========================
log_info "Тестирование доступности ключей доступа"
for key in "${ALL_KEYS[@]}"; do
  RESPONSE=$(curl -sSk "$API_URL/access-keys/$key")
  if [ -n "$RESPONSE" ]; then
    log_success "Ключ $key доступен и работает."
  else
    log_warn "Ключ $key не доступен. Проверьте настройки."
  fi
done

log_success "Установка завершена. Ваш сервер Outline VPN готов к использованию."
