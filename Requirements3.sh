#!/usr/bin/env bash
#
# Скрипт для установки Outline Server, маскирующегося под HTTPS,
# с дополнительными настройками для усложнения детекта VPN-трафика.
#
# Поддерживает:
#  - Автоустановку Docker, если он не установлен
#  - Запуск Outline на 443 порту (или другом)
#  - (Опционально) Установку Let’s Encrypt сертификата через certbot
#  - Настройку iptables для маскировки
#  - Включение TCP BBR
#
# Использование:
#   ./install_outline_stealth.sh [--hostname <hostname_or_ip>] [--api-port <port>] [--keys-port <port>]
#

set -euo pipefail

################################################################################
###                               ПАРАМЕТРЫ                                  ###
################################################################################

# Если нужно использовать реальный сертификат, включите true:
USE_CERTBOT=true
# Ваш домен (если хотите использовать Let’s Encrypt). Можно задать
# через флаг --hostname или прописать жестко здесь:
DEFAULT_DOMAIN=""

# Если у вас есть уже сертификат (fullchain.pem, privkey.pem), можно указать пути:
EXISTING_CERT_PATH=""
EXISTING_KEY_PATH=""

# Для Let’s Encrypt certbot:
EMAIL_FOR_CERTBOT="admin@example.com"

# Включить TCP BBR
ENABLE_BBR=true

################################################################################
###                             ИСХОДНЫЙ СКРИПТ                              ###
################################################################################

function display_usage() {
  cat <<EOF
Usage: $0 [--hostname <hostname>] [--api-port <port>] [--keys-port <port>]
  --hostname   The hostname or IP to be used (if omitted, autodetect)
  --api-port   The port number for the management API (default 443)
  --keys-port  The port number for the access keys (default random)
EOF
}

readonly SENTRY_LOG_FILE=${SENTRY_LOG_FILE:-}
FULL_LOG="$(mktemp -t outline_logXXXXXXXXXX)"
LAST_ERROR="$(mktemp -t outline_last_errorXXXXXXXXXX)"
readonly FULL_LOG LAST_ERROR

function log_command() {
  "$@" > >(tee -a "${FULL_LOG}") 2> >(tee -a "${FULL_LOG}" > "${LAST_ERROR}")
}

function log_error() {
  local -r RED="\033[0;31m"
  local -r NO_COLOR="\033[0m"
  echo -e "${RED}$1${NO_COLOR}"
  echo "$1" >> "${FULL_LOG}"
}

function log_for_sentry() {
  if [[ -n "${SENTRY_LOG_FILE}" ]]; then
    echo "[$(date "+%Y-%m-%d@%H:%M:%S")] install_server.sh" "$@" >> "${SENTRY_LOG_FILE}"
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

function command_exists {
  command -v "$@" &> /dev/null
}

function finish {
  local -ir EXIT_CODE=$?
  if (( EXIT_CODE != 0 )); then
    if [[ -s "${LAST_ERROR}" ]]; then
      log_error "\nLast error: $(< "${LAST_ERROR}")" >&2
    fi
    log_error "\nSomething went wrong. Full log: ${FULL_LOG}" >&2
  else
    rm "${FULL_LOG}"
  fi
  rm "${LAST_ERROR}"
}
trap finish EXIT

function fetch() {
  curl --silent --show-error --fail "$@"
}

function install_docker() {
  (
    umask 0022
    fetch https://get.docker.com/ | sh
  ) >&2
}

function start_docker() {
  systemctl enable --now docker.service >&2 || true
}

function verify_docker_installed() {
  if command_exists docker; then
    return 0
  fi
  log_error "Docker NOT INSTALLED"
  if ! confirm "Install Docker automatically? (curl https://get.docker.com/ | sh)"; then
    exit 1
  fi
  if ! run_step "Installing Docker" install_docker; then
    log_error "Docker installation failed. Visit https://docs.docker.com/install for manual instructions."
    exit 1
  fi
}

function verify_docker_running() {
  local STDERR_OUTPUT
  STDERR_OUTPUT="$(docker info 2>&1 >/dev/null)" || true
  if [[ "$STDERR_OUTPUT" == *"Is the docker daemon running"* ]]; then
    start_docker
  fi
}

function docker_container_exists() {
  docker ps -a --format '{{.Names}}'| grep --quiet "^$1$"
}

function remove_docker_container() {
  docker rm -f "$1" >&2 || true
}

function handle_docker_container_conflict() {
  local -r CONTAINER_NAME="$1"
  local -r EXIT_ON_NEGATIVE_USER_RESPONSE="$2"
  local PROMPT="The container name \"${CONTAINER_NAME}\" already exists."
  if ! confirm "${PROMPT} Remove and replace it?"; then
    if [[ "${EXIT_ON_NEGATIVE_USER_RESPONSE}" == 'true' ]]; then
      exit 0
    fi
    return 0
  fi
  if run_step "Removing ${CONTAINER_NAME} container" remove_docker_container "${CONTAINER_NAME}"; then
    log_start_step "Restarting ${CONTAINER_NAME}"
    "start_${CONTAINER_NAME}"
    return $?
  fi
  return 1
}

function get_random_port {
  local -i num=0
  until (( 1024 <= num && num < 65536)); do
    num=$(( RANDOM + (RANDOM % 2) * 32768 ))
  done
  echo "${num}"
}

function create_persisted_state_dir() {
  readonly STATE_DIR="${SHADOWBOX_DIR}/persisted-state"
  mkdir -p "${STATE_DIR}"
  chmod ug+rwx,g+s,o-rwx "${STATE_DIR}"
}

function safe_base64() {
  local url_safe
  # -w 0 не у всех дистрибутивов есть, но обычно в современных base64 есть
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
    -x509 -nodes -days 3650 -newkey rsa:2048
    -subj "/CN=${PUBLIC_HOSTNAME}"
    -keyout "${SB_PRIVATE_KEY_FILE}" -out "${SB_CERTIFICATE_FILE}"
  )
  openssl req "${openssl_req_flags[@]}" >&2
}

