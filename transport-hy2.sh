#!/bin/sh
# transport-hy2.sh — плагин ТРАНСПОРТА Hysteria2 (несущая xtun поверх общего mark-core).
#
# ИДЕЯ (как у xray-transport.sh — это его близкий клон). «Сменить протокол» = перенаправить
# default в table 1000 на xtun (несущую несёт hysteria2-клиент). Вся ОБЩАЯ маркировка
# (fwmark 0x1, ipset awg_list/iplist_set, ip rule pref 99, цепочки VPN_EXCLUDE/VPN_FORCE,
# домены) НЕ трогается — Hysteria2 несёт ровно то же, что нёс awg/xray. Оркестратор
# (transport.sh) решает, какой транспорт поднять; плагин отвечает ТОЛЬКО за свою несущую.
#
# ПОЧЕМУ переиспользуем hev/xtun и socks 10808 (как xray): у hysteria2-клиента есть и
# нативный TUN-режим, но мы НАМЕРЕННО идём через тот же tun2socks-слой (hev-socks5-tunnel),
# что и xray — это уже проверенная на железе несущая, единый xtun и единый socks-порт. Для
# hev безразлично, КТО слушает 127.0.0.1:10808 (xray или hysteria) → hev.yaml общий, меняется
# лишь локальный socks-сервер. hysteria2 = userspace QUIC поверх UDP (спец-модулей ядра нет).
#
# ФЛЕШ (важно): hysteria2 ставится ВМЕСТО xray, не третьим — /data 20 МБ не держит оба
# альт-бинаря (см. заметку hysteria2-feasibility). На роутере: awg + ОДИН из {xray|hy2}.
# hev/xtun — общий слой для любого из альтов.
#
# БЕЗОПАСНОСТЬ. Всё держится на ip rule fwmark→table 1000. Если xtun исчезнет (hev/hysteria
# умер) — маршрут уходит с устройством, table 1000 пустеет, fwmark-трафик падает в main →
# НАПРЯМУЮ (fail-open, не блэкхол). awg0 при hy2 НЕ опускаем (тёплый резерв). Ребут = сброс
# к awg (heal). Управление/SSH (br-lan, main) от транспорта не зависят.
#
# ГРАБЛИ (как у xray): на роутере НЕТ nohup/setsid → демоны через start-stop-daemon -b; есть
# полноценный curl (--socks5-hostname) для health-пробы. Клиент hysteria запускается БЕЗ
# субкоманды run (client — режим по умолчанию): `hysteria -c <config>`.
#
# Использование:
#   transport-hy2.sh up        — активировать Hysteria2-транспорт (весь дом)
#   transport-hy2.sh down      — ЧИСТО отпустить несущую → fail-open в прямой (релинквиш)
#   transport-hy2.sh status    — показать состояние
#   transport-hy2.sh health    — здоровье транспорта (для watchdog): 0 здоров / 1 нет
#   transport-hy2.sh failover  — перебор hy2-резервов внутри транспорта

AWG_DIR=/data/usr/app/awg
TABLE=1000
TUN=xtun
SOCKS_ADDR=127.0.0.1
SOCKS_PORT=10808                 # ТОТ ЖЕ порт, что у xray → общий hev.yaml несёт оба
HY2="$AWG_DIR/hysteria"
HEV="$AWG_DIR/hev"
HY2_YAML="$AWG_DIR/hysteria.yaml" # активный конфиг (генерит меню; socks5.listen ОБЯЗАН быть 127.0.0.1:10808)
SEED_CONF="/etc/dnsmasq.d/02-altserver.conf" # локальный dnsmasq-ответ server-host->IP (демон резолвит имя сам)
HEV_YAML="$AWG_DIR/hev.yaml"
HY2_PID=/tmp/hysteria.pid
HEV_PID=/tmp/hev.pid
HY2_LOG=/tmp/hysteria.log
HEV_LOG=/tmp/hev.log
TRANSPORT_FLAG="$AWG_DIR/.transport"
NOTIFY_EVENT="$AWG_DIR/notify-event.sh"
DNS1=1.1.1.1
DNS2=8.8.8.8
FWMARK=0x1

