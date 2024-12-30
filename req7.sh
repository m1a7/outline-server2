#!/usr/bin/env bash
###############################################################################
#  Этот скрипт предназначен для установки и настройки Outline VPN-сервера,
#  а также для дополнительной конфигурации и маскировки:
#
#   1. Подготовка окружения (проверка/установка Docker, необходимых пакетов).
#   2. Удаление старых версий Outline (если обнаружены).
#   3. Настройка NAT, iptables (TCP/UDP, ICMP, MTU).
#   4. Генерация ключей и сертификатов (для Outline Manager).
#   5. Установка и запуск Outline Server (через Docker).
#   6. Логирование и вывод итоговых параметров (ключи, URL и т.д.).
#   7. Тестирование установленной конфигурации и вывод инструкций пользователю.
#
#  Примечания:
#   - Скрипт совместим с Ubuntu 22.04.
#   - При возникновении ошибок скрипт НЕ прерывается (exit не используется),
#     а лишь формирует вопрос к ChatGPT и продолжает работу.
#   - Все логи (успешные и прочие) цветные и выводятся через echo.
#   - В конце скрипт выводит все сгенерированные ключи/пароли/конфигурации.
#
###############################################################################

#####################
### Цветные логи  ###
#####################
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_BLUE='\033[0;34m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'

# Будем считать успешное (OK), информационное (INFO), предупреждение (WARN) и ошибку (ERROR).
function LOG_OK()    { echo -e "${COLOR_GREEN}[OK] ${1}${COLOR_RESET}"; }
function LOG_INFO()  { echo -e "${COLOR_CYAN}[INFO] ${1}${COLOR_RESET}"; }
function LOG_WARN()  { echo -e "${COLOR_YELLOW}[WARN] ${1}${COLOR_RESET}"; }
function LOG_ERROR() { 
  echo -e "${COLOR_RED}[ERROR] ${1}${COLOR_RESET}"
  # Формируем вопрос к ChatGPT для диагностики (пример, вы можете изменить как хотите).
  echo -e "${COLOR_RED}Похоже, возникла ошибка. Попробуйте обратиться к ChatGPT:\n
    \"Привет, ChatGPT! В ходе выполнения скрипта на шаге: ${1}, у меня случилась проблема. 
     Что это может быть и как её можно исправить?\"${COLOR_RESET}"
}

# Счётчик ошибок: если > 0, в конце предупредим, что были проблемы
SCRIPT_ERRORS=0

############################################
### Раздел 1. Функции проверки и подготовки
############################################

# Проверяем, что скрипт запущен под root (или через sudo).
function check_root() {
  LOG_INFO "Проверяем, что скрипт запущен от root..."
  if [[ $EUID -ne 0 ]]; then
    LOG_ERROR "Скрипт не запущен от root! Некоторые действия могут быть недоступны."
    (( SCRIPT_ERRORS++ ))
  else
    LOG_OK "Скрипт запущен под root."
  fi
}

# Проверяем, установлен ли Docker, если нет - устанавливаем.
function check_and_install_docker() {
  LOG_INFO "Проверяем, установлен ли Docker..."
  if ! command -v docker &> /dev/null; then
    LOG_WARN "Docker не найден. Пытаемся установить..."
    # Ставим Docker по инструкции для Ubuntu
    apt-get update -y || { LOG_ERROR "apt-get update не сработал"; (( SCRIPT_ERRORS++ )); }
    apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release \
      || { LOG_ERROR "Установка зависимостей для Docker не прошла"; (( SCRIPT_ERRORS++ )); }
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor \
      | tee /usr/share/keyrings/docker-archive-keyring.gpg > /dev/null \
      || { LOG_ERROR "Не смогли получить ключ Docker GPG"; (( SCRIPT_ERRORS++ )); }
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
      https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      | tee /etc/apt/sources.list.d/docker.list > /dev/null \
      || { LOG_ERROR "Не удалось добавить репозиторий Docker в sources.list"; (( SCRIPT_ERRORS++ )); }

    apt-get update -y || { LOG_ERROR "apt-get update не сработал (этап Docker)"; (( SCRIPT_ERRORS++ )); }
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin \
      || { LOG_ERROR "Установка Docker CE не удалась"; (( SCRIPT_ERRORS++ )); }
    systemctl enable docker && systemctl start docker \
      || { LOG_ERROR "Не удалось запустить Docker"; (( SCRIPT_ERRORS++ )); }

    # Проверяем, что docker установился
    if command -v docker &> /dev/null; then
      LOG_OK "Docker установлен и запущен."
    else
      LOG_ERROR "Docker не обнаружен после установки."
      (( SCRIPT_ERRORS++ ))
    fi
  else
    LOG_OK "Docker уже установлен."
    # На всякий случай убеждаемся, что сервис активен
    systemctl start docker || { LOG_ERROR "Не смогли запустить Docker.service"; (( SCRIPT_ERRORS++ )); }
  fi
}

