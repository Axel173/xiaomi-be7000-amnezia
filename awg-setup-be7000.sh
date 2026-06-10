#!/bin/sh
#
# awg-setup-be7000.sh
# Полная автоматическая настройка AmneziaWG + split-tunneling по доменам
# на стоковой прошивке Xiaomi BE7000 (CN).
#
# Что делает:
#   1) Скачивает и запускает официальный установщик AmneziaWG от @T7m
#      (github.com/alexandershalin/amneziawg-be7000)
#   2) Поднимает интерфейс awg0 на основе твоего awg.conf
#   3) Настраивает ipset + dnsmasq + ip rule для маршрутизации
#      ТОЛЬКО выбранных доменов через AWG.
#   4) Скачивает список доменов re-filter (itdoginfo/allow-domains)
#   5) Ставит автообновление списка по cron в 5 утра.
#   6) Регистрирует автозапуск в /etc/rc.local.
#
# Требования:
#   - Скрипт запущен от root на стоковой прошивке BE7000
#   - В /data/usr/app/awg/ лежит файл awg.conf (от твоего VPS)
#   - Роутер имеет доступ в интернет
#
# Запуск:
#   chmod +x /data/usr/app/awg/awg-setup-be7000.sh
#   /data/usr/app/awg/awg-setup-be7000.sh
#
# Версия: 2.1 / май 2026
#
# Что нового в v2.1:
#   - Re-filter (itdoginfo/allow-domains) теперь ОПЦИОНАЛЕН и по
#     умолчанию ВЫКЛЮЧЕН. Для большинства пользователей iplist (CIDR
#     от opencck.org) + domain add ... закрывают потребности с лихвой,
#     а re-filter лишь добавляет 1163+ правил в dnsmasq и качается по
#     ночному cron'у без необходимости.
#     Чтобы включить re-filter, запусти установщик так:
#         ENABLE_REFILTER=1 ./awg-setup-be7000.sh
#     или экспортируй переменную: `export ENABLE_REFILTER=1`.
#     Скрипт `update-lists.sh` создаётся в любом случае — можно
#     запускать руками когда захочешь подтянуть re-filter разово.
#
# Что нового в v2 (после реального прохождения 26 мая 2026):
#   - Чистим пустые I1..I5 из awg.conf (AmneziaVPN 4.8.12.9+ их добавляет
#     даже в Legacy-режим, старый awg-tools падает на них с
#     "Line unrecognized: I2=")
#   - Сами создаём amnezia_for_awg.conf из awg.conf (иначе вендорный
#     awg_setup.sh на ПЕРВОМ запуске падает с "File amnezia_for_awg.conf
#     not found")
#   - Уважаем пользовательские бинарники: если в $AWG_DIR/bin/ лежат
#     amneziawg-go.user и awg.user — они копируются на место и
#     вендорный awg_setup.sh их не перезатирает (он проверяет наличие)
#   - split-route.sh теперь идемпотентно держит FORWARD ACCEPT — без
#     него на стоковой прошивке политика FORWARD DROP и весь LAN-трафик
#     к awg0 дропается (типа открываются только российские сайты).
#   - НЕ полагаемся на /etc/rc.local — он сбрасывается при ребуте на
#     стоковой BE7000. Автозапуск — через cron + awg-heal.sh.
#
# ОБОСНОВАНИЕ:
#   Решения опираются на опыт сообщества BE7000 и проверки на живом
#   железе; «почему именно так» поясняется в комментариях к разделам.
#

set -e

# Цвета для красивого вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log()  { printf "${BLUE}[INFO]${NC}  %s\n" "$1"; }
ok()   { printf "${GREEN}[ OK ]${NC}  %s\n" "$1"; }
warn() { printf "${YELLOW}[WARN]${NC}  %s\n" "$1"; }
err()  { printf "${RED}[FAIL]${NC}  %s\n" "$1" >&2; }

AWG_DIR="/data/usr/app/awg"
AWG_CONF="$AWG_DIR/awg.conf"
INSTALL_SCRIPT_URL="https://github.com/alexandershalin/amneziawg-be7000/raw/refs/heads/main/awg_setup.sh"
RE_FILTER_URL="https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-ipset.lst"
# Re-filter по умолчанию ВЫКЛЮЧЕН (v2.1). Чтобы включить:
#   ENABLE_REFILTER=1 ./awg-setup-be7000.sh
ENABLE_REFILTER="${ENABLE_REFILTER:-0}"
RC_LOCAL="/etc/rc.local"
DNSMASQ_CONF="/etc/dnsmasq.conf"
DNSMASQ_DIR="/etc/dnsmasq.d"
AWG_LIST_NAME="awg_list"
ROUTE_TABLE="1000"
FWMARK="0x1"

# ============================================================================
# 0. ПРЕДВАРИТЕЛЬНЫЕ ПРОВЕРКИ
# ============================================================================
log "Проверяю окружение..."

if [ "$(id -u)" -ne 0 ]; then
    err "Скрипт должен запускаться от root. Текущий пользователь: $(whoami)"
    exit 1
fi

mkdir -p "$AWG_DIR"
cd "$AWG_DIR"

