# ============================================================
# BE7000 — AmneziaWG: установка + управление (монолит be7000.ps1)
# ============================================================
# Объединяет установщик (бывш. installer/amnezia-install.ps1) и меню
# управления (бывш. vpn-toggle.ps1). На старте детектит, установлен ли AWG:
# нет -> предлагает установку; есть -> меню управления. -Install/-Manage
# форсируют режим. Payload берётся из репо ($SCRIPT_DIR): .sh из корня, бинари из bin/.
# ============================================================
# Тонкое меню поверх SSH — всё реальное действие делают
# серверные скрипты на роутере (switch-vpn.sh / domain.sh /
# awg-status.sh / vpn-toggle.sh). Этот файл их только дёргает.
#
# Что чинит v2:
#   * НЕ использует переменную $pwd — это автоматическая
#     read-only переменная PowerShell (текущий путь). Из-за неё
#     v1 падал на любом действии: "Cannot overwrite variable PWD".
#     ТА ЖЕ ГРАБЛЯ с $home (= домашний каталог): при
#     $ErrorActionPreference="Stop" присваивание роняет весь скрипт.
#     НЕ присваивай имена автопеременных: $home/$pwd/$host/$input/
#     $args/$matches/$error/$this (для «основного» конфига — $homeCfg).
#   * Не передаёт многострочные heredoc через plink (хрупко).
#     Каждая команда — одна строка, склейка через ';'.
#   * Делегирует логику серверным скриптам => поведение
#     совпадает с тем, что ты делаешь с PuTTY.
# ============================================================

param(
    [switch]$Install,   # форсировать ветку установки (в обход детекта)
    [switch]$Manage,    # форсировать меню управления (в обход детекта)
    # Файлы, перетащенные мышью НА be7000.bat: .bat форвардит их в %*, Windows
    # передаёт абсолютными путями -> ValueFromRemainingArguments собирает их сюда.
    # Пусто при обычном запуске. Обрабатываются перед меню (мульти-заливка конфигов).
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$DropFiles
)

# Версия PC-стороны проекта. Бампать при заметных изменениях; см. CHANGELOG.md.
$script:ProjectVersion = '0.3.0'

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$script:RouterExitCode = 0   # код выхода последней SSH-команды (ставит Invoke-Router)

# --- Настройки ---
$ROUTER_IP   = "192.168.31.1"
$ROUTER_USER = "root"
$LAN_SUBNET  = "192.168.31."
$AWG_DIR     = "/data/usr/app/awg"
$CRED_DIR    = Join-Path $env:APPDATA "vpn-toggle"
$CRED_FILE   = Join-Path $CRED_DIR "cred.dat"
$SCRIPT_DIR  = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$BACKUP_DIR  = Join-Path $SCRIPT_DIR "backups"

# Payload для установки (заливается на роутер по pscp -scp). Лежит в корне репо
# = $SCRIPT_DIR. awg.conf (секрет) и configs/ кладёт пользователь в корень
# (оба в .gitignore). awg_setup.sh вендорится (см. Q2).
$REQUIRED_FILES = @(
    "awg.conf",
    "awg-setup-be7000.sh",
    "awg_setup.sh",
    "awg-heal.sh",
    "switch-vpn.sh",
    "domain.sh",
    "awg-status.sh",
    "iplist-update.sh",
    "mark-core.sh",
    "transport-awg.sh",
    "transport.sh"
)
$OPTIONAL_FILES = @(
    "vpn-toggle.sh",
    "awg-watchdog.sh",
    "notify.sh",
    "notify-event.sh",
    "notify.conf.example",
    "iplist.conf.example",
    "xiaomi-bypass.sh",
    "apply-bypass.sh",
    "awg-dump.sh",
    "xray-transport.sh",
    "transport-hy2.sh",
    "hev.yaml"
)
$BIN_FILES = @{
    "amneziawg-go.user" = "bin/amneziawg-go.user"
    "awg.user"          = "bin/awg.user"
    "xray.user"         = "bin/xray.user"
    "hev.user"          = "bin/hev.user"
    "hysteria.user"     = "bin/hysteria.user"
}

# ============================================================
# Утилиты вывода
# ============================================================
function Write-Section($text) {
    Write-Host ""
    Write-Host "=== $text ===" -ForegroundColor Cyan
}
function Write-Ok($text)   { Write-Host "[ OK ] $text" -ForegroundColor Green }
function Write-Warn($text) { Write-Host "[WARN] $text" -ForegroundColor Yellow }
function Write-Err($text)  { Write-Host "[FAIL] $text" -ForegroundColor Red }
function Write-Info($text) { Write-Host "[INFO] $text" -ForegroundColor DarkGray }

# Меню управления длинное (~65 строк), а консоль по умолчанию ~25-30 → при старте
# шапка уезжает вверх. Пробуем УВЕЛИЧИТЬ высоту окна (в пределах того, что влезает
# на экран — MaxWindowSize). Best-effort: в Windows Terminal API резайза часто
# игнорируется, на низком экране упрёмся в максимум — тогда меню всё равно работает,
# просто длинновато. Всё в try/catch — резайз не должен ничего ломать.
function Try-GrowConsole {
    param([int]$Rows = 62)
    try {
        $ui = $Host.UI.RawUI
        if (-not $ui -or -not $ui.MaxWindowSize) { return }
        $want = [Math]::Min($Rows, $ui.MaxWindowSize.Height)
        $cur  = $ui.WindowSize
        if ($want -le $cur.Height) { return }                 # уже достаточно высоко
        $buf = $ui.BufferSize                                  # окно не может быть выше буфера
        if ($buf.Height -lt $want) { $buf.Height = $want; $ui.BufferSize = $buf }
        $cur.Height = $want
        $ui.WindowSize = $cur
    } catch { }
}

# ============================================================
# plink/pscp + пароль
# (Find-Tool/Find-Plink/Find-Pscp определены в секции установки ниже)
# ============================================================

function Save-Password {
    Write-Host ""
    $secure = Read-Host "Введи пароль root от роутера (символы не будут видны)" -AsSecureString
    if ($secure.Length -eq 0) { Write-Err "Пустой пароль — отмена"; return $false }
    $enc = ConvertFrom-SecureString $secure
    if (-not (Test-Path $CRED_DIR)) { New-Item -ItemType Directory -Path $CRED_DIR -Force | Out-Null }
    Set-Content -Path $CRED_FILE -Value $enc -Encoding ASCII
    Write-Ok "Пароль сохранён (DPAPI, $CRED_FILE)"
    return $true
}

function Get-StoredPassword {
    if (-not (Test-Path $CRED_FILE)) { return $null }
    try {
        $enc = Get-Content $CRED_FILE -Raw
        $secure = ConvertTo-SecureString $enc.Trim()
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try   { return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    } catch {
        Write-Warn "Не удалось прочитать сохранённый пароль: $($_.Exception.Message)"
        return $null
    }
}

function Clear-PuttyHostKey {
    # Удаляет кешированный SSH host key роутера из реестра PuTTY
    # (HKCU\Software\SimonTatham\PuTTY\SshHostKeys). Нужно при смене ключа
    # на роутере (после ребута/перепрошивки), иначе plink -batch падает с
    # "host key does not match" и "POTENTIAL SECURITY BREACH". Записи там
    # имеют вид "ssh-ed25519@22:192.168.31.1" / "ssh-rsa@22:192.168.31.1".
    param([string]$RouterHost, [int]$Port = 22)
    $regPath = "HKCU:\Software\SimonTatham\PuTTY\SshHostKeys"
    if (-not (Test-Path $regPath)) { return $false }
    $key = Get-Item -Path $regPath -ErrorAction SilentlyContinue
    if (-not $key) { return $false }
    $suffix = "@${Port}:$RouterHost"
    $cleared = $false
    foreach ($name in $key.Property) {
        if ($name -like "*$suffix") {
            Remove-ItemProperty -Path $regPath -Name $name -ErrorAction SilentlyContinue
            $cleared = $true
        }
    }
    return $cleared
}

function Get-MyLANIP {
    $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -like "$LAN_SUBNET*" } |
        Select-Object -First 1 -ExpandProperty IPAddress
    if ($ip) { return $ip }
    $route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Sort-Object -Property RouteMetric | Select-Object -First 1
    if ($route) {
        $ip = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty IPAddress
        if ($ip) { return $ip }
    }
    return $null
}

# ============================================================
# SSH-вызов одной командой (без heredoc!)
# ============================================================
function Invoke-Router {
    param([string]$Command, [switch]$Silent, [string]$StdinData)

    # КРИТИЧНО: файл .ps1 в CRLF (того требует BOM/PowerShell 5 на ру-Windows), и
    # here-string '@"..."@' тащит CRLF ВНУТРЬ команды. На busybox/ash каждый '\r'
    # прилипает к значению: 'mkdir -p /tmp/awg-bk-...\r' создаёт каталог с CR в
    # имени, дальше '$DIR/file' его уже не находит -> "nonexistent directory" (так
    # падал New-Backup при uninstall). Шлём на роутер ТОЛЬКО LF. $StdinData не
    # трогаем — там base64 (CR-безопасен) и его правят на месте вызова.
    if ($Command) { $Command = $Command -replace "`r", "" }

    $plinkExe = Find-Plink
    if (-not $plinkExe) {
        Write-Err "Не найден plink.exe. Установи PuTTY (см. README, Шаг 2) или скачай plink с https://www.putty.org/"
        return $null
    }
    $rootPwd = Get-StoredPassword     # ВАЖНО: не $pwd!
    if (-not $rootPwd) {
        Write-Warn "Пароль ещё не сохранён, давай сохраним"
        if (-not (Save-Password)) { return $null }
        $rootPwd = Get-StoredPassword
    }

    # Дефолтный stdin "y`n" — автоответ "y" на возможные prompt'ы удалённой
    # команды (переопределяется параметром -StdinData; см. $normalIn/$retryIn ниже).
    # На сам plink-prompt о host key это не действует — его глушит -batch
    # (и при изменении ключа plink из-за -batch как раз и падает; см. ниже
    # обработку $hostKeyIssue).
    # -batch выключает интерактивные prompts (никаких зависаний).
    # Временно снимаем ErrorActionPreference = Stop: иначе stderr от plink
    # (например, ругань шелла на роутере) поднимается как RemoteException
    # и убивает скрипт. Нам же нужно просто показать stderr пользователю.
    $target = "$ROUTER_USER@$ROUTER_IP"
    # Если задан -StdinData (например base64 файла под 'base64 -d' на роутере) —
    # шлём РОВНО его, без лишнего "y" (иначе данные испортятся). В retry-ветке
    # (host key сменился, -batch снят) "y\n" нужно ПЕРВОЙ строкой для приёма
    # нового ключа, а уже затем — полезный stdin.
    $useStdin = $PSBoundParameters.ContainsKey('StdinData')
    $normalIn = if ($useStdin) { $StdinData } else { "y`n" }
    $retryIn  = if ($useStdin) { "y`n" + $StdinData } else { "y`ny`n" }
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = $normalIn | & $plinkExe -ssh -batch -pw $rootPwd $target $Command 2>&1
        $code = $LASTEXITCODE

        # Лечим типичную ситуацию "после перезагрузки роутера батник падает,
        # помогает только ручной заход через PuTTY". Причина: SSH host key
        # роутера сменился (ребут/перепрошивка/новый dropbear), а в реестре
        # PuTTY лежит старый. plink -batch принципиально не умеет принимать
        # изменения ключа — отсюда "POTENTIAL SECURITY BREACH" + код 1.
        # Лечим автоматически: удаляем старую запись из реестра и переход­им
        # на повторный вызов БЕЗ -batch со "y" в stdin — plink проглотит "y"
        # на prompt о принятии нового ключа и сохранит его в реестр. На след.
        # запусках уже сработает быстрая -batch ветка.
        $hkText = "$output"
        $hostKeyIssue = (
            $hkText -match "host key does not match" -or
            $hkText -match "POTENTIAL SECURITY BREACH" -or
            $hkText -match "Cannot confirm a host key in batch mode" -or
            $hkText -match "server's host key is not cached"
        )
        if ($code -ne 0 -and $hostKeyIssue) {
            Write-Warn "SSH host key роутера изменился (или первое подключение). Принимаю новый ключ автоматически."
            if (Clear-PuttyHostKey -RouterHost $ROUTER_IP -Port 22) {
                Write-Host "Старый кешированный ключ удалён из реестра PuTTY." -ForegroundColor DarkGray
            }
            $output = $retryIn | & $plinkExe -ssh -pw $rootPwd $target $Command 2>&1
            $code = $LASTEXITCODE
            if ($code -eq 0) {
                Write-Ok "Новый host key принят и сохранён в реестр PuTTY."
            }
        }
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    if ($code -ne 0 -and -not $Silent) {
        Write-Err "SSH вернул код $code"
        if ($output) { Write-Host ($output -join "`n") -ForegroundColor DarkGray }
        if ("$output" -match "password|denied|unable to authenticate|Wrong passphrase") {
            Write-Warn "Похоже, пароль не подходит. Пересохранить?"
            $ans = Read-Host "y/N"
            if ($ans -eq "y" -or $ans -eq "Y") { Save-Password }
        }
    }
    $script:RouterExitCode = $code
    return $output
}

# ============================================================
# Действия
# ============================================================

function Action-Status {
    Write-Section "Полный статус (awg-status.sh)"
    $myIp = Get-MyLANIP
    Write-Host "Этот ПК в LAN: $myIp" -ForegroundColor DarkGray
    # На роутере awg-setup-be7000.sh создаёт симлинк /usr/bin/awg -> awg-status.sh.
    # Если симлинка нет — запускаем напрямую. На всякий случай поддерживаем
    # /usr/sbin/, /usr/bin/, /opt/sbin/ и оба пути установки.
    $cmd = "if command -v awg >/dev/null 2>&1; then awg; " +
           "elif [ -f /data/usr/app/awg/awg-status.sh ]; then sh /data/usr/app/awg/awg-status.sh; " +
           "elif [ -f /usr/sbin/awg-status.sh ]; then sh /usr/sbin/awg-status.sh; " +
           "else echo 'awg-status.sh не найден; проверь: ls -la /data/usr/app/awg/'; fi"
    $out = Invoke-Router -Command $cmd
    if ($out) { Write-Host ($out -join "`n") }

    # Состояние watchdog'а и уведомлений
    $wcmd = "printf 'Режим watchdog: '; cat /tmp/awg-watchdog.state 2>/dev/null || echo 'NORMAL'; " +
            "printf 'Уведомления: '; [ -f $AWG_DIR/.notify-off ] && echo 'ВЫКЛ' || echo 'ВКЛ'; " +
            "printf 'Watchdog в cron: '; grep -q awg-watchdog /etc/crontabs/root && echo 'да' || echo 'НЕТ'; " +
            "printf 'Failover (режим): '; cat $AWG_DIR/.failover-mode 2>/dev/null || echo sticky; " +
            "printf 'Failover home: '; cat $AWG_DIR/.failover-home 2>/dev/null || echo '?'; " +
            "printf 'Failover эскалация: '; cat $AWG_DIR/.failover-escalate 2>/dev/null || echo cross; " +
            "printf 'Домашний транспорт: '; cat $AWG_DIR/.transport-home 2>/dev/null || echo '(не задан)'"
    $w = Invoke-Router -Command $wcmd -Silent
    Write-Host ""
    Write-Host "--- Watchdog / уведомления ---" -ForegroundColor Cyan
    Write-Host ($w -join "`n")
}

function Action-WifiStatus {
    # READ-ONLY: ничего не меняет на роутере, только показывает текущее состояние
    # беспроводных интерфейсов и подсетей guest/iot. Нужно, чтобы корректно сделать
    # дальнейшие пункты (5ГГц-only / вынос подсети мимо VPN) под реальные имена,
    # а не угадывать guest_2g/iot_5g.
    Write-Section "Wi-Fi и подсети guest/iot (read-only)"
    $cmd = "echo '=== uci show wireless (ключевые поля) ==='; " +
           "uci show wireless 2>/dev/null | grep -E '\.(disabled|ssid|device|network|mode|encryption|band|channel|hidden)=' || echo '(uci wireless пуст)'; " +
           "echo; echo '=== /etc/config/network: интерфейсы guest/iot ==='; " +
           "uci show network 2>/dev/null | grep -iE 'guest|iot' || echo '(не найдено)'; " +
           "echo; echo '=== /etc/config/dhcp: пулы guest/iot ==='; " +
           "uci show dhcp 2>/dev/null | grep -iE 'guest|iot' || echo '(не найдено)'; " +
           "echo; echo '=== SSID <-> Linux-iface (hostapd-конфиги, надёжный источник) ==='; " +
           "for f in /var/run/hostapd-*.conf; do test -f `$f || continue; iface=`$(basename `$f .conf | sed s/^hostapd-//); ssid=`$(grep -i -E '^[[:space:]]*ssid=' `$f | head -1 | cut -d= -f2-); echo `$iface `$ssid; done; " +
           "echo; echo '--- iwinfo (вспомогательно) ---'; " +
           "iwinfo 2>/dev/null | awk '/ESSID:/{print}' || echo iwinfo-empty-or-missing; " +
           "echo; echo '=== Активные L3-интерфейсы (ip -br addr) ==='; " +
           "ip -br addr 2>/dev/null | grep -iE 'br-|guest|iot|wlan|wl[0-9]' || ip -br addr; " +
           "echo; echo '=== ip rule (правила маршрутизации) ==='; ip rule; " +
           "echo; echo '=== ip route show table 200 (bypass-VPN таблица) ==='; " +
           "ip route show table 200 2>/dev/null || echo '(таблица 200 пуста)'; " +
           "echo; echo '=== iptables mangle PREROUTING + VPN_EXCLUDE (метки/исключения) ==='; " +
           "iptables -t mangle -S PREROUTING 2>/dev/null | grep -vE '^-[PN] '; " +
           "iptables -t mangle -S VPN_EXCLUDE 2>/dev/null | grep -vE '^-[PN] ' || true"
    $out = Invoke-Router -Command $cmd
    if ($out) { Write-Host ($out -join "`n") }
}

# ============================================================
# Wi-Fi helpers
# ============================================================

function _Confirm($prompt) {
    $ans = Read-Host "$prompt [y/N]"
    return ($ans -eq "y" -or $ans -eq "Y")
}

function Action-GuestVpnBypassToggle {
    Write-Section "Guest 192.168.33.0/24 — мимо/через VPN"
    # Bypass-правило: ip rule add from 192.168.33.0/24 lookup main pref 90.
    # pref 90 < pref 200 (штатное `from 192.168.33.0/24 lookup 200`),
    # поэтому матчится раньше и гостевая идёт в main (=через WAN).
    # Без правила pref 90 гостевая попадает в table 200 = default dev awg0.
    # '|| true' на конце: busybox grep -c при счёте 0 печатает "0" И выходит с
    # кодом 1; без этого Invoke-Router (вызван без -Silent) рисует лишний
    # '[FAIL] SSH вернул код 1'. С '|| true' код = 0, а "0"/"1" так и остаётся в stdout.
    $checkOut = Invoke-Router -Command "ip rule show | grep -c 'from 192.168.33.0/24 lookup main' || true"
    $count = ("$checkOut").Trim()
    if ($count -match '^[1-9]') {
        Write-Host "Сейчас: гостевая идёт МИМО VPN (есть ip rule pref 90 → main)"
        if (-not (_Confirm "Вернуть гостевую В VPN (удалить правило pref 90)?")) { Write-Warn "Отмена"; return }
        # guest-off зеркалит снятие в persistent-хранилище (.bypass-guest), чтобы
        # состояние «через VPN» пережило ребут (само ip rule живёт в RAM).
        $cmd = "ip rule del from 192.168.33.0/24 lookup main pref 90 2>/dev/null && echo OK_VPN_ON || echo FAIL; sh $AWG_DIR/apply-bypass.sh guest-off >/dev/null 2>&1"
    } else {
        Write-Host "Сейчас: гостевая идёт ЧЕРЕЗ VPN (правила pref 90 нет; работает штатное pref 200 → awg0)"
        if (-not (_Confirm "Вынести гостевую МИМО VPN (добавить ip rule pref 90)?")) { Write-Warn "Отмена"; return }
        # guest-on ставит флаг .bypass-guest, чтобы вырез «мимо VPN» пережил ребут.
        $cmd = "ip rule add from 192.168.33.0/24 lookup main pref 90 && echo OK_VPN_OFF || echo FAIL; sh $AWG_DIR/apply-bypass.sh guest-on >/dev/null 2>&1"
    }
    $out = Invoke-Router -Command $cmd
    Write-Host ($out -join "`n")
}

function _GetSsidIfaceMap {
    # Возвращает hashtable: SSID -> массив iface (например wl16, wl17).
    # Источник — /var/run/hostapd-*.conf (тот же, что и в Action-WifiStatus —
    # точно работает на BE7000). Имя iface берётся из basename файла.
    # Разделитель в выводе — литерал ' ::: ' (нет в SSID, безопасно).
    $cmd = "for f in /var/run/hostapd-*.conf; do " +
           "test -f `$f || continue; " +
           "iface=`$(basename `$f .conf | sed s/^hostapd-//); " +
           "ssid=`$(grep -i -E '^[[:space:]]*ssid=' `$f | head -1 | cut -d= -f2-); " +
           "echo `$iface ::: `$ssid; " +
           "done"
    $out = Invoke-Router -Command $cmd -Silent
    $map = @{}
    # ВАЖНО: Invoke-Router возвращает массив строк. "$out" склеит его через
    # $OFS=' ' и сломает split по newline. Итерируемся напрямую через @($out).
    foreach ($line in @($out)) {
        $t = "$line".Trim()
        if (-not $t) { continue }
        $parts = $t -split " ::: ", 2
        if ($parts.Count -ne 2) { continue }
        $iface = $parts[0].Trim()
        $ssid  = $parts[1].Trim()
        if (-not $iface -or -not $ssid) { continue }
        if (-not $map.ContainsKey($ssid)) { $map[$ssid] = @() }
        $map[$ssid] += $iface
    }
    return $map
}

function _GetBypassedIfaces {
    # Возвращает hashtable iface -> $true для интерфейсов, у которых уже
    # стоит правило `-m physdev --physdev-in <iface> -j ACCEPT` в chain
    # VPN_EXCLUDE. Раньше тут было `-i <iface>`, но на BE7000 wl* живут
    # в bridge br-lan и iptables в `-i` видит сам бридж, а не физ-iface.
    # См. длинный комментарий в Action-WifiBypassVpnBySsid.
    $cmd = "iptables -t mangle -S VPN_EXCLUDE 2>/dev/null | grep -E -- '--physdev-in .* -j ACCEPT' || true"
    $out = Invoke-Router -Command $cmd -Silent
    $set = @{}
    foreach ($line in @($out)) {
        $t = "$line"
        if ($t -match '--physdev-in\s+(\S+)\b') {
            $set[$matches[1]] = $true
        }
    }
    return $set
}

# Однострочник для очистки conntrack-записей всех клиентов, подключённых
# к Wi-Fi-iface $IFACE. Без этого Qualcomm NSS/ECM продолжит держать
# offload-кэш через старый маршрут — наше новое правило в VPN_EXCLUDE
# не повлияет на уже установленные соединения.
function _ConntrackFlushForIfaceCmd($iface) {
    # 1) iwinfo даёт список MAC подключённых станций
    # 2) awk по /tmp/dhcp.leases ищет IP по MAC
    # 3) conntrack -D --src <IP> удаляет соединения этого клиента
    # /tmp/dhcp.leases хранит MAC в нижнем регистре, поэтому tolower(`$1) у awk.
    # Двойной for вместо xargs -I — BusyBox xargs не умеет -I.
    return "for mac in `$(iwinfo $iface assoclist 2>/dev/null | awk '/^[0-9A-F:]{17}/{print tolower(`$1)}'); do " +
           "for ip in `$(awk -v m=`$mac 'tolower(`$2)==m{print `$3}' /tmp/dhcp.leases); do " +
           "conntrack -D --src `$ip >/dev/null 2>&1; " +
           "done; done"
}

function Action-WifiBypassVpnBySsid {
    Write-Section "Wi-Fi SSID — мимо/через VPN (по WiFi-интерфейсам)"
    # Все Wi-Fi-сети сейчас сидят в network='lan' (общая 192.168.31.0/24),
    # поэтому развести по подсети нельзя. Идём через chain VPN_EXCLUDE:
    # `-m physdev --physdev-in <wlN> -j ACCEPT` — пакет принят в mangle,
    # обход не доходит до mark-правил, fwmark 0x1 не ставится → пакет не
    # попадает в table 1000 → не уходит в awg0.
    #
    # ВАЖНО про ACCEPT (а не RETURN): см. длинный комментарий в vpn-toggle.sh.
    # Кратко: RETURN из user-chain возвращает в PREROUTING на следующее
    # правило (= mark-правило) → mark всё равно поставится.
    #
    # ВАЖНО про physdev (а не просто -i wlN): wlN на BE7000 — это slave-порт
    # bridge'а br-lan. Для бриджуемых пакетов в iptables -i показывает bridge
    # (br-lan), а не физический iface (wl16). Поэтому нужен `-m physdev
    # --physdev-in wl16` — это матчит физический input device при проходе
    # bridge'а через iptables (bridge-nf-call-iptables=1 на BE7000 включён).
    # Проверено эмпирически через LOG-таргет — для wl16-трафика IN=br-lan,
    # PHYSIN=wl16. Просто -i wl16 НЕ работал, счётчик был 0.
    #
    # ВАЖНО про conntrack -D после: на BE7000 активен Qualcomm NSS
    # (ECM+PPE+SFE), он offload-ит установленные соединения через быстрый
    # путь. После изменения iptables-правил существующие соединения
    # продолжат идти через прежний маршрут (через VPN). conntrack -D
    # удаляет conntrack-записи → ECM получает уведомление и сбрасывает
    # offload → новые пакеты пойдут через iptables со свежим правилом.
    $map = _GetSsidIfaceMap
    if ($map.Keys.Count -eq 0) {
        Write-Err "Не удалось получить список SSID. Проверь /var/run/hostapd-*.conf на роутере."
        return
    }
    $bypassed = _GetBypassedIfaces

    Write-Host "Доступные Wi-Fi сети (по SSID):"
    Write-Host ""
    $ssids = $map.Keys | Sort-Object
    $menu = @{}
    $idx = 1
    foreach ($s in $ssids) {
        $ifaces = $map[$s] | Sort-Object
        $cnt = 0
        foreach ($if in $ifaces) { if ($bypassed[$if]) { $cnt++ } }
        $state = if ($cnt -eq 0) { "ЧЕРЕЗ VPN" }
                 elseif ($cnt -eq $ifaces.Count) { "МИМО VPN" }
                 else { "ЧАСТИЧНО ($cnt/$($ifaces.Count) мимо VPN)" }
        $ifaceStr = $ifaces -join ", "
        Write-Host ("  {0,2}) {1,-30}  [{2,-10}]  {3}" -f $idx, $s, $ifaceStr, $state)
        $menu[$idx.ToString()] = $s
        $idx++
    }
    Write-Host "   0) Отмена"
    Write-Host ""
    $sel = Read-Host "Выбери SSID (номер)"
    if ($sel -eq "0" -or -not $menu.ContainsKey($sel)) { Write-Warn "Отмена"; return }
    $ssid = $menu[$sel]
    $ifaces = $map[$ssid] | Sort-Object
    $cnt = 0
    foreach ($if in $ifaces) { if ($bypassed[$if]) { $cnt++ } }

    $parts = @()
    if ($cnt -eq $ifaces.Count) {
        Write-Host "Сейчас: '$ssid' идёт МИМО VPN (все $($ifaces.Count) iface в bypass)."
        if (-not (_Confirm "Вернуть '$ssid' В VPN?")) { Write-Warn "Отмена"; return }
        foreach ($if in $ifaces) {
            # Удаляем оба возможных формата: новый physdev и старый -i (legacy
            # от предыдущей версии скрипта). Считаем удалённым если хоть один
            # формат был.
            $parts += "deleted=0; " +
                      "iptables -t mangle -D VPN_EXCLUDE -m physdev --physdev-in $if -j ACCEPT 2>/dev/null && deleted=1; " +
                      "iptables -t mangle -D VPN_EXCLUDE -i $if -j ACCEPT 2>/dev/null && deleted=1; " +
                      "[ `$deleted = 1 ] && echo DEL_$if || echo NORULE_$if"
            # Убираем iface из persistent-хранилища, чтобы вырез не вернулся после ребута.
            $parts += "sh $AWG_DIR/apply-bypass.sh del-if $if >/dev/null 2>&1"
        }
    } else {
        $hint = if ($cnt -gt 0) { " (частично — $cnt из $($ifaces.Count) iface уже в bypass)" } else { "" }
        Write-Host "Сейчас: '$ssid' идёт ЧЕРЕЗ VPN$hint."
        if (-not (_Confirm "Вынести '$ssid' МИМО VPN?")) { Write-Warn "Отмена"; return }
        # Если chain VPN_EXCLUDE нет — поднимем через repair (он его создаст
        # и подцепит первым в PREROUTING).
        $parts += "iptables -t mangle -L VPN_EXCLUDE -n >/dev/null 2>&1 || sh $AWG_DIR/vpn-toggle.sh repair >/dev/null 2>&1"
        foreach ($if in $ifaces) {
            $parts += "(iptables -t mangle -C VPN_EXCLUDE -m physdev --physdev-in $if -j ACCEPT 2>/dev/null && echo EXISTS_$if) || " +
                      "(iptables -t mangle -A VPN_EXCLUDE -m physdev --physdev-in $if -j ACCEPT && echo ADD_$if)"
            # Зеркалим iface в persistent-хранилище (.bypass-ifaces), чтобы вырез
            # «мимо VPN» пережил ребут/fw3-reload. add-if идемпотентен.
            $parts += "sh $AWG_DIR/apply-bypass.sh add-if $if >/dev/null 2>&1"
        }
    }
    # После любого изменения — сбрасываем conntrack для клиентов этих iface,
    # чтобы NSS пересоздал offload с новым маршрутом.
    foreach ($if in $ifaces) {
        $parts += (_ConntrackFlushForIfaceCmd $if)
    }
    $parts += "echo CONNTRACK_FLUSHED"

    $cmd = $parts -join "; "
    $out = Invoke-Router -Command $cmd
    Write-Host ($out -join "`n")
    if ("$out" -match "ADD_|DEL_") {
        Write-Ok "Готово. На клиентских устройствах может потребоваться 5-10 сек чтобы новые соединения пошли по новому маршруту."
    }
}