log() { echo "[hy2-transport] $*"; }
notify_event() { [ -x "$NOTIFY_EVENT" ] && "$NOTIFY_EVENT" "$1" "$2" "$3" "$4" >/dev/null 2>&1; }

# ВАЖНО: пустой/0-байтовый пидфайл = НЕ жив. На busybox `kill -0 ""` возвращает 0 (успех) →
# наивная проверка `kill -0 "$(cat pid)"` дала бы ЛОЖНЫЙ «процесс жив» на пустом пидфайле
# (бывает при оборванной записи start-stop-daemon -m) → start_daemons НЕ перезапустил бы демон.
proc_alive() { p=$(cat "$1" 2>/dev/null | tr -d ' \r\n'); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }

# ---- резолв сервера по имени (анти-FATAL на старте) ------------------------
# ЗАЧЕМ: пользователь даёт конфиг как ему удобно — почти всегда server ПО ИМЕНИ (ссылка
# hy2://…@host…). hysteria резолвит это имя ОДИН раз при старте через системный resolver
# (dnsmasq → 1.1.1.1, а он в iplist_set → маркирован в туннель, который ещё НЕ поднят) и при
# ЛЮБОЙ осечке падает FATAL без ретрая → несущая молча не встаёт («поставилось, но VPN нет»).
# Поэтому резолвим САМИ: несколько попыток, в первую очередь против WAN/ISP-резолверов (из
# /tmp/resolv.conf.auto — их НЕ маркируем, уходят напрямую мимо туннеля), фолбэк — публичные.
# Печатает первый IPv4 в stdout (или ничего). nslookup busybox: «Address 1: <ip>» после «Name:».
resolve_ipv4() {
    _h="$1"
    _rs=$(sed -n 's/^[[:space:]]*nameserver[[:space:]]*//p' /tmp/resolv.conf.auto 2>/dev/null)
    for _r in $_rs 1.1.1.1 8.8.8.8 9.9.9.9; do
        _ip=$(nslookup "$_h" "$_r" 2>/dev/null | awk '/^Name:/{f=1;next} f&&/Address/{x=$NF; if(x ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/){print x; exit}}')
        [ -n "$_ip" ] && { echo "$_ip"; return 0; }
    done
    return 1
}
# Кладёт ответ для server-host в ЛОКАЛЬНЫЙ dnsmasq (address=/host/IP), чтобы демон резолвил имя
# САМ (нативно, как обычный клиент) и получал ответ мгновенно ЛОКАЛЬНО — без upstream-запроса в
# ещё-не-поднятый туннель. Конфиг hysteria НЕ трогаем (остаётся ПО ИМЕНИ — источник истины; SNI
# берётся из него же демоном). Резолвим на КАЖДЫЙ старт → смена IP сервера подхватится. $SEED_CONF —
# ИЗОЛИРОВАННЫЙ файл (создаём/удаляем ТОЛЬКО его, общие файлы не правим; директива address= с
# валидным IP не может уронить dnsmasq) → положить интернет не способно. Возврат 1 = host не
# зарезолвлен -> ЧЕСТНО не поднимаемся (демон по имени упал бы FATAL; оркестратор/установщик
# скажут «несущая не встала», а не «всё ок»; трафик при этом fail-open в прямой).
seed_server_dns() {
    [ -s "$HY2_YAML" ] || { log "нет $HY2_YAML"; return 1; }
    _host=$(grep -E '^[[:space:]]*server:' "$HY2_YAML" | head -1 | sed 's/^[[:space:]]*server:[[:space:]]*//; s/[[:space:]]*$//; s/^["'\'']//; s/["'\'']$//')
    _host=${_host%:*}                                    # отрезать :port
    if echo "$_host" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        rm -f "$SEED_CONF" 2>/dev/null; return 0         # server уже IP — сеять нечего, чистим прошлый сид
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
    _k=0                                                 # дождаться, что dnsmasq реально отдаёт сид (до старта демона)
    while [ "$_k" -lt 6 ]; do
        nslookup "$_host" 127.0.0.1 2>/dev/null | awk '/^Name:/{f=1;next} f&&/Address/{print $NF}' | grep -qx "$_ip" && break
        _k=$((_k+1)); sleep 1
    done
    log "локальный DNS: $_host → $_ip (демон резолвит имя сам; конфиг по имени не трогаем)"
    return 0
}

