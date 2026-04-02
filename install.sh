#!/bin/bash
set -e

# ===== Параметры сервера =====
SERVER_IP="89.169.11.237"
WG_IF="wg0"
WG_PORT="443"
BASE="/Amnezia/clients"
SCRIPTS="/Amnezia/scripts"
PROJECT="/Amnezia"

GEOIP_URL="https://raw.githubusercontent.com/runetfreedom/russia-blocked-geoip/release/text/ru-blocked.txt"
GEOSITE_URL="https://raw.githubusercontent.com/runetfreedom/russia-blocked-geosite/release/ru-blocked.txt"

# ===== Создаём папки =====
echo "[1/12] Создаём папки проекта ..."
mkdir -p "$BASE"
mkdir -p "$SCRIPTS"

# ===== Установка пакетов =====
echo "[2/12] Установка пакетов ..."
apt update
apt install -y wireguard nftables dnsmasq curl zip iptables

# ===== Генерация ключей сервера =====
echo "[3/12] Генерация ключей сервера ..."
wg genkey | tee "$PROJECT/server.key" | wg pubkey > "$PROJECT/server.pub"
SERVER_PRIV=$(cat "$PROJECT/server.key")
SERVER_PUB=$(cat "$PROJECT/server.pub")

# ===== Конфиг WireGuard =====
echo "[4/12] Создаём конфиг WireGuard ..."
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
EOF

# ===== nftables =====
echo "[5/12] Создаём nftables ..."
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

ip rule add fwmark 1 table 100 || true
ip route add default dev $WG_IF table 100 || true

# ===== dnsmasq =====
echo "[6/12] Настройка dnsmasq ..."
cat > /etc/dnsmasq.d/wg.conf <<EOF
no-resolv
server=1.1.1.1
server=8.8.8.8
cache-size=10000
domain-needed
bogus-priv
EOF

systemctl enable dnsmasq
systemctl restart dnsmasq

# ===== Скрипты обновления =====
echo "[7/12] Создаём скрипты обновления ..."
cat > "$SCRIPTS/update-geoip.sh" <<EOF
#!/bin/bash
TMP="/tmp/geoip.txt"
curl -sL $GEOIP_URL -o \$TMP

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
curl -sL $GEOSITE_URL -o \$TMP

> \$CONF
while read d; do
    echo "nftset=/\$d/inet#wg#geo_block" >> \$CONF
done < \$TMP

systemctl restart dnsmasq
EOF

chmod +x "$SCRIPTS/update-geoip.sh" "$SCRIPTS/update-domains.sh"

# ===== Скрипт регенерации конфигов =====
echo "[8/12] Создаём скрипт regenerate-users.sh ..."
cat > "$SCRIPTS/regenerate-users.sh" <<'EOF'
#!/bin/bash
PROJECT="/Amnezia"
BASE="$PROJECT/clients"
SERVER_PUB=$(cat "$PROJECT/server.pub")
ALLOWED_IPS=$(cat /tmp/geoip.txt /tmp/domains.txt 2>/dev/null | sort -u | paste -sd,)