# Проверяем наличие необходимых пакетов (iptables, openssl, jq).
function check_and_install_packages() {
  LOG_INFO "Проверяем и устанавливаем необходимые пакеты: iptables, openssl, jq..."
  apt-get update -y || { LOG_ERROR "apt-get update не сработал (общий)"; (( SCRIPT_ERRORS++ )); }
  apt-get install -y iptables openssl jq curl coreutils net-tools \
    || { LOG_ERROR "Установка iptables, openssl, jq, curl, net-tools не прошла"; (( SCRIPT_ERRORS++ )); }

  # Минимальная проверка
  command -v iptables &>/dev/null || { LOG_ERROR "iptables не установлен!"; (( SCRIPT_ERRORS++ )); }
  command -v openssl  &>/dev/null || { LOG_ERROR "openssl не установлен!"; (( SCRIPT_ERRORS++ )); }
  command -v jq       &>/dev/null || { LOG_ERROR "jq не установлен!"; (( SCRIPT_ERRORS++ )); }
}

# Удаляем предыдущий Outline (если есть).
function remove_old_outline() {
  LOG_INFO "Проверяем, нет ли старых контейнеров Outline..."
  local container_exists
  container_exists=$(docker ps -a --format '{{.Names}}' | grep -E '^shadowbox$' || true)
  if [[ -n "${container_exists}" ]]; then
    LOG_WARN "Найден старый контейнер shadowbox. Пытаемся удалить..."
    docker rm -f shadowbox &>/dev/null || { LOG_ERROR "Не смогли удалить старый контейнер shadowbox"; (( SCRIPT_ERRORS++ )); }
    LOG_OK "Старый контейнер shadowbox удалён."
  fi
  # Аналогично для watchtower
  container_exists=$(docker ps -a --format '{{.Names}}' | grep -E '^watchtower$' || true)
  if [[ -n "${container_exists}" ]]; then
    LOG_WARN "Найден старый контейнер watchtower. Пытаемся удалить..."
    docker rm -f watchtower &>/dev/null || { LOG_ERROR "Не смогли удалить watchtower"; (( SCRIPT_ERRORS++ )); }
    LOG_OK "Старый контейнер watchtower удалён."
  fi

  # Удалим старые сертификаты, если нужно
  if [[ -d /opt/outline/persisted-state ]]; then
    LOG_WARN "Найдена старая директория /opt/outline/persisted-state. Удаляем..."
    rm -rf /opt/outline/persisted-state || { LOG_ERROR "Не смогли удалить старую директорию persisted-state"; (( SCRIPT_ERRORS++ )); }
    LOG_OK "Старая директория persisted-state удалена."
  fi
}

############################################
### Раздел 2. Настройка NAT, ICMP, MTU и т.д.
############################################