if [ ! -f "$AWG_CONF" ]; then
    err "Не найден файл $AWG_CONF"
    err "Положи сюда свой awg.conf от VPS (с полями Jc/Jmin/Jmax/S1/S2/H1..H4)"
    err "и запусти скрипт снова."
    exit 1
fi

ok "awg.conf найден"

# Проверяем интернет
if ! ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
    err "Нет интернета на роутере. Подключи WAN-кабель/проверь настройки."
    exit 1
fi
ok "Интернет на роутере есть"

# ============================================================================
# 0.1 ПОДГОТОВКА КОНФИГА — чистим пустые I1..I5
# ============================================================================
# AmneziaVPN 4.8.12.9+ добавляет в конфиг заготовки I1..I5 даже в Legacy.
# Если они пустые (I2 = ), awg-tools падает: "Line unrecognized: I2=".
# Заполненные I1 (например, I1 = <b 0xHEX...>) — НЕ трогаем.
# ----------------------------------------------------------------------------
if grep -qE '^I[1-5]\s*=\s*$' "$AWG_CONF"; then
    log "Чищу пустые поля I1..I5 в awg.conf..."
    sed -i '/^I[1-5]\s*=\s*$/d' "$AWG_CONF"
    ok "Пустые I-поля удалены"
fi

# ============================================================================
# 0.2 СОЗДАЁМ amnezia_for_awg.conf — вендорный awg_setup.sh его ждёт
# ============================================================================
# Без этого файла на ПЕРВОМ запуске awg_setup.sh падает с
# "File amnezia_for_awg.conf not found". На втором запуске сам бы его
# создал, но первый запуск выглядит для пользователя как FAIL.
# ----------------------------------------------------------------------------
if [ ! -f "$AWG_DIR/amnezia_for_awg.conf" ]; then
    cp "$AWG_CONF" "$AWG_DIR/amnezia_for_awg.conf"
    ok "amnezia_for_awg.conf создан из awg.conf"
fi

# ============================================================================
# 0.3 ПОДКЛАДЫВАЕМ ПОЛЬЗОВАТЕЛЬСКИЕ БИНАРНИКИ (если есть)
# ============================================================================
# Если ты собрал свежие amneziawg-go и awg вручную (нужно для AWG 2.0 —
# поля S3/S4, диапазоны H1=N-M, заполненные I1) и положил их в
#   $AWG_DIR/bin/amneziawg-go.user
#   $AWG_DIR/bin/awg.user
# мы их установим. вендорный awg_setup.sh проверяет наличие бинарников
# через "AmneziaWG binaries exist" — и НЕ перезатрёт их.
#
# Как собрать — см. инструкцию (Приложение Г, раздел "Сборка бинарников").
# ----------------------------------------------------------------------------
if [ -f "$AWG_DIR/bin/amneziawg-go.user" ]; then
    log "Найден пользовательский amneziawg-go.user, ставлю..."
    cp "$AWG_DIR/bin/amneziawg-go.user" "$AWG_DIR/amneziawg-go"
    chmod +x "$AWG_DIR/amneziawg-go"
    cp "$AWG_DIR/amneziawg-go" "$AWG_DIR/amneziawg-go.working.bak"
    ok "amneziawg-go установлен ($("$AWG_DIR/amneziawg-go" --version 2>&1 | head -1))"
fi
if [ -f "$AWG_DIR/bin/awg.user" ]; then
    log "Найден пользовательский awg.user, ставлю..."
    cp "$AWG_DIR/bin/awg.user" "$AWG_DIR/awg"
    chmod +x "$AWG_DIR/awg"
    cp "$AWG_DIR/awg" "$AWG_DIR/awg.working.bak"
    ok "awg установлен ($("$AWG_DIR/awg" --version 2>&1 | head -1))"
fi

# Подсказка для AWG 2.0
if grep -qE '^(S3|S4)\s*=' "$AWG_CONF" || grep -qE '^H[1-4]\s*=\s*[0-9]+-[0-9]+' "$AWG_CONF"; then
    if [ ! -f "$AWG_DIR/amneziawg-go.working.bak" ] || [ ! -f "$AWG_DIR/awg.working.bak" ]; then
        warn "Конфиг AWG 2.0 (есть S3/S4 или диапазон H), но нет пользовательских"
        warn "бинарников. Вендорный awg_setup.sh скачает старые версии, которые НЕ"
        warn "понимают S3/S4. Будет ошибка 'Line unrecognized: S3=N'."
        warn "Собери бинарники по инструкции (Приложение Г) и положи в"
        warn "$AWG_DIR/bin/{amneziawg-go.user,awg.user}, потом перезапусти этот скрипт."
        warn "Альтернатива: добавь на VPS протокол AmneziaWG Legacy и используй его конфиг."
    fi
fi

# ============================================================================
# 1. УСТАНОВКА AMNEZIA WG (СКРИПТ ШАЛИНА)
# ============================================================================
log "Проверяю установщик AmneziaWG (awg_setup.sh, вендорится с бандлом)..."

