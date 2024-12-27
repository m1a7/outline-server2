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

# Проверка наличия Docker
if ! command -v docker &> /dev/null; then
  echo -e "${RED}Docker не установлен на этом сервере.${NC}"
  exit 1
fi

echo -e "${CYAN}Проверка Docker-контейнеров...${NC}"

# Проверка, запущен ли контейнер с Shadowbox
SHADOWBOX_CONTAINER=$(docker ps --filter "name=shadowbox" --format "{{.ID}}")
if [[ -z $SHADOWBOX_CONTAINER ]]; then
    echo -e "${RED}Контейнер с Shadowbox не найден.${NC}"
    exit 1
else
    echo -e "${CYAN}Найден контейнер Shadowbox: $SHADOWBOX_CONTAINER${NC}"
fi

# Извлечение конфигурации из контейнера
CONFIG_PATH="/root/shadowbox/config.json"
echo -e "${CYAN}Проверка конфигурации внутри контейнера...${NC}"
docker exec $SHADOWBOX_CONTAINER cat $CONFIG_PATH > /tmp/shadowbox_config.json
if [[ $? -ne 0 ]]; then
    echo -e "${RED}Не удалось получить конфигурацию из контейнера.${NC}"
    exit 1
fi

if grep -q "plugin" /tmp/shadowbox_config.json; then
    echo -e "${GREEN}Обфускация включена в конфигурации Shadowbox.${NC}"
else
    echo -e "${RED}Обфускация не настроена в конфигурации Shadowbox.${NC}"
fi
rm -f /tmp/shadowbox_config.json

# Анализ трафика на указанных портах
for PORT in $PORT_8843 $PORT_443; do
    echo -e "${CYAN}Анализ трафика на порту $PORT...${NC}"
    docker run --rm --net=host nicolaka/netshoot tcpdump -i any port $PORT -c 10 -nn -v &> /tmp/tcpdump_$PORT.log
    if grep -q "TLS" /tmp/tcpdump_$PORT.log; then
        echo -e "${GREEN}Обнаружен TLS-трафик на порту $PORT. Это может указывать на обфускацию.${NC}"
    else
        echo -e "${RED}Не обнаружено TLS-трафика на порту $PORT. Обфускация может отсутствовать.${NC}"
    fi
    rm -f /tmp/tcpdump_$PORT.log
done

echo -e "${CYAN}Проверка завершена.${NC}"
