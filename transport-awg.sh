#!/bin/sh
# transport-awg.sh — ПЛАГИН транспорта AmneziaWG (несущая awg0).
#
# Часть плана «транспорт-агностичное ядро + плагины».
# Это ЗЕРКАЛО xray-transport.sh для AmneziaWG: одинаковый контракт up|down|health|
# failover|status, чтобы оркестратор (heal/watchdog/меню) дёргал любой протокол
# единообразно, не зная, awg внутри или xray.
#
# РАЗДЕЛЕНИЕ СЛОЁВ (ключевая идея красивого варианта):
#   * mark-core (ОБЩЕЕ, не зависит от протокола): ipset awg_list/iplist_set, маркировка
#     mangle -m set -> MARK 0x1, ip rule fwmark 0x1 -> table 1000, цепочки VPN_EXCLUDE/
#     VPN_FORCE, домены. Его строит установщик/heal ОДИН раз и не трогает при смене
#     транспорта. Этот плагин mark-core НЕ касается.
#   * НЕСУЩАЯ (пер-транспорт, забота плагина): что стоит в default table 1000 (тут awg0),
#     FORWARD на неё, MASQUERADE (awg — нужен, у xtun/tun2socks — нет), DNS-схема
#     (awg — внутренний 172.29.x через awg0; xray — публичный, маркированный в туннель).
#
# БЕЗОПАСНОСТЬ. Всё держится на ip rule fwmark -> table 1000 (mark-core). Если awg0
# умирает или несущую сняли (down) — table 1000 теряет default, fwmark-трафик падает
# в main -> НАПРЯМУЮ (fail-open, не блэкхол). Снять привязку к ДОХЛОМУ awg0 полностью
# (вместе с mark-core) — это switch-vpn.sh safety_off; здесь down лишь РЕЛИНКВИТ
# несущей (mark-core остаётся, повторная активация дешевле). Управление/SSH (br-lan,
# main) от транспорта не зависят.
#
# ВЫЗОВ — как подпроцесс (НЕ source), симметрично xray-transport.sh:
#   transport-awg.sh up        — сделать AmneziaWG активной несущей (весь дом)
#   transport-awg.sh down      — снять awg-несущую (awg0 -> тёплый резерв, трафик прямой)
#   transport-awg.sh status    — показать состояние
#   transport-awg.sh health    — здоровье awg-несущей (для watchdog):
#                                код 0 = здорова / активен не awg; 1 = awg нездоров
#   transport-awg.sh failover  — перебор awg-резервов (делегат в switch-vpn.sh failover,
#                                единый источник правды по перебору; см. ниже)

AWG_DIR=/data/usr/app/awg
TABLE=1000
IFACE=awg0
FWMARK=0x1
TRANSPORT_FLAG="$AWG_DIR/.transport"
ACTIVE_CONF="$AWG_DIR/awg.conf"
SWITCH="$AWG_DIR/switch-vpn.sh"
AWG_SETUP="$AWG_DIR/awg_setup.sh"
NOTIFY_EVENT="$AWG_DIR/notify-event.sh"
APPLY_BYPASS="$AWG_DIR/apply-bypass.sh"
HS_MAX=180            # порог возраста handshake (сек) — как в awg-watchdog.sh
PUB_DNS1=1.1.1.1
PUB_DNS2=8.8.8.8

log() { echo "[transport-awg] $*"; }
notify_event() { [ -x "$NOTIFY_EVENT" ] && "$NOTIFY_EVENT" "$1" "$2" "$3" "$4" >/dev/null 2>&1; }

# CLI handshake читает awg (amneziawg-tools), НЕ amneziawg-go (тот ДЕМОН и на show
# печатает Usage). Предпочитаем локальный бинарь, иначе из PATH.
wg_bin() {
    if [ -x "$AWG_DIR/awg" ]; then echo "$AWG_DIR/awg"
    elif command -v awg >/dev/null 2>&1; then echo awg
    else echo ""; fi
}

# Возраст последнего handshake в секундах (999999 = handshake'а не было / нет бинаря).
hs_age() {
    wg=$(wg_bin); [ -n "$wg" ] || { echo 999999; return; }
    hs=$("$wg" show "$IFACE" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
    case "$hs" in
        ''|0) echo 999999 ;;
        *) now=$(date +%s); echo $(( now - hs )) ;;
    esac
}

carrier_up() { ip link show "$IFACE" 2>/dev/null | grep -q 'state UP\|UNKNOWN\|LOWER_UP'; }