# Настраиваем IP forwarding и базовый NAT:
function configure_nat() {
  LOG_INFO "Настраиваем IPv4 forwarding и NAT через iptables..."
  # Включаем форвардинг
  sed -i 's/#*net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
  sysctl -p | grep "net.ipv4.ip_forward" \
    && LOG_OK "IPv4 forwarding включён." \
    || { LOG_ERROR "Не удалось включить IPv4 forwarding."; (( SCRIPT_ERRORS++ )); }

  # Настраиваем базовый MASQUERADE (предположим, что выходной интерфейс - eth0)
  # Если у вас другой - нужно подставить его.
  local OUT_IFACE="eth0"

  iptables -t nat -A POSTROUTING -o "$OUT_IFACE" -j MASQUERADE \
    && LOG_OK "Успешно добавили iptables MASQUERADE для $OUT_IFACE" \
    || { LOG_ERROR "Не удалось добавить MASQUERADE для $OUT_IFACE"; (( SCRIPT_ERRORS++ )); }
}

# Отключаем (или ограничиваем) ICMP. 
function configure_icmp() {
  LOG_INFO "Ограничиваем ICMP (ping) для сокрытия VPN-туннеля..."
  # Пример: полностью блокируем входящие ping-запросы и исходящие ping-ответы
  iptables -A INPUT -p icmp --icmp-type echo-request -j DROP \
    && LOG_OK "ICMP echo-request входящий заблокирован." \
    || { LOG_ERROR "Ошибка при блокировке входящих ICMP echo-request."; (( SCRIPT_ERRORS++ )); }

  iptables -A OUTPUT -p icmp --icmp-type echo-reply -j DROP \
    && LOG_OK "ICMP echo-reply исходящий заблокирован." \
    || { LOG_ERROR "Ошибка при блокировке исходящих ICMP echo-reply."; (( SCRIPT_ERRORS++ )); }
}

# Пример изменения MTU:
function configure_mtu() {
  LOG_INFO "Настраиваем MTU для сетевого интерфейса (eth0) до 1400..."
  ip link set dev eth0 mtu 1400 \
    && LOG_OK "MTU для eth0 установлен в 1400." \
    || { LOG_ERROR "Не удалось изменить MTU для eth0."; (( SCRIPT_ERRORS++ )); }
}

############################################
### Раздел 3. Подготовка к запуску Outline
############################################

SHADOWBOX_DIR="/opt/outline"
PERSISTED_STATE_DIR="${SHADOWBOX_DIR}/persisted-state"
ACCESS_CONFIG="${SHADOWBOX_DIR}/access.txt"