function Action-WifiRollback {
    Write-Section "Откатить /etc/config/wireless из последнего бэкапа"
    $listOut = Invoke-Router -Command "ls -1t /etc/config/wireless.bak.* 2>/dev/null | head -1"
    $bak = ("$listOut").Trim()
    if (-not $bak -or $bak -match '^ls:' -or $bak -eq "") {
        Write-Warn "Не найдено ни одного бэкапа /etc/config/wireless.bak.* — нечего откатывать."
        return
    }
    Write-Host "Последний бэкап: $bak"
    if (-not (_Confirm "Восстановить из этого бэкапа и сделать wifi reload?")) { Write-Warn "Отмена"; return }
    $cmd = "cp $bak /etc/config/wireless && uci -q commit wireless && " +
           "(wifi reload >/dev/null 2>&1 || wifi >/dev/null 2>&1) && echo OK_RESTORED || echo FAIL"
    $out = Invoke-Router -Command $cmd
    Write-Host ($out -join "`n")
    if ("$out" -match "OK_RESTORED") { Write-Ok "Восстановлено. Wi-Fi отвалится на 5-10 сек." }
}

function Action-VpnOnGlobal {
    Write-Section "Включаю VPN глобально (+ восстанавливаю правила)"
    # vpn-toggle.sh v2: 'on' идемпотентно восстанавливает mangle/MASQUERADE/
    # FORWARD/ip rule. Лечит ситуацию, когда fw3 reload-ом снёс iptables.
    $cmd = "if [ -x $AWG_DIR/vpn-toggle.sh ]; then sh $AWG_DIR/vpn-toggle.sh on; else ip rule del fwmark 0x1 table 1000 2>/dev/null; ip rule add fwmark 0x1 table 1000 pref 99 && echo OK; fi"
    $out = Invoke-Router -Command $cmd
    if ("$out" -match "OK|ВКЛЮЧ") {
        Write-Ok "VPN глобально включён"
        if ("$out" -match "правила восстановлены") {
            Write-Host ($out -join "`n") -ForegroundColor DarkGray
        }
    } else { Write-Err "Не получилось"; Write-Host $out }
}

function Action-RepairRules {
    Write-Section "Чиню iptables-правила (без переключения VPN)"
    # Используется когда статус показывает 'iptables-метки PREROUTING: 0+0'
    # или 'MASQUERADE на awg0: 0 шт.' — типично после reload'а firewall'а
    # в веб-морде Xiaomi.
    $cmd = "if [ -x $AWG_DIR/vpn-toggle.sh ]; then sh $AWG_DIR/vpn-toggle.sh repair; " +
           "else echo 'vpn-toggle.sh не найден — обнови скрипт на роутере'; fi"
    $out = Invoke-Router -Command $cmd
    Write-Host ($out -join "`n")
    if ("$out" -match "OK: правила восстановлены") {
        Write-Ok "Готово. Сбрасываю DNS-кэш..."
        ipconfig /flushdns | Out-Null
        Write-Ok "DNS-кэш сброшен"
    }
}

function Action-VpnOffGlobal {
    Write-Section "Выключаю VPN глобально"
    $cmd = "if [ -x $AWG_DIR/vpn-toggle.sh ]; then sh $AWG_DIR/vpn-toggle.sh off; else ip rule del fwmark 0x1 table 1000 2>/dev/null && echo OK || echo NORULE; fi"
    $out = Invoke-Router -Command $cmd
    if ("$out" -match "OK|ВЫКЛЮЧ") {
        Write-Ok "VPN глобально выключен"
        Write-Host "Сбрасываю DNS-кэш на этом ПК..."
        ipconfig /flushdns | Out-Null
        Write-Ok "DNS-кэш сброшен"
    } elseif ("$out" -match "NORULE") {
        Write-Warn "Правило fwmark уже не было активно"
    } else { Write-Err "Не получилось"; Write-Host $out }
}

function Action-FullTunnel {
    # Подменю «полностью через VPN»: глобальный full-tunnel + точечный force
    # (устройство/SSID/гостевая ЦЕЛИКОМ через VPN, без сплита по IP). Всё —
    # через apply-bypass.sh (цепочка VPN_FORCE, переживает ребут/fw3-reload,
    # переигрывается heal/repair). Безопасно: держится на одном ip rule fwmark,
    # который watchdog снимает (safety_off) при смерти VPS → интернет не запереть.
    while ($true) {
        Write-Section "Полностью через VPN (full-tunnel / отдельная сеть)"
        $ftOn = ("" + (Invoke-Router -Command "[ -f $AWG_DIR/.full-tunnel ] && echo ON || echo OFF" -Silent)).Trim()
        $ftLabel = if ($ftOn -match "ON") { "ВКЛ — весь трафик через VPN" } else { "выкл (раздельный режим, split по IP)" }
        Write-Host ("  Глобальный full-tunnel: {0}" -f $ftLabel)
        Write-Host ""
        Write-Host "  1) Глобально: ВЕСЬ трафик через VPN — переключить" -ForegroundColor Magenta
        Write-Host "  2) Устройство по IP — ЦЕЛИКОМ через VPN: включить"  -ForegroundColor Green
        Write-Host "  3) Устройство по IP — вернуть в раздельный режим"
        Write-Host "  4) Wi-Fi SSID — ЦЕЛИКОМ через VPN (выбор из списка)" -ForegroundColor Green
        Write-Host "  5) Гостевая сеть — ЦЕЛИКОМ через VPN: вкл/выкл"
        Write-Host "  6) Показать подробно (хранилище force)"
        Write-Host "  0) Назад"
        $c = Read-Host "Выбор"
        switch ($c) {
            "1" {
                if ($ftOn -match "ON") {
                    if (_Confirm "Выключить full-tunnel (вернуть раздельный режим)?") {
                        $out = Invoke-Router -Command "sh $AWG_DIR/apply-bypass.sh full-tunnel off"
                        Write-Host ($out -join "`n"); ipconfig /flushdns | Out-Null; Write-Ok "Готово"
                    } else { Write-Warn "Отмена" }
                } else {
                    Write-Warn "ВНИМАНИЕ: при full-tunnel ВЕСЬ трафик идёт через VPS."
                    Write-Host "  Если VPS упадёт — встанет ВЕСЬ интернет до ~2 мин (пока watchdog не сделает safety_off)."
                    Write-Host "  Локалка (192.168.x / 10.x / 172.16.x) и вырезы 'мимо VPN' сохраняются."
                    if (_Confirm "Включить full-tunnel (весь трафик через VPN)?") {
                        $out = Invoke-Router -Command "sh $AWG_DIR/apply-bypass.sh full-tunnel on"
                        Write-Host ($out -join "`n"); ipconfig /flushdns | Out-Null; Write-Ok "Готово"
                    } else { Write-Warn "Отмена" }
                }
            }
            "2" {
                $ip = (Read-Host "IP устройства (например 192.168.31.50)").Trim()
                if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { Write-Warn "Не похоже на IPv4"; }
                else {
                    $out = Invoke-Router -Command "sh $AWG_DIR/apply-bypass.sh force-add-ip $ip"
                    Write-Host ($out -join "`n"); Write-Ok "$ip -> целиком через VPN"
                }
            }
            "3" {
                $ip = (Read-Host "IP устройства, которое вернуть в раздельный режим").Trim()
                if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { Write-Warn "Не похоже на IPv4"; }
                else {
                    $out = Invoke-Router -Command "sh $AWG_DIR/apply-bypass.sh force-del-ip $ip"
                    Write-Host ($out -join "`n"); Write-Ok "$ip -> раздельный режим"
                }
            }
            "4" {
                $map = _GetSsidIfaceMap
                if ($map.Count -eq 0) { Write-Warn "Не нашёл SSID (нет /var/run/hostapd-*.conf?)"; }
                else {
                    # какие iface уже форсятся в VPN
                    $forced = @{}
                    foreach ($l in @(Invoke-Router -Command "cat $AWG_DIR/.fullvpn-ifaces 2>/dev/null" -Silent)) {
                        $t = "$l".Trim(); if ($t) { $forced[$t] = $true }
                    }
                    $ssids = @($map.Keys | Sort-Object)
                    $sel = @{}; $idx = 1
                    foreach ($s in $ssids) {
                        $ifs = @($map[$s]); $isF = $false
                        foreach ($if in $ifs) { if ($forced[$if]) { $isF = $true } }
                        $stt = if ($isF) { "[ЦЕЛИКОМ через VPN]" } else { "[раздельный]" }
                        Write-Host ("  {0}) {1}  ({2})  {3}" -f $idx, $s, ($ifs -join ','), $stt)
                        $sel["$idx"] = $s; $idx++
                    }
                    $pick = (Read-Host "Номер SSID (0 — отмена)").Trim()
                    if ($sel.ContainsKey($pick)) {
                        $ssid = $sel[$pick]; $ifs = @($map[$ssid]); $anyF = $false
                        foreach ($if in $ifs) { if ($forced[$if]) { $anyF = $true } }
                        if ($anyF) {
                            foreach ($if in $ifs) { Invoke-Router -Command "sh $AWG_DIR/apply-bypass.sh force-del-if $if" | Out-Null }
                            Write-Ok "SSID '$ssid' -> раздельный режим"
                        } else {
                            foreach ($if in $ifs) { Invoke-Router -Command "sh $AWG_DIR/apply-bypass.sh force-add-if $if" | Out-Null }
                            Write-Ok "SSID '$ssid' -> ЦЕЛИКОМ через VPN"
                        }
                    } else { Write-Warn "Отмена" }
                }
            }
            "5" {
                $gF = ("" + (Invoke-Router -Command "[ -f $AWG_DIR/.fullvpn-guest ] && echo ON || echo OFF" -Silent)).Trim()
                if ($gF -match "ON") {
                    if (_Confirm "Гостевая сейчас ЦЕЛИКОМ через VPN. Вернуть в раздельный режим?") {
                        $out = Invoke-Router -Command "sh $AWG_DIR/apply-bypass.sh force-guest-off"; Write-Host ($out -join "`n")
                    } else { Write-Warn "Отмена" }
                } else {
                    if (_Confirm "Пустить гостевую (192.168.33.0/24) ЦЕЛИКОМ через VPN?") {
                        $out = Invoke-Router -Command "sh $AWG_DIR/apply-bypass.sh force-guest-on"; Write-Host ($out -join "`n")
                    } else { Write-Warn "Отмена" }
                }
            }
            "6" {
                $out = Invoke-Router -Command "sh $AWG_DIR/apply-bypass.sh list"
                if ($out) { Write-Host ($out -join "`n") }
            }
            "0" { return }
            default { Write-Warn "Неизвестный пункт" }
        }
        Write-Host ""
        Read-Host "Enter — продолжить" | Out-Null
    }
}

function _Exclude-IP($ip) {
    # Выводим УСТРОЙСТВО (источник, его IP в LAN) мимо VPN через единый движок
    # apply-bypass.sh add-ip. Почему через него, а не своим iptables:
    #   * он ставит правило -s IP -j ACCEPT в цепочку VPN_EXCLUDE. ACCEPT, а НЕ
    #     RETURN: RETURN в mangle молча не работает — пакет возвращается в
    #     PREROUTING и всё равно метится по awg_list/iplist_set (грабли проекта).
    #     Прежняя версия этой функции ставила RETURN в PREROUTING = не исключала
    #     и не переживала ребут.
    #   * он же сохраняет IP в .bypass-ips → вырез переживает ребут/fw3-reload
    #     (heal и `vpn-toggle.sh repair` переигрывают хранилище).
    # conntrack -D — после смены правила: Qualcomm NSS offload-ит уже идущие
    # соединения, без сброса они держат старый маршрут (через VPN) до таймаута.
    # echo OK — последним, чтобы Invoke-Router не принял exit-код conntrack за сбой.
    return "sh $AWG_DIR/apply-bypass.sh add-ip $ip >/dev/null 2>&1; " +
           "conntrack -D --src $ip >/dev/null 2>&1; conntrack -D --dst $ip >/dev/null 2>&1; echo OK"
}
function _Include-IP($ip) {
    # Возвращаем устройство в VPN: del-ip снимает правило -s + чистит .bypass-ips;
    # conntrack -D — чтобы соединения, шедшие напрямую, вернулись в VPN, а не
    # висели на старом NSS-offload до таймаута. del-ip идемпотентен.
    return "sh $AWG_DIR/apply-bypass.sh del-ip $ip >/dev/null 2>&1; " +
           "conntrack -D --src $ip >/dev/null 2>&1; conntrack -D --dst $ip >/dev/null 2>&1; echo OK"
}
function _Exclude-DstIP($ip) {
    # Выводим САЙТ (IP/подсеть НАЗНАЧЕНИЯ) мимо VPN: add-dst ставит -d CIDR -j
    # ACCEPT в VPN_EXCLUDE (цепочка проверяется ПЕРВОЙ, до меток — надёжно
    # перебивает iplist_set/awg_list) и сохраняет в .bypass-dst (переживает ребут).
    # conntrack -D --dst сбрасывает уже идущие к этому IP соединения (для одиночного
    # IP; для CIDR conntrack по маске не отработает — это ок, новые соединения и так
    # пойдут по новому правилу).
    return "sh $AWG_DIR/apply-bypass.sh add-dst $ip >/dev/null 2>&1; " +
           "conntrack -D --dst $ip >/dev/null 2>&1; echo OK"
}
function _Include-DstIP($ip) {
    # Возвращаем сайт в VPN: del-dst снимает -d-правило + чистит .bypass-dst.
    # «Вернуть в VPN» = перестать ПРИНУДИТЕЛЬНО гнать напрямую; реально в туннель
    # сайт пойдёт, только если попадает в awg_list/iplist_set.
    return "sh $AWG_DIR/apply-bypass.sh del-dst $ip >/dev/null 2>&1; " +
           "conntrack -D --dst $ip >/dev/null 2>&1; echo OK"
}

function _GetLanDevices {
    # Список подключённых устройств LAN из двух источников на роутере:
    #   * /tmp/dhcp.leases — IP + MAC + hostname (имя, как его прислал DHCP-
    #     клиент; бывает кириллицей — UTF-8 проходит, т.к. вверху скрипта
    #     [Console]::OutputEncoding=UTF8 и chcp 65001 в .bat).
    #   * /proc/net/arp    — кто реально «виден» сейчас (флаг != 0x0 = запись
    #     валидна → устройство онлайн). Ловит и статические IP без lease.
    # ВАЖНО: команда намеренно БЕЗ кавычек (только echo/cat/;/redirect). awk со
    # своими двойными кавычками для строк ломается при передаче через plink из
    # Windows PowerShell 5.1 (кривое экранирование "). Поэтому весь разбор —
    # здесь, на стороне PowerShell.
    $cmd = "echo ===LEASES===; cat /tmp/dhcp.leases 2>/dev/null; echo ===ARP===; cat /proc/net/arp 2>/dev/null"
    $out = Invoke-Router -Command $cmd -Silent
    $byIp = @{}
    $section = ""
    foreach ($line in @($out)) {
        $t = "$line".Trim()
        if (-not $t) { continue }
        if ($t -eq "===LEASES===") { $section = "L"; continue }
        if ($t -eq "===ARP===")    { $section = "A"; continue }
        $f = $t -split '\s+'
        if ($section -eq "L") {
            if ($f.Count -lt 3) { continue }
            $mac = $f[1]; $ip = $f[2]
            $name = if ($f.Count -ge 4) { $f[3] } else { "*" }
            if ($ip -notmatch '^\d+\.\d+\.\d+\.\d+$') { continue }
            if ($ip -notlike "$LAN_SUBNET*") { continue }
            if (-not $byIp.ContainsKey($ip)) {
                $byIp[$ip] = [pscustomobject]@{ IP = $ip; MAC = $mac; Name = $name; Online = $false }
            } else {
                if ($name -and $name -ne "*") { $byIp[$ip].Name = $name }
                if ($mac) { $byIp[$ip].MAC = $mac }
            }
        } elseif ($section -eq "A") {
            if ($f.Count -lt 4 -or $f[0] -eq "IP") { continue }   # пропускаем заголовок
            $ip = $f[0]; $flags = $f[2]; $mac = $f[3]
            if ($ip -notmatch '^\d+\.\d+\.\d+\.\d+$') { continue }
            if ($ip -notlike "$LAN_SUBNET*") { continue }
            $present = ($flags -ne "0x0" -and $mac -ne "00:00:00:00:00:00")
            if (-not $byIp.ContainsKey($ip)) {
                $byIp[$ip] = [pscustomobject]@{ IP = $ip; MAC = $mac; Name = "*"; Online = $present }
            } else {
                if ($present) { $byIp[$ip].Online = $true }
                if (-not $byIp[$ip].MAC -and $mac) { $byIp[$ip].MAC = $mac }
            }
        }
    }
    $list = @($byIp.Values) | Where-Object { $_.IP -ne $ROUTER_IP }
    $list = $list | Sort-Object { [int](($_.IP -split '\.')[-1]) }
    return $list
}

function _SelectLanDevice {
    # Печатает нумерованный список подключённых устройств и возвращает выбранный
    # IP (или $null при отмене). Пункт «M» — ручной ввод IP (устройство не в
    # leases/arp или из другой подсети).
    Write-Host "Сканирую подключённые устройства..." -ForegroundColor DarkGray
    $devices = @(_GetLanDevices)
    if ($devices.Count -eq 0) {
        Write-Warn "Список устройств пуст (dhcp.leases/arp недоступны). Введи IP вручную."
        $ip = Read-Host "IP в LAN (например ${LAN_SUBNET}50)"
        if ($ip -notmatch '^\d+\.\d+\.\d+\.\d+$') { Write-Err "Это не похоже на IP"; return $null }
        return $ip.Trim()
    }
    Write-Host ""
    Write-Host "Подключённые устройства (* = сейчас в сети):"
    Write-Host ""
    $menu = @{}
    $i = 1
    foreach ($d in $devices) {
        $mark = if ($d.Online) { "*" } else { " " }
        $nm   = if ($d.Name -and $d.Name -ne "*") { $d.Name } else { "(имя неизвестно)" }
        Write-Host ("  {0,2}) {1} {2,-15} {3,-18} {4}" -f $i, $mark, $d.IP, $d.MAC, $nm)
        $menu[$i.ToString()] = $d.IP
        $i++
    }
    Write-Host ""
    Write-Host "   M) Ввести IP вручную"
    Write-Host "   0) Отмена"
    Write-Host ""
    $sel = (Read-Host "Выбери номер устройства").Trim()
    if ($sel -eq "0" -or $sel -eq "") { return $null }
    if ($sel -eq "M" -or $sel -eq "m") {
        $ip = Read-Host "IP в LAN"
        if ($ip -notmatch '^\d+\.\d+\.\d+\.\d+$') { Write-Err "Это не похоже на IP"; return $null }
        return $ip.Trim()
    }
    if ($menu.ContainsKey($sel)) { return $menu[$sel] }
    Write-Err "Нет такого пункта"
    return $null
}

function Action-ExcludeThisPC {
    $myIp = Get-MyLANIP
    if (-not $myIp) { Write-Err "Не удалось определить IP этого ПК"; return }
    Write-Section "Выключаю VPN для этого ПК ($myIp)"
    $out = Invoke-Router -Command (_Exclude-IP $myIp)
    if ("$out" -match "OK") {
        Write-Ok "Этот ПК ($myIp) теперь идёт мимо VPN"
        ipconfig /flushdns | Out-Null
        Write-Ok "DNS-кэш сброшен"
    } else { Write-Err "Не получилось"; Write-Host $out }
}

function Action-IncludeThisPC {
    $myIp = Get-MyLANIP
    if (-not $myIp) { Write-Err "Не удалось определить IP этого ПК"; return }
    Write-Section "Возвращаю этот ПК ($myIp) в VPN"
    $out = Invoke-Router -Command (_Include-IP $myIp)
    if ("$out" -match "OK") { Write-Ok "Этот ПК снова под VPN"; ipconfig /flushdns | Out-Null }
    elseif ("$out" -match "NORULE") { Write-Warn "Не было правила-исключения" }
    else { Write-Err "Не получилось"; Write-Host $out }
}

function Action-ExcludeOtherDevice {
    Write-Section "Выключить VPN для устройства по IP"
    $ip = _SelectLanDevice
    if (-not $ip) { Write-Warn "Отмена"; return }
    Write-Host "Выключаю VPN для $ip..." -ForegroundColor DarkGray
    $out = Invoke-Router -Command (_Exclude-IP $ip)
    if ("$out" -match "OK") { Write-Ok "$ip теперь идёт мимо VPN" } else { Write-Err "Не получилось"; Write-Host $out }
}

function Action-IncludeOtherDevice {
    Write-Section "Вернуть устройство в VPN"
    $ip = _SelectLanDevice
    if (-not $ip) { Write-Warn "Отмена"; return }
    Write-Host "Возвращаю $ip в VPN..." -ForegroundColor DarkGray
    $out = Invoke-Router -Command (_Include-IP $ip)
    if ("$out" -match "OK") { Write-Ok "$ip снова под VPN" }
    elseif ("$out" -match "NORULE") { Write-Warn "Этого IP не было в исключениях" }
    else { Write-Err "Не получилось"; Write-Host $out }
}

function Action-ListExcluded {
    Write-Section "Что выведено мимо VPN (устройства / сайты-IP / SSID / guest)"
    # Источник правды — персистентное хранилище apply-bypass.sh (переживает ребут),
    # а не живой iptables. Раньше тут грепался PREROUTING на '-j RETURN' — но вырезы
    # давно живут как ACCEPT в цепочке VPN_EXCLUDE, поэтому список всегда был пуст.
    $out = Invoke-Router -Command "sh $AWG_DIR/apply-bypass.sh list 2>/dev/null"
    if (-not $out -or "$out".Trim() -eq "") { Write-Host "(пусто — всё идёт по общей настройке)" }
    else { Write-Host ($out -join "`n") }
}

function Action-ExcludeDstIP {
    Write-Section "Вывести сайт (IP/подсеть назначения) мимо VPN"
    Write-Host "Укажи IP или подсеть НАЗНАЧЕНИЯ (сам сайт/сервис), напр. 1.2.3.4 или 104.16.0.0/13." -ForegroundColor DarkGray
    Write-Host "Перебивает CIDR-список (iplist) и переживает ребут. Это НЕ про устройства LAN (для них — раздел «Устройства»)." -ForegroundColor DarkGray
    $ip = (Read-Host "IP/подсеть назначения").Trim()
    if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}(/\d{1,2})?$') { Write-Err "Это не похоже на IP/подсеть (жду A.B.C.D или A.B.C.D/NN)"; return }
    Write-Host "Вывожу $ip мимо VPN..." -ForegroundColor DarkGray
    $out = Invoke-Router -Command (_Exclude-DstIP $ip)
    if ("$out" -match "OK") { Write-Ok "$ip теперь идёт мимо VPN (напрямую), переживёт ребут" }
    else { Write-Err "Не получилось"; Write-Host ($out -join "`n") }
}

function Action-IncludeDstIP {
    Write-Section "Вернуть сайт (IP/подсеть назначения) в VPN"
    $ip = (Read-Host "IP/подсеть назначения").Trim()
    if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}(/\d{1,2})?$') { Write-Err "Это не похоже на IP/подсеть"; return }
    Write-Host "Убираю вырез для $ip..." -ForegroundColor DarkGray
    $out = Invoke-Router -Command (_Include-DstIP $ip)
    if ("$out" -match "OK") { Write-Ok "$ip больше не выводится напрямую (в VPN пойдёт, если он в туннельных списках)" }
    else { Write-Err "Не получилось"; Write-Host ($out -join "`n") }
}

# awg-демон (amneziawg-go) реально стоит на роутере? Это несущая awg0. На hy2/xray-only
# установке его НЕТ — тогда заливать/активировать awg-конфиги бессмысленно (switch-vpn
# упрётся в гард awg_installed и вернёт код 1). Чтобы НЕ вводить юзера в заблуждение,
# меню awg-конфигов сперва спрашивает это.
function Test-AwgInstalled {
    $r = "" + (Invoke-Router -Command "[ -x $AWG_DIR/amneziawg-go ] && echo AWG_YES || echo AWG_NO" -Silent)
    return ($r -match 'AWG_YES')
}

function Action-SwitchCountry {
    Write-Section "Доступные конфиги (страны)"
    if (-not (Test-AwgInstalled)) {
        Write-Warn "AmneziaWG на роутере НЕ установлен (нет amneziawg-go) — переключать страны нечем."
        Write-Host "Несущий транспорт сейчас не AmneziaWG; awg-конфиги без самого AmneziaWG не активируются." -ForegroundColor DarkGray
        Write-Host "Поставить AmneziaWG: меню -> «Установка и обслуживание» -> Установить," -ForegroundColor DarkGray
        Write-Host "выбрав вариант с AmneziaWG (напр. «AmneziaWG + Hysteria2»)." -ForegroundColor DarkGray
        return
    }
    $listOut = Invoke-Router -Command "ls -1 $AWG_DIR/configs/ 2>/dev/null | grep '\.conf$' | sed 's/\.conf$//'"
    if (-not $listOut) {
        Write-Warn "Папка $AWG_DIR/configs/ пуста. Положи туда germany.conf / france.conf и т.п."
        return
    }
    $countries = ($listOut -join "`n") -split "`r?`n" | Where-Object { $_ -and $_.Trim() -ne "" }
    $i = 1; $map = @{}
    foreach ($c in $countries) { Write-Host "  $i) $c"; $map[$i.ToString()] = $c.Trim(); $i++ }
    Write-Host "  0) Отмена"
    $sel = Read-Host "Выбери номер"
    if ($sel -eq "0" -or -not $map.ContainsKey($sel)) { Write-Warn "Отмена"; return }
    $country = $map[$sel]
    Write-Host "Переключаюсь на $country..."
    # Симлинк 'vpn' создаётся в awg-setup-be7000.sh; есть fallback на switch-vpn.sh
    $cmd = "if command -v vpn >/dev/null 2>&1; then vpn $country; else sh $AWG_DIR/switch-vpn.sh $country; fi"
    $out = Invoke-Router -Command $cmd
    Write-Host ($out -join "`n")
    $script:RouterSummary = Get-RouterSummary   # обновить «Протокол · Конфиг» в шапке
}