# ---- анти-петля: endpoint своего VPS мимо маркировки ----------------------
# IP endpoint'а awg-сервера. Сначала у демона (awg show — уже резолвленный пир),
# фолбэк — Endpoint из awg.conf (обычно сразу IP). Только IPv4 (iplist_set = cidr4).
awg_endpoint_ip() {
    wg=$(wg_bin)
    if [ -n "$wg" ]; then
        ep=$("$wg" show "$IFACE" endpoints 2>/dev/null | awk 'NR==1{print $2}' | sed 's/:[0-9]*$//')
        echo "$ep" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' && { echo "$ep"; return 0; }
    fi
    ep=$(grep -E '^Endpoint' "$ACTIVE_CONF" 2>/dev/null | head -1 | awk -F'= *' '{print $2}' | sed 's/:[0-9]*$//; s/[[:space:]]//g')
    echo "$ep" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' && echo "$ep"
}
# Исключить endpoint awg-сервера из маркировки (иначе свои же UDP-пакеты к VPS,
# если его IP в iplist_set, заворачиваются обратно в awg0 = петля). Идемпотентно,
# переживает ребут (.endpoint-bypass на /data). Зовём ДО постановки default->awg0.
exclude_endpoint() {
    ep=$(awg_endpoint_ip)
    [ -n "$ep" ] || { log "endpoint awg не определён — пропуск анти-петли"; return 0; }
    [ -x "$APPLY_BYPASS" ] && sh "$APPLY_BYPASS" endpoint-set "$ep" >/dev/null 2>&1
    log "endpoint $ep исключён из маркировки (анти-петля)"
}

