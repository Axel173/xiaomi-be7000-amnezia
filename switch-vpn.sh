#!/bin/sh
#
# switch-vpn.sh v3 — переключение страны/конфига AmneziaWG с правильной
# заменой ВСЕХ файлов конфигурации, без гонок с awg-heal.sh и с safety net
# на случай полного фейла.
#
# v3 (май 2026) — лечит «при смене страны интернет на роутере пропадает,
# падает awg, помогает только перезагрузка»:
#
#   1) вендорный awg_setup.sh читает не awg.conf, а amnezia_for_awg.conf.
#      Из него генерирует awg0.conf для amneziawg-go. v2 копировал ТОЛЬКО
#      awg.conf — поэтому на самом деле awg продолжал использовать СТАРЫЕ
#      ключи/endpoint. v3 синхронно обновляет все три файла.
#
#   2) Новый конфиг от приложения AmneziaVPN 4.8.12.9+ часто содержит
#      пустые I1..I5 — старые awg-tools валятся на них. Перед запуском
#      вендорного скрипта v3 их вычищает.
#
#   3) Между bring_down и bring_up могут параллельно сработать awg-heal.sh
#      (cron каждую минуту) и сломать состояние. v3 берёт лок
#      /tmp/awg-switching.lock — awg-heal.sh с него же читает и выходит,
#      пока идёт переключение.
#
#   4) Если awg0 в итоге не поднялся ни на новом, ни на старом конфиге —
#      v2 ОСТАВЛЯЛ висеть `ip rule fwmark 0x1 → table 1000 → dev awg0`
#      и mangle-правила по iplist_set (~3100 CIDR — Cloudflare/Google/
#      OpenAI/Discord). В результате весь трафик роутера к этим адресам
#      уходил в несуществующий awg0 → «интернет вовсе пропал, помогает
#      только ребут». v3 в этой ситуации флашит правила (safety_off),
#      роутер сохраняет доступ в интернет, а awg-heal.sh при следующем
#      запуске всё восстановит.
#
#   5) Принудительно убиваем зависшие amneziawg-go процессы перед
#      bring_up (иногда init.d stop их не убирает, особенно если запуск
#      был не через init.d).
#
# Использование:
#   switch-vpn.sh                — список конфигов
#   switch-vpn.sh <имя>          — переключиться на configs/<имя>.conf
#   switch-vpn.sh status         — текущий статус
#   switch-vpn.sh rollback       — вручную откатиться на .last.bak
#   switch-vpn.sh failover       — перебрать резервы и встать на первый рабочий
#                                  (зовётся watchdog'ом при смерти активного VPS)

AWG_DIR="/data/usr/app/awg"
CONFIGS_DIR="$AWG_DIR/configs"
ACTIVE_CONF="$AWG_DIR/awg.conf"
SHALIN_CONF="$AWG_DIR/amnezia_for_awg.conf"
AWG0_CONF="$AWG_DIR/awg0.conf"
ACTIVE_NAME="$AWG_DIR/.active"
BACKUP_CONF="$AWG_DIR/.last.bak.conf"
BACKUP_NAME="$AWG_DIR/.last.bak.name"
SWITCH_LOCK="/tmp/awg-switching.lock"
NOTIFY_EVENT="$AWG_DIR/notify-event.sh"   # обёртка событийных писем (throttle)
HS_WAIT=25                       # сколько секунд ждать handshake

# Событийное письмо: $1 key, $2 throttle_sec, $3 тема, $4 текст.
# Тихо ничего не делает, если обёртки нет или почта не настроена
# (notify-event.sh сам уважает .notify-off и тихо выходит без notify.conf).
notify_event() {
    [ -x "$NOTIFY_EVENT" ] && "$NOTIFY_EVENT" "$1" "$2" "$3" "$4" >/dev/null 2>&1
}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

mkdir -p "$CONFIGS_DIR"

# Бинарь для проверки handshake
WG=""
command -v wg >/dev/null 2>&1 && WG=wg
[ -z "$WG" ] && [ -x "$AWG_DIR/awg" ] && WG="$AWG_DIR/awg"

# ============================================================
# Локи против гонок с awg-heal.sh
# ============================================================
acquire_lock() {
    : > "$SWITCH_LOCK"
    trap 'release_lock' EXIT INT TERM HUP
}
release_lock() {
    # Сохраняем код возврата: failover отдаёт его watchdog'у (0=встал на резерв /
    # 1=прямой режим), а этот хендлер висит на EXIT-trap и не должен его затереть.
    _rc=$?
    rm -f "$SWITCH_LOCK" 2>/dev/null
    return $_rc
}