function Action-UploadConfig {
    # Заливает локальный *.conf в $AWG_DIR/configs/ БЕЗ установщика и БЕЗ pscp.
    # Механизм — как в Action-NotifySetup: контент → base64 на стороне ПК → stdin
    # в plink → 'base64 -d > файл' на роутере. Почему не pscp: этот скрипт
    # принципиально «тонкое меню поверх plink» (одна зависимость — PuTTY-plink),
    # а awg-конфиги крошечные (1-2 КБ), для них base64 через stdin с запасом.
    #
    # ВАЖНО про LF: switch-vpn.sh/awg_setup.sh парсят значения построчно; CRLF
    # оставил бы '\r' в Endpoint/ключах и сломал бы туннель. Поэтому нормализуем
    # переводы строк в LF ПЕРЕД отправкой — на роутер уходит чистый LF-файл.
    Write-Section "Залить конфиг (.conf) на роутер"
    # Если awg-демона на роутере нет (hy2/xray-only установка) — конфиг можно залить
    # про запас, но активировать его сейчас нечем. Предупреждаем явно, чтобы не
    # повторялась ловушка «залил конфиг + сменил страну -> [FAIL] нечем активировать».
    $awgInstalled = Test-AwgInstalled
    if (-not $awgInstalled) {
        Write-Warn "AmneziaWG на роутере НЕ установлен (нет amneziawg-go)."
        Write-Host "Залить .conf можно, но активировать его будет нечем — awg-конфиги работают" -ForegroundColor DarkGray
        Write-Host "только при установленном AmneziaWG (сейчас несущий транспорт другой: xray/hy2)." -ForegroundColor DarkGray
        Write-Host "Поставить AmneziaWG: меню -> «Установка и обслуживание» -> Установить," -ForegroundColor DarkGray
        Write-Host "выбрав вариант с AmneziaWG (напр. «AmneziaWG + Hysteria2»)." -ForegroundColor DarkGray
        if (-not (_Confirm "Всё равно залить awg-конфиг про запас (активировать сейчас нельзя)?")) { Write-Warn "Отмена"; return }
    }
    Write-Host "Путь к локальному .conf (можно перетащить файл в это окно)." -ForegroundColor DarkGray

    $raw = Read-Host "Путь к файлу"
    if (-not $raw) { Write-Warn "Отмена"; return }
    # Перетащенный в консоль путь обычно в кавычках — снимаем их.
    $localPath = $raw.Trim().Trim('"')
    if (-not (Test-Path -LiteralPath $localPath -PathType Leaf)) {
        Write-Err "Файл не найден: $localPath"; return
    }
    $localPath = (Resolve-Path -LiteralPath $localPath).Path

    # Имя без .conf станет идентификатором конфига (vpn <name>) и уходит в
    # shell-команды — поэтому разрешаем только безопасные символы.
    $srcName = [System.IO.Path]::GetFileName($localPath)
    $defBase = [System.IO.Path]::GetFileNameWithoutExtension($srcName)
    $inName  = Read-Host "Имя на роутере без .conf (Enter = '$defBase')"
    $base    = if ($inName) { $inName.Trim() } else { $defBase }
    $base    = $base -replace '\.conf$', ''
    if ($base -notmatch '^[A-Za-z0-9._-]+$') {
        Write-Err "Имя: только латиница/цифры/точка/дефис/подчёркивание"; return
    }
    $remoteName = "$base.conf"

    # Читаем и нормализуем переводы строк в LF.
    try   { $text = [System.IO.File]::ReadAllText($localPath) }
    catch { Write-Err "Не смог прочитать файл: $($_.Exception.Message)"; return }
    $text = $text -replace "`r`n", "`n" -replace "`r", "`n"

    # Мягкая валидация (как PreFlight в установщике): не блокируем жёстко, но
    # предупреждаем, если не похоже на awg-конфиг.
    $checks = [ordered]@{
        '[Interface]' = '\[Interface\]'
        '[Peer]'      = '\[Peer\]'
        'PrivateKey'  = 'PrivateKey\s*='
        'PublicKey'   = 'PublicKey\s*='
        'Endpoint'    = 'Endpoint\s*='
    }
    $missing = @($checks.Keys | Where-Object { $text -notmatch $checks[$_] })
    if ($missing.Count -gt 0) {
        Write-Warn "В файле не найдено: $($missing -join ', ')"
        if (-not (_Confirm "Похоже на неполный awg-конфиг. Всё равно залить?")) { Write-Warn "Отмена"; return }
    } else {
        Write-Ok "Похоже на валидный awg-конфиг ([Interface]/[Peer]/ключи/Endpoint на месте)"
    }

    # Предупредим о перезаписи существующего конфига.
    $exists = ("" + (Invoke-Router -Command "[ -f $AWG_DIR/configs/$remoteName ] && echo YES || echo NO" -Silent)).Trim()
    if ($exists -match "YES" -and -not (_Confirm "configs/$remoteName уже есть на роутере — перезаписать?")) {
        Write-Warn "Отмена"; return
    }

    # base64 (одна строка) → stdin plink → 'base64 -d' на роутере. Пишем во
    # временный .new и атомарно mv поверх боевого — чтобы прерванная заливка НЕ
    # затёрла рабочий конфиг (открытие '> файл' усекло бы его сразу). chmod 600:
    # в конфиге PrivateKey — секрет (как notify.conf). Имя $base уже
    # просанировано, так что одинарные кавычки тут — лишь подстраховка.
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text))
    $dst = "$AWG_DIR/configs/$remoteName"
    $cmd = "mkdir -p $AWG_DIR/configs && base64 -d > '$dst.new' && mv '$dst.new' '$dst' && " +
           "chmod 600 '$dst' && echo SAVED `$(wc -c < '$dst') || { rm -f '$dst.new'; echo FAILED; }"
    Write-Host "Заливаю $srcName -> $dst ..." -ForegroundColor DarkGray
    $out = Invoke-Router -Command $cmd -StdinData $b64
    if ("$out" -notmatch "SAVED") {
        Write-Err "Не удалось залить конфиг"; Write-Host ($out -join "`n"); return
    }
    $bytes = if ("$out" -match 'SAVED\s+(\d+)') { $matches[1] } else { '?' }
    Write-Ok "Готово: $dst (записано $bytes байт)"

    # Активировать предлагаем ТОЛЬКО если awg-демон реально стоит — иначе switch-vpn
    # упрётся в гард и вернёт [FAIL]. Без awg конфиг просто лежит про запас.
    if ($awgInstalled) {
        if (_Confirm "Сделать '$base' активным конфигом сейчас?") {
            $sw = "if command -v vpn >/dev/null 2>&1; then vpn $base; else sh $AWG_DIR/switch-vpn.sh $base; fi"
            $r = Invoke-Router -Command $sw
            Write-Host ($r -join "`n")
        } else {
            Write-Host "Переключиться можно позже: «Серверы AmneziaWG» -> Сменить страну/конфиг." -ForegroundColor DarkGray
        }
    } else {
        Write-Host "Конфиг сохранён про запас. Он станет рабочим после установки AmneziaWG" -ForegroundColor DarkGray
        Write-Host "(меню -> «Установка и обслуживание» -> Установить, вариант с AmneziaWG)." -ForegroundColor DarkGray
    }
}

# Мульти-заливка: пути к конфигам, перетащенные мышью НА be7000.bat (или переданные
# аргументами), раскладываются по типам и льются на роутер без диалога per-файл.
# Тип берём по РАСШИРЕНИЮ (предсказуемо), содержимое — лишь для мягкого предупреждения:
#   *.conf       -> awg-конфиг страны -> configs/<имя>.conf
#   *.json       -> xray-конфиг       -> xray-configs/<имя>.json
#   *.yaml/*.yml -> hy2-конфиг         -> hy2-configs/<имя>.yaml
# Активным НЕ делает (конфигов много — какой активировать, юзер решит в меню потом).
function Action-IngestDroppedConfigs {
    param([string[]]$Paths)
    Write-Section "Мульти-заливка конфигов (перетащено: $(@($Paths).Count))"

    # 1) Разбираем входные пути -> список items {Kind, Local, Name, Dir, RemoteExt, Text}.
    $items = @()
    foreach ($raw in @($Paths)) {
        if (-not $raw) { continue }
        $p = ("" + $raw).Trim().Trim('"')
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { Write-Warn "Пропуск (не файл): $p"; continue }
        $p = (Resolve-Path -LiteralPath $p).Path
        $leaf = Split-Path $p -Leaf
        $base = ([System.IO.Path]::GetFileNameWithoutExtension($p)) -replace '[^A-Za-z0-9._-]', '-'
        if (-not $base) { Write-Warn "Пропуск (пустое имя): $leaf"; continue }
        # ReadAllText (не Get-Content -Raw): тот на ру-Windows без BOM читает в CP1251
        # и портит кириллицу. Конфиги обычно ASCII, но читаем явно и безопасно.
        try   { $text = [System.IO.File]::ReadAllText($p) }
        catch { Write-Warn "Пропуск (не прочитать): $leaf"; continue }

        $ext = [System.IO.Path]::GetExtension($p).ToLower()
        $kind = $null; $dir = $null; $remoteExt = $null
        if     ($ext -eq '.conf')                      { $kind = 'awg';  $dir = "$AWG_DIR/configs";      $remoteExt = '.conf' }
        elseif ($ext -eq '.json')                      { $kind = 'xray'; $dir = "$AWG_DIR/xray-configs"; $remoteExt = '.json' }
        elseif ($ext -eq '.yaml' -or $ext -eq '.yml')  { $kind = 'hy2';  $dir = "$AWG_DIR/hy2-configs";  $remoteExt = '.yaml' }
        else { Write-Warn "Пропуск (расширение '$ext' не .conf/.json/.yaml): $leaf"; continue }

        if ($kind -eq 'awg' -and -not ($text -match '\[Interface\]' -and $text -match '\[Peer\]')) {
            Write-Warn "  $leaf не похож на awg-конфиг ([Interface]/[Peer] нет) — залью как есть."
        }
        $items += [pscustomobject]@{ Kind = $kind; Local = $p; Name = $base; Dir = $dir; RemoteExt = $remoteExt; Text = $text }
    }
    if ($items.Count -eq 0) { Write-Warn "Нечего заливать — подходящих конфигов не найдено."; return }

    # 2) Сводка + подтверждение (одно на всю пачку).
    Write-Host "Будет залито:" -ForegroundColor DarkGray
    foreach ($it in $items) {
        $lbl = switch ($it.Kind) { 'awg' { 'AmneziaWG' } 'xray' { 'Xray' } 'hy2' { 'Hysteria2' } }
        Write-Host ("  [{0,-9}] {1}{2}  ->  {3}/" -f $lbl, $it.Name, $it.RemoteExt, $it.Dir) -ForegroundColor DarkGray
    }
    if (@($items | Where-Object { $_.Kind -eq 'awg' }).Count -gt 0 -and -not (Test-AwgInstalled)) {
        Write-Warn "AmneziaWG на роутере не установлен — awg-конфиги лягут про запас (активируются после установки AmneziaWG)."
    }
    if (-not (_Confirm "Залить эти $($items.Count) конфиг(ов) на роутер?")) { Write-Warn "Отмена"; return }

    # 3) Заливаем атомарно (Send-RouterFileAtomic нормализует CRLF->LF и chmod 600).
    $ok = 0; $fail = 0
    foreach ($it in $items) {
        $dst = "$($it.Dir)/$($it.Name)$($it.RemoteExt)"
        Invoke-Router -Command "mkdir -p '$($it.Dir)'" -Silent | Out-Null
        Write-Info "  -> $dst"
        if (Send-RouterFileAtomic $dst $it.Text 600) { $ok++ } else { Write-Err "    не залился"; $fail++ }
    }
    Write-Host ""
    if ($fail -eq 0) { Write-Ok "Готово: залито конфигов — $ok." }
    else { Write-Warn "Залито $ok, не удалось $fail." }
    Write-Host "Активировать нужный: «Серверы AmneziaWG» -> Сменить страну/конфиг (awg)," -ForegroundColor DarkGray
    Write-Host "или «Протокол» -> Xray/Hysteria2: выбрать активный конфиг." -ForegroundColor DarkGray
}

# ============================================================
# Xray-транспорт и управление xray-конфигами (Фаза 1)
# «Сменить протокол» = xray-transport.sh up/down (свап default в table 1000
# awg0<->xtun; общие правила маркировки НЕ трогаются). Конфиги xray лежат в
# $AWG_DIR/xray-configs/<name>.json (секрет), активный копируется в xray.json.
# JSON генерим/правим ЗДЕСЬ — на роутере нет jq.
# ============================================================
function Get-Transport {
    $t = ("" + (Invoke-Router -Command "cat $AWG_DIR/.transport 2>/dev/null" -Silent)).Trim()
    if (-not $t) { $t = "awg" }
    return $t
}
function Get-XrayConfigNames {
    $raw = Invoke-Router -Command "ls -1 $AWG_DIR/xray-configs/ 2>/dev/null | grep '\.json$' | sed 's/\.json$//'" -Silent
    if (-not $raw) { return @() }
    return @((("" + ($raw -join "`n")) -split "`r?`n") | Where-Object { $_ -and $_.Trim() -ne "" } | ForEach-Object { $_.Trim() })
}
function Get-ActiveXrayName { return ("" + (Invoke-Router -Command "cat $AWG_DIR/.xray-active 2>/dev/null" -Silent)).Trim() }

function Parse-VlessLink {
    param([string]$link)
    if ($link -notmatch '^vless://') { return $null }
    $s = $link.Substring(8)
    $remark = ""
    if ($s.Contains('#')) { $k = $s.IndexOf('#'); $remark = [uri]::UnescapeDataString($s.Substring($k + 1)); $s = $s.Substring(0, $k) }
    $query = ""
    if ($s.Contains('?')) { $k = $s.IndexOf('?'); $query = $s.Substring($k + 1); $s = $s.Substring(0, $k) }
    if ($s -notmatch '^([^@]+)@(.+):(\d+)$') { return $null }
    $p = @{ uuid = $Matches[1]; host = $Matches[2]; port = $Matches[3]; remark = $remark }
    foreach ($kv in ($query -split '&')) {
        if (-not $kv) { continue }
        $eq = $kv.IndexOf('='); if ($eq -lt 0) { continue }
        $key = $kv.Substring(0, $eq); $val = [uri]::UnescapeDataString($kv.Substring($eq + 1))
        switch ($key) {
            'type'        { $p.type = $val }
            'security'    { $p.security = $val }
            'encryption'  { $p.encryption = $val }
            'flow'        { $p.flow = $val }
            'sni'         { $p.sni = $val }
            'serverName'  { $p.sni = $val }
            'fp'          { $p.fp = $val }
            'pbk'         { $p.pbk = $val }
            'sid'         { $p.sid = $val }
            'spx'         { $p.spx = $val }
            'path'        { $p.path = $val }
            'host'        { $p.hostHeader = $val }
            'serviceName' { $p.serviceName = $val }
            'alpn'        { $p.alpn = $val }
        }
    }
    return $p
}

function New-XrayConfigJson {
    param([hashtable]$P)
    $enc = if ($P.encryption) { $P.encryption } else { 'none' }
    $user = [ordered]@{ id = $P.uuid; encryption = $enc }
    if ($P.flow) { $user.flow = $P.flow }
    $net = if ($P.type) { $P.type } else { 'tcp' }
    $sec = if ($P.security) { $P.security } else { 'none' }
    $stream = [ordered]@{ network = $net; security = $sec }
    if ($sec -eq 'reality') {
        $stream.realitySettings = [ordered]@{
            serverName  = $P.sni
            fingerprint = $(if ($P.fp) { $P.fp } else { 'chrome' })
            publicKey   = $P.pbk
            shortId     = $(if ($P.sid) { $P.sid } else { '' })
            spiderX     = $(if ($P.spx) { $P.spx } else { '' })
        }
    } elseif ($sec -eq 'tls' -or $sec -eq 'xtls') {
        $stream.security = 'tls'
        $ts = [ordered]@{ serverName = $P.sni; fingerprint = $(if ($P.fp) { $P.fp } else { 'chrome' }) }
        if ($P.alpn) { $ts.alpn = @($P.alpn -split ',') }
        $stream.tlsSettings = $ts
    }
    if ($net -eq 'ws') {
        $ws = [ordered]@{ path = $(if ($P.path) { $P.path } else { '/' }) }
        if ($P.hostHeader) { $ws.headers = @{ Host = $P.hostHeader } }
        $stream.wsSettings = $ws
    } elseif ($net -eq 'grpc') {
        $stream.grpcSettings = [ordered]@{ serviceName = $P.serviceName }
    }
    $cfg = [ordered]@{
        log       = [ordered]@{ access = '/tmp/xray-access.log'; error = '/tmp/xray.log'; loglevel = 'warning' }
        inbounds  = @( [ordered]@{ tag = 'socks-in'; listen = '127.0.0.1'; port = 10808; protocol = 'socks'; settings = [ordered]@{ udp = $true } } )
        outbounds = @( [ordered]@{ tag = 'proxy'; protocol = 'vless'; settings = [ordered]@{ vnext = @( [ordered]@{ address = $P.host; port = [int]$P.port; users = @($user) } ) }; streamSettings = $stream } )
    }
    return ($cfg | ConvertTo-Json -Depth 12)
}

# Мгновенная health-проба egress через локальный socks Xray (пусто = сервер/конфиг
# не отвечает). Нужна для фидбэка при РУЧНОЙ смене xray-конфига/транспорта: иначе
# юзер видит «подключился», но зарубежные сайты молчат, и непонятно почему —
# watchdog вернёт рабочий лишь через ~2-4 мин (анти-дребезг). Лучше сказать сразу.
function Show-XrayEgressVerdict {
    param([string]$name)
    Write-Host "Проверяю egress через xray..." -ForegroundColor DarkGray
    $ip = ("" + (Invoke-Router -Command "curl -s --max-time 8 --socks5-hostname 127.0.0.1:10808 https://api.ipify.org 2>/dev/null" -Silent)).Trim()
    if ($ip) {
        Write-Ok "Xray '$name' работает — выходной IP: $ip"
    } else {
        Write-Warn "Xray '$name' подключился, но egress ПУСТ — сервер/конфиг не отвечает (SNI/порт/ключи?)."
        Write-Host "  Авто-failover вернёт рабочий xray-резерв через ~2-4 мин (анти-дребезг)," -ForegroundColor Yellow
        Write-Host "  либо выбери другой xray-конфиг сейчас (Протокол -> Выбрать активный xray-конфиг)." -ForegroundColor Yellow
    }
}

function Set-ActiveXrayConfig {
    param([string]$name)
    $cmd = "cp $AWG_DIR/xray-configs/$name.json $AWG_DIR/xray.json && chmod 600 $AWG_DIR/xray.json && echo $name > $AWG_DIR/.xray-active && echo OK"
    $out = Invoke-Router -Command $cmd
    if ("$out" -notmatch "OK") { Write-Err "Не удалось активировать $name"; Write-Host ($out -join "`n"); return }
    Write-Ok "Активный xray-конфиг: $name"
    if ((Get-Transport) -eq "xray") {
        Write-Host "Транспорт=xray — перезапускаю с новым конфигом..." -ForegroundColor DarkGray
        Write-Host ((Invoke-Router -Command "sh $AWG_DIR/xray-transport.sh down; sh $AWG_DIR/xray-transport.sh up") -join "`n")
        Show-XrayEgressVerdict $name
    }
    $script:RouterSummary = Get-RouterSummary   # обновить «Протокол · Конфиг» в шапке
}

function Action-SwitchTransport {
    Write-Section "Переключить транспорт VPN"
    $lbl = @{ awg = "AmneziaWG"; xray = "Xray"; hy2 = "Hysteria2" }
    $t = Get-Transport
    $curLbl = if ($lbl[$t]) { $lbl[$t] } else { $t }
    Write-Host "Текущий транспорт: $curLbl ($t)"
    # Готовые транспорты (плагин + секрет-конфиг + бинарь) берём у ОРКЕСТРАТОРА —
    # он один знает, что реально установлено (на флеше живёт ОДИН альт: xray ЛИБО hy2).
    $raw = Invoke-Router -Command "sh $AWG_DIR/transport.sh list 2>/dev/null" -Silent
    $avail = @((("" + ($raw -join "`n")) -split "`r?`n") | Where-Object { $_ -and $_.Trim() -ne "" } | ForEach-Object { $_.Trim() })
    # Цели переключения = готовые транспорты, КРОМЕ текущего. Раньше тут стоял
    # `$avail.Count -lt 2`, но он ломал ВОССТАНОВЛЕНИЕ из осиротевшего состояния: если
    # текущий .transport сам не готов (напр. =awg, а awg-демон не установлен после
    # hy2-only установки), avail=[hy2] (count 1) и меню отказывало встать на hy2.
    # Правильно: считать цели без текущего и пускать, если есть хоть одна.
    $targets = @($avail | Where-Object { $_ -ne $t })
    if ($targets.Count -lt 1) {
        if ($avail.Count -le 1) { Write-Warn "Готов только один транспорт ($($avail -join ', ')) — переключать не на что. Добавь конфиг альт-протокола." }
        else { Write-Warn "Других готовых транспортов нет (готов: $($avail -join ', '))." }
        return
    }
    $i = 1; $map = @{}
    foreach ($n in $avail) {
        $mk = if ($n -eq $t) { "  <- сейчас" } else { "" }
        $nm = if ($lbl[$n]) { $lbl[$n] } else { $n }
        Write-Host "  $i) $nm ($n)$mk"; $map["$i"] = $n; $i++
    }
    Write-Host "  0) Отмена"
    $sel = Read-Host "На какой транспорт переключить"
    if ($sel -eq "0" -or -not $map.ContainsKey($sel)) { Write-Warn "Отмена"; return }
    $target = $map[$sel]
    if ($target -eq $t) { Write-Warn "Уже на $curLbl"; return }
    if ($target -eq "xray" -and -not (Get-ActiveXrayName)) { Write-Warn "Нет активного xray-конфига."; return }
    if ($target -eq "hy2"  -and -not (Get-ActiveHy2Name))  { Write-Warn "Нет активного hy2-конфига."; return }
    $tLbl = if ($lbl[$target]) { $lbl[$target] } else { $target }
    if ($target -ne "awg") { Write-Host "Весь дом -> $tLbl (заблок-трафик пойдёт через $target)." -ForegroundColor Yellow }
    if (-not (_Confirm "Переключить транспорт на $tLbl ($target)?")) { Write-Warn "Отмена"; return }
    Write-Host ((Invoke-Router -Command "sh $AWG_DIR/transport.sh switch $target") -join "`n")
    # Ручной выбор = «домашний» транспорт (для авто-возврата в режиме home). Авто-cross
    # в watchdog .transport-home НЕ трогает — «дом» только ручной.
    Invoke-Router -Command "echo $target > $AWG_DIR/.transport-home" -Silent | Out-Null
    if ($target -eq "xray") { Show-XrayEgressVerdict (Get-ActiveXrayName) }
    elseif ($target -eq "hy2") { Show-Hy2EgressVerdict (Get-ActiveHy2Name) }
    $script:RouterSummary = Get-RouterSummary   # обновить «Протокол · Конфиг» в шапке
}

function Action-AddXrayConfig {
    Write-Section "Добавить xray-конфиг (vless:// или JSON)"
    Write-Host "Вставь vless://... одной строкой, либо путь к .json с xray-конфигом." -ForegroundColor DarkGray
    $raw = Read-Host "vless:// или путь к .json"
    if (-not $raw) { Write-Warn "Отмена"; return }
    $raw = $raw.Trim().Trim('"')
    $json = $null; $defName = "xray"
    if ($raw -match '^vless://') {
        $p = Parse-VlessLink $raw
        if (-not $p) { Write-Err "Не разобрал vless://"; return }
        if ($p.security -eq 'reality' -and -not $p.pbk) { Write-Warn "В ссылке нет pbk (Reality publicKey) — проверь" }
        $json = New-XrayConfigJson $p
        if ($p.remark) { $defName = $p.remark }
    } elseif (Test-Path -LiteralPath $raw -PathType Leaf) {
        try { $json = [System.IO.File]::ReadAllText($raw, [System.Text.Encoding]::UTF8); $null = $json | ConvertFrom-Json }
        catch { Write-Err "Файл не парсится как JSON"; return }
        $defName = [System.IO.Path]::GetFileNameWithoutExtension($raw)
    } else {
        try { $null = $raw | ConvertFrom-Json; $json = $raw } catch { Write-Err "Не vless:// и не JSON"; return }
    }
    $defName = ($defName -replace '[^A-Za-z0-9._-]', '-'); if (-not $defName) { $defName = "xray" }
    $inName = Read-Host "Имя конфига (Enter = '$defName')"
    $name = if ($inName) { $inName.Trim() } else { $defName }
    if ($name -notmatch '^[A-Za-z0-9._-]+$') { Write-Err "Имя: латиница/цифры/._-"; return }
    Invoke-Router -Command "mkdir -p $AWG_DIR/xray-configs" -Silent | Out-Null
    if (-not (Send-RouterFileAtomic "$AWG_DIR/xray-configs/$name.json" $json 600)) { Write-Err "Не залил конфиг"; return }
    Write-Ok "xray-конфиг '$name' сохранён"
    if (_Confirm "Сделать '$name' активным сейчас?") { Set-ActiveXrayConfig $name }
    else { Write-Host "Активировать позже: «Выбрать активный xray-конфиг»." -ForegroundColor DarkGray }
}

function Action-SwitchXrayConfig {
    Write-Section "Выбрать активный xray-конфиг"
    $names = Get-XrayConfigNames
    if ($names.Count -eq 0) { Write-Warn "Нет xray-конфигов."; return }
    $active = Get-ActiveXrayName
    $i = 1; $map = @{}
    foreach ($n in $names) { $mk = if ($n -eq $active) { "  <- активный" } else { "" }; Write-Host "  $i) $n$mk"; $map["$i"] = $n; $i++ }
    Write-Host "  0) Отмена"
    $sel = Read-Host "Номер"
    if ($sel -eq "0" -or -not $map.ContainsKey($sel)) { Write-Warn "Отмена"; return }
    Set-ActiveXrayConfig $map[$sel]
}

function Action-EditXrayReality {
    Write-Section "Правка SNI / fingerprint xray-конфига"
    $names = Get-XrayConfigNames
    if ($names.Count -eq 0) { Write-Warn "Нет xray-конфигов."; return }
    $active = Get-ActiveXrayName
    $i = 1; $map = @{}
    foreach ($n in $names) { $mk = if ($n -eq $active) { "  <- активный" } else { "" }; Write-Host "  $i) $n$mk"; $map["$i"] = $n; $i++ }
    Write-Host "  0) Отмена"
    $sel = Read-Host "Какой конфиг править"
    if ($sel -eq "0" -or -not $map.ContainsKey($sel)) { Write-Warn "Отмена"; return }
    $name = $map[$sel]
    $txt = "" + (Invoke-Router -Command "cat $AWG_DIR/xray-configs/$name.json 2>/dev/null" -Silent)
    if (-not $txt.Trim()) { Write-Err "Не прочитал конфиг"; return }
    try { $obj = $txt | ConvertFrom-Json } catch { Write-Err "Конфиг не парсится"; return }
    $ss = $obj.outbounds[0].streamSettings
    $rs = $null
    if ($ss.PSObject.Properties.Name -contains 'realitySettings') { $rs = $ss.realitySettings }
    elseif ($ss.PSObject.Properties.Name -contains 'tlsSettings') { $rs = $ss.tlsSettings }
    if (-not $rs) { Write-Err "В конфиге нет reality/tls settings"; return }
    Write-Host ("Сейчас: SNI=" + $rs.serverName + "  fp=" + $rs.fingerprint)
    Write-Warn "fingerprint меняется свободно (uTLS, клиент). SNI поможет ТОЛЬКО если сервер разрешает несколько serverNames — иначе оборвёт хэндшейк!"
    $newFp = Read-Host "Новый fingerprint (chrome/firefox/safari/ios/edge/random; Enter=без изм)"
    $newSni = Read-Host "Новый SNI/serverName (Enter=без изм)"
    if ($newFp) { $rs.fingerprint = $newFp.Trim() }
    if ($newSni) { $rs.serverName = $newSni.Trim() }
    $newJson = $obj | ConvertTo-Json -Depth 12
    if (-not (Send-RouterFileAtomic "$AWG_DIR/xray-configs/$name.json" $newJson 600)) { Write-Err "Не сохранил"; return }
    Write-Ok "Сохранено"
    if ($name -eq $active) { Set-ActiveXrayConfig $name }
}

function Action-DeleteXrayConfig {
    Write-Section "Удалить xray-конфиг"
    $names = Get-XrayConfigNames
    if ($names.Count -eq 0) { Write-Warn "Нет xray-конфигов."; return }
    $active = Get-ActiveXrayName
    $i = 1; $map = @{}
    foreach ($n in $names) { $mk = if ($n -eq $active) { "  <- активный" } else { "" }; Write-Host "  $i) $n$mk"; $map["$i"] = $n; $i++ }
    Write-Host "  0) Отмена"
    $sel = Read-Host "Какой удалить"
    if ($sel -eq "0" -or -not $map.ContainsKey($sel)) { Write-Warn "Отмена"; return }
    $name = $map[$sel]
    if ($name -eq $active -and (Get-Transport) -eq "xray") { Write-Err "Активный конфиг при транспорте xray — сначала переключись на awg."; return }
    if (-not (_Confirm "Удалить xray-конфиг '$name'?")) { Write-Warn "Отмена"; return }
    Invoke-Router -Command "rm -f $AWG_DIR/xray-configs/$name.json" -Silent | Out-Null
    if ($name -eq $active) { Invoke-Router -Command "rm -f $AWG_DIR/.xray-active" -Silent | Out-Null }
    Write-Ok "Удалён: $name"
}

# ============================================================
# Hysteria2-транспорт (альтернатива Xray; на флеше живёт ОДИН альт — xray ЛИБО hy2).
# Несущая та же (xtun через общий hev + socks 127.0.0.1:10808), меняется лишь локальный
# socks-сервер. Конфиги — $AWG_DIR/hy2-configs/<name>.yaml (секрет), активный копируется
# в hysteria.yaml. YAML простой — генерим/правим ЗДЕСЬ (на роутере нет yaml-парсера).
# ============================================================
function Get-Hy2ConfigNames {
    $raw = Invoke-Router -Command "ls -1 $AWG_DIR/hy2-configs/ 2>/dev/null | grep '\.yaml$' | sed 's/\.yaml$//'" -Silent
    if (-not $raw) { return @() }
    return @((("" + ($raw -join "`n")) -split "`r?`n") | Where-Object { $_ -and $_.Trim() -ne "" } | ForEach-Object { $_.Trim() })
}
function Get-ActiveHy2Name { return ("" + (Invoke-Router -Command "cat $AWG_DIR/.hy2-active 2>/dev/null" -Silent)).Trim() }

