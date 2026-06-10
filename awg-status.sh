#!/bin/sh
#
# awg-status.sh v3 — диагностический отчёт по AWG-туннелю.
#
# v3 (май 2026):
#   * "Версия протокола" теперь учитывает РЕАЛЬНОЕ состояние:
#     - пробует $AWG_DIR/amneziawg-go --version и awg --version
#     - если AWG 2.0 в конфиге И handshake идёт → бинарь умеет 2.0, зелёный
#     - предупреждение только если 2.0 в конфиге, а handshake нет
#   * показывает ОБА ipset — awg_list (домены) и iplist_set (CIDR)
#   * cron + awg-heal.sh — главный механизм автозапуска, rc.local инфо

AWG_DIR="/data/usr/app/awg"
AWG_LIST_NAME="awg_list"
IPLIST_NAME="iplist_set"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

WG=""
if command -v wg >/dev/null 2>&1; then WG=wg
elif [ -x "$AWG_DIR/awg" ]; then WG="$AWG_DIR/awg"
fi

header() { echo ""; printf "${BOLD}${BLUE}══════ %s ══════${NC}\n" "$1"; }
status() {
    label="$1"; value="$2"; color="${3:-$GREEN}"
    printf "  %-30s ${color}%s${NC}\n" "$label" "$value"
}
num() {
    case "$1" in
        ''|*[!0-9]*) echo 0 ;;
        *)           echo "$1" ;;
    esac
}

detect_awg_version() {
    conf="$AWG_DIR/awg.conf"
    [ ! -f "$conf" ] && { echo "?"; return; }
    if   grep -qE "^S3\s*=" "$conf" || grep -qE "^S4\s*=" "$conf"; then echo "2.0"
    elif grep -qE "^H[1-4]\s*=\s*[0-9]+-[0-9]+" "$conf";          then echo "2.0"
    elif grep -qE "^I1\s*=" "$conf";                              then echo "1.5"
    elif grep -qE "^(Jc|S1|H1)\s*=" "$conf";                      then echo "1.0 (Legacy)"
    else echo "обычный WireGuard"
    fi
}

# Попытка получить версию бинарника amneziawg-go / awg
detect_binary_version() {
    for cand in "$AWG_DIR/amneziawg-go" "$AWG_DIR/awg" amneziawg-go wg; do
        if [ -x "$cand" ] || command -v "$cand" >/dev/null 2>&1; then
            v=$("$cand" --version 2>&1 | head -1 | tr -d '\r' | head -c 80)
            # Принимаем только если есть цифры (отфильтровываем usage/error)
            case "$v" in
                *[0-9]*) echo "$v"; return ;;
            esac
        fi
    done
    # Fallback: дата файла бинарника
    if [ -f "$AWG_DIR/amneziawg-go" ]; then
        d=$(date -r "$AWG_DIR/amneziawg-go" "+%Y-%m-%d" 2>/dev/null)
        [ -n "$d" ] && echo "amneziawg-go от $d"
    fi
}

