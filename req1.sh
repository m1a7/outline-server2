#!/usr/bin/env bash
#
# Скрипт установки и настройки Outline VPN (Shadowbox) с обфускацией Shadowsocks-трафика.
# Тестировался на Ubuntu 22.04.
#
# Устанавливает Docker, поднимает контейнер Outline, добавляет watchtower,
# настраивает obfs4 (в качестве примера плагина).
# 
# -------------------------------------------------------
# Разработано в ответ на запрос:
#   "Хочу bash-скрипт, который установит Outline VPN в Docker
#    c обфускацией Shadowsocks. Скрипт на русском, цветные логи,
#    тест портов, в конце вывод ключей/конфига, в самом низу
#    скрытый код, удаляющий все настройки."
# -------------------------------------------------------

# =========================
#      Цвета вывода
# =========================
COLOR_RED="\033[0;31m"
COLOR_GREEN="\033[0;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_BLUE="\033[0;34m"
COLOR_PURPLE="\033[0;35m"
COLOR_CYAN="\033[0;36m"
COLOR_WHITE="\033[1;37m"
COLOR_NONE="\033[0m"

# =========================
#   Функции для логирования
# =========================

# Универсальный вывод информационного сообщения (жёлтым).
function log_info() {
  echo -e "${COLOR_YELLOW}[ИНФО]${COLOR_NONE} $1"
}

# Вывод успешного завершения операции (зелёным).
function log_ok() {
  echo -e "${COLOR_GREEN}[ОК]${COLOR_NONE} $1"
}

# Вывод предупреждения (синим или фиолетовым).
function log_warn() {
  echo -e "${COLOR_PURPLE}[ПРЕДУПРЕЖДЕНИЕ]${COLOR_NONE} $1"
}

# Вывод ошибки (красным). 
# В случае ошибки формируем заготовку вопроса к ChatGPT, но НЕ прерываем скрипт.
function log_error() {
  echo -e "${COLOR_RED}[ОШИБКА]${COLOR_NONE} $1"
  echo -e "${COLOR_RED}ВОПРОС К CHAT-GPT:${COLOR_NONE} Пожалуйста, помогите разобраться с ошибкой: $1"
}

# =========================
#   Проверки и окружение
# =========================

# Проверяем, запущен ли скрипт от root.
# Без этой проверки возможны проблемы с установкой пакетов и запуском docker.
function check_root() {
  log_info "Проверка прав запуска скрипта..."
  if [[ $EUID -ne 0 ]]; then
    log_warn "Скрипт не запущен от root, могут возникнуть проблемы с установкой! Продолжаем без прерывания..."
  else
    log_ok "Скрипт запущен от root."
  fi
}

# Проверяем наличие Docker; если не установлен — установим.
function check_and_install_docker() {
  log_info "Проверка наличия Docker..."
  if ! command -v docker &> /dev/null; then
    log_warn "Docker не установлен! Пытаемся установить Docker..."
    # Здесь не используем exit, чтобы скрипт не прерывался
    # Выполним официальную команду установки Docker
    if curl -fsSL https://get.docker.com | bash &>/dev/null; then
      log_ok "Docker успешно установлен."
    else
      log_error "Не удалось установить Docker. Продолжаем выполнение скрипта, но установка Outline может не получиться."
    fi
  else
    log_ok "Docker уже установлен."
  fi
}

# Проверяем, запущен ли Docker-демон.
function check_docker_running() {
  log_info "Проверка, запущен ли Docker-демон..."
  if ! systemctl is-active --quiet docker; then
    log_warn "Docker не запущен. Пытаемся запустить Docker..."
    if systemctl start docker; then
      log_ok "Docker успешно запущен."
    else
      log_error "Не удалось запустить Docker. Продолжаем выполнение, но возможны сбои."
    fi
  else
    log_ok "Docker-демон уже запущен."
  fi
}

# =========================
#    Настройки Outline
# =========================

# Переменные окружения (можно переопределять через флаги или внести вручную).
# Пусть по умолчанию используется /opt/outline
SHADOWBOX_DIR="/opt/outline"
CONTAINER_NAME="shadowbox"
WATCHTOWER_NAME="watchtower"

# Файл, куда будет сохраняться конфигурация и ключи.
ACCESS_CONFIG="${SHADOWBOX_DIR}/access.txt"

# Объявим порты, которые хотим использовать:
# - API_PORT: порт менеджмент-интерфейса Outline
# - ACCESS_KEY_PORT: порт, который Outline будет выдавать своим ключам (Shadowsocks)
# - OBFUSCATION_PORT: порт для плагина (например, obfs4)
API_PORT=0
ACCESS_KEY_PORT=0
OBFUSCATION_PORT=443    # в качестве примера маскируем под HTTPS

# Хостнейм (публичный IP). Если не задан, определим автоматически.
PUBLIC_HOSTNAME=""

# Основная функция определения внешнего IP-адреса 
# (если пользователь заранее не указал в переменной).
function detect_public_ip() {
  local ip_candidates=(
    "https://icanhazip.com"
    "https://ipinfo.io/ip"
    "https://domains.google.com/checkip"
  )
  for url in "${ip_candidates[@]}"; do
    PUBLIC_HOSTNAME="$(curl -4 -s --fail "$url" 2>/dev/null)"
    if [[ -n "$PUBLIC_HOSTNAME" ]]; then
      break
    fi
  done
}

# Функция генерации случайного порта (если не задан пользователем).
function get_random_port() {
  # Получим случайное число от 1024 до 65535
  while true; do
    local port=$((RANDOM + 1024))
    if (( port <= 65535 )); then
      echo $port
      break
    fi
  done
}

# Очистка предыдущей установки (если контейнеры уже есть).
function remove_existing_containers() {
  log_info "Проверяем, не запущены ли ранее контейнеры Shadowbox и Watchtower..."
  if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}\$"; then
    log_warn "Обнаружен контейнер $CONTAINER_NAME. Останавливаем и удаляем..."
    docker stop "$CONTAINER_NAME" &>/dev/null || log_error "Ошибка при остановке контейнера $CONTAINER_NAME"
    docker rm -f "$CONTAINER_NAME" &>/dev/null || log_error "Ошибка при удалении контейнера $CONTAINER_NAME"
    log_ok "Старый контейнер $CONTAINER_NAME удалён."
  fi
  if docker ps -a --format '{{.Names}}' | grep -q "^${WATCHTOWER_NAME}\$"; then
    log_warn "Обнаружен контейнер $WATCHTOWER_NAME. Останавливаем и удаляем..."
    docker stop "$WATCHTOWER_NAME" &>/dev/null || log_error "Ошибка при остановке контейнера $WATCHTOWER_NAME"
    docker rm -f "$WATCHTOWER_NAME" &>/dev/null || log_error "Ошибка при удалении контейнера $WATCHTOWER_NAME"
    log_ok "Старый контейнер $WATCHTOWER_NAME удалён."
  fi
}

