#!/bin/bash
#
# Outline Server installation script with basic Shadowsocks "obfs" plugin example
# running on standard HTTPS ports (80 for API, 443 for keys).
#
# ------------------------------------------------------------------------------
# ВАЖНО: Этот скрипт основан на официальном install_server.sh от Outline,
#        но содержит демонстрационные изменения для включения obfs-трафика
#        и запуска на портах 80/443. В реальной среде необходимо убедиться,
#        что в используемом Docker-образе есть поддержка obfs, либо собрать
#        собственный образ с нужными плагинами.
# ------------------------------------------------------------------------------

set -euo pipefail

function display_usage() {
  cat <<EOF
Usage: $(basename "$0") [--hostname <hostname>] [--api-port <port>] [--keys-port <port>]

  --hostname   The hostname to be used to access the management API and access keys
  --api-port   The port number for the management API (default: 80)
  --keys-port  The port number for the access keys (default: 443)

Example:
  sudo ./$(basename "$0") --hostname your_server_ip
EOF
}

# ------------------------------------------------------------------------------
# Ниже идёт та же логика, что и в оригинальном install_server.sh,
# с внесёнными корректировками (по умолчанию порты 80/443 + obfs).
# ------------------------------------------------------------------------------

readonly SENTRY_LOG_FILE=${SENTRY_LOG_FILE:-}
FULL_LOG="$(mktemp -t outline_logXXXXXXXXXX)"
LAST_ERROR="$(mktemp -t outline_last_errorXXXXXXXXXX)"
readonly FULL_LOG LAST_ERROR

# -----------------------------------
#    Вспомогательные функции лога
# -----------------------------------
function log_command() {
  "$@" > >(tee -a "${FULL_LOG}") 2> >(tee -a "${FULL_LOG}" > "${LAST_ERROR}")
}

function log_error() {
  local -r ERROR_TEXT="\033[0;31m"  # red
  local -r NO_COLOR="\033[0m"
  echo -e "${ERROR_TEXT}$1${NO_COLOR}"
  echo "$1" >> "${FULL_LOG}"
}

function log_for_sentry() {
  if [[ -n "${SENTRY_LOG_FILE}" ]]; then
    echo "[$(date '+%Y-%m-%d@%H:%M:%S')] install_obfs_outline.sh" "$@" >> "${SENTRY_LOG_FILE}"
  fi
  echo "$@" >> "${FULL_LOG}"
}

