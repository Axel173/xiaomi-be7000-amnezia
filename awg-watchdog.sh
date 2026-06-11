#!/bin/sh
# awg-watchdog.sh — сторож VPN-туннеля на Xiaomi BE7000.
#
# Запускается из cron каждые 2 минуты. Следит за живостью awg0 по возрасту
# последнего handshake (при PersistentKeepalive=25 «старше 180 сек» = VPS
# реально не отвечает, без ложных срабатываний) и переключает режимы:
#
#   NORMAL  → FAILOPEN  (VPS умер): зовёт switch-vpn.sh safety-off —
#             снимает fwmark/mangle/MASQUERADE и переводит DNS на публичный,
#             трафик идёт напрямую через провайдера. Интернет НЕ пропадает
#             (в т.ч. DNS-резолвинг, который у нас завязан на туннель —
#             см. историю инцидента). Сайты из списка на это время
#             недоступны. Шлёт письмо через notify.sh.
#
#   FAILOPEN → NORMAL   (VPS ожил): возвращает VPN-роутинг (split-route.sh)
#             и DNS-upstream обратно в туннель. Шлёт письмо.
#
# АВТО-FAILOVER (июнь 2026). Детекцию падения НЕ меняем (те же HS_DEAD/HS_ALIVE);
# меняется лишь ДЕЙСТВИЕ при смерти VPS — по режиму из $AWG_DIR/.failover-mode:
#   off    — как раньше: safety-off + письмо «VPN упал».
#   sticky — (дефолт, нет файла → sticky) зовёт `switch-vpn.sh failover`: перебор
#            configs/*.conf по алфавиту, встаём на первый рабочий и остаёмся.
#   home   — то же, плюс когда «основной» (`.failover-home`) снова доступен —
#            возвращаемся на него (ALIVE-ветка, троттл FAILBACK_INTERVAL).
# Если резервов нет (один конфиг) — любой режим вырождается в классический
# safety-off, поэтому дефолт-ВКЛ безопасен. Перебор в FAILOPEN повторяется не
# чаще FAILOVER_RETRY (вдруг резерв ожил позже). Письма failover-ok/failover-fail
# шлёт сам switch-vpn; watchdog по коду возврата лишь выставляет STATE.
#
# Почему это решает инцидент «VPS отвалился → на ПК лёг даже рунет»:
#   DNS на роутере один на все сети и форвардится в туннель. Пока туннель
#   мёртв, не резолвится ничего. safety_off временно ставит публичный DNS —
#   рунет и весь остальной трафик продолжают работать.
#
# Состояние — в /tmp/awg-watchdog.state (NORMAL/FAILOPEN). Письмо уходит
# ТОЛЬКО на смену режима, а не каждый тик. /tmp сбрасывается при ребуте —
# после загрузки считаем NORMAL, и watchdog переоценит ситуацию заново.
#
# Уведомления можно выключить, создав файл .notify-off (см. notify()).
# Туннель watchdog НЕ поднимает сам — если awg0 вообще нет, это территория
# awg-heal.sh, мы просто выходим.

AWG_DIR=/data/usr/app/awg
STATE=/tmp/awg-watchdog.state
LOCK=/tmp/awg-watchdog.lock
SWITCH_LOCK=/tmp/awg-switching.lock
LOG=/tmp/awg-watchdog.log
NOTIFY="$AWG_DIR/notify.sh"
NOTIFY_OFF="$AWG_DIR/.notify-off"

# Пороги можно переопределить через окружение (для тюнинга и тестов):
#   HS_DEAD=10 sh awg-watchdog.sh   — заставит счесть VPS мёртвым
HS_DEAD=${HS_DEAD:-180}     # handshake старше этого (сек) => VPS не отвечает
HS_ALIVE=${HS_ALIVE:-120}   # handshake свежее этого (сек) => VPS жив (возврат)
                            # зазор 120..180 — гистерезис против «дребезга»

