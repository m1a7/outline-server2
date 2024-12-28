#!/bin/bash
# Скрипт для перенастройки VPN сервера, чтобы изменять параметры Docker-контейнера для проброса портов 443 и 80.

set -euo pipefail

# Параметры
CONTAINER_NAME="shadowbox"  # Название контейнера
NEW_PORTS="-p 443:443 -p 80:80"  # Новые порты для перенаправления
DOCKER_IMAGE="quay.io/outline/shadowbox:latest"  # Образ Docker для VPN сервера

# Проверка, существует ли контейнер
if docker ps -a --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"; then
  echo "Контейнер $CONTAINER_NAME найден. Останавливаем и удаляем..."
  docker stop "$CONTAINER_NAME" || true
  docker rm "$CONTAINER_NAME" || true
else
  echo "Контейнер $CONTAINER_NAME не найден. Продолжаем."
fi

# Запуск контейнера с новыми параметрами
echo "Запуск контейнера $CONTAINER_NAME с перенаправлением портов 443 и 80..."
docker run -d \
  --name "$CONTAINER_NAME" \
  $NEW_PORTS \
  --restart=always \
  -v "/opt/outline:/opt/outline" \
  "$DOCKER_IMAGE"

# Проверка статуса контейнера
if docker ps --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"; then
  echo "Контейнер $CONTAINER_NAME успешно запущен с перенаправлением портов."
else
  echo "Ошибка при запуске контейнера $CONTAINER_NAME. Проверьте логи Docker."
  exit 1
fi

# Тестирование перенаправления портов
echo "Проверяем доступность портов..."
PORTS_TO_TEST=(443 80)
TEST_FAILED=false

for PORT in "${PORTS_TO_TEST[@]}"; do
  if nc -zv 127.0.0.1 "$PORT" 2>&1 | grep -q "succeeded"; then
    echo "Порт $PORT доступен."
  else
    echo "Ошибка: порт $PORT недоступен."
    TEST_FAILED=true
  fi
done

if [ "$TEST_FAILED" = true ]; then
  echo "Тестирование завершено с ошибками. Проверьте настройки контейнера и сети."
  exit 1
else
  echo "Все порты успешно проверены. Контейнер работает корректно."
fi

# Завершение
echo "Перенастройка завершена."