function generate_certificate_fingerprint() {
  local CERT_OPENSSL_FINGERPRINT
  CERT_OPENSSL_FINGERPRINT="$(openssl x509 -in "${SB_CERTIFICATE_FILE}" -noout -sha256 -fingerprint)" || return
  local CERT_HEX_FINGERPRINT
  CERT_HEX_FINGERPRINT="$(echo "${CERT_OPENSSL_FINGERPRINT#*=}" | tr -d :)"
  output_config "certSha256:${CERT_HEX_FINGERPRINT}"
}

function join() {
  local IFS="$1"
  shift
  echo "$*"
}

function write_config() {
  local -a config=()
  if (( FLAGS_KEYS_PORT != 0 )); then
    config+=("\"portForNewAccessKeys\": ${FLAGS_KEYS_PORT}")
  fi
  if [[ -n "${SB_DEFAULT_SERVER_NAME:-}" ]]; then
    config+=("\"name\": \"$(escape_json_string "${SB_DEFAULT_SERVER_NAME}")\"")
  fi
  config+=("\"hostname\": \"$(escape_json_string "${PUBLIC_HOSTNAME}")\"")
  echo "{$(join , "${config[@]}")}" > "${STATE_DIR}/shadowbox_server_config.json"
}

function start_shadowbox() {
  local -r START_SCRIPT="${STATE_DIR}/start_container.sh"
  cat <<-EOF > "${START_SCRIPT}"
#!/usr/bin/env bash
set -eu

docker stop "${CONTAINER_NAME}" 2> /dev/null || true
docker rm -f "${CONTAINER_NAME}" 2> /dev/null || true

docker_command=(
  docker
  run
  -d
  --name "${CONTAINER_NAME}"
  --restart always
  --net host

  --label 'com.centurylinklabs.watchtower.enable=true'
  --label 'com.centurylinklabs.watchtower.scope=outline'
  --log-driver local

  -v "${STATE_DIR}:${STATE_DIR}"
  -e "SB_STATE_DIR=${STATE_DIR}"
  -e "SB_API_PORT=${API_PORT}"
  -e "SB_API_PREFIX=${SB_API_PREFIX}"
  -e "SB_CERTIFICATE_FILE=${SB_CERTIFICATE_FILE}"
  -e "SB_PRIVATE_KEY_FILE=${SB_PRIVATE_KEY_FILE}"
  -e "SB_METRICS_URL=${SB_METRICS_URL:-}"

  "${SB_IMAGE}"
)
"\${docker_command[@]}"
EOF

  chmod +x "${START_SCRIPT}"
  local STDERR_OUTPUT
  STDERR_OUTPUT="$({ "${START_SCRIPT}" >/dev/null; } 2>&1)" && return
  readonly STDERR_OUTPUT
  log_error "FAILED"
  if docker_container_exists "${CONTAINER_NAME}"; then
    handle_docker_container_conflict "${CONTAINER_NAME}" true
    return
  else
    log_error "${STDERR_OUTPUT}"
    return 1
  fi
}

function start_watchtower() {
  local -ir WT_REFRESH="${WATCHTOWER_REFRESH_SECONDS:-3600}"
  local -ar docker_watchtower_flags=(--name watchtower --log-driver local --restart always \
    --label 'com.centurylinklabs.watchtower.enable=true' \
    --label 'com.centurylinklabs.watchtower.scope=outline' \
    -v /var/run/docker.sock:/var/run/docker.sock)
  local STDERR_OUTPUT
  STDERR_OUTPUT="$(docker run -d "${docker_watchtower_flags[@]}" containrrr/watchtower --cleanup --label-enable --scope=outline --tlsverify --interval "${WT_REFRESH}" 2>&1 >/dev/null)" && return
  readonly STDERR_OUTPUT
  log_error "FAILED"
  if docker_container_exists watchtower; then
    handle_docker_container_conflict watchtower false
    return
  else
    log_error "${STDERR_OUTPUT}"
    return 1
  fi
}

function wait_shadowbox() {
  until fetch --insecure "${LOCAL_API_URL}/access-keys" >/dev/null; do sleep 1; done
}

function create_first_user() {
  fetch --insecure --request POST "${LOCAL_API_URL}/access-keys" >&2
}

function output_config() {
  echo "$@" >> "${ACCESS_CONFIG}"
}

function add_api_url_to_config() {
  output_config "apiUrl:${PUBLIC_API_URL}"
}

function check_firewall() {
  local -i ACCESS_KEY_PORT
  ACCESS_KEY_PORT=$(fetch --insecure "${LOCAL_API_URL}/access-keys" |
    docker exec -i "${CONTAINER_NAME}" node -e '
      const fs = require("fs");
      const accessKeys = JSON.parse(fs.readFileSync(0, {encoding: "utf-8"}));
      console.log(accessKeys["accessKeys"][0]["port"]);
    ')

  if ! fetch --max-time 5 --cacert "${SB_CERTIFICATE_FILE}" "${PUBLIC_API_URL}/access-keys" >/dev/null; then
     FIREWALL_STATUS="Incoming connections seem BLOCKED on ports ${API_PORT} and ${ACCESS_KEY_PORT}."
  else
     FIREWALL_STATUS="Firewall check passed. If you have connection problems, check your router/cloud firewalls."
  fi

  FIREWALL_STATUS+="

Open these ports:
- Management port ${API_PORT}, TCP
- Access key port ${ACCESS_KEY_PORT}, TCP/UDP
"
}

function set_hostname() {
  local -ar urls=(
    'https://icanhazip.com/'
    'https://ipinfo.io/ip'
    'https://domains.google.com/checkip'
  )
  for url in "${urls[@]}"; do
    PUBLIC_HOSTNAME="$(fetch --ipv4 "${url}")" && return
  done
  echo "Failed to determine IP. Use --hostname <server_ip>." >&2
  return 1
}

function install_outline() {
  local MACHINE_TYPE
  MACHINE_TYPE="$(uname -m)"
  if [[ "${MACHINE_TYPE}" != "x86_64" ]]; then
    log_error "Unsupported machine type: ${MACHINE_TYPE}"
    exit 1
  fi

  umask 0007
  export CONTAINER_NAME="${CONTAINER_NAME:-shadowbox}"

  run_step "Verifying Docker installed" verify_docker_installed
  run_step "Verifying Docker daemon running" verify_docker_running

  log_for_sentry "Creating /opt/outline"
  export SHADOWBOX_DIR="${SHADOWBOX_DIR:-/opt/outline}"
  mkdir -p "${SHADOWBOX_DIR}"
  chmod u+s,ug+rwx,o-rwx "${SHADOWBOX_DIR}"

  log_for_sentry "Setting API port"
  API_PORT="${FLAGS_API_PORT}"
  if (( API_PORT == 0 )); then
    API_PORT=${SB_API_PORT:-443}  # Меняем порт по умолчанию на 443
  fi
  readonly API_PORT

  readonly ACCESS_CONFIG="${ACCESS_CONFIG:-${SHADOWBOX_DIR}/access.txt}"
  readonly SB_IMAGE="${SB_IMAGE:-quay.io/outline/shadowbox:stable}"

  PUBLIC_HOSTNAME="${FLAGS_HOSTNAME:-${SB_PUBLIC_IP:-}}"
  if [[ -z "${PUBLIC_HOSTNAME}" ]]; then
    if [[ -n "${DEFAULT_DOMAIN}" ]]; then
      PUBLIC_HOSTNAME="${DEFAULT_DOMAIN}"
    else
      run_step "Auto-detect public IP" set_hostname
    fi
  fi
  readonly PUBLIC_HOSTNAME

  if [[ -s "${ACCESS_CONFIG}" ]]; then
    cp "${ACCESS_CONFIG}" "${ACCESS_CONFIG}.bak" && true > "${ACCESS_CONFIG}"
  fi

  run_step "Creating persisted state dir" create_persisted_state_dir
  run_step "Generating secret key" generate_secret_key

  # Если указан существующий сертификат, используем его, иначе генерируем самоподписанный
  if [[ -n "${EXISTING_CERT_PATH}" && -n "${EXISTING_KEY_PATH}" ]]; then
    log_for_sentry "Using existing certificate"
    cp "${EXISTING_CERT_PATH}" "${STATE_DIR}/shadowbox-selfsigned.crt"
    cp "${EXISTING_KEY_PATH}"  "${STATE_DIR}/shadowbox-selfsigned.key"
    chmod 600 "${STATE_DIR}/shadowbox-selfsigned.key"
    SB_CERTIFICATE_FILE="${STATE_DIR}/shadowbox-selfsigned.crt"
    SB_PRIVATE_KEY_FILE="${STATE_DIR}/shadowbox-selfsigned.key"
  else
    run_step "Generating self-signed certificate" generate_certificate
  fi

  run_step "Generating certificate fingerprint" generate_certificate_fingerprint
  run_step "Writing config" write_config
  run_step "Starting Shadowbox" start_shadowbox
  run_step "Starting Watchtower" start_watchtower

  readonly PUBLIC_API_URL="https://${PUBLIC_HOSTNAME}:${API_PORT}/${SB_API_PREFIX}"
  readonly LOCAL_API_URL="https://localhost:${API_PORT}/${SB_API_PREFIX}"
  run_step "Waiting for Outline server to be healthy" wait_shadowbox
  run_step "Creating first user" create_first_user
  run_step "Adding API URL to config" add_api_url_to_config
  run_step "Checking firewall" check_firewall

  # Вывод результата
  function get_field_value {
    grep "$1" "${ACCESS_CONFIG}" | sed "s/$1://"
  }

  cat <<END_OF_MSG

##################################################################
CONGRATULATIONS! Outline server is up and running, on port ${API_PORT}.
Stealth is improved by using port 443 and a self-signed certificate
(or real certificate if configured).

Copy this line into Outline Manager (Step 2):
{"apiUrl":"$(get_field_value apiUrl)","certSha256":"$(get_field_value certSha256)"}

${FIREWALL_STATUS}
##################################################################
END_OF_MSG
}

function is_valid_port() {
  (( 0 < "$1" && "$1" <= 65535 ))
}

function escape_json_string() {
  local input=$1
  for ((i = 0; i < ${#input}; i++)); do
    local char="${input:i:1}"
    local escaped="${char}"
    case "${char}" in
      $'"' ) escaped="\\\"";;
      $'\\') escaped="\\\\";;
      *)
        if [[ "${char}" < $'\x20' ]]; then
          case "${char}" in
            $'\b') escaped="\\b";;
            $'\f') escaped="\\f";;
            $'\n') escaped="\\n";;
            $'\r') escaped="\\r";;
            $'\t') escaped="\\t";;
            *) escaped=$(printf "\\u%04X" "'${char}")
          esac
        fi;;
    esac
    echo -n "${escaped}"
  done
}