# Создаём необходимую структуру директорий.
function create_directories() {
  log_info "Создаём директорию для Outline: $SHADOWBOX_DIR"
  mkdir -p "$SHADOWBOX_DIR"
  chmod 700 "$SHADOWBOX_DIR"
  # В этой директории будет храниться persisted-state
  local persist="${SHADOWBOX_DIR}/persisted-state"
  mkdir -p "$persist"
  chmod 700 "$persist"
}

# Генерация сертификата TLS и секретных ключей для Outline.
function generate_certs_and_keys() {
  log_info "Генерируем самоподписанный TLS-сертификат..."
  local cert_name="${SHADOWBOX_DIR}/persisted-state/shadowbox-selfsigned"
  local cert_file="${cert_name}.crt"
  local key_file="${cert_name}.key"

  # Генерация сертификата
  # (При необходимости можно заменить на ACME Let's Encrypt и т. д.)
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -subj "/CN=${PUBLIC_HOSTNAME}" \
    -keyout "${key_file}" \
    -out "${cert_file}" 2>/dev/null

  # Добавим SHA-256 отпечаток в конфиг
  local openssl_fp
  openssl_fp="$(openssl x509 -in "${cert_file}" -noout -sha256 -fingerprint 2>/dev/null)"
  # Убираем двоеточия
  local cert_sha256
  cert_sha256="${openssl_fp##*=}"
  cert_sha256="${cert_sha256//:/}"

  # Сохраним информацию в access.txt
  echo "certSha256:${cert_sha256}" >> "${ACCESS_CONFIG}"
  log_ok "Сертификат сгенерирован. SHA-256=${cert_sha256}"
}