# --- Авто-failover на резервный конфиг (см. switch-vpn.sh failover) ---
ACTIVE_NAME="$AWG_DIR/.active"
CONFIGS_DIR="$AWG_DIR/configs"
SWITCH_VPN="$AWG_DIR/switch-vpn.sh"
FAILOVER_MODE_FILE="$AWG_DIR/.failover-mode"   # off|sticky|home; нет файла → sticky
FAILOVER_HOME_FILE="$AWG_DIR/.failover-home"   # имя «основного» конфига для home
FAILOVER_ESCALATE_FILE="$AWG_DIR/.failover-escalate"  # cross|direct; нет файла → cross
FAILOVER_STAMP=/tmp/awg-failover.stamp         # троттл повторного перебора в FAILOPEN
FAILBACK_STAMP=/tmp/awg-failback.stamp         # троттл попыток возврата на home
FAILOVER_RETRY=${FAILOVER_RETRY:-600}          # как часто (сек) повторять перебор в FAILOPEN
FAILBACK_INTERVAL=${FAILBACK_INTERVAL:-900}    # как часто (сек) пробовать возврат на home
# Защита от «хождения по кругу» awg<->xray: какие протоколы уже перебраны в ТЕКУЩЕМ
# эпизоде аварии. cross-эскалация не прыгает в протокол, который уже пробовали →
# терминал всегда safety_off, без флаппинга. Чистится, когда транспорт снова здоров.
FAILOVER_EPISODE=/tmp/awg-failover-episode
TRANSPORT_HOME_FILE="$AWG_DIR/.transport-home"  # awg|xray — предпочитаемый транспорт (ручной выбор в меню); пусто → авто-возврат транспорта выключен
XT="$AWG_DIR/xray-transport.sh"                 # транспорт-скрипт (cross-эскалация и home-возврат)
XSTATE=/tmp/awg-watchdog.xstate                 # состояние xray-мониторинга: HEALTHY/SUSPECT/FAILED

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"; }

notify() {
    # $1 — тема, $2 — текст. Молчим, если уведомления выключены флагом
    # или notify.sh недоступен. notify.sh сам тихо выйдет, если почта ещё
    # не настроена (пустой notify.conf), так что watchdog от этого не падает.
    if [ -f "$NOTIFY_OFF" ]; then
        log "notify выключен флагом .notify-off — письмо не отправлено: '$1'"
        return
    fi
    [ -x "$NOTIFY" ] && "$NOTIFY" "$1" "$2" >>"$LOG" 2>&1
}

ext_ip() { curl -s --max-time 5 https://api.ipify.org 2>/dev/null; }

# Режим failover: off|sticky|home. Нет файла/мусор → sticky (ВКЛ по умолчанию).
fo_mode() {
    m=$(cat "$FAILOVER_MODE_FILE" 2>/dev/null | tr -d ' \t\r\n')
    case "$m" in off|sticky|home) printf '%s' "$m" ;; *) printf 'sticky' ;; esac
}

# Эскалация при исчерпании серверов активного протокола: cross|direct. Нет файла →
# cross (макс. устойчивость). cross — перебрать другой протокол; direct — прямой режим.
fo_escalate() {
    e=$(cat "$FAILOVER_ESCALATE_FILE" 2>/dev/null | tr -d ' \t\r\n')
    case "$e" in cross|direct) printf '%s' "$e" ;; *) printf 'cross' ;; esac
}

# Эпизод-гард (анти-петля): помечаем перебранные протоколы; cross не лезет в уже
# пробованный. busybox-safe (grep -w есть).
episode_has() { [ -f "$FAILOVER_EPISODE" ] && grep -qw "$1" "$FAILOVER_EPISODE" 2>/dev/null; }
episode_add() { episode_has "$1" || echo "$1" >> "$FAILOVER_EPISODE"; }
episode_reset() { : > "$FAILOVER_EPISODE"; }

