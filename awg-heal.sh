#!/bin/sh
# awg-heal.sh — самовосстановление AmneziaWG + iplist после ребута.
# Запускается из cron каждую минуту; lock-файл в /tmp гарантирует выполнение
# один раз за загрузку. НЕ зависит от re-filter и dnsmasq-обвязки.
#
# Версия 2.0 / май 2026:
#   - Чистит пустые I1..I5 в awg.conf перед запуском awg_setup.sh
#   - Восстанавливает amnezia_for_awg.conf если он пропал
#   - Защищает пользовательские бинарники: если есть .working.bak —
#     восстанавливает их, если вендорный awg_setup.sh их перетёр
#   - Добавляет FORWARD ACCEPT на awg0 (без этого fw3 дропает LAN-трафик)
#   - Вызывает split-route.sh если он есть (DRY: правила в одном месте)

LOCK=/tmp/awg-heal.lock
SWITCH_LOCK=/tmp/awg-switching.lock
LOG=/tmp/awg-startup.log
AWG_DIR=/data/usr/app/awg
TABLE=1000

[ -e "$LOCK" ] && exit 0

# Если прямо сейчас идёт переключение страны через switch-vpn.sh —
# не лезем. Иначе мы можем поднять awg0 с НЕправильным конфигом
# (старый amnezia_for_awg.conf) посреди операции переключения,
# или подсунуть свои iptables-правила пока switch-vpn делает свою
# работу. switch-vpn.sh ставит этот лок при старте и снимает в конце.
[ -e "$SWITCH_LOCK" ] && exit 0

# Ждём поднятия сети (до 30 сек)
i=0
while [ $i -lt 6 ]; do
    ip route get 1.1.1.1 >/dev/null 2>&1 && break
    sleep 5; i=$((i+1))
done

: > "$LOCK"
: > "$LOG"
exec >>"$LOG" 2>&1
echo "===== awg-heal $(date) ====="

cd "$AWG_DIR" || exit 1

# 0. Подготовка конфига — чистим пустые I-поля
echo "--- preparing config ---"
if grep -qE '^I[1-5]\s*=\s*$' awg.conf 2>/dev/null; then
    sed -i '/^I[1-5]\s*=\s*$/d' awg.conf
    echo "cleaned empty I1..I5 from awg.conf"
fi
# amnezia_for_awg.conf нужен вендорному awg_setup.sh
if [ ! -f amnezia_for_awg.conf ] && [ -f awg.conf ]; then
    cp awg.conf amnezia_for_awg.conf
    echo "amnezia_for_awg.conf recreated from awg.conf"
fi
# Аналогично awg0.conf — могут чистить пустые I
if [ -f awg0.conf ] && grep -qE '^I[1-5]\s*=\s*$' awg0.conf; then
    sed -i '/^I[1-5]\s*=\s*$/d' awg0.conf
fi

# 0.5. Защита пользовательских бинарников.
# Если вендорный awg_setup.sh когда-то скачал свой amneziawg-go/awg
# поверх наших (так бывает), восстановим из .working.bak.
for bin in amneziawg-go awg; do
    if [ -f "$bin.working.bak" ]; then
        # Сравниваем размеры — если отличаются, восстанавливаем
        if [ ! -f "$bin" ] || [ "$(stat -c%s "$bin" 2>/dev/null)" != "$(stat -c%s "$bin.working.bak" 2>/dev/null)" ]; then
            cp "$bin.working.bak" "$bin"
            chmod +x "$bin"
            echo "restored $bin from .working.bak"
        fi
    fi
done

# 1. Поднимаем туннель (вендорный awg_setup.sh, идемпотентный — НЕ перекачивает
# бинарники если они есть)
echo "--- bringing up awg0 ---"
ip link del awg0 2>/dev/null
./awg_setup.sh

