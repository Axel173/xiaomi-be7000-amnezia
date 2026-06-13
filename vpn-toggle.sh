#!/bin/sh
# vpn-toggle.sh — глобальное вкл/выкл VPN и исключение конкретных устройств.
#
# v2 (май 2026): cmd_on теперь идемпотентно восстанавливает ВСЕ правила
# (mangle PREROUTING + NAT MASQUERADE + FORWARD + ip rule), а не только
# ip rule. Это лечит ситуацию, когда fw3/firewall на роутере reload-ится
# (после изменений в веб-морде Xiaomi или ребута init.d/firewall) и сносит
# ВСЕ iptables-таблицы — awg-heal.sh при этом не помогает, потому что
# у него лок /tmp/awg-heal.lock один раз за boot.
# Дополнительно добавлена команда `repair` для явного восстановления
# правил без переключения VPN on/off.
#
# Использование:
#   vpn-toggle.sh status              — текущее состояние
#   vpn-toggle.sh off                 — выключить VPN для всех (трафик через провайдера)
#   vpn-toggle.sh on                  — включить + восстановить правила (идемпотентно)
#   vpn-toggle.sh repair              — только восстановить правила (mangle/NAT/FORWARD)
#   vpn-toggle.sh exclude 192.168.31.50  — выключить VPN для одного устройства
#   vpn-toggle.sh include 192.168.31.50  — вернуть устройство в VPN
#   vpn-toggle.sh excluded            — показать список исключённых IP

TABLE=1000
MARK=0x1
EXCLUDE_CHAIN_PRE="VPN_EXCLUDE"   # mangle PREROUTING исключения
AWG_LIST="awg_list"
IPLIST_SET="iplist_set"
HEAL_LOCK="/tmp/awg-heal.lock"
AWG_DIR="/data/usr/app/awg"        # для apply-bypass.sh (персист исключений)

# ВАЖНО про target ACCEPT (а НЕ RETURN) в user-chain VPN_EXCLUDE:
# Каскад в PREROUTING после ensure_chain выглядит так:
#   1) -j VPN_EXCLUDE
#   2) -m set --match-set awg_list dst -j MARK --set-mark 0x1
#   3) -m set --match-set iplist_set dst -j MARK --set-mark 0x1
# Если в VPN_EXCLUDE стоит `-j RETURN`, то после совпадения мы возвращаемся
# в PREROUTING на правило 2, и пакет ВСЁ РАВНО получает mark → идёт в VPN.
# Если стоит `-j ACCEPT`, в mangle table это останавливает обход всех
# оставшихся правил в этой таблице → mark не ставится → пакет идёт через
# main route (провайдер). Именно это и нужно для exclude.
# Не переписывай обратно на RETURN — оно молча сломает exclude.
#
# ВАЖНО про conntrack -D после exclude/include:
# На BE7000 активен Qualcomm NSS (ECM + PPE + SFE) — ускоритель пакетов.
# Он offload-ит установленные соединения через быстрый путь, минуя iptables.
# Если просто добавить правило в VPN_EXCLUDE, существующие соединения этого
# IP продолжат идти через VPN (ECM кэширует решение).
# Поэтому после изменения exclude-правил мы вызываем `conntrack -D --src $IP`
# — это удаляет conntrack-записи для IP, ECM получает уведомление и сбрасывает
# offload. Новые пакеты пойдут через iptables и увидят свежее правило.

