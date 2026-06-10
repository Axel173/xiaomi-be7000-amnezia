#!/bin/sh
# apply-bypass.sh — переигрывает «вырезы мимо VPN» после ребута и fw3-reload.
#
# ЗАЧЕМ. Базовое раздельное туннелирование (трафик из списков -> VPN) восстанавливает
# awg-heal.sh/split-route.sh при КАЖДОЙ загрузке. А ИСКЛЮЧЕНИЯ (то, что ты увёл
# НАПРЯМУЮ, мимо VPN) живут только в iptables/ip rule = RAM, и их не восстанавливал
# никто: после ребута/fw3-reload устройство/SSID/гостевая молча возвращались в VPN.
# Этот скрипт хранит исключения в persistent-файлах на /data и переигрывает их.
#
# Что хранит (файлы в $AWG_DIR, раздел /data переживает ребут):
#   .bypass-ips      — IP устройств (ИСТОЧНИК, LAN) мимо VPN (по строке на IP).
#                      Зеркало `vpn-toggle.sh exclude` (-s IP -j ACCEPT в VPN_EXCLUDE).
#   .bypass-dst      — IP/подсети НАЗНАЧЕНИЯ (сайты/сервисы) мимо VPN (CIDR на строку).
#                      Правило -d CIDR -j ACCEPT в VPN_EXCLUDE. Надёжно перебивает
#                      iplist_set/awg_list, т.к. цепочка проверяется ПЕРВОЙ, до меток.
#   .bypass-ifaces   — Wi-Fi-iface'ы мимо VPN (по строке на iface, напр. wl16).
#                      Зеркало пункта 25 меню (правило -m physdev --physdev-in IF).
#   .bypass-guest    — флаг-файл: есть -> гостевая 192.168.33.0/24 идёт мимо VPN
#                      (ip rule pref 90 -> main). Зеркало пункта 24 меню.
#
# И ОБРАТНОЕ — «ЦЕЛИКОМ через VPN» (force, цепочка VPN_FORCE, MARK вместо ACCEPT):
#   .fullvpn-ips     — IP устройств (источник) целиком в VPN (по строке на IP).
#   .fullvpn-ifaces  — Wi-Fi iface (SSID) целиком в VPN (physdev, по строке).
#   .fullvpn-guest   — флаг: гостевая целиком в VPN (взаимоискл. с .bypass-guest).
#   .full-tunnel     — флаг: ВЕСЬ трафик через VPN (catch-all). Зеркало пункта 23.
#
# БЕЗОПАСНОСТЬ. Все правила тут гонят трафик ТОЛЬКО в прямой путь (провайдер) или в
# main-таблицу — они физически НЕ могут увести трафик в дохлый awg0. Поэтому даже при
# кривом/пустом хранилище «интернет и VPN не упадут»: это лишь карта исключений, а не
# базовая маршрутизация (её держит split-route.sh).
#
# ИДЕМПОТЕНТНОСТЬ. apply можно звать сколько угодно: перед каждым -A стоит -C (а для
# ip rule — grep-проверка), дубли не плодятся. Зовётся из awg-heal.sh (после
# split-route) и из vpn-toggle.sh repair.
#
# busybox-замечания: используем grep -qxF / grep -vxF
# (whole-line, fixed-string) — они есть в busybox; НЕ используем grep -c/--color.
#
# Использование:
#   apply-bypass.sh apply           — переиграть всё из хранилища (идемпотентно)
#   apply-bypass.sh add-ip   <IP>    — занести IP устройства в хранилище и применить
#   apply-bypass.sh del-ip   <IP>    — убрать IP устройства из хранилища и снять
#   apply-bypass.sh add-dst  <CIDR>  — сайт-IP/подсеть назначения мимо VPN (+хранилище)
#   apply-bypass.sh del-dst  <CIDR>  — вернуть сайт-IP/подсеть в VPN (снять правило)
#   apply-bypass.sh add-if   <IFACE> — занести iface и применить правило
#   apply-bypass.sh del-if   <IFACE> — убрать iface и снять правило
#   apply-bypass.sh guest-on         — гостевая мимо VPN (флаг + ip rule pref 90)
#   apply-bypass.sh guest-off        — гостевая обратно в VPN (снять флаг + правило)
#   apply-bypass.sh force-add-ip <IP>    — устройство ЦЕЛИКОМ через VPN (+хранилище)
#   apply-bypass.sh force-del-ip <IP>    — вернуть устройство в раздельный режим
#   apply-bypass.sh force-add-if <IFACE> — SSID/iface ЦЕЛИКОМ через VPN
#   apply-bypass.sh force-del-if <IFACE> — вернуть SSID/iface в раздельный режим
#   apply-bypass.sh force-guest-on       — гостевая ЦЕЛИКОМ через VPN
#   apply-bypass.sh force-guest-off      — гостевая обратно в раздельный режим
#   apply-bypass.sh full-tunnel on|off   — ВЕСЬ трафик через VPN (глоб. catch-all)
#   apply-bypass.sh list             — показать хранилище