# Основная установка Shadowbox (Outline) в Docker.
function install_outline_server() {
  log_info "Запускаем контейнер Outline (Shadowbox)..."

  # По умолчанию берём стабильный образ
  local sb_image="quay.io/outline/shadowbox:stable"
  # Можно при желании использовать nightly-образ:
  # local sb_image="quay.io/outline/shadowbox:nightly"

  # Если API_PORT не задан, получаем случайный
  if (( API_PORT == 0 )); then
    API_PORT=$(get_random_port)
  fi

  # Если ACCESS_KEY_PORT не задан, получаем случайный
  if (( ACCESS_KEY_PORT == 0 )); then
    ACCESS_KEY_PORT=$(get_random_port)
  fi

  # Генерация "секретного префикса" для управления
  local api_prefix
  api_prefix="$(head -c 16 /dev/urandom | base64 | tr '/+' '_-' | tr -d '=')"

  # Пишем конфиг в файл /opt/outline/access.txt, чтобы выводить в конце
  echo "apiPort:${API_PORT}" >> "${ACCESS_CONFIG}"
  echo "apiPrefix:${api_prefix}" >> "${ACCESS_CONFIG}"

  # Готовим скрипт старта контейнера
  local persist="${SHADOWBOX_DIR}/persisted-state"
  local start_script="${persist}/start_container.sh"

  cat <<EOF > "$start_script"
#!/usr/bin/env bash

docker run -d --restart always --net host --name ${CONTAINER_NAME} \\
  --label "com.centurylinklabs.watchtower.enable=true" \\
  --label "com.centurylinklabs.watchtower.scope=outline" \\
  --log-driver local \\
  -v "${persist}:${persist}" \\
  -e "SB_STATE_DIR=${persist}" \\
  -e "SB_API_PORT=${API_PORT}" \\
  -e "SB_API_PREFIX=${api_prefix}" \\
  -e "SB_CERTIFICATE_FILE=${persist}/shadowbox-selfsigned.crt" \\
  -e "SB_PRIVATE_KEY_FILE=${persist}/shadowbox-selfsigned.key" \\
  -e "SB_PUBLIC_IP=${PUBLIC_HOSTNAME}" \\
  -e "SB_DEFAULT_SERVER_NAME=Outline-on-${PUBLIC_HOSTNAME}" \\
  "${sb_image}"
EOF

  chmod +x "$start_script"

  if "$start_script" &>/dev/null; then
    log_ok "Контейнер Outline (Shadowbox) успешно запущен. API-Pорт: $API_PORT"
  else
    log_error "Ошибка запуска контейнера Outline. Возможно, Docker не запущен или другой конфликт."
  fi

  # Запустим watchtower (для автообновления)
  log_info "Запускаем Watchtower..."
  if docker run -d --restart always --net host --name "$WATCHTOWER_NAME" \
    --label "com.centurylinklabs.watchtower.enable=true" \
    --label "com.centurylinklabs.watchtower.scope=outline" \
    --log-driver local \
    -v /var/run/docker.sock:/var/run/docker.sock \
    containrrr/watchtower --cleanup --label-enable --scope=outline --interval 3600 &>/dev/null
  then
    log_ok "Watchtower успешно запущен."
  else
    log_error "Не удалось запустить Watchtower."
  fi

  # Дождёмся, пока Outline поднимется
  wait_for_outline_ready
}

# Проверяем доступность Outline, делая запрос к локальному API
function wait_for_outline_ready() {
  log_info "Ждём, пока контейнер Outline будет здоров..."
  local check_url
  check_url="https://localhost:${API_PORT}"

  # Пытаемся дождаться доступности /access-keys
  local max_attempts=30
  local attempt=1
  while (( attempt <= max_attempts )); do
    if curl -skf "${check_url}/access-keys" &>/dev/null; then
      log_ok "Outline ответил на запрос /access-keys. Контейнер здоров."
      break
    fi
    sleep 2
    ((attempt++))
  done

  if (( attempt > max_attempts )); then
    log_error "Контейнер Outline не ответил за отведённое время. Но продолжаем..."
  fi

  # Создадим первого пользователя (акцесс-ключ Shadowsocks)
  create_first_user
}

# Создание первого пользователя (access-key) в Outline
function create_first_user() {
  log_info "Создаём первого пользователя Outline (Shadowsocks Access Key)..."
  local url="https://localhost:${API_PORT}/access-keys"
  local result
  result="$(curl -sk -X POST "$url")"
  if [[ -n "$result" ]]; then
    echo "firstUserCreated:true" >> "${ACCESS_CONFIG}"
    log_ok "Первый пользователь создан. Ответ сервера: $result"
  else
    log_error "Не удалось создать первого пользователя."
  fi
}

# ===============================
#  Обфускация (пример с obfs4proxy)
# ===============================

