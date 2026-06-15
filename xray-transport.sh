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
NOTIFY_EVENT="$AWG_DIR/notify-event.sh"
APPLY_BYPASS="$AWG_DIR/apply-bypass.sh"
SEED_CONF="/etc/dnsmasq.d/02-altserver.conf" # локальный dnsmasq-ответ server-host->IP (демон резолвит имя сам)
DNS1=1.1.1.1
DNS2=8.8.8.8
FWMARK=0x1

log() { echo "[xray-transport] $*"; }
notify_event() { [ -x "$NOTIFY_EVENT" ] && "$NOTIFY_EVENT" "$1" "$2" "$3" "$4" >/dev/null 2>&1; }

# ВАЖНО: пустой/0-байтовый пидфайл = НЕ жив. На busybox `kill -0 ""` возвращает 0 (успех) →
# наивная проверка `kill -0 "$(cat pid)"` дала бы ЛОЖНЫЙ «процесс жив» на пустом пидфайле
# (бывает при оборванной записи start-stop-daemon -m) → start_daemons НЕ перезапустил бы демон.
proc_alive() { p=$(cat "$1" 2>/dev/null | tr -d ' \r\n'); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }

# ---- резолв сервера по имени (анти-FATAL на старте) — зеркало transport-hy2.sh ----
# ЗАЧЕМ: xray-конфиг почти всегда задаёт address ПО ИМЕНИ (vless://…@host…). xray
# резолвит это имя при старте через системный resolver (dnsmasq -> 1.1.1.1, а он в
# iplist_set -> маркирован в туннель, который ещё НЕ поднят) -> dial fails. Резолвим
# САМИ против WAN/ISP-резолверов (мимо туннеля), фолбэк — публичные. Печатает IPv4.
resolve_ipv4() {
    _h="$1"
    _rs=$(sed -n 's/^[[:space:]]*nameserver[[:space:]]*//p' /tmp/resolv.conf.auto 2>/dev/null)
    for _r in $_rs 1.1.1.1 8.8.8.8 9.9.9.9; do
        _ip=$(nslookup "$_h" "$_r" 2>/dev/null | awk '/^Name:/{f=1;next} f&&/Address/{x=$NF; if(x ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/){print x; exit}}')
        [ -n "$_ip" ] && { echo "$_ip"; return 0; }
    done
    return 1
}
# Имя/IP сервера из первого аутбаунда xray.json (vless vnext.address / vmess и т.п.).
xray_server_host() {
    sed -n 's/.*"address"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$XRAY_JSON" 2>/dev/null | head -1
}
# Кладёт ответ для server-host в ЛОКАЛЬНЫЙ dnsmasq (address=/host/IP) — демон резолвит
# имя сам, мгновенно локально, не уходя в ещё-не-поднятый туннель. Конфиг НЕ трогаем
# (имя остаётся; SNI берётся из него же). $SEED_CONF — изолированный файл. Возврат 1 =
# не зарезолвили -> честно не поднимаемся (иначе xray молча падал бы dial-ом).
seed_server_dns() {
    [ -s "$XRAY_JSON" ] || { log "нет $XRAY_JSON"; return 1; }
    _host=$(xray_server_host)
    [ -n "$_host" ] || { log "не нашёл address в $XRAY_JSON"; return 1; }
    if echo "$_host" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        rm -f "$SEED_CONF" 2>/dev/null; return 0       # server уже IP — сеять нечего
    fi
    _ip=""; _n=0
    while [ "$_n" -lt 6 ]; do
        _ip=$(resolve_ipv4 "$_host"); [ -n "$_ip" ] && break
        _n=$((_n+1)); log "резолв server-host '$_host' попытка $_n не удалась — повтор через 2с…"; sleep 2
    done
    [ -n "$_ip" ] || { log "НЕ зарезолвил server-host '$_host' за 6 попыток → несущая не встанет (честно)"; return 1; }
    echo "$_ip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || { log "резолв вернул не-IP '$_ip' — не сею"; return 1; }
    mkdir -p /etc/dnsmasq.d
    printf 'address=/%s/%s\n' "$_host" "$_ip" > "$SEED_CONF"
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || killall -HUP dnsmasq 2>/dev/null
    _k=0
    while [ "$_k" -lt 6 ]; do
        nslookup "$_host" 127.0.0.1 2>/dev/null | awk '/^Name:/{f=1;next} f&&/Address/{print $NF}' | grep -qx "$_ip" && break
        _k=$((_k+1)); sleep 1
    done
    log "локальный DNS: $_host → $_ip (демон резолвит имя сам; конфиг по имени не трогаем)"
    return 0
}

