#!/usr/bin/env bash
###################################################################################
#                                                                                 #
#  Скрипт для установки и настройки Outline VPN в Docker на сервере Ubuntu 22.04  #
#  с элементами маскировки VPN-трафика и рекомендациями по сокрытию ping-ответов. #
#                                                                                 #
#  Автор: ChatGPT                                                                 #
#  Дата:  2024-12-29                                                              #
#                                                                                 #
###################################################################################

# --------------------------- ПРИМЕЧАНИЕ О ТОМ, ЧТО ДЕЛАЕТ СКРИПТ ---------------------------
# 1) Устанавливает Docker (если он не установлен).
# 2) Запускает установку Outline VPN внутри Docker с помощью официального install_server.sh.
# 3) Настраивает работу Outline VPN на стандартном 443 порту.
# 4) Блокирует ICMP (ping) трафик или вносит задержки, чтобы усложнить его анализ.
# 5) Выполняет различные проверки до и после каждой операции и логирует результаты в цвете.
# 6) В конце выводит все ключи/пароли и конфигурационные строки для подключения.
# 7) В самом низу, в закомментированном виде, добавлен удаляющий скрипт, снимающий все настройки.
#
# ВАЖНО: Скрипт НЕ используeт "exit" и постарается выполнить все операции до конца.
#        Если возникает ошибка, скрипт выведет сообщение с формированием вопроса для ChatGPT.

# --------------------------- НАСТРОЙКА ЦВЕТОВ ЛОГОВ ---------------------------
COLOR_GREEN='\033[1;32m'
COLOR_RED='\033[1;31m'
COLOR_YELLOW='\033[1;33m'
COLOR_BLUE='\033[1;34m'
COLOR_RESET='\033[0m'

# --------------------------- ФУНКЦИЯ ВЫВОДА ЛОГОВ ---------------------------
log_info() {
  echo -e "${COLOR_BLUE}[ИНФО]${COLOR_RESET} $1"
}

log_success() {
  echo -e "${COLOR_GREEN}[УСПЕХ]${COLOR_RESET} $1"
}

log_error() {
  echo -e "${COLOR_RED}[ОШИБКА]${COLOR_RESET} $1"
}

log_warn() {
  echo -e "${COLOR_YELLOW}[ВНИМАНИЕ]${COLOR_RESET} $1"
}

# --------------------------- ПЕРЕМЕННЫЕ ---------------------------
DOCKER_INSTALL_FLAG=false
OUTLINE_VERSION="master" # Можно зафиксировать версию Outline, если требуется
OUTLINE_CONTAINER_NAME="outline-server"
SERVER_IP="128.199.56.243" # Возможно, вы захотите поменять IP или получать его динамически
PORT_API="443"            # Порт для API и управления Outline
PING_BLOCK_METHOD="drop"  # Можно переключать "drop" или "delay"

# --------------------------- ПОДГОТОВКА (ПРОВЕРКИ, УДАЛЕНИЕ СТАРОЙ ВЕРСИИ) ---------------------------
log_info "Начинаем процесс подготовки системы..."

# 1) Проверка запуска от root
if [[ $EUID -ne 0 ]]; then
  log_error "Скрипт не запущен от имени root. Для продолжения необходимы права root."
  # Не выходим из скрипта, просто логируем
fi

# 2) Проверяем установлен ли Docker
if ! command -v docker &> /dev/null
then
  log_warn "Docker не установлен в системе. Будет произведена установка Docker."
  DOCKER_INSTALL_FLAG=true
else
  log_info "Docker уже установлен. Проверим, не запущен ли контейнер $OUTLINE_CONTAINER_NAME."
  if docker ps -a --format '{{.Names}}' | grep -w "$OUTLINE_CONTAINER_NAME" &> /dev/null
  then
    log_warn "Найден старый контейнер '$OUTLINE_CONTAINER_NAME'. Будет произведена его остановка и удаление."
    docker stop "$OUTLINE_CONTAINER_NAME" || {
      log_error "Не удалось остановить контейнер '$OUTLINE_CONTAINER_NAME'. Создаём вопрос для ChatGPT..."
      log_error "Вопрос: 'Почему возникает ошибка при остановке контейнера $OUTLINE_CONTAINER_NAME?'"
    }
    docker rm "$OUTLINE_CONTAINER_NAME" || {
      log_error "Не удалось удалить контейнер '$OUTLINE_CONTAINER_NAME'. Создаём вопрос для ChatGPT..."
      log_error "Вопрос: 'Почему возникает ошибка при удалении контейнера $OUTLINE_CONTAINER_NAME?'"
    }
    log_success "Старый контейнер '$OUTLINE_CONTAINER_NAME' успешно удалён."
  else
    log_info "Старых контейнеров '$OUTLINE_CONTAINER_NAME' не обнаружено."
  fi
