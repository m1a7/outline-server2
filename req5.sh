#!/usr/bin/env bash
#
# ---------------------------------------------------------------------------------
#  Скрипт для автоматической установки и настройки приватного VPN-сервера Outline
#  (работающего в Docker) на Ubuntu 22.04 x64, с дополнительной маскировкой
#  через Nginx (TLS/SSL-туннель) и блокировкой ICMP (ping).
#
#  Внимание!
#    1) Скрипт не останавливает своё выполнение при ошибках. Вместо этого он формирует
#       сообщение с вопросом для ChatGPT, содержащее описание проблемы.
#    2) Все ключи, пароли и важные строки конфигурации выводятся в конце.
#    3) В самом низу файла содержится спрятанный блок кода для удаления всех
#       установленных компонентов (закомментирован).
#    4) Блокируем ICMP (ping) для усложнения обнаружения VPN путём bidirectional ping.
#
#  Примечание: При желании можете заменить самоподписанный сертификат на Let's Encrypt.
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

# ============================= ПОДГОТОВКА ПАРАМЕТРОВ ============================
# Замените эту переменную на ваш реальный домен или публичный IP-адрес
DOMAIN_OR_IP="64.225.67.181"

# Порт, на котором будет работать Nginx (HTTPS)
NGINX_HTTPS_PORT=443

# Внутренний порт, на котором Outline будет слушать (контейнер)
OUTLINE_INTERNAL_PORT=5000

# Имя Docker-контейнера Outline
OUTLINE_CONTAINER_NAME="outline-server-docker"

# ============================= ПРЕДВАРИТЕЛЬНЫЕ НАСТРОЙКИ ========================
log_info "Подготовка окружения. Скрипт запускается пользователем: '$(whoami)'."

# Отключаем exit-on-error, чтобы скрипт продолжал даже при ошибках
set +e

# Желательно запускать от root
if [[ $EUID -ne 0 ]]; then
  log_warn "Рекомендуется запускать этот скрипт от пользователя root."
fi

# ============================= 1. УСТАНОВКА DOCKER ==============================
run_command "Проверка и установка Docker" bash -c '
  if ! command -v docker &>/dev/null; then
    echo "Docker не найден. Устанавливаю Docker..."
    curl -fsSL https://get.docker.com | sh
    if [[ $? -ne 0 ]]; then
      echo "Не удалось установить Docker!"
      exit 1
    else
      echo "Docker установлен успешно."
    fi
  else
    echo "Docker уже установлен."
  fi
'

# ============================= 2. ЗАПУСК DEMON DOCKER ===========================
run_command "Проверка, что демон Docker запущен" bash -c '
  if ! systemctl is-active --quiet docker; then
    echo "Докер не запущен. Запускаю..."
    systemctl enable docker
    systemctl start docker
    if ! systemctl is-active --quiet docker; then
      echo "Не удалось запустить Docker!"
      exit 1
    else
      echo "Docker успешно запущен."
    fi
  else
    echo "Демон Docker уже запущен."
  fi
'

# ============================= 3. УСТАНОВКА NGINX ==============================
run_command "Установка Nginx" bash -c '
  apt-get update -y
  apt-get install -y nginx
  if [[ $? -ne 0 ]]; then
    echo "Не удалось установить Nginx!"
    exit 1
  else
    echo "Nginx установлен успешно."
  fi
'

# ============================= 4. ГЕНЕРАЦИЯ СЕРТИФИКАТА =========================
run_command "Генерация самоподписанного сертификата для Nginx" bash -c '
  mkdir -p /etc/nginx/ssl
  # Используем домен/IP из переменной $DOMAIN_OR_IP
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/nginx/ssl/nginx.key \
    -out /etc/nginx/ssl/nginx.crt \
    -subj "/CN='"$DOMAIN_OR_IP"'"
  if [[ $? -ne 0 ]]; then
    echo "Ошибка при генерации самоподписанного сертификата!"
    exit 1
  else
    echo "Сертификат сгенерирован: /etc/nginx/ssl/nginx.crt"
    echo "Ключ сгенерирован:       /etc/nginx/ssl/nginx.key"
  fi
'