# ============================================================
# Утилиты
# ============================================================
list_configs() {
    printf "${BLUE}Доступные конфиги в $CONFIGS_DIR:${NC}\n"
    found=0
    for f in "$CONFIGS_DIR"/*.conf; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .conf)
        endpoint=$(grep -E "^Endpoint" "$f" | head -1 | awk -F'= *' '{print $2}')
        active=""
        if [ -f "$ACTIVE_NAME" ] && [ "$(cat "$ACTIVE_NAME")" = "$name" ]; then
            active="${GREEN} ← АКТИВНЫЙ${NC}"
        fi
        printf "  ${YELLOW}%-20s${NC} (Endpoint: %s)%s\n" "$name" "$endpoint" "$active"
        found=$((found+1))
    done
    [ $found -eq 0 ] && printf "  ${RED}Конфигов нет.${NC} Положи .conf в %s\n" "$CONFIGS_DIR"
}

show_status() {
    printf "${BLUE}Статус AmneziaWG:${NC}\n"
    if [ -f "$ACTIVE_NAME" ]; then
        printf "  Активный конфиг: ${GREEN}%s${NC}\n" "$(cat "$ACTIVE_NAME")"
    fi
    if ip link show awg0 >/dev/null 2>&1; then
        printf "  Интерфейс awg0: ${GREEN}поднят${NC}\n"
        if [ -n "$WG" ]; then
            hs=$($WG show awg0 latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
            case "$hs" in
                ''|*[!0-9]*) hs=0 ;;
            esac
            if [ "$hs" -gt 0 ]; then
                ago=$(( $(date +%s) - hs ))
                printf "  Handshake: ${GREEN}%d сек назад${NC}\n" "$ago"
            else
                printf "  Handshake: ${RED}нет${NC}\n"
            fi
        fi
        ip_vpn=$(curl -s --interface awg0 --max-time 5 https://api.ipify.org 2>/dev/null)
        [ -n "$ip_vpn" ] && printf "  Внешний IP через VPN: ${GREEN}%s${NC}\n" "$ip_vpn"
    else
        printf "  Интерфейс awg0: ${RED}не поднят${NC}\n"
    fi
}

# Ждать handshake до HS_WAIT секунд
wait_for_handshake() {
    [ -z "$WG" ] && return 1
    i=0
    while [ $i -lt $HS_WAIT ]; do
        hs=$($WG show awg0 latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
        case "$hs" in
            ''|*[!0-9]*) hs=0 ;;
        esac
        if [ "$hs" -gt 0 ]; then
            ago=$(( $(date +%s) - hs ))
            [ "$ago" -lt 300 ] && return 0
        fi
        sleep 1
        i=$((i+1))
        printf "."
    done
    return 1
}

# Установить ВСЕ файлы конфигурации из source-файла.
# Это главное изменение v3: amnezia_for_awg.conf — то, что реально
# читает вендорный awg_setup.sh, поэтому он тоже должен обновиться.
install_config() {
    src="$1"
    name="$2"

    # 1. Главный awg.conf
    cp "$src" "$ACTIVE_CONF"

    # 2. Чистим пустые I1..I5 (AmneziaVPN 4.8.12.9+ их добавляет)
    if grep -qE '^I[1-5][[:space:]]*=[[:space:]]*$' "$ACTIVE_CONF"; then
        sed -i '/^I[1-5][[:space:]]*=[[:space:]]*$/d' "$ACTIVE_CONF"
    fi

    # 3. Синхронизируем amnezia_for_awg.conf — вендорный awg_setup.sh
    #    читает именно его. БЕЗ этого awg продолжит использовать СТАРЫЕ
    #    ключи и endpoint после "переключения".
    cp "$ACTIVE_CONF" "$SHALIN_CONF"

    # 4. Удаляем awg0.conf чтобы вендорный скрипт сгенерировал свежий.
    #    Иначе amneziawg-go читает старые ключи из awg0.conf.
    rm -f "$AWG0_CONF"

    # 5. Запоминаем имя активного
    echo "$name" > "$ACTIVE_NAME"
}

# Глушим amneziawg-go процессы (на случай если init.d не убил)
kill_awg_processes() {
    for proc in amneziawg-go amnezia-wg wireguard-go; do
        if pidof "$proc" >/dev/null 2>&1; then
            killall -TERM "$proc" 2>/dev/null
            sleep 1
            killall -KILL "$proc" 2>/dev/null
        fi
    done
}

# Поднять туннель из текущего awg.conf
bring_up() {
    ip link del awg0 2>/dev/null
    kill_awg_processes
    sleep 1

    started=0
    for s in /etc/init.d/awg /etc/init.d/amneziawg /etc/init.d/amnezia; do
        if [ -x "$s" ]; then
            "$s" start >/dev/null 2>&1
            started=1
            break
        fi
    done

    # Если init.d не справился или его нет — зовём вендорный awg_setup.sh
    if ! ip link show awg0 >/dev/null 2>&1 && [ -x "$AWG_DIR/awg_setup.sh" ]; then
        ( cd "$AWG_DIR" && ./awg_setup.sh >/tmp/switch-vpn-setup.log 2>&1 )
    fi

    # Ждём появления интерфейса
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        ip link show awg0 >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

bring_down() {
    for s in /etc/init.d/awg /etc/init.d/amneziawg /etc/init.d/amnezia; do
        [ -x "$s" ] && "$s" stop >/dev/null 2>&1 && break
    done
    ip link set awg0 down 2>/dev/null
    ip link del awg0 2>/dev/null
    kill_awg_processes
}

# Восстановить нормальную маршрутизацию через awg0
apply_routing() {
    if [ -x "$AWG_DIR/split-route.sh" ]; then
        "$AWG_DIR/split-route.sh" >/dev/null 2>&1
    fi
    # ipset awg_list сбрасываем — там осели старые IP, привязанные к
    # старому endpoint. Пусть dnsmasq заполнит свежими.
    ipset flush awg_list 2>/dev/null
    killall -HUP dnsmasq 2>/dev/null
}

# SAFETY NET: туннель окончательно мёртв (новый конфиг не поднялся и
# откат тоже не поднялся). Без этого роутер «уходит в кирпич»:
#   1) fwmark+mangle гонят трафик в дохлый awg0 — даже исходящий с
#      самого роутера к Cloudflare/Google/OpenAI (~3100 CIDR в iplist_set)
#   2) КЛЮЧЕВОЕ: dnsmasq настроен на upstream-DNS внутри туннеля
#      (172.29.172.254 от Amnezia). Когда awg0 умирает, dnsmasq шлёт
#      запросы в дохлый интерфейс → НИ ОДИН сайт не резолвится, даже
#      yandex.ru. SSH работает только потому, что заходишь по IP.
# safety_off восстанавливает оба пути: трафик идёт напрямую через
# провайдера, DNS — на 1.1.1.1/8.8.8.8. Это временное состояние;
# awg-heal.sh при следующем срабатывании (раз в минуту) всё восстановит,
# если awg.conf к тому моменту валиден (после rollback он уже OLD).
safety_off() {
    printf "${YELLOW}[safety]${NC} убираю fwmark/mangle/DNS-привязку к дохлому awg0\n"

    # 1. fwmark+mangle (чтобы трафик к iplist_set/awg_list не уходил в awg0)
    ip rule del fwmark 0x1 table 1000 2>/dev/null
    for set in awg_list iplist_set; do
        iptables -t mangle -D PREROUTING -m set --match-set "$set" dst -j MARK --set-mark 0x1 2>/dev/null
        iptables -t mangle -D OUTPUT     -m set --match-set "$set" dst -j MARK --set-mark 0x1 2>/dev/null
    done
    iptables -t nat -D POSTROUTING -o awg0 -j MASQUERADE 2>/dev/null

    # 2. DNS — выключаем upstream через дохлый туннель, ставим публичный.
    #    Это файл в overlay (/etc), он сбросится при ребуте — нам и надо.
    if [ -f /etc/dnsmasq.d/00-upstream.conf ]; then
        cat > /etc/dnsmasq.d/00-upstream.conf <<'DNS_FALLBACK'
# Временный fallback, поставлен switch-vpn.sh safety_off.
# Будет заменён обратно на VPN-DNS при следующем срабатывании awg-heal.sh
# (как только awg0 поднимется). При ребуте overlay /etc сбрасывается.
no-resolv
server=1.1.1.1
server=8.8.8.8
DNS_FALLBACK
    fi
    # Снимаем маршрут к VPN-DNS через дохлый awg0 (если был)
    VPN_DNS=$(grep -E '^DNS[[:space:]]*=' "$ACTIVE_CONF" 2>/dev/null | head -1 | awk -F'= *' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')
    [ -n "$VPN_DNS" ] && ip route del "$VPN_DNS/32" dev awg0 2>/dev/null

    # Перезапускаем dnsmasq, чтобы подхватил новый upstream
    /etc/init.d/dnsmasq restart 2>/dev/null || killall -HUP dnsmasq 2>/dev/null

    printf "${YELLOW}[safety]${NC} DNS временно на 1.1.1.1/8.8.8.8, трафик весь напрямую\n"
}

# Вернуть туннельный upstream-DNS — обратное к safety_off (тот ставит публичный
# 1.1.1.1/8.8.8.8). Нужно после УСПЕШНОГО failover: safety_off увёл DNS на
# публичный, а apply_routing/split-route.sh его НЕ возвращает (правят только
# МАРШРУТ к VPN_DNS через awg0, но не сам 00-upstream.conf). Без этого после
# failover'а dnsmasq резолвил бы через публичный DNS → домены из списка
# вернули бы поддельные IP-заглушки (DNS-спуфинг). Зеркало того, что делают awg-heal.sh и
# awg-watchdog.sh при возврате VPN. VPN_DNS берём из НОВОГО активного awg.conf.
restore_vpn_dns() {
    vpn_dns=$(grep -E '^DNS[[:space:]]*=' "$ACTIVE_CONF" 2>/dev/null | head -1 | awk -F'= *' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')
    [ -z "$vpn_dns" ] && vpn_dns=172.29.172.254
    mkdir -p /etc/dnsmasq.d
    printf 'no-resolv\nserver=%s\n' "$vpn_dns" > /etc/dnsmasq.d/00-upstream.conf
    ip route replace "$vpn_dns/32" dev awg0 2>/dev/null
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || killall -HUP dnsmasq 2>/dev/null
}

# ============================================================
# Главная процедура переключения с автооткатом
# ============================================================
switch_to() {
    target="$1"
    src="$CONFIGS_DIR/${target}.conf"
    if [ ! -f "$src" ]; then
        printf "${RED}[FAIL]${NC} Не найден файл %s\n" "$src"
        printf "Доступные конфиги:\n"
        list_configs
        exit 1
    fi

    acquire_lock

    # Сохраняем текущее (на случай отката)
    if [ -f "$ACTIVE_CONF" ]; then
        cp "$ACTIVE_CONF" "$BACKUP_CONF"
        if [ -f "$ACTIVE_NAME" ]; then
            cp "$ACTIVE_NAME" "$BACKUP_NAME"
        else
            : > "$BACKUP_NAME"
        fi
        printf "${BLUE}[бэкап]${NC} текущий конфиг сохранён в %s\n" "$BACKUP_CONF"
    fi

    printf "${BLUE}[1/5]${NC} Останавливаю awg0...\n"
    bring_down

    printf "${BLUE}[2/5]${NC} Применяю конфиг ${YELLOW}%s${NC} (awg.conf + amnezia_for_awg.conf + awg0.conf)...\n" "$target"
    install_config "$src" "$target"

    printf "${BLUE}[3/5]${NC} Поднимаю awg0...\n"
    if ! bring_up; then
        printf "${RED}[FAIL]${NC} awg0 не поднялся → автооткат\n"
        rollback
        return $?
    fi

    printf "${BLUE}[4/5]${NC} Жду handshake (до %d сек)" "$HS_WAIT"
    if wait_for_handshake; then
        printf " ${GREEN}есть${NC}\n"
        printf "${BLUE}[5/5]${NC} Применяю правила маршрутизации...\n"
        apply_routing
        printf "\n${GREEN}[OK]${NC} Переключение на ${YELLOW}%s${NC} успешно.\n\n" "$target"
        show_status
        # Осознанный (ручной) выбор страны = новый «основной» (home) для режима
        # failover home: именно сюда watchdog будет возвращаться, когда home оживёт.
        echo "$target" > "$AWG_DIR/.failover-home"
        return 0
    else
        printf " ${RED}нет ответа${NC}\n"
        printf "${RED}[FAIL]${NC} %s не подключается (handshake не пришёл за %d сек)\n" "$target" "$HS_WAIT"
        printf "${YELLOW}=> автооткат на предыдущий конфиг${NC}\n\n"
        rollback
        return $?
    fi
}

# Откат на сохранённый бэкап
rollback() {
    if [ ! -f "$BACKUP_CONF" ]; then
        printf "${RED}[FAIL]${NC} бэкап %s не найден, откатываться не на что\n" "$BACKUP_CONF"
        safety_off
        notify_event "switch-failopen" 3600 "BE7000: КРИТ — VPN не поднялся, прямой режим" \
"Новый конфиг не поднялся, а откатиться не на что (нет бэкапа $BACKUP_CONF).
Включён прямой режим (safety_off): интернет и DNS работают мимо VPN,
сайты из списка недоступны. awg0 не активен.
Зайди по SSH: cat /tmp/switch-vpn-setup.log; затем $AWG_DIR/awg-heal.sh."
        return 1
    fi
    prev_name="(неизвестно)"
    [ -s "$BACKUP_NAME" ] && prev_name=$(cat "$BACKUP_NAME")

    bring_down
    # Восстанавливаем ВСЕ три файла, как в install_config
    install_config "$BACKUP_CONF" "$prev_name"

    if bring_up && wait_for_handshake; then
        apply_routing
        printf "\n${GREEN}[ОТКАТ OK]${NC} вернулся на ${YELLOW}%s${NC}\n\n" "$prev_name"
        show_status
        notify_event "switch-rollback" 3600 "BE7000: автооткат VPN → $prev_name" \
"Переключение на новый конфиг не удалось (туннель не поднялся или не пришёл
handshake). Роутер автоматически откатился на предыдущий конфиг: $prev_name —
VPN снова работает на нём. Проверь новый конфиг и попробуй ещё раз."
        return 0
    else
        printf "\n${RED}[ОТКАТ FAIL]${NC} даже старый конфиг не поднялся.\n"
        printf "${RED}Включаю safety_off — чтобы роутер не упёрся в дохлый awg0.${NC}\n"
        safety_off
        notify_event "switch-failopen" 3600 "BE7000: КРИТ — VPN не поднялся, прямой режим" \
"Смена конфига провалилась, и ОТКАТ на старый конфиг ($prev_name) тоже не
поднял туннель. Включён прямой режим (safety_off): интернет и DNS работают
мимо VPN, сайты из списка недоступны. awg0 не активен.
Разбор по SSH: cat /tmp/switch-vpn-setup.log; cat /tmp/awg-startup.log."
        printf "${YELLOW}Что делать:${NC}\n"
        printf "  1) Проверь awg.conf: cat %s\n" "$ACTIVE_CONF"
        printf "  2) Проверь интернет на роутере: ping 1.1.1.1\n"
        printf "  3) Запусти awg-heal.sh вручную: %s/awg-heal.sh\n" "$AWG_DIR"
        printf "  4) Если не помогло — reboot и SSH-вход, разбор по логам:\n"
        printf "     cat /tmp/awg-startup.log; cat /tmp/switch-vpn-setup.log\n"
        return 1
    fi
}

# ============================================================
# FAILOVER: автоматический перебор резервных конфигов
# ============================================================
# Зовётся awg-watchdog.sh (или вручную: switch-vpn.sh failover), когда активный
# VPS умер. В отличие от switch_to (переключение на КОНКРЕТНУЮ страну) —
# перебирает ВСЕ configs/*.conf по алфавиту (glob в sh сортирован), кроме
# текущего, и встаёт на первый, давший handshake.
#
# Почему safety_off ПЕРВЫМ: перебор несколько раз опускает/поднимает awg0. Если
# оставить fwmark/mangle и туннельный DNS — на время перебора клиенты снова без
# интернета и DNS (ровно та авария, что чиним: трафик к iplist_set/awg_list
# уходит в дохлый awg0, dnsmasq не резолвит). safety_off сразу пускает трафик/DNS
# напрямую, а VPN-роутинг возвращаем ТОЛЬКО когда резерв реально ответил
# (apply_routing + restore_vpn_dns).
#
# Возврат: 0 — встали на резерв (.active обновлён install_config'ом); 1 — ни один
# не встал, остались в прямом режиме (safety_off), awg0 поднят на ИСХОДНОМ конфиге
# для дальнейшего мониторинга watchdog'ом (вернётся, когда исходный оживёт).
do_failover() {
    acquire_lock

    cur_name=""
    [ -f "$ACTIVE_NAME" ] && cur_name=$(cat "$ACTIVE_NAME")

    # Сохраняем текущий (исходный) конфиг — если ни один резерв не встанет,
    # вернём его, чтобы awg0 мониторил именно исходный сервер.
    if [ -f "$ACTIVE_CONF" ]; then
        cp "$ACTIVE_CONF" "$BACKUP_CONF"
        if [ -f "$ACTIVE_NAME" ]; then cp "$ACTIVE_NAME" "$BACKUP_NAME"; else : > "$BACKUP_NAME"; fi
    fi

    printf "${BLUE}[failover]${NC} активный сервер ${YELLOW}%s${NC} не отвечает — перебираю резервы\n" "${cur_name:-?}"

    # 1) Немедленно вернуть интернет/публичный DNS (см. шапку функции).
    safety_off

    # 2) Перебор резервов по алфавиту; первый с handshake — наш.
    tried=""
    for f in "$CONFIGS_DIR"/*.conf; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .conf)
        [ "$name" = "$cur_name" ] && continue   # текущий (дохлый) пропускаем

        printf "${BLUE}[failover]${NC} пробую ${YELLOW}%s${NC}...\n" "$name"
        bring_down
        install_config "$f" "$name"
        if bring_up && wait_for_handshake; then
            apply_routing
            restore_vpn_dns          # safety_off увёл DNS на публичный — вернуть туннельный
            ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null)
            printf "\n${GREEN}[failover OK]${NC} встал на ${YELLOW}%s${NC} (внешний IP: %s)\n" "$name" "${ip:-?}"
            notify_event "failover-ok" 1800 "BE7000: VPN-failover -> $name" \
"Сервер ${cur_name:-?} перестал отвечать. Роутер автоматически переключился
на резервный конфиг: $name — VPN снова работает (handshake получен).
Внешний IP сейчас: ${ip:-неизвестен}.

Вернуться на ${cur_name:-прежний} вручную: vpn-toggle меню -> 9 (Сменить страну)."
            return 0
        fi
        tried="$tried $name"
    done

    # 3) Ни один резерв не встал — возвращаем ИСХОДНЫЙ конфиг (чтобы awg0 мониторил
    #    именно его) и остаёмся в прямом режиме: safety_off уже сделан в п.1,
    #    apply_routing/restore_vpn_dns НЕ зовём.
    printf "\n${RED}[failover FAIL]${NC} ни один резерв не поднялся (пробовал:%s)\n" "${tried:- нет}"
    bring_down
    if [ -f "$BACKUP_CONF" ]; then
        install_config "$BACKUP_CONF" "$cur_name"
        bring_up   # без ожидания handshake: VPS мёртв, нам нужен лишь awg0 для мониторинга
    fi
    notify_event "failover-fail" 3600 "BE7000: VPN упал, резервы недоступны — прямой режим" \
"Сервер ${cur_name:-?} не отвечает, и ни один резервный конфиг не поднялся
(пробовал:${tried:- нет}). Роутер в ПРЯМОМ режиме (safety_off): интернет и DNS
работают мимо VPN, сайты из списка недоступны.
awg0 поднят на ${cur_name:-исходном} — мониторинг продолжается: когда любой
сервер оживёт, VPN вернётся автоматически (watchdog повторит перебор резервов)."
    return 1
}

# ============================================================
# MAIN
# ============================================================
case "$1" in
    ""|list|ls)
        list_configs
        echo ""
        printf "Использование: %s <имя_конфига>\n" "$0"
        printf "Пример:        %s germany\n" "$0"
        printf "Откат:         %s rollback\n" "$0"
        printf "Текущий:       %s status\n" "$0"
        ;;
    status)
        show_status
        ;;
    rollback)
        acquire_lock
        rollback
        ;;
    safety-off|safety_off)
        # Точка входа для awg-watchdog.sh: аварийный fail-open БЕЗ перебора
        # серверов — снять привязку к дохлому awg0 и пустить трафик/DNS
        # напрямую. Туннель НЕ опускаем: handshake продолжит мониториться,
        # и watchdog вернёт VPN, когда VPS оживёт.
        safety_off
        ;;
    failover)
        # Точка входа для awg-watchdog.sh (режимы sticky/home) и ручного запуска:
        # перебрать резервы и встать на первый рабочий. Код возврата (0=встали на
        # резерв / 1=прямой режим) watchdog читает, чтобы выставить своё состояние.
        do_failover
        ;;
    *)
        switch_to "$1"
        ;;
esac
