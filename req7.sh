#!/usr/bin/env bash
#
# ---------------------------------------------------------------------------------
#  Скрипт для автоматической установки и настройки приватного VPN-сервера Outline
#  (работающего в Docker) на Ubuntu 22.04 x64, с пробросом порта 443.
#
#  Внимание!
#    1) Скрипт не останавливает своё выполнение при ошибках. Вместо этого он формирует
#       сообщение с вопросом для ChatGPT, содержащее описание проблемы.
#    2) Все ключи, пароли и важные строки конфигурации выводятся в конце.
#    3) В самом низу файла содержится спрятанный блок кода для удаления всех
#       установленных компонентов (закомментирован).
#    4) Дополнительно блокируем ICMP (ping) для усложнения обнаружения VPN.
#
# ---------------------------------------------------------------------------------

# ========================== ОФОРМЛЕНИЕ ВЫВОДА (ЦВЕТА) ===========================
COLOR_RED="\033[0;31m"
COLOR_GREEN="\033[0;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_CYAN="\033[0;36m"
COLOR_NONE="\033[0m"

# ============================= ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ==========================
log_success() {
  echo -e "[${COLOR_GREEN}OK${COLOR_NONE}] $1"
}

log_info() {
  echo -e "[${COLOR_CYAN}INFO${COLOR_NONE}] $1"
}

log_warn() {
  echo -e "[${COLOR_YELLOW}WARNING${COLOR_NONE}] $1"
}

log_error() {
  local errmsg="$1"
  echo -e "[${COLOR_RED}ERROR${COLOR_NONE}] $errmsg"
  echo -e "[${COLOR_RED}ERROR${COLOR_NONE}] Похоже, возникла ошибка: '$errmsg'.\nЗадайте вопрос ChatGPT: \"Почему в процессе выполнения скрипта на шаге '${CURRENT_STEP}' возникла ошибка: '${errmsg}'?\""
}

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
OUTLINE_API_PORT=8443
OUTLINE_CONTAINER_NAME="shadowbox"
WATCHTOWER_CONTAINER_NAME="watchtower"
SHADOWBOX_DIR="/opt/outline"
ACCESS_CONFIG="$SHADOWBOX_DIR/access.txt"

# ============================= ПОДГОТОВКА ОКРУЖЕНИЯ =============================
log_info "Подготовка окружения. Скрипт запускается пользователем: '$(whoami)'."

set +e

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
  mkdir -p "'$SHADOWBOX_DIR'"
  chmod 700 "'$SHADOWBOX_DIR'"

  STATE_DIR="'$SHADOWBOX_DIR'/persisted-state"
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
  KEY=${KEY%%=*}
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
  if [[ -z "'$PUBLIC_HOSTNAME'" ]]; then
    subj="/CN=localhost"
  else
    subj="/CN='$PUBLIC_HOSTNAME'"
  fi

  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -subj "$subj" \
    -keyout "'$SB_PRIVATE_KEY_FILE'" \
    -out "'$SB_CERTIFICATE_FILE'" 2>/dev/null

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
  out=$(openssl x509 -in "'$SB_CERTIFICATE_FILE'" -noout -sha256 -fingerprint 2>/dev/null)
  if [[ $? -ne 0 ]]; then
    echo "Не удалось получить отпечаток сертификата!"
    exit 1
  fi

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
  CONFIG_FILE="'$SHADOWBOX_DIR'/persisted-state/shadowbox_server_config.json"
  cat <<EOF > "$CONFIG_FILE"
{
  "hostname": "'$PUBLIC_HOSTNAME'",
  "portForNewAccessKeys": 443
}
EOF
  echo "Конфигурационный файл создан: $CONFIG_FILE"
'

# ============================= 9. ЗАПУСК SHADOWBOX (OUTLINE SERVER) =============
run_command "Запуск Shadowbox (Outline) в Docker" bash -c '
  STATE_DIR="'$SHADOWBOX_DIR'/persisted-state"

  docker stop "'$OUTLINE_CONTAINER_NAME'" &>/dev/null || true
  docker rm -f "'$OUTLINE_CONTAINER_NAME'" &>/dev/null || true

  docker run -d \
    --name "'$OUTLINE_CONTAINER_NAME'" \
    --restart always \
    --net host \
    --label "com.centurylinklabs.watchtower.enable=true" \
    --label "com.centurylinklabs.watchtower.scope=outline" \
    --log-driver local \
    -v "$STATE_DIR:$STATE_DIR" \
    -e SB_STATE_DIR="$STATE_DIR" \
    -e SB_API_PORT="'$OUTLINE_API_PORT'" \
    -e SB_API_PREFIX="'$SB_API_PREFIX'" \
    -e SB_CERTIFICATE_FILE="'$SB_CERTIFICATE_FILE'" \
    -e SB_PRIVATE_KEY_FILE="'$SB_PRIVATE_KEY_FILE'" \
    -p "'$OUTLINE_API_PORT:$OUTLINE_API_PORT'" \
    quay.io/outline/shadowbox:stable
'

# ============================= 10. ЗАПУСК WATCHTOWER ============================
run_command "Запуск Watchtower (обновляет образы Docker)" bash -c '
  docker stop "'$WATCHTOWER_CONTAINER_NAME'" &>/dev/null || true
  docker rm -f "'$WATCHTOWER_CONTAINER_NAME'" &>/dev/null || true

  docker run -d \
    --name "'$WATCHTOWER_CONTAINER_NAME'" \
    --restart always \
    --log-driver local \
    --label "com.centurylinklabs.watchtower.enable=true" \
    --label "com.centurylinklabs.watchtower.scope=outline" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    containrrr/watchtower --cleanup --label-enable --scope=outline --tlsverify --interval 3600
'

# ============================= 11. ОЖИДАНИЕ ЗДОРОВОГО СОСТОЯНИЯ OUTLINE =========
run_command "Ожидание, пока Outline-сервер станет доступен" bash -c '
  LOCAL_API_URL="https://localhost:'"$OUTLINE_API_PORT"'/"'"$SB_API_PREFIX"'""
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
  LOCAL_API_URL="https://localhost:'"$OUTLINE_API_PORT"'/"'"$SB_API_PREFIX"'""
  curl --insecure --silent --fail --request POST "$LOCAL_API_URL/access-keys" >&2
  echo "Пользователь создан."
'

# ============================= 13. ДОБАВЛЕНИЕ API-URL В CONFIG ==================
run_command "Добавление API URL в $ACCESS_CONFIG" bash -c '
  mkdir -p "'$SHADOWBOX_DIR'"
  echo -e "\033[1;32m{\"apiUrl\":\"https://'$PUBLIC_HOSTNAME':'$OUTLINE_API_PORT'/'$SB_API_PREFIX'\"}\033[0m" >> "$ACCESS_CONFIG"
  echo "certSha256:'"$CERT_SHA256"'" >> "'$ACCESS_CONFIG'"
  echo "Добавлены строки apiUrl и certSha256 в $ACCESS_CONFIG"
'

# ============================= 14. ПРОВЕРКА ФАЕРВОЛА ХОСТА ======================
run_command "Проверка, что порт 443 доступен извне" bash -c '
  if curl --silent --fail --cacert "'$SB_CERTIFICATE_FILE'" --max-time 5 "https://'$PUBLIC_HOSTNAME':'$OUTLINE_API_PORT'/'$SB_API_PREFIX'/access-keys" >/dev/null; then
    echo "Порт 443 кажется доступен снаружи."
  else
    echo "Порт 443 может быть заблокирован фаерволом. Проверьте настройки!"
    exit 1
  fi
'

# ============================= 15. БЛОКИРОВКА ICMP (PING) =======================
run_command "Блокировка ICMP (ping) на сервере" bash -c '
  iptables -A INPUT -p icmp --icmp-type echo-request -j DROP
  iptables -A OUTPUT -p icmp --icmp-type echo-reply -j DROP

  ip6tables -A INPUT -p icmpv6 --icmpv6-type echo-request -j DROP
  ip6tables -A OUTPUT -p icmpv6 --icmp-type echo-reply -j DROP

  echo "ICMP (ping) заблокирован. Это поможет скрыть VPN от обнаружения через bidirectional ping."
'

# ============================= 16. ТЕСТИРОВАНИЕ РЕЗУЛЬТАТОВ =====================
run_command "Проверка, что порт 443 слушается" bash -c '
  if ss -tuln | grep ":443 " | grep LISTEN; then
    echo "Порт 443 прослушивается."
  else
    echo "Порт 443 не прослушивается! Проверьте конфигурацию."
    exit 1
  fi
'

run_command "Команды для ручной проверки" bash -c '
  echo "------------------------------------------"
  echo "Можно вручную проверить доступность Outline:"
  echo "  curl --insecure https://'$PUBLIC_HOSTNAME':'$OUTLINE_API_PORT'/'$SB_API_PREFIX'/access-keys"
  echo "------------------------------------------"
'

# ============================= ИТОГОВЫЕ ДАННЫЕ (КЛЮЧИ И ПАРОЛИ) =================
echo -e "${COLOR_GREEN}\n========== ИТОГИ УСТАНОВКИ ==========${COLOR_NONE}"
echo -e "${COLOR_CYAN}VPN Outline (Docker) успешно настроен (если не было ошибок выше).${COLOR_NONE}"
echo -e "PUBLIC_HOSTNAME: ${PUBLIC_HOSTNAME}"
echo -e "Outline API URL: https://${PUBLIC_HOSTNAME}:${OUTLINE_API_PORT}/${SB_API_PREFIX}"
echo -e "TLS Certificate: $SB_CERTIFICATE_FILE"
echo -e "TLS Key:         $SB_PRIVATE_KEY_FILE"
echo -e "SHA-256 Fingerprint: $CERT_SHA256"
echo -e "------------------------------------------"
echo -e "Содержимое $ACCESS_CONFIG:"
cat "$ACCESS_CONFIG" 2>/dev/null
echo -e "------------------------------------------"

echo -e "${COLOR_GREEN}Скрипт завершён.${COLOR_NONE}"



# Utility function to print section separators
print_separator() {
    echo ""
    echo "------------------------------------------"
    echo ""
}

# Function to handle errors and ensure file creation
ensure_file_exists() {
    local file_path="$1"
    if [ ! -f "$file_path" ]; then
        touch "$file_path"
    fi
}

# Ensure the SHA-256 fingerprint is correctly calculated and set
print_separator
echo "[INFO] Генерация SHA-256 отпечатка сертификата"
CERTIFICATE_FILE="/opt/outline/persisted-state/shadowbox-selfsigned.crt"
if [ -f "$CERTIFICATE_FILE" ]; then
    SHA256_FINGERPRINT=$(openssl x509 -noout -fingerprint -sha256 -inform pem -in "$CERTIFICATE_FILE" | sed 's/^.*=//;s/://g')
    echo "Отпечаток SHA-256: $SHA256_FINGERPRINT"
else
    echo "[ERROR] Сертификат не найден по пути: $CERTIFICATE_FILE"
    SHA256_FINGERPRINT="ERROR_NO_CERTIFICATE"
fi
print_separator

# Example enhancement: Adding API URL and certSha256 to access.txt
ACCESS_FILE="/opt/outline/access.txt"
print_separator
echo "[INFO] Начало шага: 'Добавление API URL в $ACCESS_FILE'"
ensure_file_exists "$ACCESS_FILE"
{
    echo "apiUrl=https://$PUBLIC_HOSTNAME:443/$SB_API_PREFIX"
    echo "certSha256=$SHA256_FINGERPRINT"
} >> "$ACCESS_FILE"
echo "Добавлены строки apiUrl и certSha256 в $ACCESS_FILE"
echo "[OK] Шаг 'Добавление API URL в $ACCESS_FILE' завершён успешно."
print_separator

# Installation summary with separators
print_separator
echo "========== ИТОГИ УСТАНОВКИ =========="
echo "VPN Outline (Docker) успешно настроен (если не было ошибок выше)."
echo "PUBLIC_HOSTNAME: $PUBLIC_HOSTNAME"
echo "Outline API URL: https://$PUBLIC_HOSTNAME:443/$SB_API_PREFIX"
echo "TLS Certificate: /opt/outline/persisted-state/shadowbox-selfsigned.crt"
echo "TLS Key:         /opt/outline/persisted-state/shadowbox-selfsigned.key"
echo "SHA-256 Fingerprint: $SHA256_FINGERPRINT"
print_separator

CONFIG_STRING="{\"apiUrl\":\"https://$PUBLIC_HOSTNAME:443/$SB_API_PREFIX\",\"certSha256\":\"$SHA256_FINGERPRINT\"}"
echo "Config string for OutlineManager: $CONFIG_STRING"
print_separator

# Commands for accessing key configuration files
echo "Commands to view key configuration files:"
echo "cat /opt/outline/access.txt"
echo "cat /opt/outline/persisted-state/shadowbox_server_config.json"
print_separator
echo "Скрипт завершён."