AWG_DIR=/data/usr/app/awg
EXCLUDE_CHAIN=VPN_EXCLUDE
STORE_IPS="$AWG_DIR/.bypass-ips"
STORE_DST="$AWG_DIR/.bypass-dst"
STORE_IFS="$AWG_DIR/.bypass-ifaces"
STORE_GUEST="$AWG_DIR/.bypass-guest"
GUEST_SUBNET=192.168.33.0/24
GUEST_PREF=90

# --- «ЦЕЛИКОМ через VPN» (force) — зеркало bypass, но наоборот: помечаем -----
# Цепочка VPN_FORCE — обратная к VPN_EXCLUDE: вместо ACCEPT (мимо VPN) ставит
# MARK $FWMARK (= в туннель), игнорируя сплит по awg_list/iplist_set. Нужна,
# чтобы целую сеть/устройство/гостевую гнать в VPN ПОЛНОСТЬЮ, и для глобального
# full-tunnel («весь трафик через VPN»). Подцепляется в PREROUTING ВТОРОЙ —
# после VPN_EXCLUDE (явный вырез мимо VPN перебивает force) и ДО mark-правил
# split-route. ТОЛЬКО PREROUTING: трафик самого роутера (OUTPUT — handshake к
# endpoint, DNS к VPS) в туннель заворачивать нельзя, будет петля.
# БЕЗОПАСНОСТЬ: как и split-route, всё держится на одном `ip rule fwmark` →
# safety_off (watchdog при смерти VPS) удаляет его, и помеченный трафик уходит
# напрямую. Т.е. full-tunnel не способен «запереть» интернет насмерть.
FORCE_CHAIN=VPN_FORCE
STORE_FORCE_IPS="$AWG_DIR/.fullvpn-ips"     # IP устройств (источник) ЦЕЛИКОМ в VPN
STORE_FORCE_IFS="$AWG_DIR/.fullvpn-ifaces"  # Wi-Fi iface (SSID) ЦЕЛИКОМ в VPN
STORE_FORCE_GUEST="$AWG_DIR/.fullvpn-guest" # флаг: гостевая ЦЕЛИКОМ в VPN
FULLTUNNEL_FLAG="$AWG_DIR/.full-tunnel"     # флаг: ВЕСЬ трафик через VPN
FWMARK=0x1
# Частные/служебные подсети, которые НЕ заворачиваем в VPN даже в full-tunnel —
# иначе ляжет связность внутри LAN и доступ к самому роутеру. RETURN (не ACCEPT):
# выходим из VPN_FORCE обратно в PREROUTING, где локалку никто не метит (в
# awg_list/iplist_set только публичные адреса), а стоковый mangle сохраняется.
LOCAL_NETS="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 224.0.0.0/4"

