#!/bin/bash

# Этот скрипт удаляет все настройки и компоненты, установленные предыдущим скриптом для настройки VPN-сервера.
# Выполняет полную очистку системы от VPN-конфигурации и связанных пакетов.

set -e

# Цвета для логирования
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
NC="\033[0m" # No Color

# Константы
MTU_DEFAULT=1500
NAT_INTERFACE=eth0
SHADOWBOX_DIR="/opt/outline"
DOCKER_IMAGE="quay.io/outline/shadowbox:stable"
VPN_PORT=443
OBFUSCATION_PORT=8443

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

# Функция для остановки и удаления Docker контейнера
remove_docker_container() {
  log_info "Остановка и удаление Docker контейнера Shadowbox..."
  if docker ps -a | grep -q shadowbox; then
    docker stop shadowbox
    docker rm shadowbox
    log_info "Docker контейнер Shadowbox успешно удален."
  else
    log_info "Docker контейнер Shadowbox не найден."
  fi
}

# Функция для удаления установленных пакетов
remove_installed_packages() {
  log_info "Удаление пакетов obfsproxy и Docker..."

  # Удаление obfsproxy
  if dpkg -l | grep -q obfsproxy; then
    apt-get remove -y obfsproxy
    log_info "Пакет obfsproxy успешно удален."
  else
    log_info "Пакет obfsproxy не установлен."
  fi

  # Удаление Docker
  if command -v docker &> /dev/null; then
    apt-get purge -y docker-ce docker-ce-cli containerd.io
    apt-get autoremove -y
    rm -rf /var/lib/docker
    rm -rf /etc/docker
    log_info "Docker успешно удален."
  else
    log_info "Docker не установлен."
  fi
}

# Функция для удаления сертификатов
remove_certificates() {
  log_info "Удаление сертификатов..."
  rm -f /etc/shadowbox-selfsigned.key /etc/shadowbox-selfsigned.crt
  log_info "Сертификаты успешно удалены."
}

# Функция для сброса MTU
reset_mtu() {
  log_info "Сброс MTU на значение по умолчанию ($MTU_DEFAULT)..."
  ip link set dev $NAT_INTERFACE mtu $MTU_DEFAULT
  log_info "MTU успешно сброшен."
}

# Функция для сброса NAT
reset_nat() {
  log_info "Сброс правил NAT..."
  iptables -t nat -D POSTROUTING -o $NAT_INTERFACE -j MASQUERADE || log_warning "Правило NAT не найдено."
  log_info "Правила NAT успешно сброшены."
}

# Функция для сброса ICMP
reset_icmp() {
  log_info "Сброс правил ICMP..."
  iptables -D INPUT -p icmp --icmp-type echo-request -j DROP || log_warning "Правило ICMP INPUT не найдено."
  iptables -D OUTPUT -p icmp --icmp-type echo-reply -j DROP || log_warning "Правило ICMP OUTPUT не найдено."
  log_info "Правила ICMP успешно сброшены."
}

# Функция для сброса правил портов
reset_ports() {
  log_info "Сброс правил для портов $VPN_PORT и $OBFUSCATION_PORT..."
  iptables -D INPUT -p tcp --dport $VPN_PORT -j ACCEPT || log_warning "Правило для TCP $VPN_PORT не найдено."
  iptables -D INPUT -p udp --dport $VPN_PORT -j ACCEPT || log_warning "Правило для UDP $VPN_PORT не найдено."
  iptables -D INPUT -p tcp --dport $OBFUSCATION_PORT -j ACCEPT || log_warning "Правило для TCP $OBFUSCATION_PORT не найдено."
  iptables -D INPUT -p udp --dport $OBFUSCATION_PORT -j ACCEPT || log_warning "Правило для UDP $OBFUSCATION_PORT не найдено."
  log_info "Правила для портов успешно сброшены."
}

# Функция для удаления оставшихся файлов
clean_remaining_files() {
  log_info "Удаление оставшихся файлов и директорий..."
  rm -rf "$SHADOWBOX_DIR"
  log_info "Директория $SHADOWBOX_DIR успешно удалена."
}

# Основная функция
main() {
  remove_docker_container
  remove_installed_packages
  remove_certificates
  reset_mtu
  reset_nat
  reset_icmp
  reset_ports
  clean_remaining_files

  log_info "Очистка завершена. Система возвращена к исходному состоянию."
}

main
