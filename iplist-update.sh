#!/bin/sh
# iplist-update.sh — скачивает CIDR с iplist.opencck.org и заливает в ipset iplist_set.
# Запускается из cron раз в сутки (с --notify) + из awg-heal.sh после ребута.
#
# Источник НАСТРАИВАЕТСЯ опциональным $AWG_DIR/iplist.conf (нет файла → весь
# cidr4 с opencck, как было). Можно сузить до конкретных сайтов (IPLIST_SITES)
# или задать свой URL (IPLIST_URL) — см. iplist.conf.example.
#
# КАСТОМНЫЙ ЛОКАЛЬНЫЙ СПИСОК (IPLIST_CUSTOM_MODE, ортогонален источнику скачивания):
#   only  — НЕ качаем вообще, set наполняется ТОЛЬКО из $IPLIST_CUSTOM_FILE (офлайн);
#   merge — качаем как обычно, потом доклеиваем $IPLIST_CUSTOM_FILE поверх;
#   пусто — кастома нет (поведение как раньше). Файл (CIDR/IP построчно) лежит на
#   /data → переживает ребут; на ПК заливается через be7000 (Источник списка IP).
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
#   IPLIST_BASE        — база для режима сайтов (по умолчанию opencck cidr4);
#   IPLIST_MIN_LINES   — порог «подозрительно мало строк» (деф. 10; снизь при узком списке);
#   IPLIST_CUSTOM_MODE — only|merge|'' — кастомный локальный список (ортогонален источнику);
#   IPLIST_CUSTOM_FILE — путь к файлу кастомного списка (деф. $AWG_DIR/iplist.custom).
IPLIST_BASE='https://iplist.opencck.org/?format=text&data=cidr4'
IPLIST_URL=''
IPLIST_SITES=''
IPLIST_MIN_LINES=10
IPLIST_CUSTOM_MODE=''                        # only|merge|'' — кастомный локальный список (ортогонален источнику скачивания)
IPLIST_CUSTOM_FILE="$AWG_DIR/iplist.custom"  # файл кастомного списка (CIDR/IP построчно), переживает ребут
[ -f "$AWG_DIR/iplist.conf" ] && . "$AWG_DIR/iplist.conf"
case "$IPLIST_MIN_LINES" in ''|*[!0-9]*) IPLIST_MIN_LINES=10 ;; esac   # защита от мусора в конфиге
case "$IPLIST_CUSTOM_MODE" in only|merge) ;; *) IPLIST_CUSTOM_MODE='' ;; esac   # только эти два режима, иначе off
[ -n "$IPLIST_CUSTOM_FILE" ] || IPLIST_CUSTOM_FILE="$AWG_DIR/iplist.custom"

if [ -n "$IPLIST_URL" ]; then
    URL="$IPLIST_URL"
elif [ -n "$IPLIST_SITES" ]; then
    URL="$IPLIST_BASE"
    for s in $IPLIST_SITES; do URL="$URL&site=$s"; done
else
    URL="$IPLIST_BASE"
fi

# Залить CIDR-список из ОДНОГО ИЛИ НЕСКОЛЬКИХ файлов в боевой ipset атомарно
# (через временный _new). Единый код для скачанного списка, кастомного файла
# (merge: оба сразу) и fallback-снимка.
# СТРАХОВКА: swap делаем ТОЛЬКО если в _new реально легло >0 записей — иначе
# кривой/пустой источник (формат не распознан, ipset отбросил всё) молча обнулил
# бы боевой set и увёл CDN-подсети мимо VPN. Возвращает 0 (swap сделан) / 1 (set не тронут).
load_set_from_files() {
    ipset list -n 2>/dev/null | grep -qx "$SET" || \
        ipset create "$SET" hash:net hashsize 4096 maxelem 1000000
    ipset destroy "${SET}_new" 2>/dev/null
    ipset create "${SET}_new" hash:net hashsize 4096 maxelem 1000000
    for f in "$@"; do
        [ -f "$f" ] || continue
        while IFS= read -r cidr; do
            case "$cidr" in
                ''|'#'*) continue ;;
            esac
            ipset add "${SET}_new" "$cidr" 2>/dev/null
        done < "$f"
    done
    n=$(ipset list "${SET}_new" 2>/dev/null | awk '/^Number of entries:/{print $NF}')
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    if [ "$n" -eq 0 ]; then
        echo "load: 0 валидных записей из [$*] — боевой set НЕ тронут"
        ipset destroy "${SET}_new" 2>/dev/null
        return 1
    fi
    ipset swap "${SET}_new" "$SET"
    ipset destroy "${SET}_new"
    echo "load: $n записей из [$*]"
    return 0
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
echo "custom mode: ${IPLIST_CUSTOM_MODE:-off} (file: $IPLIST_CUSTOM_FILE)"