# chain VPN_EXCLUDE: создать (если нет) и подцепить ПЕРВЫМ в PREROUTING+OUTPUT.
# Один-в-один с ensure_chain из vpn-toggle.sh — набор хуков и порядок должны
# совпадать (PREROUTING — для LAN-клиентов через роутер, OUTPUT — для трафика
# самого роутера). Вставка первым правилом гарантирует: исключение проверяется
# РАНЬШЕ mark-правил awg_list/iplist_set, иначе пакет всё равно получит mark.
ensure_chain() {
    iptables -t mangle -L "$EXCLUDE_CHAIN" -n >/dev/null 2>&1 || \
        iptables -t mangle -N "$EXCLUDE_CHAIN"
    iptables -t mangle -D PREROUTING -j "$EXCLUDE_CHAIN" 2>/dev/null
    iptables -t mangle -I PREROUTING 1 -j "$EXCLUDE_CHAIN"
    iptables -t mangle -D OUTPUT -j "$EXCLUDE_CHAIN" 2>/dev/null
    iptables -t mangle -I OUTPUT 1 -j "$EXCLUDE_CHAIN"
}

# --- хранилище (атомарная правка: tmp + mv, чтобы обрыв записи не побил файл) ---
store_add() {   # $1 файл, $2 значение
    [ -z "$2" ] && return 0
    touch "$1"
    grep -qxF "$2" "$1" 2>/dev/null || echo "$2" >> "$1"
}
store_del() {   # $1 файл, $2 значение
    [ -f "$1" ] || return 0
    grep -vxF "$2" "$1" > "$1.tmp" 2>/dev/null
    mv "$1.tmp" "$1"
}

# --- применение/снятие ОДНОГО правила (идемпотентно) ---
rule_add_ip() {
    iptables -t mangle -C "$EXCLUDE_CHAIN" -s "$1" -j ACCEPT 2>/dev/null || \
        iptables -t mangle -A "$EXCLUDE_CHAIN" -s "$1" -j ACCEPT
}
rule_del_ip() { iptables -t mangle -D "$EXCLUDE_CHAIN" -s "$1" -j ACCEPT 2>/dev/null; }
# dst: исключаем по АДРЕСУ НАЗНАЧЕНИЯ (-d) — это «сайт мимо VPN». ACCEPT в
# VPN_EXCLUDE (цепочка первая в PREROUTING) обрывает обход mangle раньше, чем
# трафик пометится по awg_list/iplist_set, поэтому перебивает CIDR-список.
rule_add_dst() {
    iptables -t mangle -C "$EXCLUDE_CHAIN" -d "$1" -j ACCEPT 2>/dev/null || \
        iptables -t mangle -A "$EXCLUDE_CHAIN" -d "$1" -j ACCEPT
}
rule_del_dst() { iptables -t mangle -D "$EXCLUDE_CHAIN" -d "$1" -j ACCEPT 2>/dev/null; }
rule_add_if() {
    iptables -t mangle -C "$EXCLUDE_CHAIN" -m physdev --physdev-in "$1" -j ACCEPT 2>/dev/null || \
        iptables -t mangle -A "$EXCLUDE_CHAIN" -m physdev --physdev-in "$1" -j ACCEPT
}
rule_del_if() {
    iptables -t mangle -D "$EXCLUDE_CHAIN" -m physdev --physdev-in "$1" -j ACCEPT 2>/dev/null
    iptables -t mangle -D "$EXCLUDE_CHAIN" -i "$1" -j ACCEPT 2>/dev/null   # legacy-формат (-i)
}
guest_rule_add() {
    ip rule show | grep -q "from $GUEST_SUBNET lookup main" || \
        ip rule add from "$GUEST_SUBNET" lookup main pref $GUEST_PREF
}
guest_rule_del() { ip rule del from "$GUEST_SUBNET" lookup main pref $GUEST_PREF 2>/dev/null; }

