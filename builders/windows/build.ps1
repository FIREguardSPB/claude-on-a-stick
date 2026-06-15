#Requires -Version 5.1
<#
.SYNOPSIS
    claude-on-a-stick - first-class interactive Windows builder.

.DESCRIPTION
    Turns a USB stick into a portable, no-install "real Claude Code" environment
    that runs the user's own subscription, with an AES-encrypted auth token, an
    anti-ban geo-guard, and an optional bundled Happ VPN.

    This is the Windows counterpart of builders/posix/build.sh and mirrors its
    flow exactly (see CONTRACTS.md, the binding spec):

        0. language pick (RU/EN)            -> shared/i18n.ps1 if present, else
                                               a self-contained map baked here
        1. elevation check (admin is needed to format a physical disk)
        2. USB select + confirm + format exFAT (label CLAUDE, MBR, type 0x07)
                                            -> shared/usb.ps1  Invoke-UsbSelectAndFormat
        3. download claude.exe + sha256-verify against the official manifest
        4. claude setup-token  ->  AES-256-CBC encrypt to config/oauth.enc
                                            -> shared/crypto.ps1  Protect-CasToken
        5. optional Happ VPN: silent Inno install to a dir + deep-link sub insert
                                            -> shared/happ.ps1  Get-Happ / Install-HappPortable
                                               Write-HappRunner / Add-HappSubscription
        6. write geoguard.conf, copy + template the payload launchers
           (bake MODEL + language), then run a self-test.

    Only repo logic ships in git; the claude binary, Happ, the auth token and the
    subscription link are downloaded/entered at build time and land on the stick,
    never in git.

.NOTES
    Encoding (CONTRACTS.md sec. 9): this file is saved UTF-8 *with BOM* so PS 5.1
    reads the RU strings correctly; we also force UTF-8 console + pipeline
    encoding at startup ("Console encoding" below).

    Targets per CONTRACTS.md: Windows = solid/verified.
#>