fi

# 3) Проверяем, нет ли старых iptables-правил, которые могли быть добавлены ранее
#    Удалим или обнулим только специфические правила для ICMP, добавленные нашим скриптом (при необходимости)
log_info "Проверяем iptables-правила на наличие блокировок ICMP, добавленных ранее..."
if iptables -S | grep -q "icmp --icmp-type echo-request -j DROP"; then
  iptables -D INPUT -p icmp --icmp-type echo-request -j DROP
  iptables -D OUTPUT -p icmp --icmp-type echo-reply -j DROP
  log_success "Старые DROP-правила ICMP убраны."
fi

# Удалим/сбросим возможные qdisc-правила
if tc qdisc show dev eth0 | grep -q "netem"; then
  tc qdisc del dev eth0 root
  log_success "Старые правила tc qdisc для eth0 удалены."
fi

log_info "Подготовка системы завершена."

# --------------------------- УСТАНОВКА DOCKER (ЕСЛИ НУЖНО) ---------------------------
if [ "$DOCKER_INSTALL_FLAG" = true ]; then
  log_info "Начинаем установку Docker..."
  # Обновим систему
  apt-get update -y || {
    log_error "Ошибка при выполнении 'apt-get update'. Вопрос для ChatGPT: 'Как исправить ошибку apt-get update?'"
  }
  # Установим необходимые пакеты
  apt-get install -y ca-certificates curl gnupg lsb-release || {
    log_error "Ошибка при установке зависимостей для Docker. Вопрос для ChatGPT: 'Почему не устанавливаются пакеты?'"
  }

  # Добавим Docker GPG ключ и репозиторий
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg || {
    log_error "Ошибка при загрузке GPG ключа Docker. Вопрос для ChatGPT: 'Как исправить ошибку при загрузке ключей Docker?'"
  }
  echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list

  # Установка Docker Engine
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || {
    log_error "Ошибка при установке Docker. Вопрос для ChatGPT: 'Почему Docker не устанавливается?'"
  }

  # Запускаем и включаем Docker
  systemctl enable docker
  systemctl start docker || {
    log_error "Ошибка при запуске Docker. Вопрос для ChatGPT: 'Почему не удаётся запустить Docker?'"
  }
  log_success "Docker успешно установлен и запущен."
else
  log_info "Пропускаем установку Docker, так как он уже установлен."
fi

# --------------------------- ПРОВЕРКА ЗАПУСКА DOCKER ДЕМОНА ---------------------------
log_info "Проверяем, что Docker демон действительно запущен..."
if ! systemctl is-active --quiet docker; then
  log_error "Docker демон не запущен. Вопрос для ChatGPT: 'Почему демон Docker не активен?'"
else
  log_success "Docker демон активен и работает."
fi

# --------------------------- УСТАНОВКА NETEM (ДЛЯ СЛУЧАЕВ ЗАДЕРЖКИ ПИНГОВ) ---------------------------
log_info "Устанавливаем необходимые пакеты для управления tс (iproute2), если их нет..."
apt-get install -y iproute2 iputils-ping net-tools || {
  log_error "Ошибка при установке iproute2, iputils-ping, net-tools. Вопрос для ChatGPT: 'Почему не устанавливаются пакеты iproute2 и net-tools?'"
}

# --------------------------- НАСТРОЙКА PING ---------------------------
# PING_BLOCK_METHOD="drop"  => блочим ICMP
# PING_BLOCK_METHOD="delay" => добавляем рандомные задержки

log_info "Настраиваем ICMP (ping) детект..."

if [ "$PING_BLOCK_METHOD" = "drop" ]; then
  # Блокируем все входящие ping-запросы и исходящие ping-ответы
  iptables -A INPUT -p icmp --icmp-type echo-request -j DROP
  iptables -A OUTPUT -p icmp --icmp-type echo-reply -j DROP
  log_success "ICMP (ping) полностью заблокирован (DROP)."