# --- VPN_FORCE: «целиком через VPN» (см. шапку про force) -------------------
# chain VPN_FORCE: создать (если нет) и подцепить ВТОРЫМ в PREROUTING (после
# VPN_EXCLUDE, который ensure_chain ставит первым). Только PREROUTING.
ensure_force_chain() {
    iptables -t mangle -L "$FORCE_CHAIN" -n >/dev/null 2>&1 || \
        iptables -t mangle -N "$FORCE_CHAIN"
    iptables -t mangle -D PREROUTING -j "$FORCE_CHAIN" 2>/dev/null
    iptables -t mangle -I PREROUTING 2 -j "$FORCE_CHAIN"
}

# Есть ли вообще что форсить в VPN? Если нет — VPN_FORCE не вешаем вовсе, чтобы
# у тех, кто полным туннелем не пользуется, набор правил остался прежним (split).
force_active() {
    [ -f "$FULLTUNNEL_FLAG" ]   && return 0
    [ -s "$STORE_FORCE_IPS" ]   && return 0
    [ -s "$STORE_FORCE_IFS" ]   && return 0
    [ -f "$STORE_FORCE_GUEST" ] && return 0
    return 1
}

# Пересобрать VPN_FORCE из хранилища (идемпотентно: flush + заново в нужном
# порядке). Порядок ВНУТРИ цепочки важен: сперва вывести локалку (RETURN), затем
# точечный force (устройства/iface/guest), и в самом конце — глобальный catch-all.
rebuild_force() {
    if ! force_active; then
        # ничего не форсим — снять jump и очистить, вернуть чистый split
        iptables -t mangle -D PREROUTING -j "$FORCE_CHAIN" 2>/dev/null
        iptables -t mangle -F "$FORCE_CHAIN" 2>/dev/null
        echo "[apply-bypass] force(в VPN): выключено (раздельный режим)"
        return 0
    fi
    ensure_chain          # VPN_EXCLUDE должен быть ПЕРВЫМ, чтобы VPN_FORCE лёг ВТОРЫМ
    ensure_force_chain
    iptables -t mangle -F "$FORCE_CHAIN"
    # 1) локалку/служебное — наружу из цепочки (остаётся в прямом/локальном пути)
    for net in $LOCAL_NETS; do
        iptables -t mangle -A "$FORCE_CHAIN" -d "$net" -j RETURN
    done
    iptables -t mangle -A "$FORCE_CHAIN" -d 255.255.255.255 -j RETURN
    n_fip=0; n_fif=0; fg=off; ft=off
    # 2) устройства (источник) целиком в VPN
    if [ -f "$STORE_FORCE_IPS" ]; then
        while IFS= read -r ip; do
            [ -n "$ip" ] && iptables -t mangle -A "$FORCE_CHAIN" -s "$ip" -j MARK --set-mark $FWMARK && n_fip=$((n_fip+1))
        done < "$STORE_FORCE_IPS"
    fi
    # 3) Wi-Fi iface (SSID) целиком в VPN — physdev (wlN живёт в bridge, см.
    #    комментарий про physdev в шапке про bypass-ifaces / vpn-toggle.sh)
    if [ -f "$STORE_FORCE_IFS" ]; then
        while IFS= read -r iface; do
            [ -n "$iface" ] && iptables -t mangle -A "$FORCE_CHAIN" -m physdev --physdev-in "$iface" -j MARK --set-mark $FWMARK && n_fif=$((n_fif+1))
        done < "$STORE_FORCE_IFS"
    fi
    # 4) гостевая целиком в VPN (по источнику-подсети)
    if [ -f "$STORE_FORCE_GUEST" ]; then
        iptables -t mangle -A "$FORCE_CHAIN" -s "$GUEST_SUBNET" -j MARK --set-mark $FWMARK
        fg=on
    fi
    # 5) ГЛОБАЛЬНО: весь остальной (нелокальный) форвард — в VPN. Должен идти
    #    ПОСЛЕДНИМ, после локалки-RETURN и точечных правил.
    if [ -f "$FULLTUNNEL_FLAG" ]; then
        iptables -t mangle -A "$FORCE_CHAIN" -j MARK --set-mark $FWMARK
        ft=on
    fi
    echo "[apply-bypass] force(в VPN): ip=$n_fip, iface=$n_fif, guest=$fg, full-tunnel=$ft"
}

