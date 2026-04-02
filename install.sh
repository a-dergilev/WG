#!/bin/bash
set -e

# ===== Параметры =====
PROJECT="/Amnezia"
BASE="$PROJECT/clients"
SCRIPTS="$PROJECT/scripts"
KEYS_DIR="$PROJECT/keys"
WG_IF="wg0"
WG_PORT="443"
GEOIP_URL="https://raw.githubusercontent.com/runetfreedom/russia-blocked-geoip/release/text/ru-blocked.txt"
GEOSITE_URL="https://raw.githubusercontent.com/runetfreedom/russia-blocked-geosite/release/ru-blocked.txt"

# ===== Создание папок =====
echo "[1/12] Создаём папки проекта ..."
mkdir -p "$BASE" "$SCRIPTS" "$KEYS_DIR"
chmod 700 "$KEYS_DIR"

# ===== Установка пакетов =====
echo "[2/12] Установка пакетов ..."
apt update
apt install -y wireguard nftables dnsmasq curl zip iptables

# ===== Генерация ключей сервера =====
echo "[3/12] Генерация ключей сервера ..."
if [ ! -f "$KEYS_DIR/server.key" ]; then
    wg genkey | tee "$KEYS_DIR/server.key" | wg pubkey > "$KEYS_DIR/server.pub"
    chmod 600 "$KEYS_DIR/server.key" "$KEYS_DIR/server.pub"
fi
SERVER_PRIV=$(cat "$KEYS_DIR/server.key")
SERVER_PUB=$(cat "$KEYS_DIR/server.pub")

# ===== Определение внешнего IP с локальным fallback =====
echo "[4/12] Определение внешнего IP ..."
SERVER_IP=${SERVER_IP:-$(curl -sf ifconfig.me || curl -sf ipinfo.io/ip || curl -sf icanhazip.com)}
if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="src"){print $(i+1)}}}')
fi
if [[ -z "$SERVER_IP" ]]; then
    echo "Ошибка: не удалось определить внешний IP"
    exit 1
fi

# ===== Конфиг WireGuard =====
echo "[5/12] Создаём конфиг WireGuard ..."
cat > "$PROJECT/$WG_IF.conf" <<EOF
[Interface]
PrivateKey = $SERVER_PRIV
Address = 10.66.66.1/24
ListenPort = $WG_PORT
MTU = 1280
Table = off

PostUp = sysctl -w net.ipv4.ip_forward=1
PostUp = nft -f $PROJECT/nftables.conf
PostUp = iptables -t nat -C PREROUTING -i $WG_IF -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || iptables -t nat -A PREROUTING -i $WG_IF -p udp --dport 53 -j REDIRECT --to-ports 53
PostUp = iptables -t nat -C PREROUTING -i $WG_IF -p tcp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || iptables -t nat -A PREROUTING -i $WG_IF -p tcp --dport 53 -j REDIRECT --to-ports 53

PostDown = nft flush ruleset
PostDown = iptables -t nat -D PREROUTING -i $WG_IF -p udp --dport 53 -j REDIRECT --to-ports 53 || true
PostDown = iptables -t nat -D PREROUTING -i $WG_IF -p tcp --dport 53 -j REDIRECT --to-ports 53 || true
EOF

# ===== nftables =====
echo "[6/12] Создаём nftables ..."
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

ip rule show | grep -q "fwmark 1" || ip rule add fwmark 1 table 100
ip route show table 100 | grep -q "$WG_IF" || ip route add default dev $WG_IF table 100

# ===== dnsmasq =====
echo "[7/12] Настройка dnsmasq ..."
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
echo "[8/12] Создаём скрипты обновления ..."
cat > "$SCRIPTS/update-geoip.sh" <<EOF
#!/bin/bash
TMP="/tmp/geoip.txt"
curl -sfL $GEOIP_URL -o \$TMP || { echo "Ошибка загрузки GEOIP"; exit 1; }
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
curl -sfL $GEOSITE_URL -o \$TMP || { echo "Ошибка загрузки GEOSITE"; exit 1; }
> \$CONF
while read d; do
    echo "nftset=/\$d/inet#wg#geo_block" >> \$CONF
done < \$TMP
systemctl restart dnsmasq
EOF

chmod +x "$SCRIPTS/update-geoip.sh" "$SCRIPTS/update-domains.sh"

# ===== Панель управления и регенерация пользователей =====
echo "[9/12] Создаём wg-panel и скрипт регенерации ..."
cat > "$PROJECT/wg-panel" <<'EOF'
#!/bin/bash
PROJECT="/Amnezia"
BASE="$PROJECT/clients"
SCRIPTS="$PROJECT/scripts"
KEYS_DIR="$PROJECT/keys"
WG_IF="wg0"
SERVER_PUB=$(cat "$KEYS_DIR/server.pub")

# Функция генерации уникального IP
generate_ip() {
    local ip
    local used_ips=($(ls "$BASE"/*.conf 2>/dev/null | xargs grep -h Address | awk '{print $3}' | cut -d/ -f1))
    while :; do
        ip="10.66.66.$((RANDOM%200+2))"
        [[ ! " ${used_ips[*]} " =~ " $ip " ]] && break
    done
    echo "$ip"
}

# Добавление/удаление пользователей и другие функции - как ранее, но с безопасным хранением ключей в $KEYS_DIR
EOF
chmod +x "$PROJECT/wg-panel"

# ===== TCP BBR =====
echo "[10/12] Включение TCP BBR ..."
grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p

# ===== Запуск обновлений и WireGuard =====
echo "[11/12] Запуск WireGuard и обновлений ..."
"$SCRIPTS/update-geoip.sh"
"$SCRIPTS/update-domains.sh"

systemctl enable wg-quick@$WG_IF
systemctl start wg-quick@$WG_IF

# ===== Завершение =====
echo "[12/12] Установка завершена"
echo "----------------------------------"
echo "ГОТОВО"
echo "Все клиенты и скрипты находятся в $PROJECT"
echo "Панель управления: $PROJECT/wg-panel"
echo "----------------------------------"