# Предпочитаемый («домашний») транспорт: awg|xray. ПУСТО (нет файла) → авто-возврат
# транспорта выключен (пишется только ручным выбором в меню be7000.ps1 — авто-cross
# его НЕ трогает, иначе «дом» уехал бы за аварийным переключением).
transport_home() { cat "$TRANSPORT_HOME_FILE" 2>/dev/null | tr -d ' \t\r\n'; }

# Пригоден ли xray для эскалации: скрипт есть + выбран активный конфиг (его JSON есть).
have_xray() {
    [ -x "$XT" ] || return 1
    xa=$(cat "$AWG_DIR/.xray-active" 2>/dev/null)
    [ -n "$xa" ] && [ -f "$AWG_DIR/xray-configs/$xa.json" ]
}

# Эскалация awg→xray (вариант A). Зовётся, когда awg-пул исчерпан и система уже в
# safety_off (прямой = SAFE-пол). Возвращает маркировку (safety_off её снял), поднимает
# xray, при нужде перебирает xray-пул. 0 — встали на xray; 1 — xray тоже мёртв (прямой).
# Анти-петля: не лезет в xray, если он уже пробован в этом эпизоде.
cross_awg_to_xray() {
    [ "$(fo_escalate)" = "cross" ] || return 1
    episode_has xray && return 1
    have_xray || return 1
    episode_add xray
    log "awg-пул исчерпан → cross: пробую Xray"
    [ -x "$AWG_DIR/split-route.sh" ] && sh "$AWG_DIR/split-route.sh" >>"$LOG" 2>&1   # safety_off снял fwmark/mangle — вернуть
    sh "$XT" up >>"$LOG" 2>&1
    if sh "$XT" health >/dev/null 2>&1 || sh "$XT" failover >>"$LOG" 2>&1; then
        echo NORMAL > "$STATE"; echo HEALTHY > "$XSTATE"
        ip=$(ext_ip)
        notify "BE7000: AmneziaWG упал -> перешли на Xray" \
"Все awg-серверы недоступны. Роутер автоматически переключился на Xray
(конфиг $(cat "$AWG_DIR/.xray-active" 2>/dev/null)). Внешний IP: ${ip:-неизвестен}.
Вернуться на AmneziaWG: be7000 меню -> Протокол."
        return 0
    fi
    sh "$XT" down >>"$LOG" 2>&1
    [ -x "$SWITCH_VPN" ] && sh "$SWITCH_VPN" safety-off >>"$LOG" 2>&1
    echo FAILOPEN > "$STATE"; echo FAILED > "$XSTATE"
    log "cross: Xray тоже недоступен → прямой режим"
    return 1
}

