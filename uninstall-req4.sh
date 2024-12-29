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