# Сбросить conntrack, чтобы смена режима применилась к УЖЕ установленным
# соединениям сразу (Qualcomm NSS/ECM иначе держит старый маршрут до таймаута).
# Кратко рвёт активные сессии — это норма для
# осознанного переключения режима. Полный flush (не точечный): full-tunnel/iface/
# guest точечно по src не выберешь.
force_conntrack_flush() { conntrack -F >/dev/null 2>&1 || true; }

# --- переиграть ВСЁ хранилище (вызов на boot/repair) ---
apply_all() {
    ensure_chain
    n_ip=0; n_dst=0; n_if=0; g=off
    if [ -f "$STORE_IPS" ]; then
        # `done < файл` (не пайп) — цикл в текущем шелле, счётчики не теряются
        while IFS= read -r ip; do
            [ -n "$ip" ] && rule_add_ip "$ip" && n_ip=$((n_ip+1))
        done < "$STORE_IPS"
    fi
    if [ -f "$STORE_DST" ]; then
        while IFS= read -r dst; do
            [ -n "$dst" ] && rule_add_dst "$dst" && n_dst=$((n_dst+1))
        done < "$STORE_DST"
    fi
    if [ -f "$STORE_IFS" ]; then
        while IFS= read -r iface; do
            [ -n "$iface" ] && rule_add_if "$iface" && n_if=$((n_if+1))
        done < "$STORE_IFS"
    fi
    [ -f "$STORE_GUEST" ] && { guest_rule_add; g=on; }
    echo "[apply-bypass] восстановлено: ip=$n_ip, dst=$n_dst, iface=$n_if, guest=$g"
    # «целиком через VPN» (force) — отдельная цепочка VPN_FORCE
    rebuild_force
}

