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
ufw --force enable
ufw allow 443/tcp
ufw allow 1024:65535/tcp
ufw allow 1024:65535/udp
ufw reload

# Включение брандмауэра и разрешение всех соединений
# Включение и настройка Firewall
echo -e "${CYAN}Настройка Firewall и брандмауэра...${NC}"
ufw default allow incoming
ufw default allow outgoing

# Установка правил для порта 443
# UFW
if ! sudo ufw status | grep -q "443/tcp"; then
  echo -e "${CYAN}Добавление правила для порта 443 через ufw...${NC}"
  sudo ufw allow 443/tcp
else
  echo -e "${GREEN}Правило для порта 443 уже существует в ufw.${NC}"
fi
sudo ufw reload


# Дополнительная настройка iptables
# IPTables
if ! sudo iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null; then
  echo -e "${CYAN}Добавление правила для порта 443 в iptables...${NC}"
  sudo iptables -I INPUT -p tcp --dport 443 -j ACCEPT
else
  echo -e "${GREEN}Правило для порта 443 уже существует в iptables.${NC}"
fi


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

# Вывод информации о сертификатах
echo -e "${GREEN}Сертификат создан:${NC}"
echo -e "${BLUE}Путь к ключу: ${CERT_KEY}${NC}"
echo -e "${BLUE}Путь к сертификату: ${CERT_FILE}${NC}"

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

# Удаление старых контейнеров
docker rm -f shadowbox 2>/dev/null || true
docker rm -f watchtower 2>/dev/null || true

# Проверка и освобождение порта 443
echo -e "${CYAN}Проверка использования порта 443...${NC}"
if lsof -i :443 &>/dev/null; then
  echo -e "${RED}Порт 443 уже используется!${NC}"
  echo -e "${CYAN}Процессы, использующие порт 443:${NC}"
  lsof -i :443
  echo -e "${CYAN}Попытка завершить процессы, использующие порт 443...${NC}"
  lsof -i :443 | awk 'NR>1 {print $2}' | xargs -r kill -9
  echo -e "${GREEN}Процессы, использующие порт 443, были завершены.${NC}"
else
  echo -e "${GREEN}Порт 443 свободен.${NC}"
fi

# Проверка открытых портов
echo -e "${CYAN}Проверка открытых портов...${NC}"
if nc -zv 127.0.0.1 443 &> /dev/null; then
  echo -e "${GREEN}Порт 443 доступен.${NC}"
else
  echo -e "${RED}Порт 443 недоступен.${NC}"
  echo -e "${CYAN}Попытка открыть порт 443...${NC}"
  ufw allow 443/tcp && ufw reload
  if nc -zv 127.0.0.1 443 &> /dev/null; then
    echo -e "${GREEN}Порт 443 успешно открыт.${NC}"
  else
    echo -e "${RED}Не удалось открыть порт 443. Проверьте настройки вручную.${NC}"
  fi
fi

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
  "${SB_IMAGE}" || echo -e "${RED}Ошибка запуска контейнера shadowbox.${NC}"

# Установка Watchtower
echo -e "${CYAN}Установка Watchtower...${NC}"
docker run -d --name watchtower --restart always \
  --label 'com.centurylinklabs.watchtower.enable=true' \
  --label 'com.centurylinklabs.watchtower.scope=outline' \
  -v /var/run/docker.sock:/var/run/docker.sock \
  containrrr/watchtower --cleanup --label-enable --scope=outline --tlsverify --interval 3600 || echo -e "${RED}Ошибка запуска Watchtower.${NC}"

# Проверка состояния сервера
echo -e "${CYAN}Начинаем тестирование...${NC}"

# Логирование процессов, использующих порт 443
if lsof -i :443 &>/dev/null; then
  echo -e "${CYAN}Процессы, использующие порт 443:${NC}"
  lsof -i :443
  echo -e "${RED}Ручная проверка требуется!${NC}"
  exit 1
fi

# Проверка контейнеров
# Проверка конфигурации контейнеров
echo -e "${CYAN}Проверка конфигурации контейнеров...${NC}"
SHADOWBOX_LOGS=$(docker logs shadowbox 2>&1 | grep 'apiUrl' || true)
if [[ -n "$SHADOWBOX_LOGS" ]]; then
  echo -e "${GREEN}Конфигурация shadowbox корректна.${NC}"
  echo -e "${BLUE}URL для подключения:${NC} $SHADOWBOX_LOGS"
