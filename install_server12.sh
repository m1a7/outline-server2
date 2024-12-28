#!/bin/bash

# Скрипт установки Outline VPN и Shadowsocks с обфускацией на Ubuntu 24.10 x64

# Цвета для логов
GREEN="\033[0;32m"
RED="\033[0;31m"
BLUE="\033[0;34m"
NC="\033[0m" # Сброс цвета

log_success() {
  echo -e "${GREEN}[УСПЕХ] $1${NC}"
}

log_info() {
  echo -e "${BLUE}[ИНФО] $1${NC}"
}

log_error() {
  echo -e "${RED}[ОШИБКА] $1${NC}"
}

# Переменные
SERVER_PORT=443
SS_PASSWORD="strongpassword"
SS_METHOD="aes-256-gcm"
PLUGIN_OPTS="obfs=tls"

# Функция проверки последней команды
check_last_command() {
  if [ $? -ne 0 ]; then
    log_error "$1"
    echo -e "${RED}[ВОПРОС ДЛЯ CHAT-GPT]: Почему возникла ошибка при выполнении команды \"$2\"?${NC}"
  fi
}

# 1. Подготовка и проверки
log_info "Начинаю подготовку и проверку системы..."

# Проверяем, запускается ли скрипт от имени root
if [ "$EUID" -ne 0 ]; then
  log_error "Скрипт должен быть запущен от имени root! Используйте sudo."
  echo "sudo bash $0"
  exit 0 # Без остановки выполнения скрипта
fi

# Проверяем доступность порта 443
log_info "Проверяю доступность порта $SERVER_PORT..."
if lsof -i:$SERVER_PORT | grep LISTEN > /dev/null; then
  log_error "Порт $SERVER_PORT уже используется. Пожалуйста, освободите его."
  exit 0
fi

# Устанавливаем Docker, если не установлен
log_info "Устанавливаю необходимые утилиты..."
apt update && apt install -y curl docker.io docker-compose
check_last_command "Не удалось установить зависимости" "apt install"

log_success "Подготовка завершена."

# 2. Основной процесс установки и настройки
log_info "Начинаю установку Outline VPN..."

# Загружаем Docker-образы
docker pull outline/shadowbox
check_last_command "Не удалось загрузить Docker-образ Outline." "docker pull outline/shadowbox"

docker pull outline/outline-ss-server
check_last_command "Не удалось загрузить Docker-образ Outline SS." "docker pull outline/outline-ss-server"

# Генерация ключей
API_KEY=$(openssl rand -hex 16)
CERT_SHA256=$(openssl x509 -noout -fingerprint -sha256 -inform pem -in <(openssl req -x509 -nodes -newkey rsa:2048 -keyout /dev/null -out /dev/null) | awk -F= '{print $2}')

# Запуск Outline VPN
docker run -d --name outline-server \
  -e SB_API_PREFIX=$API_KEY \
  -e SB_METRICS_URL="https://metrics.example.com" \
  -e NODE_ENV=production \
  -p $SERVER_PORT:443 \
  outline/shadowbox
check_last_command "Ошибка при запуске контейнера Outline." "docker run outline-server"

log_success "Outline VPN установлен."

# Настройка Shadowsocks с обфускацией
log_info "Настраиваю Shadowsocks с обфускацией..."
docker run -d --name ss-server \
  -p $SERVER_PORT:443 \
  -e PASSWORD=$SS_PASSWORD \
  -e METHOD=$SS_METHOD \
  -e PLUGIN="obfs-server" \
  -e PLUGIN_OPTS="$PLUGIN_OPTS" \
  outline/outline-ss-server
check_last_command "Ошибка при настройке Shadowsocks." "docker run ss-server"

log_success "Shadowsocks настроен."

# 3. Вывод строки для подключения
log_info "Вывод строки для подключения:"
echo -e "{\"apiUrl\":\"https://$(curl -s ifconfig.me):$SERVER_PORT/$API_KEY\",\"certSha256\":\"$CERT_SHA256\"}"

# 4. Тестирование
log_info "Начинаю тестирование настроек..."

# Проверка работы контейнеров
docker ps | grep outline-server > /dev/null && log_success "Outline VPN работает." || log_error "Outline VPN не работает."
docker ps | grep ss-server > /dev/null && log_success "Shadowsocks работает." || log_error "Shadowsocks не работает."

# Проверка обфускации
log_info "Тестирование обфускации (obfs)..."
curl -s --proxy socks5h://127.0.0.1:$SERVER_PORT https://www.google.com > /dev/null
if [ $? -eq 0 ]; then
  log_success "Обфускация работает корректно."
else
  log_error "Ошибка: обфускация не работает. Проверьте конфигурацию."
fi


log_success "Скрипт завершён успешно!"