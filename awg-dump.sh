#!/bin/sh
#
# awg-dump.sh — единый диагностический СРЕЗ (логи + состояние) одним текстовым
# потоком на stdout. Назначение: при «не работает / непонятно почему» снять
# «всё и сразу» и разобрать самому либо приложить к обращению в чат сообщества.
#
# Зеркало пункта 37 меню be7000.ps1: ПК гонит этот скрипт на роутер через
# 'base64 -d | sh' и складывает вывод в локальный файл be7000-diag-<дата>.txt
# (поэтому скрипт самодостаточен и не зависит от того, установлен ли он уже).
#
# БЕЗОПАСНОСТЬ (дамп задуман как ШАРИНГ-артефакт — он НЕ должен слить секреты):
#   1. НЕ читаем секретные файлы (awg.conf / configs/*.conf / awg0.conf /
#      amnezia_for_awg.conf / notify.conf) — только факт наличия + права (ls -l).
#      Раз приватный ключ не читаем — он физически не может попасть в дамп.
#      `awg show` приватный ключ не печатает (дизайн wireguard), но печатает
#      peer-pubkey/endpoint — их добивает redact() ниже.
#   2. Финальный фильтр redact() поверх ВСЕГО вывода:
#        * base64-ключи (43 символа + '=')  -> [KEY-REDACTED];
#        * endpoint-строки                  -> [REDACTED] (вдруг endpoint — хост);
#        * публичные IPv4 -> первые 2 октета + .x.x. Приватные/служебные
#          (10/172.16-31/192.168/127/169.254/0) ОСТАВЛЯЕМ — без них не разобрать
#          LAN и маршруты. Так не утекут endpoint/внешний IP VPS и домашний IP.
#   ВСЁ РАВНО просмотрите файл перед публикацией — маскировка эвристическая.
#
# Вывод — ЧИСТЫЙ текст без ANSI-цветов (артефакт идёт в файл/мессенджер).
# Все команды защищены (2>/dev/null / || echo) — на голом/недонастроенном
# роутере скрипт не падает, а честно показывает «нет / не поднят».

AWG_DIR="/data/usr/app/awg"