# awg_setup.sh теперь ВЕНДОРИТСЯ: лежит в репо и заливается установщиком вместе
# с остальными скриптами (REQUIRED_FILES в be7000.ps1) ДО запуска этого
# скрипта — github убран из критического пути установки. Если файла почему-то нет
# (напр. ручной запуск awg-setup-be7000.sh без бандла) — это ошибка установки:
# НЕ тянем с сети, просим перезалить (историч. источник — $INSTALL_SCRIPT_URL).
if [ ! -f "$AWG_DIR/awg_setup.sh" ]; then
    err "awg_setup.sh не найден в $AWG_DIR — он поставляется с установщиком (вендорится)."
    err "Перезалей файлы бандла. Историч. источник: $INSTALL_SCRIPT_URL"
    exit 1
fi
chmod +x "$AWG_DIR/awg_setup.sh"
ok "Установщик AWG на месте (вендорится с бандлом, github не нужен)"

# Запускаем установщик AWG. Он сам:
# - скачивает amneziawg-go под нужную архитектуру
# - создаёт интерфейс awg0
# - поднимает его на основе awg.conf
# - вешает в автозапуск
log "Запускаю установщик AmneziaWG (может занять 1-2 минуты)..."
if ! ip link show awg0 >/dev/null 2>&1; then
    "$AWG_DIR/awg_setup.sh" || {
        err "Установщик AWG завершился с ошибкой"
        err "Открой $AWG_DIR/awg_setup.sh глазами, разберись с конфигом"
        exit 1
    }
    ok "AmneziaWG установлен"
else
    ok "Интерфейс awg0 уже поднят, переустановку пропускаю"
fi

# Ждём, пока интерфейс поднимется
log "Жду поднятия awg0..."
for i in $(seq 1 30); do
    if ip link show awg0 >/dev/null 2>&1; then
        ok "awg0 поднят"
        break
    fi
    sleep 1
done

if ! ip link show awg0 >/dev/null 2>&1; then
    err "awg0 не появился за 30 секунд. Проверь awg.conf, ключи и endpoint VPS."
    err "Команда для диагностики: ip a; cat $AWG_DIR/awg_setup.log (если есть)"
    exit 1
fi

# Проверяем handshake (если хотя бы один пир ответил — туннель работает)
log "Проверяю handshake с VPS..."
sleep 3
if command -v wg >/dev/null 2>&1; then
    WG_CMD="wg"
elif command -v amnezia-wg >/dev/null 2>&1; then
    WG_CMD="amnezia-wg"
elif [ -x "$AWG_DIR/awg" ]; then
    # ВАЖНО: CLI-утилита это awg (amneziawg-tools), а НЕ amneziawg-go — последний
    # это ДЕМОН и на 'show' печатает "Usage: amneziawg-go ... INTERFACE-NAME" и
    # выходит. Раньше тут стоял amneziawg-go → проверка handshake в установке
    # всегда печатала Usage впустую (видно в логах установки на железе).
    WG_CMD="$AWG_DIR/awg"
fi

if [ -n "$WG_CMD" ]; then
    "$WG_CMD" show awg0 2>/dev/null || warn "Не удалось получить wg show, но интерфейс есть"
fi

# ============================================================================
# 2. УСТАНОВКА IPSET (если нет)
# ============================================================================
log "Проверяю наличие ipset..."

if ! command -v ipset >/dev/null 2>&1; then
    warn "ipset не найден, пробую установить через opkg..."
    if command -v opkg >/dev/null 2>&1; then
        opkg update || warn "opkg update не удался, продолжаю"
        opkg install ipset || {
            err "Не удалось установить ipset через opkg."
            err "Ставь вручную через Entware или ImmortalWrt репо."
            exit 1
        }
    else
        err "opkg недоступен. ipset нужно поставить вручную."
        exit 1
    fi
fi
ok "ipset на месте: $(ipset --version | head -1)"

# Создаём ipset (идемпотентно)
if ! ipset list -n | grep -q "^${AWG_LIST_NAME}$"; then
    ipset create "$AWG_LIST_NAME" hash:net family inet hashsize 1024 maxelem 1000000
    ok "ipset $AWG_LIST_NAME создан"
else
    ok "ipset $AWG_LIST_NAME уже существует"
fi

# ============================================================================
# 3. НАСТРОЙКА DNSMASQ
# ============================================================================
# Используем упрощённый upstream: no-resolv + server=1.1.1.1/8.8.8.8 (через
# туннель). Если нужен полноценный DoH — подними cloudflared или dnscrypt-proxy
# и укажи server=127.0.0.1#5053.
# ----------------------------------------------------------------------------
log "Настраиваю dnsmasq..."

mkdir -p "$DNSMASQ_DIR"

# Подключаем директорию conf-dir в основной конфиг
if ! grep -q "^conf-dir=$DNSMASQ_DIR" "$DNSMASQ_CONF" 2>/dev/null; then
    echo "" >> "$DNSMASQ_CONF"
    echo "# Подключение split-tunnel конфигов (добавлено awg-setup-be7000)" >> "$DNSMASQ_CONF"
    echo "conf-dir=$DNSMASQ_DIR,*.conf" >> "$DNSMASQ_CONF"
    ok "conf-dir добавлен в $DNSMASQ_CONF"
else
    ok "conf-dir уже подключён"
fi