# ==================== 1. ИНТЕРФЕЙС AWG0 ====================
header "Интерфейс awg0"
if ip link show awg0 >/dev/null 2>&1; then
    status "Состояние:" "поднят" "$GREEN"
    awg_ip=$(ip -4 addr show awg0 | awk '/inet / {print $2}' | head -1)
    status "Внутренний IP:" "$awg_ip"

    # --- Handshake (нужен ПЕРЕД проверкой версии — даёт ground truth) ---
    hs_ago=-1
    if [ -n "$WG" ]; then
        hs=$(num "$($WG show awg0 latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')")
        if [ "$hs" -gt 0 ]; then
            hs_ago=$(( $(date +%s) - hs ))
        fi
    fi

    # --- Версия протокола + версия бинарника ---
    awg_ver=$(detect_awg_version)
    bin_ver=$(detect_binary_version)

    case "$awg_ver" in
        "2.0")
            # AWG 2.0 в конфиге. Главный признак "бинарь свежий" — есть handshake.
            if [ "$hs_ago" -ge 0 ] && [ "$hs_ago" -lt 600 ]; then
                status "Версия протокола:" "AWG 2.0 — работает (handshake идёт)" "$GREEN"
            elif [ "$hs_ago" -ge 0 ]; then
                status "Версия протокола:" "AWG 2.0 — handshake давний, проверь VPS" "$YELLOW"
            else
                status "Версия протокола:" "AWG 2.0 — handshake нет, возможно бинарь старый" "$YELLOW"
            fi
            ;;
        "1.5")    status "Версия протокола:" "AWG 1.5 — поддерживается" "$GREEN" ;;
        "1.0"*)   status "Версия протокола:" "AWG 1.0 (Legacy) — стабильно работает" "$GREEN" ;;
        *)        status "Версия протокола:" "$awg_ver" "$YELLOW" ;;
    esac
    [ -n "$bin_ver" ] && status "Бинарь:" "$bin_ver" "$BLUE"

    [ -f "$AWG_DIR/.active" ] && status "Активный конфиг:" "$(cat "$AWG_DIR/.active")"
    endpoint=$(grep -E "^Endpoint" "$AWG_DIR/awg.conf" 2>/dev/null | head -1 | awk -F'= *' '{print $2}')
    [ -n "$endpoint" ] && status "Endpoint VPS:" "$endpoint"

    # --- Handshake вывод ---
    if [ "$hs_ago" -ge 0 ]; then
        if   [ "$hs_ago" -lt 180 ]; then status "Последний handshake:" "$hs_ago сек назад" "$GREEN"
        elif [ "$hs_ago" -lt 600 ]; then status "Последний handshake:" "$hs_ago сек назад (давно)" "$YELLOW"
        else                             status "Последний handshake:" "$hs_ago сек назад — СТАРЫЙ" "$RED"
        fi
    elif [ -n "$WG" ]; then
        status "Последний handshake:" "никогда — VPS не отвечает!" "$RED"
    else
        status "Бинарь wg/awg:" "не найден" "$YELLOW"
    fi

    if [ -n "$WG" ]; then
        xfer=$($WG show awg0 transfer 2>/dev/null | awk 'NR==1{print $2" "$3}')
        rx=$(num "$(echo "$xfer" | awk '{print $1}')")
        tx=$(num "$(echo "$xfer" | awk '{print $2}')")
        if [ "$rx" -gt 0 ] || [ "$tx" -gt 0 ]; then
            status "Принято/передано:" "$((rx/1024/1024)) MB / $((tx/1024/1024)) MB"
        fi
    fi
else
    status "Состояние:" "НЕ ПОДНЯТ" "$RED"
fi

# ==================== 2. IPSET awg_list (домены) ====================
header "ipset $AWG_LIST_NAME — IP резолвленных доменов"
if ipset list -n 2>/dev/null | grep -qx "$AWG_LIST_NAME"; then
    cnt=$(num "$(ipset list "$AWG_LIST_NAME" 2>/dev/null | awk '/^Number of entries:/{print $NF}')")
    if [ "$cnt" -gt 0 ]; then
        status "Состояние:" "наполнен" "$GREEN"
        status "IP-адресов:" "$cnt"
    else
        status "Состояние:" "пустой (ОК если CIDR-список наполнен)" "$YELLOW"
        status "IP-адресов:" "0"
    fi
else
    status "Состояние:" "НЕ СОЗДАН" "$RED"
fi

# ==================== 3. IPSET iplist_set (CIDR от opencck) ====================
header "ipset $IPLIST_NAME — подсети CIDR от iplist.opencck.org"
if ipset list -n 2>/dev/null | grep -qx "$IPLIST_NAME"; then
    cnt=$(num "$(ipset list "$IPLIST_NAME" 2>/dev/null | awk '/^Number of entries:/{print $NF}')")
    if   [ "$cnt" -gt 100 ]; then status "Состояние:" "наполнен" "$GREEN";          status "CIDR-подсетей:" "$cnt"
    elif [ "$cnt" -gt 0 ];   then status "Состояние:" "подозрительно мало" "$YELLOW"; status "CIDR-подсетей:" "$cnt"
    else                          status "Состояние:" "пустой — запусти iplist-update.sh" "$RED"
    fi
    if [ -f /tmp/iplist-update.log ]; then
        last=$(grep -E "^=====" /tmp/iplist-update.log | tail -1 | sed 's/===== //; s/ =====//')
        [ -n "$last" ] && status "Обновлён:" "$last"
    fi
else
    status "Состояние:" "НЕ СОЗДАН — запусти iplist-update.sh" "$RED"
fi

