#!/bin/sh
# xray-transport.sh — переключение ТРАНСПОРТА VPN между AmneziaWG (awg0) и Xray (xtun).
#
# ИДЕЯ. «Сменить протокол» = перенаправить default в table 1000 с awg0 на xtun (и
# обратно). Вся ОБЩАЯ маркировка (fwmark 0x1, ipset awg_list/iplist_set, ip rule pref 99,
# цепочки VPN_EXCLUDE/VPN_FORCE, домены) НЕ трогается — Xray несёт ровно то же, что нёс
# awg. Это слой ПОВЕРХ split-route.sh: активация xray накладывает xtun-маршрут, откат —
# идемпотентный split-route.sh возвращает default dev awg0.
#
# tun2socks (hev-socks5-tunnel) создаёт TUN xtun и форвардит в локальный socks Xray
# (127.0.0.1:10808); Xray-аутбаунд — VLESS/Reality на VPS. tun2socks ТЕРМИНИРУЕТ
# соединение на роутере → MASQUERADE для xtun НЕ нужен (исходящее к VPS идёт от роутера).
#
# БЕЗОПАСНОСТЬ. Всё держится на ip rule fwmark→table 1000. Если xtun исчезнет (hev умер) —
# маршрут уходит с устройством, table 1000 пустеет, fwmark-трафик падает в main → НАПРЯМУЮ
# (fail-open, не блэкхол). awg0 при xray НЕ опускаем (тёплый резерв). Ребут = сброс к awg
# (heal). Управление/SSH (br-lan, main) от транспорта не зависят.
#
# ГРАБЛИ (доказано в тестовой обвязке): на роутере НЕТ nohup/setsid → демоны через
# start-stop-daemon -b; есть полноценный curl (с --socks5-hostname) для health-пробы.
#
# Использование:
#   xray-transport.sh up        — активировать Xray-транспорт (весь дом)
#   xray-transport.sh down      — вернуть AmneziaWG-транспорт
#   xray-transport.sh status    — показать состояние
#   xray-transport.sh health    — проверить здоровье xray-транспорта (для watchdog):
#                                 код 0 = здоров / транспорт не xray; 1 = xray нездоров

AWG_DIR=/data/usr/app/awg
TABLE=1000
TUN=xtun
SOCKS_ADDR=127.0.0.1
SOCKS_PORT=10808
XRAY="$AWG_DIR/xray"
HEV="$AWG_DIR/hev"
XRAY_JSON="$AWG_DIR/xray.json"
HEV_YAML="$AWG_DIR/hev.yaml"
XRAY_PID=/tmp/xray.pid
HEV_PID=/tmp/hev.pid
XRAY_LOG=/tmp/xray.log
HEV_LOG=/tmp/hev.log
TRANSPORT_FLAG="$AWG_DIR/.transport"
SPLIT="$AWG_DIR/split-route.sh"
AWG_CONF="$AWG_DIR/awg.conf"
NOTIFY_EVENT="$AWG_DIR/notify-event.sh"
DNS1=1.1.1.1
DNS2=8.8.8.8
FWMARK=0x1

log() { echo "[xray-transport] $*"; }
notify_event() { [ -x "$NOTIFY_EVENT" ] && "$NOTIFY_EVENT" "$1" "$2" "$3" "$4" >/dev/null 2>&1; }

proc_alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }

