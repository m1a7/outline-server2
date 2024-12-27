#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # Без цвета

# Функция для проверки состояния контейнера shadowbox
check_shadowbox_container() {
    echo -e "${BLUE}Проверка контейнера shadowbox...${NC}"
    if ! docker ps | grep -q shadowbox; then
        echo -e "${RED}Контейнер shadowbox не запущен.${NC}"
        echo "Запустите контейнер командой:"
        echo -e "${YELLOW}docker start shadowbox${NC}"
        exit 1
    else
        echo -e "${GREEN}Контейнер shadowbox работает.${NC}"
    fi
}

# Функция для проверки состояния портов
check_ports() {
    echo -e "${BLUE}Проверка открытых портов...${NC}"
    PORTS=("443" "8843" "8443")
    for PORT in "${PORTS[@]}"; do
        if ! nc -zv 127.0.0.1 $PORT &>/dev/null; then
            echo -e "${RED}Порт $PORT недоступен.${NC}"
            echo "Убедитесь, что он открыт в настройках брандмауэра."
        else
            echo -e "${GREEN}Порт $PORT доступен.${NC}"
            # Показать, кто использует порт
            PROCESS_INFO=$(lsof -i :$PORT)
            if [[ -n "$PROCESS_INFO" ]]; then
                echo -e "${YELLOW}Порт $PORT используется следующими процессами:${NC}"
                echo "$PROCESS_INFO"
            else
                echo -e "${GREEN}Порт $PORT свободен.${NC}"
            fi
        fi
    done
}

# Функция для проверки обфускации
check_obfuscation() {
    echo -e "${BLUE}Проверка обфускации данных...${NC}"
    OBFUSCATION_LOG=$(docker logs shadowbox 2>&1 | grep -i 'obfs')

    if [[ -z "$OBFUSCATION_LOG" ]]; then
        echo -e "${RED}Обфускация данных не работает.${NC}"
        echo "Проверьте настройки контейнера. Последние логи shadowbox:"
        docker logs shadowbox | tail -n 20
    else
        echo -e "${GREEN}Обфускация работает корректно.${NC}"
        echo "Логи обфускации:"
        echo "$OBFUSCATION_LOG"
    fi
}

# Функция для проверки брандмауэра
check_firewall() {
    echo -e "${BLUE}Проверка правил брандмауэра...${NC}"
    if ! sudo ufw status | grep -q "ALLOW"; then
        echo -e "${RED}Порты блокируются брандмауэром.${NC}"
        echo "Разрешите порты командой:"
        echo -e "${YELLOW}sudo ufw allow 443${NC}"
        echo -e "${YELLOW}sudo ufw allow 8843${NC}"
        echo -e "${YELLOW}sudo ufw allow 8443${NC}"
    else
        echo -e "${GREEN}Брандмауэр настроен корректно.${NC}"
    fi
}

# Основной блок выполнения
echo -e "${BLUE}Запуск проверки сервера Outline...${NC}"
check_shadowbox_container
check_ports
check_obfuscation
check_firewall
echo -e "${GREEN}Проверка завершена.${NC}"
