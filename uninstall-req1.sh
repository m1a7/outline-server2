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
apt-get remove -y docker docker.io containerd runc
apt-get autoremove -y

echo "Все компоненты Outline и obfs4 удалены."