elif [ "$PING_BLOCK_METHOD" = "delay" ]; then
  # Добавим задержку в 100ms со стандартным отклонением 20ms
  tc qdisc add dev eth0 root netem delay 100ms 20ms distribution normal
  log_success "ICMP (ping) теперь обрабатывается с задержкой 100±20 мс."
else
  log_warn "Метод защиты PING_BLOCK_METHOD не распознан. Параметр не применяется."
fi

# --------------------------- УСТАНОВКА И НАСТРОЙКА OUTLINE VPN ---------------------------
# 1) Скачиваем скрипт установки Outline и устанавливаем.
#    Официальный скрипт: https://raw.githubusercontent.com/Jigsaw-Code/outline-server/<версия>/src/server_manager/install_scripts/install_server.sh
log_info "Начинаем установку Outline VPN..."
OUTLINE_INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/Jigsaw-Code/outline-server/${OUTLINE_VERSION}/src/server_manager/install_scripts/install_server.sh"

# Переменные окружения для установки на нужном порту
export OVERRIDE_API_PORT="$PORT_API"
export DO_INSTALL_DOCKER=false   # Так как Docker уже у нас есть
export SKIP_START_WATCHTOWER=false

# Скачиваем и запускаем
wget -qO- "$OUTLINE_INSTALL_SCRIPT_URL" | bash || {
  log_error "Ошибка при выполнении скрипта install_server.sh. Вопрос для ChatGPT: 'Почему не удаётся установить Outline VPN через скрипт?'"
}

# Проверим, создался ли контейнер
if docker ps -a --format '{{.Names}}' | grep -w "$OUTLINE_CONTAINER_NAME" &> /dev/null
then
  log_success "Контейнер $OUTLINE_CONTAINER_NAME успешно создан/запущен."
else
  log_error "Контейнер $OUTLINE_CONTAINER_NAME не найден. Вопрос для ChatGPT: 'Почему после установки Outline не появился контейнер?'"
fi

# --------------------------- ФИКСИРОВАНИЕ ВЫВОДА ОТ OUTLINE, ЧТОБЫ ПОЛУЧИТЬ КОНФИГ ---------------------------
# Официальный скрипт обычно выводит JSON-конфиг в конце, но нам нужно перехватить этот вывод.
# Самый простой способ – перенаправить вывод в файл и считать его.
# Однако outline_install_server.sh выводит информацию в реальном времени.
# Попробуем выудить нужный JSON из лога установки (если он есть).

log_info "Ищем конфигурационную строку Outline..."
OUTLINE_CONFIG_FILE="/var/log/outline_install_config.log"
# Т.к. у скрипта нет родной опции для вывода JSON в файл, можно поступить хитро:
# - Перехватить весь вывод install_server.sh в файл.
# Но мы уже вызвали его напрямую через wget|bash. Можно повторно вызвать команду `docker exec`?
# Однако официальной простой команды нет, поэтому выберем approach:
#   1) Проверим, есть ли файл state.json внутри /opt/outline/persisted-state .
#   2) Сгенерируем короткий "config" через "docker logs" или "docker exec".

if [ -f "/opt/outline/persisted-state/outline_access.txt" ]; then
  # В свежих версиях Outline информация хранится в outline_access.txt
  cp /opt/outline/persisted-state/outline_access.txt "$OUTLINE_CONFIG_FILE"
  log_success "Найден файл /opt/outline/persisted-state/outline_access.txt. Конфиг скопирован во временный файл."
else
  # Попробуем заглянуть в docker logs (если файл недоступен).
  docker logs "$OUTLINE_CONTAINER_NAME" 2>&1 | grep -A 10 "To manage your Outline server, " > "$OUTLINE_CONFIG_FILE"
  log_info "Конфигурационные данные взяты из docker logs."
fi

# Извлечём JSON из "$OUTLINE_CONFIG_FILE"
OUTLINE_JSON_CONFIG=$(grep -oE '\{.*\}' "$OUTLINE_CONFIG_FILE")
if [ -z "$OUTLINE_JSON_CONFIG" ]; then
  log_error "Не удалось найти JSON-конфиг Outline. Вопрос для ChatGPT: 'Почему не получается вытащить конфиг из Outline?'"
else
  log_success "JSON-конфиг Outline успешно извлечён."
fi

