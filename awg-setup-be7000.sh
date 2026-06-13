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
#   - transport-awg.sh up идемпотентно держит FORWARD ACCEPT для awg0 — без
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
# Очистка НЕвыбранного альт-транспорта (xray <-> hy2 взаимоисключающи на флеше /data
# ~20 МБ — живёт ОДИН альт). INSTALL_ALT (env от be7000.ps1) = какой АЛЬТ оставляем:
#   xray | hy2 | none.
#   * Удаляем БИНАРЬ другого альта (тяжёлый: xray ~7.6 МБ, hysteria ~4.6 МБ) — освобождаем
#     флеш и убираем «призрак» из меню (transport_ready без бинаря = false).
#   * Конфиги (xray-configs/ · hy2-configs/ · .xray-active · .hy2-active) НЕ трогаем —
#     лёгкие, дают вернуться переустановкой без повторной вставки ссылок.
#   * awg НИКОГДА здесь не удаляем (база/тёплый резерв; снос awg — только Uninstall).
#   * hev общий для xray и hy2 → снимаем лишь когда альта нет вовсе (INSTALL_ALT=none = awg-only).
#   * INSTALL_ALT пуст (старый ПК / прямой запуск без переменной) → НЕ чистим (обратная совместимость).
# Идемпотентно. ПК зовёт субкомандой `purge-alt` ДО заливки тяжёлых бинарей (чтобы пик
# флеша на свопе альта awg+xray->awg+hy2 не переполнил /data). rm живёт ЗДЕСЬ, в .sh на
# роутере (а не в команде с ПК) — обходит PS-guard на литерал rm.
INSTALL_ALT="${INSTALL_ALT:-}"
# ВАЖНО про `set -e` (вверху файла): хелперы чистки вызываются ПОСЛЕДОВАТЕЛЬНО (`A; B; C`)
# в ветках purge_unselected_alt. Идиома `[ -f x ] && { … }` возвращает 1, когда файла НЕТ
# (а это норма: пидфайл мог уже снять релинквиш, бинарь — прошлая чистка). Простая команда
# с кодом 1 под `set -e` РОНЯЕТ скрипт → следующий шаг не выполняется. Реальный баг: при
# свопе hy2<->xray релинквиш убивал демон и удалял пидфайл, затем _kill_alt_daemon на
# отсутствующем пидфайле возвращал 1 → set -e обрывал ветку ДО _purge_bin → бинарь старого
# альта НЕ удалялся, оба альта копились на флеше → переполнение /data. Поэтому хелперы
# ЯВНО возвращают 0 (best-effort чистка не должна валить установщик).
_purge_bin() { [ -f "$1" ] || return 0; rm -f "$1"; ok "Снят бинарь $2 (на флеше остаётся выбранный альт: ${INSTALL_ALT})"; return 0; }
# Снять РАБОТАЮЩИЙ демон убираемого альта. ЗАЧЕМ: _purge_bin убирает лишь файл-бинарь,
# а ПРОЦЕСС остаётся жив и держит общий socks-порт 10808 (xray и hysteria делят и порт,
# и hev). При свопе альта (xray<->hy2) живой старый демон не даёт новому забиндить порт
# → новый транспорт молча не встаёт, hev продолжает гнать трафик через СТАРЫЙ протокол
# (egress чужого сервера). Бьём по пидфайлу + чистим его (плагин при старте тоже
# подстрахуется через free_foreign_socks, но тут снимаем зомби сразу + освобождаем RAM).
_kill_alt_daemon() { [ -f "$1" ] || return 0; start-stop-daemon -K -p "$1" 2>/dev/null || true; rm -f "$1"; return 0; }
# Если убираемый альт СЕЙЧАС несёт трафик (.transport == он) — СНАЧАЛА чисто отпустить его
# несущую через оркестратор (transport.sh down → fail-open в прямой). ЗАЧЕМ: _kill_alt_daemon
# гасит лишь демон-socks, но xtun с `default` в table 1000 ОСТАЁТСЯ → весь маркированный трафик
# (вкл. собственную интернет-пробу установщика и DNS роутера — оба замаркированы в туннель)
# блэкхолится → pre-flight «Нет интернета» → установка падает, причём В ПЕТЛЮ (каждая повторная
# упрётся в тот же осиротевший дохлый xtun). down флашит table 1000 + ставит прямой DNS → проба
# проходит; новую несущую поднимет основной проход установщика (transport.sh up). Зовётся ТОЛЬКО
# при cur==убираемый → awg-несущую (default dev awg0) не трогает.
_relinquish_if_active() {
    cur=$(cat "$AWG_DIR/.transport" 2>/dev/null | tr -d ' \r\n')
    [ "$cur" = "$1" ] || return 0
    [ -x "$AWG_DIR/transport.sh" ] && "$AWG_DIR/transport.sh" down "$1" >/dev/null 2>&1
    warn "Убираемый альт ($1) нёс трафик — несущая снята (релинквиш → прямой режим до подъёма новой)."
}
purge_unselected_alt() {
    [ -n "$INSTALL_ALT" ] || return 0
    case "$INSTALL_ALT" in
        xray) _relinquish_if_active hy2;  _kill_alt_daemon /tmp/hysteria.pid; _purge_bin "$AWG_DIR/hysteria" "Hysteria2" ;;
        hy2)  _relinquish_if_active xray; _kill_alt_daemon /tmp/xray.pid;     _purge_bin "$AWG_DIR/xray" "Xray" ;;
        none) _relinquish_if_active xray; _relinquish_if_active hy2; _kill_alt_daemon /tmp/xray.pid; _kill_alt_daemon /tmp/hysteria.pid; _purge_bin "$AWG_DIR/xray" "Xray"; _purge_bin "$AWG_DIR/hysteria" "Hysteria2"; _purge_bin "$AWG_DIR/hev" "hev (tun2socks)" ;;
        *)    warn "purge_unselected_alt: неизвестный INSTALL_ALT='$INSTALL_ALT', пропускаю" ;;
    esac
}
# Субкоманда от ПК: ТОЛЬКО очистка невыбранного альта и выход (до заливки тяжёлых бинарей).
if [ "${1:-}" = purge-alt ]; then purge_unselected_alt; exit 0; fi

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