for CONF in $BASE/*.conf; do
    [ -f "$CONF" ] || continue
    NAME=$(basename "$CONF" .conf)
    PRIV=$(grep PrivateKey "$CONF" | awk '{print $3}')

    cat > "$CONF" <<CFG
[Interface]
PrivateKey = $PRIV
Address = 10.66.66.$((RANDOM%200+2))/24
DNS = 10.66.66.1

[Peer]
PublicKey = $SERVER_PUB
Endpoint = $(curl -s ifconfig.me):443
AllowedIPs = $ALLOWED_IPS
PersistentKeepalive = 25
CFG
done
EOF
chmod +x "$SCRIPTS/regenerate-users.sh"

# ===== Скрипт очистки =====
cat > "$SCRIPTS/cleanup.sh" <<EOF
#!/bin/bash
nft flush set inet wg geo_block 2>/dev/null || true
systemctl restart dnsmasq
EOF
chmod +x "$SCRIPTS/cleanup.sh"

# ===== Панель управления =====
echo "[9/12] Создаём wg-panel ..."
cat > "$PROJECT/wg-panel" <<'EOF'
#!/bin/bash
PROJECT="/Amnezia"
BASE="$PROJECT/clients"
SCRIPTS="$PROJECT/scripts"
WG_IF="wg0"
SERVER_PUB=$(cat "$PROJECT/server.pub")

human_readable() {
    local bytes=$1
    if [ $bytes -lt 1024 ]; then
        echo "${bytes}B"
    elif [ $bytes -lt $((1024**2)) ]; then
        echo "$((bytes/1024)) KB"
    elif [ $bytes -lt $((1024**3)) ]; then
        echo "$((bytes/(1024**2))) MB"
    else
        echo "$((bytes/(1024**3))) GB"
    fi
}

while true; do
    clear
    echo "=============================="
    echo "   WireGuard Panel (Amnezia)"
    echo "=============================="
    echo "1) Добавить пользователя"
    echo "2) Удалить пользователя"
    echo "3) Список пользователей"
    echo "4) Обновить geoip"
    echo "5) Обновить geosite"
    echo "6) Очистить кеш"
    echo "7) Перезапустить WG"
    echo "8) Мониторинг трафика"
    echo "9) Экспорт конфигов (ZIP)"
    echo "0) Выход"
    echo "=============================="
    read -rp "Выбор: " opt

    case "$opt" in
        1)
            read -rp "Имя пользователя: " NAME
            IP="10.66.66.$((RANDOM%200+2))"
            wg genkey | tee "$BASE/$NAME.key" | wg pubkey > "$BASE/$NAME.pub"
            PRIV=$(cat "$BASE/$NAME.key")
            PUB=$(cat "$BASE/$NAME.pub")
            ALLOWED_IPS=$(cat /tmp/geoip.txt /tmp/domains.txt 2>/dev/null | sort -u | paste -sd,)
            cat > "$BASE/$NAME.conf" <<CFG
[Interface]
PrivateKey = $PRIV
Address = $IP/24
DNS = 10.66.66.1

[Peer]
PublicKey = $SERVER_PUB
Endpoint = $(curl -s ifconfig.me):443
AllowedIPs = $ALLOWED_IPS
PersistentKeepalive = 25
CFG
            wg set $WG_IF peer $PUB allowed-ips $IP/32
            echo "Готово: $BASE/$NAME.conf"
            read -n1 -r -p "Enter..."
        ;;
        2)
            read -rp "Имя пользователя: " NAME
            PUB=$(cat "$BASE/$NAME.pub")
            wg set $WG_IF peer $PUB remove
            rm -f "$BASE/$NAME."*
            echo "Удален"
            read -n1 -r -p "Enter..."
        ;;
        3)
            ls "$BASE" | grep .conf || echo "Пусто"
            read -n1 -r -p "Enter..."
        ;;
        4)
            "$SCRIPTS/update-geoip.sh"
            "$SCRIPTS/regenerate-users.sh"
            echo "OK"
            read -n1 -r -p "Enter..."
        ;;
        5)
            "$SCRIPTS/update-domains.sh"
            "$SCRIPTS/regenerate-users.sh"
            echo "OK"
            read -n1 -r -p "Enter..."
        ;;
        6)
            "$SCRIPTS/cleanup.sh"
            echo "OK"
            read -n1 -r -p "Enter..."
        ;;
        7)
            systemctl restart wg-quick@$WG_IF
            echo "OK"
            read -n1 -r -p "Enter..."
        ;;
        8)
            echo "==== Мониторинг трафика ===="
            printf "%-20s %-15s %-15s\n" "Пользователь" "RX" "TX"
            echo "-------------------------------------------------"
            for PUB_FILE in $BASE/*.pub; do
                [ -f "$PUB_FILE" ] || continue
                NAME=$(basename "$PUB_FILE" .pub)
                PUB=$(cat "$PUB_FILE")
                STATS=$(wg show $WG_IF transfer | grep "$PUB" || echo "0 0")
                RX=$(echo $STATS | awk '{print $2}')
                TX=$(echo $STATS | awk '{print $3}')
                RX_HR=$(human_readable $RX)
                TX_HR=$(human_readable $TX)
                echo -e "$NAME\t$RX_HR\t$TX_HR"
            done
            read -n1 -r -p "Enter..."
        ;;
        9)
            cd "$BASE"
            zip -r wg-clients.zip *.conf >/dev/null 2>&1
            echo "Создан ZIP архив: $BASE/wg-clients.zip"
            read -n1 -r -p "Enter..."
        ;;
        0)
            exit
        ;;
        *)
            echo "Неверный выбор!"
            read -n1 -r -p "Enter..."
        ;;
    esac
done
EOF
chmod +x "$PROJECT/wg-panel"

# ===== cron =====
echo "[10/12] Настройка cron ..."
echo "0 */6 * * * root $SCRIPTS/update-geoip.sh" > /etc/cron.d/geoip
echo "5 */6 * * * root $SCRIPTS/update-domains.sh" > /etc/cron.d/geosite
echo "10 */6 * * * root $SCRIPTS/regenerate-users.sh" > /etc/cron.d/regenerate

# ===== TCP BBR =====
echo "[11/12] Включение TCP BBR ..."
grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p

# ===== Запуск =====
echo "[12/12] Запуск WireGuard ..."
systemctl enable wg-quick@$WG_IF
systemctl start wg-quick@$WG_IF

"$SCRIPTS/update-geoip.sh"
"$SCRIPTS/update-domains.sh"
"$SCRIPTS/regenerate-users.sh"

echo "----------------------------------"
echo "ГОТОВО"
echo "Панель управления: $PROJECT/wg-panel"
echo "----------------------------------"