# Парсер hy2:// / hysteria2:// : auth@host:port/?sni=&insecure=&obfs=&obfs-password=#remark
function Parse-Hy2Link {
    param([string]$link)
    if ($link -match '^hysteria2://') { $s = $link.Substring(12) }
    elseif ($link -match '^hy2://')   { $s = $link.Substring(6) }
    else { return $null }
    $remark = ""
    if ($s.Contains('#')) { $k = $s.IndexOf('#'); $remark = [uri]::UnescapeDataString($s.Substring($k + 1)); $s = $s.Substring(0, $k) }
    $query = ""
    if ($s.Contains('?')) { $k = $s.IndexOf('?'); $query = $s.Substring($k + 1); $s = $s.Substring(0, $k) }
    $s = $s.TrimEnd('/')
    # auth = всё до последнего @ (пароль может содержать что угодно, кроме @); host:port — хвост.
    if ($s -notmatch '^(.*)@([^@:]+):(\d+)$') { return $null }
    $p = @{ auth = [uri]::UnescapeDataString($Matches[1]); host = $Matches[2]; port = $Matches[3]; remark = $remark; insecure = $false }
    foreach ($kv in ($query -split '&')) {
        if (-not $kv) { continue }
        $eq = $kv.IndexOf('='); if ($eq -lt 0) { continue }
        $key = $kv.Substring(0, $eq); $val = [uri]::UnescapeDataString($kv.Substring($eq + 1))
        switch ($key) {
            'sni'          { $p.sni = $val }
            'insecure'     { $p.insecure = ($val -eq '1' -or $val -eq 'true') }
            'obfs'         { $p.obfs = $val }
            'obfs-password' { $p.obfsPass = $val }
            'obfsParam'    { $p.obfsPass = $val }
        }
    }
    if (-not $p.sni) { $p.sni = $p.host }
    return $p
}

# YAML-строка значения в двойных кавычках (пароли/obfs могут содержать спецсимволы YAML).
function _Hy2Quote($v) { return '"' + (($v -replace '\\', '\\') -replace '"', '\"') + '"' }

function New-Hy2ConfigYaml {
    param([hashtable]$P)
    $sni = if ($P.sni) { $P.sni } else { $P.host }
    $ins = if ($P.insecure) { 'true' } else { 'false' }
    $lines = @()
    $lines += "server: $($P.host):$($P.port)"
    $lines += "auth: $(_Hy2Quote $P.auth)"
    $lines += "tls:"
    $lines += "  sni: $sni"
    $lines += "  insecure: $ins"
    if ($P.obfs -eq 'salamander' -and $P.obfsPass) {
        $lines += "obfs:"
        $lines += "  type: salamander"
        $lines += "  salamander:"
        $lines += "    password: $(_Hy2Quote $P.obfsPass)"
    }
    # socks5.listen ЖЁСТКО 127.0.0.1:10808 — должно совпадать с hev.yaml и health-пробой.
    $lines += "socks5:"
    $lines += "  listen: 127.0.0.1:10808"
    return (($lines -join "`n") + "`n")
}

# Мгновенная проба egress через socks 10808 (как Show-XrayEgressVerdict — тот же порт).
function Show-Hy2EgressVerdict {
    param([string]$name)
    Write-Host "Проверяю egress через hysteria..." -ForegroundColor DarkGray
    $ip = ("" + (Invoke-Router -Command "curl -s --max-time 8 --socks5-hostname 127.0.0.1:10808 https://api.ipify.org 2>/dev/null" -Silent)).Trim()
    if ($ip) {
        Write-Ok "Hysteria2 '$name' работает — выходной IP: $ip"
    } else {
        Write-Warn "Hysteria2 '$name' подключился, но egress ПУСТ — сервер/конфиг не отвечает (порт/sni/insecure/пароль?)."
        Write-Host "  Авто-failover вернёт рабочий резерв через ~2-4 мин (анти-дребезг)," -ForegroundColor Yellow
        Write-Host "  либо выбери другой hy2-конфиг сейчас (Протокол -> Выбрать активный hy2-конфиг)." -ForegroundColor Yellow
    }
}

function Set-ActiveHy2Config {
    param([string]$name)
    $cmd = "cp $AWG_DIR/hy2-configs/$name.yaml $AWG_DIR/hysteria.yaml && chmod 600 $AWG_DIR/hysteria.yaml && echo $name > $AWG_DIR/.hy2-active && echo OK"
    $out = Invoke-Router -Command $cmd
    if ("$out" -notmatch "OK") { Write-Err "Не удалось активировать $name"; Write-Host ($out -join "`n"); return }
    Write-Ok "Активный hy2-конфиг: $name"
    if ((Get-Transport) -eq "hy2") {
        Write-Host "Транспорт=hy2 — перезапускаю с новым конфигом..." -ForegroundColor DarkGray
        Write-Host ((Invoke-Router -Command "sh $AWG_DIR/transport-hy2.sh down; sh $AWG_DIR/transport-hy2.sh up") -join "`n")
        Show-Hy2EgressVerdict $name
    }
    $script:RouterSummary = Get-RouterSummary   # обновить «Протокол · Конфиг» в шапке
}

function Action-AddHy2Config {
    Write-Section "Добавить hy2-конфиг (hy2:// или hysteria2://)"
    Write-Host "Вставь hy2://... одной строкой (от своего Hysteria2-сервера)." -ForegroundColor DarkGray
    $raw = Read-Host "hy2:// или hysteria2://"
    if (-not $raw) { Write-Warn "Отмена"; return }
    $raw = $raw.Trim().Trim('"')
    $p = Parse-Hy2Link $raw
    if (-not $p) { Write-Err "Не разобрал hy2://-ссылку"; return }
    if (-not $p.obfs) { Write-Warn "В ссылке нет obfs (Salamander) — без него hy2 = голый QUIC/TLS, DPI может палить. Для РФ желателен obfs на сервере." }
    $yaml = New-Hy2ConfigYaml $p
    $defName = if ($p.remark) { $p.remark } else { "hy2" }
    $defName = ($defName -replace '[^A-Za-z0-9._-]', '-'); if (-not $defName) { $defName = "hy2" }
    $inName = Read-Host "Имя конфига (Enter = '$defName')"
    $name = if ($inName) { $inName.Trim() } else { $defName }
    if ($name -notmatch '^[A-Za-z0-9._-]+$') { Write-Err "Имя: латиница/цифры/._-"; return }
    Invoke-Router -Command "mkdir -p $AWG_DIR/hy2-configs" -Silent | Out-Null
    if (-not (Send-RouterFileAtomic "$AWG_DIR/hy2-configs/$name.yaml" $yaml 600)) { Write-Err "Не залил конфиг"; return }
    Write-Ok "hy2-конфиг '$name' сохранён"
    if (_Confirm "Сделать '$name' активным сейчас?") { Set-ActiveHy2Config $name }
    else { Write-Host "Активировать позже: «Выбрать активный hy2-конфиг»." -ForegroundColor DarkGray }
}

function Action-SwitchHy2Config {
    Write-Section "Выбрать активный hy2-конфиг"
    $names = Get-Hy2ConfigNames
    if ($names.Count -eq 0) { Write-Warn "Нет hy2-конфигов."; return }
    $active = Get-ActiveHy2Name
    $i = 1; $map = @{}
    foreach ($n in $names) { $mk = if ($n -eq $active) { "  <- активный" } else { "" }; Write-Host "  $i) $n$mk"; $map["$i"] = $n; $i++ }
    Write-Host "  0) Отмена"
    $sel = Read-Host "Номер"
    if ($sel -eq "0" -or -not $map.ContainsKey($sel)) { Write-Warn "Отмена"; return }
    Set-ActiveHy2Config $map[$sel]
}

function Action-EditHy2 {
    Write-Section "Правка SNI / insecure hy2-конфига"
    $names = Get-Hy2ConfigNames
    if ($names.Count -eq 0) { Write-Warn "Нет hy2-конфигов."; return }
    $active = Get-ActiveHy2Name
    $i = 1; $map = @{}
    foreach ($n in $names) { $mk = if ($n -eq $active) { "  <- активный" } else { "" }; Write-Host "  $i) $n$mk"; $map["$i"] = $n; $i++ }
    Write-Host "  0) Отмена"
    $sel = Read-Host "Какой конфиг править"
    if ($sel -eq "0" -or -not $map.ContainsKey($sel)) { Write-Warn "Отмена"; return }
    $name = $map[$sel]
    # ВАЖНО: Invoke-Router возвращает МАССИВ строк; `"" + массив` склеил бы их через
    # $OFS = ПРОБЕЛ → все переводы строк YAML стали бы пробелами, файл схлопнулся бы в
    # ОДНУ строку. YAML чувствителен к переносам (ключи на своих строках), и на роутере
    # busybox `grep '^server:'` тогда хватает ВЕСЬ файл как значение server → резолв
    # server-host падает, несущая не встаёт. Поэтому собираем обратно через `n (LF).
    $txt = ((Invoke-Router -Command "cat $AWG_DIR/hy2-configs/$name.yaml 2>/dev/null" -Silent) -join "`n")
    if (-not $txt.Trim()) { Write-Err "Не прочитал конфиг"; return }
    $curSni = if ($txt -match '(?m)^\s*sni:\s*(.+?)\s*$') { $Matches[1] } else { "?" }
    $curIns = if ($txt -match '(?m)^\s*insecure:\s*(.+?)\s*$') { $Matches[1] } else { "?" }
    Write-Host ("Сейчас: SNI=$curSni  insecure=$curIns")
    Write-Warn "SNI помогает ТОЛЬКО если сервер допускает это имя в сертификате — иначе TLS оборвётся."
    $newSni = Read-Host "Новый SNI (Enter=без изм)"
    $newIns = Read-Host "insecure true/false (Enter=без изм)"
    $txt = ($txt -replace "`r", "")
    if ($newSni) { $txt = $txt -replace '(?m)^(\s*sni:\s*).*$', "`${1}$($newSni.Trim())" }
    if ($newIns -eq 'true' -or $newIns -eq 'false') { $txt = $txt -replace '(?m)^(\s*insecure:\s*).*$', "`${1}$newIns" }
    if (-not (Send-RouterFileAtomic "$AWG_DIR/hy2-configs/$name.yaml" $txt 600)) { Write-Err "Не сохранил"; return }
    Write-Ok "Сохранено"
    if ($name -eq $active) { Set-ActiveHy2Config $name }
}

function Action-DeleteHy2Config {
    Write-Section "Удалить hy2-конфиг"
    $names = Get-Hy2ConfigNames
    if ($names.Count -eq 0) { Write-Warn "Нет hy2-конфигов."; return }
    $active = Get-ActiveHy2Name
    $i = 1; $map = @{}
    foreach ($n in $names) { $mk = if ($n -eq $active) { "  <- активный" } else { "" }; Write-Host "  $i) $n$mk"; $map["$i"] = $n; $i++ }
    Write-Host "  0) Отмена"
    $sel = Read-Host "Какой удалить"
    if ($sel -eq "0" -or -not $map.ContainsKey($sel)) { Write-Warn "Отмена"; return }
    $name = $map[$sel]
    if ($name -eq $active -and (Get-Transport) -eq "hy2") { Write-Err "Активный конфиг при транспорте hy2 — сначала переключись на другой транспорт."; return }
    if (-not (_Confirm "Удалить hy2-конфиг '$name'?")) { Write-Warn "Отмена"; return }
    Invoke-Router -Command "rm -f $AWG_DIR/hy2-configs/$name.yaml" -Silent | Out-Null
    if ($name -eq $active) { Invoke-Router -Command "rm -f $AWG_DIR/.hy2-active" -Silent | Out-Null }
    Write-Ok "Удалён: $name"
}

function Action-DeleteAwgConfig {
    Write-Section "Удалить конфиг страны (awg)"
    $raw = Invoke-Router -Command "ls -1 $AWG_DIR/configs/ 2>/dev/null | grep '\.conf$' | sed 's/\.conf$//'" -Silent
    $names = @((("" + ($raw -join "`n")) -split "`r?`n") | Where-Object { $_ -and $_.Trim() -ne "" } | ForEach-Object { $_.Trim() })
    if ($names.Count -eq 0) { Write-Warn "Папка configs/ пуста."; return }
    $active = ("" + (Invoke-Router -Command "cat $AWG_DIR/.active 2>/dev/null" -Silent)).Trim()
    $i = 1; $map = @{}
    foreach ($n in $names) { $mk = if ($n -eq $active) { "  <- активный" } else { "" }; Write-Host "  $i) $n$mk"; $map["$i"] = $n; $i++ }
    Write-Host "  0) Отмена"
    $sel = Read-Host "Какой удалить"
    if ($sel -eq "0" -or -not $map.ContainsKey($sel)) { Write-Warn "Отмена"; return }
    $name = $map[$sel]
    if ($name -eq $active) { Write-Err "Нельзя удалить активный конфиг ($name) — сначала переключись на другой."; return }
    if (-not (_Confirm "Удалить awg-конфиг '$name'?")) { Write-Warn "Отмена"; return }
    Invoke-Router -Command "rm -f $AWG_DIR/configs/$name.conf" -Silent | Out-Null
    Write-Ok "Удалён: configs/$name.conf"
}

function Action-DomainList {
    Write-Section "Домены, идущие через AWG (domain.sh list)"
    $cmd = "if command -v domain >/dev/null 2>&1; then domain list; else sh $AWG_DIR/domain.sh list; fi"
    $out = Invoke-Router -Command $cmd
    Write-Host ($out -join "`n")
}

function Action-DomainAdd {
    Write-Section "Добавить домен в VPN"
    $d = Read-Host "Домен (например chatgpt.com)"
    if (-not $d) { Write-Warn "Отмена"; return }
    $d = $d.Trim()
    if ($d -notmatch '^[A-Za-z0-9.\-]+$') { Write-Err "Подозрительные символы в домене"; return }
    $cmd = "if command -v domain >/dev/null 2>&1; then domain add $d; else sh $AWG_DIR/domain.sh add $d; fi"
    Write-Host (Invoke-Router -Command $cmd)
}

function Action-DomainRemove {
    Write-Section "Удалить домен"
    $d = Read-Host "Домен"
    if (-not $d) { Write-Warn "Отмена"; return }
    $d = $d.Trim()
    if ($d -notmatch '^[A-Za-z0-9.\-]+$') { Write-Err "Подозрительные символы"; return }
    $cmd = "if command -v domain >/dev/null 2>&1; then domain remove $d; else sh $AWG_DIR/domain.sh remove $d; fi"
    Write-Host (Invoke-Router -Command $cmd)
}

function Action-DomainSearch {
    Write-Section "Поиск домена во всех списках"
    $q = Read-Host "Что искать (часть строки, напр. openai)"
    if (-not $q) { Write-Warn "Отмена"; return }
    if ($q -notmatch '^[A-Za-z0-9.\-]+$') { Write-Err "Только латиница/цифры/точки/дефис"; return }
    $cmd = "if command -v domain >/dev/null 2>&1; then domain search $q; else sh $AWG_DIR/domain.sh search $q; fi"
    Write-Host (Invoke-Router -Command $cmd)
}

# ------------------------------------------------------------
# iplist.conf — модель «прочитать -> изменить ключ -> записать» + кастомный файл
# ------------------------------------------------------------
# Источник CIDR-списка (ipset iplist_set) описывает $AWG_DIR/iplist.conf, его
# читает iplist-update.sh ('. iplist.conf' busybox'ом). Поэтому строго LF и без
# $/кавычек/бэктиков в значениях. Пишем через base64 -> stdin plink -> 'base64 -d',
# .new + атомарный mv (прерванная заливка не затрёт рабочий файл).
#
# ДВЕ ОРТОГОНАЛЬНЫЕ оси настройки (потому conf не пересобираем с нуля, а
# читаем -> меняем нужный ключ -> пишем — смена одной оси не сбрасывает другую):
#   1) источник СКАЧИВАНИЯ: дефолт opencck cidr4 / IPLIST_SITES / IPLIST_URL;
#   2) кастомный ЛОКАЛЬНЫЙ файл (IPLIST_CUSTOM_MODE): off / only / merge.
function Send-RouterFileAtomic {
    # Атомарно записать текст в файл на роутере: нормализуем CRLF->LF, base64 ->
    # stdin plink -> 'base64 -d' -> .new + mv + chmod. Возвращает $true/$false.
    param([string]$RemotePath, [string]$Content, [int]$Mode = 600)
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Content -replace "`r`n", "`n")))
    $cmd = "base64 -d > '$RemotePath.new' && mv '$RemotePath.new' '$RemotePath' && chmod $Mode '$RemotePath' && echo SAVED `$(wc -c < '$RemotePath') || { rm -f '$RemotePath.new'; echo FAILED; }"
    $out = Invoke-Router -Command $cmd -StdinData $b64
    if ("$out" -notmatch "SAVED") { Write-Host ($out -join "`n"); return $false }
    return $true
}
function Write-IplistConf {
    param([string]$Content)
    if (-not (Send-RouterFileAtomic "$AWG_DIR/iplist.conf" $Content)) { Write-Err "Не удалось записать iplist.conf"; return $false }
    Write-Ok "iplist.conf сохранён"
    return $true
}
function Get-IplistConf {
    # Прочитать текущий iplist.conf с роутера в hashtable IPLIST_* (без обрамляющих
    # кавычек). Нет файла -> пустой hash (дефолт).
    $h = @{}
    $raw = Invoke-Router -Command "cat '$AWG_DIR/iplist.conf' 2>/dev/null" -Silent
    if (-not $raw) { return $h }
    foreach ($ln in (("" + ($raw -join "`n")) -split "`n")) {
        if ($ln -match '^\s*#') { continue }
        if ($ln -match '^\s*(IPLIST_[A-Z_]+)\s*=\s*(.*)$') {
            $k = $Matches[1]; $v = $Matches[2].Trim()
            if ($v -match '^"(.*)"$') { $v = $Matches[1] } elseif ($v -match "^'(.*)'$") { $v = $Matches[1] }
            $h[$k] = $v
        }
    }
    return $h
}
function Format-IplistConf {
    param([hashtable]$H, [string]$Origin = "be7000")
    $out = "# iplist.conf — источник списка IP для iplist-update.sh (через be7000: $Origin)`n" +
           "# Сорсится busybox: строго LF, без спецсимволов в значениях. Правка — через be7000.`n"
    foreach ($k in @('IPLIST_URL','IPLIST_SITES','IPLIST_BASE','IPLIST_MIN_LINES','IPLIST_CUSTOM_MODE','IPLIST_CUSTOM_FILE')) {
        if ($H.ContainsKey($k) -and ("" + $H[$k]) -ne "") { $out += ('{0}="{1}"' -f $k, $H[$k]) + "`n" }
    }
    return $out
}
function Set-IplistConf {
    # Прочитать conf -> применить Set (хеш ключ=значение) и Remove (список ключей) -> записать.
    param([hashtable]$Set = @{}, [string[]]$Remove = @(), [string]$Origin = "меню")
    $h = Get-IplistConf
    foreach ($k in $Remove) { if ($h.ContainsKey($k)) { $h.Remove($k) | Out-Null } }
    foreach ($k in $Set.Keys) { $h[$k] = $Set[$k] }
    return (Write-IplistConf (Format-IplistConf $h $Origin))
}
# Валидаторы значений источника скачивания (зовутся из меню и установки).
function Get-ValidatedSites {
    param([string]$Raw)
    $sites = @($Raw -split '[,\s]+' | Where-Object { $_ -ne "" })
    if ($sites.Count -eq 0) { Write-Warn "Пусто"; return $null }
    $bad = @($sites | Where-Object { $_ -notmatch '^[A-Za-z0-9.\-]+$' })
    if ($bad.Count -gt 0) { Write-Err "Недопустимые имена: $($bad -join ', ')"; return $null }
    return ($sites -join ' ')
}
function Get-ValidatedUrl {
    param([string]$Raw)
    $u = $Raw.Trim()
    if ($u -notmatch '^https?://') { Write-Err "URL должен начинаться с http:// или https://"; return $null }
    # Запрещаем символы, ломающие значение в двойных кавычках при source.
    if ($u -match '["`$\\]') { Write-Err "URL содержит запрещённый символ (кавычка/бэктик/доллар/обратный слеш)"; return $null }
    return $u
}
function Upload-CustomIplist {
    # Прочитать локальный .txt со списком CIDR/IPv4, провалидировать и атомарно
    # залить в $AWG_DIR/iplist.custom. Ввод — ПУТЬ (можно перетащить файл в окно
    # консоли: drag-drop вставит путь, часто в кавычках). Возвращает $true при успехе.
    Write-Host "Перетащи .txt в окно консоли или укажи путь к файлу со списком IP/подсетей." -ForegroundColor DarkGray
    Write-Host "Формат: одна CIDR/IPv4 в строке (напр. 104.16.0.0/12 или 8.8.8.8). # — комментарии, пустые строки ок." -ForegroundColor DarkGray
    $path = Read-Host "Путь к .txt"
    if (-not $path) { Write-Warn "Пусто, отмена"; return $false }
    $path = $path.Trim().Trim('"').Trim("'")
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Write-Err "Файл не найден: $path"; return $false }

    # Читаем ЯВНО UTF-8 (грабля CP1251 на ру-Windows для файлов без BOM).
    try { $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) }
    catch { Write-Err "Не прочитать файл: $($_.Exception.Message)"; return $false }

    # txt-only в этом заходе: похожее на JSON отбиваем сразу.
    if ($text.TrimStart() -match '^[\{\[]') { Write-Err "Похоже на JSON. Нужен простой текст: одна CIDR/IP в строке. (Другие форматы — позже.)"; return $false }

    # IPv4 ± маска, с проверкой диапазонов октетов (0-255) и маски (0-32).
    $reIp = '^((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(/(3[0-2]|[12]?\d))?$'
    $valid = New-Object System.Collections.Generic.List[string]
    $bad   = New-Object System.Collections.Generic.List[string]
    foreach ($ln in ($text -split "`r?`n")) {
        $t = ($ln -replace '#.*$', '').Trim()   # срезать inline-комментарий и пробелы
        if ($t -eq "") { continue }              # пустые/чистые комментарии — молча мимо
        if ($t -match $reIp) { $valid.Add($t) | Out-Null } else { $bad.Add($ln.Trim()) | Out-Null }
    }

    if ($valid.Count -eq 0) {
        Write-Err "В файле нет валидных CIDR/IPv4 — отмена (ничего не залито)."
        if ($bad.Count -gt 0) { Write-Host ("Примеры непонятных строк: " + (($bad | Select-Object -First 5) -join ' | ')) -ForegroundColor DarkGray }
        return $false
    }
    if ($bad.Count -gt 0) { Write-Warn "Отброшено невалидных строк: $($bad.Count) (примеры: $(($bad | Select-Object -First 5) -join ' | '))" }
    # Бюджет /data тесный (~4 МБ) — гард на размер списка.
    if ($valid.Count -gt 50000) { Write-Err "Слишком большой список: $($valid.Count) строк (лимит 50000 — /data на роутере мал)."; return $false }
    Write-Ok "Валидных подсетей/IP: $($valid.Count)"

    $content = "# iplist.custom — кастомный список IP/подсетей (залит через be7000)`n" +
               "# Одна CIDR/IPv4 в строке. Читается iplist-update.sh (режим only/merge).`n" +
               (($valid -join "`n")) + "`n"
    Write-Host "Заливаю $AWG_DIR/iplist.custom ..." -ForegroundColor DarkGray
    if (-not (Send-RouterFileAtomic "$AWG_DIR/iplist.custom" $content)) { Write-Err "Не удалось залить кастомный список"; return $false }
    Write-Ok "Кастомный список залит: $($valid.Count) записей -> $AWG_DIR/iplist.custom"
    return $true
}
function Run-IplistUpdateNow {
    Write-Host "Запускаю iplist-update.sh (атомарный swap — текущая маршрутизация не прервётся) ..." -ForegroundColor DarkGray
    $upd = "sh $AWG_DIR/iplist-update.sh; echo '--- результат ---'; " +
           "ipset list iplist_set 2>/dev/null | grep -E '^(Name|Number of entries):'; " +
           "tail -n 5 /tmp/iplist-update.log 2>/dev/null"
    Write-Host ((Invoke-Router -Command $upd) -join "`n")
}
# Источник iplist на этапе УСТАНОВКИ: дефолт — весь cidr4 (файл не создаём,
# iplist-update.sh берёт дефолт), но сразу даём сузить, чтоб не лезть потом в «Источник списка IP».
function Prompt-IplistSourceAtInstall {
    Write-Section "Источник списка IP (iplist) для раздельного туннеля"
    Write-Host "Какие подсети гнать в VPN по CIDR-списку (помимо твоих доменов)?"
    Write-Host "  1) Дефолт: весь cidr4 с opencck (~3000+ подсетей: CF/Google/OpenAI/Discord/Meta)" -ForegroundColor Green
    Write-Host "  2) Только конкретные сайты (напр. discord.com youtube.com) — opencck"
    Write-Host "  3) Свой URL целиком — любой источник, отдающий CIDR/IP построчно"
    Write-Host "  4) Кастомный локальный .txt список (свой файл) — only/merge"
    Write-Host "  (поменять потом: «Сайты, домены и списки IP» -> Источник списка IP. Сайты: https://iplist.opencck.org)" -ForegroundColor DarkGray
    $sel = Read-Host "Выбор [1]"
    if (-not $sel) { $sel = "1" }
    switch ($sel) {
        "2" {
            $raw = Read-Host "Сайты (через пробел/запятую)"
            $sites = if ($raw) { Get-ValidatedSites $raw } else { $null }
            # порог снижаем: узкий список легитимно даёт мало строк (иначе анти-«страница-ошибки» отклонит).
            if ($sites) { Set-IplistConf -Set @{ IPLIST_SITES = $sites; IPLIST_MIN_LINES = '3' } -Origin "установка: сайты" | Out-Null }
            else { Write-Warn "-> оставляю дефолт" }
        }
        "3" {
            $u = Read-Host "URL (отдаёт CIDR/IP построчно, напр. format=text)"
            $url = if ($u) { Get-ValidatedUrl $u } else { $null }
            if ($url) { Set-IplistConf -Set @{ IPLIST_URL = $url } -Origin "установка: URL" | Out-Null; Write-Ok "Источник: $url" }
            else { Write-Warn "-> оставляю дефолт" }
        }
        "4" {
            if (Upload-CustomIplist) {
                Write-Host "  o) only  — ТОЛЬКО локальный файл, без интернета"
                Write-Host "  m) merge — opencck + локальный файл сверху [по умолчанию]"
                $m = Read-Host "Режим [m]"
                $mode = if ($m -eq 'o') { 'only' } else { 'merge' }
                Set-IplistConf -Set @{ IPLIST_CUSTOM_MODE = $mode } -Origin "установка: custom $mode" | Out-Null
                Write-Ok "Кастомный список включён ($mode)"
            } else { Write-Warn "-> оставляю дефолт (весь cidr4 с opencck)" }
        }
        default { Write-Info "Оставляю дефолт (весь cidr4 с opencck)." }
    }
}

