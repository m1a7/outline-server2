#!/bin/bash
#
# Установка Outline с использованием порта 443 и поддержкой обфускации

set -euo pipefail

# Обновление системы и установка необходимых зависимостей
apt update && apt upgrade -y
apt install -y apt-transport-https ca-certificates curl software-properties-common

# Убедитесь, что Docker установлен и обновлен
if ! command -v docker &> /dev/null; then
  echo "Docker не установлен. Устанавливаю..."
  curl -fsSL https://get.docker.com | bash
else
  echo "Docker уже установлен. Проверяю обновления..."
  apt install -y docker-ce docker-ce-cli containerd.io
fi

# Запуск Docker, если он не работает
systemctl enable --now docker.service

# Параметры установки
SHADOWBOX_DIR="/opt/outline"
CONTAINER_NAME="shadowbox"
SB_IMAGE="quay.io/outline/shadowbox:stable"
API_PORT=443
KEYS_PORT=443
ACCESS_CONFIG="${SHADOWBOX_DIR}/access.txt"

# Создание рабочего каталога
mkdir -p "${SHADOWBOX_DIR}"
chmod u+s,ug+rwx,o-rwx "${SHADOWBOX_DIR}"

# Генерация секретного ключа
SB_API_PREFIX=$(head -c 16 /dev/urandom | base64 | tr '/+' '_-' | tr -d '=')

# Создание сертификатов TLS
STATE_DIR="${SHADOWBOX_DIR}/persisted-state"
mkdir -p "${STATE_DIR}"
CERTIFICATE_NAME="${STATE_DIR}/shadowbox-selfsigned"
SB_CERTIFICATE_FILE="${CERTIFICATE_NAME}.crt"
SB_PRIVATE_KEY_FILE="${CERTIFICATE_NAME}.key"
openssl req -x509 -nodes -days 36500 -newkey rsa:4096 \
  -subj "/CN=$(curl -s https://icanhazip.com/)" \
  -keyout "${SB_PRIVATE_KEY_FILE}" -out "${SB_CERTIFICATE_FILE}"

# Создание конфигурации
cat <<EOF > "${STATE_DIR}/shadowbox_server_config.json"
{
  "portForNewAccessKeys": ${KEYS_PORT},
  "hostname": "$(curl -s https://icanhazip.com/)",
  "name": "Outline Server"
}
EOF

# Удаление предыдущих контейнеров (если есть)
docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
docker rm -f watchtower 2>/dev/null || true

# Запуск Shadowbox контейнера
docker run -d --name "${CONTAINER_NAME}" --restart always --net host \
  --label 'com.centurylinklabs.watchtower.enable=true' \
  --label 'com.centurylinklabs.watchtower.scope=outline' \
  --log-driver local \
  -v "${STATE_DIR}:${STATE_DIR}" \
  -e "SB_STATE_DIR=${STATE_DIR}" \
  -e "SB_API_PORT=${API_PORT}" \
  -e "SB_API_PREFIX=${SB_API_PREFIX}" \
  -e "SB_CERTIFICATE_FILE=${SB_CERTIFICATE_FILE}" \
  -e "SB_PRIVATE_KEY_FILE=${SB_PRIVATE_KEY_FILE}" \
  "${SB_IMAGE}"

# Установка Watchtower для автоматического обновления контейнеров
docker run -d --name watchtower --restart always \
  --label 'com.centurylinklabs.watchtower.enable=true' \
  --label 'com.centurylinklabs.watchtower.scope=outline' \
  -v /var/run/docker.sock:/var/run/docker.sock \
  containrrr/watchtower --cleanup --label-enable --scope=outline --tlsverify --interval 3600

# Проверка запуска и вывод конфигурации
if docker ps | grep -q "${CONTAINER_NAME}"; then
  echo "Outline сервер успешно запущен. Конфигурация:"
  echo "{"apiUrl":"https://$(curl -s https://icanhazip.com/):${API_PORT}/${SB_API_PREFIX}","certSha256":"$(openssl x509 -in ${SB_CERTIFICATE_FILE} -noout -sha256 -fingerprint | cut -d'=' -f2 | tr -d ':')"}"
else
  echo "Ошибка запуска Outline сервера. Проверьте логи Docker."
fi