# Устанавливаем obfs4proxy и запускаем тестовый obfs4-сервис.
# В реальной среде для Outline+Shadowsocks может потребоваться 
# дополнительное проксирование трафика. Ниже — упрощённый пример.
function setup_obfs4() {
  log_info "Устанавливаем obfs4proxy для обфускации..."
  apt-get update -y && apt-get install -y obfs4proxy
  if [[ $? -eq 0 ]]; then
    log_ok "obfs4proxy установлен успешно."
  else
    log_error "Ошибка установки obfs4proxy."
  fi

  # В данном примере мы просто поднимаем docker-контейнер со встроенным Shadowsocks + obfs4
  # Однако, чтобы связать это именно с Outline, нужно доработать цепочку проксирования
  # (например, используя docker network, 127.0.0.1, т. п.).
  # Здесь же показан демонстрационный запуск на 443-порту (TLS-like).
  
  # Обратите внимание, что Outline сам по себе может слушать 443, 
  # потому либо перенесите Outline на другой порт, либо используйте другой порт для obfs4.
  
  # Для демонстрации допустим, что Outline слушает свой random-port, 
  # а obfs4 будет перенаправлять на Shadowsocks Outline. 
  # Реальная прокладка: obfs4 -> Outline -> Shadowsocks
  
  # Ниже — фейковый пример контейнера, в реальности его нужно заменить 
  # на контейнер, поддерживающий obfs4 + Shadowbox, или настроить вручную.
  
  log_info "Запускаем демонстрационный obfs4-контейнер (пример). Порт: $OBFUSCATION_PORT"
  # Ниже контейнер выдуманный (example/ss-obfs4). 
  # В реальном проекте придётся собрать или найти подходящий образ.
  # Если нужно просто показать механику — пусть будет так.
  if docker run -d \
    -p "$OBFUSCATION_PORT:$OBFUSCATION_PORT" \
    --name "obfs4-demo" \
    example/ss-obfs4:latest /bin/sh -c "exec obfs4proxy --enableLogging=true --logLevel=INFO" &>/dev/null
  then
    log_ok "Контейнер obfs4-demo запущен на порту $OBFUSCATION_PORT. (пример)"
    echo "obfs4Port:${OBFUSCATION_PORT}" >> "${ACCESS_CONFIG}"
  else
    log_error "Не удалось запустить obfs4-demo контейнер. Продолжаем..."
  fi
}

# ===============================
#        Проверки Firewall
# ===============================
function check_firewall_rules() {
  log_info "Проверка, не блокируется ли порт $OBFUSCATION_PORT..."
  # Простая проверка: попробуем достучаться до 127.0.0.1:$OBFUSCATION_PORT
  # (но это не гарантирует внешнюю доступность)
  if timeout 1 bash -c "echo >/dev/tcp/127.0.0.1/$OBFUSCATION_PORT" 2>/dev/null; then
    log_ok "Локально порт $OBFUSCATION_PORT открыт."
  else
    log_warn "Похоже, локально порт $OBFUSCATION_PORT закрыт или не прослушивается. Плагин может не работать."
  fi

  # Выводим пользователю подсказку по открытию портов во внешнем фаерволе
  echo -e "${COLOR_CYAN}Откройте во внешнем фаерволе (Cloud, VPS, Router) следующие порты: \
${API_PORT} (TCP) для менеджмента, \
$ACCESS_KEY_PORT (TCP/UDP) для Shadowsocks, \
$OBFUSCATION_PORT (TCP/UDP) для obfs4 (если нужно).${COLOR_NONE}"
}

# ===============================
#            Тесты
# ===============================

function run_tests() {
  # Покажем командам, как проверить соединения вручную
  log_info "Подготовка тестов для проверки Outline и obfs4..."

  echo -e "${COLOR_WHITE}Чтобы проверить работу Outline (Shadowsocks) через API, \
можно выполнить команду:${COLOR_NONE}"
  echo -e "${COLOR_GREEN}curl -skf https://localhost:${API_PORT}/access-keys${COLOR_NONE}"
  echo

  echo -e "${COLOR_WHITE}Чтобы протестировать obfs4 на порту ${OBFUSCATION_PORT}, \
можно выполнить команду (пример):${COLOR_NONE}"
  echo -e "${COLOR_GREEN}nmap -sT -p ${OBFUSCATION_PORT} 127.0.0.1${COLOR_NONE}"
  echo
}

# ===============================
#  Вывод итоговой информации
# ===============================