# Генерируем секрет (API_PREFIX) и сертификаты.
API_PORT=443
function generate_keys_and_certs() {
  LOG_INFO "Генерируем секретный ключ (API_PREFIX) для Outline..."
  # Возьмём 16 байт энтропии и перекодируем в base64 URL-safe
  local random_bytes
  random_bytes=$(head -c 16 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=')
  SB_API_PREFIX="$random_bytes"
  LOG_OK "Секретный ключ API_PREFIX сгенерирован: ${SB_API_PREFIX}"

  LOG_INFO "Генерируем самоподписанный SSL-сертификат для сервера..."
  mkdir -p "$PERSISTED_STATE_DIR"
  local CERT_NAME="${PERSISTED_STATE_DIR}/shadowbox-selfsigned"
  SB_CERTIFICATE_FILE="${CERT_NAME}.crt"
  SB_PRIVATE_KEY_FILE="${CERT_NAME}.key"

  # Допустим, мы хотим использовать IP сервера, а если не получилось — fallback на localhost
  local SERVER_IP
  SERVER_IP=$(curl -4s https://icanhazip.com || echo "127.0.0.1")

  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -subj "/CN=${SERVER_IP}" \
    -keyout "${SB_PRIVATE_KEY_FILE}" \
    -out "${SB_CERTIFICATE_FILE}" &>/dev/null

  if [[ -s "${SB_CERTIFICATE_FILE}" && -s "${SB_PRIVATE_KEY_FILE}" ]]; then
    LOG_OK "Сертификаты созданы: ${SB_CERTIFICATE_FILE} и ${SB_PRIVATE_KEY_FILE}."
  else
    LOG_ERROR "Не удалось создать сертификат/ключ."
    (( SCRIPT_ERRORS++ ))
  fi

  # Получаем SHA256 отпечаток
  CERT_SHA256=$(openssl x509 -in "${SB_CERTIFICATE_FILE}" -noout -fingerprint -sha256 \
    | sed 's/://g' | sed 's/^.*=//g')
  LOG_OK "SHA256 отпечаток сертификата: ${CERT_SHA256}"

  # Запишем это всё в access.txt
  mkdir -p "$SHADOWBOX_DIR"
  echo -n "" > "$ACCESS_CONFIG"
  echo "apiUrl:https://${SERVER_IP}:${API_PORT}/${SB_API_PREFIX}" >> "$ACCESS_CONFIG"
  echo "certSha256:${CERT_SHA256}" >> "$ACCESS_CONFIG"
}

# Собираем JSON-строку для Outline Manager.
function collect_outline_manager_config() {
  LOG_INFO "Формируем итоговый JSON для Outline Manager..."
  # Из ACCESS_CONFIG «apiUrl:...», «certSha256:...»
  local apiUrl certSha256
  apiUrl=$(grep 'apiUrl:' "$ACCESS_CONFIG" | sed 's/apiUrl://')
  certSha256=$(grep 'certSha256:' "$ACCESS_CONFIG" | sed 's/certSha256://')
  OUTLINE_MANAGER_CONFIG="{\"apiUrl\":\"${apiUrl}\",\"certSha256\":\"${certSha256}\"}"

  LOG_OK "Итоговая строка для Outline Manager: ${OUTLINE_MANAGER_CONFIG}"
}

############################################
### Раздел 4. Запуск Outline Container
############################################

function install_and_run_outline() {
  LOG_INFO "Запускаем контейнер Shadowbox (Outline Server) и Watchtower..."

  # Официальное имя образа Outline
  local SB_IMAGE="quay.io/outline/shadowbox:stable"

  # Создаем start_container.sh
  local START_SCRIPT="${PERSISTED_STATE_DIR}/start_container.sh"
  cat <<-EOF > "${START_SCRIPT}"
#!/usr/bin/env bash

docker stop shadowbox 2>/dev/null || true
docker rm -f shadowbox 2>/dev/null || true

docker run -d --name shadowbox --restart always --net host \\
  --label "com.centurylinklabs.watchtower.enable=true" \\
  --label "com.centurylinklabs.watchtower.scope=outline" \\
  --log-driver local \\
  -v "${PERSISTED_STATE_DIR}:${PERSISTED_STATE_DIR}" \\
  -e "SB_STATE_DIR=${PERSISTED_STATE_DIR}" \\
  -e "SB_API_PORT=${API_PORT}" \\
  -e "SB_API_PREFIX=${SB_API_PREFIX}" \\
  -e "SB_CERTIFICATE_FILE=${SB_CERTIFICATE_FILE}" \\
  -e "SB_PRIVATE_KEY_FILE=${SB_PRIVATE_KEY_FILE}" \\
  "${SB_IMAGE}"
EOF

  chmod +x "${START_SCRIPT}"
  # Запускаем
  bash "${START_SCRIPT}" || { LOG_ERROR "Ошибка запуска Shadowbox контейнера."; (( SCRIPT_ERRORS++ )); }

  # Запуск watchtower для автообновления
  # (Если контейнер уже есть - не страшно, мы удалили в remove_old_outline)
  docker run -d --name watchtower --restart always \
    --label "com.centurylinklabs.watchtower.enable=true" \
    --label "com.centurylinklabs.watchtower.scope=outline" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    containrrr/watchtower --cleanup --label-enable --scope=outline --tlsverify --interval 3600  &>/dev/null \
    && LOG_OK "Watchtower запущен." \
    || { LOG_ERROR "Ошибка при запуске Watchtower."; (( SCRIPT_ERRORS++ )); }
}

############################################
### Раздел 5. Тесты и финальный вывод
############################################

# Попробуем проверить, что контейнеры запущены, порты слушаются и т.д.
function test_configuration() {
  LOG_INFO "Проверяем работу контейнеров..."

  # 1. Проверим, что контейнер shadowbox работает
  local shadowbox_running
  shadowbox_running=$(docker ps --format '{{.Names}}' | grep -E '^shadowbox$' || true)
  if [[ -n "${shadowbox_running}" ]]; then
    LOG_OK "Контейнер shadowbox запущен."
  else
    LOG_ERROR "Контейнер shadowbox не запущен!"
    (( SCRIPT_ERRORS++ ))
  fi

  # 2. Проверим, что контейнер watchtower работает
  local watchtower_running
  watchtower_running=$(docker ps --format '{{.Names}}' | grep -E '^watchtower$' || true)
  if [[ -n "${watchtower_running}" ]]; then
    LOG_OK "Контейнер watchtower запущен."
  else
    LOG_ERROR "Контейнер watchtower не запущен!"
    (( SCRIPT_ERRORS++ ))
  fi

  # 3. Проверим доступность порта $API_PORT
  #    (простой netcat, если установлен, или ss)
  LOG_INFO "Проверяем порт ${API_PORT} (TCP) на 0.0.0.0..."
  if ss -tuln | grep ":${API_PORT} " &>/dev/null; then
    LOG_OK "Порт ${API_PORT} слушается."
  else
    LOG_ERROR "Порт ${API_PORT} не прослушивается!"
    (( SCRIPT_ERRORS++ ))
  fi
}

# Выводим инструкции пользователю
function print_instructions() {
  LOG_INFO "Выводим инструкции по ручному тестированию..."

  echo -e "${COLOR_CYAN}Для ручной проверки работоспособности Outline:${COLOR_RESET}"
  echo "1) Попробуйте открыть в браузере: https://<IP_сервера>:$API_PORT/$SB_API_PREFIX"
  echo "   (Возможна ошибка сертификата, т.к. он самоподписанный)."
  echo "2) Проверьте логи Docker: docker logs shadowbox"
  echo "3) Убедитесь, что ICMP (ping) к серверу не проходит (как и планировалось)."
  echo "4) Убедитесь, что Outline Manager принимает выданную конфигурацию."
}

# Финальная функция, выводящая все ключи, пароли и т.д.
function print_final_config() {
  LOG_INFO "Все настройки завершены. Выводим данные..."

  LOG_OK "=== Содержимое ${ACCESS_CONFIG} ==="
  cat "${ACCESS_CONFIG}"
  
  LOG_OK "=== Итоговая строка для Outline Manager: ==="
  echo "${OUTLINE_MANAGER_CONFIG}"

  echo -e "${COLOR_CYAN}Установка завершена.${COLOR_RESET}"
  if (( SCRIPT_ERRORS > 0 )); then
    echo -e "${COLOR_RED}В ходе выполнения скрипта возникли ошибки (${SCRIPT_ERRORS}). 
Пожалуйста, проверьте логи выше.${COLOR_RESET}"
  else
    echo -e "${COLOR_GREEN}Скрипт выполнен без ошибок.${COLOR_RESET}"
  fi
}

#########################################################
### "Главный" блок — Выполнение всего по порядку
#########################################################

LOG_INFO "Начинаем работу скрипта установки и настройки Outline..."

# 1. Подготовка:
check_root
check_and_install_docker
check_and_install_packages
remove_old_outline

# 2. Настройка сети и туннеля:
configure_nat
configure_icmp
configure_mtu

# 3. Генерация ключей/сертификатов + запись в файл:
generate_keys_and_certs
collect_outline_manager_config

# 4. Установка/запуск Outline контейнера:
install_and_run_outline

# 5. Тестирование:
test_configuration

# 6. Вывод итоговой инфы, ключей и инструкций:
print_instructions
print_final_config
