#!/bin/sh
# notify-event.sh — единая точка отправки СОБЫТИЙНЫХ писем с BE7000.
#
# Зачем отдельно от notify.sh:
#   notify.sh — «тупой» транспорт (ведёт SMTP-диалог и всё). А поводов для
#   письма стало много: критические сбои switch-vpn, не поднявшийся после
#   ребута туннель, утренняя сводка iplist. Если звать notify.sh из каждого
#   места напрямую — получим (а) СПАМ (cron повторяет один и тот же сбой
#   каждый тик) и (б) дублирование проверки .notify-off в каждом скрипте.
#   Эта обёртка решает оба: throttle по ключу + единый выключатель.
#
# Использование:
#   notify-event.sh <key> <throttle_sec> "Тема" "Текст"
#     key          — идентификатор класса события ([a-z0-9_-]); по нему
#                    ведётся throttle и пишется отметка времени.
#     throttle_sec — не слать письмо с тем же key чаще раза в N секунд.
#                    0 = без ограничения (для редких событий: сводка раз в
#                    сутки, разовое письмо о загрузке — там throttle не нужен).
#
# Известные ключи (класс события → кто шлёт):
#   boot-ok / boot-fail                — awg-heal.sh (после загрузки/ребута)
#   switch-rollback / switch-failopen  — switch-vpn.sh (ручная смена страны)
#   failover-ok / failover-fail        — switch-vpn.sh failover (авто-перебор резервов)
#   iplist-digest / iplist-fail        — iplist-update.sh (утренняя сводка / сбой)
#
# throttle-отметки лежат в /tmp (сбрасываются при ребуте — после загрузки
# первое письмо любого класса пройдёт сразу, это желаемо: ребут = повод
# узнать актуальное состояние). .notify-off глушит всё разом, как у watchdog.
#
# ВАЖНО (грабли DNS): письмо об упавшем VPN уйдёт только если DNS уже
# переведён на публичный (safety_off). smtp.yandex.ru идёт мимо туннеля
# по маршруту, НО резолвится через dnsmasq → upstream внутри туннеля.
# switch-vpn зовёт notify-event ПОСЛЕ safety_off (DNS уже на 1.1.1.1) —
# там письмо уйдёт. А «boot-fail» из awg-heal может не уйти, пока watchdog
# (≤2 мин) не сделает safety_off — он же продублирует своим письмом.

AWG_DIR=/data/usr/app/awg
NOTIFY="$AWG_DIR/notify.sh"
NOTIFY_OFF="$AWG_DIR/.notify-off"
LOG=/tmp/notify-event.log

KEY="$1"
THROTTLE="$2"
SUBJECT="$3"
BODY="$4"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"; }

# Глобальный выключатель (как в awg-watchdog.sh)
if [ -f "$NOTIFY_OFF" ]; then
    log "notify-event: .notify-off — пропуск '$SUBJECT' (key=$KEY)"
    exit 0
fi

# notify.sh может быть ещё не залит / не исполняемым — не падаем
[ -x "$NOTIFY" ] || { log "notify-event: нет $NOTIFY — пропуск '$SUBJECT'"; exit 0; }

# Санитизируем ключ для имени файла-отметки (только безопасные символы)
safe_key=$(printf '%s' "$KEY" | tr -c 'a-zA-Z0-9_-' '_')
STAMP="/tmp/notify-event.$safe_key.stamp"

# Throttle: если с прошлой УСПЕШНОЙ отправки этого ключа прошло меньше
# THROTTLE сек — молчим. busybox date +%s есть; отметка — содержимое файла.
now=$(date +%s)
case "$THROTTLE" in ''|*[!0-9]*) THROTTLE=0 ;; esac
if [ "$THROTTLE" -gt 0 ] && [ -f "$STAMP" ]; then
    last=$(cat "$STAMP" 2>/dev/null)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ "$last" -gt 0 ] && [ "$((now - last))" -lt "$THROTTLE" ]; then
        log "notify-event: throttle ($((now - last))с < ${THROTTLE}с) — пропуск '$SUBJECT' (key=$safe_key)"
        exit 0
    fi
fi

# Отправляем. Отметку времени ставим ТОЛЬКО при успехе notify.sh, чтобы
# временный сбой отправки (DNS/SMTP) не «съел» throttle-окно и письмо
# повторилось при следующем событии того же класса.
# (notify.sh выходит 0 и когда почта не настроена — это считаем «успехом»:
#  слать нечего, throttle просто не даст спамить логом.)
if "$NOTIFY" "$SUBJECT" "$BODY" >>"$LOG" 2>&1; then
    echo "$now" > "$STAMP"
    log "notify-event: отправлено '$SUBJECT' (key=$safe_key)"
    exit 0
else
    log "notify-event: notify.sh НЕ подтвердил отправку '$SUBJECT' (key=$safe_key) — повтор при след. событии"
    exit 1
fi