# Сколько резервных конфигов в configs/ (кроме активного). busybox-safe.
count_backups() {
    a=$(cat "$ACTIVE_NAME" 2>/dev/null)
    c=0
    for f in "$CONFIGS_DIR"/*.conf; do
        [ -f "$f" ] || continue
        [ "$(basename "$f" .conf)" = "$a" ] && continue
        c=$((c+1))
    done
    printf '%d' "$c"
}

# Возраст (сек) с момента записи stamp-файла; нет файла → большое число.
stamp_age() {
    if [ -f "$1" ]; then
        t=$(cat "$1" 2>/dev/null); case "$t" in ''|*[!0-9]*) t=0 ;; esac
        echo $(( $(date +%s) - t ))
    else
        echo 999999
    fi
}

# Запустить перебор резервов через switch-vpn.sh и выставить STATE по коду:
# 0 — встали на резерв (NORMAL); 1 — прямой режим (FAILOPEN). Письма шлёт switch-vpn.
run_failover() {
    date +%s > "$FAILOVER_STAMP"
    if sh "$SWITCH_VPN" failover >>"$LOG" 2>&1; then
        echo "NORMAL" > "$STATE"
        log "failover: встали на резерв ($(cat "$ACTIVE_NAME" 2>/dev/null))"
        return 0
    else
        echo "FAILOPEN" > "$STATE"
        log "failover: резервы недоступны → прямой режим"
        return 1
    fi
}

# Бинарь для чтения handshake
WG=""
command -v wg >/dev/null 2>&1 && WG=wg
[ -z "$WG" ] && [ -x "$AWG_DIR/awg" ] && WG="$AWG_DIR/awg"

# Не лезем во время ручного переключения страны (switch-vpn.sh держит лок)
[ -e "$SWITCH_LOCK" ] && exit 0

# Один экземпляр за раз
[ -e "$LOCK" ] && exit 0
: > "$LOCK"
trap 'rm -f "$LOCK"' EXIT INT TERM HUP

# Транспорт-aware. При .transport=xray awg-логику НЕ применяем (иначе watchdog зря
# гонял бы awg-failover, видя «старый» handshake awg0-резерва). Лестница на сбой xray
# (НЕ цикл — каждый протокол перебираем ≤1 раза за эпизод, терминал = safety_off):
#   off            → вернуться на AmneziaWG (как раньше).
#   sticky/home    → перебор xray-резервов (xray-transport.sh failover); исчерпан →
#                    по .failover-escalate: cross → AmneziaWG + перебор awg-резервов
#                    (анти-петля через episode-гард), direct → прямой режим.
# Анти-дребезг: первая осечка health = SUSPECT (без действий), реакция со 2-го тика.
# После фолбэка .transport=awg → следующий тик идёт обычной awg-веткой.
TRANSPORT=$(cat "$AWG_DIR/.transport" 2>/dev/null)
if [ "$TRANSPORT" = "xray" ] && [ -x "$XT" ]; then
    xcur=HEALTHY; [ -f "$XSTATE" ] && xcur=$(cat "$XSTATE")

    if sh "$XT" health >>"$LOG" 2>&1; then
        if [ "$xcur" != "HEALTHY" ]; then echo HEALTHY > "$XSTATE"; episode_reset; log "xray health: ок"; fi
        # A: домашний транспорт = awg, а мы на xray (после cross) → вернуться на awg,
        # когда awg0 снова жив (он держит handshake тёплым резервом). Только mode=home,
        # троттл FAILBACK_INTERVAL. transport_home пуст → не трогаем (юзер не задавал).
        if [ "$(fo_mode)" = "home" ] && [ "$(transport_home)" = "awg" ] \
           && [ "$(stamp_age "$FAILBACK_STAMP")" -ge "$FAILBACK_INTERVAL" ]; then
            ahs=$($WG show awg0 latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
            case "$ahs" in ''|*[!0-9]*) ahs=0 ;; esac
            if [ "$ahs" -gt 0 ] && [ $(( $(date +%s) - ahs )) -le "$HS_ALIVE" ]; then
                date +%s > "$FAILBACK_STAMP"
                log "home-transport: awg жив → возврат на AmneziaWG"
                sh "$XT" down >>"$LOG" 2>&1
            fi
        fi
        exit 0
    fi

    # Первая осечка → SUSPECT, без действий: ждём подтверждения на след. тике (≈2 мин;
    # зеркало гистерезиса awg-handshake, чтобы не флапать на разовой пробе). Это и
    # начало нового эпизода аварии — сбрасываем episode-гард.
    if [ "$xcur" = "HEALTHY" ]; then
        echo SUSPECT > "$XSTATE"; episode_reset
        log "xray health: осечка (жду подтверждения на следующем тике)"
        exit 0
    fi

    mode=$(fo_mode)
    episode_add xray
    log "xray health: подтверждённый сбой (режим=$mode)"

    if [ "$mode" = "off" ]; then
        log "xray режим=off → фолбэк на AmneziaWG"
        sh "$XT" down >>"$LOG" 2>&1
        echo FAILED > "$XSTATE"
        ip=$(ext_ip)
        notify "BE7000: Xray упал -> вернулись на AmneziaWG" \
"Xray не прошёл проверку здоровья (демон/туннель/проба egress).
Авто-failover выключен (режим off) — роутер вернулся на AmneziaWG (awg0).
Внешний IP сейчас: ${ip:-неизвестен}.
Снова включить Xray: be7000 меню -> Протокол."
        exit 0
    fi

    # sticky/home → перебор xray-резервов
    log "→ перебор xray-резервов"
    if sh "$XT" failover >>"$LOG" 2>&1; then
        echo HEALTHY > "$XSTATE"
        log "xray-failover: встали на резервный xray-сервер"
        exit 0
    fi

    # xray-пул исчерпан → эскалация
    esc=$(fo_escalate)
    if [ "$esc" = "cross" ] && ! episode_has awg; then
        episode_add awg
        log "xray-пул исчерпан → cross: переключаюсь на AmneziaWG"
        sh "$XT" down >>"$LOG" 2>&1   # down вернул awg0 на текущий (default) конфиг
        # Сначала проверим, ЖИВ ли текущий awg-сервер (awg0 держит handshake даже как
        # тёплый резерв). Жив → остаёмся на нём; НЕЗАЧЕМ звать do_failover, который
        # пропускает текущий по имени и зря ушёл бы на резерв, бросив рабочий default.
        ahs=$($WG show awg0 latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
        case "$ahs" in ''|*[!0-9]*) ahs=0 ;; esac
        if [ "$ahs" -gt 0 ] && [ $(( $(date +%s) - ahs )) -le "$HS_DEAD" ]; then
            echo "NORMAL" > "$STATE"; echo HEALTHY > "$XSTATE"
            log "cross: awg ($(cat "$ACTIVE_NAME" 2>/dev/null)) жив — остаёмся на нём"
        elif [ -x "$SWITCH_VPN" ] && sh "$SWITCH_VPN" failover >>"$LOG" 2>&1; then
            echo "NORMAL" > "$STATE"; echo HEALTHY > "$XSTATE"
            log "cross: текущий awg мёртв → встали на awg-резерв"
        else
            echo "FAILOPEN" > "$STATE"; echo FAILED > "$XSTATE"
            log "cross: awg-резервы тоже недоступны → прямой режим"
        fi
        exit 0
    fi

    # direct, либо cross но awg уже пробовали в этом эпизоде (анти-петля) → прямой режим
    log "xray-пул исчерпан → прямой режим (escalate=$esc)"
    sh "$XT" down >>"$LOG" 2>&1
    [ -x "$SWITCH_VPN" ] && sh "$SWITCH_VPN" safety-off >>"$LOG" 2>&1
    echo "FAILOPEN" > "$STATE"; echo FAILED > "$XSTATE"
    ip=$(ext_ip)
    notify "BE7000: Xray и резервы недоступны -> прямой режим" \
"Xray упал, и ни один xray-резерв не поднялся. Роутер в ПРЯМОМ режиме
(safety_off): интернет/DNS работают мимо VPN, сайты из списка недоступны.
Внешний IP сейчас: ${ip:-неизвестен}.
Вернуть Xray вручную: be7000 меню -> Протокол."
    exit 0
fi

# Нет awg0 или нет бинаря — не наша зона ответственности (см. awg-heal.sh)
ip link show awg0 >/dev/null 2>&1 || exit 0
[ -z "$WG" ] && exit 0

# Возраст последнего handshake
hs=$($WG show awg0 latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
case "$hs" in ''|*[!0-9]*) hs=0 ;; esac
now=$(date +%s)
if [ "$hs" -gt 0 ]; then age=$((now - hs)); else age=999999; fi

cur="NORMAL"
[ -f "$STATE" ] && cur=$(cat "$STATE")

if [ "$age" -ge "$HS_DEAD" ]; then
    # ===== VPS не отвечает =====
    mode=$(fo_mode)
    nbk=$(count_backups)
    if [ "$cur" != "FAILOPEN" ]; then
        # --- переход: VPS только что умер --- (новый эпизод аварии)
        episode_reset; episode_add awg; date +%s > "$FAILOVER_STAMP"
        if [ "$mode" != "off" ] && [ "$nbk" -ge 1 ] && [ -x "$SWITCH_VPN" ]; then
            # есть awg-резервы → перебор (письма шлёт switch-vpn); awg-пул исчерпан →
            # cross на Xray (вариант A), иначе остаёмся в прямом режиме.
            log "VPS МЁРТВ (handshake ${age}с) → failover (режим=$mode, резервов=$nbk)"
            run_failover || cross_awg_to_xray
        elif [ "$mode" != "off" ] && [ "$(fo_escalate)" = "cross" ] && have_xray; then
            # failover включён, awg-резервов нет → сразу cross на Xray (A)
            log "VPS МЁРТВ (handshake ${age}с), awg-резервов нет → cross на Xray"
            [ -x "$SWITCH_VPN" ] && sh "$SWITCH_VPN" safety-off >>"$LOG" 2>&1
            echo "FAILOPEN" > "$STATE"
            cross_awg_to_xray
        else
            # режим off, либо нет ни awg-резервов, ни xray — классический fail-open
            log "VPS МЁРТВ (handshake ${age}с) → прямой режим (режим=$mode, резервов=$nbk)"
            [ -x "$SWITCH_VPN" ] && sh "$SWITCH_VPN" safety-off >>"$LOG" 2>&1
            echo "FAILOPEN" > "$STATE"
            active=$(cat "$ACTIVE_NAME" 2>/dev/null)
            ip=$(ext_ip)
            notify "BE7000: VPN упал, прямой режим" \
"VPS не отвечает (последний handshake ${age} сек назад).
Конфиг: ${active:-?}.

Роутер перешёл в ПРЯМОЙ режим: интернет и DNS работают мимо VPN,
сайты из списка временно недоступны.
Внешний IP сейчас: ${ip:-неизвестен}.

Когда VPS снова заработает, VPN вернётся автоматически и придёт
второе письмо. Если VPS долго не оживает — проверь его или смени
страну: vpn-toggle меню → 9 (Сменить страну)."
        fi
    else
        # --- уже FAILOPEN: периодически (троттл) пробуем восстановиться заново ---
        # Каждый ретрай = свежая попытка ВСЕЙ лестницы (awg-пул + cross на xray):
        # сбрасываем эпизод-гард, вдруг что-то ожило. Без флаппинга — раз в FAILOVER_RETRY.
        if [ "$mode" != "off" ] && [ "$(stamp_age "$FAILOVER_STAMP")" -ge "$FAILOVER_RETRY" ]; then
            date +%s > "$FAILOVER_STAMP"; episode_reset; episode_add awg
            log "VPS всё ещё мёртв (${age}с), FAILOPEN → повторная попытка восстановления"
            if [ "$nbk" -ge 1 ] && [ -x "$SWITCH_VPN" ]; then
                run_failover || cross_awg_to_xray
            else
                cross_awg_to_xray
            fi
        else
            log "VPS всё ещё мёртв (${age}с), уже FAILOPEN — без изменений"
        fi
    fi
elif [ "$age" -le "$HS_ALIVE" ]; then
    # ===== VPS жив =====
    if [ "$cur" = "FAILOPEN" ]; then
        log "VPS ОЖИЛ (handshake ${age}с назад) → возврат VPN"
        # 1) маршрутизация обратно через awg0
        [ -x "$AWG_DIR/split-route.sh" ] && sh "$AWG_DIR/split-route.sh" >>"$LOG" 2>&1
        # 2) DNS-upstream обратно в туннель (как awg-heal/awg-setup)
        VPN_DNS=$(grep -E '^DNS\s*=' "$AWG_DIR/awg.conf" 2>/dev/null | head -1 | awk -F'= *' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')
        [ -z "$VPN_DNS" ] && VPN_DNS=172.29.172.254
        printf 'no-resolv\nserver=%s\n' "$VPN_DNS" > /etc/dnsmasq.d/00-upstream.conf
        ip route replace "$VPN_DNS/32" dev awg0 2>/dev/null
        /etc/init.d/dnsmasq restart >/dev/null 2>&1 || killall -HUP dnsmasq 2>/dev/null
        echo "NORMAL" > "$STATE"; episode_reset   # эпизод аварии закрыт
        ip=$(ext_ip)
        notify "BE7000: VPN восстановлен" \
"VPS снова отвечает (последний handshake ${age} сек назад).
Вернул VPN-роутинг и DNS через туннель.
Внешний IP: ${ip:-неизвестен}."
    else
        # ===== уже NORMAL: в режиме home пробуем вернуться на основной =====
        # После прошлого failover мы можем работать на РЕЗЕРВНОМ конфиге. Если
        # режим home и активный != основного — раз в FAILBACK_INTERVAL проверяем,
        # ожил ли основной: ping его Endpoint (НЕ срывая рабочий резерв), и при
        # успехе зовём switch-vpn <home> (он сам проверит handshake и при неудаче
        # откатится на текущий резерв). ICMP-проба — чтобы не дёргать рабочий
        # туннель впустую; если VPS блокирует ICMP, авто-возврат не сработает —
        # вернуться можно вручную (меню 9).
        if [ "$(fo_mode)" = "home" ] && [ "$(transport_home)" = "xray" ] && have_xray \
           && [ "$(stamp_age "$FAILBACK_STAMP")" -ge "$FAILBACK_INTERVAL" ]; then
            # ===== home-транспорт = xray, а мы на awg (после cross) → вернуться на xray =====
            # Reality-сервер НЕ отвечает на ICMP и неотличим по TCP (маскируется под HTTPS)
            # → «ожил ли он» надёжно проверяется ТОЛЬКО подъёмом xray + egress-пробой.
            # Делаем редко (FAILBACK_INTERVAL) и откатываемся на awg, если не встал. Это
            # opt-in (mode=home): краткая просадка раз в интервал, пока домашний xray мёртв.
            date +%s > "$FAILBACK_STAMP"
            log "home-transport: проба возврата на домашний Xray (подъём + egress-проба)"
            [ -x "$AWG_DIR/split-route.sh" ] && sh "$AWG_DIR/split-route.sh" >>"$LOG" 2>&1
            sh "$XT" up >>"$LOG" 2>&1
            if sh "$XT" health >/dev/null 2>&1; then
                echo HEALTHY > "$XSTATE"; log "home-transport: вернулись на Xray"
            else
                sh "$XT" down >>"$LOG" 2>&1; log "home-transport: xray ещё мёртв — остаёмся на awg"
            fi
        elif [ "$(fo_mode)" = "home" ]; then
            home=$(cat "$FAILOVER_HOME_FILE" 2>/dev/null)
            [ -z "$home" ] && home="default"
            active=$(cat "$ACTIVE_NAME" 2>/dev/null)
            if [ -n "$active" ] && [ "$active" != "$home" ] \
               && [ -f "$CONFIGS_DIR/$home.conf" ] && [ -x "$SWITCH_VPN" ] \
               && [ "$(stamp_age "$FAILBACK_STAMP")" -ge "$FAILBACK_INTERVAL" ]; then
                date +%s > "$FAILBACK_STAMP"
                ep=$(grep -E '^Endpoint' "$CONFIGS_DIR/$home.conf" 2>/dev/null | head -1 | awk -F'= *' '{print $2}' | sed 's/:[0-9]*$//' | tr -d ' ')
                if [ -n "$ep" ] && ping -c 1 -W 2 "$ep" >/dev/null 2>&1; then
                    log "home-failback: основной '$home' (endpoint $ep) ожил → возврат"
                    sh "$SWITCH_VPN" "$home" >>"$LOG" 2>&1
                else
                    log "home-failback: основной '$home' ещё недоступен — остаёмся на '$active'"
                fi
            fi
        fi
    fi
fi
# Зона ${HS_ALIVE}..${HS_DEAD} — гистерезис, режим не трогаем.
exit 0
