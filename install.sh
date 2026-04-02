#!/bin/bash
set -e

# ===== Параметры =====
WG_IF="wg0"
WG_PORT="443"
PROJECT="/Amnezia"
BASE="$PROJECT/clients"
SCRIPTS="$PROJECT/scripts"
GEOIP_URL="https://raw.githubusercontent.com/runetfreedom/russia-blocked-geoip/release/text/ru-blocked.txt"
GEOSITE_URL="https://raw.githubusercontent.com/runetfreedom/russia-blocked-geosite/release/ru-blocked.txt"

# ===== Очистка старого =====
systemctl stop wg-quick@$WG_IF 2>/dev/null || true
systemctl disable wg-quick@$WG_IF 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true
systemctl disable dnsmasq 2>/dev/null || true
ip link show $WG_IF &>/dev/null && wg-quick down $WG_IF || true
rm -rf "$PROJECT" /etc/wireguard/$WG_IF.conf /etc/dnsmasq.d/wg.conf
nft flush table inet wg 2>/dev/null || true
iptables -t nat -D PREROUTING -i $WG_IF -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || true
iptables -t nat -D PREROUTING -i $WG_IF -p tcp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || true
ip rule del fwmark 1 table 100 2>/dev/null || true
ip route flush table 100 2>/dev/null || true

# ===== Создаем папки =====
mkdir -p "$BASE" "$SCRIPTS"

# ===== Установка пакетов =====
apt update
apt install -y wireguard nftables dnsmasq curl zip iptables

# ===== Генерация ключей сервера =====
wg genkey | tee "$PROJECT/server.key" | wg pubkey > "$PROJECT/server.pub"
SERVER_PRIV=$(cat "$PROJECT/server.key")
SERVER_PUB=$(cat "$PROJECT/server.pub")

# ===== Определение внешнего IP =====
EXTERNAL_IP=$(curl -sf4 ifconfig.me || ip route get 1.1.1.1 | awk '{print $7; exit}')
[ -z "$EXTERNAL_IP" ] && echo "Не удалось определить внешний IP" && exit 1

# ===== Конфиг WireGuard =====
cat > "$PROJECT/$WG_IF.conf" <<EOF
[Interface]
PrivateKey = $SERVER_PRIV
Address = 10.66.66.1/24
ListenPort = $WG_PORT
MTU = 1280
Table = off

PostUp = sysctl -w net.ipv4.ip_forward=1
PostUp = nft -f $PROJECT/nftables.conf
PostUp = iptables -t nat -A PREROUTING -i $WG_IF -p udp --dport 53 -j REDIRECT --to-ports 53
PostUp = iptables -t nat -A PREROUTING -i $WG_IF -p tcp --dport 53 -j REDIRECT --to-ports 53

PostDown = nft flush ruleset
PostDown = iptables -t nat -D PREROUTING -i $WG_IF -p udp --dport 53 -j REDIRECT --to-ports 53 || true
PostDown = iptables -t nat -D PREROUTING -i $WG_IF -p tcp --dport 53 -j REDIRECT --to-ports 53 || true
EOF

# ===== nftables =====
cat > "$PROJECT/nftables.conf" <<EOF
table inet wg {
    set geo_block {
        type ipv4_addr
        flags interval
    }

    chain output {
        type route hook output priority mangle;
        ip daddr @geo_block mark set 1
    }
}
EOF

ip rule add fwmark 1 table 100 2>/dev/null || true
ip route add default dev $WG_IF table 100 2>/dev/null || true

# ===== dnsmasq =====
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    systemctl stop systemd-resolved
    systemctl disable systemd-resolved
    rm -f /etc/resolv.conf
    echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf
fi

cat > /etc/dnsmasq.d/wg.conf <<EOF
no-resolv
server=1.1.1.1
server=8.8.8.8
cache-size=10000
domain-needed
bogus-priv
bind-interfaces
listen-address=10.66.66.1
EOF

systemctl enable dnsmasq
systemctl restart dnsmasq

# ===== Скрипты обновления =====
cat > "$SCRIPTS/update-geoip.sh" <<EOF
#!/bin/bash
TMP="/tmp/geoip.txt"
curl -sfL $GEOIP_URL -o \$TMP || exit 1

nft delete set inet wg geo_block 2>/dev/null || true
nft add set inet wg geo_block { type ipv4_addr; flags interval; }

for ip in \$(cat \$TMP); do
    nft add element inet wg geo_block { \$ip }
done
EOF

cat > "$SCRIPTS/update-domains.sh" <<EOF
#!/bin/bash
TMP="/tmp/domains.txt"
CONF="/etc/dnsmasq.d/wg-domains.conf"
curl -sfL $GEOSITE_URL -o \$TMP || exit 1

> \$CONF
while read d; do
    echo "nftset=/\$d/inet#wg#geo_block" >> \$CONF
done < \$TMP

systemctl restart dnsmasq
EOF

chmod +x "$SCRIPTS/update-geoip.sh" "$SCRIPTS/update-domains.sh"

# ===== Запуск обновлений и WireGuard =====
"$SCRIPTS/update-geoip.sh"
"$SCRIPTS/update-domains.sh"

systemctl enable wg-quick@$WG_IF
wg-quick up $PROJECT/$WG_IF.conf

echo "=================================="
echo "Установка завершена. WireGuard wg0 поднят."
echo "Панель управления и скрипты в $PROJECT"
echo "=================================="
