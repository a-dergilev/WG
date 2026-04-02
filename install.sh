#!/bin/bash
set -e

# ===== Параметры =====
PROJECT="/Amnezia"
BASE="$PROJECT/clients"
SCRIPTS="$PROJECT/scripts"
KEYS="$PROJECT/keys"
WG_IF="wg0"
WG_PORT="443"
GEOIP_URL="https://raw.githubusercontent.com/runetfreedom/russia-blocked-geoip/release/text/ru-blocked.txt"
GEOSITE_URL="https://raw.githubusercontent.com/runetfreedom/russia-blocked-geosite/release/ru-blocked.txt"

# ===== Создаем папки =====
mkdir -p "$BASE" "$SCRIPTS" "$KEYS"
chmod 700 "$KEYS"

# ===== Установка пакетов =====
apt update
apt install -y wireguard nftables dnsmasq curl zip iptables

# ===== Генерация ключей =====
if [ ! -f "$KEYS/server.key" ]; then
    wg genkey | tee "$KEYS/server.key" | wg pubkey > "$KEYS/server.pub"
    chmod 600 "$KEYS/server.key" "$KEYS/server.pub"
fi
SERVER_PRIV=$(cat "$KEYS/server.key")
SERVER_PUB=$(cat "$KEYS/server.pub")

# ===== Определяем внешний IP =====
SERVER_IP=$(curl -sf ifconfig.me || curl -sf ipinfo.io/ip || curl -sf icanhazip.com)
SERVER_IP=${SERVER_IP:-$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++){if($i=="src"){print $(i+1)}}}')}
if [[ -z "$SERVER_IP" ]]; then
    echo "Не удалось определить внешний IP"
    exit 1
fi

# ===== WireGuard конфиг =====
mkdir -p /etc/wireguard
cat > /etc/wireguard/$WG_IF.conf <<EOF
[Interface]
PrivateKey = $SERVER_PRIV
Address = 10.66.66.1/24
ListenPort = $WG_PORT
MTU = 1280
Table = off

PostUp = sysctl -w net.ipv4.ip_forward=1
PostUp = iptables -t nat -C PREROUTING -i $WG_IF -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || iptables -t nat -A PREROUTING -i $WG_IF -p udp --dport 53 -j REDIRECT --to-ports 53
PostUp = iptables -t nat -C PREROUTING -i $WG_IF -p tcp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || iptables -t nat -A PREROUTING -i $WG_IF -p tcp --dport 53 -j REDIRECT --to-ports 53

PostDown = iptables -t nat -D PREROUTING -i $WG_IF -p udp --dport 53 -j REDIRECT --to-ports 53 || true
PostDown = iptables -t nat -D PREROUTING -i $WG_IF -p tcp --dport 53 -j REDIRECT --to-ports 53 || true
EOF
chmod 600 /etc/wireguard/$WG_IF.conf

# ===== nftables =====
cat > $PROJECT/nftables.conf <<EOF
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

# ===== systemd-resolved =====
if systemctl is-active --quiet systemd-resolved; then
    systemctl stop systemd-resolved
    systemctl disable systemd-resolved
    rm -f /etc/resolv.conf
    echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf
fi

# ===== Поднимаем WireGuard перед dnsmasq =====
wg-quick up /etc/wireguard/$WG_IF.conf || true

# ===== Таблица маршрутизации для geo_block =====
ip rule add fwmark 1 table 100 2>/dev/null || true
ip route add default dev $WG_IF table 100 2>/dev/null || true

# ===== dnsmasq =====
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

# ===== TCP BBR =====
grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p

# ===== Автозапуск WireGuard =====
systemctl enable wg-quick@$WG_IF
systemctl restart wg-quick@$WG_IF

echo "----------------------------------"
echo "Установка завершена. WireGuard поднят, dnsmasq слушает 10.66.66.1"
echo "Конфиг wg0: /etc/wireguard/$WG_IF.conf"
echo "----------------------------------"
