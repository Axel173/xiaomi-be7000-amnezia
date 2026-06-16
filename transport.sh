#!/bin/sh
# transport.sh — ОРКЕСТРАТОР транспортов VPN (тонкий слой НАД плагинами transport-*).
#
# ИДЕЯ (чистая плагинная модель, чтобы добавлять транспорты дёшево — xray, hysteria2, …):
#   * Плагин транспорта (transport-awg.sh / xray-transport.sh / …) несёт ОДИН контракт
#     up|down|health|failover|status и отвечает ТОЛЬКО за СВОЮ несущую:
#       up   — взять default в table 1000 (+ FORWARD/MASQUERADE/DNS своей схемы);
#       down — ЧИСТО отпустить несущую -> fail-open в прямой (НЕ решает, что поднять следом!).
#   * Что поднять следующим (cross awg<->xray<->…) решает ЭТОТ оркестратор, а НЕ плагин.
#   * Маркировка (mark-core: ipset->MARK + ip rule fwmark->table) — ОБЩАЯ, держим отдельно.
#
# РЕЕСТР транспортов — $REGISTRY (порядок = приоритет для cross-перебора). Добавить
# hysteria2 = одна строка в $REGISTRY + ветки в plugin_for()/transport_ready(). Всё
# остальное (меню, heal, watchdog) пойдёт через этот оркестратор без правок.
#
# БЕЗОПАСНОСТЬ: всё на ip rule fwmark -> table 1000. Любой down/смерть несущей = fail-open
# в main (прямой), не блэкхол. Оркестратор НЕ трогает awg0-интерфейс при switch (тёплый
# резерв сохраняется — down плагина снимает лишь маршрутизацию, не интерфейс).
#
# Команды:
#   transport.sh active            — текущий активный транспорт (.transport)
#   transport.sh list              — установленные/готовые транспорты (по реестру)
#   transport.sh next <name>       — следующий ГОТОВЫЙ транспорт != <name> (для cross)
#   transport.sh up [<name>]       — поднять несущую <name> (деф. active) поверх mark-core
#   transport.sh down [<name>]     — отпустить несущую <name> (деф. active) -> fail-open в прямой
#   transport.sh switch <name>     — отпустить текущую несущую, поднять <name>, записать .transport
#   transport.sh health [<name>]   — здоровье несущей (деф. active): 0 здоров / 1 нет
#   transport.sh failover [<name>] — перебор резервов ВНУТРИ транспорта (деф. active)

AWG_DIR=/data/usr/app/awg
TRANSPORT_FLAG="$AWG_DIR/.transport"
MARK_CORE="$AWG_DIR/mark-core.sh"

# Реестр: порядок приоритета и cross-перебора. Порядок = приоритет cross («awg» как
# надёжная база первой). xray и hy2 на флеше взаимоисключающи (см. transport_ready).
REGISTRY="awg xray hy2"

# Имя транспорта -> путь плагина (явная карта: имена файлов исторически разные —
# transport-awg.sh, но xray-transport.sh; сводим тут, без переименований).
plugin_for() {
    case "$1" in
        awg)  echo "$AWG_DIR/transport-awg.sh" ;;
        xray) echo "$AWG_DIR/xray-transport.sh" ;;
        hy2)  echo "$AWG_DIR/transport-hy2.sh" ;;
        *)    echo "" ;;
    esac
}

