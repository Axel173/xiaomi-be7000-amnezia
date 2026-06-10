#!/bin/sh
#
# domain.sh — управление списком доменов, идущих через AWG-туннель
#
# Использование:
#   domain.sh add <домен>       — добавить домен в туннель
#   domain.sh remove <домен>    — убрать домен из туннеля
#   domain.sh list              — показать пользовательские добавления
#   domain.sh search <строка>   — найти, есть ли строка в любом списке
#   domain.sh reload            — перечитать все списки (после ручной правки)
#
# Примеры:
#   domain.sh add chatgpt.com
#   domain.sh add youtube.com
#   domain.sh add my-private-site.net
#   domain.sh remove instagram.com
#   domain.sh search openai
#
# Где живут списки:
#   /etc/dnsmasq.d/awg-domains.conf  — большой список re-filter (обновляется
#                                        автоматически кроном, не трогать!)
#   /etc/dnsmasq.d/awg-custom.conf   — твой ручной список (этим файлом
#                                        управляет этот скрипт)
#
# Версия 1.0 / май 2026

DNSMASQ_DIR="/etc/dnsmasq.d"
CUSTOM_FILE="$DNSMASQ_DIR/awg-custom.conf"
MAIN_FILE="$DNSMASQ_DIR/awg-domains.conf"
IPSET_NAME="awg_list"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

mkdir -p "$DNSMASQ_DIR"
[ ! -f "$CUSTOM_FILE" ] && {
    echo "# Пользовательские домены, идущие через AWG-туннель." > "$CUSTOM_FILE"
    echo "# Управляется через domain.sh. Можно редактировать руками." >> "$CUSTOM_FILE"
    echo "" >> "$CUSTOM_FILE"
}

reload_dnsmasq() {
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || killall -HUP dnsmasq 2>/dev/null
    # Также сбросим ipset, чтобы старые подмены не висели
    ipset flush "$IPSET_NAME" 2>/dev/null
}