function log_start_step() {
  log_for_sentry "$@"
  local -r str="> $*"
  local -ir lineLength=47
  echo -n "${str}"
  local -ir numDots=$(( lineLength - ${#str} - 1 ))
  if (( numDots > 0 )); then
    echo -n " "
    for _ in $(seq 1 "${numDots}"); do echo -n .; done
  fi
  echo -n " "
}

function run_step() {
  local -r msg="$1"
  log_start_step "${msg}"
  shift
  if log_command "$@"; then
    echo "OK"
  else
    return
  fi
}

function confirm() {
  echo -n "> $1 [Y/n] "
  local RESPONSE
  read -r RESPONSE
  RESPONSE=$(echo "${RESPONSE}" | tr '[:upper:]' '[:lower:]') || return
  [[ -z "${RESPONSE}" || "${RESPONSE}" == "y" || "${RESPONSE}" == "yes" ]]
}

function finish() {
  local -ir EXIT_CODE=$?
  if (( EXIT_CODE != 0 )); then
    if [[ -s "${LAST_ERROR}" ]]; then
      log_error "\nLast error: $(< "${LAST_ERROR}")" >&2
    fi
    log_error "\nSorry! Something went wrong. Please send us the log below:\nFull log: ${FULL_LOG}" >&2
  else
    rm "${FULL_LOG}"
  fi
  rm "${LAST_ERROR}"
}
trap finish EXIT

# -----------------------------------
#    Функции проверки и установки
# -----------------------------------
function command_exists {
  command -v "$@" &> /dev/null
}

function verify_docker_installed() {
  if command_exists docker; then
    return 0
  fi
  log_error "Docker is NOT installed"
  if ! confirm "Would you like to install Docker automatically (curl https://get.docker.com/ | sh)?"; then
    exit 0
  fi
  if ! run_step "Installing Docker" install_docker; then
    log_error "Docker installation failed, please install manually."
    exit 1
  fi
  log_start_step "Verifying Docker installation"
  command_exists docker
}

function install_docker() {
  (
    umask 0022
    curl -sSL https://get.docker.com/ | sh
  ) >&2
}

function verify_docker_running() {
  local STDERR_OUTPUT
  STDERR_OUTPUT="$(docker info 2>&1 >/dev/null)" || true
  local -ir RET=$?
  if (( RET == 0 )); then
    return 0
  elif [[ "${STDERR_OUTPUT}" == *"Is the docker daemon running"* ]]; then
    start_docker
    return
  fi
  return "${RET}"
}

function start_docker() {
  systemctl enable --now docker.service >&2
}

function docker_container_exists() {
  docker ps -a --format '{{.Names}}' | grep --quiet "^$1$"
}

function remove_docker_container() {
  docker rm -f "$1" >&2
}

function get_random_port() {
  local -i num=0
  until (( 1024 <= num && num < 65536)); do
    num=$(( RANDOM + (RANDOM % 2) * 32768 ))
  done
  echo "${num}"
}

# -----------------------------------
#    Настройка Outline + obfs
# -----------------------------------

# Папка, куда ставится Outline
export SHADOWBOX_DIR="${SHADOWBOX_DIR:-/opt/outline}"
mkdir -p "${SHADOWBOX_DIR}"
chmod u+s,ug+rwx,o-rwx "${SHADOWBOX_DIR}"

# Имя контейнера
export CONTAINER_NAME="${CONTAINER_NAME:-shadowbox}"

# Где хранить доступы
ACCESS_CONFIG="${ACCESS_CONFIG:-${SHADOWBOX_DIR}/access.txt}"

# Docker-образ (должен содержать obfs-плагин, если нужно реальное шифрование)
export SB_IMAGE="${SB_IMAGE:-quay.io/outline/shadowbox:stable}"

# Для демонстрации указываем базовые переменные plugin
# Обратите внимание, что не все образы Outline поддерживают эти переменные.
export SHADOWSOCKS_PLUGIN="obfs-server"
# Пример: шифруем трафик как HTTPS (tls) и включаем fast-open (по желанию)
export SHADOWSOCKS_PLUGIN_OPTIONS="obfs=tls;fast-open"

# -----------------------------------
#   Установка и запуск Outline VPN
# -----------------------------------

# Создаём директорию для постоянного хранения (persisted-state)
function create_persisted_state_dir() {
  readonly STATE_DIR="${SHADOWBOX_DIR}/persisted-state"
  mkdir -p "${STATE_DIR}"
  chmod ug+rwx,g+s,o-rwx "${STATE_DIR}"
}

function safe_base64() {
  local url_safe
  url_safe="$(base64 -w 0 - | tr '/+' '_-')"
  echo -n "${url_safe%%=*}"
}

function generate_secret_key() {
  SB_API_PREFIX="$(head -c 16 /dev/urandom | safe_base64)"
  readonly SB_API_PREFIX
}

function generate_certificate() {
  local -r CERTIFICATE_NAME="${STATE_DIR}/shadowbox-selfsigned"
  readonly SB_CERTIFICATE_FILE="${CERTIFICATE_NAME}.crt"
  readonly SB_PRIVATE_KEY_FILE="${CERTIFICATE_NAME}.key"
  declare -a openssl_req_flags=(
    -x509 -nodes -days 36500 -newkey rsa:4096
    -subj "/CN=${PUBLIC_HOSTNAME}"
    -keyout "${SB_PRIVATE_KEY_FILE}" -out "${SB_CERTIFICATE_FILE}"
  )
  openssl req "${openssl_req_flags[@]}" >&2
}

function generate_certificate_fingerprint() {
  local CERT_OPENSSL_FINGERPRINT
  CERT_OPENSSL_FINGERPRINT="$(openssl x509 -in "${SB_CERTIFICATE_FILE}" -noout -sha256 -fingerprint)" || return
  local CERT_HEX_FINGERPRINT
  CERT_HEX_FINGERPRINT="$(echo "${CERT_OPENSSL_FINGERPRINT#*=}" | tr -d :)" || return
  output_config "certSha256:${CERT_HEX_FINGERPRINT}"
}

function output_config() {
  echo "$@" >> "${ACCESS_CONFIG}"
}

function parse_flags() {
  local params
  # Переопределим порты по умолчанию: API=80, KEY=443
  # Пользователь может изменить их через --api-port и --keys-port
  DEFAULT_API_PORT=80
  DEFAULT_KEYS_PORT=443

  params="$(getopt --longoptions hostname:,api-port:,keys-port: -n "$0" -- "$@")" || {
    display_usage
    exit 1
  }
  eval set -- "${params}"

  FLAGS_HOSTNAME=""
  FLAGS_API_PORT=${DEFAULT_API_PORT}
  FLAGS_KEYS_PORT=${DEFAULT_KEYS_PORT}

  while (( $# > 0 )); do
    local flag="$1"
    shift
    case "${flag}" in
      --hostname)
        FLAGS_HOSTNAME="$1"
        shift
        ;;
      --api-port)
        FLAGS_API_PORT="$1"
        shift
        ;;
      --keys-port)
        FLAGS_KEYS_PORT="$1"
        shift
        ;;
      --)
        break
        ;;
      *)
        log_error "Unsupported flag: ${flag}"
        display_usage
        exit 1
        ;;
    esac
  done

  export PUBLIC_HOSTNAME="${FLAGS_HOSTNAME}"
  export API_PORT="${FLAGS_API_PORT}"
  export KEYS_PORT="${FLAGS_KEYS_PORT}"
}

function is_valid_port() {
  (( 0 < "$1" && "$1" <= 65535 ))
}

function join_by() {
  local IFS="$1"
  shift
  echo "$*"
}

function escape_json_string() {
  local input="$1"
  local i
  for ((i = 0; i < ${#input}; i++)); do
    local char="${input:i:1}"
    local escaped="${char}"
    case "${char}" in
      '"') escaped="\\\"";;
      '\\') escaped="\\\\";;
      $'\b') escaped="\\b";;
      $'\f') escaped="\\f";;
      $'\n') escaped="\\n";;
      $'\r') escaped="\\r";;
      $'\t') escaped="\\t";;
    esac
    printf "%s" "${escaped}"
  done
}