function Action-IplistSource {
    # Управление источником CIDR-списка (ipset iplist_set). ДВЕ ОРТОГОНАЛЬНЫЕ оси:
    #   - источник СКАЧИВАНИЯ (opencck по умолчанию / сайты / свой URL);
    #   - кастомный ЛОКАЛЬНЫЙ файл (off / only / merge).
    # Conf читается-меняется-пишется по ключам (Set-IplistConf), поэтому смена одной
    # оси НЕ сбрасывает другую. iplist-update.sh при отсутствии IPLIST_* берёт дефолт
    # (весь cidr4 с opencck). Меню остаётся открытым для нескольких операций подряд.
    Write-Section "Источник списка IP (iplist)"

    # Есть ли уже залитый кастомный файл (для подсказок при включении only/merge).
    $hasCustom = { ("" + (Invoke-Router -Command "[ -s '$AWG_DIR/iplist.custom' ] && echo yes" -Silent)).Trim() -eq 'yes' }

    while ($true) {
        # Текущее состояние (read-only): значения conf + кастомный файл + счётчик set + хвост лога.
        $show = "cd '$AWG_DIR' 2>/dev/null; " + @'
if [ -f iplist.conf ]; then echo '--- iplist.conf (значения) ---'; grep -v '^#' iplist.conf | grep . || echo '(пусто -> дефолт: весь cidr4 с opencck)'; else echo '(нет iplist.conf -> дефолт: весь cidr4 с opencck)'; fi
printf '--- кастомный файл: '
if [ -s iplist.custom ]; then cnt=$(grep -c '^[0-9]' iplist.custom 2>/dev/null); echo "${cnt:-0} записей"; else echo '(нет iplist.custom)'; fi
printf '--- iplist_set: '
ipset list iplist_set 2>/dev/null | awk '/^Number of entries:/{print $NF" подсетей"}'
echo '--- лог (хвост) ---'
tail -n 3 /tmp/iplist-update.log 2>/dev/null
'@
        Write-Host ((Invoke-Router -Command $show -Silent) -join "`n") -ForegroundColor Gray
        Write-Host ""
        Write-Host "  Источник СКАЧИВАНИЯ (из интернета):" -ForegroundColor Cyan
        Write-Host "    1) opencck — весь cidr4 (дефолт: CF/Google/OpenAI/Discord/Meta)"
        Write-Host "    2) Только конкретные сайты на opencck (IPLIST_SITES)"
        Write-Host "    3) Свой URL целиком — любой источник, отдающий CIDR/IP построчно"
        Write-Host "  Кастомный ЛОКАЛЬНЫЙ файл:" -ForegroundColor Cyan
        Write-Host "    4) Залить / обновить локальный .txt список"
        Write-Host "    5) Режим: off   — не использовать локальный файл"
        Write-Host "    6) Режим: only  — ТОЛЬКО локальный файл, без интернета"
        Write-Host "    7) Режим: merge — интернет (1/2/3) + локальный файл сверху"
        Write-Host "  Прочее:" -ForegroundColor Cyan
        Write-Host "    8) Обновить список сейчас (iplist-update.sh)"
        Write-Host "    0) Назад"
        $sel = Read-Host "Выбор"

        $changed = $false
        switch ($sel) {
            "1" {
                if (Set-IplistConf -Remove @('IPLIST_URL','IPLIST_SITES','IPLIST_MIN_LINES') -Origin "меню: opencck дефолт") {
                    Write-Ok "Источник скачивания: весь cidr4 с opencck"; $changed = $true
                }
            }
            "2" {
                Write-Host "Сайты через пробел/запятую (напр.: discord.com discord.gg discord.media). Список: https://iplist.opencck.org" -ForegroundColor DarkGray
                $raw = Read-Host "Сайты"
                if ($raw) {
                    $sites = Get-ValidatedSites $raw
                    # порог снижаем: узкий список легитимно даёт мало строк (анти-«страница-ошибки» иначе отклонит).
                    if ($sites -and (Set-IplistConf -Set @{ IPLIST_SITES = $sites; IPLIST_MIN_LINES = '3' } -Remove @('IPLIST_URL') -Origin "меню: сайты")) {
                        Write-Ok "Источник скачивания: сайты [$sites]"; $changed = $true
                    }
                } else { Write-Warn "Пусто, не меняю" }
            }
            "3" {
                Write-Host "Полный URL. Должен отдавать CIDR/IP построчно (как iplist.opencck.org/?format=text)." -ForegroundColor DarkGray
                $u = Read-Host "URL"
                if ($u) {
                    $url = Get-ValidatedUrl $u
                    if ($url -and (Set-IplistConf -Set @{ IPLIST_URL = $url } -Remove @('IPLIST_SITES') -Origin "меню: свой URL")) {
                        Write-Ok "Источник скачивания: $url"; $changed = $true
                    }
                } else { Write-Warn "Пусто, не меняю" }
            }
            "4" {
                if (Upload-CustomIplist) {
                    $changed = $true
                    # Файл залит, но если режим ещё off — он не используется; предложим включить.
                    $cur = "" + (Get-IplistConf)['IPLIST_CUSTOM_MODE']
                    if ($cur -ne 'only' -and $cur -ne 'merge') {
                        Write-Host "Режим кастома сейчас OFF — файл пока не используется." -ForegroundColor Yellow
                        Write-Host "  o) only  — только этот файл, без интернета"
                        Write-Host "  m) merge — интернет + этот файл сверху"
                        Write-Host "  Enter — оставить off"
                        switch (Read-Host "Включить режим?") {
                            "o" { if (Set-IplistConf -Set @{ IPLIST_CUSTOM_MODE = 'only' }  -Origin "меню: custom only")  { Write-Ok "Режим кастома: only" } }
                            "m" { if (Set-IplistConf -Set @{ IPLIST_CUSTOM_MODE = 'merge' } -Origin "меню: custom merge") { Write-Ok "Режим кастома: merge" } }
                            default { Write-Info "Режим оставлен off" }
                        }
                    }
                }
            }
            "5" {
                # off: убираем ключ режима (файл НЕ удаляем — пусть лежит на будущее).
                if (Set-IplistConf -Remove @('IPLIST_CUSTOM_MODE') -Origin "меню: custom off") {
                    Write-Ok "Кастомный файл выключен (off). Сам файл не удалён."; $changed = $true
                }
            }
            "6" {
                if (-not (& $hasCustom)) { Write-Warn "Локального файла ещё нет — сначала пункт 4 (залить). only без файла оставит set пустым." }
                if (Set-IplistConf -Set @{ IPLIST_CUSTOM_MODE = 'only' } -Origin "меню: custom only") {
                    Write-Ok "Режим кастома: only (интернет не используется)"; $changed = $true
                }
            }
            "7" {
                if (-not (& $hasCustom)) { Write-Warn "Локального файла ещё нет — сначала пункт 4 (залить)." }
                if (Set-IplistConf -Set @{ IPLIST_CUSTOM_MODE = 'merge' } -Origin "меню: custom merge") {
                    Write-Ok "Режим кастома: merge (интернет + файл)"; $changed = $true
                }
            }
            "8" { Run-IplistUpdateNow }
            "0" { return }
            default { Write-Warn "Неизвестный пункт" }
        }

        if ($changed) {
            if (_Confirm "Применить сейчас (iplist-update.sh)?") { Run-IplistUpdateNow }
            else { Write-Host "Применится при следующем запуске (boot или 5:00), либо пункт 8." -ForegroundColor DarkGray }
        }
        Write-Host ""
    }
}

function Action-ChangePassword {
    Write-Section "Смена сохранённого пароля"
    if (Save-Password) { Write-Ok "Готово" }
}

function Action-RawSSH {
    Write-Section "Произвольная команда на роутере"
    # Короткие awg/vpn/domain в SSH НЕ работают (симлинков нет: / = squashfs ro),
    # поэтому подсказываем рабочие формы — полный путь sh $AWG_DIR/<скрипт>.sh.
    $c = Read-Host "Команда на роутере (напр. 'ip rule', 'sh $AWG_DIR/awg-status.sh', 'sh $AWG_DIR/switch-vpn.sh status')"
    if (-not $c) { return }
    $out = Invoke-Router -Command $c
    Write-Host ($out -join "`n")
}

# ============================================================
# Уведомления (e-mail через notify.sh + awg-watchdog.sh)
# ============================================================
function Action-NotifySetup {
    # Записывает $AWG_DIR/notify.conf (chmod 600) с Яндекс-кредами.
    # Пароль идёт на роутер через base64 на stdin (не в командной строке).
    Write-Section "Настроить почту для уведомлений (Яндекс SMTP)"
    Write-Host "Нужен Яндекс-ящик и ПАРОЛЬ ПРИЛОЖЕНИЯ (не основной пароль аккаунта)." -ForegroundColor DarkGray
    Write-Host "Яндекс Почта → Настройки → Безопасность → 'Пароли приложений' → 'Почта (IMAP/SMTP)'." -ForegroundColor DarkGray
    Write-Host "  Включить доступ по протоколам: https://yandex.ru/support/yandex-360/customers/mail/ru/mail-clients/others" -ForegroundColor DarkGray
    Write-Host "  Создать пароль приложения:     https://id.yandex.ru/security/app-passwords" -ForegroundColor DarkGray
    $email = Read-Host "Яндекс e-mail (логин@yandex.ru)"
    if (-not $email) { Write-Warn "Отмена"; return }
    $sec = Read-Host "Пароль приложения (ввод скрыт)" -AsSecureString
    if ($sec.Length -eq 0) { Write-Warn "Пустой пароль — отмена"; return }
    $bp = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $pass = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bp) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bp) }

    $conf = "SMTP_HOST=smtp.yandex.ru`nSMTP_PORT=465`nSMTP_USER=$email`nSMTP_PASS=$pass`nMAIL_TO=$email`n"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($conf))

    $plinkExe = Find-Plink
    if (-not $plinkExe) { Write-Err "plink.exe не найден"; return }
    $rootPwd = Get-StoredPassword
    if (-not $rootPwd) { if (-not (Save-Password)) { return }; $rootPwd = Get-StoredPassword }

    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    $r = $b64 | & $plinkExe -ssh -batch -pw $rootPwd "$ROUTER_USER@$ROUTER_IP" "base64 -d > $AWG_DIR/notify.conf && chmod 600 $AWG_DIR/notify.conf && echo CONF_SAVED"
    $ErrorActionPreference = $prevEAP
    if ("$r" -match "CONF_SAVED") {
        Write-Ok "Почта сохранена в $AWG_DIR/notify.conf (chmod 600)"
        if (_Confirm "Отправить тестовое письмо сейчас?") { Action-NotifyTest }
    } else {
        Write-Err "Не удалось сохранить notify.conf"; Write-Host ($r -join "`n")
    }
}

function Action-NotifyTest {
    Write-Section "Тест: отправить письмо с роутера сейчас"
    # Тема/текст латиницей: при передаче через plink кириллица в аргументах
    # может побиться. Реальные письма watchdog генерит на роутере (UTF-8) —
    # там кириллица корректна.
    # ВАЖНО: notify.sh ВЫХОДИТ С КОДОМ 0, даже когда почта НЕ настроена (нет
    # notify.conf или пустой SMTP_PASS) — это сделано нарочно, чтобы watchdog не
    # считал ненастроенную почту ошибкой. Значит «RC=0» САМ ПО СЕБЕ не означает,
    # что письмо ушло (так получался ложный «[OK] отправлено» при пустом конфиге).
    # Поэтому сперва проверяем конфиг на роутере; только если он есть и заполнен —
    # реальный RC notify.sh достоверен (0 = сервер принял 235+queued, 1 = отказ SMTP).
    $cmd = "cd $AWG_DIR || exit 1; " +
           "if [ ! -s notify.conf ]; then echo RESULT=NOCONF; exit 0; fi; " +
           "if ! grep -q '^SMTP_PASS=.' notify.conf; then echo RESULT=NOPASS; exit 0; fi; " +
           "sh notify.sh 'BE7000 notify test' 'If you got this, email notifications work.'; " +
           "echo RC=`$?; echo '---TAIL---'; tail -4 /tmp/notify.log"
    $out = Invoke-Router -Command $cmd
    $txt = ($out -join "`n")
    Write-Host $txt
    if     ($txt -match 'RESULT=NOCONF') { Write-Warn "Почта НЕ настроена: на роутере нет notify.conf (или он пуст). Письмо НЕ отправлено — сначала 'Настроить почту'." }
    elseif ($txt -match 'RESULT=NOPASS') { Write-Warn "notify.conf есть, но не заполнен пароль приложения (SMTP_PASS). Письмо НЕ отправлено — перезапусти 'Настроить почту'." }
    elseif ($txt -match 'RC=0')          { Write-Ok "Письмо отправлено и принято сервером Яндекса (250 queued) — проверь почту (и папку Спам)." }
    else                                 { Write-Warn "Сервер не принял письмо. Проверь логин и ПАРОЛЬ ПРИЛОЖЕНИЯ Яндекса (не основной пароль): 'Настроить почту'." }
}

function Action-NotifyToggle {
    Write-Section "Уведомления: включить / выключить"
    $flag = "$AWG_DIR/.notify-off"
    $state = ("" + (Invoke-Router -Command "[ -f $flag ] && echo OFF || echo ON" -Silent)).Trim()
    if ($state -match "OFF") {
        Write-Host "Сейчас: уведомления ВЫКЛЮЧЕНЫ."
        if (_Confirm "Включить уведомления?") {
            $out = Invoke-Router -Command "rm -f $flag && echo ENABLED"
            if ("$out" -match "ENABLED") { Write-Ok "Уведомления включены" } else { Write-Err "Не получилось"; Write-Host $out }
        }
    } else {
        Write-Host "Сейчас: уведомления ВКЛЮЧЕНЫ."
        if (_Confirm "Выключить уведомления? (watchdog продолжит чинить VPN, но письма слать не будет)") {
            $out = Invoke-Router -Command ": > $flag && echo DISABLED"
            if ("$out" -match "DISABLED") { Write-Ok "Уведомления выключены (флаг .notify-off)" } else { Write-Err "Не получилось"; Write-Host $out }
        }
    }
}

function Action-FailoverToggle {
    # Режим авто-failover (на роутере — файл .failover-mode: off|sticky|home).
    # off    — при падении VPS просто прямой режим (как было до фичи).
    # sticky — switch-vpn.sh failover: перебрать configs/*.conf по алфавиту,
    #          встать на первый рабочий и остаться (дефолт; нет файла → sticky).
    # home   — то же + возврат на «основной» (.failover-home), когда тот оживёт.
    Write-Section "Авто-failover при падении VPS (AmneziaWG и Xray)"
    $modeFile = "$AWG_DIR/.failover-mode"
    $homeFile = "$AWG_DIR/.failover-home"
    $escFile  = "$AWG_DIR/.failover-escalate"

    # Текущее состояние тянем простыми cat и парсим на стороне PS (без хрупкой
    # shell-логики в одной строке через plink).
    $out = Invoke-Router -Command "printf 'M:'; cat $modeFile 2>/dev/null; echo; printf 'H:'; cat $homeFile 2>/dev/null; echo; printf 'A:'; cat $AWG_DIR/.active 2>/dev/null; echo; printf 'E:'; cat $escFile 2>/dev/null; echo" -Silent
    $mode = "sticky"; $homeCfg = ""; $active = ""; $esc = "cross"
    foreach ($line in @($out)) {
        $t = "$line".Trim()
        if     ($t -match '^M:(.*)$') { $v = $matches[1].Trim(); if ($v) { $mode = $v } }
        elseif ($t -match '^H:(.*)$') { $homeCfg = $matches[1].Trim() }
        elseif ($t -match '^A:(.*)$') { $active = $matches[1].Trim() }
        elseif ($t -match '^E:(.*)$') { $v = $matches[1].Trim(); if ($v) { $esc = $v } }
    }
    if ($mode -notin @('off','sticky','home')) { $mode = 'sticky' }
    if ($esc  -notin @('cross','direct'))      { $esc  = 'cross' }

    Write-Host "При смерти активного сервера watchdog сам перебирает серверы ТЕКУЩЕГО"
    Write-Host "протокола (awg: configs/*.conf · xray: xray-configs/*.json) и встаёт на"
    Write-Host "первый рабочий, с письмом на почту."
    Write-Host ""
    $cur = switch ($mode) {
        'off'   { "ВЫКЛ — при падении просто прямой режим (как раньше)" }
        'home'  { "home — встать на резерв, вернуться на основной ('$homeCfg'), когда оживёт" }
        default { "sticky — встать на резерв и остаться на нём" }
    }
    $curEsc = if ($esc -eq 'direct') { "direct — прямой режим" } else { "cross — попробовать другой протокол" }
    Write-Host "Сейчас режим: $cur"
    Write-Host "При исчерпании серверов протокола: $curEsc"
    Write-Host "Активный awg-конфиг: $active"
    Write-Host ""
    Write-Host "  ось 1 — перебор серверов внутри протокола:" -ForegroundColor Cyan
    Write-Host "  1) Выключить (off)"                                       -ForegroundColor Yellow
    Write-Host "  2) sticky — встать на резерв и остаться"                  -ForegroundColor Green
    Write-Host "  3) home — то же + возврат на основной сервер И на домашний транспорт, когда оживут" -ForegroundColor Green
    Write-Host "  0) Отмена"
    $sel = (Read-Host "Выбор").Trim()
    $newMode = switch ($sel) { "1" { "off" } "2" { "sticky" } "3" { "home" } default { $null } }
    if (-not $newMode) { Write-Warn "Отмена"; return }

    $newHome = $homeCfg
    if ($newMode -eq "home") {
        $listOut = Invoke-Router -Command "ls -1 $AWG_DIR/configs/ 2>/dev/null | grep '\.conf$' | sed 's/\.conf$//'"
        $configs = @(($listOut -join "`n") -split "`r?`n" | Where-Object { $_ -and $_.Trim() -ne "" } | ForEach-Object { $_.Trim() })
        if ($configs.Count -eq 0) {
            Write-Warn "В $AWG_DIR/configs/ нет конфигов — для home нужны хотя бы 2. Отмена."
            return
        }
        Write-Host ""
        Write-Host "Какой конфиг считать ОСНОВНЫМ (куда возвращаться)?"
        $i = 1; $map = @{}
        foreach ($c in $configs) {
            $tag = if ($c -eq $homeCfg) { " (текущий основной)" } elseif ($c -eq $active) { " (активен сейчас)" } else { "" }
            Write-Host "  $i) $c$tag"
            $map[$i.ToString()] = $c; $i++
        }
        Write-Host "  0) Отмена"
        $hsel = (Read-Host "Номер").Trim()
        if (-not $map.ContainsKey($hsel)) { Write-Warn "Отмена"; return }
        $newHome = $map[$hsel]
    }

    # Ось 2 — что делать, когда серверы активного протокола ИСЧЕРПАНЫ (только при
    # включённом failover). cross — перебрать другой протокол (awg<->xray), затем
    # прямой режим; direct — сразу прямой режим. Анти-петля встроена в watchdog
    # (каждый протокол перебирается ≤1 раза за эпизод → терминал всегда safety_off).
    $newEsc = $esc
    if ($newMode -ne "off") {
        Write-Host ""
        Write-Host "  ось 2 — когда серверы активного протокола закончились:" -ForegroundColor Cyan
        Write-Host "  1) cross — попробовать ДРУГОЙ протокол (awg<->xray), потом прямой" -ForegroundColor Green
        Write-Host "  2) direct — сразу прямой режим (без смены протокола)"             -ForegroundColor Yellow
        Write-Host "  (Enter — оставить: $esc)"
        $esel = (Read-Host "Выбор").Trim()
        $newEsc = switch ($esel) { "1" { "cross" } "2" { "direct" } "" { $esc } default { $esc } }
    }

    if ($newMode -eq "home") {
        $apply = "echo home > $modeFile && echo $newHome > $homeFile && echo $newEsc > $escFile && echo OK"
    } else {
        $apply = "echo $newMode > $modeFile && echo $newEsc > $escFile && echo OK"
    }
    $r = Invoke-Router -Command $apply
    if ("$r" -match "OK") {
        switch ($newMode) {
            "off"   { Write-Ok "Авто-failover ВЫКЛЮЧЕН (при падении VPS — прямой режим)" }
            "home"  { Write-Ok "Режим: home (основной = '$newHome')" }
            default { Write-Ok "Режим: sticky (встать на резерв и остаться)" }
        }
        if ($newMode -ne "off") {
            if ($newEsc -eq "direct") { Write-Ok "При исчерпании протокола: direct (прямой режим)" }
            else                      { Write-Ok "При исчерпании протокола: cross (перебрать другой протокол)" }
        }
    } else { Write-Err "Не получилось"; Write-Host ($r -join "`n") }
}

# ============================================================
# Главное меню
# ============================================================
# ============================================================
# УСТАНОВКА / ОБСЛУЖИВАНИЕ (из бывшего amnezia-install.ps1)
# ============================================================
function Find-Tool($name) {
    $candidates = @(
        "C:\Program Files\PuTTY\$name",
        "C:\Program Files (x86)\PuTTY\$name",
        $name
    )
    foreach ($p in $candidates) {
        if (Test-Path $p) { return $p }
        $cmd = Get-Command $p -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    return $null
}

function Find-Plink { Find-Tool "plink.exe" }

function Find-Pscp  { Find-Tool "pscp.exe"  }

function Ensure-Password {
    $p = Get-StoredPassword
    if ($p) { return $p }
    Write-Warn "Пароль ещё не сохранён"
    if (-not (Save-Password)) { return $null }
    return Get-StoredPassword
}

function Run-SSH($cmd) {
    $r = Invoke-Router -Command $cmd
    if ($r) { return $r }
    return $null
}

function Upload-File {
    param([string]$LocalPath, [string]$RemotePath)
    $pscpExe = Find-Pscp
    if (-not $pscpExe) { Write-Err "pscp.exe не найден"; return $false }
    $rootPwd = Ensure-Password
    if (-not $rootPwd) { return $false }

    if (-not (Test-Path $LocalPath)) { Write-Err "Локальный файл не найден: $LocalPath"; return $false }

    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & $pscpExe -scp -batch -pw $rootPwd $LocalPath "$ROUTER_USER@${ROUTER_IP}:$RemotePath" 2>&1
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Err "pscp upload не удалось ($LocalPath -> $RemotePath)"
        Write-Host ($out -join "`n") -ForegroundColor DarkGray
        return $false
    }
    return $true
}

function Download-File {
    param([string]$RemotePath, [string]$LocalPath)
    $pscpExe = Find-Pscp
    if (-not $pscpExe) { Write-Err "pscp.exe не найден"; return $false }
    $rootPwd = Ensure-Password
    if (-not $rootPwd) { return $false }

    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & $pscpExe -scp -batch -pw $rootPwd "$ROUTER_USER@${ROUTER_IP}:$RemotePath" $LocalPath 2>&1
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Err "pscp download не удалось ($RemotePath -> $LocalPath)"
        Write-Host ($out -join "`n") -ForegroundColor DarkGray
        return $false
    }
    return $true
}

function Ensure-HostKey {
    $plinkExe = Find-Plink
    if (-not $plinkExe) { return $false }
    $rootPwd = Ensure-Password
    if (-not $rootPwd) { return $false }

    # Без -batch, но с пайпом 'y\n' для автоматического согласия
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = "y`n" | & $plinkExe -ssh -pw $rootPwd "$ROUTER_USER@$ROUTER_IP" "echo hostkey_ok" 2>&1
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    if ("$out" -match "hostkey_ok") { return $true }
    Write-Warn "Не удалось установить SSH-соединение для регистрации ключа:"
    Write-Host ($out -join "`n") -ForegroundColor DarkGray
    return $false
}