# ============================= 5. НАСТРОЙКА NGINX (PROXY PASS) ==================
run_command "Настройка Nginx для HTTPS-прокси на Outline" bash -c '
cat <<EOL > /etc/nginx/sites-available/outline
server {
    listen '"$NGINX_HTTPS_PORT"' ssl;
    server_name '"$DOMAIN_OR_IP"';

    ssl_certificate /etc/nginx/ssl/nginx.crt;
    ssl_certificate_key /etc/nginx/ssl/nginx.key;

    # Пробрасываем трафик на локальный Outline-сервер (Docker)
    location / {
        proxy_pass http://127.0.0.1:'"$OUTLINE_INTERNAL_PORT"';
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOL

ln -sf /etc/nginx/sites-available/outline /etc/nginx/sites-enabled/outline
# Проверяем синтаксис Nginx:
nginx -t
if [[ $? -ne 0 ]]; then
  echo "Конфигурация Nginx не прошла проверку!"
  exit 1
fi

# Перезапускаем Nginx
systemctl restart nginx
if [[ $? -ne 0 ]]; then
  echo "Не удалось перезапустить Nginx!"
  exit 1
fi
'

# ============================= 6. ПОДГОТОВКА БРАНДМАУЭРА (UFW) ==================
run_command "Настройка брандмауэра (UFW) для 443" bash -c '
  ufw allow 443/tcp
  ufw reload
  echo "Разрешили входящие соединения на порт 443."
'

# ============================= 7. ПОДГОТОВКА OUTLINE (Docker) ===================
# Образ Outline (пример - официальный Outline Server)
OUTLINE_IMAGE="quay.io/outline/shadowbox:stable"

run_command "Запуск контейнера Outline на внутреннем порту $OUTLINE_INTERNAL_PORT" bash -c '
  docker stop '"$OUTLINE_CONTAINER_NAME"' &>/dev/null || true
  docker rm -f '"$OUTLINE_CONTAINER_NAME"' &>/dev/null || true

  # В реальности можно настроить volume для персистентных данных и сертификатов
  docker run -d --name '"$OUTLINE_CONTAINER_NAME"' \
    -p 127.0.0.1:'"$OUTLINE_INTERNAL_PORT"':5000 \
    -e "SB_API_PREFIX=api" \
    -e "SB_METRICS_PORT=9090" \
    -e "SB_PRIVATE_KEY_FILE=/tmp/private.key" \
    -e "SB_CERTIFICATE_FILE=/tmp/certificate.crt" \
    '"$OUTLINE_IMAGE"'
'

# ============================= 8. БЛОКИРОВКА ICMP (ping) ========================
run_command "Блокировка ICMP (ping) на сервере" bash -c '
  # Блокируем входящие ICMP запросы типа echo-request
  iptables -A INPUT -p icmp --icmp-type echo-request -j DROP
  # Блокируем исходящие ICMP ответы echo-reply
  iptables -A OUTPUT -p icmp --icmp-type echo-reply -j DROP

  # Аналогично для IPv6
  ip6tables -A INPUT -p icmpv6 --icmpv6-type echo-request -j DROP
  ip6tables -A OUTPUT -p icmpv6 --icmpv6-type echo-reply -j DROP

  echo "ICMP (ping) заблокирован. Это поможет скрыть VPN от обнаружения (bidirectional ping)."
'

# -------------------------------------------------------------------------------
# Пример альтернативы (добавление задержки и рандомизации вместо блокировки):
# -------------------------------------------------------------------------------
: <<'NETEM_RANDOMIZATION'
run_command "Добавление задержек/рандомизации для ICMP (через netem)" bash -c '
  apt-get install -y iproute2
  tc qdisc add dev eth0 root netem delay 100ms 20ms distribution normal
  echo "Добавлена случайная задержка для ICMP, вместо полной блокировки ping."
'
NETEM_RANDOMIZATION

# ============================= 9. ТЕСТОВЫЕ ПРОВЕРКИ ============================
run_command "Проверка прослушивания 443 порта Nginx" bash -c '
  if ss -tuln | grep ":'"$NGINX_HTTPS_PORT"' " | grep LISTEN; then
    echo "Nginx слушает порт '"$NGINX_HTTPS_PORT"'."
  else
    echo "Порт '"$NGINX_HTTPS_PORT"' не прослушивается!"
    exit 1
  fi
'

run_command "Проверка, что контейнер Outline запущен" bash -c '
  if docker ps --format "{{.Names}}" | grep -q '"$OUTLINE_CONTAINER_NAME"'; then
    echo "Контейнер '"$OUTLINE_CONTAINER_NAME"' успешно запущен."
  else
    echo "Контейнер '"$OUTLINE_CONTAINER_NAME"' не найден!"
    exit 1
  fi
'

# ============================= 10. КОМАНДЫ ДЛЯ РУЧНЫХ ТЕСТОВ ===================
run_command "Вывод команд для ручных тестов" bash -c '
  echo "------------------------------------------"
  echo "Для проверки доступности Outline (через HTTPS-прокси Nginx):"
  echo "  curl -k https://'"$DOMAIN_OR_IP"':443/api"
  echo "------------------------------------------"
  echo "Проверка, что ICMP заблокирован (ping не должен проходить):"
  echo "  ping '"$DOMAIN_OR_IP"'  # Должен timeout-иться"
  echo "------------------------------------------"
'

# ============================= 11. ВЫВОД ВСЕХ ВАЖНЫХ ДАННЫХ ====================
echo -e "${COLOR_GREEN}\n========== ИТОГИ УСТАНОВКИ ==========${COLOR_NONE}"
echo -e "${COLOR_CYAN}VPN Outline (через Docker) + Nginx (TLS/SSL) успешно настроены.${COLOR_NONE}"
echo -e "Домен/IP:         ${DOMAIN_OR_IP}"
echo -e "Порт HTTPS (TLS): ${NGINX_HTTPS_PORT}"
echo -e "Внутренний порт Outline: ${OUTLINE_INTERNAL_PORT}"
echo -e "Ссылка для Outline Manager (пример!):"
echo -e "  {\\"apiUrl\\":\\"https://${DOMAIN_OR_IP}:${NGINX_HTTPS_PORT}/api\\",\\"certSha256\\":\\"${certSha256}\\"}"
echo -e "------------------------------------------"
echo -e "Сертификат: /etc/nginx/ssl/nginx.crt"
echo -e "Ключ:       /etc/nginx/ssl/nginx.key"
echo -e "------------------------------------------"
echo -e "Для реального продакшена лучше использовать Let's Encrypt.\n"
echo -e "${COLOR_GREEN}Скрипт завершён.${COLOR_NONE}"

# ============================= СПРЯТАННЫЙ КОД ДЛЯ УДАЛЕНИЯ =====================
# Ниже размещаем закомментированный блок, который полностью удаляет всё, что установили.
# Запускать только если действительно хотите снести всё.

: <<'HIDDEN_REMOVE_BLOCK'
echo "ОСТОРОЖНО! Удаляем все установленные компоненты: Outline + Nginx."

# 1. Останавливаем и удаляем контейнер Outline
docker stop outline-server-docker || true
docker rm -f outline-server-docker || true

# 2. Удаляем Nginx
apt-get remove -y nginx
apt-get autoremove -y

# 3. Удаляем Docker (ОСТОРОЖНО, если Docker не нужен больше нигде):
# apt-get remove -y docker docker.io
# apt-get autoremove -y

# 4. Удаляем сертификаты
rm -rf /etc/nginx/ssl

# 5. Возвращаем ICMP:
iptables -D INPUT -p icmp --icmp-type echo-request -j DROP
iptables -D OUTPUT -p icmp --icmp-type echo-reply -j DROP
ip6tables -D INPUT -p icmpv6 --icmpv6-type echo-request -j DROP
ip6tables -D OUTPUT -p icmpv6 --icmpv6-type echo-reply -j DROP

# 6. Удаляем symlink конфигурации Nginx
rm -f /etc/nginx/sites-enabled/outline
rm -f /etc/nginx/sites-available/outline

# 7. Перезагружаем ufw (при желании закрываем порт 443 обратно)
ufw delete allow 443/tcp || true
ufw reload

echo "Удаление завершено."
HIDDEN_REMOVE_BLOCK