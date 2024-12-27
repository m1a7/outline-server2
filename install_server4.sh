#!/bin/bash
set -euo pipefail

# Обновление системы
apt update && apt upgrade -y
apt install -y apt-transport-https ca-certificates curl software-properties-common net-tools ufw

# Установка Docker
if ! command -v docker &> /dev/null; then
  curl -fsSL https://get.docker.com | bash
else
  apt install -y docker-ce docker-ce-cli containerd.io
fi
systemctl enable --now docker

# Настройка брандмауэра
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
openssl req -x509 -nodes -days 36500 -newkey rsa:4096 \
  -subj "/CN=$(curl -s https://icanhazip.com/)" \
  -keyout "${STATE_DIR}/shadowbox-selfsigned.key" -out "${STATE_DIR}/shadowbox-selfsigned.crt"

# Генерация уникального ключа API
SB_API_PREFIX=$(head -c 16 /dev/urandom | base64 | tr '/+' '_-' | tr -d '=')

# Создание конфигурации
cat <<EOF > "${STATE_DIR}/shadowbox_server_config.json"
{
  "portForNewAccessKeys": 443,
  "hostname": "$(curl -s https://icanhazip.com/)",
  "name": "Outline Server"
}
EOF

# Удаление старых контейнеров (если есть)
docker rm -f shadowbox 2>/dev/null || true
docker rm -f watchtower 2>/dev/null || true

# Запуск контейнера Shadowbox
docker run -d --name shadowbox --restart always \
  --net host \
  -v "${STATE_DIR}:${STATE_DIR}" \
  -e "SB_STATE_DIR=${STATE_DIR}" \
  -e "SB_API_PORT=443" \
  -e "SB_API_PREFIX=${SB_API_PREFIX}" \
  -e "SB_CERTIFICATE_FILE=${STATE_DIR}/shadowbox-selfsigned.crt" \
  -e "SB_PRIVATE_KEY_FILE=${STATE_DIR}/shadowbox-selfsigned.key" \
  -e "SB_METRICS_URL=" \
  "${SB_IMAGE}"

# Установка Watchtower для автообновлений
docker run -d --name watchtower --restart always \
  --label 'com.centurylinklabs.watchtower.enable=true' \
  --label 'com.centurylinklabs.watchtower.scope=outline' \
  -v /var/run/docker.sock:/var/run/docker.sock \
  containrrr/watchtower --cleanup --label-enable --scope=outline --tlsverify --interval 3600

# Вывод конфигурации
if docker ps | grep -q shadowbox; then
  echo "Outline сервер успешно запущен. Конфигурация:"
  echo "{\"apiUrl\":\"https://$(curl -s https://icanhazip.com/):443/${SB_API_PREFIX}\",\"certSha256\":\"$(openssl x509 -in ${STATE_DIR}/shadowbox-selfsigned.crt -noout -sha256 -fingerprint | cut -d'=' -f2 | tr -d ':')\"}"
else
  echo "Ошибка запуска Outline сервера. Проверьте логи Docker."
fi