ensure_chain() {
    iptables -t mangle -L "$EXCLUDE_CHAIN_PRE" -n >/dev/null 2>&1 || {
        iptables -t mangle -N "$EXCLUDE_CHAIN_PRE"
    }
    # Гарантируем, что наш chain вызывается ПЕРВЫМ в PREROUTING
    # (для трафика, идущего ЧЕРЕЗ роутер — LAN-клиенты → VPN-цели).
    iptables -t mangle -D PREROUTING -j "$EXCLUDE_CHAIN_PRE" 2>/dev/null
    iptables -t mangle -I PREROUTING 1 -j "$EXCLUDE_CHAIN_PRE"
    # И в OUTPUT (для трафика, который ГЕНЕРИРУЕТ сам роутер — daemons
    # типа xq_info_sync_mqtt / messagingagent, ходящие на Xiaomi cloud).
    # Без этого Mi Home модуль BE7000 ломается: router-cloud-tunnel идёт
    # через VPN → cloud видит "не родной" IP, отказ. См. xiaomi-bypass.sh.
    iptables -t mangle -D OUTPUT -j "$EXCLUDE_CHAIN_PRE" 2>/dev/null
    iptables -t mangle -I OUTPUT 1 -j "$EXCLUDE_CHAIN_PRE"
}

cmd_status() {
    if ip rule show | grep -q "fwmark $MARK"; then
        echo "VPN: ON (глобально)"
    else
        echo "VPN: OFF (глобально)"
    fi
    echo
    echo "awg0 интерфейс:"
    ip a show awg0 2>/dev/null | grep -E 'inet |state' | head -2
    echo
    echo "Исключённые IP (трафик идёт мимо VPN):"
    iptables -t mangle -L "$EXCLUDE_CHAIN_PRE" -n 2>/dev/null | awk '/ACCEPT/{print "  " $4}'
}

cmd_off() {
    ip rule del fwmark $MARK table $TABLE 2>/dev/null
    echo "VPN глобально ВЫКЛЮЧЕН. Трафик идёт через провайдера."
    echo "Не забудь: ipconfig /flushdns на клиентах."
}

# Идемпотентно восстановить ВСЕ правила, которые ставит awg-heal.sh
# (mangle PREROUTING + NAT POSTROUTING + FORWARD + route в таблицу 1000).
# Зачем: fw3/firewall на роутере иногда перезагружается (изменения в
# веб-морде Xiaomi, /etc/init.d/firewall restart) и сносит ВСЕ iptables-
# таблицы. awg-heal.sh при этом сам не восстановит — у него лок
# /tmp/awg-heal.lock один раз за boot, и cron каждый тик просто выходит.
cmd_repair() {
    if ! ip link show awg0 >/dev/null 2>&1; then
        echo "awg0 не поднят — сначала запусти awg-heal:"
        echo "  rm -f $HEAL_LOCK && sh /data/usr/app/awg/awg-heal.sh"
        return 1
    fi

    # 1. route default в таблице 1000 — туда уходят пакеты с fwmark 0x1
    ip route replace default dev awg0 table $TABLE 2>/dev/null

    # 2. ip rule fwmark → table 1000
    ip rule del fwmark $MARK table $TABLE 2>/dev/null
    ip rule add fwmark $MARK table $TABLE pref 99

    # 3. mangle PREROUTING: метим трафик к VPN-IP'шникам из обоих ipset
    for set in "$AWG_LIST" "$IPLIST_SET"; do
        if ipset list -n 2>/dev/null | grep -qx "$set"; then
            iptables -t mangle -C PREROUTING -m set --match-set "$set" dst -j MARK --set-mark $MARK 2>/dev/null || \
                iptables -t mangle -A PREROUTING -m set --match-set "$set" dst -j MARK --set-mark $MARK
        fi
    done

    # 4. NAT MASQUERADE на awg0
    iptables -t nat -C POSTROUTING -o awg0 -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -o awg0 -j MASQUERADE

    # 5. FORWARD ACCEPT (политика DROP на fw3 иначе режет LAN→awg0)
    iptables -C FORWARD -o awg0 -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -o awg0 -j ACCEPT
    iptables -C FORWARD -i awg0 -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i awg0 -j ACCEPT

    # 6. chain исключений (используется cmd_exclude/cmd_include)
    ensure_chain

    # 6.5. Восстанавливаем сами исключения «мимо VPN» из persistent-хранилища.
    # fw3-reload сносит iptables → ensure_chain выше создал VPN_EXCLUDE ПУСТОЙ;
    # без этого устройства/SSID/guest, выведенные напрямую, после repair снова
    # ушли бы в VPN. apply идемпотентен и трогает только прямой путь.
    [ -x "$AWG_DIR/apply-bypass.sh" ] && "$AWG_DIR/apply-bypass.sh" apply

    # 6.6. Активный транспорт. Шаги 1/5 выше вернули default table 1000 на awg0 и
    # FORWARD awg0 — если активен Xray, переигрываем его поверх (xray-transport.sh up
    # идемпотентен: демоны живы — не перезапускает, заново ставит default dev xtun +
    # FORWARD xtun + DNS). Без этого после fw3-reload xray-режим «сползал» бы на awg.
    repair_t=$(cat "$AWG_DIR/.transport" 2>/dev/null | tr -d ' \r\n')
    if [ -n "$repair_t" ] && [ "$repair_t" != "awg" ] && [ -x "$AWG_DIR/transport.sh" ]; then
        "$AWG_DIR/transport.sh" up "$repair_t"
    fi

    # 7. снимаем лок awg-heal — если он висит с прошлого boot и реально
    # что-то опять отвалится, cron-тик через минуту восстановит сам.
    rm -f "$HEAL_LOCK" 2>/dev/null

    echo "OK: правила восстановлены (mangle + NAT MASQUERADE + FORWARD + route)."
}

