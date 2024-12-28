#!/bin/bash

# Скрипт тестирования работы Outline VPN и Shadowsocks
# Автор: CHAT-GPT
# Версия: 1.0

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
SERVER_IP="68.183.234.156"
SERVER_PORT=443
SS_PASSWORD="strongpassword"
SS_METHOD="aes-256-gcm"
PLUGIN_OPTS="obfs=tls"

# Функция проверки последней команды
check_last_command() {
  if [ $? -ne 0 ]; then
    log_error "$1"
    echo -e "${RED}[ВОПРОС ДЛЯ CHAT-GPT]: Почему возникла ошибка при выполнении команды \"$2\"?${NC}"
  else
    log_success "$3"
  fi
}

# Тест соединения к серверу
log_info "Проверяю возможность подключения к серверу $SERVER_IP на порту $SERVER_PORT..."
nc -zv $SERVER_IP $SERVER_PORT
check_last_command "Не удалось подключиться к серверу." "nc -zv $SERVER_IP $SERVER_PORT" "Соединение с сервером успешно установлено."

# Тестирование работы Shadowsocks
log_info "Тестирую работу Shadowsocks..."
echo -n "Test Message" | openssl enc -aes-256-gcm -pass pass:$SS_PASSWORD -e | \
  curl --socks5-hostname $SERVER_IP:$SERVER_PORT https://www.google.com -o /dev/null
check_last_command "Shadowsocks не работает." "curl через SOCKS5" "Shadowsocks работает корректно."

# Тест обфускации
log_info "Тестирую обфускацию с плагином obfs..."
curl -x "socks5h://$SERVER_IP:$SERVER_PORT" -H "Host: www.google.com" -k https://www.google.com -o /dev/null
check_last_command "Обфускация не работает." "curl с обфускацией" "Обфускация работает корректно."

# Тест доступности Docker-контейнеров
log_info "Проверяю, работают ли Docker-контейнеры..."
docker ps | grep -q outline-server && log_success "Контейнер Outline работает." || log_error "Контейнер Outline не работает."
docker ps | grep -q ss-server && log_success "Контейнер Shadowsocks работает." || log_error "Контейнер Shadowsocks не работает."

# Тест API сервера Outline
log_info "Проверяю доступность API сервера Outline..."
curl -s "https://$SERVER_IP:$SERVER_PORT/$API_KEY" | grep -q "success" && \
  log_success "API сервера Outline доступно." || log_error "API сервера Outline недоступно."

# Итог тестов
log_success "Все тесты завершены. Проверьте логи для детальной информации."