# ---- DNS ------------------------------------------------------------------
# В hy2-режиме внутренний Amnezia-DNS (172.29.x dev awg0) ненадёжен (awg0 = тёплый резерв,
# при заблокированном awg мёртв) → ведём DNS НЕЗАВИСИМО: публичный резолвер, принудительно
# маркированный в туннель (уйдёт в xtun→hysteria, не утечёт). Зеркало set_xray_dns.
set_hy2_dns() {
    mkdir -p /etc/dnsmasq.d
    printf 'no-resolv\nserver=%s\nserver=%s\n' "$DNS1" "$DNS2" > /etc/dnsmasq.d/00-upstream.conf
    for d in "$DNS1" "$DNS2"; do
        iptables -t mangle -C OUTPUT -d "$d" -j MARK --set-mark $FWMARK 2>/dev/null || \
            iptables -t mangle -A OUTPUT -d "$d" -j MARK --set-mark $FWMARK
    done
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || killall -HUP dnsmasq 2>/dev/null
}
# Прямой DNS (релинквиш / прямой режим): публичный резолвер БЕЗ маркировки в туннель.
set_direct_dns() {
    for d in "$DNS1" "$DNS2"; do
        iptables -t mangle -D OUTPUT -d "$d" -j MARK --set-mark $FWMARK 2>/dev/null
    done
    mkdir -p /etc/dnsmasq.d
    printf 'no-resolv\nserver=%s\nserver=%s\n' "$DNS1" "$DNS2" > /etc/dnsmasq.d/00-upstream.conf
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || killall -HUP dnsmasq 2>/dev/null
}

# ---- демоны ---------------------------------------------------------------
# Запуск hysteria в фоне С ЗАХВАТОМ вывода в $HY2_LOG. ЗАЧЕМ: у hysteria2-клиента НЕТ опции
# «писать лог в файл» (он пишет в stderr), а start-stop-daemon -b при демонизации уводит
# stdio демона в /dev/null → причина сбоя (socks не поднялся: кривой сервер/sni/auth/порт)
# была НЕВИДНА — tail "$HY2_LOG" и в start_daemons, и в диагностике установщика выдавал пусто
# (из-за этого установка падала «без ошибки»). Обёртка `sh -c 'exec … >>log 2>&1'`
# переоткрывает stdout/stderr УЖЕ ПОСЛЕ демонизации (внутри sh, до exec) → лог пишется;
# exec сохраняет PID для pidfile. -x /bin/sh безопасен: дедуп у нас на proc_alive (по
# пидфайлу), а -K в stop/restart матчит по -p, не по -x.
spawn_hysteria() {
    : > "$HY2_LOG" 2>/dev/null || true
    seed_server_dns || return 1            # посеять server-host->IP в локальный dnsmasq; 1 = не зарезолвили
    start-stop-daemon -S -b -m -p "$HY2_PID" -x /bin/sh -- -c "exec '$HY2' -c '$HY2_YAML' >>'$HY2_LOG' 2>&1"
}