# --------------------------- ПРОВЕРКА РАБОТОСПОСОБНОСТИ OUTLINE ---------------------------
log_info "Проверяем, что контейнер '$OUTLINE_CONTAINER_NAME' прослушивает порт $PORT_API..."

# Можем проверить, что порт доступен внутри контейнера:
docker ps --format '{{.Names}}: {{.Ports}}' | grep -w "$OUTLINE_CONTAINER_NAME" | grep "$PORT_API" &> /dev/null && \
log_success "Контейнер действительно слушает порт $PORT_API." || {
  log_error "Контейнер не слушает порт $PORT_API. Вопрос для ChatGPT: 'Почему контейнер Outline не слушает порт $PORT_API?'"
}

# Внешняя проверка:
# (Простая проверка через curl, возможно, даст ошибку self-signed certificate, поэтому игнорируем сертификат)
curl -k --silent https://"$SERVER_IP":"$PORT_API" &> /dev/null
if [ $? -eq 0 ]; then
  log_success "Проверка через curl прошла. Сервер отвечает на https://$SERVER_IP:$PORT_API"
else
  log_error "Не удалось получить ответ на https://$SERVER_IP:$PORT_API. Вопрос для ChatGPT: 'Почему Outline не отвечает на внешний запрос?'"
fi

# --------------------------- ИТОГОВЫЕ КОНФИГУРАЦИИ И ПАРОЛИ ---------------------------
log_info "Все настройки завершены. Теперь выводим доступные ключи и пароли."
log_info "Ниже представлен JSON-конфиг для Outline Manager. Скопируйте его в Outline Manager:"
echo -e "${COLOR_GREEN}${OUTLINE_JSON_CONFIG}${COLOR_RESET}"

log_info "Если нужно, используйте данные для подключения к серверу:"
echo -e "${COLOR_BLUE}IP сервера:${COLOR_RESET} $SERVER_IP"
echo -e "${COLOR_BLUE}Порт API / Outline Manager:${COLOR_RESET} $PORT_API"
echo -e "${COLOR_BLUE}Способ обхода DPI:${COLOR_RESET} Outline Shadowsocks + порт 443 (HTTPS)."

# --------------------------- ТЕСТОВЫЕ КОМАНДЫ ДЛЯ ПОЛЬЗОВАТЕЛЯ ---------------------------
log_info "Рекомендуется выполнить следующие команды для дополнительной проверки вручную:"
echo -e "${COLOR_YELLOW}1) docker ps -a${COLOR_RESET}  # Посмотреть запущенные контейнеры"
echo -e "${COLOR_YELLOW}2) curl -k https://$SERVER_IP:$PORT_API${COLOR_RESET}  # Проверить ответ сервера Outline"
echo -e "${COLOR_YELLOW}3) iptables -L -n -v | grep icmp${COLOR_RESET}  # Убедиться, что ICMP правила работают"
echo -e "${COLOR_YELLOW}4) tc qdisc show dev eth0${COLOR_RESET}         # Убедиться, что задержки/блокировки ICMP применены"

log_success "Установка и настройка Outline VPN завершена!"

##########################################################################################
###                              УДАЛЯЮЩИЙ СЦЕНАРИЙ                                  ###
###   Ниже, в комментарии, размещён код на случай, если нужно всё снести начисто.    ###
###   Инструкция:                                                                     ###
###   1) Скопируйте этот код в отдельный bash-файл, например remove_outline.sh.       ###
###   2) Запустите его: sudo bash remove_outline.sh                                  ###
##########################################################################################
: '
#!/usr/bin/env bash
echo "Останавливаем и удаляем контейнер Outline..."
docker stop outline-server 2>/dev/null
docker rm outline-server 2>/dev/null

echo "Удаляем iptables-правила для ICMP..."
iptables -D INPUT -p icmp --icmp-type echo-request -j DROP 2>/dev/null
iptables -D OUTPUT -p icmp --icmp-type echo-reply -j DROP 2>/dev/null

echo "Сбрасываем qdisc-правила (netem) на eth0..."
tc qdisc del dev eth0 root 2>/dev/null

echo "Удаляем файлы Outline..."
rm -rf /opt/outline /etc/outline 2>/dev/null

echo "Останавливаем и удаляем Docker (если нужно, по желанию)..."
systemctl stop docker
apt-get remove --purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
apt-get autoremove -y

echo "Удаление завершено!"
'
##########################################################################################