case "$1" in
    apply)     apply_all ;;
    add-ip)    [ -z "$2" ] && { echo "нужен IP";    exit 1; }; ensure_chain; store_add "$STORE_IPS" "$2"; rule_add_ip "$2"; echo "IP $2 -> хранилище + применён" ;;
    del-ip)    [ -z "$2" ] && { echo "нужен IP";    exit 1; }; store_del "$STORE_IPS" "$2"; rule_del_ip "$2"; echo "IP $2 убран из хранилища" ;;
    add-dst)   [ -z "$2" ] && { echo "нужен CIDR";  exit 1; }; ensure_chain; store_add "$STORE_DST" "$2"; rule_add_dst "$2"; echo "dst $2 -> хранилище + мимо VPN" ;;
    del-dst)   [ -z "$2" ] && { echo "нужен CIDR";  exit 1; }; store_del "$STORE_DST" "$2"; rule_del_dst "$2"; echo "dst $2 убран из хранилища" ;;
    add-if)    [ -z "$2" ] && { echo "нужен iface"; exit 1; }; ensure_chain; store_add "$STORE_IFS" "$2"; rule_add_if "$2"; echo "iface $2 -> хранилище + применён" ;;
    del-if)    [ -z "$2" ] && { echo "нужен iface"; exit 1; }; store_del "$STORE_IFS" "$2"; rule_del_if "$2"; echo "iface $2 убран из хранилища" ;;
    guest-on)  ensure_chain; touch "$STORE_GUEST"; guest_rule_add; echo "guest 192.168.33.0/24 -> мимо VPN (флаг + ip rule)" ;;
    guest-off) rm -f "$STORE_GUEST"; guest_rule_del; echo "guest 192.168.33.0/24 -> обратно в VPN" ;;
    # --- «целиком через VPN» (force). Меняем хранилище -> пересобираем VPN_FORCE
    #     -> сбрасываем conntrack, чтобы применилось к текущим соединениям сразу.
    force-add-ip)  [ -z "$2" ] && { echo "нужен IP";    exit 1; }; store_add "$STORE_FORCE_IPS" "$2"; rebuild_force; force_conntrack_flush; echo "IP $2 -> ЦЕЛИКОМ через VPN (+хранилище)" ;;
    force-del-ip)  [ -z "$2" ] && { echo "нужен IP";    exit 1; }; store_del "$STORE_FORCE_IPS" "$2"; rebuild_force; force_conntrack_flush; echo "IP $2 -> обычный режим (раздельный)" ;;
    force-add-if)  [ -z "$2" ] && { echo "нужен iface"; exit 1; }; store_add "$STORE_FORCE_IFS" "$2"; rebuild_force; force_conntrack_flush; echo "iface $2 -> ЦЕЛИКОМ через VPN" ;;
    force-del-if)  [ -z "$2" ] && { echo "нужен iface"; exit 1; }; store_del "$STORE_FORCE_IFS" "$2"; rebuild_force; force_conntrack_flush; echo "iface $2 -> обычный режим" ;;
    # guest целиком в VPN взаимоисключим с guest мимо VPN — снимаем bypass-флаг
    force-guest-on)  rm -f "$STORE_GUEST"; guest_rule_del; touch "$STORE_FORCE_GUEST"; rebuild_force; force_conntrack_flush; echo "guest -> ЦЕЛИКОМ через VPN" ;;
    force-guest-off) rm -f "$STORE_FORCE_GUEST"; rebuild_force; force_conntrack_flush; echo "guest -> обычный режим (раздельный)" ;;
    full-tunnel)
        case "$2" in
            on)  touch "$FULLTUNNEL_FLAG"; rebuild_force; force_conntrack_flush; echo "FULL-TUNNEL ON: весь трафик через VPN (кроме локалки и вырезов)" ;;
            off) rm -f "$FULLTUNNEL_FLAG"; rebuild_force; force_conntrack_flush; echo "FULL-TUNNEL OFF: вернулся раздельный режим (split по awg_list/iplist_set)" ;;
            *)   if [ -f "$FULLTUNNEL_FLAG" ]; then echo "full-tunnel: ON"; else echo "full-tunnel: OFF"; fi ;;
        esac ;;
    list)
        echo "== .bypass-ips (устройства/источник мимо VPN) =="
        if [ -s "$STORE_IPS" ]; then cat "$STORE_IPS"; else echo "(пусто)"; fi
        echo "== .bypass-dst (сайты-IP/назначение мимо VPN) =="
        if [ -s "$STORE_DST" ]; then cat "$STORE_DST"; else echo "(пусто)"; fi
        echo "== .bypass-ifaces (SSID/iface мимо VPN) =="
        if [ -s "$STORE_IFS" ]; then cat "$STORE_IFS"; else echo "(пусто)"; fi
        echo "== ЦЕЛИКОМ через VPN (force) =="
        if [ -f "$FULLTUNNEL_FLAG" ]; then echo "FULL-TUNNEL: ВЕСЬ трафик через VPN (кроме локалки и вырезов выше)"; fi
        echo "-- .fullvpn-ips (устройства целиком в VPN) --"
        if [ -s "$STORE_FORCE_IPS" ]; then cat "$STORE_FORCE_IPS"; else echo "(пусто)"; fi
        echo "-- .fullvpn-ifaces (SSID/iface целиком в VPN) --"
        if [ -s "$STORE_FORCE_IFS" ]; then cat "$STORE_FORCE_IFS"; else echo "(пусто)"; fi
        echo "== guest =="
        if   [ -f "$STORE_FORCE_GUEST" ]; then echo "ЦЕЛИКОМ через VPN (force)"
        elif [ -f "$STORE_GUEST" ];       then echo "мимо VPN (pref $GUEST_PREF)"
        else echo "раздельный режим (split)"; fi
        ;;
    *)
        echo "Использование: $0 {apply|add-ip IP|del-ip IP|add-dst CIDR|del-dst CIDR|add-if IFACE|del-if IFACE|guest-on|guest-off|force-add-ip IP|force-del-ip IP|force-add-if IFACE|force-del-if IFACE|force-guest-on|force-guest-off|full-tunnel on|off|list}"
        exit 1
        ;;
esac