# ---- DNS ------------------------------------------------------------------
# awg-режим: dnsmasq форвардит во ВНУТРЕННИЙ Amnezia-DNS (172.29.172.254 dev awg0).
# Зеркало restore_vpn_dns из switch-vpn.sh (единая логика; в слой-вайринге switch-vpn
# будет делегировать сюда). VPN_DNS берём из активного awg.conf.
restore_vpn_dns() {
    vpn_dns=$(grep -E '^DNS[[:space:]]*=' "$ACTIVE_CONF" 2>/dev/null | head -1 | awk -F'= *' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')
    [ -z "$vpn_dns" ] && vpn_dns=172.29.172.254
    mkdir -p /etc/dnsmasq.d
    printf 'no-resolv\nserver=%s\n' "$vpn_dns" > /etc/dnsmasq.d/00-upstream.conf
    ip route replace "$vpn_dns/32" dev "$IFACE" 2>/dev/null
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || killall -HUP dnsmasq 2>/dev/null
}
# Релинквит несущей -> DNS на публичный НАПРЯМУЮ (не маркируем: при снятой несущей
# трафик к 1.1.1.1/8.8.8.8 должен идти мимо туннеля). Зеркало DNS-части safety_off.
set_public_dns() {
    vpn_dns=$(grep -E '^DNS[[:space:]]*=' "$ACTIVE_CONF" 2>/dev/null | head -1 | awk -F'= *' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')
    [ -n "$vpn_dns" ] && ip route del "$vpn_dns/32" dev "$IFACE" 2>/dev/null
    mkdir -p /etc/dnsmasq.d
    printf 'no-resolv\nserver=%s\nserver=%s\n' "$PUB_DNS1" "$PUB_DNS2" > /etc/dnsmasq.d/00-upstream.conf
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || killall -HUP dnsmasq 2>/dev/null
}

# ---- несущая (carrier) ----------------------------------------------------
# Поднять awg0, если его нет. Зеркало bring_up из switch-vpn.sh (init.d -> вендорный
# awg_setup.sh -> ждём интерфейс). Возврат 0 — awg0 есть.
ensure_carrier() {
    if ip link show "$IFACE" >/dev/null 2>&1; then return 0; fi
    for s in /etc/init.d/awg /etc/init.d/amneziawg /etc/init.d/amnezia; do
        [ -x "$s" ] && { "$s" start >/dev/null 2>&1; break; }
    done
    if ! ip link show "$IFACE" >/dev/null 2>&1 && [ -x "$AWG_SETUP" ]; then
        ( cd "$AWG_DIR" && ./awg_setup.sh >/tmp/transport-awg-setup.log 2>&1 )
    fi
    i=0; while [ $i -lt 15 ]; do
        ip link show "$IFACE" >/dev/null 2>&1 && return 0
        sleep 1; i=$((i+1))
    done
    return 1
}

# Наложить awg-несущую поверх mark-core: default dev awg0 + FORWARD awg0 + MASQUERADE
# awg0 + маршрут к VPN_DNS. Это КАРРИЕР-часть split-route.sh (mark-core/ip rule —
# отдельно, тут не трогаем). Идемпотентно.
apply_awg_routing() {
    ip link set "$IFACE" up 2>/dev/null
    # FORWARD ACCEPT (fw3 policy FORWARD=DROP -> без этого LAN-трафик в awg0 дропается)
    iptables -C FORWARD -o "$IFACE" -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -o "$IFACE" -j ACCEPT
    iptables -C FORWARD -i "$IFACE" -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i "$IFACE" -j ACCEPT
    # NAT для исходящего через awg0 (у tun2socks/xtun этого НЕ нужно — он терминирует)
    iptables -t nat -C POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
    # СВАП дефолта в боевой таблице на awg0 (маркировку/ip rule mark-core НЕ трогаем)
    ip route replace default dev "$IFACE" table "$TABLE"
}

# Снять awg-несущую (релинквит): убрать default/FORWARD/MASQUERADE awg0. mark-core
# (ip rule + ipset MARK) ОСТАЁТСЯ -> table 1000 без default -> fail-open в main (прямой).
# awg0 НЕ удаляем — тёплый резерв для быстрого кросс-возврата.
remove_awg_routing() {
    ip route del default dev "$IFACE" table "$TABLE" 2>/dev/null
    iptables -D FORWARD -o "$IFACE" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i "$IFACE" -j ACCEPT 2>/dev/null
    iptables -t nat -D POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null
}

# ---- команды контракта ----------------------------------------------------
cmd_up() {
    if ! ensure_carrier; then
        log "awg0 не поднялся — несущую не активирую"
        return 1
    fi
    exclude_endpoint        # анти-петля: endpoint мимо маркировки ДО постановки default->awg0
    apply_awg_routing
    restore_vpn_dns
    echo awg > "$TRANSPORT_FLAG"
    # Ручная/оркестраторная смена транспорта = новый «эпизод» для авто-failover.
    rm -f /tmp/awg-watchdog.xstate /tmp/awg-failover-episode 2>/dev/null
    conntrack -F >/dev/null 2>&1 || true
    log "транспорт = AmneziaWG (default table $TABLE -> $IFACE). mark-core сохранён."
    cmd_status
}

cmd_down() {
    remove_awg_routing
    set_public_dns
    # .transport НЕ переписываем: «кто активен» решает оркестратор (он поднимет
    # следующий транспорт). Снятая несущая = прямой режим до следующего up.
    rm -f /tmp/awg-watchdog.xstate /tmp/awg-failover-episode 2>/dev/null
    conntrack -F >/dev/null 2>&1 || true
    log "AmneziaWG-несущая снята ($IFACE — тёплый резерв, трафик напрямую)."
}

cmd_health() {
    t=awg; [ -f "$TRANSPORT_FLAG" ] && t=$(cat "$TRANSPORT_FLAG" 2>/dev/null | tr -d ' \r\n')
    [ "$t" = awg ] || return 0          # активен не awg — судить не нам
    carrier_up || { log "health: $IFACE не поднят"; return 1; }
    age=$(hs_age)
    if [ "$age" -ge "$HS_MAX" ]; then
        log "health: handshake устарел (${age}с >= ${HS_MAX}с)"
        return 1
    fi
    return 0
}

# Перебор awg-резервов делегируем в switch-vpn.sh failover — ЕДИНЫЙ источник правды
# (там safety_off -> перебор configs/*.conf -> apply_routing -> restore_vpn_dns -> письма).
# Дублировать do_failover здесь нельзя (два источника правды по перебору, дрейф).
cmd_failover() {
    [ -x "$SWITCH" ] || { log "нет $SWITCH"; return 1; }
    sh "$SWITCH" failover
}

cmd_status() {
    t=awg; [ -f "$TRANSPORT_FLAG" ] && t=$(cat "$TRANSPORT_FLAG" 2>/dev/null | tr -d ' \r\n')
    echo "--- transport-awg status ---"
    echo "активный транспорт (.transport): ${t:-awg}"
    echo "--- default в table $TABLE ---"; ip route show table "$TABLE" 2>/dev/null | grep default || echo "(нет default — прямой режим)"
    echo "--- $IFACE ---"; ip link show "$IFACE" >/dev/null 2>&1 && echo "поднят (handshake $(hs_age)с назад)" || echo "нет"
    echo "--- FORWARD $IFACE ---"; iptables -C FORWARD -o "$IFACE" -j ACCEPT 2>/dev/null && echo "ACCEPT есть" || echo "нет"
}

case "$1" in
    up)       cmd_up ;;
    down)     cmd_down ;;
    status)   cmd_status ;;
    health)   cmd_health ;;
    failover) cmd_failover ;;
    *) echo "usage: $0 up|down|status|health|failover"; exit 2 ;;
esac