# Освободить socks-порт, если его держит ЧУЖОЙ процесс. ЗАЧЕМ: hysteria и xray
# делят ОДИН socks 10808 и общий hev → провайдер socks должен быть РОВНО один.
# При свопе альта (reinstall hy2<->xray) старый демон остаётся ЖИВ (purge-alt
# убирает лишь файл-бинарь, не процесс) и держит порт → наша hysteria не забиндит
# и молча умрёт ("bind: address already in use"), а netstat увидит ЧУЖОГО
# слушателя → start_daemons вернул бы ЛОЖНЫЙ успех, hev пошёл бы через старый
# протокол (egress чужого сервера, не нашего). Поэтому перед стартом бьём чужого.
free_foreign_socks() {
    own=$(cat "$HY2_PID" 2>/dev/null | tr -d ' \r\n')
    holder=$(netstat -ltnp 2>/dev/null | grep "$SOCKS_ADDR:$SOCKS_PORT " | awk '{print $NF}' | cut -d/ -f1 | head -n1)
    case "$holder" in ''|*[!0-9]*) return 0 ;; esac   # никто не слушает / pid не распарсился
    [ "$holder" = "$own" ] && return 0                 # уже наша hysteria
    log "socks $SOCKS_PORT держит чужой pid $holder — освобождаю (своп альта/рестарт)"
    kill "$holder" 2>/dev/null
    i=0; while [ $i -lt 5 ]; do netstat -ltn 2>/dev/null | grep -q "$SOCKS_ADDR:$SOCKS_PORT" || break; sleep 1; i=$((i+1)); done
}
start_daemons() {
    [ -x "$HY2" ] || { log "НЕТ бинаря $HY2 — установи (be7000.ps1)"; return 1; }
    [ -x "$HEV" ] || { log "НЕТ бинаря $HEV"; return 1; }
    [ -s "$HY2_YAML" ] || { log "НЕТ конфига $HY2_YAML — добавь hy2-конфиг (меню)"; return 1; }
    [ -s "$HEV_YAML" ] || { log "НЕТ $HEV_YAML"; return 1; }

    free_foreign_socks   # выгнать оставшийся xray/чужой демон с порта 10808
    if ! proc_alive "$HY2_PID"; then
        log "запускаю hysteria…"
        spawn_hysteria || { log "hysteria не запущена: не удалось зарезолвить server-host. Лог:"; tail -n 15 "$HY2_LOG" 2>/dev/null; return 1; }
    fi
    # ВНИМАНИЕ: socks открывается ТОЛЬКО ПОСЛЕ установления QUIC-сессии с сервером, а у
    # hysteria2 (UDP/QUIC) на цензурируемых/throttle-сетях хендшейк бывает медленным — на
    # живом железе замерено от ~1с до ~17с (DPI по UDP 443 заставляет QUIC ретраить). Раньше
    # ждали 8с → при медленном коннекте socks не успевал, start_daemons возвращал 1, cmd_up
    # делал stop_daemons, и установщик под set -e обрывался ДО регистрации cron. Ждём до 25с
    # (запас к наблюдавшимся 15-17с). Здоровье/перебор резервов потом стерегёт watchdog.
    i=0
    while [ $i -lt 25 ]; do
        netstat -ltn 2>/dev/null | grep -q "$SOCKS_ADDR:$SOCKS_PORT" && break
        sleep 1; i=$((i+1))
    done
    if ! netstat -ltn 2>/dev/null | grep -q "$SOCKS_ADDR:$SOCKS_PORT"; then
        log "hysteria не слушает $SOCKS_PORT (socks5.listen в конфиге обязан быть $SOCKS_ADDR:$SOCKS_PORT). Лог:"; tail -n 15 "$HY2_LOG" 2>/dev/null
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
    start-stop-daemon -K -p "$HEV_PID" 2>/dev/null
    start-stop-daemon -K -p "$HY2_PID" 2>/dev/null
    ip link del "$TUN" 2>/dev/null
}