function Show-RouterResources {
    param([string]$Label = "Ресурсы роутера сейчас")
    # SSH-команду держим в ЧИСТОМ ASCII: кириллица в аргументах plink на
    # ру-Windows бьётся (см. Action-NotifyTest в be7000.ps1). Поэтому роутер
    # отдаёт «сырые» токены (RAM/DISK/LOGS ...), а по-русски форматируем здесь.
    #   * RAM из /proc/meminfo — формат стабилен на любом busybox (в отличие от
    #     `free`); MemAvailable на старом ядре может отсутствовать → отдаём -1.
    #   * df устойчив к переносу длинного имени устройства: числа всегда в
    #     последней строке, поля адресуем от конца (Avail=$(NF-2), Size=$(NF-4)).
    #   * Берём только /data (ubifs, persist — туда ставится awg) и /tmp (RAM):
    #     на BE7000 НЕТ /overlay, df по нему свалился бы на ro-squashfs `/`, а тот
    #     всегда 100% по природе squashfs — мнимое «забито», пугает зря.
    #   * Логи все в /tmp (tmpfs=RAM) — их суммарный размер это тоже занятая RAM.
    # ВАЖНО: awk-программы полны кавычек, а PS5 при передаче аргумента в нативный
    # plink кавычки курочит → awk на роутере падает с «Unexpected token» (проверено
    # на железе). Поэтому скрипт кодируем в base64 (чистый ASCII, без кавычек) и
    # декодируем на роутере (`echo <b64> | base64 -d | sh`) — тот же приём, что в
    # Action-NotifySetup для notify.conf.
    $resScript = @'
awk '/^MemTotal:/{t=$2}/^MemFree:/{f=$2}/^MemAvailable:/{a=$2}END{printf "RAM %d %d %d\n",f/1024,t/1024,(a==""?-1:a/1024)}' /proc/meminfo 2>/dev/null
for m in /data /tmp; do df -h "$m" 2>/dev/null | tail -1 | awk -v mp="$m" 'NF>=5{printf "DISK %s %s %s %s\n",mp,$(NF-2),$(NF-4),$(NF-1)}'; done
ls -l /tmp/*.log 2>/dev/null | awk '{s+=$5}END{printf "LOGS %d %d\n",(s+1023)/1024,NR}'
'@
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($resScript -replace "`r`n", "`n")))
    $r = Invoke-Router -Command "echo $b64 | base64 -d | sh" -Silent
    Write-Host ""
    Write-Host "--- $Label ---" -ForegroundColor Cyan
    if (-not $r -or -not $r) { Write-Info "(не удалось получить данные о памяти роутера)"; return }
    foreach ($ln in @($r)) {
        $t = ("$ln" -replace "`r", "").Trim()
        if (-not $t) { continue }
        $p = $t -split "\s+"
        switch ($p[0]) {
            "RAM" {
                if ($p.Count -lt 4) { break }
                $msg = "RAM:       {0} МБ свободно из {1} МБ" -f $p[1], $p[2]
                $availMb = [int]$p[1]
                if ([int]$p[3] -ge 0) { $msg += " (доступно $($p[3]) МБ)"; $availMb = [int]$p[3] }
                if    ($availMb -lt 30) { Write-Host $msg -ForegroundColor Red }
                elseif ($availMb -lt 60) { Write-Host $msg -ForegroundColor Yellow }
                else                     { Write-Host $msg -ForegroundColor Green }
            }
            "DISK" {
                if ($p.Count -lt 5) { break }
                Write-Host ("Диск {0,-8} {1} своб из {2} (занято {3})" -f $p[1], $p[2], $p[3], $p[4]) -ForegroundColor Gray
            }
            "LOGS" {
                if ($p.Count -lt 3) { break }
                Write-Host ("Логи /tmp: {0} КБ в {1} файл(ах)" -f $p[1], $p[2]) -ForegroundColor Gray
            }
        }
    }
}

function PreFlight {
    param([string]$Proto = "awg")   # awg | xray | both — awg.conf нужен только при awg/both
    Write-Section "Pre-flight проверки"
    $problems = @()

    # 1. plink + pscp
    $plinkExe = Find-Plink
    $pscpExe  = Find-Pscp
    if ($plinkExe) { Write-Ok "plink.exe: $plinkExe" } else { Write-Err "plink.exe не найден"; $problems += "plink" }
    if ($pscpExe)  { Write-Ok "pscp.exe:  $pscpExe"  } else { Write-Err "pscp.exe не найден";  $problems += "pscp" }
    if ($problems) {
        Write-Warn "Установи PuTTY MSI: https://www.putty.org/ (plink и pscp идут в комплекте)"
        return $false
    }

    # 2. Локальные файлы
    Write-Info "Папка скрипта: $SCRIPT_DIR"
    $missing = @()
    # При xray-only awg.conf не нужен — исключаем его из обязательных.
    $reqFiles = if ($Proto -eq 'xray' -or $Proto -eq 'hy2') { $REQUIRED_FILES | Where-Object { $_ -ne 'awg.conf' } } else { $REQUIRED_FILES }
    foreach ($f in $reqFiles) {
        $p = Join-Path $SCRIPT_DIR $f
        if (Test-Path $p) {
            $size = (Get-Item $p).Length
            Write-Ok "$f ($size байт)"
        } else {
            Write-Err "$f -- НЕ НАЙДЕН"
            $missing += $f
        }
    }
    # Опциональные файлы (показываем ДО ранних return'ов чтобы юзер видел картину)
    foreach ($f in $OPTIONAL_FILES) {
        $p = Join-Path $SCRIPT_DIR $f
        if (Test-Path $p) { Write-Ok "$f (опционально, есть)" }
        else { Write-Info "$f (опционально, нет -- пропустим)" }
    }
    # Бинарники AWG 2.0 -- проверяем ARM64 ELF
    $binFound = @()
    $binBad = $false
    foreach ($k in $BIN_FILES.Keys) {
        $p = Join-Path $SCRIPT_DIR $BIN_FILES[$k]
        if (-not (Test-Path $p)) {
            Write-Info "$k (AWG 2.0 бинарник, нет -- нужен только если конфиг AWG 2.0 без Legacy)"
            continue
        }
        $bytes = [System.IO.File]::ReadAllBytes($p) | Select-Object -First 20
        $isElf   = ($bytes.Count -ge 4 -and $bytes[0] -eq 0x7F -and $bytes[1] -eq 0x45 -and $bytes[2] -eq 0x4C -and $bytes[3] -eq 0x46)
        $is64    = ($bytes.Count -ge 5 -and $bytes[4] -eq 2)
        $isLE    = ($bytes.Count -ge 6 -and $bytes[5] -eq 1)
        # e_machine на offset 18 (little-endian, 2 байта): 0xB7 = AArch64
        $isArm64 = ($bytes.Count -ge 20 -and $bytes[18] -eq 0xB7 -and $bytes[19] -eq 0x00)
        if (-not $isElf)                       { Write-Err "$k -- не ELF-файл (не Linux-бинарник!)"; $binBad = $true; continue }
        if (-not ($is64 -and $isLE -and $isArm64)) { Write-Err "$k -- не aarch64 ELF (нужен ARM64; про бинарники — README, раздел «Про AmneziaWG 2.0 и бинарники»)"; $binBad = $true; continue }
        $sizeKb = [math]::Round((Get-Item $p).Length / 1024, 1)
        $binFound += $k
        Write-Ok "$k (ARM64 ELF, $sizeKb KB)"
    }
    if ($binFound.Count -eq 0 -and -not $binBad) {
        Write-Info "Бинарников AWG 2.0 нет -- awg_setup.sh скачает свои (для AWG 1.x этого хватит)"
    }
    # Теперь обрабатываем фатальные ошибки
    if ($missing.Count -gt 0) {
        Write-Err "Не хватает обязательных файлов: $($missing -join ', ')"
        return $false
    }
    if ($binBad) {
        Write-Err "Бинарник(и) AWG битые -- исправь и перезапусти"
        return $false
    }

    # 3. Валидация конфига транспорта.
    if ($Proto -eq 'xray') {
        # xray-only: awg.conf не нужен. Нужны бинарники xray + hev (tun2socks).
        if ($binFound -notcontains 'xray.user') { Write-Err "Для Xray нужен bin/xray.user (ARM64 ELF) -- не найден или битый"; return $false }
        if ($binFound -notcontains 'hev.user')  { Write-Err "Для Xray нужен bin/hev.user (tun2socks, ARM64 ELF) -- не найден или битый"; return $false }
        Write-Ok "Xray-бинарники на месте (xray.user + hev.user). awg.conf для xray-only не требуется."
        Write-Info "xray-конфиг (vless://) спросим в процессе установки."
    } elseif ($Proto -eq 'hy2') {
        # hy2-only: awg.conf не нужен. Нужны бинарники hysteria + hev (tun2socks).
        if ($binFound -notcontains 'hysteria.user') { Write-Err "Для Hysteria2 нужен bin/hysteria.user (ARM64 ELF) -- не найден или битый"; return $false }
        if ($binFound -notcontains 'hev.user')      { Write-Err "Для Hysteria2 нужен bin/hev.user (tun2socks, ARM64 ELF) -- не найден или битый"; return $false }
        Write-Ok "Hysteria2-бинарники на месте (hysteria.user + hev.user). awg.conf для hy2-only не требуется."
        Write-Info "hy2-конфиг (hy2://) спросим в процессе установки."
    } else {
        $confPath = Join-Path $SCRIPT_DIR "awg.conf"
        $conf = Get-Content $confPath -Raw
        if ($conf -notmatch '\[Interface\]') { Write-Err "В awg.conf нет [Interface]"; return $false }
        if ($conf -notmatch '\[Peer\]')      { Write-Err "В awg.conf нет [Peer]";      return $false }
        if ($conf -notmatch 'PrivateKey\s*=') { Write-Err "В awg.conf нет PrivateKey"; return $false }
        if ($conf -notmatch 'PublicKey\s*=')  { Write-Err "В awg.conf нет PublicKey";  return $false }
        if ($conf -notmatch 'Endpoint\s*=')   { Write-Err "В awg.conf нет Endpoint";   return $false }
        Write-Ok "awg.conf валиден (есть [Interface], [Peer], PrivateKey, PublicKey, Endpoint)"

        # Определим версию AWG
        $awgVer = "1.0 (Legacy)"
        if ($conf -match '(?m)^\s*S3\s*=' -or $conf -match '(?m)^\s*S4\s*=' -or $conf -match '(?m)^\s*H[1-4]\s*=\s*\d+-\d+') {
            $awgVer = "2.0"
        } elseif ($conf -match '(?m)^\s*I1\s*=\s*\S+') {
            $awgVer = "1.5"
        }
        Write-Info "Версия AWG в конфиге: $awgVer"
        if ($awgVer -eq "2.0" -and $binFound.Count -eq 0) {
            Write-Warn "У тебя AWG 2.0, но нет своих бинарников. awg_setup.sh ставит старые сборки -- они могут упасть с 'Line unrecognized: S3=...'"
            Write-Warn "Либо используй готовые бинарники из репозитория (awg.user/amneziawg-go.user), либо Legacy-конфиг на VPS."
        }
    }

    # 4. Доступность роутера
    Write-Info "Пинг $ROUTER_IP..."
    if (-not (Test-Connection -ComputerName $ROUTER_IP -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
        Write-Err "$ROUTER_IP не отвечает на пинг. Проверь подключение."
        return $false
    }
    Write-Ok "Роутер отвечает на пинг"

    # 5. SSH работает
    Write-Info "Проверяю SSH..."
    if (-not (Ensure-HostKey)) {
        Write-Err "SSH недоступен. Проверь: 1) пароль 2) что xmir-patcher включил SSH (Install permanent SSH)"
        return $false
    }
    Write-Ok "SSH работает"

    # 6. Записываемая директория
    $r = Invoke-Router -Command "mkdir -p $AWG_DIR && touch $AWG_DIR/.write_test && rm $AWG_DIR/.write_test && echo OK" -Silent
    if (-not $r -or -not ("$r" -match "OK")) {
        Write-Err "$AWG_DIR не записывается. Возможно SSH под не-root."
        if ($r) { Write-Host ($r -join "`n") -ForegroundColor DarkGray }
        return $false
    }
    Write-Ok "$AWG_DIR доступен для записи"

    # Память роутера (базовый уровень до установки — потом сравним с Verify-Install)
    Show-RouterResources "Ресурсы роутера (до установки)"

    Write-Ok "Pre-flight OK"
    return $true
}

function New-Backup {
    Write-Section "Создаю backup состояния роутера"
    if (-not (Test-Path $BACKUP_DIR)) { New-Item -ItemType Directory -Path $BACKUP_DIR -Force | Out-Null }
    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    $tarName = "awg-backup-$ts.tar.gz"
    $remoteTar = "/tmp/$tarName"
    $localTar  = Join-Path $BACKUP_DIR $tarName

    # На роутере: тарим всё, что можем сломать установкой
    $tarCmd = @"
TS=$ts
TAR=$remoteTar
TMPDIR=/tmp/awg-bk-`$TS
mkdir -p `$TMPDIR
# Снимки состояния
ip rule show > `$TMPDIR/ip-rule.txt 2>/dev/null
iptables-save > `$TMPDIR/iptables.save 2>/dev/null
ipset save > `$TMPDIR/ipset.save 2>/dev/null
crontab -l > `$TMPDIR/crontab.txt 2>/dev/null
# Файлы (то, что есть)
[ -d /data/usr/app/awg ] && cp -a /data/usr/app/awg `$TMPDIR/awg_dir 2>/dev/null
[ -f /etc/rc.local ] && cp -a /etc/rc.local `$TMPDIR/rc.local 2>/dev/null
[ -d /etc/dnsmasq.d ] && cp -a /etc/dnsmasq.d `$TMPDIR/dnsmasq.d 2>/dev/null
[ -f /etc/dnsmasq.conf ] && cp -a /etc/dnsmasq.conf `$TMPDIR/dnsmasq.conf 2>/dev/null
[ -f /etc/crontabs/root ] && cp -a /etc/crontabs/root `$TMPDIR/crontabs_root 2>/dev/null
cd /tmp && tar czf `$TAR -C /tmp awg-bk-`$TS 2>/dev/null && rm -rf `$TMPDIR && echo SIZE:`$(wc -c < `$TAR)
"@
    $r = Invoke-Router -Command $tarCmd
    if (-not $r -or $script:RouterExitCode -ne 0) {
        Write-Err "Не удалось создать tar на роутере"
        return $null
    }
    if ("$r" -notmatch "SIZE:(\d+)") {
        Write-Err "Tar создан, но размер не определён:"
        Write-Host ($r -join "`n") -ForegroundColor DarkGray
        return $null
    }
    $size = [int]$matches[1]
    Write-Ok "Tar на роутере: $remoteTar ($size байт)"

    # Скачиваем
    Write-Info "Скачиваю backup..."
    if (-not (Download-File -RemotePath $remoteTar -LocalPath $localTar)) {
        Write-Err "Backup не скачался, оставляю на роутере: $remoteTar"
        return $null
    }
    Write-Ok "Backup сохранён: $localTar"

    # Чистим с роутера
    Run-SSH "rm -f $remoteTar" | Out-Null

    return $localTar
}

function Get-LocalBackups {
    if (-not (Test-Path $BACKUP_DIR)) { return @() }
    Get-ChildItem -Path $BACKUP_DIR -Filter "awg-backup-*.tar.gz" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
}

function Action-Backup {
    if (-not (PreFlight)) { return }
    $b = New-Backup
    if ($b) { Write-Ok "Готово: $b" }
}

# Какой АЛЬТ (xray|hy2|none) оставляем для выбранного протокола установки. Альты
# xray/hy2 взаимоисключающи на флеше; awg — база (в выбор альта не входит, авто-очисткой
# не удаляется). awg-only / неизвестно → 'none' (альта нет, оба alt-бинаря + hev снимаются).
function Get-SelectedAlt([string]$Proto) {
    switch ($Proto) {
        'xray'    { 'xray' }
        'both'    { 'xray' }
        'hy2'     { 'hy2' }
        'bothhy2' { 'hy2' }
        default   { 'none' }
    }
}

# Что РЕАЛЬНО установлено на роутере — по наличию рабочих бинарей в корне $AWG_DIR (а НЕ
# по конфигам/.transport: версие-независимо, не зависит от transport.sh). Возвращает proto-
# строку для Upload-AllFiles (awg/xray/hy2/both/bothhy2) или $null, если не определилось.
# Нужно «Обновить скрипты», чтобы заливать awg.conf лишь когда awg реально стоит (а не
# плодить осиротевший awg.conf на alt-only роутере). $A/$X/$H — переменные РОУТЕРА (backtick).
function Get-InstalledProto {
    $r = "" + (Invoke-Router -Command "A=0; X=0; H=0; [ -x $AWG_DIR/amneziawg-go ] && A=1; [ -x $AWG_DIR/xray ] && X=1; [ -x $AWG_DIR/hysteria ] && H=1; echo INSTPROTO:`$A`$X`$H" -Silent)
    if ($r -notmatch 'INSTPROTO:(\d)(\d)(\d)') { return $null }
    $a = $Matches[1] -eq '1'; $x = $Matches[2] -eq '1'; $h = $Matches[3] -eq '1'
    if ($a -and $x) { return 'both' }
    if ($a -and $h) { return 'bothhy2' }
    if ($a) { return 'awg' }
    if ($x) { return 'xray' }
    if ($h) { return 'hy2' }
    return $null
}

function Upload-AllFiles {
    param([string]$Proto = "awg", [bool]$PurgeOtherAlt = $false, [bool]$SkipBins = $false)
    Write-Section "Заливаю файлы на роутер ($AWG_DIR)"

    # Подготовим директории
    $r = Invoke-Router -Command "mkdir -p $AWG_DIR $AWG_DIR/bin $AWG_DIR/configs && echo OK" -Silent
    if (-not $r -or "$r" -notmatch "OK") {
        Write-Err "Не смог создать $AWG_DIR на роутере"
        return $false
    }

    # Главные файлы. При xray-only НЕ заливаем awg.conf — иначе установщик увидит
    # HAVE_AWG=1 и поднимет ещё и AmneziaWG (получился бы «оба», а не чистый Xray).
    $allFiles = @($REQUIRED_FILES) + @($OPTIONAL_FILES | Where-Object { Test-Path (Join-Path $SCRIPT_DIR $_) })
    if ($Proto -eq 'xray' -or $Proto -eq 'hy2') { $allFiles = $allFiles | Where-Object { $_ -ne 'awg.conf' } }
    foreach ($f in $allFiles) {
        $local = Join-Path $SCRIPT_DIR $f
        if (-not (Test-Path $local)) { continue }
        Write-Info "  -> $f"
        if (-not (Upload-File -LocalPath $local -RemotePath "$AWG_DIR/$f")) {
            Write-Err "Загрузка $f сорвалась"
            return $false
        }
    }

    # СВОП АЛЬТА: перед заливкой тяжёлых alt-бинарей снимаем бинарь СТАРОГО (невыбранного)
    # альта на роутере — иначе на awg+xray -> awg+hy2 пик (старый+новый альт) переполнит
    # /data ~20 МБ. Делает router-side awg-setup (он залит ВЫШЕ в этом же вызове = новая
    # версия с субкомандой purge-alt) → PS-guard на литерал rm не мешает (rm живёт в .sh на
    # роутере). Гейт $PurgeOtherAlt: ТОЛЬКО при реальной установке (Action-Install); «Обновить
    # скрипты» (Action-UpdateScripts) зовёт Upload-AllFiles без флага → альты не трогаются.
    if ($PurgeOtherAlt) {
        $selAlt = Get-SelectedAlt $Proto
        Write-Info "  очистка невыбранного альта (оставляем: $selAlt)"
        Invoke-Router -Command "INSTALL_ALT=$selAlt sh $AWG_DIR/awg-setup-be7000.sh purge-alt 2>&1" -Silent | Out-Null
    }

    # Бинарники в bin/ — ТОЛЬКО нужные выбранному протоколу. Флеш /data тесный (~20 МБ):
    # держать на нём ОБА альта (xray 7.6 + hy2 4.6) нельзя, а awg-база (5 МБ) при alt-only
    # бесполезна. awg/both/bothhy2 → awg-база; xray/both → +xray+hev; hy2/bothhy2 → +hysteria+hev.
    # $SkipBins: «Обновить скрипты» (Action-UpdateScripts) контрактно шлёт только .sh+awg.conf —
    # бинари НЕ трогаем, иначе alt-only юзеру лились бы лишние awg-бинари (~5 МБ) в bin/.
    if (-not $SkipBins) {
        $needBins = @()
        if ($Proto -eq 'awg' -or $Proto -eq 'both' -or $Proto -eq 'bothhy2') { $needBins += @('amneziawg-go.user', 'awg.user') }
        if ($Proto -eq 'xray' -or $Proto -eq 'both')    { $needBins += @('xray.user', 'hev.user') }
        if ($Proto -eq 'hy2'  -or $Proto -eq 'bothhy2') { $needBins += @('hysteria.user', 'hev.user') }
        # Перед заливкой ТЯЖЁЛОГО bin/-стейджинга снимаем СТАРЫЕ рабочие копии тех же бинарей
        # в корне $AWG_DIR. ЗАЧЕМ: на реинсталле поверх установленного (напр. awg -> awg+xray)
        # старый рутовый amneziawg-go (4.85) + новый bin/-стейджинг (amneziawg-go.user 4.85 +
        # xray.user 7.75 = 13.25) не влезают в пик на 20-МБ /data ещё ДО запуска установщика →
        # заливка/cp падали «No space». Демоны живут в ПАМЯТИ — снос файла-бинаря их НЕ роняет
        # (awg0/несущая работают), а установщик переставит бинарь из bin/ (mv). Снимаем только
        # то, что СЕЙЧАС переустанавливаем (по needBins).
        $rmRoot = @($needBins | ForEach-Object { $_ -replace '\.user$', '' })
        if ($rmRoot.Count) {
            Write-Info "  освобождаю место: снимаю старые рутовые бинари ($($rmRoot -join ', '))"
            Invoke-Router -Command "cd $AWG_DIR && rm -f $($rmRoot -join ' ')" -Silent | Out-Null
        }
        foreach ($k in $needBins) {
            if (-not $BIN_FILES.ContainsKey($k)) { continue }
            $local = Join-Path $SCRIPT_DIR $BIN_FILES[$k]
            if (-not (Test-Path $local)) { continue }
            Write-Info "  -> bin/$k"
            if (-not (Upload-File -LocalPath $local -RemotePath "$AWG_DIR/bin/$k")) {
                Write-Err "Загрузка bin/$k сорвалась"
                return $false
            }
        }
    }

    # Папка configs/ если есть (с дополнительными странами)
    $cfgDir = Join-Path $SCRIPT_DIR "configs"
    if (Test-Path $cfgDir) {
        $cfgs = Get-ChildItem -Path $cfgDir -Filter "*.conf" -ErrorAction SilentlyContinue
        foreach ($c in $cfgs) {
            Write-Info "  -> configs/$($c.Name)"
            if (-not (Upload-File -LocalPath $c.FullName -RemotePath "$AWG_DIR/configs/$($c.Name)")) {
                Write-Warn "configs/$($c.Name) не залился, пропускаю"
            }
        }
    }

    # chmod
    $r = Invoke-Router -Command "cd $AWG_DIR && chmod +x *.sh bin/*.user 2>/dev/null; echo CHMOD_OK" -Silent
    if (-not ($r -and "$r" -match "CHMOD_OK")) {
        Write-Warn "chmod вернул что-то странное:"
        if ($r) { Write-Host ($r -join "`n") -ForegroundColor DarkGray }
    }
    Write-Ok "Файлы залиты и chmod +x проставлен"
    return $true
}

function Run-Installer {
    param([bool]$EnableRefilter = $false, [string]$Proto = "")
    Write-Section "Запускаю awg-setup-be7000.sh на роутере"
    $envPrefix = ""
    if ($EnableRefilter) { $envPrefix += "ENABLE_REFILTER=1 " }
    # INSTALL_PROTO задаёт АКТИВНЫЙ транспорт. Для xray-only -- xray; для awg/both
    # установщик определит сам (есть awg.conf => awg по умолчанию).
    if ($Proto -eq 'xray') { $envPrefix += "INSTALL_PROTO=xray " }
    elseif ($Proto -eq 'hy2') { $envPrefix += "INSTALL_PROTO=hy2 " }
    # Без -Silent -- пользователь должен видеть прогресс
    $r = Invoke-Router -Command "cd $AWG_DIR && ${envPrefix}sh ./awg-setup-be7000.sh 2>&1"
    if ($r) {
        Write-Host ($r -join "`n")
        if ($script:RouterExitCode -ne 0) {
            Write-Err "Инсталлер вернул код $($script:RouterExitCode)"
            return $false
        }
    }
    # Проверим что не было фатальных парсер-ошибок
    if ("$r" -match "Line unrecognized:|Configuration parsing error") {
        Write-Err "Парсер AWG не понимает конфиг. Скорее всего AWG 2.0 без своих бинарников."
        Write-Warn "Положи бинарники AWG 2.0 из репозитория (awg.user/amneziawg-go.user) и повтори."
        return $false
    }
    return $true
}

function Verify-Install {
    param([string]$Proto = "awg")
    # Итог «несущая поднялась?» отдаём через script-scoped переменную (а не return —
    # функция много пишет в host, а Show-RouterResources мог бы подмешать объект в
    # пайплайн и испортить булев return). Action-Install читает $script:LastVerifyCarrierUp.
    $script:LastVerifyCarrierUp = $false
    Write-Section "Проверка после установки"
    if ($Proto -eq 'xray' -or $Proto -eq 'hy2') {
        # alt-only: awg0 нет — проверяем egress через socks альт-транспорта (тот же порт 10808).
        $altLbl = if ($Proto -eq 'hy2') { 'Hysteria2' } else { 'Xray' }
        $tp = ("" + (Invoke-Router -Command "cat $AWG_DIR/.transport 2>/dev/null" -Silent)).Trim()
        Write-Info "Активный транспорт: $tp"
        # Несущая альта поднимается не мгновенно: socks открывается ТОЛЬКО после QUIC/Reality-
        # хендшейка (для hy2 на DPI-сети ~15-17с). Пробуем egress с ретраями (~30с), чтобы не
        # объявить провал раньше времени.
        Write-Info "Проверяю egress через VPN (до ~30 сек)..."
        $ip = ""
        for ($i = 0; $i -lt 6; $i++) {
            $ip = ("" + (Invoke-Router -Command "curl -s --max-time 8 --socks5-hostname 127.0.0.1:10808 https://api.ipify.org 2>/dev/null" -Silent)).Trim()
            if ($ip -match '^\d+\.\d+\.\d+\.\d+$') { break }
            Start-Sleep -Seconds 5
        }
        if ($ip -match '^\d+\.\d+\.\d+\.\d+$') {
            $script:LastVerifyCarrierUp = $true
            Write-Ok "$altLbl поднят -- выходной IP через VPN: $ip"
        } else {
            # Громко: несущая НЕ встала. Это fail-open (интернет работает напрямую), но VPN
            # сейчас НЕ несёт трафик. Самая частая причина для конфига «по имени сервера» —
            # временная DNS-осечка резолва адреса VPS на старте; помогает повтор.
            Write-Host ""
            Write-Host "  ------------------------------------------------------------" -ForegroundColor Yellow
            Write-Warn  "$altLbl НЕСУЩАЯ НЕ ПОДНЯЛАСЬ -- VPN сейчас НЕ работает."
            Write-Host  "  Интернет идёт НАПРЯМУЮ (fail-open): роутер не завис, но трафик мимо VPN." -ForegroundColor Yellow
            Write-Host  "  Причины: VPS/конфиг (сервер/порт/sni/пароль/ключи) ЛИБО временный сбой DNS-" -ForegroundColor Yellow
            Write-Host  "  резолва адреса сервера (если конфиг по ИМЕНИ хоста, а не по IP)." -ForegroundColor Yellow
            Write-Host  "  Что сделать: меню -> Протокол -> выбрать этот конфиг ещё раз (нередко встаёт со 2-го раза)." -ForegroundColor Yellow
            Write-Host  "  Не помогло -> Установка и обслуживание -> Диагностика (или Выгрузка дампа)." -ForegroundColor Yellow
            Write-Host "  ------------------------------------------------------------" -ForegroundColor Yellow
        }
        $ipl = ("" + (Invoke-Router -Command "ipset list iplist_set 2>/dev/null | awk '/Number of entries/{print `$NF}'" -Silent)).Trim()
        if ($ipl -match '^[0-9]+$' -and [int]$ipl -gt 0) { Write-Ok "iplist_set: $ipl подсетей" }
        else { Write-Warn "iplist пока пуст -- обновится по cron 5:00 или вручную (Источник списка IP -> Обновить)" }
        $cr = Invoke-Router -Command "grep -qF awg-heal.sh /etc/crontabs/root && echo OK || echo NONE" -Silent
        if ("$cr" -match "OK") { Write-Ok "awg-heal.sh в cron (boot-восстановление)" } else { Write-Warn "awg-heal.sh не в cron" }
        Show-RouterResources "Ресурсы роутера (после установки)"
        return
    }
    $r = Invoke-Router -Command "$AWG_DIR/awg show awg0 2>/dev/null | head -20"
    if ($r) { Write-Host ($r -join "`n") }
    # Активная проверка handshake с ретраем (возраст последнего HS, как у watchdog:
    # >0 и <180с = живой). Здоровый VPS отвечает за секунды; даём ~30с на раскачку.
    Write-Info "Проверяю handshake с VPS (до ~30 сек)..."
    $probe = "ok=0; i=0; while [ `$i -lt 6 ]; do " +
             "hs=`$($AWG_DIR/awg show awg0 latest-handshakes 2>/dev/null | awk 'NR==1{print `$2}'); " +
             "case `"`$hs`" in ''|*[!0-9]*) hs=0;; esac; " +
             "if [ `"`$hs`" -gt 0 ]; then age=`$(( `$(date +%s) - hs )); if [ `"`$age`" -lt 180 ]; then ok=1; break; fi; fi; " +
             "i=`$((i+1)); sleep 5; done; echo HSPROBE=`$ok"
    $pr = Invoke-Router -Command $probe -Silent
    if ("$pr" -match "HSPROBE=1") {
        $script:LastVerifyCarrierUp = $true
        Write-Ok "Handshake живой -- туннель работает"
    } else {
        # Мёртвый конфиг = DNS-SPOF: dnsmasq форвардит в дохлый awg0, не резолвится
        # ничего (даже рунет), и почта не уйдёт. Не оставляем юзера в этом — сразу
        # failover: он safety_off (интернет/DNS мгновенно напрямую) -> перебор
        # резервов -> встаёт на первый рабочий; все мертвы -> остаётся прямой режим.
        # Письмо шлёт сам switch-vpn (best-effort: при свежей установке почта ещё
        # не настроена -> notify-event тихо промолчит, и это нормально).
        Write-Warn "Handshake не пришёл за ~30с -- основной конфиг похоже мёртвый (VPS не отвечает)."
        Write-Info "Чтобы не оставить роутер со сломанным DNS, запускаю failover (резерв -> иначе прямой режим)..."
        $fo = Invoke-Router -Command "sh $AWG_DIR/switch-vpn.sh failover 2>&1"
        if ($fo) { Write-Host ($fo -join "`n") -ForegroundColor DarkGray }
        $hs2 = ("" + (Invoke-Router -Command "$AWG_DIR/awg show awg0 latest-handshakes 2>/dev/null | awk 'NR==1{print `$2}'" -Silent)).Trim()
        $act = ("" + (Invoke-Router -Command "cat $AWG_DIR/.active 2>/dev/null" -Silent)).Trim()
        if ($hs2 -match '^[1-9][0-9]*$') {
            $script:LastVerifyCarrierUp = $true
            Write-Ok "Переключился на рабочий резерв: $act -- VPN работает."
        } else {
            Write-Warn "Ни один конфиг не поднялся -> ПРЯМОЙ режим (safety_off): интернет и DNS идут мимо VPN, сайты из списка пока недоступны через VPN."
            Write-Info "Проверь свой VPS/конфиг (endpoint, ключи). Оживёт -- watchdog вернёт VPN сам (sticky); или be7000.bat -> 9 (сменить страну)."
        }
        # DNS теперь рабочий (резерв или публичный после safety_off) -> докачиваю
        # iplist: через мёртвый туннель при установке он не скачивался.
        Write-Info "Догружаю CIDR-список (iplist)..."
        $ipl = ("" + (Invoke-Router -Command "sh $AWG_DIR/iplist-update.sh >/dev/null 2>&1; ipset list iplist_set 2>/dev/null | awk '/Number of entries/{print `$NF}'" -Silent)).Trim()
        if ($ipl -match '^[0-9]+$' -and [int]$ipl -gt 0) { Write-Ok "iplist_set: $ipl подсетей" }
        else { Write-Warn "iplist пока пуст (источник недоступен?) -- обновится по cron 5:00 или вручную: Источник списка IP -> Обновить" }
    }
    # FORWARD
    $r = Invoke-Router -Command "iptables -L FORWARD -v -n 2>/dev/null | head -5"
    if ($r) { Write-Info "iptables FORWARD (первые правила):"; Write-Host ($r -join "`n") -ForegroundColor DarkGray }
    # cron
    $r = Invoke-Router -Command "grep -E 'awg-heal|iplist-update' /etc/crontabs/root 2>/dev/null"
    if ($r -and "$r" -match "awg-heal") {
        Write-Ok "awg-heal.sh прописан в cron"
    } else {
        Write-Warn "awg-heal.sh не в cron -- после ребута может не подняться"
    }
    # watchdog cron (добавлено июнь 2026). grep -qF + echo: всегда exit 0, чтобы
    # busybox не выдал ложный [FAIL] код 1 при отсутствии строки.
    $r = Invoke-Router -Command "grep -qF awg-watchdog.sh /etc/crontabs/root && echo WD_CRON_OK || echo WD_CRON_NONE" -Silent
    if ("$r" -match "WD_CRON_OK") {
        Write-Ok "awg-watchdog.sh прописан в cron (*/2 мин): при падении VPS авто-failover на резерв"
        Write-Info "Режим failover по умолчанию sticky (перебрать резервы и остаться); off/sticky/home -- be7000.bat -> 21"
    } else {
        Write-Warn "awg-watchdog.sh не в cron -- падение VPS не переведёт трафик в прямой режим сам"
    }

    # Память роутера после установки — сравни с «до установки» из pre-flight,
    # чтобы видеть, сколько съел VPN (бинарники в /data, рантайм в RAM).
    Show-RouterResources "Ресурсы роутера (после установки)"
}

# Выбор протокола на первой установке. Возвращает awg | xray | both | $null (отмена).
# Гарантирует awg.conf в папке скрипта (его читают PreFlight и Upload-AllFiles). Если файла
# нет — предлагает указать путь к awg.conf от VPS и КОПИРУЕТ его в $SCRIPT_DIR\awg.conf
# (нормализуя CRLF->LF, секрет-конфиг пишем без BOM). Так юзеру НЕ надо вручную «кидать файл
# в корень» — достаточно перетащить его в окно при выборе варианта с AmneziaWG. Возвращает
# $true, если awg.conf на месте (был или только что скопирован).
function Ensure-AwgConfLocal {
    $dst = Join-Path $SCRIPT_DIR "awg.conf"
    if (Test-Path $dst) { return $true }
    Write-Warn "awg.conf в папке скрипта ($SCRIPT_DIR) не найден."
    Write-Host "Укажи путь к awg.conf от твоего VPS — скопирую его сюда (можно перетащить файл в окно)." -ForegroundColor DarkGray
    $raw = Read-Host "Путь к awg.conf (Enter = отмена)"
    if (-not $raw) { return $false }
    $src = $raw.Trim().Trim('"')
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { Write-Err "Файл не найден: $src"; return $false }
    $src = (Resolve-Path -LiteralPath $src).Path
    try   { $text = [System.IO.File]::ReadAllText($src) }
    catch { Write-Err "Не смог прочитать файл: $($_.Exception.Message)"; return $false }
    if ($text -notmatch '\[Interface\]' -or $text -notmatch '\[Peer\]') {
        if (-not (_Confirm "Файл не похож на awg-конфиг ([Interface]/[Peer] не найдены). Всё равно использовать?")) { return $false }
    }
    $text = $text -replace "`r`n", "`n" -replace "`r", "`n"
    try   { [System.IO.File]::WriteAllText($dst, $text, (New-Object System.Text.UTF8Encoding($false))) }
    catch { Write-Err "Не смог записать $dst : $($_.Exception.Message)"; return $false }
    Write-Ok "awg.conf скопирован в папку скрипта: $dst"
    return $true
}