# 1+2. Наполнение боевого ipset. Боевой set трогаем ТОЛЬКО валидным набором
#      (>0 записей, см. load_set_from_files), поэтому сбой/кривой источник не
#      рушит маршрутизацию.
USED_FALLBACK=0
LINES=0
SRC_DESC="$URL"   # описание источника для письма-сводки

if [ "$IPLIST_CUSTOM_MODE" = only ]; then
    # ----- only: интернет НЕ трогаем, наполняем ТОЛЬКО из локального файла -----
    SRC_DESC="локальный файл $IPLIST_CUSTOM_FILE (режим only)"
    echo "source: $SRC_DESC"
    if [ -s "$IPLIST_CUSTOM_FILE" ]; then
        LINES=$(wc -l < "$IPLIST_CUSTOM_FILE")
        load_set_from_files "$IPLIST_CUSTOM_FILE" || \
            mail_event iplist-fail 0 "BE7000: кастомный список без валидных подсетей" \
"Режим 'only' (только локальный файл), но $IPLIST_CUSTOM_FILE не дал ни одной
валидной подсети. Маршрутизация оставлена на ПРОШЛОМ списке iplist_set."
    else
        echo "only-mode: нет/пуст $IPLIST_CUSTOM_FILE"
        mail_event iplist-fail 0 "BE7000: кастомный список отсутствует" \
"Режим 'only', но файла $IPLIST_CUSTOM_FILE нет или он пуст. Залей список через
be7000 (Источник списка IP -> Кастомный локальный файл). Боевой set не тронут."
    fi
else
    # ----- скачиваем (как раньше); merge доклеит локальный файл поверх -----
    echo "source: $URL"
    DOWNLOAD_OK=0
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

    HAVE_CUSTOM=0
    [ "$IPLIST_CUSTOM_MODE" = merge ] && [ -s "$IPLIST_CUSTOM_FILE" ] && HAVE_CUSTOM=1

    if [ "$DOWNLOAD_OK" = 1 ]; then
        # Удачно. merge → скачанное + локальный файл; иначе только скачанное.
        if [ "$HAVE_CUSTOM" = 1 ]; then
            SRC_DESC="$URL + локальный файл $IPLIST_CUSTOM_FILE (режим merge)"
            load_set_from_files "$TMP" "$IPLIST_CUSTOM_FILE"
        else
            load_set_from_files "$TMP"
        fi
        cp "$TMP" "$SNAP_FILE" 2>/dev/null   # снимок = ТОЛЬКО скачанная часть (на boot домержим custom)
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
        elif [ -s "$SNAP_FILE" ] || [ "$HAVE_CUSTOM" = 1 ]; then
            # set пуст (типично после ребута при мёртвом источнике) — поднимаем из
            # снимка (+ локальный файл в merge). Custom — встроенная страховка на boot.
            if [ "$HAVE_CUSTOM" = 1 ]; then
                echo "set empty — loading fallback (snapshot + custom)"
                load_set_from_files "$SNAP_FILE" "$IPLIST_CUSTOM_FILE"
            else
                echo "set empty — loading fallback snapshot $SNAP_FILE"
                load_set_from_files "$SNAP_FILE"
            fi
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
"Источник: $SRC_DESC." \
"Строк с источника: $LINES." \
"" \
"VPN: $vpn_state." \
"Активный конфиг: ${active:-?}." \
"Внешний IP сейчас: ${ip:-неизвестен}.")
    subj="BE7000: список IP обновлён — $COUNT подсетей"
    [ "$USED_FALLBACK" = 1 ] && subj="BE7000: список IP поднят из снимка — $COUNT подсетей"
    mail_event iplist-digest 0 "$subj" "$BODY"
fi

echo "done"
