#!/usr/bin/env bash

echo "ОСТОРОЖНО! Удаляем все установленные компоненты Outline + Shadowsocks."

# 1. Останавливаем и удаляем контейнеры
docker stop shadowbox watchtower shadowsocks-obfs || true
docker rm -f shadowbox watchtower shadowsocks-obfs || true

# 2. Удаляем пакеты obfs4proxy (если не используете в других сервисах)
apt-get remove -y obfs4proxy
apt-get autoremove -y

# 3. Удаляем директорию /opt/outline
rm -rf /opt/outline

# 4. При необходимости удаляем Docker (ОСТОРОЖНО, если Docker не нужен больше нигде):
apt-get remove -y docker docker.io
apt-get autoremove -y

# 5. Возвращаем ICMP:
  iptables -D INPUT -p icmp --icmp-type echo-request -j DROP
  iptables -D OUTPUT -p icmp --icmp-type echo-reply -j DROP
  ip6tables -D INPUT -p icmpv6 --icmpv6-type echo-request -j DROP
  ip6tables -D OUTPUT -p icmpv6 --icmpv6-type echo-reply -j DROP

echo "Удаление завершено."