# DNS: подменяем upstream на DNS внутри VPN-туннеля.
# КРИТИЧНО: некоторые провайдеры подменяют DNS-ответы (DNS-спуфинг) для части
# доменов, возвращая адрес-заглушку. Прямые 1.1.1.1/8.8.8.8 не спасают —
# провайдер перехватит UDP/53 на пути. Поэтому DNS должен быть внутри туннеля
# и недоступен снаружи.
# У конфигов от Amnezia это обычно 172.29.172.254 — берём его из awg.conf.
VPN_DNS=$(grep -E '^DNS\s*=' "$AWG_CONF" | head -1 | awk -F'= *' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')
[ -z "$VPN_DNS" ] && VPN_DNS="172.29.172.254"

DNS_OVERRIDE="$DNSMASQ_DIR/00-upstream.conf"
cat > "$DNS_OVERRIDE" <<EOF
# DNS-сервер внутри VPN-туннеля (защита от подмен провайдером).
# Адрес взят из awg.conf поля DNS=. Если у тебя другой — поправь здесь
# и убедись что awg-heal.sh использует тот же (переменная VPN_DNS).
no-resolv
server=$VPN_DNS
EOF
ok "DNS upstream настроен ($DNS_OVERRIDE → $VPN_DNS)"

# Маршрут к VPN DNS через туннель — иначе dnsmasq до него не достучится
if ip link show awg0 >/dev/null 2>&1; then
    ip route replace "$VPN_DNS/32" dev awg0 2>/dev/null
    ok "Маршрут к $VPN_DNS прописан через awg0"
fi

# ============================================================================
# 4. СПИСОК ДОМЕНОВ (re-filter)
# ============================================================================
# Список доменов берём из re-filter (itdoginfo/allow-domains) — актуальный и
# удобный для dnsmasq+ipset формат. Нужен иной источник (antifilter geoip/
# geosite и т.п.) — замени RE_FILTER_URL в начале скрипта.
# ----------------------------------------------------------------------------
TMP_LIST="/tmp/re-filter-raw.lst"
TARGET_LIST="$DNSMASQ_DIR/awg-domains.conf"

if [ "$ENABLE_REFILTER" = "1" ]; then
    log "Скачиваю список доменов (re-filter)..."
    if curl -fsSL -o "$TMP_LIST" "$RE_FILTER_URL" 2>/dev/null; then
        # Файл с itdoginfo может быть в формате:
        #   ipset=/domain.com/vpn_domains
        # Нам нужно заменить имя ipset на $AWG_LIST_NAME
        sed "s/ipset=\(\/.*\/\).*/ipset=\1${AWG_LIST_NAME}/" "$TMP_LIST" > "$TARGET_LIST"
        ok "Список доменов установлен: $(wc -l < "$TARGET_LIST") строк"
    else
        warn "Не удалось скачать список доменов, ставлю минимальный пресет"
        cat > "$TARGET_LIST" <<EOF
# Минимальный пресет — добавляй сам по аналогии
ipset=/youtube.com/googlevideo.com/ytimg.com/youtu.be/ggpht.com/$AWG_LIST_NAME
ipset=/openai.com/chatgpt.com/oaistatic.com/cdn.oaistatic.com/$AWG_LIST_NAME
ipset=/anthropic.com/claude.ai/$AWG_LIST_NAME
ipset=/discord.com/discordapp.com/discord.gg/discord.media/$AWG_LIST_NAME
ipset=/instagram.com/cdninstagram.com/$AWG_LIST_NAME
ipset=/facebook.com/fbcdn.net/$AWG_LIST_NAME
ipset=/twitter.com/x.com/twimg.com/$AWG_LIST_NAME
ipset=/github.com/githubusercontent.com/githubassets.com/$AWG_LIST_NAME
EOF
    fi
    # Перезапускаем dnsmasq, чтобы он подхватил новые правила
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || killall -HUP dnsmasq 2>/dev/null || true
    ok "dnsmasq перезапущен"
else
    log "Re-filter отключён (ENABLE_REFILTER=0) — пропускаю скачивание списка"
    log "  iplist (CIDR от opencck.org) + 'domain add' покрывают большинство сайтов."
    log "  Если позже захочешь включить — запусти: ENABLE_REFILTER=1 $0"
    log "  Или разово: $AWG_DIR/update-lists.sh"
fi

# ============================================================================
# 4b. CIDR-СПИСКИ ОТ iplist.opencck.org (доп. к доменам)
# ============================================================================
# Доменный re-filter надёжен для крупных сайтов, но плохо ловит CDN с
# рандомными хостнеймами (Cloudflare, OpenAI, Discord). iplist.opencck.org
# отдаёт готовые CIDR-блоки крупнейших сервисов. Скрипт iplist-update.sh
# создаёт ipset iplist_set и маркирует трафик к этим подсетям тем же
# fwmark 0x1. Если iplist-update.sh не залит — пропустим.
# ----------------------------------------------------------------------------
if [ -f "$AWG_DIR/iplist-update.sh" ]; then
    log "Подгружаю CIDR от iplist.opencck.org..."
    chmod +x "$AWG_DIR/iplist-update.sh"
    "$AWG_DIR/iplist-update.sh" || warn "iplist-update вернул ошибку — см. /tmp/iplist-update.log"
    if ipset list -n 2>/dev/null | grep -qx iplist_set; then
        ipl_count=$(ipset list iplist_set | awk '/^Number of entries:/{print $NF}')
        ok "iplist_set наполнен: $ipl_count CIDR"
    fi
fi

# ============================================================================
# 5. СКРИПТ МАРШРУТИЗАЦИИ
# ============================================================================
log "Создаю скрипт маршрутизации split-route.sh..."

cat > "$AWG_DIR/split-route.sh" <<EOF
#!/bin/sh
# split-route.sh — настраивает PBR-маршрутизацию через awg0 для IP из ipset.
# Идемпотентен: можно перезапускать сколько угодно раз.
set -e

# 1) Отдельная таблица маршрутизации с дефолтом через awg0
ip route flush table $ROUTE_TABLE 2>/dev/null || true
ip route add default dev awg0 table $ROUTE_TABLE

# 2) Маркируем пакеты к IP из ipset (awg_list — домены, iplist_set — CIDR)
for set in $AWG_LIST_NAME iplist_set; do
    if ipset list -n 2>/dev/null | grep -qx "\$set"; then
        iptables -t mangle -D PREROUTING -m set --match-set "\$set" dst -j MARK --set-mark $FWMARK 2>/dev/null || true
        iptables -t mangle -D OUTPUT     -m set --match-set "\$set" dst -j MARK --set-mark $FWMARK 2>/dev/null || true
        iptables -t mangle -A PREROUTING -m set --match-set "\$set" dst -j MARK --set-mark $FWMARK
        iptables -t mangle -A OUTPUT     -m set --match-set "\$set" dst -j MARK --set-mark $FWMARK
    fi
done

# 3) Помеченные пакеты — по таблице $ROUTE_TABLE
ip rule del fwmark $FWMARK table $ROUTE_TABLE 2>/dev/null || true
ip rule add fwmark $FWMARK table $ROUTE_TABLE pref 99

# 4) NAT для исходящего трафика через awg0
iptables -t nat -D POSTROUTING -o awg0 -j MASQUERADE 2>/dev/null || true
iptables -t nat -A POSTROUTING -o awg0 -j MASQUERADE

# 5) FORWARD ACCEPT — КРИТИЧНО.
# На стоковой BE7000 у fw3 policy FORWARD = DROP, и в zone-конфиге нет
# Forward 'lan' -> 'awg', есть только 'guest' -> 'awg'. Без этих правил
# весь LAN-трафик на awg0 дропается, на ПК сайты "не открываются".
# Используем общие правила (без -i br-lan) чтобы работало и для br-guest
# тоже, и при кастомных бриджах пользователя.
iptables -D FORWARD -o awg0 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i awg0 -j ACCEPT 2>/dev/null || true
iptables -I FORWARD 1 -o awg0 -j ACCEPT
iptables -I FORWARD 1 -i awg0 -j ACCEPT

# 6) Маршрут к VPN DNS (172.29.172.254) через туннель — чтобы dnsmasq до него дошёл
VPN_DNS=\$(grep -E '^DNS\s*=' "$AWG_CONF" 2>/dev/null | head -1 | awk -F'= *' '{print \$2}' | awk -F',' '{print \$1}' | tr -d ' ')
[ -n "\$VPN_DNS" ] && ip route replace "\$VPN_DNS/32" dev awg0 2>/dev/null

echo "[split-route] правила применены"
EOF

chmod +x "$AWG_DIR/split-route.sh"
ok "split-route.sh готов"

# Запускаем прямо сейчас
log "Применяю правила маршрутизации..."
"$AWG_DIR/split-route.sh"
ok "Правила применены"

# ============================================================================
# 6. АВТОЗАПУСК ЧЕРЕЗ /etc/rc.local
# ============================================================================
log "Настраиваю автозапуск..."

# ВАЖНО: на стоковой BE7000 /etc/rc.local сбрасывается при ребуте (overlay),
# поэтому рассчитывать на него нельзя. Используем cron + awg-heal.sh —
# по образцу xmir-patcher, чей ssh_patch.sh выживает ребуты тем же путём.

# Для совместимости всё-таки прописываем и в rc.local (если он чудом выживет —
# не помешает; если нет — heal через cron возьмёт своё через минуту).
if [ -f "$RC_LOCAL" ]; then
    sed -i '/# AWG-SETUP-BE7000 START/,/# AWG-SETUP-BE7000 END/d' "$RC_LOCAL"
fi

# Главное — cron-задача awg-heal.sh (запускается каждую минуту, lock в /tmp
# гарантирует выполнение один раз за загрузку).
mkdir -p /etc/crontabs
touch /etc/crontabs/root

if [ -f "$AWG_DIR/awg-heal.sh" ]; then
    chmod +x "$AWG_DIR/awg-heal.sh"
    if ! grep -qF "$AWG_DIR/awg-heal.sh" /etc/crontabs/root; then
        echo "*/1 * * * * $AWG_DIR/awg-heal.sh >/dev/null 2>&1" >> /etc/crontabs/root
        ok "Cron-задача awg-heal зарегистрирована (каждую минуту)"
    else
        ok "Cron-задача awg-heal уже на месте"
    fi
else
    warn "$AWG_DIR/awg-heal.sh не найден — автоматическое восстановление после ребута"
    warn "работать НЕ будет. Залей awg-heal.sh через WinSCP и перезапусти скрипт."
fi

# iplist-update.sh — раз в сутки в 5:00, с --notify (утренняя сводка на почту:
# кол-во CIDR + дельта + краткий статус VPN). Вызов из awg-heal.sh идёт БЕЗ
# флага — там о загрузке шлёт письмо сам heal, дайджест при каждом ребуте не нужен.
if [ -f "$AWG_DIR/iplist-update.sh" ]; then
    chmod +x "$AWG_DIR/iplist-update.sh"
    IPLIST_CRON="0 5 * * * $AWG_DIR/iplist-update.sh --notify >/dev/null 2>&1"
    if grep -qF "$AWG_DIR/iplist-update.sh --notify" /etc/crontabs/root; then
        :  # актуальная строка уже на месте
    elif grep -qF "$AWG_DIR/iplist-update.sh" /etc/crontabs/root; then
        # старая строка без --notify (установка до июня 2026) — обновляем на месте
        sed -i "\|$AWG_DIR/iplist-update.sh|d" /etc/crontabs/root
        echo "$IPLIST_CRON" >> /etc/crontabs/root
        ok "Cron-задача iplist-update обновлена (+--notify: утренняя сводка на почту)"
    else
        echo "$IPLIST_CRON" >> /etc/crontabs/root
        ok "Cron-задача iplist-update зарегистрирована (5:00 ежедневно, со сводкой на почту)"
    fi
fi

# awg-watchdog.sh — сторож VPN: каждые 2 минуты проверяет живость VPS, при
# падении переводит трафик в прямой режим (safety-off) и шлёт письмо. Добавлен
# в установку июнь 2026 (раньше cron ставился вручную после заливки файла).
if [ -f "$AWG_DIR/awg-watchdog.sh" ]; then
    chmod +x "$AWG_DIR/awg-watchdog.sh"
    if ! grep -qF "$AWG_DIR/awg-watchdog.sh" /etc/crontabs/root; then
        echo "*/2 * * * * $AWG_DIR/awg-watchdog.sh >/dev/null 2>&1" >> /etc/crontabs/root
        ok "Cron-задача awg-watchdog зарегистрирована (каждые 2 минуты)"
    fi
fi

# ============================================================================
# 7. АВТООБНОВЛЕНИЕ СПИСКА ДОМЕНОВ (CRON, ежедневно в 5:00)
# ============================================================================
log "Готовлю update-lists.sh (re-filter, для ручного запуска)..."

# update-lists.sh создаём ВСЕГДА — даже когда re-filter выключен,
# пользователь может запустить его руками: /data/usr/app/awg/update-lists.sh
cat > "$AWG_DIR/update-lists.sh" <<EOF
#!/bin/sh
# Скачивает свежий список доменов (re-filter) и перезапускает dnsmasq.
TMP="/tmp/re-filter-raw.lst"
TARGET="$DNSMASQ_DIR/awg-domains.conf"
if curl -fsSL -o "\$TMP" "$RE_FILTER_URL"; then
    sed "s|ipset=\(\\/.*\\/\).*|ipset=\\1$AWG_LIST_NAME|" "\$TMP" > "\$TARGET"
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || killall -HUP dnsmasq
    logger -t awg-update "Список доменов обновлён: \$(wc -l < \$TARGET) строк"
else
    logger -t awg-update "Ошибка обновления списка"
fi
EOF
chmod +x "$AWG_DIR/update-lists.sh"
ok "update-lists.sh готов ($AWG_DIR/update-lists.sh)"

mkdir -p /etc/crontabs
touch /etc/crontabs/root

if [ "$ENABLE_REFILTER" = "1" ]; then
    # Регистрируем cron (если ещё не зарегистрирован)
    CRON_LINE="0 5 * * * $AWG_DIR/update-lists.sh"
    if ! grep -qF "$AWG_DIR/update-lists.sh" /etc/crontabs/root; then
        echo "$CRON_LINE" >> /etc/crontabs/root
        /etc/init.d/cron restart 2>/dev/null || /etc/init.d/crond restart 2>/dev/null || true
        ok "Cron-задача добавлена (каждый день в 5:00)"
    else
        ok "Cron-задача уже на месте"
    fi
else
    # Если флаг выключен — выкорчёвываем cron-строку, если она осталась
    # от прошлой установки с включённым re-filter.
    if grep -qF "$AWG_DIR/update-lists.sh" /etc/crontabs/root; then
        sed -i "\|$AWG_DIR/update-lists.sh|d" /etc/crontabs/root
        /etc/init.d/cron restart 2>/dev/null || /etc/init.d/crond restart 2>/dev/null || true
        ok "Старая cron-задача re-filter удалена (флаг выключен)"
    else
        log "Cron re-filter не ставится (ENABLE_REFILTER=0)"
    fi
fi

# ============================================================================
# 7b. УСТАНОВКА HELPER-СКРИПТОВ (vpn, domain, awg-status)
# ============================================================================
# Если рядом со скриптом лежат switch-vpn.sh / domain.sh / awg-status.sh —
# делаем их исполняемыми и публикуем как короткие команды через /usr/bin.
# Так пользователь сможет писать просто 'vpn germany' или 'domain add chatgpt.com'.
# ----------------------------------------------------------------------------
log "Устанавливаю helper-скрипты..."
for helper in switch-vpn.sh domain.sh awg-status.sh; do
    if [ -f "$AWG_DIR/$helper" ]; then
        chmod +x "$AWG_DIR/$helper"
    fi
done

# Коротких команд (vpn/domain/awg) в /usr/bin НЕ создаём. На стоке BE7000 корень
# (/) — squashfs (ro): `ln` молча падает, симлинков по факту нет (проверено вживую:
# command -v vpn/domain/awg → not found, PATH = /usr/sbin:/usr/bin:/sbin:/bin без
# $AWG_DIR). Плюс имя `awg` в $AWG_DIR занято бинарём amneziawg-tools. Управление —
# с ПК через be7000.bat (меню) либо полным путём `sh $AWG_DIR/<скрипт>.sh` (см. итог
# ниже). Раньше тут был тщетный `ln -sf ... /usr/bin/...` — убран как мёртвый код.

# Создаём папку configs/ и кладём туда текущий awg.conf копией,
# чтобы пользователь сразу мог им управлять через 'vpn'
mkdir -p "$AWG_DIR/configs"
if [ -f "$AWG_CONF" ] && [ ! -f "$AWG_DIR/configs/default.conf" ]; then
    cp "$AWG_CONF" "$AWG_DIR/configs/default.conf"
    ok "Текущий конфиг сохранён как 'default' (можно переключаться через 'vpn')"
fi
# .active — ИМЯ текущего конфига. Сеем 'default', если ещё не задан. ВАЖНО: раньше
# .active писался ТОЛЬКО внутри блока выше (когда default.conf создавали из awg.conf).
# Но если пользователь привёз свой configs/default.conf в payload, блок пропускался
# и .active оставался ПУСТЫМ → failover/статус показывали «активный сервер ?», а
# watchdog (count_backups/home-failback) считал активный конфиг резервным.
if [ ! -s "$AWG_DIR/.active" ]; then
    echo "default" > "$AWG_DIR/.active"
fi

# Авто-failover (switch-vpn.sh failover): «основной» конфиг для режима home.
# Сеем один раз = текущий активный (default при первой установке); не перетираем,
# если уже есть (пользователь мог выбрать другой через меню). Режим по умолчанию —
# sticky (файла .failover-mode нет → watchdog считает sticky); менять в vpn-toggle.
# `|| true` в command-sub — чтобы под `set -e` отсутствующий .active не ронял скрипт.
if [ ! -f "$AWG_DIR/.failover-home" ]; then
    act=$(cat "$AWG_DIR/.active" 2>/dev/null || true)
    [ -n "$act" ] || act="default"
    echo "$act" > "$AWG_DIR/.failover-home"
    ok "Авто-failover: основной конфиг (home) = '$act', режим по умолчанию sticky"
fi

# ============================================================================
# 7.5 ЧИСТКА ИЗБЫТОЧНЫХ bin/*.user (экономия флеша — /data на стоке всего ~20 МБ)
# ============================================================================
# bin/{amneziawg-go,awg}.user — КАНОНИЧЕСКИЙ источник бинарей, нужный ТОЛЬКО на
# установке: выше (секция 0.3) мы уже скопировали их в рабочие бинари и в
# .working.bak. В runtime (boot/heal/switch/watchdog) bin/*.user не читает НИКТО
# — самовосстановление идёт из .working.bak (awg-heal.sh). На стоке /data всего
# ~20 МБ, а amneziawg-go ~4.7 МБ: держать его в ТРЁХ копиях (рабочий +
# .working.bak + bin/*.user) расточительно. Скрипт дошёл сюда => awg0 поднят,
# рабочие бинари корректны, значит .working.bak (снятый с них) валиден — можно
# удалить bin/*.user. Источник не теряется: он в git и в payload be7000.ps1 →
# при следующей установке зальётся снова (и эта же секция снова подчистит).
# СТРАХОВКА ВАЖНЕЕ МЕСТА: удаляем bin/$b.user только если .working.bak реально
# есть и его размер совпадает с рабочим бинарём; иначе оставляем как запасной
# источник восстановления (лучше потратить флеш, чем остаться без самопочинки).
for b in amneziawg-go awg; do
    [ -f "$AWG_DIR/bin/$b.user" ] || continue
    wb="$AWG_DIR/$b.working.bak"
    if [ -f "$wb" ] && [ -f "$AWG_DIR/$b" ] && \
       [ "$(stat -c%s "$wb" 2>/dev/null)" = "$(stat -c%s "$AWG_DIR/$b" 2>/dev/null)" ]; then
        rm -f "$AWG_DIR/bin/$b.user"
        ok "bin/$b.user удалён (есть рабочий + валидный .working.bak; источник — git/payload)"
    else
        warn "bin/$b.user оставлен: нет валидного .working.bak (страховка важнее места)"
    fi
done
rmdir "$AWG_DIR/bin" 2>/dev/null || true   # уберём каталог, если опустел

# ============================================================================
# 8. ФИНАЛЬНАЯ ПРОВЕРКА
# ============================================================================
# Ожидаемая скорость: AWG (Go-реализация) на стоке — ориентировочно 200-400
# Мбит. Гигабит на этом железе/прошивке недостижим (нужен модуль ядра/OpenWrt).
# ----------------------------------------------------------------------------
echo ""
echo "========================================================================"
ok "Настройка завершена!"
echo "========================================================================"
echo ""
echo "Что у тебя сейчас работает:"
echo ""
echo "  1. AmneziaWG-туннель awg0 поднят:"
ip -br a show awg0 2>/dev/null || warn "awg0 не виден — проверь конфиг"
echo ""
echo "  2. ipset $AWG_LIST_NAME готов принимать IP-адреса:"
echo "     Размер сейчас: $(ipset list "$AWG_LIST_NAME" | grep -c '^[0-9]' || echo 0) записей"
echo "     (он будет наполняться по мере того, как устройства будут открывать"
echo "      сайты из списка. Открой YouTube — IP появятся.)"
echo ""
if [ "$ENABLE_REFILTER" = "1" ]; then
    echo "  3. Список доменов re-filter: $TARGET_LIST"
    echo "     ($(wc -l < "$TARGET_LIST" 2>/dev/null || echo 0) строк, обновляется ежедневно в 5:00)"
else
    echo "  3. Re-filter ВЫКЛЮЧЕН (по умолчанию в v2.1)."
    echo "     Маршрутизация через VPN работает по iplist_set (CIDR) +"
    echo "     ipset awg_list (твои 'domain add ...'). Этого хватает для"
    echo "     YouTube, OpenAI, Discord, Meta, Cloudflare и т.п."
    echo "     Включить re-filter: ENABLE_REFILTER=1 ./awg-setup-be7000.sh"
    echo "     Разово обновить руками: $AWG_DIR/update-lists.sh"
fi
echo ""
echo "  4. После ребута роутера всё поднимется само (cron+awg-heal.sh)."
echo "     Если /etc/rc.local выживет — отлично, нет — heal через минуту всё восстановит."
echo ""
echo "  5. Авто-failover: если активный VPS умрёт, watchdog сам переберёт"
echo "     configs/*.conf по алфавиту и встанет на первый рабочий (режим sticky"
echo "     по умолчанию). Сменить режим off/sticky/home — be7000.bat → 21."
echo ""
echo "========================================================================"
echo "ТЕСТ:"
echo "========================================================================"
echo "  - Через подключённое устройство открой https://2ip.ru — должен показать"
echo "    IP твоего ПРОВАЙДЕРА (это значит, что обычный трафик идёт мимо VPN)."
echo "  - Открой https://www.youtube.com и зайди в любое видео — должно играть"
echo "    без тормозов. Чтобы проверить, что YouTube идёт через VPS:"
echo "    в браузере открой https://www.youtube.com/about — снизу будет ваша"
echo "    \"страна\" — она должна совпадать со страной твоего VPS."
echo ""
echo "  - Из консоли роутера: 'ipset list $AWG_LIST_NAME | head' — должны"
echo "    появиться IP-адреса googlevideo.com и подобных."
echo ""
echo "УПРАВЛЕНИЕ: удобнее всего с ПК через be7000.bat (меню)."
echo ""
echo "В консоли роутера коротких команд awg/vpn/domain НЕТ (на стоке / это"
echo "squashfs ro -> симлинки в /usr/bin не создаются). Зови по ПОЛНОМУ пути:"
echo "  sh $AWG_DIR/awg-status.sh           — полный статус AWG + ipset + правила"
echo "  sh $AWG_DIR/awg-status.sh test      — проверка популярных сайтов (через VPN или нет)"
echo "  sh $AWG_DIR/switch-vpn.sh           — список доступных конфигов стран"
echo "  sh $AWG_DIR/switch-vpn.sh germany   — переключиться на конфиг germany.conf"
echo "  sh $AWG_DIR/switch-vpn.sh status    — текущий активный конфиг + страна"
echo "  sh $AWG_DIR/domain.sh add chatgpt.com      — добавить домен в туннель"
echo "  sh $AWG_DIR/domain.sh remove instagram.com — убрать домен из своего списка"
echo "  sh $AWG_DIR/domain.sh list          — твои добавления + статистика"
echo "  sh $AWG_DIR/domain.sh search openai — поиск по всем спискам"
echo ""
echo "ДОПОЛНИТЕЛЬНЫЕ КОНФИГИ (для смены страны):"
echo "  Положи .conf файлы в $AWG_DIR/configs/"
echo "  Например: germany.conf, france.conf, netherlands.conf"
echo "  Затем: sh $AWG_DIR/switch-vpn.sh germany   (или be7000.bat -> 9)"
echo ""
echo "НИЗКОУРОВНЕВЫЕ КОМАНДЫ (если что-то не работает):"
echo "  $AWG_DIR/awg show awg0        — статус туннеля + handshake (wg тут НЕТ, есть awg)"
echo "  ipset list $AWG_LIST_NAME | head — что попало в список"
echo "  iptables -t mangle -L -v -n   — правила маркировки"
echo "  ip rule                       — правила роутинга"
echo "  ip route show table $ROUTE_TABLE  — таблица маршрутизации VPN"
echo "  $AWG_DIR/iplist-update.sh     — обновить CIDR-список вручную"
echo ""
echo "Если что-то не работает — смотри /tmp/awg-startup.log после ребута."
echo "========================================================================"
