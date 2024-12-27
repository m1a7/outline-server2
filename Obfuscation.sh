#!/bin/bash

# Функция для проверки состояния контейнера shadowbox
check_shadowbox_container() {
    echo "Проверка контейнера shadowbox..."
    if ! docker ps | grep -q shadowbox; then
        echo "Контейнер shadowbox не запущен. Запустите контейнер командой:"
        echo "docker start shadowbox"
        exit 1
    else
        echo "Контейнер shadowbox работает."
    fi
}

# Функция для проверки состояния портов
check_ports() {
    echo "Проверка открытых портов..."
    PORTS=("443" "8843" "8443")
    for PORT in "${PORTS[@]}"; do
        if ! nc -zv 127.0.0.1 $PORT &>/dev/null; then
            echo "Порт $PORT недоступен. Убедитесь, что он открыт в настройках брандмауэра."
        else
            echo "Порт $PORT доступен."
        fi
    done
}

# Функция для проверки обфускации
check_obfuscation() {
    echo "Проверка обфускации данных..."
    OBFUSCATION_LOG=$(docker logs shadowbox 2>&1 | grep -i 'obfs')

    if [[ -z "$OBFUSCATION_LOG" ]]; then
        echo "Обфускация данных не работает. Проверьте настройки контейнера."
    else
        echo "Обфускация работает корректно."
    fi
}

# Функция для проверки брандмауэра
check_firewall() {
    echo "Проверка правил брандмауэра..."
    if ! sudo ufw status | grep -q "ALLOW"; then
        echo "Порты блокируются брандмауэром. Разрешите порты командой:"
        echo "sudo ufw allow 443"
        echo "sudo ufw allow 8843"
        echo "sudo ufw allow 8443"
    else
        echo "Брандмауэр настроен корректно."
    fi
}

# Основной блок выполнения
echo "Запуск проверки сервера Outline..."
check_shadowbox_container
check_ports
check_obfuscation
check_firewall
echo "Проверка завершена."
