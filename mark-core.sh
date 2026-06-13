#!/bin/sh
# mark-core.sh — ТРАНСПОРТ-АГНОСТИЧНОЕ ядро PBR-маршрутизации.
#
# Часть плана «транспорт-агностичное ядро + плагины». Это бывшие
# ШАГИ 2-3 split-route.sh, вычищенные от всего, что привязано к КОНКРЕТНОЙ несущей:
# маркировка пакетов по ipset (mangle -m set -> MARK 0x1) + правило ip rule
# fwmark 0x1 -> table 1000. Больше НИЧЕГО.
#
# ПОЧЕМУ ОТДЕЛЬНО. Раньше split-route.sh мешал ядро и несущую в кучу и под set -e
# первой же строкой делал `ip route add default dev awg0` — без awg0 он аварийно
# падал, и маркировка (это ядро) не накладывалась ВООБЩЕ. Из-за этого нельзя было
# поднять VPN на одном лишь Xray (без awg). Теперь ядро не знает про несущую:
# `default dev <iface> table 1000` ставит активный transport-*.sh (awg0 / xtun / ...).
#
# ИДЕМПОТЕНТНО, БЕЗ set -e: сетов может ещё не быть (ipset живёт в RAM, на boot
# пуст до наполнения) — тогда соответствующую маркировку просто пропускаем, как
# делал split-route. Падать на отсутствии одного из сетов нельзя.
#
# БЕЗОПАСНОСТЬ. Само по себе ядро НЕ направляет трафик в туннель — оно лишь МЕТИТ
# и заводит ip rule на table 1000. Пока активный транспорт не положит туда default,
# table 1000 пуста -> fwmark-трафик уходит в main -> НАПРЯМУЮ (fail-open).

FWMARK=0x1
TABLE=1000

# Маркируем пакеты к IP из ipset: awg_list — IP резолвленных доменов (dnsmasq),
# iplist_set — CIDR от opencck. Несущей это не касается — кто несёт (awg0/xtun),
# решает активный транспорт через default в table $TABLE.
for set in awg_list iplist_set; do
    if ipset list -n 2>/dev/null | grep -qx "$set"; then
        iptables -t mangle -D PREROUTING -m set --match-set "$set" dst -j MARK --set-mark $FWMARK 2>/dev/null || true
        iptables -t mangle -D OUTPUT     -m set --match-set "$set" dst -j MARK --set-mark $FWMARK 2>/dev/null || true
        iptables -t mangle -A PREROUTING -m set --match-set "$set" dst -j MARK --set-mark $FWMARK
        iptables -t mangle -A OUTPUT     -m set --match-set "$set" dst -j MARK --set-mark $FWMARK
    fi
done

# Помеченные пакеты — по таблице $TABLE (default в неё кладёт активный транспорт).
ip rule del fwmark $FWMARK table $TABLE 2>/dev/null || true
ip rule add fwmark $FWMARK table $TABLE pref 99

echo "[mark-core] маркировка применена (table $TABLE, fwmark $FWMARK; default ставит транспорт)"