# --- редактор секретов: ключи + endpoint + публичные IPv4 (см. шапку) ---------
redact() {
    sed -e 's#[A-Za-z0-9+/]\{43\}=#[KEY-REDACTED]#g' \
        -e 's#PrivateKey *=.*#PrivateKey = [KEY-REDACTED]#g' \
        -e 's#PublicKey *=.*#PublicKey = [KEY-REDACTED]#g' \
        -e 's#PresharedKey *=.*#PresharedKey = [KEY-REDACTED]#g' \
        -e 's#endpoint: .*#endpoint: [REDACTED]#g' \
        -e 's#Endpoint *=.*#Endpoint = [REDACTED]#g' \
    | awk '
    {
        line = $0; out = ""
        while (match(line, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) {
            ip   = substr(line, RSTART, RLENGTH)
            out  = out substr(line, 1, RSTART - 1)
            line = substr(line, RSTART + RLENGTH)
            split(ip, o, ".")
            if (o[1]=="10" || o[1]=="127" || o[1]=="0" || \
                (o[1]=="192" && o[2]=="168") || \
                (o[1]=="169" && o[2]=="254") || \
                (o[1]=="172" && o[2]>=16 && o[2]<=31)) {
                out = out ip                     # приватный/служебный — оставляем
            } else {
                out = out o[1] "." o[2] ".x.x"   # публичный — маскируем хвост
            }
        }
        print out line
    }'
}

sec() { echo ""; echo "==================================================================="; echo "## $1"; echo "==================================================================="; }
sub() { echo ""; echo "----- $1 -----"; }

# несекретный файл: показать содержимое целиком (или пометить отсутствие)
showf() {
    if [ -f "$1" ]; then echo "[$1]"; cat "$1" 2>/dev/null; echo "[/$1]"
    else echo "[$1] — нет"; fi
}
# секрет: ТОЛЬКО права/владелец/размер/имя, без содержимого
showmeta() {
    if [ -e "$1" ]; then ls -ld "$1" 2>/dev/null | awk '{print $1, $3, $5, $NF}'
    else echo "$1 — нет"; fi
}
# Версия прошивки Xiaomi лежит в UCI-файле /usr/share/xiaoqiang/xiaoqiang_version
# (строки вида: option ROM '1.1.38' / HARDWARE 'RC06' / CHANNEL / BUILDTIME).
# xqver KEY -> вернуть значение в кавычках. Это и есть «версия прошивки роутера».
xqver() { grep -E "^[[:space:]]*option $1 " /usr/share/xiaoqiang/xiaoqiang_version 2>/dev/null | head -1 | sed "s/.*'\(.*\)'.*/\1/"; }

main() {

sec "ОБЗОР РОУТЕРА (железо / прошивка / нагрузка)"
rom=$(xqver ROM); ch=$(xqver CHANNEL); hw=$(xqver HARDWARE); bt=$(xqver BUILDTIME)
echo "Прошивка (ROM):  ${rom:-?} (${ch:-?})   сборка: ${bt:-?}"
echo "Модель:          Xiaomi ${hw:-?}  /  $(cat /proc/device-tree/model 2>/dev/null | tr -d '\000')"
echo "Ядро:            $(uname -s 2>/dev/null) $(uname -r 2>/dev/null) $(uname -m 2>/dev/null)"
echo "BusyBox:         $(busybox 2>&1 | head -1)"
ncpu=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
la=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)
# load average -> понятный % загрузки (load1/ядра*100). Сырой load оставляем в скобках
# для технического разбора (тот, кто разбирает дамп, узнаёт привычную метрику).
pct=$(awk -v n="${ncpu:-1}" '{if(n>0)printf "%.0f",$1/n*100; exit}' /proc/loadavg 2>/dev/null)
echo "CPU:             ${ncpu:-?} ядра · загрузка ~${pct:-?}% (load average: ${la:-?})"
awk '/^MemTotal:/{t=$2}/^MemFree:/{f=$2}/^MemAvailable:/{a=$2}END{printf "RAM:             %d МБ свободно из %d МБ (доступно %s)\n", f/1024, t/1024, (a==""?"?":sprintf("%d МБ", a/1024))}' /proc/meminfo 2>/dev/null
# ПЗУ = постоянная память /data (ubifs, переживает ребут — туда ставится AWG/конфиги/
# логи). df|awk печатает строку сам (НЕ внутри echo "$(...)": awk-овский $(NF-2)
# схлестнулся бы с шелловским $(...) внутри двойных кавычек). / squashfs-корень не
# берём — он всегда 100% по природе сжатого ro-образа (мнимое «забито», пугает зря).
df -h /data 2>/dev/null | tail -1 | awk 'NF>=5{printf "ПЗУ (/data):     %s свободно из %s (занято %s)\n", $(NF-2),$(NF-4),$(NF-1)}'
echo "Uptime:          $(uptime 2>/dev/null)"
echo "Дата (роутер):   $(date 2>/dev/null)"
echo "Hostname:        $(cat /proc/sys/kernel/hostname 2>/dev/null)"
echo "AWG_DIR:         $AWG_DIR"

sec "ИНТЕРФЕЙС awg0"
ip addr show awg0 2>/dev/null || echo "(awg0 не поднят)"
sub "ip link"
ip link show awg0 2>/dev/null || echo "(нет)"

sec "СОСТОЯНИЕ AWG (awg show — ключи/endpoint замаскированы)"
if [ -x "$AWG_DIR/awg" ]; then
    "$AWG_DIR/awg" show awg0 2>/dev/null || echo "(awg show awg0 не отработал)"
    sub "возраст handshake"
    hs=$("$AWG_DIR/awg" show awg0 latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
    case "$hs" in
        ''|*[!0-9]*) echo "handshake: нет / никогда — VPS не отвечает?" ;;
        0)           echo "handshake: 0 — никогда" ;;
        *)           echo "handshake: $(( $(date +%s) - hs )) сек назад" ;;
    esac
else
    echo "(бинарь $AWG_DIR/awg не найден)"
fi

sec "МАРШРУТИЗАЦИЯ (fwmark / таблицы)"
sub "ip rule"
ip rule 2>/dev/null
sub "ip route show table 1000 (VPN-таблица)"
ip route show table 1000 2>/dev/null || echo "(таблица 1000 пуста)"
sub "default route (main)"
ip route show default 2>/dev/null
sub "ip route get 8.8.8.8 (куда реально пойдёт)"
ip route get 8.8.8.8 2>/dev/null

sec "IPTABLES mangle (метки в туннель)"
iptables -t mangle -S 2>/dev/null || echo "(mangle недоступен)"
sub "PREROUTING со счётчиками (видно, бьют ли правила трафик)"
iptables -t mangle -L PREROUTING -v -n 2>/dev/null | head -30
sub "VPN_EXCLUDE / VPN_FORCE со счётчиками"
iptables -t mangle -L VPN_EXCLUDE -v -n 2>/dev/null || echo "(цепочки VPN_EXCLUDE нет)"
iptables -t mangle -L VPN_FORCE   -v -n 2>/dev/null || echo "(цепочки VPN_FORCE нет)"

sec "IPTABLES nat (MASQUERADE) + FORWARD policy"
iptables -t nat -S POSTROUTING 2>/dev/null | grep -E "MASQUERADE|awg0" || echo "(нет MASQUERADE на awg0)"
sub "FORWARD (policy + первые правила)"
iptables -S FORWARD 2>/dev/null | head -8

sec "IPSET (наполнение списков)"
echo "Наборы: $(ipset list -n 2>/dev/null | tr '\n' ' ')"
for s in awg_list iplist_set; do
    n=$(ipset list "$s" 2>/dev/null | awk -F': ' '/^Number of entries/{print $2}')
    echo "  $s: ${n:-нет набора}"
done

sec "CONNTRACK"
echo "Активных соединений: $(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || conntrack -C 2>/dev/null || echo '?')"

