#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m' # Сброс цвета

# Проверка прав пользователя
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Этот скрипт должен быть запущен с правами root!${NC}" 1>&2
   exit 1
fi

# Параметры подключения
SERVER_IP="134.209.178.97"
PORT_8843="8843"
PORT_443="443"

# Проверка наличия Shadowsocks
if ! command -v ss-server &> /dev/null; then
  echo -e "${RED}Shadowsocks не установлен на этом сервере.${NC}"
  exit 1
fi

echo -e "${CYAN}Проверка обфускации на сервере...${NC}"

# Проверка настроек Shadowsocks
SS_CONFIG_FILE="/etc/shadowsocks-libev/config.json"
if [[ -f $SS_CONFIG_FILE ]]; then
    echo -e "${CYAN}Конфигурационный файл найден: $SS_CONFIG_FILE${NC}"
    if grep -q "plugin" $SS_CONFIG_FILE; then
        echo -e "${GREEN}Обфускация включена в конфигурации Shadowsocks.${NC}"
    else
        echo -e "${RED}Обфускация не настроена в конфигурации Shadowsocks.${NC}"
    fi
else
    echo -e "${RED}Конфигурационный файл Shadowsocks не найден.${NC}"
fi

# Анализ трафика на указанных портах
for PORT in $PORT_8843 $PORT_443; do
    echo -e "${CYAN}Анализ трафика на порту $PORT...${NC}"
    tcpdump -i any port $PORT -c 10 -nn -v &> /tmp/tcpdump_$PORT.log
    if grep -q "TLS" /tmp/tcpdump_$PORT.log; then
        echo -e "${GREEN}Обнаружен TLS-трафик на порту $PORT. Это может указывать на обфускацию.${NC}"
    else
        echo -e "${RED}Не обнаружено TLS-трафика на порту $PORT. Обфускация может отсутствовать.${NC}"
    fi
    rm -f /tmp/tcpdump_$PORT.log
done

echo -e "${CYAN}Проверка завершена.${NC}"
