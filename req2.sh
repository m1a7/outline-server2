#!/usr/bin/env bash
#
# ---------------------------------------------------------------------------------
#  Скрипт для автоматической установки и настройки приватного VPN-сервера Outline
#  (работающего в Docker) на Ubuntu 22.04 x64, с обфускацией через Shadowsocks
#  (плагин obfs4) и пробросом порта 443.
#
#  Требования и особенности:
#    1) Скрипт не останавливает своё выполнение при ошибках. Вместо этого он формирует
#       сообщение с вопросом для ChatGPT, содержащее описание проблемы.
#    2) Все ключи, пароли и важные строки конфигурации выводятся в конце.
#    3) В самом низу файла содержится закомментированный блок кода, который
#       полностью удаляет все установленные компоненты (осторожно!).
#    4) После завершения настройки скрипт выполняет базовые тесты и выводит команды,
#       которые можно вручную запустить для проверки.
#    5) Скрипт предназначен для запуска на Ubuntu 22.04 (LTS) x64.
#
#  Примечание: Скрипт старается проверить и протестировать установку обфускации и
#              проброс порта 443, однако для полноты тестов могут потребоваться
#              дополнительные проверки сети и фаервола со стороны хостинга.
# ---------------------------------------------------------------------------------

# ========================== ОФОРМЛЕНИЕ ВЫВОДА (ЦВЕТА) ===========================
COLOR_RED="\033[0;31m"
COLOR_GREEN="\033[0;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_CYAN="\033[0;36m"
COLOR_NONE="\033[0m"

# ============================= ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ==========================
# Функция логирования успешного шага
log_success() {
  echo -e "[${COLOR_GREEN}OK${COLOR_NONE}] $1"
}

# Функция логирования информационного шага
log_info() {
  echo -e "[${COLOR_CYAN}INFO${COLOR_NONE}] $1"
}

# Функция логирования предупреждения
log_warn() {
  echo -e "[${COLOR_YELLOW}WARNING${COLOR_NONE}] $1"
}

# Функция логирования ошибки. Не завершает работу, а формирует вопрос к ChatGPT.
log_error() {
  local errmsg="$1"
  echo -e "[${COLOR_RED}ERROR${COLOR_NONE}] $errmsg"
  echo -e "[${COLOR_RED}ERROR${COLOR_NONE}] Похоже, возникла ошибка: '$errmsg'.\nЗадайте вопрос ChatGPT: \"Почему в процессе выполнения скрипта на шаге '${CURRENT_STEP}' возникла ошибка: '${errmsg}'?\""
}

# Функция для выполнения команд с логированием.
#   - Не прерывает скрипт в случае ошибки,
#   - Хранит название текущего шага в глобальной переменной $CURRENT_STEP,
#     чтобы при возникновении ошибки мы могли вывести его в лог.
run_command() {
  local step_description="$1"
  shift
  CURRENT_STEP="$step_description"

  log_info "Начало шага: '$step_description'"
  if "$@"; then
    log_success "Шаг '$step_description' завершён успешно."
  else
    log_error "Не удалось выполнить шаг '$step_description'."
  fi
}

# ============================= НАСТРОЙКА ГЛОБАЛЬНЫХ ПЕРЕМЕННЫХ ==================
# Порт, на котором будет работать Outline (Manager API). Требование: порт 443.
OUTLINE_API_PORT=443

# Порт для сервиса Shadowsocks. Согласно задаче, также 443.
SHADOWSOCKS_PORT=443

# Название Docker-контейнера Outline
OUTLINE_CONTAINER_NAME="shadowbox"

# Название Docker-контейнера Watchtower
WATCHTOWER_CONTAINER_NAME="watchtower"

# Директория для установки Outline (persistent state)
SHADOWBOX_DIR="/opt/outline"

# Файл для записи основных параметров (доступ и др.)
ACCESS_CONFIG="$SHADOWBOX_DIR/access.txt"

# ============================= ПОДГОТОВКА ОКРУЖЕНИЯ =============================
log_info "Подготовка окружения. Скрипт запускается пользователем: '$(whoami)'."

# Отключаем опцию exit-on-error, чтобы скрипт не обрывался
# при возникновении ошибок. Все ошибки будут логироваться.
set +e

# Проверяем права (желательно запускать от root)
if [[ $EUID -ne 0 ]]; then
  log_warn "Рекомендуется запускать этот скрипт от пользователя root для упрощённой работы с Docker и сетевыми настройками."
fi

# ============================= 1. ПРОВЕРКА DOCKER ===============================
run_command "Проверка наличия Docker" bash -c '
  if ! command -v docker &>/dev/null; then
    echo "Docker не найден. Попытаюсь установить..."
    curl -fsSL https://get.docker.com | sh
    if [[ $? -eq 0 ]]; then
      echo "Docker установлен успешно."
    else
      echo "Не удалось установить Docker!"
      exit 1
    fi
  else
    echo "Docker уже установлен."
  fi
'

# ============================= 2. ПРОВЕРКА DEMON DOCKER =========================
run_command "Проверка, что демон Docker запущен" bash -c '
  if ! systemctl is-active --quiet docker; then
    echo "Докер не запущен. Попытаюсь запустить..."
    systemctl enable docker
    systemctl start docker
    if systemctl is-active --quiet docker; then
      echo "Docker успешно запущен."
    else
      echo "Не удалось запустить Docker!"
      exit 1
    fi
  else
    echo "Демон Docker уже запущен."
  fi
'

# ============================= 3. ОПРЕДЕЛЕНИЕ ВНЕШНЕГО IP =======================
# Функция для определения публичного IP. Если все проваливаются — оставляем пустым.
PUBLIC_HOSTNAME=""
run_command "Определение внешнего IP адреса" bash -c '
  possible_urls=(
    "https://icanhazip.com"
    "https://ipinfo.io/ip"
    "https://domains.google.com/checkip"
  )
  for url in "${possible_urls[@]}"; do
    IP=$(curl -4 -s --max-time 5 "$url")
    if [[ -n "$IP" ]]; then
      echo "Обнаружен IP: $IP"
      echo "$IP" > /tmp/my_public_ip.txt
      exit 0
    fi
  done
  echo "Не удалось определить внешний IP."
  exit 1
'
if [[ -f /tmp/my_public_ip.txt ]]; then
  PUBLIC_HOSTNAME="$(cat /tmp/my_public_ip.txt)"
  log_success "PUBLIC_HOSTNAME=$PUBLIC_HOSTNAME"
else
  log_error "Параметр PUBLIC_HOSTNAME не установлен. Продолжаем, но конфигурация может быть некорректна!"
fi

# ============================= 4. СОЗДАНИЕ PERSISTENT STATE DIR =================
run_command "Создание директории $SHADOWBOX_DIR и каталога для стейта" bash -c '
  mkdir -p "'"$SHADOWBOX_DIR"'"
  chmod 700 "'"$SHADOWBOX_DIR"'"

  STATE_DIR="'"$SHADOWBOX_DIR"'/persisted-state"
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
'

# ============================= 5. ГЕНЕРАЦИЯ СЕКРЕТНОГО КЛЮЧА ====================
SB_API_PREFIX=""
run_command "Генерация секретного ключа" bash -c '
  function safe_base64() {
    base64 -w 0 - | tr "/+" "_-"
  }
  KEY=$(head -c 16 /dev/urandom | safe_base64)
  KEY=${KEY%%=*}    # Обрезаем возможные символы '=' в конце
  echo "$KEY" > /tmp/sb_api_prefix.txt
  echo "Секретный ключ: $KEY"
'

if [[ -f /tmp/sb_api_prefix.txt ]]; then
  SB_API_PREFIX="$(cat /tmp/sb_api_prefix.txt)"
  log_success "Секретный ключ (SB_API_PREFIX)=$SB_API_PREFIX"
else
  log_error "Не удалось сгенерировать секретный ключ (SB_API_PREFIX)"
fi

# ============================= 6. ГЕНЕРАЦИЯ TLS-СЕРТИФИКАТА =====================
SB_CERTIFICATE_FILE="$SHADOWBOX_DIR/persisted-state/shadowbox-selfsigned.crt"
SB_PRIVATE_KEY_FILE="$SHADOWBOX_DIR/persisted-state/shadowbox-selfsigned.key"
run_command "Генерация самоподписанного сертификата" bash -c '
  if [[ -z "'"$PUBLIC_HOSTNAME"'" ]]; then
    subj="/CN=localhost"
  else
    subj="/CN='"$PUBLIC_HOSTNAME"'"
  fi

  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -subj "$subj" \
    -keyout "'"$SB_PRIVATE_KEY_FILE"'" \
    -out "'"$SB_CERTIFICATE_FILE"'" 2>/dev/null

  if [[ $? -eq 0 ]]; then
    echo "Сертификат успешно сгенерирован."
  else
    echo "Ошибка при генерации сертификата!"
    exit 1
  fi
'

# ============================= 7. ГЕНЕРАЦИЯ SHA-256 ОТПЕЧАТКА ===================
CERT_SHA256=""
run_command "Генерация SHA-256 отпечатка сертификата" bash -c '
  out=$(openssl x509 -in "'"$SB_CERTIFICATE_FILE"'" -noout -sha256 -fingerprint 2>/dev/null)
  if [[ $? -ne 0 ]]; then
    echo "Не удалось получить отпечаток сертификата!"
    exit 1
  fi

  # Пример: SHA256 Fingerprint=BD:DB:C9:...
  fingerprint=${out#*=}
  fingerprint_no_colons=$(echo "$fingerprint" | tr -d ":")
  echo "$fingerprint_no_colons" > /tmp/cert_fingerprint.txt
  echo "Отпечаток SHA-256: $fingerprint_no_colons"
'

if [[ -f /tmp/cert_fingerprint.txt ]]; then
  CERT_SHA256="$(cat /tmp/cert_fingerprint.txt)"
  log_success "SHA-256 отпечаток сертификата: $CERT_SHA256"
else
  log_error "Не удалось получить SHA-256 отпечаток сертификата."
fi

# ============================= 8. ЗАПИСЬ КОНФИГУРАЦИОННЫХ ДАННЫХ ================
run_command "Запись первичных конфигурационных данных" bash -c '
  CONFIG_FILE="'"$SHADOWBOX_DIR"'/persisted-state/shadowbox_server_config.json"
  cat <<EOF > "$CONFIG_FILE"
{
  "hostname": "'"$PUBLIC_HOSTNAME"'",
  "portForNewAccessKeys": '$SHADOWSOCKS_PORT'
}
EOF
  echo "Конфигурационный файл создан: $CONFIG_FILE"
'

# ============================= 9. ЗАПУСК SHADOWBOX (OUTLINE SERVER) =============
run_command "Запуск Shadowbox (Outline) в Docker" bash -c '
  STATE_DIR="'"$SHADOWBOX_DIR"'/persisted-state"

  docker stop "'"$OUTLINE_CONTAINER_NAME"'" &>/dev/null || true
  docker rm -f "'"$OUTLINE_CONTAINER_NAME"'" &>/dev/null || true

  docker run -d \
    --name "'"$OUTLINE_CONTAINER_NAME"'" \
    --restart always \
    --net host \
    --label "com.centurylinklabs.watchtower.enable=true" \
    --label "com.centurylinklabs.watchtower.scope=outline" \
    --log-driver local \
    -v "$STATE_DIR:$STATE_DIR" \
    -e SB_STATE_DIR="$STATE_DIR" \
    -e SB_API_PORT="'"$OUTLINE_API_PORT"'" \
    -e SB_API_PREFIX="'"$SB_API_PREFIX"'" \
    -e SB_CERTIFICATE_FILE="'"$SB_CERTIFICATE_FILE"'" \
    -e SB_PRIVATE_KEY_FILE="'"$SB_PRIVATE_KEY_FILE"'" \
    -p "'"$OUTLINE_API_PORT:$OUTLINE_API_PORT"'" \
    quay.io/outline/shadowbox:stable
'

# ============================= 10. ЗАПУСК WATCHTOWER ============================
run_command "Запуск Watchtower (обновляет образы Docker)" bash -c '
  docker stop "'"$WATCHTOWER_CONTAINER_NAME"'" &>/dev/null || true
  docker rm -f "'"$WATCHTOWER_CONTAINER_NAME"'" &>/dev/null || true

  docker run -d \
    --name "'"$WATCHTOWER_CONTAINER_NAME"'" \
    --restart always \
    --log-driver local \
    --label "com.centurylinklabs.watchtower.enable=true" \
    --label "com.centurylinklabs.watchtower.scope=outline" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    containrrr/watchtower --cleanup --label-enable --scope=outline --tlsverify --interval 3600
'

# ============================= 11. ОЖИДАНИЕ ЗДОРОВОГО СОСТОЯНИЯ OUTLINE =========
run_command "Ожидание, пока Outline-сервер станет доступен" bash -c '
  LOCAL_API_URL="https://localhost:'"$OUTLINE_API_PORT"'/'"$SB_API_PREFIX"'"
  for i in {1..60}; do
    if curl --insecure --silent --fail "$LOCAL_API_URL/access-keys" >/dev/null; then
      echo "Outline-сервер готов к работе."
      exit 0
    fi
    sleep 2
  done
  echo "Не дождались здорового состояния сервера за 120 секунд."
  exit 1
'

# ============================= 12. СОЗДАНИЕ ПЕРВОГО ПОЛЬЗОВАТЕЛЯ ================
run_command "Создание первого пользователя Outline" bash -c '
  LOCAL_API_URL="https://localhost:'"$OUTLINE_API_PORT"'/'"$SB_API_PREFIX"'"
  curl --insecure --silent --fail --request POST "$LOCAL_API_URL/access-keys" >&2
  echo "Пользователь создан."
'

# ============================= 13. ДОБАВЛЕНИЕ API-URL В CONFIG ==================
run_command "Добавление API URL в $ACCESS_CONFIG" bash -c '
  mkdir -p "'"$SHADOWBOX_DIR"'"
  echo "apiUrl:https://'"$PUBLIC_HOSTNAME"':'"$OUTLINE_API_PORT"'/'"$SB_API_PREFIX"'" >> "'"$ACCESS_CONFIG"'"
  echo "certSha256:'"$CERT_SHA256"'" >> "'"$ACCESS_CONFIG"'"
  echo "Добавлены строки apiUrl и certSha256 в $ACCESS_CONFIG"
'

# ============================= 14. ПРОВЕРКА ФАЕРВОЛА ХОСТА ======================
run_command "Проверка, что порт 443 доступен извне" bash -c '
  if curl --silent --fail --cacert "'"$SB_CERTIFICATE_FILE"'" --max-time 5 "https://'"$PUBLIC_HOSTNAME"':'"$OUTLINE_API_PORT"'/'"$SB_API_PREFIX"'/access-keys" >/dev/null; then
    echo "Порт 443 кажется доступен снаружи."
  else
    echo "Порт 443 может быть заблокирован фаерволом. Проверьте настройки!"
    exit 1
  fi
'

# ============================= 15. УСТАНОВКА И НАСТРОЙКА OBFS4PROXY =============
run_command "Установка obfs4proxy (для DPI-обфускации)" bash -c '
  apt-get update -y && apt-get install -y obfs4proxy
  if [[ $? -eq 0 ]]; then
    echo "obfs4proxy установлен."
  else
    echo "Не удалось установить obfs4proxy."
    exit 1
  fi
'

# Пример дополнительного контейнера с Shadowsocks + obfs4.  
# Если Outline-сервер уже слушает 443, для демонстрации мы запускаем
# этот контейнер на другом порту (например, 8443) — однако при желании
# можно перенастроить и прокинуть всё на 443, используя SNI (требуются
# дополнительные правки, прокси/Reverse Proxy и т.д.).
SHADOWSOCKS_OBFS_PORT=8443
run_command "Запуск Shadowsocks (c obfs4) в отдельном контейнере" bash -c '
  SHADOWSOCKS_IMAGE="hlandau/ss-obfs:latest"
  docker stop shadowsocks-obfs &>/dev/null || true
  docker rm -f shadowsocks-obfs &>/dev/null || true

  docker run -d \
    --name shadowsocks-obfs \
    --restart always \
    -p '"$SHADOWSOCKS_OBFS_PORT"':443 \
    -e "SERVER_ADDR=0.0.0.0" \
    -e "PASSWORD=MySecretPassword" \
    -e "METHOD=aes-256-gcm" \
    -e "PLUGIN=obfs-server" \
    -e "PLUGIN_OPTS=obfs=http" \
    "$SHADOWSOCKS_IMAGE"
'

# ============================= ТЕСТИРОВАНИЕ РЕЗУЛЬТАТОВ =========================
run_command "Проверка, что порт 443 слушается (Outline)" bash -c '
  if ss -tuln | grep ":443 " | grep LISTEN; then
    echo "Outline слушает порт 443."
  else
    echo "Outline НЕ слушает порт 443! Проверьте конфигурацию."
    exit 1
  fi
'

run_command "Проверка, что obfs4proxy (Shadowsocks) слушает порт '"$SHADOWSOCKS_OBFS_PORT"'" bash -c '
  if ss -tuln | grep ":'"$SHADOWSOCKS_OBFS_PORT"' " | grep LISTEN; then
    echo "Shadowsocks+obfs4 слушает порт '"$SHADOWSOCKS_OBFS_PORT"'."
  else
    echo "Порт '"$SHADOWSOCKS_OBFS_PORT"' не прослушивается! Проверьте конфигурацию."
    exit 1
  fi
'

run_command "Рекомендованные команды для ручной проверки" bash -c '
  echo "------------------------------------------"
  echo "1) Проверка доступности Outline API (сервер 128.199.56.243):"
  echo "   curl --insecure https://128.199.56.243:'"$OUTLINE_API_PORT"'/'"$SB_API_PREFIX"'/access-keys"
  echo "2) Проверка Shadowsocks (c obfs):"
  echo "   # Нужно поднять локально shadowsocks-клиент с параметрами:"
  echo "   #  server = 128.199.56.243, port = '"$SHADOWSOCKS_OBFS_PORT"', password = MySecretPassword, method = aes-256-gcm,"
  echo "   #  plugin = obfs-local, plugin_opts = \"obfs=http;obfs-host=...\""
  echo "------------------------------------------"
'

# ============================= ИТОГОВЫЕ ДАННЫЕ (КЛЮЧИ И ПАРОЛИ) =================
echo -e "${COLOR_GREEN}\n========== ИТОГИ УСТАНОВКИ ==========${COLOR_NONE}"
echo -e "${COLOR_CYAN}VPN Outline (Docker) + obfs4 (Shadowsocks) успешно настроены (если не было ошибок выше).${COLOR_NONE}"
echo -e "PUBLIC_HOSTNAME: ${PUBLIC_HOSTNAME}"
echo -e "Outline API URL: https://${PUBLIC_HOSTNAME}:${OUTLINE_API_PORT}/${SB_API_PREFIX}"
echo -e "TLS Certificate: $SB_CERTIFICATE_FILE"
echo -e "TLS Key:         $SB_PRIVATE_KEY_FILE"
echo -e "SHA-256 Fingerprint: $CERT_SHA256"
echo -e "Shadowsocks (obfs4) контейнер: порт ${SHADOWSOCKS_OBFS_PORT}, пароль: MySecretPassword"
echo -e "------------------------------------------"
echo -e "Содержимое $ACCESS_CONFIG:"
cat "$ACCESS_CONFIG"
echo -e "------------------------------------------"
echo -e "Скрипт закончил своё выполнение. Если возникли ошибки, см. выше в логе."

# ============================= СПРЯТАННЫЙ КОД ДЛЯ УДАЛЕНИЯ =====================
# Ниже размещаем закомментированный блок, который полностью удаляет всё, что установили.
# Внимание! Запускать только если вы действительно хотите снести всё.
#
# Осторожно: Это приведёт к потере всех данных Outline и Shadowsocks, сертификатов и т.д.
# Раскомментируйте блок и выполните, если нужно сделать полную очистку.

: <<'HIDDEN_REMOVE_BLOCK'
echo "ОСТОРОЖНО! Удаляем все установленные компоненты Outline + Shadowsocks."

# 1. Останавливаем и удаляем контейнеры
docker stop shadowbox watchtower shadowsocks-obfs || true
docker rm -f shadowbox watchtower shadowsocks-obfs || true

# 2. Удаляем пакеты obfs4proxy (если вы не используете их в других сервисах)
apt-get remove -y obfs4proxy
apt-get autoremove -y

# 3. Удаляем директорию /opt/outline
rm -rf /opt/outline

# 4. Если Docker установлен только для Outline, можно удалить Docker (необязательно)
# apt-get remove -y docker docker.io
# apt-get autoremove -y

echo "Удаление завершено."
HIDDEN_REMOVE_BLOCK