# Готов ли транспорт к подъёму: плагин установлен + есть его секрет-конфиг.
transport_ready() {
    p=$(plugin_for "$1"); [ -n "$p" ] && [ -x "$p" ] || return 1
    case "$1" in
        # awg — БАЗА, но на hy2/xray-only установке awg-бинарей НЕТ, а awg.conf мог
        # появиться позже (залили конфиг страны через меню «Серверы AmneziaWG»).
        # Требуем И конфиг, И ОБА бинаря: amneziawg-go (ДЕМОН несущей awg0) И awg (CLI
        # amneziawg-tools — им awg_setup.sh делает `awg setconf awg0`, без него awg0 НЕ
        # встаёт). Раньше проверяли лишь amneziawg-go: при половинной установке (демон
        # докачался, а awg-CLI пропал/не докачался — реальный кейс из proto-install)
        # list/switch/next считали awg «готовым», и switch awg РОНЯЛ рабочую несущую
        # (down xray → up awg → awg0 не встаёт → fail-open без восстановления).
        awg)  [ -f "$AWG_DIR/awg.conf" ] && [ -x "$AWG_DIR/amneziawg-go" ] && [ -x "$AWG_DIR/awg" ] ;;
        # Для альтов требуем И секрет-конфиг, И бинарь: на тесном /data живёт лишь ОДИН
        # альт (xray ЛИБО hysteria), поэтому next()/list() не должны предлагать транспорт,
        # чей бинарь не установлен, даже если осиротевший конфиг остался лежать на флеше.
        xray) [ -s "$AWG_DIR/xray.json" ]     && [ -x "$AWG_DIR/xray" ] ;;
        hy2)  [ -s "$AWG_DIR/hysteria.yaml" ] && [ -x "$AWG_DIR/hysteria" ] ;;
        *)    return 1 ;;
    esac
}

active() { cat "$TRANSPORT_FLAG" 2>/dev/null | tr -d ' \r\n'; }
apply_marking() { [ -x "$MARK_CORE" ] && "$MARK_CORE" >/dev/null 2>&1; }

cmd_list() { for t in $REGISTRY; do transport_ready "$t" && echo "$t"; done; }

# Следующий готовый транспорт, отличный от $1 (первый по реестру). Код 1 — нет другого.
cmd_next() {
    for t in $REGISTRY; do
        [ "$t" = "$1" ] && continue
        transport_ready "$t" && { echo "$t"; return 0; }
    done
    return 1
}

# Поднять несущую транспорта поверх общего ядра (mark-core). Деф. — активный.
cmd_up() {
    t="${1:-$(active)}"; [ -n "$t" ] || t=awg
    p=$(plugin_for "$t"); [ -x "$p" ] || { echo "[transport] нет плагина для '$t'"; return 1; }
    apply_marking
    "$p" up
}

# Переключить активный транспорт: отпустить текущую несущую (плагин down — чистый
# релинквиш), поднять несущую нового. .transport пишем здесь (единая точка истины).
# awg0-интерфейс при этом НЕ опускается (тёплый резерв; down снимает лишь маршрутизацию).
cmd_switch() {
    new="$1"
    transport_ready "$new" || { echo "[transport] '$new' не готов (нет плагина/конфига)"; return 1; }
    cur=$(active)
    if [ -n "$cur" ] && [ "$cur" != "$new" ]; then
        cp=$(plugin_for "$cur"); [ -x "$cp" ] && "$cp" down
    fi
    apply_marking            # гарантируем ядро (на случай прихода из safety_off, где маркировка снята)
    echo "$new" > "$TRANSPORT_FLAG"
    np=$(plugin_for "$new"); [ -x "$np" ] && "$np" up
}

# Отпустить несущую транспорта (плагин down — ЧИСТЫЙ релинквиш -> fail-open в прямой).
# НЕ решает, что поднять следом, и НЕ переписывает .transport (это забота switch/вызывающего:
# напр. watchdog зовёт down при уходе в прямой режим, оставляя .transport прежним для boot/heal).
cmd_down()     { t="${1:-$(active)}"; p=$(plugin_for "$t"); [ -x "$p" ] && "$p" down; }
cmd_health()   { t="${1:-$(active)}"; p=$(plugin_for "$t"); [ -x "$p" ] && "$p" health; }
cmd_failover() { t="${1:-$(active)}"; p=$(plugin_for "$t"); [ -x "$p" ] && "$p" failover; }

case "$1" in
    active)   active; echo ;;
    list)     cmd_list ;;
    next)     cmd_next "$2" ;;
    up)       cmd_up "$2" ;;
    down)     cmd_down "$2" ;;
    switch)   cmd_switch "$2" ;;
    health)   cmd_health "$2" ;;
    failover) cmd_failover "$2" ;;
    *) echo "usage: $0 active|list|next <t>|up [t]|down [t]|switch <t>|health [t]|failover [t]"; exit 2 ;;
esac
