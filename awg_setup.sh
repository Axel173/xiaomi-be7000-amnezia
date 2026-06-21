#!/bin/sh

config_file="amnezia_for_awg.conf"
interface_config="awg0.conf"
if [ ! -f "$config_file" ]; then
    echo "File $config_file not found"
    exit 1
fi

# Парсим Address/DNS устойчиво к формату конфига: «=» с пробелами ИЛИ без, dual-stack
# через запятую (берём первый токен = IPv4), хвостовой CR. Старый `-F' = '` требовал
# РОВНО «Address = X»: на экспорте без пробелов (Address=...) или с IPv6 через запятую он
# возвращал пусто → `ip a add` ниже падал, и awg0 оставался БЕЗ IPv4 (handshake идёт,
# данные не ходят, rx≈0). Идиома та же, что для DNS в awg-setup-be7000.sh.
address=$(grep -E '^[[:space:]]*Address[[:space:]]*=' "$config_file" | head -1 | sed 's/^[^=]*=[[:space:]]*//' | cut -d',' -f1 | tr -d ' \t\r')
dns=$(grep -E '^[[:space:]]*DNS[[:space:]]*=' "$config_file" | head -1 | sed 's/^[^=]*=[[:space:]]*//' | cut -d',' -f1 | tr -d ' \t\r')
echo "AmneziaWG client address: $address"
echo "DNS: $dns"

if [ -f "$interface_config" ]; then
    echo "$interface_config already exists"
else
    awk '!/^Address/ && !/^DNS/' "$config_file" > "$interface_config"
    echo "$interface_config created"
fi

# Проверяем бинари AmneziaWG. ВАЖНО: НЕ качаем их с github (как в оригинале
# Шалина) — там СТАРАЯ AWG 1.x, которая не понимает S3/S4/H-диапазоны AWG 2.0
# (awg setconf падает с "Line unrecognized: S3="). Канонический источник бинарей —
# установщик (be7000.ps1 -> bin/*.user). Если рабочего бинаря нет — ЯВНО падаем
# (НЕ тянем старьё с внешнего github; репо может исчезнуть).
# Восстановление при пропаже/порче = переустановка с ПК
# (отдельной .working.bak-копии на роутере больше не держим — экономия флеша).
if [ ! -f "awg" ] || [ ! -f "amneziawg-go" ]; then
    echo "ERROR: бинари AmneziaWG (awg/amneziawg-go) не найдены." >&2
    echo "       Поставь их установщиком (be7000.ps1, bin/*.user). Качать старую" >&2
    echo "       AWG 1.x с github НЕ будем — она ломает конфиг AWG 2.0." >&2
    exit 1
fi
echo "AmneziaWG binaries exist, setting up awg0 interface"


# Set up AmneziaWG interface
/data/usr/app/awg/amneziawg-go awg0
/data/usr/app/awg/awg setconf awg0 /data/usr/app/awg/awg0.conf
if [ -n "$address" ]; then
    ip a add "$address" dev awg0
else
    echo "ERROR: поле Address не найдено в $config_file — awg0 останется БЕЗ IPv4 (туннель не понесёт трафик)." >&2
fi
ip l set up awg0

# /data/usr/app/awg/awg - check connection

# Delete existing route for guest network 
ip route del 192.168.33.0/24 dev br-guest

# Add new guest network routes
ip route add 192.168.33.0/24 dev br-guest table main
ip route add default dev awg0 table 200
ip rule add from 192.168.33.0/24 to 192.168.33.1 dport 53 table main pref 100
ip rule add from 192.168.33.0/24 table 200 pref 200

# Set up firewall for DNS requests
iptables -A FORWARD -i br-guest -d 192.168.33.1 -p tcp --dport 53 -j ACCEPT
iptables -A FORWARD -i br-guest -d 192.168.33.1 -p udp --dport 53 -j ACCEPT
iptables -A FORWARD -i br-guest -s 192.168.33.1 -p tcp --sport 53 -j ACCEPT
iptables -A FORWARD -i br-guest -s 192.168.33.1 -p udp --sport 53 -j ACCEPT

# Common rules for traffic
iptables -A FORWARD -i br-guest -o awg0 -j ACCEPT
iptables -A FORWARD -i awg0 -o br-guest -j ACCEPT

# Set up NAT for DNS requests from guest network
iptables -t nat -A PREROUTING -p udp -s 192.168.33.0/24 --dport 53 -j DNAT --to-destination ${dns}:53
iptables -t nat -A PREROUTING -p tcp -s 192.168.33.0/24 --dport 53 -j DNAT --to-destination ${dns}:53

# Set up NAT
iptables -t nat -A POSTROUTING -s 192.168.33.0/24 -o awg0 -j MASQUERADE

# Set up firewall AmneziaWG zone
uci set firewall.awg=zone
uci set firewall.awg.name='awg'
uci set firewall.awg.network='awg0'
uci set firewall.awg.input='ACCEPT'
uci set firewall.awg.output='ACCEPT'
uci set firewall.awg.forward='ACCEPT'
if ! uci show firewall | grep -qE "src='awg'|dest='awg'"; then
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src='guest'
    uci set firewall.@forwarding[-1].dest='awg'
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src='awg'
    uci set firewall.@forwarding[-1].dest='guest'
fi
uci commit firewall

# Clear routes cache and restart firewall
echo "Restarting firewall..."
ip route flush cache
/etc/init.d/firewall reload

# Turn IP-forwarding on
echo 1 > /proc/sys/net/ipv4/ip_forward