# 2. Прописываем upstream DNS изнутри VPN (защита от подмен провайдером).
# DNS адрес берём из awg.conf, fallback — 172.29.172.254 (типовой у Amnezia)
VPN_DNS=$(grep -E '^DNS\s*=' awg.conf 2>/dev/null | head -1 | awk -F'= *' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')
[ -z "$VPN_DNS" ] && VPN_DNS=172.29.172.254
echo "VPN_DNS: $VPN_DNS"

mkdir -p /etc/dnsmasq.d
cat > /etc/dnsmasq.d/00-upstream.conf <<UPSTREAM
no-resolv
server=$VPN_DNS
UPSTREAM
grep -q '^conf-dir=/etc/dnsmasq.d' /etc/dnsmasq.conf || \
    echo 'conf-dir=/etc/dnsmasq.d,*.conf' >> /etc/dnsmasq.conf
ip route replace "$VPN_DNS/32" dev awg0 2>/dev/null
/etc/init.d/dnsmasq restart 2>/dev/null

# 3. ipset awg_list — наполняется dnsmasq'ом по ipset-правилам из
# /etc/dnsmasq.d/awg-domains.conf (если re-filter включён, v2.1+) и/или
# /etc/dnsmasq.d/awg-domains-custom.conf (твои `domain add ...`).
# Если re-filter выключен и ручных доменов нет — ipset остаётся пустым,
# и это нормально: маршрутизация работает через iplist_set (CIDR).
ipset list -n 2>/dev/null | grep -qx awg_list || \
    ipset create awg_list hash:net family inet hashsize 1024 maxelem 1000000

# 4. CIDR от iplist (создаёт ipset iplist_set + mangle PREROUTING)
if [ -x ./iplist-update.sh ]; then
    ./iplist-update.sh
fi

# 5. Маршрутизация + FORWARD ACCEPT — либо через split-route.sh, либо
# inline-фоллбэк если его нет.
if [ -x ./split-route.sh ]; then
    echo "--- running split-route.sh ---"
    ./split-route.sh
else
    echo "--- inline routing rules ---"
    # таблица
    ip route flush table $TABLE 2>/dev/null
    ip route add default dev awg0 table $TABLE
    ip rule del fwmark 0x1 table $TABLE 2>/dev/null
    ip rule add fwmark 0x1 table $TABLE pref 99

    # маркировка для обоих ipset
    for set in awg_list iplist_set; do
        if ipset list -n 2>/dev/null | grep -qx "$set"; then
            iptables -t mangle -C PREROUTING -m set --match-set "$set" dst -j MARK --set-mark 0x1 2>/dev/null || \
                iptables -t mangle -A PREROUTING -m set --match-set "$set" dst -j MARK --set-mark 0x1
        fi
    done

    # NAT
    iptables -t nat -D POSTROUTING -o awg0 -j MASQUERADE 2>/dev/null
    iptables -t nat -A POSTROUTING -o awg0 -j MASQUERADE

    # FORWARD ACCEPT — без него на стоковой BE7000 fw3 политика DROP
    # дропает весь LAN-трафик к awg0 ("открываются только российские сайты")
    iptables -D FORWARD -o awg0 -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i awg0 -j ACCEPT 2>/dev/null
    iptables -I FORWARD 1 -o awg0 -j ACCEPT
    iptables -I FORWARD 1 -i awg0 -j ACCEPT
fi

# 5.5. Восстанавливаем «вырезы мимо VPN» (исключения устройств / SSID / guest).
# Базовую маршрутизацию (трафик из списков->VPN) подняли выше; здесь возвращаем то, что
# пользователь увёл НАПРЯМУЮ через меню/vpn-toggle — иначе после ребута эти
# исключения (живут только в iptables/ip rule = RAM) молча уходят обратно в VPN.
# Безопасно: apply работает только с прямым путём, awg0 не затрагивает.
if [ -x ./apply-bypass.sh ]; then
    echo "--- restoring bypass carve-outs ---"
    ./apply-bypass.sh apply
fi

# 6. Диагностика
echo "--- awg0 ---"
./awg show awg0 2>&1 | head -20
echo "--- iplist_set ---"
ipset list iplist_set 2>&1 | head -7
echo "--- ip rule ---"
ip rule show
echo "--- FORWARD (first 5) ---"
iptables -L FORWARD -v -n | head -5

# 7. Вердикт + письмо (1 раз за boot — heal под локом, спама не будет).
#    Ждём handshake до 25 сек, как switch-vpn, чтобы не слать ложный
#    «не поднялся», пока туннель ещё договаривается с VPS.
echo "--- verdict ---"
NOTIFY_EVENT="$AWG_DIR/notify-event.sh"
WG=""
command -v wg >/dev/null 2>&1 && WG=wg
[ -z "$WG" ] && [ -x "$AWG_DIR/awg" ] && WG="$AWG_DIR/awg"

hs=0
if ip link show awg0 >/dev/null 2>&1 && [ -n "$WG" ]; then
    i=0
    while [ $i -lt 25 ]; do
        hs=$($WG show awg0 latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
        case "$hs" in ''|*[!0-9]*) hs=0 ;; esac
        [ "$hs" -gt 0 ] && [ "$(( $(date +%s) - hs ))" -lt 300 ] && break
        sleep 1; i=$((i+1))
    done
fi

active=$(cat "$AWG_DIR/.active" 2>/dev/null)
if [ -x "$NOTIFY_EVENT" ]; then
    if [ "$hs" -gt 0 ]; then
        age=$(( $(date +%s) - hs ))
        ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null)
        echo "verdict: awg0 up, handshake ${age}s"
        "$NOTIFY_EVENT" boot-ok 0 "BE7000: загрузка OK, VPN поднят" \
"После запуска/перезагрузки роутер поднял туннель.
Конфиг: ${active:-?}. Handshake: ${age} сек назад.
Внешний IP: ${ip:-неизвестен}.

(Письмо приходит раз за загрузку — если роутер ребутнулся сам,
это сигнал: скачок питания, краш или кто-то перезагрузил.)" >/dev/null 2>&1
    else
        if ip link show awg0 >/dev/null 2>&1; then awg0_state="есть, но handshake не пришёл"; else awg0_state="не создан"; fi
        echo "verdict: awg0 down ($awg0_state)"
        "$NOTIFY_EVENT" boot-fail 0 "BE7000: после загрузки VPN НЕ поднялся" \
"awg-heal отработал, но туннель не поднялся (awg0: $awg0_state).
Конфиг: ${active:-?}. Трафик к сайтам из списка сейчас не идёт.
Загляни по SSH: cat /tmp/awg-startup.log; $AWG_DIR/awg-status.sh test.

(Если VPS просто мёртв — watchdog в ближайшие 2 мин переведёт роутер
в прямой режим и пришлёт своё письмо.)" >/dev/null 2>&1
    fi
fi

echo "===== awg-heal done $(date) ====="