function Choose-InstallProtocol {
    $haveAwgConf = Test-Path (Join-Path $SCRIPT_DIR "awg.conf")
    $haveXrayBin = Test-Path (Join-Path $SCRIPT_DIR $BIN_FILES['xray.user'])
    $haveHy2Bin  = Test-Path (Join-Path $SCRIPT_DIR $BIN_FILES['hysteria.user'])
    Write-Section "Какой VPN-протокол ставим?"
    if (-not $haveAwgConf) { Write-Info "awg.conf в папке скрипта НЕ найден -- при выборе AmneziaWG спрошу путь к нему (или заранее положи awg.conf от VPS рядом со скриптом)." }
    if (-not $haveXrayBin) { Write-Info "bin/xray.user не найден -- вариант Xray недоступен." }
    if (-not $haveHy2Bin)  { Write-Info "bin/hysteria.user не найден -- вариант Hysteria2 недоступен." }
    Write-Host ""
    Write-Host "  На флеше /data (~20 МБ) живёт ОДИН альт: Xray ЛИБО Hysteria2 (не оба)." -ForegroundColor DarkGray
    Write-Host "  1) AmneziaWG (нужен awg.conf)"
    Write-Host "  2) Xray -- VLESS/Reality (vless:// спрошу дальше)"
    Write-Host "  3) Hysteria2 -- QUIC (hy2:// спрошу дальше)"
    Write-Host "  4) AmneziaWG + Xray (awg активный, xray переключателем/резервом)"
    Write-Host "  5) AmneziaWG + Hysteria2 (awg активный, hy2 переключателем/резервом)"
    Write-Host "  0) Отмена"
    $sel = Read-Host "Выбор"
    switch ($sel) {
        "1" { if (-not $haveAwgConf -and -not (Ensure-AwgConfLocal)) { Write-Err "Без awg.conf вариант AmneziaWG недоступен"; return $null }; return "awg" }
        "2" { if (-not $haveXrayBin) { Write-Err "Нет bin/xray.user в папке скрипта"; return $null }; return "xray" }
        "3" { if (-not $haveHy2Bin)  { Write-Err "Нет bin/hysteria.user в папке скрипта"; return $null }; return "hy2" }
        "4" { if (-not $haveXrayBin) { Write-Err "Нет bin/xray.user в папке скрипта"; return $null }; if (-not $haveAwgConf -and -not (Ensure-AwgConfLocal)) { Write-Err "Без awg.conf вариант 'awg+xray' недоступен"; return $null }; return "both" }
        "5" { if (-not $haveHy2Bin)  { Write-Err "Нет bin/hysteria.user в папке скрипта"; return $null }; if (-not $haveAwgConf -and -not (Ensure-AwgConfLocal)) { Write-Err "Без awg.conf вариант 'awg+hy2' недоступен"; return $null }; return "bothhy2" }
        default { return $null }
    }
}

# Гарантирует наличие активного xray-конфига на роутере ДО запуска установщика
# (тот поднимет xray в конце). Если конфига нет — спрашивает vless:// и провижнит.
function Ensure-XrayConfigForInstall {
    if ((Get-XrayConfigNames).Count -gt 0 -and (Get-ActiveXrayName)) {
        Write-Ok "xray-конфиг уже на роутере: $(Get-ActiveXrayName)"
        return $true
    }
    Write-Section "xray-конфиг (vless://) для установки"
    Write-Host "Вставь ссылку vless://... от своего VPS (VLESS/Reality)." -ForegroundColor DarkGray
    $raw = Read-Host "vless://"
    if (-not $raw) { Write-Warn "Пусто"; return $false }
    $raw = $raw.Trim().Trim('"')
    $p = Parse-VlessLink $raw
    if (-not $p) { Write-Err "Не разобрал vless://"; return $false }
    if ($p.security -eq 'reality' -and -not $p.pbk) { Write-Warn "В ссылке нет pbk (Reality publicKey) -- проверь" }
    $json = New-XrayConfigJson $p
    $name = if ($p.remark) { ($p.remark -replace '[^A-Za-z0-9._-]', '-') } else { "xray" }
    if (-not $name) { $name = "xray" }
    Invoke-Router -Command "mkdir -p $AWG_DIR/xray-configs" -Silent | Out-Null
    if (-not (Send-RouterFileAtomic "$AWG_DIR/xray-configs/$name.json" $json 600)) { Write-Err "Не залил xray-конфиг"; return $false }
    # Кладём активный конфиг + .transport=xray. БЕЗ перезапуска демонов — установщик
    # сам поднимет xray в конце (xray-transport.sh up).
    $r = Invoke-Router -Command "cp $AWG_DIR/xray-configs/$name.json $AWG_DIR/xray.json && chmod 600 $AWG_DIR/xray.json && echo $name > $AWG_DIR/.xray-active && echo xray > $AWG_DIR/.transport && echo OK" -Silent
    if ("$r" -notmatch "OK") { Write-Err "Не активировал xray-конфиг"; return $false }
    Write-Ok "xray-конфиг '$name' залит и выбран активным"
    return $true
}

# Аналог Ensure-XrayConfigForInstall для Hysteria2: гарантирует активный hy2-конфиг на
# роутере ДО установщика (тот поднимет hy2 в конце через transport.sh up hy2).
function Ensure-Hy2ConfigForInstall {
    if ((Get-Hy2ConfigNames).Count -gt 0 -and (Get-ActiveHy2Name)) {
        Write-Ok "hy2-конфиг уже на роутере: $(Get-ActiveHy2Name)"
        return $true
    }
    Write-Section "hy2-конфиг (hy2://) для установки"
    Write-Host "Вставь ссылку hy2://... (или hysteria2://) от своего Hysteria2-сервера." -ForegroundColor DarkGray
    $raw = Read-Host "hy2://"
    if (-not $raw) { Write-Warn "Пусто"; return $false }
    $raw = $raw.Trim().Trim('"')
    $p = Parse-Hy2Link $raw
    if (-not $p) { Write-Err "Не разобрал hy2://"; return $false }
    if (-not $p.obfs) { Write-Warn "В ссылке нет obfs (Salamander) -- без него hy2 уязвим к DPI по QUIC. Для РФ желателен obfs на сервере." }
    $yaml = New-Hy2ConfigYaml $p
    $name = if ($p.remark) { ($p.remark -replace '[^A-Za-z0-9._-]', '-') } else { "hy2" }
    if (-not $name) { $name = "hy2" }
    Invoke-Router -Command "mkdir -p $AWG_DIR/hy2-configs" -Silent | Out-Null
    if (-not (Send-RouterFileAtomic "$AWG_DIR/hy2-configs/$name.yaml" $yaml 600)) { Write-Err "Не залил hy2-конфиг"; return $false }
    # Активный конфиг + .transport=hy2. БЕЗ перезапуска демонов — установщик сам поднимет
    # hy2 в конце (transport.sh up hy2).
    $r = Invoke-Router -Command "cp $AWG_DIR/hy2-configs/$name.yaml $AWG_DIR/hysteria.yaml && chmod 600 $AWG_DIR/hysteria.yaml && echo $name > $AWG_DIR/.hy2-active && echo hy2 > $AWG_DIR/.transport && echo OK" -Silent
    if ("$r" -notmatch "OK") { Write-Err "Не активировал hy2-конфиг"; return $false }
    Write-Ok "hy2-конфиг '$name' залит и выбран активным"
    return $true
}

function Action-Install {
    # Выбор протокола: awg / xray / both. От него зависит, нужен ли awg.conf и xray-конфиг.
    $proto = Choose-InstallProtocol
    if (-not $proto) { Write-Warn "Отмена"; return }

    if (-not (PreFlight -Proto $proto)) {
        Write-Err "Pre-flight не прошёл -- установка отменена"
        return
    }

    Write-Host ""
    Write-Warn "Сейчас будет: backup -> загрузка файлов -> запуск инсталлера (протокол: $proto)"
    $ans = Read-Host "Продолжить? (y/N)"
    if ($ans -ne "y" -and $ans -ne "Y") { Write-Warn "Отмена"; return }

    # Backup ОБЯЗАТЕЛЕН
    $backup = New-Backup
    if (-not $backup) {
        Write-Err "Backup не получился. Установка ОТМЕНЕНА (rollback был бы невозможен)."
        return
    }

    # re-filter по умолчанию ВЫКЛ: iplist (CIDR от opencck) перекрывает его, а
    # лишние 1163+ доменных правил только грузят dnsmasq. Включить разово при
    # желании можно вручную на роутере: ENABLE_REFILTER=1 ./awg-setup-be7000.sh
    $refilter = $false

    # Upload (при xray Upload-AllFiles не зальёт awg.conf; если его и так нет — пропустит)
    if (-not (Upload-AllFiles -Proto $proto -PurgeOtherAlt $true)) {
        Write-Err "Загрузка файлов сорвалась. Можно откатиться: меню -> Откатить из backup -> $backup"
        return
    }

    # xray-конфиг (для xray/both): нужен на роутере ДО установщика — он поднимет xray
    # в конце. Для xray-only обязателен; для both желателен (иначе xray-резерв пустой,
    # добавишь позже через меню).
    if ($proto -eq 'xray' -or $proto -eq 'both') {
        if (-not (Ensure-XrayConfigForInstall)) {
            if ($proto -eq 'xray') {
                Write-Err "Без xray-конфига xray-only не поднять. Установка отменена."
                Write-Info "Откат при необходимости: меню -> Откатить из backup -> $backup"
                return
            } else {
                Write-Warn "xray-конфиг не задан -- ставлю AmneziaWG активным, Xray добавишь позже через меню."
            }
        }
    } elseif ($proto -eq 'hy2' -or $proto -eq 'bothhy2') {
        if (-not (Ensure-Hy2ConfigForInstall)) {
            if ($proto -eq 'hy2') {
                Write-Err "Без hy2-конфига hy2-only не поднять. Установка отменена."
                Write-Info "Откат при необходимости: меню -> Откатить из backup -> $backup"
                return
            } else {
                Write-Warn "hy2-конфиг не задан -- ставлю AmneziaWG активным, Hysteria2 добавишь позже через меню."
            }
        }
    }

    # Источник iplist (можно сузить сразу; по умолчанию весь cidr4 с opencck).
    # Пишем ДО Run-Installer: установщик прямо в процессе зовёт iplist-update.sh,
    # читающий $AWG_DIR/iplist.conf -> первая закачка уже по выбранному источнику.
    Prompt-IplistSourceAtInstall

    # Install
    if (-not (Run-Installer -EnableRefilter $refilter -Proto $proto)) {
        Write-Err "Инсталлер упал. Можно откатиться: меню -> Откатить из backup -> $backup"
        return
    }

    # Verify (результат «несущая поднялась?» кладёт в $script:LastVerifyCarrierUp)
    Verify-Install -Proto $proto
    $carrierUp = $script:LastVerifyCarrierUp
    $script:AwgState = "INSTALLED"   # меню теперь покажет блок управления
    # Установка сменила несущий транспорт/активный конфиг (.transport/.active и т.п.) —
    # обновляем кэш шапки, иначе «Протокол · Конфиг» висит со старым значением (напр.
    # ставил awg поверх hy2: транспорт стал awg, а шапка ещё показывала Hysteria2).
    $script:RouterSummary = Get-RouterSummary
    Write-Host ""
    # Итог установки ЯВНЫЙ: встала несущая или нет (а не всегда бодрое «завершена»).
    # Провал подъёма у нас не фатален (fail-open) -> установщик доходит сюда и при мёртвой
    # несущей; раньше итог это глотал, и было неясно, работает VPN или нет.
    if ($carrierUp) {
        Write-Ok "Установка завершена -- VPN поднят и работает."
    } else {
        Write-Warn "Установка ЗАВЕРШЕНА, но VPN сейчас НЕ поднят (трафик идёт напрямую) -- см. предупреждение выше."
        Write-Info "Подними позже: меню -> Протокол -> выбрать конфиг ещё раз; не помогло -> Установка и обслуживание -> Диагностика."
    }
    Write-Info "Бэкап на случай отката: $backup. Дальнейшее управление -- через be7000.bat"
}

function Action-UpdateScripts {
    if (-not (PreFlight)) { return }
    Write-Host ""
    Write-Warn "Обновлю только .sh скрипты и awg.conf (без переустановки вендорного awg_setup.sh)"
    $ans = Read-Host "Продолжить? (y/N)"
    if ($ans -ne "y" -and $ans -ne "Y") { return }

    $backup = New-Backup
    if (-not $backup) { Write-Err "Backup не получился, отмена"; return }

    # Заливаем .sh + awg.conf, НО бинари не трогаем (-SkipBins) и awg.conf шлём лишь если awg
    # реально установлен: proto берём по фактическим бинарям на роутере (Get-InstalledProto).
    # Нет детекта (старый/пустой роутер) → 'awg' как было (с -SkipBins лишних бинарей всё равно нет).
    $instProto = Get-InstalledProto
    if (-not $instProto) { $instProto = 'awg' }
    if (-not (Upload-AllFiles -Proto $instProto -SkipBins $true)) { Write-Err "Загрузка сорвалась"; return }

    # Дёрнем awg-heal, чтобы он пересобрал состояние с новыми скриптами
    Write-Info "Дёргаю awg-heal.sh чтобы применить новые скрипты..."
    Run-SSH "$AWG_DIR/awg-heal.sh 2>&1 | tail -20" | ForEach-Object { Write-Host $_ }
    Write-Ok "Скрипты обновлены"
}

function Action-Rollback {
    Write-Section "Откат из backup"
    $backups = Get-LocalBackups
    if ($backups.Count -eq 0) {
        Write-Warn "В $BACKUP_DIR нет файлов awg-backup-*.tar.gz"
        return
    }
    Write-Host "Доступные backup'ы (новые сверху):"
    $i = 1; $map = @{}
    foreach ($b in $backups) {
        $sizeKb = [math]::Round($b.Length / 1024, 1)
        Write-Host ("  {0}) {1}  [{2} KB]  {3:yyyy-MM-dd HH:mm}" -f $i, $b.Name, $sizeKb, $b.LastWriteTime)
        $map[$i.ToString()] = $b
        $i++
    }
    Write-Host "  0) Отмена"
    $sel = Read-Host "Выбери номер"
    if ($sel -eq "0" -or -not $map.ContainsKey($sel)) { Write-Warn "Отмена"; return }
    $backup = $map[$sel]

    Write-Host ""
    Write-Warn "Откат сделает:"
    Write-Host "  1. Снимет awg0, сбросит ipset, mangle-правила, fwmark"
    Write-Host "  2. Восстановит /data/usr/app/awg/, /etc/rc.local, /etc/dnsmasq.d/, cron"
    Write-Host "  3. Перезагрузит роутер (overlay /etc сбросится, awg-heal.sh поднимет всё с нуля)"
    $ans = Read-Host "Точно откатить из $($backup.Name)? (y/N)"
    if ($ans -ne "y" -and $ans -ne "Y") { Write-Warn "Отмена"; return }

    if (-not (PreFlight)) { Write-Err "Pre-flight не прошёл, откат отменён"; return }

    # 1. Заливаем tar на роутер
    $remoteTar = "/tmp/$($backup.Name)"
    Write-Info "Заливаю backup на роутер..."
    if (-not (Upload-File -LocalPath $backup.FullName -RemotePath $remoteTar)) {
        Write-Err "Загрузка backup сорвалась"
        return
    }

    # 2. Гасим текущее состояние + восстанавливаем
    $restore = @"
set +e
# Гасим текущее
ifconfig awg0 down 2>/dev/null
ip link del awg0 2>/dev/null
iptables -t mangle -F PREROUTING 2>/dev/null
iptables -t mangle -F OUTPUT 2>/dev/null
ip rule del fwmark 0x1 2>/dev/null
ipset destroy awg_list 2>/dev/null
ipset destroy iplist_set 2>/dev/null

# Распаковываем backup
TAR=$remoteTar
TMPDIR=/tmp/awg-restore-`$`$
mkdir -p `$TMPDIR
tar xzf `$TAR -C `$TMPDIR
SRCDIR=`$(ls -d `$TMPDIR/awg-bk-* 2>/dev/null | head -1)
if [ -z "`$SRCDIR" ]; then echo "ERR: backup пустой"; exit 1; fi

# Восстанавливаем /data/usr/app/awg
if [ -d "`$SRCDIR/awg_dir" ]; then
    rm -rf /data/usr/app/awg
    cp -a "`$SRCDIR/awg_dir" /data/usr/app/awg
    echo "OK: awg_dir восстановлен"
fi

# Восстанавливаем /etc файлы (они слетят при ребуте -- но awg-heal.sh поднимет)
[ -f "`$SRCDIR/rc.local" ]       && cp "`$SRCDIR/rc.local" /etc/rc.local
[ -d "`$SRCDIR/dnsmasq.d" ]      && { rm -rf /etc/dnsmasq.d; cp -a "`$SRCDIR/dnsmasq.d" /etc/dnsmasq.d; }
[ -f "`$SRCDIR/dnsmasq.conf" ]   && cp "`$SRCDIR/dnsmasq.conf" /etc/dnsmasq.conf
[ -f "`$SRCDIR/crontabs_root" ]  && cp "`$SRCDIR/crontabs_root" /etc/crontabs/root

rm -rf `$TMPDIR `$TAR
echo "RESTORE_OK"
"@
    $r = Invoke-Router -Command $restore
    if ($r) { Write-Host ($r -join "`n") }
    if (-not $r -or "$r" -notmatch "RESTORE_OK") {
        Write-Err "Распаковка backup сорвалась"
        return
    }
    Write-Ok "Backup распакован на роутере"

    Write-Host ""
    $ans = Read-Host "Перезагрузить роутер сейчас? (рекомендуется) (y/N)"
    if ($ans -eq "y" -or $ans -eq "Y") {
        Run-SSH "( sleep 1 && reboot ) &" | Out-Null
        Write-Ok "Роутер уходит в ребут. Жди ~2 минуты, потом проверь 'awg' через be7000."
    } else {
        Write-Warn "Без ребута часть /etc может остаться от старого состояния. Можно так: 'sh $AWG_DIR/awg-heal.sh' через SSH."
    }
}

function Action-Uninstall {
    Write-Section "Полное удаление AWG с роутера"
    Write-Warn "Удалит:"
    Write-Host "  - awg0 интерфейс, ipset, mangle/fwmark правила (вкл. цепочки VPN_EXCLUDE/VPN_FORCE)"
    Write-Host "  - /etc/dnsmasq.d/awg-*.conf, /etc/dnsmasq.d/00-upstream.conf"
    Write-Host "  - cron-записи awg-heal/iplist-update/update-lists/awg-watchdog/xiaomi-bypass"
    Write-Host "  - блок AWG-SETUP-BE7000 из /etc/rc.local"
    Write-Host "  - симлинки /usr/bin/{awg,vpn,domain}"
    Write-Host "  - файлы в /data/usr/app/awg/ (conf, ключи, секреты) -- опционально, спрошу в конце"
    Write-Host ""
    $ans = Read-Host "Подтверди (y/N)"
    if ($ans -ne "y" -and $ans -ne "Y") { Write-Warn "Отмена"; return }

    # Удаление снимает AWG С РОУТЕРА -- локальный install-payload (awg.conf/.sh/бинари)
    # для этого НЕ нужен. Гонять полный PreFlight тут нельзя: он валидирует awg.conf и
    # падает, если запущено из клона репо без секретов (awg.conf в .gitignore). Хватает
    # связи: plink + роутер доступен + SSH (PreFlight-Remote). pscp проверит сам backup ниже.
    if (-not (PreFlight-Remote)) { Write-Err "Нет связи с роутером, удаление отменено"; return }

    # Сначала backup на всякий
    $backup = New-Backup
    if (-not $backup) { Write-Err "Backup не получился, отмена"; return }

    $cmd = @"
set +e
ifconfig awg0 down 2>/dev/null
ip link del awg0 2>/dev/null
iptables -t mangle -F PREROUTING 2>/dev/null
iptables -t mangle -F OUTPUT 2>/dev/null
iptables -t mangle -F VPN_EXCLUDE 2>/dev/null; iptables -t mangle -X VPN_EXCLUDE 2>/dev/null
iptables -t mangle -F VPN_FORCE 2>/dev/null; iptables -t mangle -X VPN_FORCE 2>/dev/null
ip rule del fwmark 0x1 2>/dev/null
ip rule del fwmark 0x1 table 1000 2>/dev/null
ipset destroy awg_list 2>/dev/null
ipset destroy iplist_set 2>/dev/null
rm -f /etc/dnsmasq.d/awg-*.conf /etc/dnsmasq.d/00-upstream.conf 2>/dev/null
sed -i '/# AWG-SETUP-BE7000 START/,/# AWG-SETUP-BE7000 END/d' /etc/rc.local 2>/dev/null
sed -i '/awg-heal\.sh/d'      /etc/crontabs/root 2>/dev/null
sed -i '/iplist-update\.sh/d' /etc/crontabs/root 2>/dev/null
sed -i '/update-lists\.sh/d'  /etc/crontabs/root 2>/dev/null
sed -i '/awg-watchdog\.sh/d'  /etc/crontabs/root 2>/dev/null
sed -i '/xiaomi-bypass\.sh/d' /etc/crontabs/root 2>/dev/null
rm -f /usr/bin/awg /usr/bin/vpn /usr/bin/domain 2>/dev/null
/etc/init.d/cron restart 2>/dev/null || /etc/init.d/crond restart 2>/dev/null
/etc/init.d/dnsmasq restart 2>/dev/null
echo "UNINSTALL_OK"
"@
    $r = Invoke-Router -Command $cmd
    if ($r) { Write-Host ($r -join "`n") }
    if ("$r" -match "UNINSTALL_OK") {
        Write-Ok "AWG деактивирован (awg0/ipset/правила/cron/dnsmasq/rc.local сняты)."
        Write-Host ""
        Write-Warn "В $AWG_DIR остались файлы и СЕКРЕТЫ:"
        Write-Host "  - awg.conf / awg0.conf / configs/*.conf  (приватные ключи VPN)"
        Write-Host "  - notify.conf  (логин/пароль SMTP в открытом виде, если настраивал почту)"
        Write-Host "  - вырезы мимо VPN (.bypass-*), режим failover, снимок iplist, кастомный список (iplist.custom)"
        Write-Info "Оставить удобно для переустановки. Но если отдаёшь/продаёшь роутер -- лучше стереть."
        if (_Confirm "Стереть ТАКЖЕ все файлы в $AWG_DIR (полная очистка, переустановка будет с нуля)?") {
            $wipe = Invoke-Router -Command "rm -rf $AWG_DIR && echo WIPE_OK || echo WIPE_FAIL"
            if ("$wipe" -match "WIPE_OK") {
                Write-Ok "$AWG_DIR удалён полностью. Роутер чист от AWG."
                $script:AwgState = "FRESH"
                $script:RouterSummary = $null   # .transport стёрт — не показывать в шапке старый «Протокол · Конфиг»
            } else {
                Write-Warn "Не удалось удалить ${AWG_DIR}:"; Write-Host ($wipe -join "`n") -ForegroundColor DarkGray
            }
        } else {
            Write-Ok "Файлы в $AWG_DIR оставлены -- можно вернуть через «Установка и обслуживание» -> Установить."
        }
        Write-Info "Backup для отката: $backup"
    } else {
        Write-Warn "Что-то не так, проверь вывод"
    }
}

function PreFlight-Remote {
    if (-not (Find-Plink)) { Write-Err "plink.exe не найден"; return $false }
    if (-not (Test-Connection -ComputerName $ROUTER_IP -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
        Write-Err "$ROUTER_IP не отвечает"; return $false
    }
    if (-not (Ensure-HostKey)) { Write-Err "SSH не работает"; return $false }
    return $true
}

function Test-RouterReachable {
    # Быстрая проверка ДО попыток SSH (ping + TCP-порт 22). Чтобы на старте:
    #  - не дёргать сохранение пароля «в пустоту», когда роутер недоступен;
    #  - сразу сказать, ЧТО чинить (сеть/IP или закрытый SSH), а не ловить «код 1».
    if (-not (Test-Connection -ComputerName $ROUTER_IP -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
        Write-Warn "Роутер $ROUTER_IP не отвечает на ping."
        Write-Info "Проверь: ты в сети роутера (LAN-кабель/его Wi-Fi)? Верный IP ($ROUTER_IP)?"
        return $false
    }
    # TCP-проба порта 22 с таймаутом 2с (Test-NetConnection медленный и шумит).
    $portOpen = $false
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect($ROUTER_IP, 22, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(2000, $false) -and $tcp.Connected) { $portOpen = $true }
        $tcp.Close()
    } catch { $portOpen = $false }
    if (-not $portOpen) {
        Write-Warn "$ROUTER_IP пингуется, но SSH (порт 22) закрыт."
        Write-Info "Включи постоянный SSH через xmir-patcher (пункт 'Install permanent SSH'),"
        Write-Info "см. README, Шаг 1 (root-доступ по SSH)."
        return $false
    }
    return $true
}

function Action-Diagnose {
    Write-Section "Диагностика"

    # Локальные файлы рядом со скриптом -- информационно
    Write-Section "Локально в $SCRIPT_DIR"
    foreach ($f in $REQUIRED_FILES) {
        $p = Join-Path $SCRIPT_DIR $f
        if (Test-Path $p) { Write-Ok "$f ($((Get-Item $p).Length) байт)" }
        else { Write-Err "$f -- НЕТ (обязательный, для установки нужен)" }
    }
    foreach ($f in $OPTIONAL_FILES) {
        $p = Join-Path $SCRIPT_DIR $f
        if (Test-Path $p) { Write-Ok "$f (опц., есть)" }
        else { Write-Info "$f (опц., нет)" }
    }
    foreach ($k in $BIN_FILES.Keys) {
        $p = Join-Path $SCRIPT_DIR $BIN_FILES[$k]
        if (Test-Path $p) {
            $sizeKb = [math]::Round((Get-Item $p).Length / 1024, 1)
            Write-Ok "$k (AWG 2.0 бинарник, $sizeKb KB)"
        } else {
            Write-Info "$k (AWG 2.0 бинарник, нет -- нужен только для AWG 2.0 без Legacy)"
        }
    }
    $cfgDir = Join-Path $SCRIPT_DIR "configs"
    if (Test-Path $cfgDir) {
        $cfgs = @(Get-ChildItem -Path $cfgDir -Filter "*.conf" -ErrorAction SilentlyContinue)
        Write-Info "configs/: $($cfgs.Count) .conf файлов"
    } else {
        Write-Info "configs/: нет (опц. папка с конфигами стран)"
    }

    Write-Host ""
    if (-not (PreFlight-Remote)) { return }

    Write-Section "awg-status"
    $r = Run-SSH "if command -v awg >/dev/null 2>&1; then awg; elif [ -x $AWG_DIR/awg-status.sh ]; then sh $AWG_DIR/awg-status.sh; else echo '(awg-status.sh не установлен -- AWG ещё не накатан?)'; fi"
    Write-Host ($r -join "`n")

    Write-Section "Интерфейс awg0"
    $r = Run-SSH "ip a show awg0 2>/dev/null || echo '(awg0 не поднят)'"
    Write-Host ($r -join "`n")

    Write-Section "Handshake / transfer"
    $r = Run-SSH "$AWG_DIR/awg show awg0 2>/dev/null | grep -E 'latest handshake|transfer|endpoint' || echo '(awg show не отрабатывает)'"
    Write-Host ($r -join "`n")

    Write-Section "iptables FORWARD (первые правила)"
    $r = Run-SSH "iptables -L FORWARD -v -n 2>/dev/null | head -5"
    Write-Host ($r -join "`n")
    Write-Info "Должны быть 2 ACCEPT для awg0 (в обе стороны). Без них трафик дропается -- почини: меню «Починить правила»."

    Write-Section "ip rule (fwmark маршрутизация)"
    $r = Run-SSH "ip rule show | grep -E 'fwmark|^[0-9]+:' | head -10"
    Write-Host ($r -join "`n")

    Write-Section "ipset (наполнение)"
    $r = Run-SSH "for s in awg_list iplist_set; do n=`$(ipset list `$s 2>/dev/null | grep -c '^[0-9]'); echo `$s: `$n записей; done"
    Write-Host ($r -join "`n")

    Write-Section "Cron (awg-heal, iplist)"
    $r = Run-SSH "grep -E 'awg-heal|iplist-update|update-lists' /etc/crontabs/root 2>/dev/null || echo '(пусто -- после ребута не поднимется!)'"
    Write-Host ($r -join "`n")

    Write-Section "dnsmasq.d (overlay)"
    $r = Run-SSH "ls -la /etc/dnsmasq.d/ 2>/dev/null | grep -E 'awg|upstream' || echo '(нет наших файлов -- overlay сброшен? awg-heal.sh должен поднять через минуту)'"
    Write-Host ($r -join "`n")

    Write-Section "Файлы в $AWG_DIR"
    $r = Run-SSH "ls -la $AWG_DIR/ 2>/dev/null"
    Write-Host ($r -join "`n")

    Write-Section "Бинарники AWG (на роутере)"
    $binCmd = @"
ls -la $AWG_DIR/amneziawg-go $AWG_DIR/awg 2>/dev/null || echo '(бинарники не установлены)'
echo '--- versions ---'
[ -x $AWG_DIR/amneziawg-go ] && $AWG_DIR/amneziawg-go --version 2>&1 | head -1
[ -x $AWG_DIR/awg ] && $AWG_DIR/awg --version 2>&1 | head -1
"@
    $r = Run-SSH $binCmd
    Write-Host ($r -join "`n")

    Write-Section "Лог последнего awg-heal"
    $r = Run-SSH "[ -f /tmp/awg-startup.log ] && tail -15 /tmp/awg-startup.log || echo '(awg-startup.log нет -- heal ещё не запускался)'"
    Write-Host ($r -join "`n")

    Write-Section "Тест: внешний IP через awg0"
    $r = Run-SSH "curl -s --interface awg0 --max-time 5 https://api.ipify.org 2>/dev/null || echo '(curl через awg0 не отработал)'"
    Write-Host ($r -join "`n")
}

function Action-DiagDump {
    Write-Section "Выгрузка диагностики в файл (логи + состояние)"
    # Гоним ЛОКАЛЬНЫЙ awg-dump.sh на роутер: stdin = base64(скрипта), команда =
    # 'base64 -d | sh | base64'. Первый 'base64 -d' разворачивает скрипт, 'sh' его
    # исполняет, а ВЫХОД дампа кодируется обратно в base64 ВТОРЫМ 'base64'.
    # Зачем двойной base64: вывод роутера — UTF-8 (кириллица), а PowerShell 5
    # декодирует stdout нативного plink по КОДОВОЙ СТРАНИЦЕ КОНСОЛИ (не UTF-8) →
    # кириллица превращалась в мусор ещё на этапе захвата (та самая "непонятная
    # кодировка" в файле). base64 — чистый ASCII, консольная кодировка его не
    # портит; на ПК декодируем БАЙТЫ и пишем их как есть. Бонусом скрипт всегда
    # исполняется из репо (актуальная версия), даже если на роутере его ещё нет.
    $localDump = Join-Path $SCRIPT_DIR "awg-dump.sh"
    if (-not (Test-Path $localDump)) {
        Write-Err "Рядом со скриптом нет awg-dump.sh ($SCRIPT_DIR) — обнови репозиторий проекта."
        return
    }
    Write-Info "Снимаю состояние роутера (несколько секунд)..."
    # ВАЖНО: читаем awg-dump.sh как UTF-8 ЯВНО. Get-Content -Raw на ру-Windows
    # (PS5) для файла БЕЗ BOM берёт ANSI-кодировку (CP1251) → кириллица скрипта
    # ломалась в двойную кодировку ещё ДО отправки (на роутер уезжал мусор, в
    # дампе «часть битая»: латиница/цифры ок, кириллица каракулями). ReadAllText
    # с UTF8 декодирует корректно (BOM не обязателен).
    $raw   = [System.IO.File]::ReadAllText($localDump, [System.Text.Encoding]::UTF8)
    $b64in = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($raw -replace "`r`n", "`n")))
    # Маркеры BEGIN/END вокруг base64 — отсекают возможный шум plink/MOTD до и
    # после полезных данных (любая лишняя НЕ-пробельная строка сломала бы
    # FromBase64String, причём молча — буквы шума сами по себе валидный base64).
    $out = Invoke-Router -Command "printf '___AWGDUMP_BEGIN___\n'; base64 -d | sh | base64; printf '___AWGDUMP_END___\n'" -StdinData $b64in -Silent
    if (-not $out) {
        Write-Err "Пустой ответ от роутера (связь/SSH/пароль?). Проверь: «Установка и обслуживание» -> pre-flight / диагностика."
        return
    }
    # Берём строго то, что между маркерами; склеиваем и выкидываем пробелы/переводы.
    $text = (@($out) -join "`n")
    $m = [regex]::Match($text, '(?s)___AWGDUMP_BEGIN___(.*?)___AWGDUMP_END___')
    $b64out = if ($m.Success) { $m.Groups[1].Value -replace '\s', '' } else { $text -replace '\s', '' }
    try {
        $bytes = [Convert]::FromBase64String($b64out)
    } catch {
        Write-Err "Не удалось декодировать ответ роутера (ожидался base64). Связь оборвалась / старый busybox без 'base64'?"
        return
    }
    # Кладём НЕ в корень репо, а в подпапку diag/ (чтобы не засорять корень; она в .gitignore).
    $diagDir = Join-Path $SCRIPT_DIR "diag"
    if (-not (Test-Path $diagDir)) { New-Item -ItemType Directory -Path $diagDir -Force | Out-Null }
    $ts      = Get-Date -Format "yyyyMMdd-HHmmss"
    $outFile = Join-Path $diagDir "be7000-diag-$ts.txt"
    # Заголовок ПК-стороны (массив строк, чтобы не возиться с here-string в CRLF-файле).
    $headerText = (@(
        "# BE7000 — диагностический дамп",
        "# собран: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  ПК -> $ROUTER_USER@$ROUTER_IP",
        "# Ключи, endpoint и публичные IP замаскированы скриптом awg-dump.sh.",
        "# ВСЁ РАВНО просмотри файл перед публикацией — маскировка эвристическая.",
        ""
    ) -join "`n") + "`n"
    # Пишем БАЙТАМИ: BOM (чтобы редакторы сразу увидели UTF-8) + заголовок + тело роутера.
    $buf = New-Object System.Collections.Generic.List[byte]
    $buf.AddRange([byte[]](0xEF, 0xBB, 0xBF))
    $buf.AddRange([Text.Encoding]::UTF8.GetBytes($headerText))
    $buf.AddRange($bytes)
    [System.IO.File]::WriteAllBytes($outFile, $buf.ToArray())
    $kb = [math]::Round((Get-Item $outFile).Length / 1024, 1)
    Write-Ok "Готово: $outFile  ($kb КБ)"
    Write-Info "Можно приложить к вопросу в чате сообщества — секреты уже замаскированы."
    $ans = Read-Host "Открыть файл сейчас? (y/N)"
    if ($ans -match '^[yY]') { Start-Process notepad.exe $outFile }
}

