#!/bin/bash

# Скрипт удаления Outline VPN и Shadowsocks с сервера Ubuntu 24.10 x64
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

# Проверка запуска от имени root
if [ "$EUID" -ne 0 ]; then
  log_error "Скрипт должен быть запущен от имени root! Используйте sudo."
  echo "sudo bash $0"
  exit 0
fi

log_info "Начинаю процесс удаления всех компонентов..."

# 1. Остановка и удаление Docker-контейнеров
log_info "Останавливаю Docker-контейнеры..."
docker stop outline-server ss-server 2>/dev/null || log_info "Контейнеры уже остановлены."
docker rm outline-server ss-server 2>/dev/null || log_info "Контейнеры уже удалены."

# 2. Удаление Docker-образов
log_info "Удаляю Docker-образы..."
docker rmi outline/shadowbox outline/outline-ss-server 2>/dev/null || log_info "Образы уже удалены."

# 3. Удаление установленных пакетов
log_info "Удаляю установленные пакеты Docker..."
apt remove --purge -y docker.io docker-compose 2>/dev/null
apt autoremove -y 2>/dev/null
apt clean

# 4. Удаление ключей и сертификатов
log_info "Удаляю ключи и сертификаты..."
CERT_PATH="/etc/outline-vpn"
if [ -d "$CERT_PATH" ]; then
  rm -rf "$CERT_PATH"
  log_success "Ключи и сертификаты удалены."
else
  log_info "Ключи и сертификаты отсутствуют или уже удалены."
fi

# 5. Очистка кэша Docker
log_info "Очищаю кэш Docker..."
docker system prune -af --volumes 2>/dev/null

# 6. Проверка успешного удаления
log_info "Проверка успешного удаления..."
if ! docker ps -a | grep -q outline-server && ! docker images | grep -q outline; then
  log_success "Все компоненты Docker удалены."
else
  log_error "Некоторые компоненты Docker не были удалены. Проверьте вручную."
fi

if ! dpkg -l | grep -q docker; then
  log_success "Docker и связанные пакеты успешно удалены."
else
  log_error "Docker не был полностью удалён. Проверьте вручную."
fi

# Итог
log_success "Процесс удаления завершён. Сервер полностью очищен."