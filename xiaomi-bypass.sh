#!/bin/sh
# xiaomi-bypass.sh — выводит трафик роутера к Xiaomi cloud МИМО AmneziaWG.
#
# Проблема: Mi Home модуль BE7000 ("настройки сети") показывает "роутер не
# в сети" / "ошибка подключения". Причина: китайские IPs Xiaomi cloud
# (Alibaba CN, China Unicom, Kingsoft) попали в iplist_set (autoupdated из
# iplist.opencck.org — список подсетей сервисов). Демоны на роутере
# (xq_info_sync_mqtt, messagingagent) пытаются обратиться к Xiaomi через
# awg0 → cloud видит европейский VPN-IP → отказ.
#
# Решение: резолвим Xiaomi cloud-домены, кладём их IPs в ipset xiaomi_bypass,
# подцепляем правило ACCEPT в VPN_EXCLUDE chain (он висит в PREROUTING и
# OUTPUT первым) — пакеты к этим IPs не получают fwmark и идут через main
# роутинг (= провайдер).
#
# Запускается:
#   * из cron раз в 6 часов (DNS может меняться)
#   * из awg-heal.sh после boot (TODO добавить вручную)
#   * вручную: sh /data/usr/app/awg/xiaomi-bypass.sh

EXCLUDE_CHAIN="VPN_EXCLUDE"
BYPASS_SET="xiaomi_bypass"
LOG=/tmp/xiaomi-bypass.log

# Домены Xiaomi cloud. Если Mi Home ругается на что-то ещё — добавь сюда.
DOMAINS="
api.io.mi.com
ru.api.io.mi.com
de.api.io.mi.com
i2.api.io.mi.com
business.smartcamera.api.io.mi.com
tracker.api.xiaomi.com
api.miwifi.com
router.miwifi.com
api.io.miwifi.com
ott.io.mi.com
resolver.msg.xiaomi.net
"

exec >>"$LOG" 2>&1
echo "===== $(date) ====="

# 1. Создать ipset (если нет)
ipset list -n 2>/dev/null | grep -qx "$BYPASS_SET" || \
    ipset create "$BYPASS_SET" hash:net hashsize 256 maxelem 1024

# 2. Заполнить временный ipset
ipset destroy "${BYPASS_SET}_new" 2>/dev/null
ipset create "${BYPASS_SET}_new" hash:net hashsize 256 maxelem 1024

ADDED=0
for d in $DOMAINS; do
    nslookup "$d" 2>/dev/null | awk '/^Address.*: [0-9]/{print $NF}' | grep -v '^127\.' | while read ip; do
        ipset add "${BYPASS_SET}_new" "$ip" 2>/dev/null && echo "  $d -> $ip"
    done
done

# 3. Атомарный swap
ipset swap "${BYPASS_SET}_new" "$BYPASS_SET" 2>/dev/null
ipset destroy "${BYPASS_SET}_new" 2>/dev/null

COUNT=$(ipset list "$BYPASS_SET" | awk '/^Number of entries:/{print $NF}')
echo "ipset $BYPASS_SET: $COUNT entries"

# 4. Убедиться что VPN_EXCLUDE существует и подцеплен ПЕРВЫМ в PREROUTING/OUTPUT
iptables -t mangle -L "$EXCLUDE_CHAIN" -n >/dev/null 2>&1 || \
    iptables -t mangle -N "$EXCLUDE_CHAIN"
for hook in PREROUTING OUTPUT; do
    iptables -t mangle -C "$hook" -j "$EXCLUDE_CHAIN" 2>/dev/null || {
        iptables -t mangle -I "$hook" 1 -j "$EXCLUDE_CHAIN"
        echo "hooked $EXCLUDE_CHAIN in $hook"
    }
done

# 5. Идемпотентно добавить правило bypass-set ACCEPT (один раз)
iptables -t mangle -C "$EXCLUDE_CHAIN" -m set --match-set "$BYPASS_SET" dst -j ACCEPT 2>/dev/null || {
    iptables -t mangle -A "$EXCLUDE_CHAIN" -m set --match-set "$BYPASS_SET" dst -j ACCEPT
    echo "bypass rule added"
}

# 6. Сбросить conntrack-записи к bypass-IPs — иначе Qualcomm NSS/ECM
# продолжит держать старый offload через VPN. Новые пакеты пойдут через
# свежие маршруты.
N=0
ipset list "$BYPASS_SET" | awk '/^[0-9]+\./{print $1}' | while read ip; do
    conntrack -D --dst "$ip" 2>/dev/null
done >/dev/null 2>&1

echo "done"