# ---- DNS ------------------------------------------------------------------
# В xray-режиме внутренний Amnezia-DNS (172.29.x dev awg0) ненадёжен (при
# заблокированном awg awg0 мёртв) → ведём DNS НЕЗАВИСИМО: публичный резолвер,
# принудительно маркированный в туннель (уйдёт в xtun→xray, не утечёт).
set_xray_dns() {
    mkdir -p /etc/dnsmasq.d
    printf 'no-resolv\nserver=%s\nserver=%s\n' "$DNS1" "$DNS2" > /etc/dnsmasq.d/00-upstream.conf
    for d in "$DNS1" "$DNS2"; do
        iptables -t mangle -C OUTPUT -d "$d" -j MARK --set-mark $FWMARK 2>/dev/null || \
            iptables -t mangle -A OUTPUT -d "$d" -j MARK --set-mark $FWMARK
    done
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || killall -HUP dnsmasq 2>/dev/null
}
# Обратно к awg-DNS (зеркало restore_vpn_dns из switch-vpn.sh).
restore_awg_dns() {
    for d in "$DNS1" "$DNS2"; do
        iptables -t mangle -D OUTPUT -d "$d" -j MARK --set-mark $FWMARK 2>/dev/null
    done
    vpn_dns=$(grep -E '^DNS[[:space:]]*=' "$AWG_CONF" 2>/dev/null | head -1 | awk -F'= *' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')
    [ -z "$vpn_dns" ] && vpn_dns=172.29.172.254
    mkdir -p /etc/dnsmasq.d
    printf 'no-resolv\nserver=%s\n' "$vpn_dns" > /etc/dnsmasq.d/00-upstream.conf
    ip route replace "$vpn_dns/32" dev awg0 2>/dev/null
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || killall -HUP dnsmasq 2>/dev/null
}

# ---- демоны ---------------------------------------------------------------
start_daemons() {
    [ -x "$XRAY" ] || { log "НЕТ бинаря $XRAY — установи (be7000.ps1)"; return 1; }
    [ -x "$HEV" ]  || { log "НЕТ бинаря $HEV"; return 1; }
    [ -s "$XRAY_JSON" ] || { log "НЕТ конфига $XRAY_JSON — добавь xray-конфиг (меню)"; return 1; }
    [ -s "$HEV_YAML" ]  || { log "НЕТ $HEV_YAML"; return 1; }

    if ! proc_alive "$XRAY_PID"; then
        log "запускаю xray…"
        start-stop-daemon -S -b -m -p "$XRAY_PID" -x "$XRAY" -- run -c "$XRAY_JSON"
    fi
    i=0
    while [ $i -lt 8 ]; do
        netstat -ltn 2>/dev/null | grep -q "$SOCKS_ADDR:$SOCKS_PORT" && break
        sleep 1; i=$((i+1))
    done
    if ! netstat -ltn 2>/dev/null | grep -q "$SOCKS_ADDR:$SOCKS_PORT"; then
        log "xray не слушает $SOCKS_PORT. Лог:"; tail -n 15 "$XRAY_LOG" 2>/dev/null
        return 1
    fi
    if ! proc_alive "$HEV_PID"; then
        log "запускаю hev (tun2socks)…"
        start-stop-daemon -S -b -m -p "$HEV_PID" -x "$HEV" -- "$HEV_YAML"
    fi
    i=0
    while [ $i -lt 6 ]; do
        ip link show "$TUN" >/dev/null 2>&1 && break
        sleep 1; i=$((i+1))
    done
    ip link show "$TUN" >/dev/null 2>&1 || { log "tun $TUN не создан. Лог hev:"; tail -n 15 "$HEV_LOG" 2>/dev/null; return 1; }
    return 0
}
stop_daemons() {
    start-stop-daemon -K -p "$HEV_PID"  2>/dev/null
    start-stop-daemon -K -p "$XRAY_PID" 2>/dev/null
    ip link del "$TUN" 2>/dev/null
}

# Перезапустить ТОЛЬКО xray с текущим $XRAY_JSON (hev/xtun не трогаем — тот же
# socks-порт). Для перебора xray-резервов: меняем конфиг и поднимаем xray заново.
# Возврат: 0 — socks снова слушает; 1 — не поднялся.
restart_xray() {
    start-stop-daemon -K -p "$XRAY_PID" 2>/dev/null
    i=0; while [ $i -lt 4 ]; do netstat -ltn 2>/dev/null | grep -q "$SOCKS_ADDR:$SOCKS_PORT" || break; sleep 1; i=$((i+1)); done
    start-stop-daemon -S -b -m -p "$XRAY_PID" -x "$XRAY" -- run -c "$XRAY_JSON"
    i=0; while [ $i -lt 8 ]; do netstat -ltn 2>/dev/null | grep -q "$SOCKS_ADDR:$SOCKS_PORT" && break; sleep 1; i=$((i+1)); done
    netstat -ltn 2>/dev/null | grep -q "$SOCKS_ADDR:$SOCKS_PORT"
}

# Перебор xray-резервов ВНУТРИ xray-транспорта (зеркало do_failover из switch-vpn).
# Перебирает $AWG_DIR/xray-configs/*.json (кроме активного) по алфавиту, встаёт на
# первый, прошедший health (egress-проба). hev/xtun не трогаем — рестартим лишь xray.
# Возврат: 0 — встали на рабочий xray-резерв (.xray-active обновлён); 1 — ни один не
# поднялся (вызывающий watchdog эскалирует: cross→awg или прямой режим).
cmd_failover() {
    ip link show "$TUN" >/dev/null 2>&1 || { log "xray-failover: нет $TUN — xray не активен"; return 1; }
    cur=$(cat "$AWG_DIR/.xray-active" 2>/dev/null | tr -d ' \r\n')
    tried=""
    for f in "$AWG_DIR"/xray-configs/*.json; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .json)
        [ "$name" = "$cur" ] && continue       # текущий (дохлый) пропускаем
        log "xray-failover: пробую $name…"
        cp "$f" "$XRAY_JSON" && chmod 600 "$XRAY_JSON"
        echo "$name" > "$AWG_DIR/.xray-active"
        if restart_xray && cmd_health; then
            conntrack -F >/dev/null 2>&1 || true
            ip=$(curl -s --max-time 8 --socks5-hostname "$SOCKS_ADDR:$SOCKS_PORT" https://api.ipify.org 2>/dev/null)
            log "xray-failover OK: встал на $name (egress ${ip:-?})"
            notify_event "xray-failover-ok" 1800 "BE7000: Xray-failover -> $name" \
"Xray-сервер ${cur:-?} перестал отвечать. Роутер переключился на резервный
xray-конфиг: $name — VPN снова работает. Внешний IP: ${ip:-неизвестен}.

Сменить вручную: be7000 меню -> Протокол -> Выбрать активный xray-конфиг."
            return 0
        fi
        tried="$tried $name"
    done
    # Ни один резерв не встал. Если мы что-то пробовали (xray.json уже перезаписан
    # дохлым кандидатом) — вернём исходный активный, чтобы down/мониторинг шли по нему.
    # Если резервов не было вовсе ($tried пуст) — xray.json не трогали, рестарт не нужен.
    if [ -n "$tried" ] && [ -n "$cur" ] && [ -f "$AWG_DIR/xray-configs/$cur.json" ]; then
        cp "$AWG_DIR/xray-configs/$cur.json" "$XRAY_JSON" && chmod 600 "$XRAY_JSON"
        echo "$cur" > "$AWG_DIR/.xray-active"
        restart_xray || true
    fi
    log "xray-failover FAIL: ни один резерв не поднялся (пробовал:${tried:- нет})"
    return 1
}

# ---- маршрутизация (xtun-слой поверх общих правил) ------------------------
apply_xray_routing() {
    ip link set "$TUN" up 2>/dev/null
    # FORWARD ACCEPT для xtun (как у awg0; filter FORWARD policy = DROP)
    iptables -C FORWARD -o "$TUN" -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -o "$TUN" -j ACCEPT
    iptables -C FORWARD -i "$TUN" -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i "$TUN" -j ACCEPT
    # СВАП дефолта в боевой таблице: awg0 -> xtun (маркировку/ip rule НЕ трогаем)
    ip route replace default dev "$TUN" table "$TABLE"
}

# ============================================================
cmd_up() {
    if ! start_daemons; then
        log "запуск не удался — остаюсь на awg"
        stop_daemons
        return 1
    fi
    apply_xray_routing
    set_xray_dns
    echo xray > "$TRANSPORT_FLAG"
    # Сброс watchdog-состояния: ручная смена транспорта = новый «эпизод» для
    # авто-failover (иначе старый XSTATE=FAILED/флаг-эпизод подавили бы перебор).
    rm -f /tmp/awg-watchdog.xstate /tmp/awg-failover-episode 2>/dev/null
    conntrack -F >/dev/null 2>&1 || true
    log "транспорт = XRAY (default table $TABLE -> $TUN). Общие правила сохранены."
    cmd_status
}

cmd_down() {
    echo awg > "$TRANSPORT_FLAG"          # ставим первым: heal/watchdog увидят awg
    stop_daemons
    iptables -D FORWARD -o "$TUN" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i "$TUN" -j ACCEPT 2>/dev/null
    # Вернуть awg-маршрутизацию: split-route.sh идемпотентно ставит default dev awg0
    # (+ mark/ip rule/MASQUERADE/маршрут VPN_DNS). awg0 при xray не опускали → он есть.
    if [ -x "$SPLIT" ]; then
        "$SPLIT" >/dev/null 2>&1
    else
        ip route replace default dev awg0 table "$TABLE" 2>/dev/null
    fi
    restore_awg_dns
    rm -f /tmp/awg-watchdog.xstate /tmp/awg-failover-episode 2>/dev/null
    conntrack -F >/dev/null 2>&1 || true
    log "транспорт = AmneziaWG (default table $TABLE -> awg0)."
}

cmd_status() {
    t=awg; [ -f "$TRANSPORT_FLAG" ] && t=$(cat "$TRANSPORT_FLAG")
    echo "=== транспорт: $t ==="
    echo "--- default в table $TABLE ---"; ip route show table "$TABLE" 2>/dev/null | grep default
    echo "--- демоны ---"
    proc_alive "$XRAY_PID" && echo "xray: pid $(cat $XRAY_PID) жив" || echo "xray: не запущен"
    proc_alive "$HEV_PID"  && echo "hev:  pid $(cat $HEV_PID) жив"  || echo "hev:  не запущен"
    echo "--- tun $TUN ---"; ip -o link show "$TUN" 2>/dev/null || echo "нет"
    echo "--- socks $SOCKS_PORT ---"; netstat -ltn 2>/dev/null | grep "$SOCKS_PORT" || echo "не слушает"
    if [ "$t" = xray ]; then
        echo "--- egress через xray socks ---"
        curl -s --max-time 8 --socks5-hostname "$SOCKS_ADDR:$SOCKS_PORT" https://api.ipify.org 2>/dev/null; echo
    fi
    echo "--- awg0 (тёплый резерв) ---"; ip link show awg0 >/dev/null 2>&1 && echo "поднят" || echo "нет"
}

# health для watchdog: 0 = здоров ИЛИ транспорт не xray; 1 = xray нездоров.
cmd_health() {
    t=awg; [ -f "$TRANSPORT_FLAG" ] && t=$(cat "$TRANSPORT_FLAG")
    [ "$t" = xray ] || return 0
    proc_alive "$XRAY_PID" || { log "health: xray не жив"; return 1; }
    proc_alive "$HEV_PID"  || { log "health: hev не жив"; return 1; }
    ip link show "$TUN" >/dev/null 2>&1 || { log "health: нет $TUN"; return 1; }
    # проба реального выхода через прокси (детектит смерть VPS / блок Reality)
    ip=$(curl -s --max-time 8 --socks5-hostname "$SOCKS_ADDR:$SOCKS_PORT" https://api.ipify.org 2>/dev/null)
    [ -n "$ip" ] || { log "health: проба egress пуста"; return 1; }
    return 0
}

case "$1" in
    up)       cmd_up ;;
    down)     cmd_down ;;
    status)   cmd_status ;;
    health)   cmd_health ;;
    failover) cmd_failover ;;
    *) echo "usage: $0 up|down|status|health|failover"; exit 2 ;;
esac
