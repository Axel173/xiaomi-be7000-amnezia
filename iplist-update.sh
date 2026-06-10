#!/bin/sh
# iplist-update.sh — скачивает CIDR с iplist.opencck.org и заливает в ipset iplist_set.
# Запускается из cron раз в сутки (с --notify) + из awg-heal.sh после ребута.
#
# Источник НАСТРАИВАЕТСЯ опциональным $AWG_DIR/iplist.conf (нет файла → весь
# cidr4 с opencck, как было). Можно сузить до конкретных сайтов (IPLIST_SITES)
# или задать свой URL (IPLIST_URL) — см. iplist.conf.example.
#
# УСТОЙЧИВОСТЬ к недоступности источника (важно для крона в 5:00 и для boot):
# боевой ipset трогаем ТОЛЬКО после удачного скачивания (атомарный swap), поэтому
# сбой источника НЕ рушит маршрутизацию. set наполнен → остаётся прошлый список;
# set пуст (типично после РЕБУТА при мёртвом источнике) → поднимаем из локального
# снимка .iplist.snapshot (обновляется при каждом удачном скачивании). Роутер и
# интернет при недоступности источника не страдают.
#
# Флаг --notify — слать на почту итог запуска (утренняя сводка: сколько CIDR,
# дельта к прошлому разу, краткий статус VPN; либо письмо о провале закачки).
# Cron (5:00) зовёт С флагом; awg-heal зовёт БЕЗ — при каждом ребуте сводка не
# нужна, о загрузке heal шлёт своё письмо. Письма идут через notify-event.sh
# (он уважает .notify-off и throttle; здесь throttle 0 — события и так редкие).

AWG_DIR=/data/usr/app/awg
SET=iplist_set
TMP=/tmp/iplist.txt
LOG=/tmp/iplist-update.log
NOTIFY_EVENT="$AWG_DIR/notify-event.sh"
COUNT_FILE="$AWG_DIR/.iplist.count"   # прошлое число подсетей (для дельты; переживает ребут)
SNAP_FILE="$AWG_DIR/.iplist.snapshot" # последний удачно скачанный список — fallback на boot при мёртвом источнике (переживает ребут)

# --- Источник списка: настраивается опциональным $AWG_DIR/iplist.conf ----------
# Файл на /data → переживает ребут. Нет файла → дефолт (весь cidr4 с opencck),
# поведение как раньше. Переменные (все опциональны, см. iplist.conf.example):
#   IPLIST_URL       — полный URL, используется как есть (escape hatch / др. источник);
#   IPLIST_SITES     — список сайтов через пробел → собирается &site=... к IPLIST_BASE
#                      (игнорируется, если задан IPLIST_URL);
#   IPLIST_BASE      — база для режима сайтов (по умолчанию opencck cidr4);
#   IPLIST_MIN_LINES — порог «подозрительно мало строк» (деф. 10; снизь при узком списке).
IPLIST_BASE='https://iplist.opencck.org/?format=text&data=cidr4'
IPLIST_URL=''
IPLIST_SITES=''
IPLIST_MIN_LINES=10
[ -f "$AWG_DIR/iplist.conf" ] && . "$AWG_DIR/iplist.conf"
case "$IPLIST_MIN_LINES" in ''|*[!0-9]*) IPLIST_MIN_LINES=10 ;; esac   # защита от мусора в конфиге

if [ -n "$IPLIST_URL" ]; then
    URL="$IPLIST_URL"
elif [ -n "$IPLIST_SITES" ]; then
    URL="$IPLIST_BASE"
    for s in $IPLIST_SITES; do URL="$URL&site=$s"; done
else
    URL="$IPLIST_BASE"
fi

# Залить CIDR-список из файла в боевой ipset атомарно (через временный _new).
# Единый код для свежескачанного списка и для fallback-снимка.
load_set_from_file() {
    ipset list -n 2>/dev/null | grep -qx "$SET" || \
        ipset create "$SET" hash:net hashsize 4096 maxelem 1000000
    ipset destroy "${SET}_new" 2>/dev/null
    ipset create "${SET}_new" hash:net hashsize 4096 maxelem 1000000
    while IFS= read -r cidr; do
        case "$cidr" in
            ''|'#'*) continue ;;
        esac
        ipset add "${SET}_new" "$cidr" 2>/dev/null
    done < "$1"
    ipset swap "${SET}_new" "$SET"
    ipset destroy "${SET}_new"
}

# Флаг уведомлений
NOTIFY=0
[ "$1" = "--notify" ] && NOTIFY=1

# Письмо (только при --notify и наличии обёртки)
mail_event() {
    [ "$NOTIFY" = 1 ] && [ -x "$NOTIFY_EVENT" ] && "$NOTIFY_EVENT" "$1" "$2" "$3" "$4" >/dev/null 2>&1
}

exec >>"$LOG" 2>&1
echo "===== $(date) (notify=$NOTIFY) ====="
echo "source: $URL"

# 1. Скачать во временный файл. Боевой ipset НЕ трогаем, пока скачанное не
#    признано валидным, — поэтому сбой источника не рушит маршрутизацию.
DOWNLOAD_OK=0
LINES=0
if curl -s --max-time 120 "$URL" -o "$TMP"; then
    LINES=$(wc -l < "$TMP")
    echo "downloaded: $LINES lines"
    if [ "$LINES" -ge "$IPLIST_MIN_LINES" ]; then
        DOWNLOAD_OK=1
    else
        echo "suspicious size ($LINES < $IPLIST_MIN_LINES) — reject"
    fi