cmd_on() {
    cmd_repair || return 1
    echo "VPN глобально ВКЛЮЧЁН."
}

cmd_exclude() {
    IP=$1
    [ -z "$IP" ] && { echo "укажи IP: vpn-toggle.sh exclude 192.168.31.50"; exit 1; }
    ensure_chain
    iptables -t mangle -C "$EXCLUDE_CHAIN_PRE" -s "$IP" -j ACCEPT 2>/dev/null && {
        echo "IP $IP уже исключён"; exit 0
    }
    iptables -t mangle -A "$EXCLUDE_CHAIN_PRE" -s "$IP" -j ACCEPT
    # NSS-offload может держать старые соединения через VPN — сбрасываем
    N=$(conntrack -D --src "$IP" 2>/dev/null | wc -l)
    # Зеркалим в persistent-хранилище, чтобы исключение пережило ребут/fw3-reload
    # (правило выше живёт только в iptables = RAM). add-ip идемпотентен.
    [ -x "$AWG_DIR/apply-bypass.sh" ] && "$AWG_DIR/apply-bypass.sh" add-ip "$IP" >/dev/null 2>&1
    echo "IP $IP исключён из VPN (трафик пойдёт напрямую). Сброшено conntrack-записей: $N"
    echo "Не забудь на устройстве: ipconfig /flushdns"
}

cmd_include() {
    IP=$1
    [ -z "$IP" ] && { echo "укажи IP: vpn-toggle.sh include 192.168.31.50"; exit 1; }
    if iptables -t mangle -D "$EXCLUDE_CHAIN_PRE" -s "$IP" -j ACCEPT 2>/dev/null; then
        N=$(conntrack -D --src "$IP" 2>/dev/null | wc -l)
        echo "IP $IP возвращён в VPN. Сброшено conntrack-записей: $N"
    else
        echo "IP $IP не был в исключениях."
    fi
    # Убираем из persistent-хранилища (чтобы не вернулся после ребута). Идемпотентно.
    [ -x "$AWG_DIR/apply-bypass.sh" ] && "$AWG_DIR/apply-bypass.sh" del-ip "$IP" >/dev/null 2>&1
}

cmd_excluded() {
    iptables -t mangle -L "$EXCLUDE_CHAIN_PRE" -n 2>/dev/null | awk '/ACCEPT/{print $4}'
}

case "$1" in
    status|"")    cmd_status ;;
    off)          cmd_off ;;
    on)           cmd_on ;;
    repair)       cmd_repair ;;
    exclude)      cmd_exclude "$2" ;;
    include)      cmd_include "$2" ;;
    excluded)     cmd_excluded ;;
    *)
        echo "Использование: $0 {status|on|off|repair|exclude IP|include IP|excluded}"
        exit 1
        ;;
esac