[CmdletBinding()]
param(
    # Skip the destructive format step (re-build onto an already-formatted CLAUDE stick).
    # You will be asked for the existing drive letter instead.
    [switch]$NoFormat,
    # Force a UI language instead of asking (ru|en). Default: ask, seeded from Get-Culture.
    [ValidateSet('ru', 'en')]
    [string]$Lang,
    # Release channel for the claude binary.
    [ValidateSet('stable', 'latest')]
    [string]$Channel = 'stable',
    # Default model baked into the stick launcher's `--model`. (CONTRACTS.md locked default.)
    [string]$Model = 'claude-opus-4-8',
    # Non-interactive: assume "no VPN" (skips the Happ prompt entirely).
    [switch]$NoHapp,
    # MULTI-OS STICK ("one stick, any OS"): which platform binaries to bake onto the
    # stick. Comma-separated list of release platform ids, or 'A' = all common
    # (win32-x64,linux-x64,darwin-arm64). Default (unset) = THIS host's win32 target.
    # Valid ids: win32-x64 win32-arm64 linux-x64 linux-arm64 linux-x64-musl
    #            linux-arm64-musl darwin-x64 darwin-arm64.  (CONTRACTS.md sec 8 + MULTI-OS delta)
    [string]$Target,
    # Non-interactive escape hatch for unattended runs / CI: never prompt for the
    # target list, just use -Target (or the host default). Mirrors the other -No* flags.
    [switch]$NoTargetPrompt
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ------------------------------------------------------------------------------
# Console encoding  (RU strings + claude prints emit UTF-8; PS 5.1 defaults to
# the OEM codepage and would mojibake them). Force UTF-8 in + out + pipeline.
# ------------------------------------------------------------------------------
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$OutputEncoding = [System.Text.Encoding]::UTF8
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# Where we live, where the repo root and its siblings are.
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path        # builders/windows
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path      # claude-on-a-stick/
$SharedDir = Join-Path $RepoRoot 'shared'
$PayloadDir = Join-Path $RepoRoot 'payload'

# Official download host (CONTRACTS.md sec. 8, VERIFIED).
$ManifestHost = 'https://downloads.claude.ai/claude-code-releases'

# ==============================================================================
#  Tiny UI helpers, usable even before i18n is ready / a shared module loads.
# ==============================================================================
function Write-Step { param([string]$m) Write-Host ''; Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok { param([string]$m) Write-Host "[OK] $m" -ForegroundColor Green }
function Write-Warn2 { param([string]$m) Write-Host "[!]  $m" -ForegroundColor Yellow }
function Write-ErrLine { param([string]$m) Write-Host "[X]  $m" -ForegroundColor Red }
function Die { param([string]$m) Write-ErrLine $m; exit 1 }

# Resolve a sibling module's path if it exists, else $null.
# (Modules are robust standalone and define their own T() fallback, so a missing
#  one is only fatal when the builder actually needs its functions - we check
#  the concrete function names later and Die with a precise message then.)
#
# NOTE: the actual dot-source MUST happen at the script's top level (not inside a
# helper function). Dot-sourcing with `. $p` *inside* a function injects the
# module's functions into that function's LOCAL scope, so they vanish the moment
# the helper returns - they would NOT be visible to the rest of the builder. So
# this returns the path and the caller does `. $path` at script scope.
function Resolve-Shared {
    param([Parameter(Mandatory)][string]$File)
    $p = Join-Path $SharedDir $File
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    return $p
}

# ==============================================================================
#  0)  I18N  -  prefer shared/i18n.ps1 (T accessor + Set-Lang). It is not yet a
#      committed file in every checkout, and each shared module ships its own
#      English T() fallback, so build.ps1 carries a self-contained RU/EN map and
#      installs T()/Set-Lang ONLY if i18n.ps1 didn't already provide them. This
#      keeps the builder first-class and runnable standalone (CONTRACTS.md sec 9).
# ==============================================================================
$i18nPath = Resolve-Shared 'i18n.ps1'
$i18nLoaded = [bool]$i18nPath
if ($i18nPath) { . $i18nPath }   # dot-source at script scope (functions stay visible)

if (-not (Get-Command -Name 'T' -ErrorAction SilentlyContinue) -or
    -not (Get-Command -Name 'Set-Lang' -ErrorAction SilentlyContinue)) {

    # ----- built-in message map (msg[lang][key]) -----
    $script:Lang = 'en'
    $script:CasMsg = @{
        en = @{
            welcome              = 'Claude on a Stick - build a portable, no-install Claude Code USB.'
            welcome_sub          = 'Repo ships logic only; binaries + your token are fetched/entered now and land on the stick.'
            # ---- MULTI-OS STICK target selection (one stick, any OS) ----
            step_target          = 'Choosing target platform(s)'
            target_one_stick     = 'MULTI-OS: one stick can launch Claude on Windows, Linux AND macOS from the same encrypted token.'
            target_host_default  = 'Default = this host only: {0}'
            target_menu          = 'Enter a comma-separated list of platforms, A = all common (win32-x64,linux-x64,darwin-arm64), or blank for the default.'
            target_choices       = '  win32-x64  win32-arm64  linux-x64  linux-arm64  linux-x64-musl  linux-arm64-musl  darwin-x64  darwin-arm64'
            target_prompt        = 'Targets [{0}]'
            target_bad           = 'Unknown platform id (ignored): {0}'
            target_none          = 'No valid target platform selected - aborting.'
            target_selected      = 'Building for: {0}'
            step_download_multi  = 'Downloading + verifying {0} platform binary/binaries'
            dl_for_plat          = '-- {0} --'
            dl_into              = 'Placed bin\{0}\{1}'
            step_elev            = 'Checking privileges'
            elev_ok              = 'Running as Administrator.'
            elev_need            = 'Administrator is required to format a USB disk.'
            elev_how             = 'Right-click PowerShell -> Run as administrator, then re-run build.ps1.'
            elev_warn_noformat   = 'Not elevated; -NoFormat set - continuing, but disk operations would fail.'
            step_usb             = 'Selecting and formatting the USB stick'
            usb_pick_aborted     = 'No stick selected / format aborted. Nothing was changed.'
            usb_noformat_ask     = 'Enter the EXISTING CLAUDE stick drive letter (e.g. E)'
            usb_noformat_bad     = 'That drive does not exist.'
            usb_ready            = 'Stick ready at {0}'
            step_download        = 'Downloading the Claude Code binary'
            dl_plat              = 'Platform {0}, channel {1}.'
            dl_version           = 'Resolved version {0}.'
            dl_badver            = 'Unexpected version string from the manifest host: {0}'
            dl_noplat            = 'Platform {0} not present in the {1} manifest.'
            dl_gpg_ok            = 'GPG manifest signature verified.'
            dl_gpg_fail          = 'GPG manifest signature did NOT verify (continuing; checksum still enforced).'
            dl_gpg_skip          = 'GPG verify skipped (signature unavailable).'
            dl_gpg_absent        = 'gpg not found - skipping signature check (best-effort per spec).'
            dl_fetching          = 'Fetching {0}'
            dl_size_mismatch     = 'Size mismatch: got {0} bytes, manifest says {1}. Continuing to checksum.'
            dl_sum_mismatch      = 'SHA-256 MISMATCH. Got {0}, expected {1}. Aborting (deleted the download).'
            dl_verified          = 'claude.exe {0} verified (sha256 {1}...).'
            step_token           = 'Provisioning the auth token (claude setup-token)'
            token_explain        = 'This logs in your Claude subscription and mints a long-lived, inference-only token.'
            token_login_hint     = 'A browser window will open for the OAuth login; paste the code back if asked.'
            token_choice_prompt  = 'How do you want to provide your Claude token?'
            token_choice_paste   = '  [1] Paste an existing token (you already have an sk-ant-oat… token)'
            token_choice_new     = "  [2] Get a new one now - opens your browser via 'claude setup-token'"
            token_choice_ask     = 'Choice [1/2]'
            token_running        = 'Running: claude setup-token (config redirected onto the stick) ...'
            token_cmd_failed     = 'claude setup-token exited with code {0}.'
            token_not_captured   = 'Could not auto-capture the token from setup-token output.'
            token_cross          = 'Cross-platform build: cannot run the target binary here - paste the token manually.'
            token_paste          = 'Paste your Claude OAuth token'
            token_empty          = 'No token obtained - aborting.'
            token_setpw          = 'Set a Stick password (used to encrypt the token)'
            token_setpw2         = 'Repeat the Stick password'
            token_pw_short       = 'Use at least 6 characters.'
            token_pw_diff        = 'Passwords do not match.'
            token_encrypting     = 'Encrypting the token to config\oauth.enc (AES-256, PBKDF2-SHA1 300k) ...'
            token_enc_failed     = 'Failed to write config\oauth.enc.'
            token_encrypted      = 'Token encrypted -> {0}'
            step_happ            = 'Optional VPN (Happ)'
            happ_skipped_flag    = 'Happ skipped (-NoHapp).'
            happ_ask             = 'Bundle the Happ VPN onto the stick? [y/N]'
            happ_installed       = 'Happ installed (portable) -> {0}'
            happ_sub_ask         = 'Paste your subscription link (raw URL or happ://...) - blank to skip'
            happ_sub_ok          = 'Subscription imported into Happ.'
            happ_sub_manual      = 'Could not verify the import; the deep-link was printed above for manual import.'
            happ_sub_none        = 'No subscription entered - you can add one in Happ later.'
            happ_none            = 'No VPN bundled - relying on the host/system VPN (geo-guard still governs).'
            happ_failed          = 'Happ setup failed: {0}'
            happ_failed_hint     = 'Continuing without a bundled VPN; you can re-run the builder to add it.'
            step_payload         = 'Writing geo-guard + launchers onto the stick'
            geo_written          = 'geoguard.conf written (BLOCKLIST=RU,BY,CU,IR,KP,SY, INCONCLUSIVE=prompt).'
            payload_missing_dir  = 'Payload templates not found at {0} - cannot lay down the launchers.'
            payload_missing_file = 'Payload file missing (skipped): {0}'
            payload_copied       = 'Copied + templated {0} of {1} launcher files.'
            step_selftest        = 'Self-test'
            selftest_version     = 'claude --version off the stick: {0}'
            selftest_version_fail= 'claude --version did not return cleanly.'
            selftest_version_err = 'claude --version error: {0}'
            selftest_decrypt     = 'Verifying the encrypted token round-trips (re-enter the Stick password) ...'
            selftest_decrypt_ok  = 'Token decrypts correctly with that password.'
            selftest_decrypt_fail= 'Token did NOT decrypt - the password you just typed may differ from the build one.'
            selftest_decrypt_err = 'Decrypt self-test error: {0}'
            selftest_decrypt_skip= 'Decrypt self-test skipped (decrypt.ps1 or oauth.enc missing).'
            done                 = 'BUILD COMPLETE. Portable Claude Code is on {0}'
            done_run             = 'On the target PC: open {0} and double-click START.bat.'
            done_run_posix       = 'On Linux/macOS: open a terminal in {0} and run ./start.sh.'
            done_targets         = 'Platforms baked onto the stick: {0}'
            done_safety          = 'Token-only encryption protects the auth token; for client PII use whole-volume encryption (BitLocker To Go / VeraCrypt).'
            # ---- keys emitted by shared/usb.ps1 (localized here; the module ships English-only) ----
            usb_scanning         = 'Scanning for removable USB disks...'
            usb_none             = 'No removable USB disks found. Plug one in and retry.'
            usb_list_header      = 'Removable USB disks detected:'
            usb_pick_prompt      = "Enter the NUMBER of the disk to use (or 'q' to abort)"
            usb_bad_pick         = 'Invalid choice.'
            usb_aborted          = 'Aborted by user. Nothing was changed.'
            usb_selected         = 'Selected:'
            usb_warn_erase       = 'WARNING: ALL DATA on this device will be PERMANENTLY ERASED.'
            usb_confirm_prompt   = 'Type ERASE and the device id exactly to confirm'
            usb_confirm_mismatch = 'Confirmation did not match. Aborting (nothing erased).'
            usb_need_admin       = 'Formatting needs Administrator. Re-run PowerShell elevated.'
            usb_no_storagecmd    = 'Storage cmdlets not available (Get-Disk/Clear-Disk). Needs Windows 8+/Server 2012+.'
            usb_formatting       = 'Formatting (this destroys everything on the device)...'
            usb_clearing         = 'Clearing the disk (Clear-Disk -RemoveData)...'
            usb_initmbr          = 'Initializing MBR partition table...'
            usb_part             = 'Creating one partition (max size, assigning drive letter)...'
            usb_mkfs             = 'Creating exFAT filesystem labelled'
            usb_done             = 'Done. The stick is formatted and ready.'
            usb_fail             = 'Format FAILED.'
            usb_internal_skipped = '(internal/system disks are never shown)'
            # ---- dotted keys emitted by shared/usb.ps1 (it uses usb.* / fmt.*,
            #      and passes -f args, so these must exist AND T() must format) ----
            'usb.scanning'       = 'Scanning for removable USB disks...'
            'usb.none_found'     = 'No removable USB disk found. Plug one in and re-run.'
            'usb.list_header'    = 'Detected removable disks (internal disks are NEVER offered):'
            'usb.row'            = '  {0})  {1}   size={2}   model={3}'
            'usb.choose'         = "Type the number of the target disk (or 'q' to quit): "
            'usb.bad_choice'     = 'Not a valid choice. Try again.'
            'usb.is_hdd_warn'    = "Note: a USB HDD also shows as a USB disk. Make ABSOLUTELY sure '{0}' is the stick you want to erase."
            'usb.warn_title'     = '!!! DESTRUCTIVE ACTION - READ CAREFULLY !!!'
            'usb.warn_body'      = 'ALL data on {0} ({1}, {2}) will be PERMANENTLY ERASED. This cannot be undone.'
            'usb.erase_prompt'   = 'To confirm, type ERASE {0} exactly (anything else cancels): '
            'usb.erase_mismatch' = 'Confirmation did not match. Nothing was erased.'
            'fmt.start'          = 'Formatting {0} ... (MBR, single exFAT partition type 0x07, label CLAUDE)'
            'fmt.clear'          = '  - Clearing the disk (Clear-Disk)...'
            'fmt.parttable'      = '  - Initializing MBR partition table...'
            'fmt.partition'      = '  - Creating one partition...'
            'fmt.mkfs'           = '  - Formatting exFAT (label CLAUDE)...'
            'fmt.done'           = 'Format complete. Stick is drive {0}.'
            'fmt.need_admin'     = 'Formatting needs Administrator. Re-run this builder elevated (Run as administrator).'
            # ---- keys emitted by shared/happ.ps1 ----
            happ_api_fail        = 'Could not reach the Happ release API.'
            happ_downloading     = 'Downloading'
            happ_dl_fail         = 'Happ download failed:'
            happ_installing      = 'Installing Happ silently (portable, no admin)...'
            happ_install_warn    = 'Happ installer returned a non-zero exit'
            happ_portable_ok     = 'Happ portable-ized'
            happ_bin_notfound    = 'Happ.exe not found in the installed tree.'
            happ_runner_written  = 'run-happ.bat written:'
            happ_starting        = 'Starting the portable Happ instance...'
            happ_inserting_sub   = 'Forwarding the subscription deep-link to Happ...'
            happ_sub_unverified  = 'Could not confirm the subscription import.'
            happ_manual_hint     = 'Import this deep-link manually in Happ once:'
        }
        ru = @{
            welcome              = 'Claude on a Stick - сборка портативной USB-флешки с Claude Code без установки.'
            welcome_sub          = 'В репозитории только логика; бинарники и ваш токен скачиваются/вводятся сейчас и ложатся на флешку.'
            # ---- MULTI-OS: выбор целевых платформ (одна флешка - любая ОС) ----
            step_target          = 'Выбор целевой платформы (платформ)'
            target_one_stick     = 'MULTI-OS: одна флешка запускает Claude на Windows, Linux И macOS из одного зашифрованного токена.'
            target_host_default  = 'По умолчанию = только этот хост: {0}'
            target_menu          = 'Введите список платформ через запятую, A = все основные (win32-x64,linux-x64,darwin-arm64) или пусто для значения по умолчанию.'
            target_choices       = '  win32-x64  win32-arm64  linux-x64  linux-arm64  linux-x64-musl  linux-arm64-musl  darwin-x64  darwin-arm64'
            target_prompt        = 'Платформы [{0}]'
            target_bad           = 'Неизвестный идентификатор платформы (пропущен): {0}'
            target_none          = 'Не выбрано ни одной корректной платформы - прерывание.'
            target_selected      = 'Сборка для: {0}'
            step_download_multi  = 'Загрузка и проверка бинарников: {0} шт.'
            dl_for_plat          = '-- {0} --'
            dl_into              = 'Размещено bin\{0}\{1}'
            step_elev            = 'Проверка прав'
            elev_ok              = 'Запущено от имени администратора.'
            elev_need            = 'Для форматирования USB-диска нужны права администратора.'
            elev_how             = 'ПКМ по PowerShell -> «Запуск от имени администратора», затем снова запустите build.ps1.'
            elev_warn_noformat   = 'Без прав администратора; задан -NoFormat - продолжаем, но операции с диском не сработают.'
            step_usb             = 'Выбор и форматирование USB-флешки'
            usb_pick_aborted     = 'Флешка не выбрана / форматирование отменено. Ничего не изменено.'
            usb_noformat_ask     = 'Введите букву диска уже готовой флешки CLAUDE (например, E)'
            usb_noformat_bad     = 'Такого диска нет.'
            usb_ready            = 'Флешка готова: {0}'
            step_download        = 'Загрузка бинарника Claude Code'
            dl_plat              = 'Платформа {0}, канал {1}.'
            dl_version           = 'Определена версия {0}.'
            dl_badver            = 'Неожиданная строка версии от хоста манифеста: {0}'
            dl_noplat            = 'Платформа {0} отсутствует в манифесте {1}.'
            dl_gpg_ok            = 'GPG-подпись манифеста проверена.'
            dl_gpg_fail          = 'GPG-подпись манифеста НЕ прошла проверку (продолжаем; контрольная сумма всё равно проверяется).'
            dl_gpg_skip          = 'Проверка GPG пропущена (подпись недоступна).'
            dl_gpg_absent        = 'gpg не найден - пропускаем проверку подписи (по спецификации - best-effort).'
            dl_fetching          = 'Скачивание {0}'
            dl_size_mismatch     = 'Несовпадение размера: получено {0} байт, в манифесте {1}. Переходим к контрольной сумме.'
            dl_sum_mismatch      = 'НЕ совпала SHA-256. Получено {0}, ожидалось {1}. Прерывание (загрузка удалена).'
            dl_verified          = 'claude.exe {0} проверен (sha256 {1}...).'
            step_token           = 'Подготовка токена аутентификации (claude setup-token)'
            token_explain        = 'Это вход в вашу подписку Claude и выпуск долгоживущего токена только для инференса.'
            token_login_hint     = 'Откроется окно браузера для входа OAuth; при запросе вставьте код обратно.'
            token_choice_prompt  = 'Как передать токен Claude?'
            token_choice_paste   = '  [1] Вставить готовый токен (у вас уже есть sk-ant-oat…)'
            token_choice_new     = "  [2] Получить новый сейчас - откроется браузер ('claude setup-token')"
            token_choice_ask     = 'Выбор [1/2]'
            token_running        = 'Выполняется: claude setup-token (конфиг перенаправлен на флешку) ...'
            token_cmd_failed     = 'claude setup-token завершился с кодом {0}.'
            token_not_captured   = 'Не удалось автоматически извлечь токен из вывода setup-token.'
            token_cross          = 'Сборка под другую платформу: целевой бинарник здесь не запустить - вставьте токен вручную.'
            token_paste          = 'Вставьте ваш OAuth-токен Claude'
            token_empty          = 'Токен не получен - прерывание.'
            token_setpw          = 'Задайте пароль флешки (им шифруется токен)'
            token_setpw2         = 'Повторите пароль флешки'
            token_pw_short       = 'Используйте не менее 6 символов.'
            token_pw_diff        = 'Пароли не совпадают.'
            token_encrypting     = 'Шифрование токена в config\oauth.enc (AES-256, PBKDF2-SHA1 300k) ...'
            token_enc_failed     = 'Не удалось записать config\oauth.enc.'
            token_encrypted      = 'Токен зашифрован -> {0}'
            step_happ            = 'Опциональный VPN (Happ)'
            happ_skipped_flag    = 'Happ пропущен (-NoHapp).'
            happ_ask             = 'Положить VPN Happ на флешку? [y/N]'
            happ_installed       = 'Happ установлен (портативно) -> {0}'
            happ_sub_ask         = 'Вставьте ссылку подписки (сырой URL или happ://...) - пусто, чтобы пропустить'
            happ_sub_ok          = 'Подписка импортирована в Happ.'
            happ_sub_manual      = 'Не удалось подтвердить импорт; ссылка выведена выше для ручного добавления.'
            happ_sub_none        = 'Подписка не введена - можно добавить её в Happ позже.'
            happ_none            = 'VPN не добавлен - полагаемся на системный VPN (гео-страж всё равно действует).'
            happ_failed          = 'Не удалось настроить Happ: {0}'
            happ_failed_hint     = 'Продолжаем без встроенного VPN; добавить можно повторным запуском сборщика.'
            step_payload         = 'Запись гео-стража и лаунчеров на флешку'
            geo_written          = 'geoguard.conf записан (BLOCKLIST=RU,BY,CU,IR,KP,SY, INCONCLUSIVE=prompt).'
            payload_missing_dir  = 'Шаблоны payload не найдены в {0} - не могу записать лаунчеры.'
            payload_missing_file = 'Файл payload отсутствует (пропущен): {0}'
            payload_copied       = 'Скопировано и шаблонизировано {0} из {1} файлов лаунчера.'
            step_selftest        = 'Самопроверка'
            selftest_version     = 'claude --version с флешки: {0}'
            selftest_version_fail= 'claude --version вернул не штатно.'
            selftest_version_err = 'Ошибка claude --version: {0}'
            selftest_decrypt     = 'Проверка обратимости шифрования токена (введите пароль флешки ещё раз) ...'
            selftest_decrypt_ok  = 'Токен корректно расшифрован этим паролем.'
            selftest_decrypt_fail= 'Токен НЕ расшифровался - возможно, введённый пароль отличается от заданного при сборке.'
            selftest_decrypt_err = 'Ошибка самопроверки расшифровки: {0}'
            selftest_decrypt_skip= 'Самопроверка расшифровки пропущена (нет decrypt.ps1 или oauth.enc).'
            done                 = 'СБОРКА ЗАВЕРШЕНА. Портативный Claude Code на {0}'
            done_run             = 'На целевом ПК: откройте {0} и дважды щёлкните START.bat.'
            done_run_posix       = 'На Linux/macOS: откройте терминал в {0} и запустите ./start.sh.'
            done_targets         = 'Платформы, записанные на флешку: {0}'
            done_safety          = 'Шифрование «только токен» защищает токен; для клиентских ПДн используйте шифрование всего тома (BitLocker To Go / VeraCrypt).'
            # ---- ключи, которые печатает shared/usb.ps1 (локализованы здесь; в модуле только английский) ----
            usb_scanning         = 'Поиск съёмных USB-дисков...'
            usb_none             = 'Съёмные USB-диски не найдены. Вставьте флешку и повторите.'
            usb_list_header      = 'Обнаружены съёмные USB-диски:'
            usb_pick_prompt      = 'Введите НОМЕР нужного диска (или «q» для отмены)'
            usb_bad_pick         = 'Неверный выбор.'
            usb_aborted          = 'Отменено пользователем. Ничего не изменено.'
            usb_selected         = 'Выбрано:'
            usb_warn_erase       = 'ВНИМАНИЕ: ВСЕ ДАННЫЕ на этом устройстве будут БЕЗВОЗВРАТНО СТЁРТЫ.'
            usb_confirm_prompt   = 'Для подтверждения введите ERASE и идентификатор устройства в точности'
            usb_confirm_mismatch = 'Подтверждение не совпало. Отмена (ничего не стёрто).'
            usb_need_admin       = 'Для форматирования нужны права администратора. Перезапустите PowerShell с повышением.'
            usb_no_storagecmd    = 'Командлеты хранилища недоступны (Get-Disk/Clear-Disk). Нужна Windows 8+/Server 2012+.'
            usb_formatting       = 'Форматирование (это уничтожит всё на устройстве)...'
            usb_clearing         = 'Очистка диска (Clear-Disk -RemoveData)...'
            usb_initmbr          = 'Инициализация таблицы разделов MBR...'
            usb_part             = 'Создание одного раздела (макс. размер, назначение буквы)...'
            usb_mkfs             = 'Создание файловой системы exFAT с меткой'
            usb_done             = 'Готово. Флешка отформатирована и готова.'
            usb_fail             = 'ОШИБКА форматирования.'
            usb_internal_skipped = '(внутренние/системные диски никогда не показываются)'
            # ---- точечные ключи из shared/usb.ps1 (usb.* / fmt.* + аргументы -f) ----
            'usb.scanning'       = 'Поиск съёмных USB-дисков...'
            'usb.none_found'     = 'Съёмные USB-диски не найдены. Вставьте флешку и повторите.'
            'usb.list_header'    = 'Обнаружены съёмные диски (внутренние диски НИКОГДА не предлагаются):'
            'usb.row'            = '  {0})  {1}   размер={2}   модель={3}'
            'usb.choose'         = 'Введите номер целевого диска (или «q» для выхода): '
            'usb.bad_choice'     = 'Неверный выбор. Повторите.'
            'usb.is_hdd_warn'    = 'Внимание: USB-HDD тоже отображается как USB-диск. УБЕДИТЕСЬ, что «{0}» - именно та флешка, которую нужно стереть.'
            'usb.warn_title'     = '!!! РАЗРУШИТЕЛЬНОЕ ДЕЙСТВИЕ - ЧИТАЙТЕ ВНИМАТЕЛЬНО !!!'
            'usb.warn_body'      = 'ВСЕ данные на {0} ({1}, {2}) будут БЕЗВОЗВРАТНО СТЁРТЫ. Отменить нельзя.'
            'usb.erase_prompt'   = 'Для подтверждения введите ERASE {0} в точности (иначе - отмена): '
            'usb.erase_mismatch' = 'Подтверждение не совпало. Ничего не стёрто.'
            'fmt.start'          = 'Форматирование {0} ... (MBR, один раздел exFAT типа 0x07, метка CLAUDE)'
            'fmt.clear'          = '  - Очистка диска (Clear-Disk)...'
            'fmt.parttable'      = '  - Инициализация таблицы разделов MBR...'
            'fmt.partition'      = '  - Создание одного раздела...'
            'fmt.mkfs'           = '  - Форматирование exFAT (метка CLAUDE)...'
            'fmt.done'           = 'Форматирование завершено. Флешка - диск {0}.'
            'fmt.need_admin'     = 'Для форматирования нужны права администратора. Перезапустите сборщик с повышением.'
            # ---- ключи, которые печатает shared/happ.ps1 ----
            happ_api_fail        = 'Не удалось обратиться к API релизов Happ.'
            happ_downloading     = 'Скачивание'
            happ_dl_fail         = 'Не удалось скачать Happ:'
            happ_installing      = 'Тихая установка Happ (портативно, без администратора)...'
            happ_install_warn    = 'Установщик Happ вернул ненулевой код'
            happ_portable_ok     = 'Happ сделан портативным'
            happ_bin_notfound    = 'Happ.exe не найден в установленном дереве.'
            happ_runner_written  = 'Записан run-happ.bat:'
            happ_starting        = 'Запуск портативного экземпляра Happ...'
            happ_inserting_sub   = 'Передача deep-link подписки в Happ...'
            happ_sub_unverified  = 'Не удалось подтвердить импорт подписки.'
            happ_manual_hint     = 'Импортируйте этот deep-link в Happ вручную один раз:'
        }
    }

    function Set-Lang {
        param([Parameter(Mandatory)][ValidateSet('ru', 'en')][string]$Code)
        $script:Lang = $Code
    }
    function T {
        # Accept the SAME contract as shared/i18n.ps1 + shared/usb.ps1's own T():
        # a key PLUS optional remaining args that fill {0} {1} ... via .NET -f.
        # The dot-sourced modules (usb.ps1 emits usb.* / fmt.* keys) call
        # `T 'usb.row' ($i+1) $id $size $model`; a single-$Key signature here made
        # those calls throw "A positional parameter cannot be found that accepts
        # argument '1'." and crashed the builder in the USB step (the prior crash
        # class). ValueFromRemainingArguments captures them so the call succeeds.
        param(
            [Parameter(Mandatory, Position = 0)][string]$Key,
            [Parameter(ValueFromRemainingArguments = $true)][object[]]$Rest
        )
        $tbl = $script:CasMsg[$script:Lang]
        $tmpl = $null
        if ($tbl -and $tbl.ContainsKey($Key)) { $tmpl = $tbl[$Key] }
        else {
            $en = $script:CasMsg['en']
            if ($en -and $en.ContainsKey($Key)) { $tmpl = $en[$Key] }
        }
        if ($null -eq $tmpl) { $tmpl = $Key }
        if ($null -ne $Rest -and $Rest.Count -gt 0) {
            try { return ($tmpl -f $Rest) } catch { return $tmpl }
        }
        return $tmpl
    }
}

# Decide the UI language (CONTRACTS.md sec 9: ask FIRST, default from culture).
if ($PSBoundParameters.ContainsKey('Lang') -and $Lang) {
    Set-Lang $Lang
}
else {
    $cultureLang = 'en'
    try { if ((Get-Culture).TwoLetterISOLanguageName -eq 'ru') { $cultureLang = 'ru' } } catch {}
    Set-Lang $cultureLang

    Write-Host ''
    Write-Host 'claude-on-a-stick  -  Windows builder' -ForegroundColor White
    Write-Host '  [E] English    [R] Russian / Русский' -ForegroundColor DarkGray
    $def = if ($cultureLang -eq 'ru') { 'R' } else { 'E' }
    $sel = Read-Host "Language / Язык [$def]"
    if ([string]::IsNullOrWhiteSpace($sel)) { $sel = $def }
    switch -Regex ($sel.Trim().ToUpper()) {
        '^R' { Set-Lang 'ru' }
        '^E' { Set-Lang 'en' }
        default { Set-Lang $cultureLang }
    }
}

# The chosen language string, baked into the launchers and passed to sub-modules.
$ChosenLang = if (Get-Variable -Name Lang -Scope Script -ErrorAction SilentlyContinue) { $script:Lang } else { 'en' }

Write-Host ''
Write-Host (T 'welcome') -ForegroundColor White
Write-Host (T 'welcome_sub') -ForegroundColor DarkGray

# Bring in the rest of the shared toolkit (they also define local T() fallbacks,
# but ours is already in scope, so they reuse it).
$usbPath = Resolve-Shared 'usb.ps1'
$usbLoaded = [bool]$usbPath
if ($usbPath) { . $usbPath }          # dot-source at script scope

$cryptoPath = Resolve-Shared 'crypto.ps1'
$cryptoLoaded = [bool]$cryptoPath
if ($cryptoPath) { . $cryptoPath }    # dot-source at script scope

$happPath = Resolve-Shared 'happ.ps1'
$happLoaded = [bool]$happPath
if ($happPath) { . $happPath }        # dot-source at script scope

# Verify the cross-module interface up front (fail fast with a precise message
# rather than half-formatting a stick and dying later on a missing function).
if (-not $usbLoaded -or -not (Get-Command Invoke-UsbSelectAndFormat -ErrorAction SilentlyContinue)) {
    Die "shared/usb.ps1 is missing or lacks Invoke-UsbSelectAndFormat. The repo is incomplete."
}
if (-not $cryptoLoaded -or -not (Get-Command Protect-CasToken -ErrorAction SilentlyContinue)) {
    Die "shared/crypto.ps1 is missing or lacks Protect-CasToken. The repo is incomplete."
}
# happ.ps1 is only required if the user opts into the VPN; checked at that step.

# ==============================================================================
#  0b) TARGET PLATFORM(S)  -  MULTI-OS STICK ("one stick, any OS").
#      Mirror of build.sh's multi-target step: choose ONE or MANY release
#      platforms in a single run. The destructive format + the encrypted token +
#      the shared config are still done exactly ONCE (later steps); only the
#      binary download + the launcher *union* fan out per selected platform.
#      Default (single-target) stays this host's win32 build, so existing
#      single-target runs are unchanged.  (CONTRACTS.md sec 8 + MULTI-OS delta)
# ==============================================================================

# Canonical list of release platform ids (CONTRACTS.md sec 8).
$AllPlatforms = @(
    'win32-x64', 'win32-arm64',
    'linux-x64', 'linux-arm64', 'linux-x64-musl', 'linux-arm64-musl',
    'darwin-x64', 'darwin-arm64'
)
# "A = all common" expands to one binary per OS family.
$CommonPlatforms = @('win32-x64', 'linux-x64', 'darwin-arm64')

# Detect THIS host's win32 platform id (the single-target default).
$hostArch = $env:PROCESSOR_ARCHITECTURE
$HostPlatform = if ($hostArch -match 'ARM64') { 'win32-arm64' } else { 'win32-x64' }

# Parse a raw target spec ("A", or a comma/space/semicolon list) into a validated,
# de-duplicated, order-preserving array. Unknown ids are warned + dropped.
function Resolve-Targets {
    param([string]$Spec)
    if ([string]::IsNullOrWhiteSpace($Spec)) { return @() }
    if ($Spec.Trim().ToUpper() -eq 'A') { return $CommonPlatforms }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($raw in ($Spec -split '[,;\s]+')) {
        $p = $raw.Trim().ToLower()
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if ($p -eq 'a') { foreach ($c in $CommonPlatforms) { if (-not $out.Contains($c)) { $out.Add($c) } }; continue }
        if ($AllPlatforms -contains $p) {
            if (-not $out.Contains($p)) { $out.Add($p) }
        }
        else {
            Write-Warn2 ((T 'target_bad') -f $p)
        }
    }
    return $out.ToArray()
}

Write-Step (T 'step_target')
Write-Host (T 'target_one_stick') -ForegroundColor DarkGray
Write-Host ((T 'target_host_default') -f $HostPlatform) -ForegroundColor DarkGray

# Build the working target set: explicit -Target wins; else prompt (unless
# -NoTargetPrompt); blank => host default (single-target, unchanged behaviour).
[string[]]$Targets = @()
if ($PSBoundParameters.ContainsKey('Target') -and -not [string]::IsNullOrWhiteSpace($Target)) {
    $Targets = Resolve-Targets $Target
}
elseif ($NoTargetPrompt) {
    $Targets = @($HostPlatform)
}
else {
    Write-Host (T 'target_menu') -ForegroundColor DarkGray
    Write-Host (T 'target_choices') -ForegroundColor DarkGray
    $sel = Read-Host ((T 'target_prompt') -f $HostPlatform)
    if ([string]::IsNullOrWhiteSpace($sel)) {
        $Targets = @($HostPlatform)
    }
    else {
        $Targets = Resolve-Targets $sel
    }
}

if (-not $Targets -or $Targets.Count -eq 0) {
    Die (T 'target_none')
}
$IsMultiTarget = ($Targets.Count -gt 1)
Write-Ok ((T 'target_selected') -f ($Targets -join ', '))

# Launcher-family flags drive the UNION copy later (MULTI-OS delta point 4):
#   any win32-*       -> copy the Windows launcher set
#   any linux/darwin  -> copy the POSIX launcher set
$NeedWinLaunchers = [bool]($Targets | Where-Object { $_ -like 'win32-*' })
$NeedPosixLaunchers = [bool]($Targets | Where-Object { $_ -like 'linux-*' -or $_ -like 'darwin-*' })

# ==============================================================================
#  1)  ELEVATION  -  formatting a physical disk needs admin on Windows.
# ==============================================================================
function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

Write-Step (T 'step_elev')
if (-not (Test-Admin)) {
    if ($NoFormat) {
        Write-Warn2 (T 'elev_warn_noformat')
    }
    else {
        Write-ErrLine (T 'elev_need')
        Write-Host (T 'elev_how') -ForegroundColor DarkGray
        exit 1
    }
}
else {
    Write-Ok (T 'elev_ok')
}

# ==============================================================================
#  2)  USB SELECT + CONFIRM + FORMAT exFAT   ->  shared/usb.ps1
#      Invoke-UsbSelectAndFormat does the whole guarded flow (enumerate USB-bus
#      disks only -> explicit numeric pick -> typed "ERASE Disk N" confirm ->
#      Clear-Disk + MBR + exFAT label CLAUDE) and returns the assigned drive
#      LETTER (e.g. 'E') on success, $null on any abort/failure. (CONTRACTS sec 10)
# ==============================================================================
Write-Step (T 'step_usb')

$driveLetter = $null
if ($NoFormat) {
    # Re-build onto an already-formatted CLAUDE stick: ask for its drive letter.
    while ($true) {
        $dl = (Read-Host (T 'usb_noformat_ask')).Trim().TrimEnd(':').ToUpper()
        if ($dl -match '^[A-Z]$' -and (Test-Path -LiteralPath ("${dl}:\"))) {
            $driveLetter = $dl
            break
        }
        Write-Warn2 (T 'usb_noformat_bad')
    }
}
else {
    $driveLetter = Invoke-UsbSelectAndFormat
}

if ([string]::IsNullOrWhiteSpace($driveLetter)) {
    Die (T 'usb_pick_aborted')
}

# Normalize to a trailing-separator root (matches the launchers' %~dp0 style: "X:\").
$StickRoot = ($driveLetter.TrimEnd(':')) + ':\'
if (-not (Test-Path -LiteralPath $StickRoot)) {
    Die (T 'usb_pick_aborted')
}
Write-Ok ((T 'usb_ready') -f $StickRoot)

# Create the on-stick skeleton (CONTRACTS.md sec. 2).
foreach ($sub in @('bin', 'config', 'projects', 'tmp', 'apps')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $StickRoot $sub) | Out-Null
}

# ==============================================================================
#  3)  DOWNLOAD claude binary/binaries + sha256-verify   (CONTRACTS.md sec. 8)
#      MULTI-OS: the SAME uniform layout is used for single AND multi builds:
#          bin/<platform>/claude       (posix)
#          bin/<platform>/claude.exe   (windows)
#      Each selected platform is resolved from the manifest, downloaded into its
#      own subdir and sha256-verified independently (abort on any mismatch). The
#      version + manifest + GPG check are fetched ONCE and reused for every plat.
# ==============================================================================
Write-Step ((T 'step_download_multi') -f $Targets.Count)
Write-Host ((T 'dl_plat') -f ($Targets -join ', '), $Channel) -ForegroundColor DarkGray

function Get-Text { param([string]$Url) return (Invoke-RestMethod -Uri $Url -TimeoutSec 30) }

# 3a. resolve bare semver from /<channel>  (ONCE).
$ver = "$([string](Get-Text "$ManifestHost/$Channel"))".Trim()
if ($ver -notmatch '^\d+\.\d+\.\d+') { Die ((T 'dl_badver') -f $ver) }
Write-Host ((T 'dl_version') -f $ver) -ForegroundColor DarkGray

# 3b. /<ver>/manifest.json  (ONCE).
$manifest = Get-Text "$ManifestHost/$ver/manifest.json"
# StrictMode-safe presence test: accessing an absent property (e.g. the platform
# key missing from the manifest) throws under Set-StrictMode -Version Latest, so
# probe the property names rather than reading the value to test for it.
$platforms = if ($manifest.PSObject.Properties.Name -contains 'platforms') { $manifest.platforms } else { $null }
if (-not $platforms) { Die ((T 'dl_noplat') -f ($Targets -join ', '), $ver) }

# 3c. (best-effort) GPG manifest signature verify, only if gpg is present (ONCE).
$gpg = Get-Command gpg -ErrorAction SilentlyContinue
if ($gpg) {
    try {
        $tmpMan = Join-Path $env:TEMP "cos-manifest-$ver.json"
        $tmpSig = "$tmpMan.sig"
        Invoke-WebRequest -Uri "$ManifestHost/$ver/manifest.json" -OutFile $tmpMan -UseBasicParsing -TimeoutSec 30
        Invoke-WebRequest -Uri "$ManifestHost/$ver/manifest.json.sig" -OutFile $tmpSig -UseBasicParsing -TimeoutSec 30
        & $gpg.Source --verify $tmpSig $tmpMan 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Ok (T 'dl_gpg_ok') } else { Write-Warn2 (T 'dl_gpg_fail') }
        Remove-Item -Force -ErrorAction SilentlyContinue $tmpMan, $tmpSig
    }
    catch { Write-Warn2 (T 'dl_gpg_skip') }
}
else {
    Write-Host (T 'dl_gpg_absent') -ForegroundColor DarkGray
}

# 3d. per-platform download + verify into bin/<plat>/claude(.exe).
$binRoot = Join-Path $StickRoot 'bin'
# Remember the host-runnable win32 binary path (for the setup-token step + self-test).
$hostBinDst = $null
foreach ($plat in $Targets) {
    Write-Host ((T 'dl_for_plat') -f $plat) -ForegroundColor White
    if (-not ($platforms.PSObject.Properties.Name -contains $plat)) {
        Die ((T 'dl_noplat') -f $plat, $ver)
    }
    $entry = $platforms.$plat
    $binName = $entry.binary          # "claude.exe" (win) / "claude" (else)
    $wantSum = ($entry.checksum).ToLower()
    $wantSize = if ($entry.PSObject.Properties.Name -contains 'size') { $entry.size } else { $null }

    # Uniform per-platform subdir. The on-stick file name follows the OS family.
    $platDir = Join-Path $binRoot $plat
    New-Item -ItemType Directory -Force -Path $platDir | Out-Null
    $localName = if ($plat -like 'win32-*') { 'claude.exe' } else { 'claude' }
    $binDst = Join-Path $platDir $localName

    $binUrl = "$ManifestHost/$ver/$plat/$binName"
    Write-Host ((T 'dl_fetching') -f $binUrl) -ForegroundColor DarkGray
    Invoke-WebRequest -Uri $binUrl -OutFile $binDst -UseBasicParsing -TimeoutSec 600

    $gotSize = (Get-Item -LiteralPath $binDst).Length
    if ($wantSize -and ($gotSize -ne $wantSize)) {
        Write-Warn2 ((T 'dl_size_mismatch') -f $gotSize, $wantSize)
    }
    $gotSum = (Get-FileHash -LiteralPath $binDst -Algorithm SHA256).Hash.ToLower()
    if ($gotSum -ne $wantSum) {
        Remove-Item -Force -ErrorAction SilentlyContinue $binDst
        Die ((T 'dl_sum_mismatch') -f $gotSum, $wantSum)
    }
    Write-Ok ((T 'dl_verified') -f $ver, $gotSum.Substring(0, 16))
    Write-Ok ((T 'dl_into') -f $plat, $localName)

    # The host can run a win32 binary matching its own arch -> use it for the
    # interactive setup-token + the --version self-test below.
    if ($plat -eq $HostPlatform) { $hostBinDst = $binDst }
}

# ==============================================================================
#  4)  AUTH TOKEN  ->  `claude setup-token`  ->  AES encrypt to config/oauth.enc
#      crypto.ps1 owns the exact byte-format: Protect-CasToken takes the PLAIN
#      token + the password + the out path and writes salt|iv|ct (PBKDF2-SHA1
#      300k, AES-256-CBC/PKCS7). So build.ps1 prompts + confirms the Stick
#      password here (masked) and hands it to Protect-CasToken. (CONTRACTS sec 4)
# ==============================================================================
Write-Step (T 'step_token')

Write-Host (T 'token_explain') -ForegroundColor DarkGray
Write-Host (T 'token_login_hint') -ForegroundColor DarkGray
Write-Host ''

# Offer an explicit choice for how to provide the token. Option [2] runs
# `claude setup-token` with the env pointed AT THE STICK so login state + the
# resulting token are produced in an isolated, on-stick home (host C: untouched -
# mirrors env.bat's CLAUDE_CONFIG_DIR / HOME redirection). It is only available
# when the target binary can run on THIS host (Windows builder -> win32 target,
# and the just-downloaded claude.exe is present).
$stickConfig = Join-Path $StickRoot 'config'
$tokenPlain = $null

# Helper: masked paste of an existing token (returned as plaintext string).
function Read-TokenPaste {
    param([string]$Prompt)
    $sec = Read-Host $Prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# host_runnable: this is a Windows host, so it can run a win32 binary whose arch
# matches the host. In a MULTI-OS build that win32 binary is only present if the
# host's platform was among the selected targets (-> $hostBinDst was set in the
# download loop). When cross-building (e.g. only linux/darwin targets) there is
# no runnable binary here, so we fall back to manual paste.
# StrictMode-safe: $IsWindows is an automatic var on PS 6+ but is UNSET on Windows
# PowerShell 5.1 (the primary target), where reading it throws under StrictMode -
# so probe via Get-Variable; absence means PS 5.1 == Windows == runnable.
$isWin = if (Get-Variable -Name IsWindows -Scope Global -ErrorAction SilentlyContinue) { $IsWindows } else { $true }
$hostRunnable = $isWin -and $hostBinDst -and (Test-Path -LiteralPath $hostBinDst)

# Print the menu and read the (non-sensitive) choice. Default to [2] when we can
# run setup-token here; force [1] when cross-building.
Write-Host (T 'token_choice_prompt') -ForegroundColor White
Write-Host (T 'token_choice_paste')  -ForegroundColor DarkGray
$choice = '1'
if ($hostRunnable) {
    Write-Host (T 'token_choice_new') -ForegroundColor DarkGray
    $sel = Read-Host (T 'token_choice_ask')
    if ([string]::IsNullOrWhiteSpace($sel)) { $sel = '2' }   # default [2]
    $choice = $sel.Trim()
}
else {
    Write-Host (T 'token_cross') -ForegroundColor DarkGray  # cross-build: paste only
}

if ($choice -eq '2') {
    $prevConfig = $env:CLAUDE_CONFIG_DIR
    $prevHome = $env:HOME
    $prevApiKey = $env:ANTHROPIC_API_KEY
    try {
        $env:CLAUDE_CONFIG_DIR = $stickConfig
        $env:HOME = $stickConfig
        $env:ANTHROPIC_API_KEY = ''   # never let a host key shadow the subscription token

        Write-Host (T 'token_running') -ForegroundColor DarkGray
        # setup-token is interactive (browser OAuth) and prints the long-lived
        # token to stdout on success. Capture stdout; pull the token-ish line.
        # Uses the host-matching win32 binary downloaded above ($hostBinDst).
        $tokenOut = & $hostBinDst 'setup-token' 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw ((T 'token_cmd_failed') -f $LASTEXITCODE) }
        foreach ($line in ($tokenOut -split "`r?`n")) {
            $l = $line.Trim()
            if ($l -match '^[A-Za-z0-9_\-\.]{24,}$') { $tokenPlain = $l }
        }
        if ([string]::IsNullOrWhiteSpace($tokenPlain)) { throw (T 'token_not_captured') }
    }
    catch {
        # setup-token failed or yielded nothing -> warn and fall through to paste.
        Write-Warn2 (T 'token_not_captured')
        $tokenPlain = $null
    }
    finally {
        # Restore the builder's own env regardless of outcome.
        $env:CLAUDE_CONFIG_DIR = $prevConfig
        $env:HOME = $prevHome
        $env:ANTHROPIC_API_KEY = $prevApiKey
    }
}

# Manual paste path: explicit choice [1], any other input, or a setup-token
# capture that failed / produced nothing.
if ([string]::IsNullOrWhiteSpace($tokenPlain)) {
    $tokenPlain = Read-TokenPaste (T 'token_paste')
}

if ([string]::IsNullOrWhiteSpace($tokenPlain)) { Die (T 'token_empty') }

# Prompt + confirm the Stick password (masked) - crypto.ps1 takes it as a param.
function Read-PlainSecret {
    param([string]$Prompt)
    $s = Read-Host $Prompt -AsSecureString
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

$pw = $null
while ($true) {
    $p1 = Read-PlainSecret (T 'token_setpw')
    if ($p1.Length -lt 6) { Write-Warn2 (T 'token_pw_short'); continue }
    $p2 = Read-PlainSecret (T 'token_setpw2')
    if ($p1 -ne $p2) { Write-Warn2 (T 'token_pw_diff'); continue }
    $pw = $p1
    break
}

$encPath = Join-Path $stickConfig 'oauth.enc'
Write-Host (T 'token_encrypting') -ForegroundColor DarkGray
Protect-CasToken -Plaintext $tokenPlain -Password $pw -OutPath $encPath

# Best-effort scrub of the plaintext token + password from memory.
$tokenPlain = $null; $pw = $null; $p1 = $null; $p2 = $null
[GC]::Collect()

if (-not (Test-Path -LiteralPath $encPath)) { Die (T 'token_enc_failed') }
Write-Ok ((T 'token_encrypted') -f $encPath)

# Seed the on-stick config that env.bat expects (NEVER write any plaintext token).
$settingsPath = Join-Path $stickConfig 'settings.json'
if (-not (Test-Path -LiteralPath $settingsPath)) {
    '{ "$schema": "https://json.schemastore.org/claude-code-settings.json" }' |
    Set-Content -LiteralPath $settingsPath -Encoding UTF8
}
$dotClaude = Join-Path $stickConfig '.claude.json'
if (-not (Test-Path -LiteralPath $dotClaude)) {
    '{}' | Set-Content -LiteralPath $dotClaude -Encoding UTF8
}

# ==============================================================================
#  5)  OPTIONAL HAPP VPN  ->  shared/happ.ps1
#      Get-Happ -Arch -OutDir       -> downloads setup-Happ.<arch>.exe, returns path
#      Install-HappPortable -Setup -Dst  -> silent Inno install into apps\happ
#      Write-HappRunner -Dst         -> apps\happ\run-happ.bat (APPDATA on stick)
#      Add-HappSubscription -Dst -Raw -> import the sub via happ:// deep-link
#      (CONTRACTS sec 6/7)
# ==============================================================================
Write-Step (T 'step_happ')

# MULTI-OS delta point 7: Happ binaries are OS-specific (~300MB each), so in a
# multi-target build VPN bundling is OPTIONAL and OFF by default - rely on the
# host/system VPN (geoguard's "no bundled Happ -> host VPN" fallback stays). The
# Windows happ.ps1 can only fetch the Windows installer, so it bundles ONLY the
# Windows Happ here; other OSes' Happ would be added by their own builder.
# Single-target (win32 only) keeps the verified apps\happ path unchanged; a
# multi-target build that opts in lands the Windows Happ under apps\happ-win32.
$wantHapp = $false
if ($NoHapp) {
    Write-Host (T 'happ_skipped_flag') -ForegroundColor DarkGray
}
elseif (-not $NeedWinLaunchers) {
    # No win32 target at all -> nothing the Windows happ.ps1 could bundle.
    Write-Host (T 'happ_none') -ForegroundColor DarkGray
}
else {
    $ans = Read-Host (T 'happ_ask')   # y/N  (default N, doubly so in multi-OS)
    $wantHapp = ($ans -match '^[YyДд]')
}

if ($wantHapp) {
    if (-not $happLoaded -or -not (Get-Command Install-HappPortable -ErrorAction SilentlyContinue)) {
        Write-Warn2 ((T 'happ_failed') -f 'shared/happ.ps1 missing or incomplete')
        Write-Host (T 'happ_failed_hint') -ForegroundColor DarkGray
    }
    else {
        # Single-target win32 build keeps the original apps\happ path (vpnup.bat
        # default). Multi-target build uses the per-OS apps\happ-win32 layout that
        # vpnup.bat resolves per running OS (delta point 7).
        $happLeaf = if ($IsMultiTarget) { 'happ-win32' } else { 'happ' }
        $happDst = Join-Path (Join-Path $StickRoot 'apps') $happLeaf
        $happArch = if ($hostArch -match 'ARM64') { 'arm64' } else { 'x64' }
        try {
            New-Item -ItemType Directory -Force -Path $happDst | Out-Null
            # Download the setup .exe into a temp dir, then silent-install onto the stick.
            $happTmp = Join-Path $env:TEMP 'cos-happ-dl'
            $setup = Get-Happ -Arch $happArch -OutDir $happTmp
            Install-HappPortable -Setup $setup -Dst $happDst | Out-Null
            Write-HappRunner -Dst $happDst | Out-Null
            Write-Ok ((T 'happ_installed') -f $happDst)

            # Subscription deep-link (raw URL -> happ://add/<urlenc>; happ://... verbatim).
            $sub = Read-Host (T 'happ_sub_ask')
            if (-not [string]::IsNullOrWhiteSpace($sub)) {
                $ok = Add-HappSubscription -Dst $happDst -Raw $sub.Trim()
                if ($ok) { Write-Ok (T 'happ_sub_ok') } else { Write-Warn2 (T 'happ_sub_manual') }
            }
            else {
                Write-Host (T 'happ_sub_none') -ForegroundColor DarkGray
            }
        }
        catch {
            Write-Warn2 ((T 'happ_failed') -f $_.Exception.Message)
            Write-Host (T 'happ_failed_hint') -ForegroundColor DarkGray
        }
    }
}
else {
    Write-Host (T 'happ_none') -ForegroundColor DarkGray
}

# ==============================================================================
#  6)  GEOGUARD CONF + PAYLOAD LAUNCHERS (templated) + SELF-TEST
# ==============================================================================
Write-Step (T 'step_payload')

if (-not (Test-Path -LiteralPath $PayloadDir)) {
    Die ((T 'payload_missing_dir') -f $PayloadDir)
}

# 6a. geoguard.conf  (CONTRACTS.md sec. 5 defaults). Prefer the repo template;
#     fall back to writing the canonical defaults if the payload file is absent.
$geoConfDst = Join-Path $StickRoot 'geoguard.conf'
$geoConfSrc = Join-Path $PayloadDir 'geoguard.conf'
if (Test-Path -LiteralPath $geoConfSrc) {
    Copy-Item -LiteralPath $geoConfSrc -Destination $geoConfDst -Force
}
else {
    @(
        '# claude-on-a-stick geo-guard (anti-ban). See CONTRACTS.md sec. 5.',
        'GUARD_ENABLED=1',
        'BLOCKLIST=RU,BY,CU,IR,KP,SY',
        'INCONCLUSIVE=prompt'
    ) -join "`r`n" | Set-Content -LiteralPath $geoConfDst -Encoding ascii
}
Write-Ok (T 'geo_written')

# 6b. Copy + TEMPLATE the payload launchers onto the stick root.
#     Tokens substituted in every copied file:
#         __MODEL__  -> the chosen model (default claude-opus-4-8)
#         __LANG__   -> ru|en  (bakes the launcher message language)
#     MULTI-OS delta point 4 - UNION launcher copy:
#         any win32-*       target -> copy the Windows launcher set
#         any linux/darwin  target -> copy the POSIX launcher set
#     geoguard.conf + README-STICK.txt are ALWAYS present (written/copied above
#     and below). NOTE: run-happ.{bat,sh} is NOT copied to the root - the happ
#     helper's runner writer drops it INTO apps\happ where the chain expects it.
$winPayload = @(
    'START.bat',
    'DIAG.bat',
    'env.bat',
    'vpnup.bat',
    'geoguard.bat',
    'geoguard.ps1',
    'decrypt.ps1'
)
$posixPayload = @(
    'start.sh',
    'diag.sh',
    'env.sh',
    'vpnup.sh',
    'geoguard.sh',
    'decrypt.sh'
)

# Write a templated copy of a payload file to $DestRoot. Returns $true if copied.
# Line endings + BOM are chosen by file type so each OS family gets correct files
# even when the build itself runs on Windows.
function Copy-Template {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$DestRoot
    )
    $src = Join-Path $PayloadDir $Name
    if (-not (Test-Path -LiteralPath $src)) {
        Write-Warn2 ((T 'payload_missing_file') -f $Name)
        return $false
    }
    $text = Get-Content -LiteralPath $src -Raw
    # Bake build-time choices into the launcher.
    $text = $text.Replace('__MODEL__', $Model).Replace('__LANG__', $ChosenLang)
    $dst = Join-Path $DestRoot $Name

    if ($Name -match '\.sh$') {
        # POSIX shell scripts: LF endings, NO BOM (a BOM or CRLF breaks the shebang
        # and `read`/`set` on Linux/macOS).
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($dst, ($text -replace "`r?`n", "`n"), $enc)
    }
    elseif ($Name -match '\.bat$') {
        # .bat must be plain UTF-8 / NO BOM (cmd.exe chokes on a UTF-8 BOM at the
        # top of a batch file; START.bat sets chcp 65001 itself). CRLF endings.
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($dst, ($text -replace "`r?`n", "`r`n"), $enc)
    }
    else {
        # .ps1 / .txt -> UTF-8 WITH BOM so PS 5.1 reads RU strings; CRLF endings.
        $enc = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($dst, ($text -replace "`r?`n", "`r`n"), $enc)
    }
    return $true
}

# Build the union file list once, so single-target stays identical to before.
$payloadFiles = New-Object System.Collections.Generic.List[string]
if ($NeedWinLaunchers) { foreach ($f in $winPayload) { $payloadFiles.Add($f) } }
if ($NeedPosixLaunchers) { foreach ($f in $posixPayload) { $payloadFiles.Add($f) } }
# README-STICK.txt is shared across all OSes (always copied).
$payloadFiles.Add('README-STICK.txt')

$copied = 0
foreach ($f in $payloadFiles) {
    if (Copy-Template -Name $f -DestRoot $StickRoot) { $copied++ }
}
Write-Ok ((T 'payload_copied') -f $copied, $payloadFiles.Count)

# 6c. SELF-TEST  -  prove the produced stick actually works end-to-end.
#     (1) claude --version straight off the stick (no token / proxy needed).
#     (2) decrypt round-trip via crypto.ps1 Unprotect-CasToken using the same
#         password the user enters now (re-typed so we never keep it in memory).
Write-Step (T 'step_selftest')

# (1) version - only when a host-runnable win32 binary is on the stick. In a
#     cross-build (e.g. only linux/darwin targets) there is nothing to exec here.
if ($hostBinDst -and (Test-Path -LiteralPath $hostBinDst)) {
    try {
        $verOut = & $hostBinDst '--version' 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0 -and $verOut.Trim()) {
            Write-Ok ((T 'selftest_version') -f $verOut.Trim())
        }
        else { Write-Warn2 (T 'selftest_version_fail') }
    }
    catch { Write-Warn2 ((T 'selftest_version_err') -f $_.Exception.Message) }
}
else {
    Write-Host (T 'token_cross') -ForegroundColor DarkGray
}

# (2) decrypt round-trip (crypto.ps1's own helper - same byte-format as the stick's
#     decrypt.ps1, but no subprocess needed). Re-prompt for the password.
if ((Get-Command Unprotect-CasToken -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $encPath)) {
    Write-Host (T 'selftest_decrypt') -ForegroundColor DarkGray
    try {
        $verifyPw = Read-PlainSecret (T 'token_setpw')
        $back = Unprotect-CasToken -InPath $encPath -Password $verifyPw
        $verifyPw = $null
        if (-not [string]::IsNullOrWhiteSpace($back)) { Write-Ok (T 'selftest_decrypt_ok') }
        else { Write-Warn2 (T 'selftest_decrypt_fail') }
        $back = $null
    }
    catch {
        # Wrong password surfaces as a CryptographicException (bad padding).
        Write-Warn2 (T 'selftest_decrypt_fail')
    }
}
else {
    Write-Warn2 (T 'selftest_decrypt_skip')
}

# ------------------------------------------------------------------------------
#  DONE
# ------------------------------------------------------------------------------
Write-Host ''
Write-Host '============================================================' -ForegroundColor Green
Write-Ok ((T 'done') -f $StickRoot)
Write-Host ((T 'done_targets') -f ($Targets -join ', ')) -ForegroundColor White
if ($NeedWinLaunchers) { Write-Host ((T 'done_run') -f $StickRoot) -ForegroundColor White }
if ($NeedPosixLaunchers) { Write-Host ((T 'done_run_posix') -f $StickRoot) -ForegroundColor White }
Write-Host (T 'done_safety') -ForegroundColor DarkGray
Write-Host '============================================================' -ForegroundColor Green
exit 0