case "$1" in
    add)
        domain="$2"
        if [ -z "$domain" ]; then
            printf "${RED}Укажи домен:${NC} domain.sh add chatgpt.com\n"
            exit 1
        fi
        # Убираем www., http://, https://, всё лишнее
        domain=$(echo "$domain" | sed -E 's|^https?://||; s|^www\.||; s|/.*$||')
        # Проверяем — есть ли уже
        if grep -q "ipset=/$domain/" "$CUSTOM_FILE" 2>/dev/null; then
            printf "${YELLOW}Домен %s уже в пользовательском списке.${NC}\n" "$domain"
            exit 0
        fi
        # Проверим в основном списке тоже (информационно)
        if grep -q "/$domain/" "$MAIN_FILE" 2>/dev/null; then
            printf "${BLUE}Кстати, %s уже есть в основном re-filter списке.${NC}\n" "$domain"
            printf "${BLUE}Но всё равно добавлю в твой пользовательский — на всякий.${NC}\n"
        fi
        echo "ipset=/$domain/$IPSET_NAME" >> "$CUSTOM_FILE"
        reload_dnsmasq
        printf "${GREEN}[ + ]${NC} %s добавлен в туннель.\n" "$domain"
        printf "Открой сайт в браузере — его IP попадут в ipset awg_list.\n"
        ;;

    remove|rm|del)
        domain="$2"
        if [ -z "$domain" ]; then
            printf "${RED}Укажи домен:${NC} domain.sh remove instagram.com\n"
            exit 1
        fi
        domain=$(echo "$domain" | sed -E 's|^https?://||; s|^www\.||; s|/.*$||')
        # Убираем строку
        if grep -q "ipset=/$domain/" "$CUSTOM_FILE" 2>/dev/null; then
            sed -i "/^ipset=\/$domain\/.*/d" "$CUSTOM_FILE"
            reload_dnsmasq
            printf "${GREEN}[ - ]${NC} %s убран из пользовательского списка.\n" "$domain"
        else
            printf "${YELLOW}%s не было в пользовательском списке.${NC}\n" "$domain"
            if grep -q "/$domain/" "$MAIN_FILE" 2>/dev/null; then
                printf "${YELLOW}Но он есть в основном re-filter — он туда автоматом${NC}\n"
                printf "${YELLOW}возвращается при обновлении. Чтобы убрать насовсем,${NC}\n"
                printf "${YELLOW}нужно добавить домен в исключения (см. ниже).${NC}\n"
                printf "\n"
                printf "Сделать исключение (домен ВСЕГДА идёт напрямую):\n"
                printf "  echo \"server=/%s/#\" >> %s/awg-exclude.conf\n" "$domain" "$DNSMASQ_DIR"
                printf "  /etc/init.d/dnsmasq restart\n"
            fi
        fi
        ;;

    list|ls)
        printf "${BLUE}Твои домены (через AWG):${NC}\n"
        if [ -s "$CUSTOM_FILE" ]; then
            grep "^ipset=" "$CUSTOM_FILE" | sed -E 's|ipset=/([^/]+)/.*|  \1|'
        else
            printf "  ${YELLOW}(пусто, используется только основной re-filter)${NC}\n"
        fi
        echo ""
        # ВАЖНО про grep -c без '|| echo 0': busybox grep -c при НУЛЕ совпадений
        # печатает "0" И выходит с кодом 1. Старое '... || echo 0' тогда дописывало
        # ВТОРОЙ "0" → значение становилось "0\n0" → busybox printf '%d' ругался
        # "invalid number '0\n0'" и возвращал код 1, а вызывающий be7000.ps1
        # принимал это за ошибку SSH и рисовал ложный [FAIL]. grep -c и так всегда
        # выводит число — берём как есть, ${var:-0} лишь страхует пустой вывод.
        if [ -f "$MAIN_FILE" ]; then
            main_count=$(grep -c "^ipset=" "$MAIN_FILE" 2>/dev/null)
            printf "${BLUE}Основной re-filter:${NC} %s правил\n" "${main_count:-0}"
            printf "  (обновляется ежедневно в 5:00, файл $MAIN_FILE)\n"
        fi
        ipset_cnt=$(ipset list "$IPSET_NAME" 2>/dev/null | grep -c '^[0-9]')
        printf "${BLUE}Сейчас в ipset (резолвлено IP):${NC} %d записей\n" "${ipset_cnt:-0}"
        ;;

    search|find|grep)
        needle="$2"
        if [ -z "$needle" ]; then
            printf "${RED}Укажи что искать:${NC} domain.sh search openai\n"
            exit 1
        fi
        printf "${BLUE}Поиск '%s' в всех списках:${NC}\n" "$needle"
        echo ""
        # ВАЖНО: busybox grep НЕ знает '--color' (v1.25.1: "unrecognized option:
        # color") — старый 'grep -i --color' молча падал, 2>/dev/null глушил ошибку,
        # и поиск ВСЕГДА возвращал пусто. Убрали --color. И берём вывод grep в
        # переменную: раньше 'grep | sed || echo "(нет)"' никогда не печатал "(нет)",
        # т.к. код выхода пайпа = код sed (0), даже когда grep ничего не нашёл.
        echo "В твоём списке (awg-custom.conf):"
        res=$(grep -i "$needle" "$CUSTOM_FILE" 2>/dev/null)
        if [ -n "$res" ]; then printf '%s\n' "$res" | sed 's/^/  /'; else echo "  (нет)"; fi
        echo ""
        echo "В основном re-filter (awg-domains.conf):"
        res=$(grep -i "$needle" "$MAIN_FILE" 2>/dev/null | head -20)
        if [ -n "$res" ]; then printf '%s\n' "$res" | sed 's/^/  /'; else echo "  (нет)"; fi
        echo ""
        # И покажем сразу, какие IP в ipset из этих доменов
        echo "Текущие IP в ipset:"
        ipset list "$IPSET_NAME" 2>/dev/null | grep -E '^[0-9]' | head -10 | sed 's/^/  /'
        ;;

    reload)
        reload_dnsmasq
        printf "${GREEN}[ OK ]${NC} dnsmasq перечитан, ipset сброшен.\n"
        printf "Новые IP подъедут при следующих DNS-запросах с клиентов.\n"
        ;;

    *)
        cat <<EOF
Управление списком доменов, идущих через AWG-туннель:

  domain.sh add <домен>       — добавить домен в туннель
  domain.sh remove <домен>    — убрать домен из пользовательского списка
  domain.sh list              — показать все твои добавления + статистику
  domain.sh search <строка>   — найти строку во всех списках
  domain.sh reload            — перезагрузить dnsmasq после ручной правки

Примеры:
  domain.sh add chatgpt.com
  domain.sh add my-personal-site.net
  domain.sh remove instagram.com
  domain.sh search youtube
EOF
        ;;
esac