function write_config() {
  local -a config=()
  # Передаём порт для ключей, чтобы Outline создавал новые ключи на 443
  config+=("\"portForNewAccessKeys\": ${KEYS_PORT}")
  config+=("\"hostname\": \"$(escape_json_string "${PUBLIC_HOSTNAME}")\"")
  echo "{$(join_by , "${config[@]}")}" > "${STATE_DIR}/shadowbox_server_config.json"
}

# Основная функция запуска контейнера Outline
function start_shadowbox() {
  local -r START_SCRIPT="${STATE_DIR}/start_container.sh"
  cat <<-EOF > "${START_SCRIPT}"
#!/usr/bin/env bash
set -eu

docker stop "${CONTAINER_NAME}" 2> /dev/null || true
docker rm -f "${CONTAINER_NAME}" 2> /dev/null || true

# Запуск с нужными переменными среды
docker_command=(
  docker run -d
  --name "${CONTAINER_NAME}" 
  --restart always
  --net host

  # Watchtower
  --label 'com.centurylinklabs.watchtower.enable=true'
  --label 'com.centurylinklabs.watchtower.scope=outline'

  --log-driver local

  -v "${STATE_DIR}:${STATE_DIR}"
  -e "SB_STATE_DIR=${STATE_DIR}"

  # API порт (по умолчанию 80)
  -e "SB_API_PORT=${API_PORT}"
  # SHADOWSOCKS_EXTRA_ARGS передадим как переменные плагина
  -e "SHADOWSOCKS_PLUGIN=${SHADOWSOCKS_PLUGIN}"
  -e "SHADOWSOCKS_PLUGIN_OPTIONS=${SHADOWSOCKS_PLUGIN_OPTIONS}"

  -e "SB_API_PREFIX=${SB_API_PREFIX}"
  -e "SB_CERTIFICATE_FILE=${SB_CERTIFICATE_FILE}"
  -e "SB_PRIVATE_KEY_FILE=${SB_PRIVATE_KEY_FILE}"

  "${SB_IMAGE}"
)

"\${docker_command[@]}"
EOF
  chmod +x "${START_SCRIPT}"
  log_command "${START_SCRIPT}" >/dev/null
}

function start_watchtower() {
  local -ir WATCHTOWER_REFRESH_SECONDS="${WATCHTOWER_REFRESH_SECONDS:-3600}"
  local -ar docker_watchtower_flags=(
    --name watchtower
    --log-driver local
    --restart always
    -v /var/run/docker.sock:/var/run/docker.sock
    --label 'com.centurylinklabs.watchtower.enable=true'
    --label 'com.centurylinklabs.watchtower.scope=outline'
  )
  docker run -d "${docker_watchtower_flags[@]}" containrrr/watchtower \
    --cleanup --label-enable --scope=outline --tlsverify \
    --interval "${WATCHTOWER_REFRESH_SECONDS}" >/dev/null
}

function wait_shadowbox() {
  local local_api="https://localhost:${API_PORT}/${SB_API_PREFIX}"
  until curl --silent --show-error --fail --insecure "${local_api}/access-keys" >/dev/null 2>&1; do
    sleep 1
  done
}

function create_first_user() {
  local local_api="https://localhost:${API_PORT}/${SB_API_PREFIX}"
  curl --silent --show-error --fail --insecure --request POST "${local_api}/access-keys" >/dev/null
}

function add_api_url_to_config() {
  local public_api="https://${PUBLIC_HOSTNAME}:${API_PORT}/${SB_API_PREFIX}"
  output_config "apiUrl:${public_api}"
}