function parse_flags() {
  local params
  params="$(getopt --longoptions hostname:,api-port:,keys-port: -n "$0" -- "$@")" || true
  eval set -- "${params}"

  declare -g FLAGS_HOSTNAME=""
  declare -gi FLAGS_API_PORT=0
  declare -gi FLAGS_KEYS_PORT=0

  while (( $# > 0 )); do
    local flag="$1"; shift
    case "${flag}" in
      --hostname)
        FLAGS_HOSTNAME="$1"
        shift
        ;;
      --api-port)
        FLAGS_API_PORT="$1"
        shift
        if ! is_valid_port "${FLAGS_API_PORT}"; then
          log_error "Invalid value for --api-port: ${FLAGS_API_PORT}"
          exit 1
        fi
        ;;
      --keys-port)
        FLAGS_KEYS_PORT="$1"
        shift
        if ! is_valid_port "${FLAGS_KEYS_PORT}"; then
          log_error "Invalid value for --keys-port: ${FLAGS_KEYS_PORT}"
          exit 1
        fi
        ;;
      --)
        break
        ;;
      *)
        display_usage
        exit 1
        ;;
    esac
  done
  if (( FLAGS_API_PORT != 0 && FLAGS_API_PORT == FLAGS_KEYS_PORT )); then
    log_error "--api-port must differ from --keys-port"
    exit 1
  fi
}