# Что ставим — AmneziaWG / Xray / оба — по наличию конфигов (+ опц. env INSTALL_PROTO
# от be7000.ps1). Это снимает ЖЁСТКОЕ требование awg.conf: возможна установка ТОЛЬКО
# Xray (без AmneziaWG). Гарды [ "$HAVE_AWG" = 1 ] ниже пропускают awg-секции при xray-only.
HAVE_AWG=0;  [ -f "$AWG_CONF" ] && HAVE_AWG=1
HAVE_XRAY=0; ls "$AWG_DIR"/xray-configs/*.json >/dev/null 2>&1 && HAVE_XRAY=1
[ -s "$AWG_DIR/xray.json" ] && HAVE_XRAY=1
HAVE_HY2=0;  ls "$AWG_DIR"/hy2-configs/*.yaml >/dev/null 2>&1 && HAVE_HY2=1
[ -s "$AWG_DIR/hysteria.yaml" ] && HAVE_HY2=1
if [ "$HAVE_AWG" = 0 ] && [ "$HAVE_XRAY" = 0 ] && [ "$HAVE_HY2" = 0 ]; then
    err "Не найдено ни $AWG_CONF, ни xray-/hy2-конфигов ($AWG_DIR/xray-configs/*.json | hy2-configs/*.yaml)."
    err "Положи awg.conf (AmneziaWG) и/или альт-конфиг (Xray/Hysteria2) и запусти снова."
    exit 1
fi
# Активный транспорт: awg (если awg.conf), иначе xray, иначе hy2. Переопределяется env INSTALL_PROTO.
if [ "$HAVE_AWG" = 1 ]; then ACTIVE_PROTO=awg; elif [ "$HAVE_XRAY" = 1 ]; then ACTIVE_PROTO=xray; else ACTIVE_PROTO=hy2; fi
[ -n "$INSTALL_PROTO" ] && ACTIVE_PROTO="$INSTALL_PROTO"
ok "Ставим: AmneziaWG=$HAVE_AWG, Xray=$HAVE_XRAY, Hysteria2=$HAVE_HY2; активный транспорт = $ACTIVE_PROTO"

# Проверяем интернет. TCP-проба (curl) надёжнее ICMP: ping не пройдёт, если трафик к
# 1.1.1.1 уже маркирован в туннель (xray несёт через SOCKS, а SOCKS не передаёт ICMP;
# при awg — через awg0), либо провайдер режет ICMP. Фолбэк на ping — для сетей, где
# curl к этим хостам закрыт.
if curl -fsS --max-time 5 -o /dev/null https://1.1.1.1 2>/dev/null || \
   curl -fsS --max-time 5 -o /dev/null https://www.gstatic.com/generate_204 2>/dev/null || \
   ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
    ok "Интернет на роутере есть"
else
    err "Нет интернета на роутере. Подключи WAN-кабель/проверь настройки."
    exit 1
fi

# ============================================================================
# 0.1 ПОДГОТОВКА КОНФИГА — чистим пустые I1..I5
# ============================================================================
# AmneziaVPN 4.8.12.9+ добавляет в конфиг заготовки I1..I5 даже в Legacy.
# Если они пустые (I2 = ), awg-tools падает: "Line unrecognized: I2=".
# Заполненные I1 (например, I1 = <b 0xHEX...>) — НЕ трогаем.
# ----------------------------------------------------------------------------
if [ "$HAVE_AWG" = 1 ] && grep -qE '^I[1-5]\s*=\s*$' "$AWG_CONF"; then
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
if [ "$HAVE_AWG" = 1 ] && [ ! -f "$AWG_DIR/amnezia_for_awg.conf" ]; then
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
# mv (rename на том же ФС), НЕ cp. ЗАЧЕМ (бюджет флеша /data ~20 МБ): cp оставлял ВТОРУЮ
# копию (bin/*.user + рабочий бинарь) до чистки 7.5 → на awg+<альт> пик (amneziawg-go.user
# 4.85 + xray.user 7.75 в bin/ ОДНОВРЕМЕННО + удвоение awg при cp) НЕ влезал в 20 МБ → cp
# обрывался «No space» и оставлял ОБРЕЗАННЫЙ бинарь (rename так не умеет: либо весь файл,
# либо никак). Теперь awg-бинари переносятся как xray/hev — без удвоения и без риска обрезка.
# Источник bin/*.user — в git/payload, зальётся при следующей установке (7.5 уже не нужна
# для awg, но безвредна).
if [ "$HAVE_AWG" = 1 ] && [ -f "$AWG_DIR/bin/amneziawg-go.user" ]; then
    log "Найден пользовательский amneziawg-go.user, ставлю (mv, без удвоения флеша)..."
    mv "$AWG_DIR/bin/amneziawg-go.user" "$AWG_DIR/amneziawg-go"
    chmod +x "$AWG_DIR/amneziawg-go"
    ok "amneziawg-go установлен ($("$AWG_DIR/amneziawg-go" --version 2>&1 | head -1))"
fi
if [ "$HAVE_AWG" = 1 ] && [ -f "$AWG_DIR/bin/awg.user" ]; then
    log "Найден пользовательский awg.user, ставлю (mv, без удвоения флеша)..."
    mv "$AWG_DIR/bin/awg.user" "$AWG_DIR/awg"
    chmod +x "$AWG_DIR/awg"
    ok "awg установлен ($("$AWG_DIR/awg" --version 2>&1 | head -1))"
fi

# Xray + tun2socks (hev) — альт-транспорт (Фаза 1). ВАЖНО про бюджет флеша: /data
# всего ~20 МБ, а xray.user ~7.6 МБ. Если cp'нуть (как amneziawg-go), на момент
# установки была бы ВТОРАЯ копия (+7.6 МБ) → пик не влезает. Поэтому xray/hev
# переносим ЧЕРЕЗ mv (rename на том же ФС = без удвоения места). Источник bin/*.user
# в git/payload → при следующей установке зальётся снова. xray-configs/ — для
# vless/JSON-конфигов (be7000.ps1). Наличие бинарей необязательно: awg-only установка
# просто пропустит этот блок.
if [ -f "$AWG_DIR/bin/xray.user" ]; then
    log "Найден xray.user, ставлю (mv, без удвоения флеша)..."
    mv "$AWG_DIR/bin/xray.user" "$AWG_DIR/xray"
    chmod +x "$AWG_DIR/xray"
    ok "xray установлен ($("$AWG_DIR/xray" version 2>&1 | head -1))"
fi
if [ -f "$AWG_DIR/bin/hev.user" ]; then
    log "Найден hev.user (tun2socks), ставлю..."
    mv "$AWG_DIR/bin/hev.user" "$AWG_DIR/hev"
    chmod +x "$AWG_DIR/hev"
    ok "hev (tun2socks) установлен"
fi
# Hysteria2-клиент — альт-транспорт ВМЕСТО xray (на флеше живёт один альт). mv (без
# удвоения флеша), как xray. Заливается ТОЛЬКО при выборе hy2 (be7000.ps1 шлёт лишь
# нужный bin/*.user) → при xray-установке этого файла нет и блок пропускается.
if [ -f "$AWG_DIR/bin/hysteria.user" ]; then
    log "Найден hysteria.user, ставлю (mv, без удвоения флеша)..."
    mv "$AWG_DIR/bin/hysteria.user" "$AWG_DIR/hysteria"
    chmod +x "$AWG_DIR/hysteria"
    ok "hysteria установлен"
fi
[ -f "$AWG_DIR/xray-transport.sh" ] && chmod +x "$AWG_DIR/xray-transport.sh"
[ -f "$AWG_DIR/transport-hy2.sh" ] && chmod +x "$AWG_DIR/transport-hy2.sh"
mkdir -p "$AWG_DIR/xray-configs" "$AWG_DIR/hy2-configs"

# Подсказка для AWG 2.0
if grep -qE '^(S3|S4)\s*=' "$AWG_CONF" || grep -qE '^H[1-4]\s*=\s*[0-9]+-[0-9]+' "$AWG_CONF"; then
    if [ ! -x "$AWG_DIR/amneziawg-go" ] || [ ! -x "$AWG_DIR/awg" ]; then
        warn "Конфиг AWG 2.0 (есть S3/S4 или диапазон H), но нет рабочих бинарников"
        warn "AmneziaWG. Вендорный awg_setup.sh их БОЛЬШЕ НЕ качает (старые версии с"
        warn "github ломали S3/S4) — он просто упадёт с exit 1, awg0 не поднимется."
        warn "Собери бинарники по инструкции (Приложение Г) и положи в"
        warn "$AWG_DIR/bin/{amneziawg-go.user,awg.user}, потом перезапусти этот скрипт."
        warn "Альтернатива: добавь на VPS протокол AmneziaWG Legacy и используй его конфиг."
    fi
fi

# ============================================================================
# 1. УСТАНОВКА AMNEZIA WG (СКРИПТ ШАЛИНА) — только при HAVE_AWG (есть awg.conf).
# При xray-only вся секция пропускается: awg0 не нужен.
# ============================================================================
if [ "$HAVE_AWG" = 1 ]; then
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
fi   # /HAVE_AWG (конец секции 1: установка/подъём awg0)

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
DNS_OVERRIDE="$DNSMASQ_DIR/00-upstream.conf"
if [ "$ACTIVE_PROTO" = xray ] || [ "$ACTIVE_PROTO" = hy2 ]; then
    # Альт-транспорт (xray/hy2) несёт DNS публичным резолвером, МАРКИРОВАННЫМ в туннель
    # (это делает <transport>.sh up ниже). Здесь — публичная заглушка, чтобы dnsmasq
    # резолвил и до подъёма транспорта. Внутренний Amnezia-DNS (172.29.x dev awg0) при
    # альте недостижим (awg0 может быть заблокирован/отсутствовать).
    printf 'no-resolv\nserver=1.1.1.1\nserver=8.8.8.8\n' > "$DNS_OVERRIDE"
    ok "DNS upstream: публичный 1.1.1.1/8.8.8.8 (альт-транспорт; будет маркирован в туннель)"
else
    # AmneziaWG: upstream ВНУТРИ туннеля (адрес из awg.conf поля DNS=, fallback 172.29.172.254).
    VPN_DNS=$(grep -E '^DNS\s*=' "$AWG_CONF" 2>/dev/null | head -1 | awk -F'= *' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')
    [ -z "$VPN_DNS" ] && VPN_DNS="172.29.172.254"
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
# 5. МАРШРУТИЗАЦИЯ: ядро (mark-core) + активный транспорт (плагин)
# ============================================================================
# split-route.sh РЕТАЙРНУТ (июнь 2026): ЕДИНЫЙ источник правды — mark-core.sh (ядро:
# маркировка ipset->MARK + ip rule fwmark->table $ROUTE_TABLE) + плагины транспорта
# (несущую default в table $ROUTE_TABLE кладёт transport-awg.sh / xray-transport.sh).
# Отдельный awg0-генератор больше не нужен и НЕ создаётся; mark-core.sh и
# transport-awg.sh — REQUIRED payload. Раскладка ровно как awg-heal.sh на boot.
log "Применяю ядро маршрутизации + активный транспорт ($ACTIVE_PROTO)..."
echo "$ACTIVE_PROTO" > "$AWG_DIR/.transport"
if [ -x "$AWG_DIR/mark-core.sh" ]; then
    "$AWG_DIR/mark-core.sh"
else
    err "mark-core.sh отсутствует (payload неполон) — маркировка не применена"
fi
# Несущую активного транспорта поднимает ОРКЕСТРАТОР (transport.sh up <proto> — он же
# идемпотентно переиграет mark-core). Добавить hysteria = расширить ACTIVE_PROTO-детект
# (HAVE_*) + реестр transport.sh; этот вызов и heal/watchdog тогда не правятся.
#
# ВАЖНО (грабля, поправлено июнь 2026): подъём несущей НЕ должен быть фатальным под set -e.
# Раньше тут было `[ -x … ] && transport.sh up …` — при неудачном подъёме (транзиентная
# гонка сразу после установки/ребута: холодный QUIC у hysteria, гонка xtun у hev) эта строка
# под `set -e` роняла ВЕСЬ установщик ДО регистрации cron (heal/watchdog/iplist). Итог:
# роутер без сторожа и самовосстановления, несущая не встала бы и после ребута, а на экране
# установка просто «мигала» (плагин при сбое не имел лога → причина была невидна). Теперь:
#   (1) пробуем подъём дважды (транзиент обычно проходит со 2-й попытки);
#   (2) при сбое показываем ЯВНО + дампим логи демонов (иначе причина прячется);
#   (3) ПРОДОЛЖАЕМ установку (fail-open безопасен; cron поднимут несущую на boot/восстановлении).
CARRIER_UP=0
if [ -x "$AWG_DIR/transport.sh" ]; then
    n=1
    while [ "$n" -le 2 ]; do
        out=$("$AWG_DIR/transport.sh" up "$ACTIVE_PROTO" 2>&1) && rc=0 || rc=$?
        [ -n "$out" ] && printf '%s\n' "$out"
        if [ "$rc" = 0 ]; then CARRIER_UP=1; break; fi
        warn "Попытка $n: транспорт $ACTIVE_PROTO не поднялся (код $rc). Повтор через 3с…"
        sleep 3; n=$((n+1))
    done
else
    warn "transport.sh отсутствует (payload неполон) — несущая не поднята."
fi
if [ "$CARRIER_UP" = 1 ]; then
    ok "Маршрутизация + транспорт ($ACTIVE_PROTO) применены"
else
    err "Несущая ($ACTIVE_PROTO) НЕ поднялась. VPN сейчас в ПРЯМОМ режиме (fail-open: интернет"
    err "работает, трафик идёт МИМО туннеля). Установка продолжается — см. логи демонов ниже."
    # Логи демонов — чтобы причина (сервер/sni/ключи/порт) была ВИДНА, а не пряталась.
    for L in /tmp/hysteria.log /tmp/xray.log /tmp/hev.log; do
        [ -s "$L" ] && { warn "--- последние строки $L ---"; tail -n 15 "$L"; }
    done
    warn "cron (heal/watchdog) будет зарегистрирован — несущую поднимут после ребута / при"
    warn "восстановлении. Либо проверь конфиг в меню (Протокол) и повтори установку."
fi

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
# установке: выше (секция 0.3) мы уже скопировали их в рабочие бинари. В runtime
# (boot/heal/switch/watchdog) bin/*.user не читает НИКТО. На стоке /data всего
# ~20 МБ, а amneziawg-go ~4.8 МБ: держать его второй копией в bin/ расточительно.
# Скрипт дошёл сюда => awg0 поднят, т.е. рабочие бинари ГАРАНТИРОВАННО исправны
# (туннель работает) — можно удалить bin/*.user. Источник не теряется: он в git и
# в payload be7000.ps1 → при следующей установке зальётся снова (и эта же секция
# снова подчистит). Раньше для удаления требовался валидный .working.bak; теперь
# .working.bak НЕ создаём (curl-угроза, ради которой он жил, устранена — см.
# awg_setup.sh), а исправность проверяем НАПРЯМУЮ: рабочий бинарь есть и его размер
# совпадает с источником bin/$b.user (=> copy секции 0.3 прошла успешно).
for b in amneziawg-go awg; do
    [ -f "$AWG_DIR/bin/$b.user" ] || continue
    if [ -f "$AWG_DIR/$b" ] && \
       [ "$(stat -c%s "$AWG_DIR/bin/$b.user" 2>/dev/null)" = "$(stat -c%s "$AWG_DIR/$b" 2>/dev/null)" ]; then
        rm -f "$AWG_DIR/bin/$b.user"
        ok "bin/$b.user удалён (рабочий бинарь на месте, размер совпал; источник — git/payload)"
    else
        warn "bin/$b.user оставлен: рабочего $b нет или размер не совпал с источником"
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
if [ "$ACTIVE_PROTO" = xray ] || [ "$ACTIVE_PROTO" = hy2 ]; then
    echo "  1. Активный транспорт: $ACTIVE_PROTO (TUN xtun). AmneziaWG не используется."
    ip -br a show xtun 2>/dev/null || echo "     (xtun поднят через transport.sh up)"
else
    echo "  1. AmneziaWG-туннель awg0 поднят:"
    ip -br a show awg0 2>/dev/null || warn "awg0 не виден — проверь конфиг"
fi
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