sec "DNS (dnsmasq)"
sub "/etc/dnsmasq.d/ (наши файлы)"
ls -la /etc/dnsmasq.d/ 2>/dev/null | grep -E "awg|upstream" || echo "(наших файлов нет)"
sub "00-upstream.conf (форвард upstream в туннель)"
showf /etc/dnsmasq.d/00-upstream.conf
sub "счётчики доменов"
echo "awg-domains: $(grep -c '^ipset=' /etc/dnsmasq.d/awg-domains.conf 2>/dev/null || echo 0)"
echo "awg-custom:  $(grep -c '^ipset=' /etc/dnsmasq.d/awg-custom.conf 2>/dev/null || echo 0)"
sub "/etc/resolv.conf"
cat /etc/resolv.conf 2>/dev/null

sec "СОСТОЯНИЕ (persist-файлы в AWG_DIR — несекретные)"
echo "Активный конфиг (.active): $(cat "$AWG_DIR/.active" 2>/dev/null || echo '?')"
for f in .failover-mode .failover-home .full-tunnel .bypass-ips .bypass-dst \
         .bypass-ifaces .bypass-guest .fullvpn-ips .fullvpn-ifaces \
         .fullvpn-guest .iplist.count; do
    showf "$AWG_DIR/$f"
done
sub "iplist.conf (источник списка IP — несекретно)"
showf "$AWG_DIR/iplist.conf"

sec "СЕКРЕТНЫЕ ФАЙЛЫ — ТОЛЬКО НАЛИЧИЕ / ПРАВА (содержимое НЕ читаем)"
echo "(режим / владелец / размер / имя)"
showmeta "$AWG_DIR/awg.conf"
showmeta "$AWG_DIR/awg0.conf"
showmeta "$AWG_DIR/amnezia_for_awg.conf"
showmeta "$AWG_DIR/notify.conf"
if [ -d "$AWG_DIR/configs" ]; then
    for c in "$AWG_DIR"/configs/*.conf; do [ -e "$c" ] && showmeta "$c"; done
fi

sec "ЛОКИ / СТЕЙТ В /tmp"
for l in awg-heal.lock awg-switching.lock awg-watchdog.lock awg-watchdog.state; do
    if [ -e "/tmp/$l" ]; then
        echo "/tmp/$l: есть$( [ -s "/tmp/$l" ] && echo " -> $(cat "/tmp/$l" 2>/dev/null)" )"
    else
        echo "/tmp/$l: нет"
    fi
done

sec "CRON (автозапуск — без него после ребута не поднимется)"
cat /etc/crontabs/root 2>/dev/null || echo "(crontab пуст?!)"

sec "БИНАРНИКИ AWG + ВЕРСИИ"
ls -l "$AWG_DIR/amneziawg-go" "$AWG_DIR/awg" 2>/dev/null || echo "(бинарников нет)"
[ -x "$AWG_DIR/amneziawg-go" ] && { printf 'amneziawg-go: '; "$AWG_DIR/amneziawg-go" --version 2>&1 | head -1; }
[ -x "$AWG_DIR/awg" ]         && { printf 'awg: ';          "$AWG_DIR/awg" --version 2>&1 | head -1; }

sec "РЕСУРСЫ (RAM / диск / размер логов)"
awk '/^MemTotal:/{t=$2}/^MemFree:/{f=$2}/^MemAvailable:/{a=$2}END{printf "RAM: %d МБ свободно из %d МБ (доступно %s)\n", f/1024, t/1024, (a==""?"?":sprintf("%d МБ", a/1024))}' /proc/meminfo 2>/dev/null
for m in /data /tmp; do
    df -h "$m" 2>/dev/null | tail -1 | awk -v mp="$m" 'NF>=5{printf "Диск %s: %s своб из %s (занято %s)\n", mp, $(NF-2), $(NF-4), $(NF-1)}'
done
ls -l /tmp/*.log 2>/dev/null | awk '{s+=$5}END{if(NR>0)printf "Логи /tmp: %d КБ в %d файлах\n",(s+1023)/1024,NR; else print "Логи /tmp: нет"}'

sec "ЛОГИ /tmp (хвосты по 40 строк)"
for lg in awg-startup.log switch-vpn-setup.log awg-watchdog.log iplist-update.log hysteria.log xray.log hev.log notify.log notify-event.log; do
    sub "$lg"
    if [ -f "/tmp/$lg" ]; then tail -40 "/tmp/$lg" 2>/dev/null; else echo "(нет)"; fi
done

sec "ВНЕШНИЙ IP (тест маршрута — IP замаскированы redact)"
printf 'Прямой IP:  '; curl -s --max-time 5 https://api.ipify.org 2>/dev/null || printf '(нет ответа)'
echo ""
if ip link show awg0 >/dev/null 2>&1; then
    printf 'Через awg0: '; curl -s --interface awg0 --max-time 6 https://api.ipify.org 2>/dev/null || printf '(нет ответа через туннель)'
    echo ""
fi

echo ""
echo "==================================================================="
echo "## КОНЕЦ ДАМПА"
echo "==================================================================="
}

main 2>&1 | redact
