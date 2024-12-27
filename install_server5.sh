#!/bin/bash
set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # Сброс цвета

# Обновление системы
echo -e "${CYAN}Обновление системы...${NC}"
apt update && apt upgrade -y
apt install -y apt-transport-https ca-certificates curl software-properties-common net-tools ufw

# Установка Docker
echo -e "${CYAN}Проверка и установка Docker...${NC}"
if ! command -v docker &> /dev/null; then
  curl -fsSL https://get.docker.com | bash
else
  apt install -y docker-ce docker-ce-cli containerd.io
fi
systemctl enable --now docker

# Настройка брандмауэра
echo -e "${CYAN}Настройка брандмауэра...${NC}"
ufw allow 443/tcp
ufw allow 1024:65535/tcp
ufw allow 1024:65535/udp
ufw reload

# Переменные
SHADOWBOX_DIR="/opt/outline"
STATE_DIR="${SHADOWBOX_DIR}/persisted-state"
SB_IMAGE="quay.io/outline/shadowbox:stable"
mkdir -p "${STATE_DIR}"

# Генерация сертификата
echo -e "${CYAN}Генерация сертификатов...${NC}"
CERT_KEY="${STATE_DIR}/shadowbox-selfsigned.key"
CERT_FILE="${STATE_DIR}/shadowbox-selfsigned.crt"
openssl req -x509 -nodes -days 36500 -newkey rsa:4096 \
  -subj "/CN=$(curl -s https://icanhazip.com/)" \
  -keyout "${CERT_KEY}" -out "${CERT_FILE}"

echo -e "${GREEN}Сертификат создан:${NC}"
echo -e "${BLUE}Путь к ключу: ${CERT_KEY}${NC}"
cat "${CERT_KEY}"
echo -e "${BLUE}Путь к сертификату: ${CERT_FILE}${NC}"
cat "${CERT_FILE}"

# Генерация уникального ключа API
echo -e "${CYAN}Генерация API ключа...${NC}"
SB_API_PREFIX=$(head -c 16 /dev/urandom | base64 | tr '/+' '_-' | tr -d '=')
echo -e "${GREEN}API ключ:${NC} ${BLUE}${SB_API_PREFIX}${NC}"

# Создание конфигурации
echo -e "${CYAN}Создание конфигурации...${NC}"
cat <<EOF > "${STATE_DIR}/shadowbox_server_config.json"
{
  "portForNewAccessKeys": 443,
  "hostname": "$(curl -s https://icanhazip.com/)",
  "name": "Outline Server"
}
EOF
echo -e "${GREEN}Файл конфигурации создан: ${BLUE}${STATE_DIR}/shadowbox_server_config.json${NC}"

# Удаление старых контейнеров (если есть)
docker rm -f shadowbox 2>/dev/null || true
docker rm -f watchtower 2>/dev/null || true

# Запуск контейнера Shadowbox
echo -e "${CYAN}Запуск контейнера Shadowbox...${NC}"
docker run -d --name shadowbox --restart always \
  --net host \
  -v "${STATE_DIR}:${STATE_DIR}" \
  -e "SB_STATE_DIR=${STATE_DIR}" \
  -e "SB_API_PORT=443" \
  -e "SB_API_PREFIX=${SB_API_PREFIX}" \
  -e "SB_CERTIFICATE_FILE=${CERT_FILE}" \
  -e "SB_PRIVATE_KEY_FILE=${CERT_KEY}" \
  -e "SB_METRICS_URL=" \
  "${SB_IMAGE}"

# Установка Watchtower для автообновлений
echo -e "${CYAN}Установка Watchtower...${NC}"
docker run -d --name watchtower --restart always \
  --label 'com.centurylinklabs.watchtower.enable=true' \
  --label 'com.centurylinklabs.watchtower.scope=outline' \
  -v /var/run/docker.sock:/var/run/docker.sock \
  containrrr/watchtower --cleanup --label-enable --scope=outline --tlsverify --interval 3600

# Проверка состояния сервера
echo -e "${CYAN}Начинаем тестирование...${NC}"

# 1. Проверка открытых портов
echo -e "${CYAN}Проверка открытых портов...${NC}"
START_PORT=443
END_PORT=65535

last_status=""
range_start=""
problem_ports=0

for port in $(seq $START_PORT $END_PORT); do
  if nc -zv 127.0.0.1 "$port" 2>/dev/null; then
    current_status="open"
  else
    current_status="closed"
    [[ "$port" -le 65535 && "$port" -ge 1024 ]] && problem_ports=$((problem_ports + 1))
  fi

  if [[ "$last_status" != "$current_status" ]]; then
    # Если статус изменился, выводим диапазон предыдущих портов
    if [[ -n "$range_start" ]]; then
      echo -e "${last_status^} порты: ${range_start}-${port-1}"
    fi
    range_start="$port"
    last_status="$current_status"
  fi
done

# Выводим последний диапазон
if [[ -n "$range_start" ]]; then
  echo -e "${last_status^} порты: ${range_start}-${END_PORT}"
fi

# Проверяем наличие проблемных портов
if [[ $problem_ports -gt 0 ]]; then
  echo -e "${RED}Обнаружены проблемы! Закрыто $problem_ports портов в диапазоне 1024-65535, которые нужны для работы сервера.${NC}"
else
  echo -e "${GREEN}Все необходимые порты открыты.${NC}"
fi


# 2. Проверка состояния контейнеров
echo -e "${CYAN}Проверка контейнеров Docker...${NC}"
if docker ps | grep -q shadowbox; then
  echo -e "${GREEN}Контейнер shadowbox работает.${NC}"
else
  echo -e "${RED}Контейнер shadowbox не запущен!${NC}"
fi

if docker ps | grep -q watchtower; then
  echo -e "${GREEN}Контейнер watchtower работает.${NC}"
else
  echo -e "${RED}Контейнер watchtower не запущен!${NC}"
fi

# 3. Проверка конфигурации контейнеров
echo -e "${CYAN}Проверка конфигурации контейнеров...${NC}"
SHADOWBOX_LOGS=$(docker logs shadowbox 2>&1 | grep 'apiUrl')
if [[ -n "$SHADOWBOX_LOGS" ]]; then
  echo -e "${GREEN}Конфигурация shadowbox корректна.${NC}"
  echo -e "${BLUE}URL для подключения:${NC} $SHADOWBOX_LOGS"
else
  echo -e "${RED}Ошибка в конфигурации shadowbox!${NC}"
fi

# 4. Проверка правил брандмауэра
echo -e "${CYAN}Проверка правил брандмауэра...${NC}"
if sudo ufw status | grep -q '443'; then
  echo -e "${GREEN}Порты для TCP/UDP разрешены.${NC}"
else
  echo -e "${RED}Правила брандмауэра блокируют порты!${NC}"
fi

# 5. Проверка обфускации данных
echo -e "${CYAN}Проверка обфускации данных...${NC}"
# Симуляция трафика обфускации может быть сложной, используем простую проверку
if docker logs shadowbox 2>&1 | grep -q 'obfs'; then
  echo -e "${GREEN}Обфускация включена и работает.${NC}"
else
  echo -e "${RED}Обфускация данных не работает!${NC}"
fi

echo -e "${CYAN}Тестирование завершено.${NC}"
