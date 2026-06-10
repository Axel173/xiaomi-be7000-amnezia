#!/bin/sh
# notify.sh — отправка уведомления на e-mail прямо с роутера BE7000.
#
# Зачем openssl, а не msmtp/curl:
#   - curl на стоке собран БЕЗ SMTP (`curl --version` → Protocols без smtp);
#   - msmtp/ssmtp/sendmail не установлены, а opkg-фиды (18.06-SNAPSHOT miwifi)
#     ненадёжны и тянутся из интернета;
#   - openssl-util + base64 уже есть в системе — поэтому SMTP-диалог ведём
#     руками через `openssl s_client`. Ничего ставить не нужно.
#
# Зачем именно РОССИЙСКИЙ SMTP (Яндекс):
#   notify.sh зовётся из awg-watchdog.sh ИМЕННО когда VPN упал. Иностранные
#   каналы (Telegram, Gmail) у нас ходят ЧЕРЕЗ VPN и в этот момент недоступны.
#   smtp.yandex.ru идёт по default route через провайдера, МИМО awg0
#   (проверено: `ip route get 77.88.21.158` → via <gw> dev eth0). Значит
#   письмо уйдёт даже при мёртвом туннеле.
#
# Использование:
#   notify.sh "Тема письма" "Текст письма"
#
# Конфиг — notify.conf рядом со скриптом (chmod 600, НЕ в git). Если его нет
# или он не заполнен (пустой SMTP_PASS) — тихо выходим с кодом 0, чтобы
# watchdog не считал это ошибкой, пока почта ещё не настроена.

CONF="$(dirname "$0")/notify.conf"
LOG=/tmp/notify.log

SUBJECT="$1"
BODY="$2"

[ -f "$CONF" ] || { echo "$(date) notify: нет $CONF — пропуск" >>"$LOG"; exit 0; }
. "$CONF"

if [ -z "$SMTP_HOST" ] || [ -z "$SMTP_USER" ] || [ -z "$SMTP_PASS" ] || [ -z "$MAIL_TO" ]; then
    echo "$(date) notify: notify.conf не заполнен (нет SMTP_PASS?) — пропуск" >>"$LOG"
    exit 0
fi
SMTP_PORT="${SMTP_PORT:-465}"

# base64 для AUTH LOGIN (логин/пароль) и для MIME-кодирования темы (кириллица).
U_B64=$(printf '%s' "$SMTP_USER" | base64 | tr -d '\n')
P_B64=$(printf '%s' "$SMTP_PASS" | base64 | tr -d '\n')
SUBJ_B64=$(printf '%s' "$SUBJECT" | base64 | tr -d '\n')

DATE_HDR=$(date -R 2>/dev/null || date)

# timeout (если есть) — чтобы зависший SMTP не копил процессы в cron.
# busybox бывает с двумя синтаксисами: новый "timeout N CMD" и старый
# "timeout -t N CMD". Определяем рабочий, пробуя на безобидном `true`.
TMO=""
if command -v timeout >/dev/null 2>&1; then
    if timeout 2 true 2>/dev/null; then
        TMO="timeout 25"
    elif timeout -t 2 true 2>/dev/null; then
        TMO="timeout -t 25"
    fi
fi

# Резолвим SMTP-хост САМИ через ПУБЛИЧНЫЙ DNS и подключаемся по IP.
# Зачем: smtp.yandex.ru идёт МИМО туннеля по маршруту, но его ИМЯ резолвится
# через dnsmasq → upstream ВНУТРИ туннеля. Письмо шлётся как раз когда VPN
# мёртв — обычный резолв тогда падает, и письмо не уходит. nslookup к 1.1.1.1
# бьёт в обход dnsmasq. -servername ниже сохраняет правильный SNI при подключении
# по IP. Если резолв не удался (нет nslookup / DNS недоступен) — откатываемся на
# имя, т.е. поведение как раньше, ничего не теряя.
# (Остаётся узкий случай: VPN мёртв И mangle ещё включён — тогда 1.1.1.1 само
#  завёрнуто в туннель и резолв не пройдёт. Это сценарий awg-heal/boot-fail;
#  там письмо подстрахует watchdog, который сделает safety_off за ≤2 мин.)
SMTP_IP=""
case "$SMTP_HOST" in
    *[!0-9.]*)   # это имя, а не IPv4 — пробуем зарезолвить публичными DNS
        for dns in 1.1.1.1 8.8.8.8 9.9.9.9; do
            SMTP_IP=$(nslookup "$SMTP_HOST" "$dns" 2>/dev/null | awk -v d="$dns" '
                { for (i=1;i<=NF;i++)
                    if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $i != d) { print $i; exit } }')
            [ -n "$SMTP_IP" ] && break
        done
        ;;
    *) SMTP_IP="$SMTP_HOST" ;;   # SMTP_HOST уже IP
esac
if [ -n "$SMTP_IP" ]; then
    CONNECT="$SMTP_IP:$SMTP_PORT"
else
    CONNECT="$SMTP_HOST:$SMTP_PORT"   # fallback — как было
fi
echo "$(date) notify: connect=$CONNECT (host=$SMTP_HOST)" >>"$LOG"

# SMTP-диалог. sleep между шагами: AUTH LOGIN пошаговый (сервер ждёт логин,
# потом пароль), без пауз Яндекс иногда рвёт сессию. -crlf: openssl сам
# добавляет \r к каждой строке. -quiet: меньше служебного шума в выводе.
RESP=$(
{
    echo "EHLO router";            sleep 1
    echo "AUTH LOGIN";             sleep 1
    echo "$U_B64";                 sleep 1
    echo "$P_B64";                 sleep 1
    echo "MAIL FROM:<$SMTP_USER>"; sleep 1
    echo "RCPT TO:<$MAIL_TO>";     sleep 1
    echo "DATA";                   sleep 1
    echo "From: $SMTP_USER"
    echo "To: $MAIL_TO"
    echo "Subject: =?UTF-8?B?$SUBJ_B64?="
    echo "MIME-Version: 1.0"
    echo "Content-Type: text/plain; charset=UTF-8"
    echo "Content-Transfer-Encoding: 8bit"
    echo "Date: $DATE_HDR"
    echo ""
    printf '%s\n' "$BODY"
    echo ""
    echo "-- "
    echo "Поддержать: https://web.tribute.tg/d/LtA"
    echo "Другие способы: https://github.com/Axel173/xiaomi-be7000-amnezia#12-поддержать-автора"
    echo "."
    sleep 1
    echo "QUIT"
    sleep 1
} | $TMO openssl s_client -connect "$CONNECT" -servername "$SMTP_HOST" -crlf -quiet 2>&1
)

echo "$(date) notify: subj='$SUBJECT'" >>"$LOG"
echo "$RESP" >>"$LOG"

# Успех = аутентификация прошла (235) И сервер принял письмо после DATA
# (250 ... queued / 250 2.0.0 Ok).
if echo "$RESP" | grep -q "235" && echo "$RESP" | grep -qiE "250 2.0.0|queued|250 ok"; then
    exit 0
else
    echo "$(date) notify: ОТПРАВКА НЕ ПОДТВЕРЖДЕНА (детали выше)" >>"$LOG"
    exit 1
fi