function Get-RouterSummary {
    # Короткая сводка для шапки меню: прошивка (ROM), нагрузка CPU, RAM. Отдаём с
    # роутера ASCII-токенами (FW/LOAD/RAM) и форматируем по-русски здесь — латиница/
    # цифры консольной кодировкой не портятся (в отличие от кириллицы; см. Action-
    # DiagDump). Версию прошивки Xiaomi берём из UCI /usr/share/xiaoqiang/xiaoqiang_version
    # (option ROM '1.1.38' / CHANNEL 'release' — то же, что в веб-морде «Version: 1.1.38 Release»).
    $sh = @'
F=/usr/share/xiaoqiang/xiaoqiang_version
rom=$(grep -E "option ROM " $F 2>/dev/null | sed "s/.*'\(.*\)'.*/\1/")
ch=$(grep -E "option CHANNEL " $F 2>/dev/null | sed "s/.*'\(.*\)'.*/\1/")
echo "FW ${rom:-?} ${ch:-?}"
echo "LOAD $(cut -d' ' -f1 /proc/loadavg 2>/dev/null) $(grep -c ^processor /proc/cpuinfo 2>/dev/null)"
awk '/^MemTotal:/{t=$2}/^MemFree:/{f=$2}/^MemAvailable:/{a=$2}END{printf "RAM %d %d\n",(a==""?f:a)/1024,t/1024}' /proc/meminfo 2>/dev/null
df /data 2>/dev/null | tail -1 | awk 'NF>=5{printf "DISK %d %d %s\n",$(NF-2)/1024,$(NF-4)/1024,$(NF-1)}'
D=/data/usr/app/awg
echo "TPT $(cat $D/.transport 2>/dev/null || echo awg)"
echo "ACONF $(cat $D/.active 2>/dev/null)"
echo "XCONF $(cat $D/.xray-active 2>/dev/null)"
echo "HCONF $(cat $D/.hy2-active 2>/dev/null)"
# Живость несущей (LIVE 0|1): шапка не должна врать «Протокол: X», когда туннель не несёт.
# Дёшево и без egress-пробы: есть ли default в table 1000 И жив ли бэкенд активного
# транспорта (awg -> свежий handshake awg0; альт -> socks 10808 слушается = QUIC/Reality
# сессия установлена). Всё локально/мгновенно, лишнего SSH-таймаута не добавляет.
t=$(cat $D/.transport 2>/dev/null || echo awg)
live=0
if ip route show table 1000 2>/dev/null | grep -q '^default'; then
  case "$t" in
    awg) hs=$($D/awg show awg0 latest-handshakes 2>/dev/null | awk 'NR==1{print $2}'); case "$hs" in ''|*[!0-9]*) hs=0;; esac; [ "$hs" -gt 0 ] && [ $(( $(date +%s) - hs )) -lt 180 ] && live=1 ;;
    *)   netstat -ltn 2>/dev/null | grep -q '127.0.0.1:10808' && live=1 ;;
  esac
fi
echo "LIVE $live"
'@
    $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(($sh -replace "`r`n", "`n")))
    $out = Invoke-Router -Command "echo $b64 | base64 -d | sh" -Silent
    if (-not $out) { return $null }
    $fw = $null; $load = $null; $ram = $null; $disk = $null
    $tpt = "awg"; $aconf = $null; $xconf = $null; $hconf = $null
    $live = -1   # -1 = неизвестно (старый роутер без токена LIVE) -> не утверждаем про несущую
    foreach ($ln in @($out)) {
        $p = (("$ln" -replace "`r", "").Trim()) -split "\s+"
        switch ($p[0]) {
            "FW"   { if ($p.Count -ge 3) { $fw = "$($p[1]) ($($p[2]))" } elseif ($p.Count -ge 2) { $fw = $p[1] } }
            "TPT"   { if ($p.Count -ge 2 -and $p[1]) { $tpt   = $p[1] } }
            "ACONF" { if ($p.Count -ge 2 -and $p[1]) { $aconf = $p[1] } }
            "XCONF" { if ($p.Count -ge 2 -and $p[1]) { $xconf = $p[1] } }
            "HCONF" { if ($p.Count -ge 2 -and $p[1]) { $hconf = $p[1] } }
            "LIVE"  { if ($p.Count -ge 2 -and $p[1] -match '^[01]$') { $live = [int]$p[1] } }
            "LOAD" {
                if ($p.Count -ge 3) {
                    # load average -> понятный % загрузки ЦП (load/ядра*100). Парсим
                    # инвариантно: на ру-Windows [double]"1.04" ломается (дес. запятая).
                    try {
                        $l1 = [double]::Parse($p[1], [System.Globalization.CultureInfo]::InvariantCulture)
                        $nc = [int]$p[2]
                        if ($nc -gt 0) { $load = "ЦП ~$([math]::Round($l1 / $nc * 100))%" }
                    } catch { }
                }
            }
            "RAM"  { if ($p.Count -ge 3) { $ram  = "ОЗУ $($p[1]) из $($p[2]) МБ своб" } }
            "DISK" { if ($p.Count -ge 4) { $disk = "ПЗУ /data $($p[1]) из $($p[2]) МБ своб ($($p[3]))" } }
        }
    }
    # Строка протокола: какой транспорт несёт трафик + активный конфиг. Обновляется
    # при смене транспорта/страны/xray-конфига (вызовы Get-RouterSummary после них) —
    # см. Action-SwitchTransport/SwitchCountry/SwitchXrayConfig. CPU/RAM/прошивка
    # остаются снимком за сессию (тянуть на каждом экране = лишний SSH-таймаут).
    if ($tpt -eq "xray")    { $pname = "Xray";      $cfg = if ($xconf) { $xconf } else { '?' } }
    elseif ($tpt -eq "hy2") { $pname = "Hysteria2"; $cfg = if ($hconf) { $hconf } else { '?' } }
    else                    { $pname = "AmneziaWG"; $cfg = if ($aconf) { $aconf } else { '?' } }
    # Шапка отражает РЕАЛЬНОЕ состояние несущей, а не просто .transport: live=1 — VPN
    # несёт; live=0 — туннель не поднят (fail-open, трафик напрямую) и это надо кричать,
    # иначе «Протокол: Hysteria2» вводит в заблуждение, будто VPN включён; live=-1 —
    # старый роутер без токена, не утверждаем (нейтральная строка как раньше).
    # Префикс '[!]' ловит Show-Header и красит строку жёлтым.
    if ($live -eq 0)        { $proto = "[!] VPN НЕ АКТИВЕН — несущая $pname ($cfg) НЕ поднята, трафик идёт НАПРЯМУЮ" }
    elseif ($live -eq 1)    { $proto = "Протокол: $pname  ·  Конфиг: $cfg  ·  VPN активен" }
    else                    { $proto = "Протокол: $pname  ·  Конфиг: $cfg" }
    # Две строки ресурсов: 1) прошивка + ЦП, 2) ОЗУ + ПЗУ (в одну строку всё длинно).
    $l1 = @(); if ($fw) { $l1 += "Прошивка $fw" }; if ($load) { $l1 += $load }
    $l2 = @(); if ($ram) { $l2 += $ram };          if ($disk) { $l2 += $disk }
    $lines = @()
    if ($proto) { $lines += $proto }
    if ($l1.Count) { $lines += ($l1 -join "  ·  ") }
    if ($l2.Count) { $lines += ($l2 -join "  ·  ") }
    if (-not $lines.Count) { return $null }
    return $lines
}

function Show-Header {
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  BE7000 — AmneziaWG: установка + управление  v$($script:ProjectVersion)" -ForegroundColor Cyan
    Write-Host "  Роутер: $ROUTER_IP" -ForegroundColor Cyan
    if ($script:RouterSummary) {
        foreach ($l in @($script:RouterSummary)) {
            # Строку «VPN НЕ АКТИВЕН» (префикс [!] из Get-RouterSummary) выделяем жёлтым,
            # чтобы провал несущей бросался в глаза на любом экране, а не сливался с шапкой.
            $clr = if ("$l" -match '^\[!\]') { 'Yellow' } else { 'Cyan' }
            Write-Host "  $l" -ForegroundColor $clr
        }
    }
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  Поддержать проект:  https://web.tribute.tg/d/LtA" -ForegroundColor DarkYellow
    Write-Host "============================================================" -ForegroundColor Cyan
}

# Подменю с ЛОКАЛЬНОЙ нумерацией (1..N + 0 назад). Остаётся открытым, пока не введут 0
# (можно сделать несколько операций подряд). $Items: @{ Label; Do(scriptblock); Color }.
function Invoke-Submenu {
    param([string]$Title, [object[]]$Items)
    while ($true) {
        Clear-Host
        Show-Header
        Write-Host ""
        Write-Host "  $Title" -ForegroundColor White
        Write-Host ""
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $clr = if ($Items[$i].Color) { $Items[$i].Color } else { "Gray" }
            Write-Host ("  {0,2}) {1}" -f ($i + 1), $Items[$i].Label) -ForegroundColor $clr
        }
        Write-Host ""
        Write-Host "   0) Назад"
        Write-Host ""
        $sel = Read-Host "Выбор"
        if ($sel -eq "0" -or $sel -eq "") { return }
        $n = 0
        if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $Items.Count) {
            & $Items[$n - 1].Do
            Write-Host ""
            Read-Host "Enter — назад в подменю"
        } else {
            Write-Warn "Нет такого пункта"
            Start-Sleep -Milliseconds 600
        }
    }
}

# ============================================================
# Старт: детект состояния роутера -> установка или управление
# ============================================================
$plinkExe = Find-Plink
if (-not $plinkExe) {
    Write-Err "plink.exe не найден."
    Write-Host "Установи PuTTY (ставит и plink, и pscp): https://www.putty.org/ -> 'Package files' -> MSI installer."
    Write-Host "После установки они будут в C:\Program Files\PuTTY\ (или добавь их каталог в PATH)."
    Read-Host "Нажми Enter для выхода"
    exit 1
}
# pscp не фатален: меню/управление ходят через plink. Но установка/backup
# (пункты 30/31/33/34) без pscp не сработают — предупредим заранее.
if (-not (Find-Pscp)) {
    Write-Warn "pscp.exe не найден — установка / обновление / backup / откат работать НЕ будут."
    Write-Info "Он идёт в том же PuTTY MSI (https://www.putty.org/). Управление по SSH доступно и без него."
}

# Установлен ли AWG на роутере? Проба по двум ключевым файлам.
function Detect-AwgState {
    # INSTALLED, если есть switch-vpn.sh И хотя бы один конфиг ЛЮБОГО транспорта:
    # awg.conf (AmneziaWG) / xray.json|xray-configs/*.json (Xray) / hysteria.yaml|
    # hy2-configs/*.yaml (Hysteria2). Иначе alt-only установка (hy2/xray без awg)
    # ошибочно выглядела бы как FRESH. hy2-ветку добавили июнь 2026 — без неё
    # чисто-Hysteria2 роутер детектился «не установлен» и меню звало переустановку.
    $probe = "[ -f $AWG_DIR/switch-vpn.sh ] && { [ -f $AWG_DIR/awg.conf ] || [ -s $AWG_DIR/xray.json ] || ls $AWG_DIR/xray-configs/*.json >/dev/null 2>&1 || [ -s $AWG_DIR/hysteria.yaml ] || ls $AWG_DIR/hy2-configs/*.yaml >/dev/null 2>&1; } && echo INSTALLED || echo FRESH"
    $out = "" + (Invoke-Router -Command $probe -Silent)
    if ($out -match "INSTALLED") { return "INSTALLED" }
    if ($out -match "FRESH")     { return "FRESH" }
    return "UNKNOWN"   # роутер недоступен / нет пароля
}

# Состояние, по которому меню решает, показывать ли блок управления.
# -Manage форсирует полное меню; -Install — ветку установки.
$script:AwgState = "INSTALLED"
if (-not $Manage) {
    if ($Install) {
        $script:AwgState = "FRESH"
    } else {
        Write-Section "Проверяю состояние роутера ($ROUTER_IP)"
        # Ранняя проверка связи ДО SSH: не дёргаем пароль «в пустоту» и сразу
        # подсказываем, что чинить (сеть / закрытый SSH), если роутер не отвечает.
        if (-not (Test-RouterReachable)) {
            $script:AwgState = "UNKNOWN"
            Write-Info "В меню: «Установка и обслуживание» (установка/диагностика) и «Доступ» (пароль)."
        } else {
            $script:AwgState = Detect-AwgState
            if ($script:AwgState -eq "UNKNOWN") {
                # Порт 22 открыт, но проба по SSH не прошла — обычно пароль не сохранён/неверен.
                Write-Warn "Роутер на связи, но проверить установку не вышло — похоже, пароль не сохранён/неверен."
                Write-Info "В меню: «Доступ» -> пароль, затем «Установка и обслуживание» -> диагностика."
            }
        }
    }
    if ($script:AwgState -eq "FRESH") {
        Write-Warn "AmneziaWG на роутере не найден (или роутер свежий)."
        # При дропе файлов не лезем с авто-установкой — юзер пришёл залить конфиги.
        if (-not $DropFiles -and (_Confirm "Запустить установку сейчас?")) { Action-Install }
        elseif (-not $DropFiles) { Write-Info "Ок — установка доступна в меню: «Установка и обслуживание»." }
    } elseif ($script:AwgState -eq "INSTALLED") {
        Write-Ok "AmneziaWG установлен — открываю меню управления."
    }
}

# Файлы, перетащенные мышью НА be7000.bat (.bat форвардит их в %* -> $DropFiles):
# мульти-заливка конфигов БЕЗ диалога per-файл. Делаем ДО меню; затем обычный поток
# продолжится — можно сразу активировать нужный конфиг в меню.
if ($DropFiles -and @($DropFiles).Count -gt 0) {
    if ($script:AwgState -eq "UNKNOWN") {
        Write-Warn "Роутер недоступен — перетащенные конфиги не залить. Проверь связь/пароль и повтори."
    } else {
        Action-IngestDroppedConfigs @($DropFiles)
        if (-not (_Confirm "Открыть меню управления?")) { exit 0 }
    }
}

# Сводка роутера (прошивка/CPU/RAM) в шапку меню — тянем ОДИН раз за сессию и
# кэшируем (ASCII-токены, кодировке консоли не подвластны). Пропускаем, если
# роутер недоступен (UNKNOWN) — лишний таймаут на старте ни к чему.
$script:RouterSummary = $null
if ($script:AwgState -ne "UNKNOWN") { $script:RouterSummary = Get-RouterSummary }

# Окно консоли: меню управления длинное (~65 строк) → пробуем растянуть окно под
# него, чтобы шапка была видна сразу. Короткому меню (FRESH/UNKNOWN) хватает
# скромной высоты. Best-effort (см. Try-GrowConsole — если не вышло, не страшно).
Try-GrowConsole -Rows $(if ($script:AwgState -eq "INSTALLED") { 68 } else { 32 })

# ============================================================
# Меню: категории (главное) -> подменю (локальная нумерация 1..N).
# Action-* функции не меняются — меняется только навигация. Mgmt=$true -> категория
# видна лишь когда AWG установлен; иначе доступны только установка/обслуживание и доступ.
# ============================================================
$cats = @(
    @{ Title = "Статус роутера"; Mgmt = $true; Direct = { Action-Status } }
    @{ Title = "VPN: включить / выключить / весь трафик"; Mgmt = $true; Sub = {
        Invoke-Submenu "VPN — глобально" @(
            @{ Label = "Включить VPN глобально";  Color = "Green";  Do = { Action-VpnOnGlobal } }
            @{ Label = "Выключить VPN глобально"; Color = "Yellow"; Do = { Action-VpnOffGlobal } }
            @{ Label = "Весь трафик / отдельная сеть целиком в туннель (full-tunnel)"; Color = "Magenta"; Do = { Action-FullTunnel } }
        ) } }
    @{ Title = "Устройства: мимо VPN или обратно"; Mgmt = $true; Sub = {
        Invoke-Submenu "Устройства — мимо VPN / обратно в VPN" @(
            @{ Label = "Вывести ЭТОТ ПК мимо VPN"; Color = "Yellow"; Do = { Action-ExcludeThisPC } }
            @{ Label = "Вернуть ЭТОТ ПК в VPN"; Color = "Green"; Do = { Action-IncludeThisPC } }
            @{ Label = "Вывести другое устройство мимо VPN (список / IP)"; Color = "Yellow"; Do = { Action-ExcludeOtherDevice } }
            @{ Label = "Вернуть устройство в VPN (список / IP)"; Color = "Green"; Do = { Action-IncludeOtherDevice } }
            @{ Label = "Показать всё, что выведено мимо VPN"; Do = { Action-ListExcluded } }
        ) } }
    @{ Title = "Сайты, домены и списки IP"; Mgmt = $true; Sub = {
        Invoke-Submenu "Сайты, домены и списки IP" @(
            @{ Label = "Список доменов через VPN"; Do = { Action-DomainList } }
            @{ Label = "Добавить домен в VPN"; Do = { Action-DomainAdd } }
            @{ Label = "Удалить домен из VPN"; Do = { Action-DomainRemove } }
            @{ Label = "Поиск домена в списках"; Do = { Action-DomainSearch } }
            @{ Label = "Вывести САЙТ (IP/подсеть) мимо VPN"; Color = "Yellow"; Do = { Action-ExcludeDstIP } }
            @{ Label = "Вернуть САЙТ (IP/подсеть) в VPN"; Color = "Green"; Do = { Action-IncludeDstIP } }
            @{ Label = "Источник списка IP (iplist): opencck / сайты / URL / кастомный файл"; Color = "Magenta"; Do = { Action-IplistSource } }
        ) } }
    @{ Title = "Серверы AmneziaWG: страны + failover"; Mgmt = $true; Sub = {
        Invoke-Submenu "Серверы AmneziaWG (страны)  ·  xray-серверы — в категории «Протокол»" @(
            @{ Label = "Сменить страну/конфиг AmneziaWG"; Do = { Action-SwitchCountry } }
            @{ Label = "Залить новый конфиг AmneziaWG (.conf) на роутер"; Color = "Green"; Do = { Action-UploadConfig } }
            @{ Label = "Удалить конфиг страны (awg)"; Color = "Red"; Do = { Action-DeleteAwgConfig } }
            @{ Label = "Авто-failover при падении VPS (off/sticky/home)"; Color = "Magenta"; Do = { Action-FailoverToggle } }
        ) } }
    @{ Title = "Протокол: AmneziaWG / Xray / Hysteria2"; Mgmt = $true; Sub = {
        Invoke-Submenu "Протокол: AmneziaWG / Xray / Hysteria2  (альт на флеше один: Xray ЛИБО Hysteria2)" @(
            @{ Label = "Переключить транспорт (awg / xray / hy2)"; Color = "Magenta"; Do = { Action-SwitchTransport } }
            @{ Label = "Xray: добавить конфиг (vless:// или JSON)"; Color = "Green"; Do = { Action-AddXrayConfig } }
            @{ Label = "Xray: выбрать активный конфиг"; Do = { Action-SwitchXrayConfig } }
            @{ Label = "Xray: правка SNI / fingerprint (RKN бьёт по fp=chrome)"; Color = "Yellow"; Do = { Action-EditXrayReality } }
            @{ Label = "Xray: удалить конфиг"; Color = "Red"; Do = { Action-DeleteXrayConfig } }
            @{ Label = "Hysteria2: добавить конфиг (hy2://)"; Color = "Green"; Do = { Action-AddHy2Config } }
            @{ Label = "Hysteria2: выбрать активный конфиг"; Do = { Action-SwitchHy2Config } }
            @{ Label = "Hysteria2: правка SNI / insecure"; Color = "Yellow"; Do = { Action-EditHy2 } }
            @{ Label = "Hysteria2: удалить конфиг"; Color = "Red"; Do = { Action-DeleteHy2Config } }
        ) } }
    @{ Title = "Wi-Fi и подсети (guest / SSID)"; Mgmt = $true; Sub = {
        Invoke-Submenu "Wi-Fi и подсети" @(
            @{ Label = "Статус Wi-Fi + подсети guest/iot + ip rule (read-only)"; Do = { Action-WifiStatus } }
            @{ Label = "Guest-подсеть: вне VPN <-> через VPN"; Color = "Magenta"; Do = { Action-GuestVpnBypassToggle } }
            @{ Label = "Wi-Fi SSID: вне VPN <-> через VPN (выбор из списка)"; Color = "Magenta"; Do = { Action-WifiBypassVpnBySsid } }
            @{ Label = "Откатить /etc/config/wireless из бэкапа"; Color = "DarkYellow"; Do = { Action-WifiRollback } }
        ) } }
    @{ Title = "Уведомления на почту"; Mgmt = $true; Sub = {
        Invoke-Submenu "Уведомления на e-mail (при падении VPN)" @(
            @{ Label = "Настроить почту (Яндекс)"; Color = "Magenta"; Do = { Action-NotifySetup } }
            @{ Label = "Вкл/выкл уведомления"; Do = { Action-NotifyToggle } }
            @{ Label = "Тест: отправить письмо сейчас"; Do = { Action-NotifyTest } }
        ) } }
    @{ Title = "Починить правила (после сброса файрвола)"; Mgmt = $true; Direct = { Action-RepairRules } }
    @{ Title = "Установка и обслуживание"; Mgmt = $false; Sub = {
        Invoke-Submenu "Установка и обслуживание" @(
            @{ Label = "Установить/переустановить AmneziaWG (полный цикл с backup)"; Color = "Green"; Do = { Action-Install } }
            @{ Label = "Обновить только .sh скрипты + awg.conf"; Do = { Action-UpdateScripts } }
            @{ Label = "Pre-flight проверка (без изменений)"; Do = { PreFlight | Out-Null } }
            @{ Label = "Создать backup состояния роутера"; Do = { Action-Backup } }
            @{ Label = "Откатить из backup"; Color = "Yellow"; Do = { Action-Rollback } }
            @{ Label = "Удалить AWG с роутера (uninstall)"; Color = "Red"; Do = { Action-Uninstall } }
            @{ Label = "Диагностика установки (awg status, файлы, cron)"; Do = { Action-Diagnose } }
            @{ Label = "Выгрузить диагностику в файл (логи/состояние)"; Color = "Cyan"; Do = { Action-DiagDump } }
        ) } }
    @{ Title = "Доступ: SSH-команда / сменить пароль"; Mgmt = $false; Sub = {
        Invoke-Submenu "Доступ к роутеру" @(
            @{ Label = "Произвольная команда на роутере (raw SSH)"; Do = { Action-RawSSH } }
            @{ Label = "Изменить сохранённый пароль root"; Do = {
                Action-ChangePassword
                if ($script:AwgState -ne "INSTALLED" -and (Test-RouterReachable)) {
                    $script:AwgState = Detect-AwgState
                    if ($script:AwgState -ne "UNKNOWN") { $script:RouterSummary = Get-RouterSummary }
                }
            } }
        ) } }
)

$exit = $false
while (-not $exit) {
    Clear-Host
    Show-Header
    Write-Host ""
    if ($script:AwgState -ne "INSTALLED") {
        if ($script:AwgState -eq "UNKNOWN") {
            Write-Warn "Роутер недоступен или не отвечает (сеть / SSH / пароль)."
        } else {
            Write-Warn "AmneziaWG на роутере не установлен."
        }
        Write-Info "Доступны установка/обслуживание и доступ к роутеру (см. ниже)."
        Write-Host ""
    }
    $visible = @($cats | Where-Object { (-not $_.Mgmt) -or ($script:AwgState -eq "INSTALLED") })
    for ($i = 0; $i -lt $visible.Count; $i++) {
        Write-Host ("  {0,2}) {1}" -f ($i + 1), $visible[$i].Title)
    }
    Write-Host ""
    Write-Host "   0) Выход"
    Write-Host ""
    $choice = Read-Host "Выбор"
    if ($choice -eq "0") { $exit = $true; continue }
    $n = 0
    if ([int]::TryParse($choice, [ref]$n) -and $n -ge 1 -and $n -le $visible.Count) {
        $cat = $visible[$n - 1]
        if ($cat.Direct) {
            & $cat.Direct
            Write-Host ""
            Read-Host "Enter — назад в меню"
        } elseif ($cat.Sub) {
            & $cat.Sub
        }
    } else {
        Write-Warn "Нет такого пункта"
        Start-Sleep -Milliseconds 600
    }
}