# ---- анти-петля: endpoint своего VPS мимо маркировки ----------------------
# IP endpoint'а xray-сервера: сперва из сида (точный IP, который пойдёт в dial),
# фолбэк — address из конфига, если он сразу IP. Только IPv4 (iplist_set = cidr4).
xray_endpoint_ip() {
    _ip=$(sed -n 's%^address=/[^/]*/%%p' "$SEED_CONF" 2>/dev/null | head -1)
    [ -n "$_ip" ] && { echo "$_ip"; return 0; }
    _h=$(xray_server_host)
    echo "$_h" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' && echo "$_h"
}
# Исключить endpoint xray-сервера из маркировки (иначе свои же пакеты к VPS, если его
# IP в iplist_set, заворачиваются в xtun = петля). Зовём ДО постановки default->xtun.
exclude_endpoint() {
    ep=$(xray_endpoint_ip)
    [ -n "$ep" ] || { log "endpoint xray не определён — пропуск анти-петли"; return 0; }
    [ -x "$APPLY_BYPASS" ] && sh "$APPLY_BYPASS" endpoint-set "$ep" >/dev/null 2>&1
    log "endpoint $ep исключён из маркировки (анти-петля)"
}

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
# Прямой DNS (релинквиш / прямой режим): публичный резолвер БЕЗ маркировки в туннель
# (туннеля нет → к 1.1.1.1/8.8.8.8 надо идти мимо). Снимаем и OUTPUT-mark, что вешал
# set_xray_dns. Зеркало DNS-части switch-vpn.sh safety_off, но для xray (нет awg0/awg.conf).
set_direct_dns() {
    for d in "$DNS1" "$DNS2"; do
        iptables -t mangle -D OUTPUT -d "$d" -j MARK --set-mark $FWMARK 2>/dev/null
    done
    mkdir -p /etc/dnsmasq.d
    printf 'no-resolv\nserver=%s\nserver=%s\n' "$DNS1" "$DNS2" > /etc/dnsmasq.d/00-upstream.conf
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || killall -HUP dnsmasq 2>/dev/null
}

# ---- демоны ---------------------------------------------------------------
# Запуск xray в фоне С ЗАХВАТОМ вывода в $XRAY_LOG. ЗАЧЕМ: start-stop-daemon -b при
# демонизации уводит stdio демона в /dev/null → если xray-конфиг не задаёт лог-файл, причина
# сбоя (socks не поднялся: кривой сервер/sni/ключи/порт) была НЕВИДНА — tail "$XRAY_LOG" и в
# start_daemons, и в диагностике установщика выдавал пусто. Обёртка `sh -c 'exec … >>log 2>&1'`
# переоткрывает stdout/stderr УЖЕ ПОСЛЕ демонизации (внутри sh, до exec) → лог пишется; exec
# сохраняет PID для pidfile. -x /bin/sh безопасен: дедуп на proc_alive (по пидфайлу), а -K в
# stop/restart матчит по -p, не по -x.
spawn_xray() {
    : > "$XRAY_LOG" 2>/dev/null || true
    seed_server_dns || return 1            # посеять server-host->IP в локальный dnsmasq; 1 = не зарезолвили
    start-stop-daemon -S -b -m -p "$XRAY_PID" -x /bin/sh -- -c "exec '$XRAY' run -c '$XRAY_JSON' >>'$XRAY_LOG' 2>&1"
}