# ==================== 4. ВНЕШНИЕ IP ====================
header "Тест: куда идёт трафик"
ip_direct=$(curl -s --max-time 4 https://api.ipify.org 2>/dev/null)
if [ -n "$ip_direct" ]; then
    status "Прямой IP (без VPN):" "$ip_direct"
else
    status "Прямой IP (без VPN):" "недоступен (api.ipify.org не ответил)" "$YELLOW"
fi
if ip link show awg0 >/dev/null 2>&1; then
    ip_vpn=$(curl -s --interface awg0 --max-time 5 https://api.ipify.org 2>/dev/null)
    if [ -n "$ip_vpn" ]; then
        if [ -n "$ip_direct" ] && [ "$ip_direct" = "$ip_vpn" ]; then
            status "IP через VPN:" "$ip_vpn — СОВПАДАЕТ С ПРЯМЫМ!" "$RED"
        else
            status "IP через VPN:" "$ip_vpn" "$GREEN"
        fi
    else
        status "IP через VPN:" "недоступен" "$RED"
    fi
fi

# ==================== 5. ПРАВИЛА ====================
header "Правила маршрутизации"
fwmark_rules=$(ip rule 2>/dev/null | grep -c "fwmark 0x1")
status "ip rule с fwmark 0x1:" "$fwmark_rules шт."
mangle_awg=$(iptables -t mangle -L PREROUTING -v -n 2>/dev/null | grep -c "match-set $AWG_LIST_NAME")
mangle_ipl=$(iptables -t mangle -L PREROUTING -v -n 2>/dev/null | grep -c "match-set $IPLIST_NAME")
mangle_total=$((mangle_awg + mangle_ipl))
if [ "$mangle_total" -ge 2 ]; then
    status "iptables-метки PREROUTING:" "$mangle_awg ($AWG_LIST_NAME) + $mangle_ipl ($IPLIST_NAME)" "$GREEN"
else
    status "iptables-метки PREROUTING:" "$mangle_awg ($AWG_LIST_NAME) + $mangle_ipl ($IPLIST_NAME)" "$YELLOW"
fi
nat_rules=$(iptables -t nat -L POSTROUTING -v -n 2>/dev/null | grep -c "MASQUERADE.*awg0")
status "MASQUERADE на awg0:" "$nat_rules шт."

# ==================== 6. СПИСКИ ДОМЕНОВ ====================
header "Списки доменов (dnsmasq)"
if [ -f /etc/dnsmasq.d/awg-domains.conf ]; then
    main_count=$(num "$(grep -c '^ipset=' /etc/dnsmasq.d/awg-domains.conf 2>/dev/null)")
    main_size=$(du -h /etc/dnsmasq.d/awg-domains.conf 2>/dev/null | awk '{print $1}')
    main_age=$(date -r /etc/dnsmasq.d/awg-domains.conf "+%Y-%m-%d %H:%M" 2>/dev/null || echo "?")
    status "re-filter (опционально):" "$main_count правил, $main_size"
    status "  обновлён:" "$main_age"
else
    status "re-filter (опционально):" "нет — используется iplist+custom" "$BLUE"
fi
if [ -f /etc/dnsmasq.d/awg-custom.conf ]; then
    cust=$(num "$(grep -c '^ipset=' /etc/dnsmasq.d/awg-custom.conf 2>/dev/null)")
    status "Твои добавления:" "$cust доменов"
fi

# ==================== 7. ТЕСТ КОНКРЕТНЫХ САЙТОВ ====================
if [ "$1" = "test" ]; then
    header "Проверка популярных сайтов"
    for domain in youtube.com chatgpt.com claude.ai instagram.com discord.com github.com; do
        ip_first=$(nslookup "$domain" 127.0.0.1 2>/dev/null | grep -A1 'Name:' | tail -1 | awk '{print $NF}')
        if [ -n "$ip_first" ]; then
            in_awg=0; in_ipl=0
            ipset test "$AWG_LIST_NAME" "$ip_first" 2>/dev/null && in_awg=1
            ipset test "$IPLIST_NAME"   "$ip_first" 2>/dev/null && in_ipl=1
            if [ "$in_awg" = "1" ] || [ "$in_ipl" = "1" ]; then
                tag=""
                [ "$in_awg" = "1" ] && tag="${tag}awg_list "
                [ "$in_ipl" = "1" ] && tag="${tag}iplist_set"
                status "$domain:" "ЧЕРЕЗ VPN ($ip_first, $tag)" "$GREEN"
            else
                status "$domain:" "НАПРЯМУЮ ($ip_first)" "$YELLOW"
            fi
        fi
    done
fi

# ==================== 8. АВТОЗАПУСК ====================
header "Автозапуск (главное — cron)"
if grep -q "awg-heal.sh" /etc/crontabs/root 2>/dev/null; then
    heal_line=$(grep "awg-heal.sh" /etc/crontabs/root | head -1 | awk '{print $1,$2,$3,$4,$5}')
    status "cron awg-heal:" "включён ($heal_line)" "$GREEN"
else
    status "cron awg-heal:" "ОТСУТСТВУЕТ — после ребута всё развалится!" "$RED"
fi
if grep -q "iplist-update" /etc/crontabs/root 2>/dev/null; then
    upd_line=$(grep "iplist-update" /etc/crontabs/root | head -1 | awk '{print $1,$2,$3,$4,$5}')
    status "cron iplist-update:" "включён ($upd_line)" "$GREEN"
else
    status "cron iplist-update:" "выключен — CIDR не обновляются" "$YELLOW"
fi
if grep -q "AWG-SETUP-BE7000" /etc/rc.local 2>/dev/null; then
    status "rc.local:" "блок есть (бонус)" "$GREEN"
else
    status "rc.local:" "пусто (норм, на BE7000 сбрасывается)" "$BLUE"
fi

# ==================== 9. РЕСУРСЫ РОУТЕРА ====================
# Зачем здесь: при установке и после полезно видеть, что VPN/скрипты не съедают
# память. ВАЖНО: все наши логи лежат в /tmp, а /tmp на BE7000 — это tmpfs (RAM),
# поэтому раздутый лог = съеденная RAM (до ребута; ребут /tmp чистит).
# RAM берём из /proc/meminfo — его формат стабилен на любом busybox, в отличие
# от `free` (у разных версий разный вывод). df считаем устойчиво к переносу
# длинного имени устройства на отдельную строку: числа всегда в ПОСЛЕДНЕЙ строке,
# поэтому адресуем поля от конца ($(NF-2)=Avail, $(NF-4)=Size, $(NF-1)=Use%).
header "Ресурсы роутера"
mt=$(num "$(awk '/^MemTotal:/{print $2}'     /proc/meminfo 2>/dev/null)")
mf=$(num "$(awk '/^MemFree:/{print $2}'      /proc/meminfo 2>/dev/null)")
ma=$(num "$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)")
if [ "$mt" -gt 0 ]; then
    # старое ядро без MemAvailable → как оценку «доступно» берём MemFree
    if [ "$ma" -gt 0 ]; then avail_mb=$((ma/1024)); else avail_mb=$((mf/1024)); fi
    txt="$((mf/1024)) МБ свободно из $((mt/1024)) МБ"
    [ "$ma" -gt 0 ] && txt="$txt (доступно $((ma/1024)) МБ)"
    if   [ "$avail_mb" -lt 30 ]; then status "RAM:" "$txt" "$RED"
    elif [ "$avail_mb" -lt 60 ]; then status "RAM:" "$txt" "$YELLOW"
    else                              status "RAM:" "$txt" "$GREEN"
    fi
fi
# Берём /data (ubifs, переживает ребут — туда ставится awg) и /tmp (tmpfs=RAM, логи).
# /overlay НЕ трогаем: на BE7000 такого монтирования НЕТ (корень — ro-squashfs, /etc —
# ramfs), и `df /overlay` свалился бы на squashfs-корень `/`, а он ВСЕГДА 100% по природе
# сжатого read-only образа — показывает мнимое «забито под завязку» и пугает зря.
for m in /data /tmp; do
    dline=$(df -h "$m" 2>/dev/null | tail -1 | awk 'NF>=5{printf "%s своб из %s (занято %s)", $(NF-2), $(NF-4), $(NF-1)}')
    [ -n "$dline" ] && status "Диск $m:" "$dline"
done
# Суммарный размер наших логов в /tmp (это tmpfs = RAM). ls -l: размер в поле $5.
logsz=$(ls -l /tmp/*.log 2>/dev/null | awk '{s+=$5} END{if (NR>0) printf "%d КБ в %d файл(ах)", (s+1023)/1024, NR}')
[ -n "$logsz" ] && status "Логи в /tmp:" "$logsz"

echo ""
printf "${BLUE}Совет:${NC} '${BOLD}awg-status.sh test${NC}' покажет, какие сайты идут через VPN.\n"
echo ""