function check_firewall() {
  local local_api="https://localhost:${API_PORT}/${SB_API_PREFIX}"
  local public_api="https://${PUBLIC_HOSTNAME}:${API_PORT}/${SB_API_PREFIX}"
  local -i access_key_port
  access_key_port="$(curl --insecure --silent --show-error --fail "${local_api}/access-keys" \
    | docker exec -i "${CONTAINER_NAME}" node -e '
      const fs = require("fs");
      const accessKeys = JSON.parse(fs.readFileSync(0, {encoding: "utf-8"}));
      console.log(accessKeys["accessKeys"][0]["port"]);
    ' || echo 443 )"

  if ! curl --max-time 5 --cacert "${SB_CERTIFICATE_FILE}" -sSf "${public_api}/access-keys" >/dev/null 2>&1; then
    log_error "Looks like port ${API_PORT} or ${access_key_port} is blocked by firewall"
  fi
  cat <<MSG >> "${FULL_LOG}"

If you have connection problems, please ensure ports ${API_PORT} (TCP) and ${access_key_port} (TCP/UDP)
are open in your firewall or cloud provider settings.
MSG
}

function set_hostname_if_empty() {
  if [[ -n "${PUBLIC_HOSTNAME}" ]]; then
    return
  fi
  # Простая попытка получить внешний IP
  local -ar urls=(
    'https://icanhazip.com/'
    'https://ipinfo.io/ip'
    'https://domains.google.com/checkip'
  )
  for url in "${urls[@]}"; do
    set +e
    PUBLIC_HOSTNAME="$(curl -4 -sSL --fail "${url}")"
    if [[ -n "${PUBLIC_HOSTNAME}" ]]; then
      set -e
      return
    fi
    set -e
  done
  echo "Failed to determine the server IP address. Use --hostname <server_ip>."
  exit 1
}

function install_shadowbox() {
  # Для x86_64
  local MACHINE_TYPE
  MACHINE_TYPE="$(uname -m)"
  if [[ "${MACHINE_TYPE}" != "x86_64" ]]; then
    log_error "Only x86_64 is supported. Found: ${MACHINE_TYPE}"
    exit 1
  fi

  # Ограничение прав
  umask 0007

  run_step "Verifying Docker is installed" verify_docker_installed
  run_step "Verifying Docker daemon is running" verify_docker_running

  log_for_sentry "Creating Outline directory at ${SHADOWBOX_DIR}"

  # Если в access.txt что-то есть, сделаем бэкап
  if [[ -s "${ACCESS_CONFIG}" ]]; then
    cp "${ACCESS_CONFIG}" "${ACCESS_CONFIG}.bak"
    true > "${ACCESS_CONFIG}"
  fi

  run_step "Creating persisted state dir" create_persisted_state_dir
  run_step "Generating secret key" generate_secret_key
  run_step "Setting hostname if empty" set_hostname_if_empty
  run_step "Generating TLS certificate" generate_certificate
  run_step "Generating cert fingerprint" generate_certificate_fingerprint
  run_step "Writing Outline config" write_config
  run_step "Starting Outline container" start_shadowbox
  run_step "Starting Watchtower" start_watchtower

  run_step "Waiting for Outline to be healthy" wait_shadowbox
  run_step "Creating first user" create_first_user
  run_step "Adding API URL to config" add_api_url_to_config
  run_step "Checking firewall" check_firewall

  # Получаем apiUrl и certSha256 для вывода
  function get_field_value {
    grep "$1" "${ACCESS_CONFIG}" | sed "s/$1://"
  }

  cat <<EOF

============================================================
CONGRATULATIONS! Your Outline (with obfs) server is running.

Please copy the following line (including curly brackets)
into Step 2 of the Outline Manager interface:

{"apiUrl":"$(get_field_value apiUrl)","certSha256":"$(get_field_value certSha256)"}

Your API is listening on port ${API_PORT}, your keys on port ${KEYS_PORT}.
Obfuscation plugin: $SHADOWSOCKS_PLUGIN (options: $SHADOWSOCKS_PLUGIN_OPTIONS)

The full log is in: ${FULL_LOG}
============================================================
EOF
}

# -----------------------------------
#    MAIN
# -----------------------------------
function main() {
  parse_flags "$@"

  # Валидация портов (пользователь может передать --api-port 0 и т.п.)
  if ! is_valid_port "${API_PORT}"; then
    log_error "Invalid API port: ${API_PORT}"
    exit 1
  fi
  if ! is_valid_port "${KEYS_PORT}"; then
    log_error "Invalid keys port: ${KEYS_PORT}"
    exit 1
  fi
  if (( API_PORT == KEYS_PORT )); then
    log_error "API port must differ from keys port!"
    exit 1
  fi

  install_shadowbox
}

main "$@"