else
  echo -e "${RED}Ошибка в конфигурации shadowbox!${NC}"
  echo -e "${CYAN}Подробные логи shadowbox:${NC}"
  docker logs shadowbox || echo -e "${RED}Не удалось получить логи shadowbox.${NC}"
fi

if docker ps | grep -q watchtower; then
  echo -e "${GREEN}Контейнер watchtower работает.${NC}"
else
  echo -e "${RED}Контейнер watchtower не запущен!${NC}"
  docker logs watchtower || true
fi

# Проверка конфигурации контейнеров
echo -e "${CYAN}Проверка конфигурации контейнеров...${NC}"
SHADOWBOX_LOGS=$(docker logs shadowbox 2>&1 | grep 'apiUrl' || true)
if [[ -n "$SHADOWBOX_LOGS" ]]; then
  echo -e "${GREEN}Конфигурация shadowbox корректна.${NC}"
  echo -e "${BLUE}URL для подключения:${NC} $SHADOWBOX_LOGS"
else
  echo -e "${RED}Ошибка в конфигурации shadowbox!${NC}"
fi

sudo ufw reload

# Проверка правил брандмауэра
echo -e "${CYAN}Проверка правил брандмауэра...${NC}"
if sudo ufw status | grep -q '443'; then
  echo -e "${GREEN}Порты для TCP/UDP разрешены.${NC}"
else
  echo -e "${RED}Правила брандмауэра блокируют порты!${NC}"
fi

# Проверка обфускации данных
echo -e "${CYAN}Проверка обфускации данных...${NC}"
if docker logs shadowbox 2>&1 | grep -q 'obfs'; then
  echo -e "${GREEN}Обфускация включена и работает.${NC}"
else
  echo -e "${RED}Обфускация данных не работает!${NC}"
  echo -e "${CYAN}Диагностика причин:${NC}"
  SHADOWBOX_OBFS_LOGS=$(docker logs shadowbox 2>&1 | grep -i 'error\|warn' || true)
  if [[ -n "$SHADOWBOX_OBFS_LOGS" ]]; then
    echo -e "${RED}Найдены ошибки или предупреждения:${NC}"
    echo -e "$SHADOWBOX_OBFS_LOGS"
  else
    echo -e "${CYAN}Логи обфускации не содержат явных ошибок. Проверьте настройки контейнера.${NC}"
  fi
fi
echo -e "${CYAN}Тестирование завершено.${NC}"

# Вывод конфигурации для Outline Manager
API_URL="https://$(curl -s https://icanhazip.com/):443/${SB_API_PREFIX}"
CERT_SHA256=$(openssl x509 -in "${CERT_FILE}" -noout -sha256 -fingerprint | cut -d'=' -f2 | tr -d ':')
CONFIG_STRING="{apiUrl:${API_URL},certSha256:${CERT_SHA256}}"
echo -e "${CYAN}Конфигурация для Outline Manager:${NC}"
echo -e "${GREEN}${CONFIG_STRING}${NC}"

# Вывод путей к созданным файлам
echo -e "${CYAN}Созданные файлы и пути:${NC}"
echo -e "${BLUE}Ключ: ${CERT_KEY}${NC}"
echo -e "${BLUE}Сертификат: ${CERT_FILE}${NC}"
echo -e "${BLUE}Файл конфигурации: ${STATE_DIR}/shadowbox_server_config.json${NC}"

# Вывод тестовых команд
echo -e "${CYAN}Тестовые команды для проверки настроек:${NC}"
echo -e "${BLUE}# Проверить доступность портов${NC}"
echo "sudo ufw status"
echo "nc -zv 127.0.0.1 443"

echo -e "${BLUE}# Проверить запущенные контейнеры${NC}"
echo "docker ps"

echo -e "${BLUE}# Проверить конфигурацию shadowbox${NC}"
echo "docker logs shadowbox | grep 'apiUrl'"

echo -e "${BLUE}# Проверить обфускацию${NC}"
echo "docker logs shadowbox | grep 'obfs'"

# Завершение
echo -e "${CYAN}Скрипт выполнен успешно.${NC}"