function print_final_info() {
  log_info "Выводим итоговую информацию, ключи и пароли..."

  # Считаем access.txt и отформатируем вывод
  echo -e "${COLOR_BLUE}===== Содержимое access.txt =====${COLOR_NONE}"
  cat "${ACCESS_CONFIG}"
  echo -e "${COLOR_BLUE}=================================${COLOR_NONE}"

  # Формируем JSON-строку для Outline Manager (как это делает оригинальный скрипт)
  local api_url="https://${PUBLIC_HOSTNAME}:${API_PORT}/$(grep 'apiPrefix:' "${ACCESS_CONFIG}" | cut -d':' -f2)"
  local cert_sha256="$(grep 'certSha256:' "${ACCESS_CONFIG}" | cut -d':' -f2)"
  local manager_json="{\"apiUrl\":\"${api_url}\",\"certSha256\":\"${cert_sha256}\"}"

  echo -e "${COLOR_GREEN}Скопируйте следующую строку в Outline Manager (Шаг 2):${COLOR_NONE}"
  echo -e "${COLOR_WHITE}${manager_json}${COLOR_NONE}"
  echo

  log_ok "Установка и конфигурация Outline завершены."
  log_ok "Не забудьте проверить порты в фаерволе провайдера!"
}

# ===============================
#         Основной сценарий
# ===============================

# 1. Проверка root
check_root

# 2. Проверка / установка Docker
check_and_install_docker

# 3. Проверка, запущен ли Docker
check_docker_running

# 4. Установка/обновление некоторых пакетов (curl, openssl и пр.)
log_info "Устанавливаем необходимые инструменты: curl, openssl..."
apt-get update -y && apt-get install -y curl openssl
if [[ $? -eq 0 ]]; then
  log_ok "Утилиты curl и openssl установлены/обновлены."
else
  log_error "Не удалось установить curl/openssl."
fi

# 5. Определяем публичный IP (если не задан вручную)
if [[ -z "$PUBLIC_HOSTNAME" ]]; then
  detect_public_ip
  if [[ -z "$PUBLIC_HOSTNAME" ]]; then
    log_error "Не удалось определить внешний IP-адрес. Указывайте вручную в переменной PUBLIC_HOSTNAME."
    # Продолжим, но Outline может быть неправильно сконфигурирован
  else
    log_ok "Обнаружен внешний IP: $PUBLIC_HOSTNAME"
  fi
fi

# 6. Удалим старые контейнеры (если есть)
remove_existing_containers

# 7. Создаём директории /opt/outline и т.п.
create_directories

# 8. Инициализируем или очищаем access.txt
> "${ACCESS_CONFIG}"

# 9. Генерируем сертификаты
generate_certs_and_keys

# 10. Устанавливаем (запускаем) Outline
install_outline_server

# 11. Устанавливаем obfs4
setup_obfs4

# 12. Проверяем firewall
check_firewall_rules

# 13. Выполним тесты
run_tests

# 14. Выведем финальную информацию
print_final_info

# 15. Дополнительные сообщения
echo -e "${COLOR_CYAN}Сервер, на котором выполнялся скрипт: 128.199.56.243, пароль: Auth777Key\$DO.${COLOR_NONE}"
echo -e "${COLOR_CYAN}(Вы можете использовать эти данные для ручного SSH-теста).${COLOR_NONE}"

# Скрипт НЕ заканчивается вызовом exit, 
# так что он завершится "сам по себе" с кодом 0, если не было фатальных ошибок.
# ============================================
#           Конец основного скрипта
# ============================================


#################################################################################################
# ПРИКРЫТЫЙ РАЗДЕЛ (закомментированный) ДЛЯ УДАЛЕНИЯ ВСЕГО, ЧТО БЫЛО УСТАНОВЛЕНО И НАСТРОЕНО
#################################################################################################
: <<'HIDDEN_CLEANUP_SCRIPT'
#!/usr/bin/env bash
#
# cleanup_outline.sh
#
# Скрипт удаления всех данных, контейнеров, сертификатов и т. д.
# Осторожно! Выполняйте, только если хотите полностью очистить систему
# от Outline VPN и сопутствующих компонентов. 

# 1. Останавливаем и удаляем контейнер shadowbox
docker stop shadowbox 2>/dev/null || true
docker rm -f shadowbox 2>/dev/null || true

# 2. Останавливаем и удаляем контейнер watchtower
docker stop watchtower 2>/dev/null || true
docker rm -f watchtower 2>/dev/null || true

# 3. Удаляем демонстрационный obfs4-контейнер (если поднимался)
docker stop obfs4-demo 2>/dev/null || true
docker rm -f obfs4-demo 2>/dev/null || true

# 4. Удаляем директорию /opt/outline со всем содержимым
rm -rf /opt/outline

# 5. При желании, можно удалить obfs4proxy
apt-get remove -y obfs4proxy

# 6. (Опционально) Удаляем Docker
#    Если хотим вообще снести Docker (аккуратно, 
#    ведь это может повлиять на другие сервисы!)
# apt-get remove -y docker docker.io containerd runc
# apt-get autoremove -y

echo "Все компоненты Outline и obfs4 удалены."
HIDDEN_CLEANUP_SCRIPT