# Перезапустить ТОЛЬКО hysteria с текущим $HY2_YAML (hev/xtun не трогаем — тот же socks-порт).
# Для перебора hy2-резервов: меняем конфиг и поднимаем hysteria заново. 0 — socks снова слушает.
restart_hy2() {
    start-stop-daemon -K -p "$HY2_PID" 2>/dev/null
    i=0; while [ $i -lt 4 ]; do netstat -ltn 2>/dev/null | grep -q "$SOCKS_ADDR:$SOCKS_PORT" || break; sleep 1; i=$((i+1)); done
    spawn_hysteria || { log "restart_hy2: резолв server-host не удался"; return 1; }
    i=0; while [ $i -lt 25 ]; do netstat -ltn 2>/dev/null | grep -q "$SOCKS_ADDR:$SOCKS_PORT" && break; sleep 1; i=$((i+1)); done   # QUIC-хендшейк бывает ~15-17с (см. start_daemons)
    netstat -ltn 2>/dev/null | grep -q "$SOCKS_ADDR:$SOCKS_PORT"
}

# Перебор hy2-резервов ВНУТРИ транспорта (зеркало cmd_failover из xray-transport.sh).
# Перебирает $AWG_DIR/hy2-configs/*.yaml (кроме активного) по алфавиту, встаёт на первый,
# прошедший health (egress-проба). hev/xtun не трогаем — рестартим лишь hysteria.
# Возврат: 0 — встали на рабочий hy2-резерв (.hy2-active обновлён); 1 — ни один не поднялся
# (вызывающий watchdog эскалирует: cross→awg или прямой режим).
cmd_failover() {
    ip link show "$TUN" >/dev/null 2>&1 || { log "hy2-failover: нет $TUN — hysteria не активна"; return 1; }
    cur=$(cat "$AWG_DIR/.hy2-active" 2>/dev/null | tr -d ' \r\n')
    tried=""
    for f in "$AWG_DIR"/hy2-configs/*.yaml; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .yaml)
        [ "$name" = "$cur" ] && continue       # текущий (дохлый) пропускаем
        log "hy2-failover: пробую $name…"
        cp "$f" "$HY2_YAML" && chmod 600 "$HY2_YAML"
        echo "$name" > "$AWG_DIR/.hy2-active"
        if restart_hy2 && cmd_health; then
            conntrack -F >/dev/null 2>&1 || true
            ip=$(curl -s --max-time 8 --socks5-hostname "$SOCKS_ADDR:$SOCKS_PORT" https://api.ipify.org 2>/dev/null)
            log "hy2-failover OK: встал на $name (egress ${ip:-?})"
            notify_event "hy2-failover-ok" 1800 "BE7000: Hysteria2-failover -> $name" \
"Hysteria2-сервер ${cur:-?} перестал отвечать. Роутер переключился на резервный
hy2-конфиг: $name — VPN снова работает. Внешний IP: ${ip:-неизвестен}.

Сменить вручную: be7000 меню -> Протокол -> Выбрать активный hy2-конфиг."
            return 0
        fi
        tried="$tried $name"
    done
    # Ни один резерв не встал → вернём исходный активный, чтобы down/мониторинг шли по нему.
    if [ -n "$tried" ] && [ -n "$cur" ] && [ -f "$AWG_DIR/hy2-configs/$cur.yaml" ]; then
        cp "$AWG_DIR/hy2-configs/$cur.yaml" "$HY2_YAML" && chmod 600 "$HY2_YAML"
        echo "$cur" > "$AWG_DIR/.hy2-active"
        restart_hy2 || true
    fi
    log "hy2-failover FAIL: ни один резерв не поднялся (пробовал:${tried:- нет})"
    return 1
}

# ---- маршрутизация (xtun-слой поверх общих правил) ------------------------
apply_hy2_routing() {
    ip link set "$TUN" up 2>/dev/null
    iptables -C FORWARD -o "$TUN" -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -o "$TUN" -j ACCEPT
    iptables -C FORWARD -i "$TUN" -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i "$TUN" -j ACCEPT
    ip route replace default dev "$TUN" table "$TABLE"
}

# ============================================================
cmd_up() {
    if ! start_daemons; then
        log "запуск не удался — несущая не поднята (оркестратор решит, что дальше)"
        stop_daemons
        return 1
    fi
    apply_hy2_routing
    set_hy2_dns
    echo hy2 > "$TRANSPORT_FLAG"
    # Сброс watchdog-состояния: ручная смена транспорта = новый «эпизод» для авто-failover.
    rm -f /tmp/awg-watchdog.xstate /tmp/awg-failover-episode 2>/dev/null
    conntrack -F >/dev/null 2>&1 || true
    log "транспорт = HYSTERIA2 (default table $TABLE -> $TUN). Общие правила сохранены."
    cmd_status
}

cmd_down() {
    # ЧИСТЫЙ РЕЛИНКВИШ (симметрично transport-awg/xray down): отпускаем ТОЛЬКО свою несущую
    # (xtun) → fail-open в прямой. НЕ решаем, что поднять следом, и НЕ трогаем .transport —
    # это забота ОРКЕСТРАТОРА (transport.sh switch <name>).
    stop_daemons
    iptables -D FORWARD -o "$TUN" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i "$TUN" -j ACCEPT 2>/dev/null
    ip route flush table "$TABLE" 2>/dev/null || true
    rm -f "$SEED_CONF" 2>/dev/null         # снять локальный сид server-host (set_direct_dns ниже рестартит dnsmasq)
    set_direct_dns
    rm -f /tmp/awg-watchdog.xstate /tmp/awg-failover-episode 2>/dev/null
    conntrack -F >/dev/null 2>&1 || true
    log "Hysteria2-несущая снята (релинквиш) -> прямой режим (fail-open). Следующий транспорт ставит оркестратор."
}

cmd_status() {
    t=awg; [ -f "$TRANSPORT_FLAG" ] && t=$(cat "$TRANSPORT_FLAG")
    echo "=== транспорт: $t ==="
    echo "--- default в table $TABLE ---"; ip route show table "$TABLE" 2>/dev/null | grep default
    echo "--- демоны ---"
    proc_alive "$HY2_PID" && echo "hysteria: pid $(cat $HY2_PID) жив" || echo "hysteria: не запущен"
    proc_alive "$HEV_PID" && echo "hev:      pid $(cat $HEV_PID) жив" || echo "hev:      не запущен"
    echo "--- tun $TUN ---"; ip -o link show "$TUN" 2>/dev/null || echo "нет"
    echo "--- socks $SOCKS_PORT ---"; netstat -ltn 2>/dev/null | grep "$SOCKS_PORT" || echo "не слушает"
    if [ "$t" = hy2 ]; then
        echo "--- egress через hysteria socks ---"
        curl -s --max-time 8 --socks5-hostname "$SOCKS_ADDR:$SOCKS_PORT" https://api.ipify.org 2>/dev/null; echo
    fi
    echo "--- awg0 (тёплый резерв) ---"; ip link show awg0 >/dev/null 2>&1 && echo "поднят" || echo "нет"
}

# health для watchdog: 0 = здоров ИЛИ транспорт не hy2; 1 = hy2 нездоров.
cmd_health() {
    t=awg; [ -f "$TRANSPORT_FLAG" ] && t=$(cat "$TRANSPORT_FLAG")
    [ "$t" = hy2 ] || return 0
    proc_alive "$HY2_PID" || { log "health: hysteria не жив"; return 1; }
    proc_alive "$HEV_PID" || { log "health: hev не жив"; return 1; }
    ip link show "$TUN" >/dev/null 2>&1 || { log "health: нет $TUN"; return 1; }
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