################################################################################
###                       ДОПОЛНИТЕЛЬНЫЕ СЕТЕВЫЕ НАСТРОЙКИ                    ###
################################################################################

function enable_bbr() {
  # Включаем BBR, если нужно
  if $ENABLE_BBR ; then
    echo "net.core.default_qdisc = fq"     >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p || true
  fi
}

function configure_iptables() {
  # Минимальные правила, чтобы трафик на 443 выглядел просто как HTTPS.
  # Обычно Outline уже слушает 443 (TCP/UDP).
  # Ниже — пример, как можно скрыть факт, что порт 443 обрабатывает не Apache/NGINX, а Docker:
  if command_exists iptables; then
    # Сбрасываем старые правила — осторожно, может прервать SSH, если что-то не так
    # iptables -F
    # Разрешаем нужные порты
    iptables -I INPUT -p tcp --dport 443 -j ACCEPT
    iptables -I INPUT -p udp --dport 443 -j ACCEPT
  fi
}

function obtain_letsencrypt() {
  if ! $USE_CERTBOT ; then
    return 0
  fi

  if [[ -z "${FLAGS_HOSTNAME}" && -z "${DEFAULT_DOMAIN}" ]]; then
    echo "No domain specified for Let's Encrypt. Skipping..."
    return 0
  fi

  local domain="${FLAGS_HOSTNAME:-${DEFAULT_DOMAIN}}"

  if ! command_exists certbot; then
    echo "Installing certbot..."
    if command_exists apt; then
      apt-get update && apt-get install -y certbot
    elif command_exists yum; then
      yum install -y certbot
    else
      echo "Please install certbot manually." >&2
      return 1
    fi
  fi

  # Открываем 80 порт для http-01
  iptables -I INPUT -p tcp --dport 80 -j ACCEPT || true

  echo "Obtaining Let’s Encrypt certificate for domain: ${domain}"
  certbot certonly --standalone -m "${EMAIL_FOR_CERTBOT}" --agree-tos -d "${domain}" --non-interactive --no-eff-email || {
    echo "Could not obtain Let's Encrypt certificate. Continuing with self-signed..."
    return 0
  }

  # При успехе сертификаты будут в /etc/letsencrypt/live/<domain>/
  local fullchain="/etc/letsencrypt/live/${domain}/fullchain.pem"
  local privkey="/etc/letsencrypt/live/${domain}/privkey.pem"

  if [[ -f "${fullchain}" && -f "${privkey}" ]]; then
    cp "${fullchain}" "${STATE_DIR}/shadowbox-selfsigned.crt"
    cp "${privkey}"  "${STATE_DIR}/shadowbox-selfsigned.key"
    chmod 600 "${STATE_DIR}/shadowbox-selfsigned.key"
    echo "Using real certificate from Let’s Encrypt!"
  else
    echo "Let’s Encrypt certificate not found, continuing self-signed..."
  fi
}

################################################################################
###                                MAIN                                       ###
################################################################################
function main() {
  parse_flags "$@"

  # Включаем TCP BBR
  enable_bbr

  # Настраиваем iptables (скрываем Docker за 443)
  configure_iptables

  # Ставим Outline
  install_outline

  # Пробуем получить реальный сертификат (после установки Outline)
  # и перезапускаем контейнер, если успешно получили
  obtain_letsencrypt || true

  if [[ -f "/etc/letsencrypt/live/${FLAGS_HOSTNAME:-${DEFAULT_DOMAIN}}/fullchain.pem" ]]; then
    echo "Restarting Outline with new certificate..."
    # Просто перезапустим контейнер Shadowbox, теперь он возьмёт свежие файлы
    start_shadowbox
    echo "Shadowbox restarted with Let’s Encrypt certificate."
  fi

  echo "Done."
}

main "$@"