else
    echo "download failed"
fi

# 2. Развилка по результату скачивания.
USED_FALLBACK=0
if [ "$DOWNLOAD_OK" = 1 ]; then
    # Удачно: атомарно заливаем в боевой set и обновляем снимок для будущих ребутов.
    load_set_from_file "$TMP"
    cp "$TMP" "$SNAP_FILE" 2>/dev/null
else
    # Сбой источника. Решаем по состоянию боевого set:
    CUR=$(ipset list "$SET" 2>/dev/null | awk '/^Number of entries:/{print $NF}')
    case "$CUR" in ''|*[!0-9]*) CUR=0 ;; esac
    if [ "$CUR" -gt 0 ]; then
        # set наполнен (обычный суточный апдейт при мёртвом источнике) — НЕ трогаем.
        echo "keep existing set ($CUR entries)"
        mail_event iplist-fail 0 "BE7000: НЕ обновился список IP" \
"Не удалось обновить список IP-подсетей.
Источник: $URL
Маршрутизация работает на ПРОШЛОМ списке ($CUR подсетей) — ничего не
сломалось, новых подсетей не добавилось. Если повторяется несколько
дней — проверь доступность источника."
        exit 1
    elif [ -s "$SNAP_FILE" ]; then
        # set пуст (типично после ребута при мёртвом источнике) — поднимаем из снимка.
        echo "set empty — loading fallback snapshot $SNAP_FILE"
        load_set_from_file "$SNAP_FILE"
        USED_FALLBACK=1
    else
        # set пуст и снимка нет — сделать нечего, оставляем пустым (как было до фолбэка).
        echo "set empty and no snapshot — nothing to load"
        mail_event iplist-fail 0 "BE7000: список IP пуст" \
"Источник недоступен, локального снимка ещё нет — ipset iplist_set пуст.
Источник: $URL
Рунет и домены (awg_list) работают, но CDN-подсети из CIDR временно НЕ
заворачиваются в VPN. Наполнится при следующем удачном обновлении
(ближайший ребут или 5:00)."
        exit 1
    fi
fi

COUNT=$(ipset list "$SET" | awk '/^Number of entries:/{print $NF}')
case "$COUNT" in ''|*[!0-9]*) COUNT=0 ;; esac
echo "ipset $SET: $COUNT entries (fallback=$USED_FALLBACK)"

# 4. Правило маркировки (идемпотентно — добавляем если нет)
if ! iptables -t mangle -C PREROUTING -m set --match-set "$SET" dst -j MARK --set-mark 0x1 2>/dev/null; then
    iptables -t mangle -A PREROUTING -m set --match-set "$SET" dst -j MARK --set-mark 0x1
    echo "mangle rule added for $SET"
fi

# 5. Дельта к прошлому разу (для сводки) + сохранение текущего значения.
#    COUNT_FILE в $AWG_DIR (не /tmp) — переживает ребут, иначе дельта терялась бы.
#    При fallback из снимка дельту и COUNT_FILE НЕ трогаем — это не «обновление»,
#    иначе дельта следующего удачного запуска сравнивалась бы со снимком.
if [ "$USED_FALLBACK" = 1 ]; then
    delta="из локального снимка"
else
    PREV=$(cat "$COUNT_FILE" 2>/dev/null)
    case "$PREV" in ''|*[!0-9]*) PREV="" ;; esac
    echo "$COUNT" > "$COUNT_FILE"
    if [ -n "$PREV" ]; then
        d=$((COUNT - PREV))
        if   [ "$d" -gt 0 ]; then delta="было $PREV, +$d"
        elif [ "$d" -lt 0 ]; then delta="было $PREV, $d"
        else                      delta="без изменений"; fi
    else
        delta="первое измерение"
    fi
fi
echo "delta: $delta"

# 6. Утренняя сводка на почту (только при --notify). Собираем краткий
#    статус VPN — curl/awg дёргаем лишь здесь, чтобы вызов из awg-heal был лёгким.
if [ "$NOTIFY" = 1 ]; then
    WG=""
    command -v wg >/dev/null 2>&1 && WG=wg
    [ -z "$WG" ] && [ -x "$AWG_DIR/awg" ] && WG="$AWG_DIR/awg"
    vpn_state="awg0 не поднят"
    if ip link show awg0 >/dev/null 2>&1; then
        vpn_state="awg0 up"
        if [ -n "$WG" ]; then
            hs=$($WG show awg0 latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
            case "$hs" in ''|*[!0-9]*) hs=0 ;; esac
            if [ "$hs" -gt 0 ]; then
                vpn_state="awg0 up, handshake $(( $(date +%s) - hs )) сек назад"
            else
                vpn_state="awg0 up, handshake ещё нет"
            fi
        fi
    fi
    active=$(cat "$AWG_DIR/.active" 2>/dev/null)
    ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null)
    BODY=$(printf '%s\n' \
"Утреннее обновление списка IP-подсетей." \
"" \
"Подсетей в iplist_set: $COUNT ($delta)." \
"Скачано строк с источника: $LINES." \
"" \
"VPN: $vpn_state." \
"Активный конфиг: ${active:-?}." \
"Внешний IP сейчас: ${ip:-неизвестен}.")
    subj="BE7000: список IP обновлён — $COUNT подсетей"
    [ "$USED_FALLBACK" = 1 ] && subj="BE7000: список IP поднят из снимка — $COUNT подсетей"
    mail_event iplist-digest 0 "$subj" "$BODY"
fi

echo "done"