# Освободить socks-порт, если его держит ЧУЖОЙ процесс. ЗАЧЕМ: xray и hysteria
# делят ОДИН socks 10808 и общий hev → провайдер socks должен быть РОВНО один.
# При свопе альта (reinstall xray<->hy2) старый демон остаётся ЖИВ (purge-alt
# убирает лишь файл-бинарь, не процесс) и держит порт → наш xray не забиндит и
# молча умрёт ("bind: address already in use"), а netstat увидит ЧУЖОГО слушателя
# → start_daemons вернул бы ЛОЖНЫЙ успех, hev пошёл бы через старый протокол
# (egress чужого сервера, не нашего). Поэтому перед стартом бьём чужого держателя.
free_foreign_socks() {
    own=$(cat "$XRAY_PID" 2>/dev/null | tr -d ' \r\n')
    holder=$(netstat -ltnp 2>/dev/null | grep "$SOCKS_ADDR:$SOCKS_PORT " | awk '{print $NF}' | cut -d/ -f1 | head -n1)
    case "$holder" in ''|*[!0-9]*) return 0 ;; esac   # никто не слушает / pid не распарсился
    [ "$holder" = "$own" ] && return 0                 # уже наш xray
    log "socks $SOCKS_PORT держит чужой pid $holder — освобождаю (своп альта/рестарт)"
    kill "$holder" 2>/dev/null
    i=0; while [ $i -lt 5 ]; do netstat -ltn 2>/dev/null | grep -q "$SOCKS_ADDR:$SOCKS_PORT" || break; sleep 1; i=$((i+1)); done
}
start_daemons() {
    [ -x "$XRAY" ] || { log "НЕТ бинаря $XRAY — установи (be7000.ps1)"; return 1; }
    [ -x "$HEV" ]  || { log "НЕТ бинаря $HEV"; return 1; }
    [ -s "$XRAY_JSON" ] || { log "НЕТ конфига $XRAY_JSON — добавь xray-конфиг (меню)"; return 1; }
    [ -s "$HEV_YAML" ]  || { log "НЕТ $HEV_YAML"; return 1; }

    free_foreign_socks   # выгнать оставшийся hysteria/чужой демон с порта 10808
    if ! proc_alive "$XRAY_PID"; then
        log "запускаю xray…"
        spawn_xray || { log "xray не запущен: не удалось зарезолвить server-host. Лог:"; tail -n 15 "$XRAY_LOG" 2>/dev/null; return 1; }
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
    spawn_xray || { log "restart_xray: резолв server-host не удался"; return 1; }
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
            exclude_endpoint        # анти-петля: endpoint нового резерва мимо маркировки
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
    exclude_endpoint        # анти-петля: endpoint мимо маркировки ДО постановки default->xtun
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
    # ЧИСТЫЙ РЕЛИНКВИШ (симметрично transport-awg.sh down): отпускаем ТОЛЬКО свою несущую
    # (xtun) -> fail-open в прямой. НЕ решаем, что поднять следом, и НЕ трогаем .transport —
    # это забота ОРКЕСТРАТОРА (transport.sh switch <name>). stop_daemons удаляет xtun -> его
    # default в table $TABLE исчезает с устройством -> fwmark-трафик уходит в main (ПРЯМОЙ).
    # DNS -> публичный напрямую (туннеля нет). Маркировку (mark-core) НЕ трогаем — общая.
    stop_daemons
    iptables -D FORWARD -o "$TUN" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i "$TUN" -j ACCEPT 2>/dev/null
    ip route flush table "$TABLE" 2>/dev/null || true
    rm -f "$SEED_CONF" 2>/dev/null         # снять локальный сид server-host (set_direct_dns ниже рестартит dnsmasq)
    set_direct_dns
    rm -f /tmp/awg-watchdog.xstate /tmp/awg-failover-episode 2>/dev/null
    conntrack -F >/dev/null 2>&1 || true
    log "Xray-несущая снята (релинквиш) -> прямой режим (fail-open). Следующий транспорт ставит оркестратор."
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
