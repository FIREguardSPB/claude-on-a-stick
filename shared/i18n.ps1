# =============================================================================
# claude-on-a-stick - i18n (RU/EN) for the Windows builder (builders\windows\build.ps1)
# and for the templated stick launchers / decrypt.ps1 / geoguard.ps1 that dot-source it.
#
# Per CONTRACTS.md section 9:
#   - ONE nested message map  $Msg[lang][key]  with an accessor  T key  (PowerShell).
#   - Ask language FIRST (default from Get-Culture; single keypress to override).
#   - ALL user-facing strings go through T(); technical tokens
#     (claude, Happ, flags, env names, paths) stay UNTRANSLATED.
#   - Save THIS FILE as UTF-8 WITH BOM so PowerShell 5.1 reads the Cyrillic
#     correctly; the script also forces UTF-8 console output below.
#
# Design: $Msg is a hashtable of hashtables -> $Msg['en'] and $Msg['ru'], each a
#         flat key->string table. T looks up $Msg[$Lang][$key], falls back to
#         English, then to a loud <<key>> sentinel. Placeholders {0} {1} ... are
#         filled positionally from T()'s remaining args via -f, with technical
#         tokens passed IN as args so strings never hard-code paths/flags.
#
# Usage:
#   . "$PSScriptRoot\..\shared\i18n.ps1"     # dot-source
#   Invoke-PickLanguage                       # interactive (sets $script:Lang), or:
#   $script:Lang = 'ru'                       # set directly (skip the prompt)
#   T 'lang.prompt'
#   T 'usb.confirm' 'PhysicalDrive2' '57.6 GB' 'SanDisk Ultra'
# =============================================================================

# Make the console emit UTF-8 so Cyrillic renders on PS 5.1 (CONTRACTS section 9).
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding           = [System.Text.Encoding]::UTF8
} catch {
    # Non-fatal: some hosts (ISE) disallow setting this; messages still work.
}

# $script:Lang - active language, 'en' or 'ru'. Default decided in Invoke-PickLanguage.
# StrictMode-safe: reading a never-set $script:Lang throws under
# Set-StrictMode -Version Latest, so probe for existence via Get-Variable first.
if (-not (Get-Variable -Scope Script -Name Lang -ErrorAction SilentlyContinue)) { $script:Lang = 'en' }

# -----------------------------------------------------------------------------
# Nested message map: $Msg[lang][key]
# -----------------------------------------------------------------------------
$script:Msg = @{

    # ============================ ENGLISH (primary) =========================
    'en' = @{

        # --- language prompt ----------------------------------------------
        'lang.prompt' = 'Select language / Выберите язык:  [E]nglish (default) / [R]usский - press E or R: '
        'lang.set'    = 'Language: English.'

        # --- generic / banner ---------------------------------------------
        'app.banner'        = 'claude-on-a-stick - portable Claude Code builder'
        'app.tagline'       = 'Turns a USB stick into a no-install, portable Claude Code environment.'
        'common.yes'        = 'yes'
        'common.no'         = 'no'
        'common.ok'         = 'OK'
        'common.skip'       = 'skip'
        'common.press_enter'= 'Press Enter to continue...'
        'common.aborted'    = 'Aborted. Nothing was changed.'
        'common.step'       = '[Step {0}/{1}] {2}'

        # --- USB selection / warnings / ERASE confirm ---------------------
        'usb.scanning'      = 'Scanning for removable USB disks...'
        'usb.none_found'    = 'No removable USB disk found. Plug one in and re-run.'
        'usb.list_header'   = 'Detected removable disks (internal disks are NEVER offered):'
        'usb.row'           = '  {0})  {1}   size={2}   model={3}'
        'usb.choose'        = "Type the number of the target disk (or 'q' to quit): "
        'usb.bad_choice'    = 'Not a valid choice. Try again.'
        'usb.is_hdd_warn'   = "Note: a USB HDD also shows as a USB disk. Make ABSOLUTELY sure '{0}' is the stick you want to erase."
        'usb.warn_title'    = '!!! DESTRUCTIVE ACTION - READ CAREFULLY !!!'
        'usb.warn_body'     = 'ALL data on {0} ({1}, {2}) will be PERMANENTLY ERASED. This cannot be undone.'
        'usb.erase_prompt'  = 'To confirm, type ERASE {0} exactly (anything else cancels): '
        'usb.erase_mismatch'= 'Confirmation did not match. Nothing was erased.'

        # --- format progress ----------------------------------------------
        'fmt.start'             = 'Formatting {0} ... (MBR, single exFAT partition type 0x07, label CLAUDE)'
        'fmt.clear'             = '  - Clearing the disk (Clear-Disk)...'
        'fmt.parttable'         = '  - Initializing MBR partition table...'
        'fmt.partition'         = '  - Creating one partition...'
        'fmt.mkfs'              = '  - Formatting exFAT (label CLAUDE)...'
        'fmt.done'              = 'Format complete. Stick is drive {0}.'
        'fmt.need_admin'        = 'Formatting needs Administrator. Re-run this builder elevated (Run as administrator).'

        # --- Claude binary download / verify ------------------------------
        'dl.channel_prompt' = 'Release channel - [S]table (default) or [L]atest? '
        'dl.platform'       = 'Target platform for the binary: {0}'
        'dl.resolving'      = 'Resolving {0} version from {1}...'
        'dl.resolved'       = 'Resolved version: {0}'
        'dl.manifest'       = 'Fetching manifest for {0}...'
        'dl.downloading'    = 'Downloading claude binary ({0})...'
        'dl.verifying'      = 'Verifying SHA-256 checksum...'
        'dl.verify_ok'      = 'Checksum OK.'
        'dl.verify_fail'    = 'CHECKSUM MISMATCH - download corrupted or tampered. Aborting.'
        'dl.gpg_checking'   = 'gpg present - verifying manifest signature (best-effort)...'
        'dl.gpg_ok'         = 'Manifest signature verified.'
        'dl.gpg_skip'       = 'gpg not present - skipping manifest signature check (best-effort only).'
        'dl.gpg_warn'       = 'Manifest signature could NOT be verified. Continue anyway? [y/N]: '
        'dl.placed'         = 'Placed binary at {0}.'
        'dl.net_fail'       = 'Network error while contacting {0}. Check connectivity and re-run.'

        # --- setup-token instructions -------------------------------------
        'token_choice_prompt' = 'How do you want to provide your Claude token?'
        'token_choice_paste'  = '  [1] Paste an existing token (you already have an sk-ant-oat… token)'
        'token_choice_new'    = "  [2] Get a new one now - opens your browser via 'claude setup-token'"
        'token_choice_ask'    = 'Choice [1/2]'
        'token.intro'  = 'Now we need YOUR long-lived Claude auth token (inference-only).'
        'token.howto'  = 'In a separate terminal where you are logged in, run:  claude setup-token'
        'token.howto2' = 'It prints a long-lived OAuth token. Copy the whole token.'
        'token.paste'  = 'Paste the token here (input hidden), then press Enter: '
        'token.empty'  = 'No token entered. The stick will not be able to authenticate. Try again.'
        'token.note'   = 'The token is stored ONLY as AES-encrypted config\oauth.enc on the stick - never in git, never in plaintext.'

        # --- stick password set / confirm ---------------------------------
        'pw.intro'      = 'Choose a STICK PASSWORD. It encrypts the token at rest (AES-256-CBC, PBKDF2-HMAC-SHA1 300000).'
        'pw.set'        = 'Set stick password (input hidden): '
        'pw.confirm'    = 'Confirm stick password: '
        'pw.mismatch'   = 'Passwords do not match. Try again.'
        'pw.empty'      = 'Empty password is not allowed. Try again.'
        'pw.weak'       = 'That password is very short. Use a longer one? [Y/n]: '
        'pw.encrypting' = 'Encrypting token -> config\oauth.enc ...'
        'pw.enc_done'   = 'Token encrypted and written to config\oauth.enc.'

        # --- stick launcher: password UNLOCK (decrypt at run time) ---------
        'unlock.prompt' = 'Stick password: '
        'unlock.fail'   = 'Wrong password or corrupted token. Cannot unlock.'
        'unlock.ok'     = 'Token unlocked.'

        # --- Happ / VPN optional + subscription paste ---------------------
        'happ.offer'        = 'Bundle the Happ VPN on the stick? (optional, for restricted regions) [y/N]: '
        'happ.skip'         = 'Skipping Happ. The stick will rely on the host / system VPN. Geo-guard still applies.'
        'happ.downloading'  = 'Downloading Happ desktop for {0}...'
        'happ.portableize'  = 'Making Happ portable (redirecting its config onto the stick)...'
        'happ.sub_intro'    = 'Paste your subscription. Accepted: a raw sub URL, or a ready happ://crypt5/... link.'
        'happ.sub_paste'    = 'Subscription (raw URL or happ://...), or leave empty to add it later: '
        'happ.sub_empty'    = 'No subscription entered. You can import it later inside Happ.'
        'happ.sub_inserting'= 'Inserting subscription into Happ (deep link)...'
        'happ.sub_ok'       = 'Subscription imported (verified via Happ config).'
        'happ.sub_manual'   = 'Could not auto-import. On first run, import this link manually inside Happ:'
        'happ.autoconnect'  = "Tip: enable Happ 'auto-connect on launch' so the stick brings the VPN up by itself."
        'happ.win_vcredist' = 'Note: if a bare Windows PC errors on msvcp140.dll, bundle the VC++ redist DLLs.'

        # --- stick launcher: VPN bring-up ---------------------------------
        'vpn.none'     = 'No bundled Happ on this stick - relying on host/system VPN.'
        'vpn.starting' = 'Starting Happ (proxy mode)...'
        'vpn.probing'  = 'Probing for the Happ proxy port (10808,10809,2080,1080,10800,8080)...'
        'vpn.up'       = 'VPN proxy is up on 127.0.0.1:{0}. Routing Claude through it.'
        'vpn.timeout'  = "Happ proxy did not come up in time. Enable Happ and 'auto-connect', then retry."

        # --- geo-guard config + run-time decisions ------------------------
        'guard.intro'               = 'Geo-guard (anti-ban) prevents launching from a blocked exit country.'
        'guard.enable'              = 'Enable geo-guard on the stick? [Y/n]: '
        'guard.blocklist'           = 'Blocked countries (comma-separated, default {0}): '
        'guard.inconclusive'        = 'If country detection fails - [P]rompt (default) / [B]lock / [A]llow? '
        'guard.disabled_note'       = 'Geo-guard disabled - the stick will launch without a country check.'
        'guard.checking'            = 'Geo-guard: checking exit country (direct)...'
        'guard.country'             = 'Geo-guard: exit country = {0}.'
        'guard.allowed'             = 'Geo-guard: {0} is not blocked - launching directly (VPN left untouched).'
        'guard.blocked_try_vpn'     = 'Geo-guard: {0} is blocked - bringing up the VPN and re-checking through the proxy...'
        'guard.blocked_via_vpn'     = 'Geo-guard: exit via proxy = {0}.'
        'guard.refuse'              = 'Geo-guard: exit country {0} is blocked and no usable VPN exit is available. Refusing to launch.'
        'guard.inconclusive_prompt' = 'Geo-guard: could not determine exit country. Continue anyway? [y/N]: '
        'guard.inconclusive_block'  = 'Geo-guard: could not determine exit country and policy=block. Refusing to launch.'
        'guard.disabled_runtime'    = 'Geo-guard disabled (GUARD_ENABLED=0) - skipping country check.'

        # --- done summary --------------------------------------------------
        'done.title'        = 'Done - your portable Claude stick is ready.'
        'done.mount'        = 'Stick: {0}'
        'done.howrun_posix' = 'On Linux/macOS:  open the stick and run  ./start.sh'
        'done.howrun_win'   = 'On Windows:      open the stick and double-click  START.bat'
        'done.model'        = 'Default model baked into the launcher: {0}'
        'done.vpn_yes'      = 'Happ VPN: bundled.'
        'done.vpn_no'       = 'Happ VPN: not bundled (relies on host/system VPN).'
        'done.guard'        = 'Geo-guard: {0}  (blocklist: {1})'
        'done.security'     = 'Reminder: stick contents are plaintext under token-only encryption. For client PII use whole-volume encryption (BitLocker To Go / VeraCrypt / LUKS). See docs\SECURITY.md.'
        'done.eject'        = 'Safely eject the stick before unplugging.'

        # --- errors (generic) ---------------------------------------------
        'err.generic'           = 'Error: {0}'
        'err.need_tool'         = 'Required tool not found: {0}. Install it and re-run.'
        'err.no_internet'       = 'No internet connection detected. A build needs to download the binary.'
        'err.write_fail'        = 'Could not write to {0}. Check that the stick is mounted and writable.'
        'err.unsupported_os'    = 'Unsupported OS for this builder: {0}.'
        'err.macos_experimental'= 'NOTE: macOS support is EXPERIMENTAL/best-effort (built without a Mac to verify). Manual fallbacks may be required.'
    }

    # ============================== RUSSIAN ================================
    'ru' = @{

        # --- language prompt ----------------------------------------------
        'lang.prompt' = 'Select language / Выберите язык:  [E]nglish / [R]usский (по умолчанию) - нажмите E или R: '
        'lang.set'    = 'Язык: русский.'

        # --- generic / banner ---------------------------------------------
        'app.banner'        = 'claude-on-a-stick - сборщик переносимого Claude Code'
        'app.tagline'       = 'Превращает USB-флешку в переносимое окружение Claude Code без установки.'
        'common.yes'        = 'да'
        'common.no'         = 'нет'
        'common.ok'         = 'ОК'
        'common.skip'       = 'пропустить'
        'common.press_enter'= 'Нажмите Enter для продолжения...'
        'common.aborted'    = 'Прервано. Ничего не изменено.'
        'common.step'       = '[Шаг {0}/{1}] {2}'

        # --- USB selection / warnings / ERASE confirm ---------------------
        'usb.scanning'      = 'Поиск съёмных USB-дисков...'
        'usb.none_found'    = 'Съёмный USB-диск не найден. Подключите флешку и запустите снова.'
        'usb.list_header'   = 'Найденные съёмные диски (внутренние диски НИКОГДА не предлагаются):'
        'usb.row'           = '  {0})  {1}   размер={2}   модель={3}'
        'usb.choose'        = "Введите номер целевого диска (или 'q' для выхода): "
        'usb.bad_choice'    = 'Неверный выбор. Попробуйте ещё раз.'
        'usb.is_hdd_warn'   = "Внимание: USB-HDD тоже отображается как USB-диск. Убедитесь АБСОЛЮТНО точно, что '{0}' - это именно та флешка, которую нужно стереть."
        'usb.warn_title'    = '!!! РАЗРУШИТЕЛЬНОЕ ДЕЙСТВИЕ - ЧИТАЙТЕ ВНИМАТЕЛЬНО !!!'
        'usb.warn_body'     = 'ВСЕ данные на {0} ({1}, {2}) будут БЕЗВОЗВРАТНО СТЁРТЫ. Отменить это будет невозможно.'
        'usb.erase_prompt'  = 'Для подтверждения введите в точности  ERASE {0}  (любой другой ввод отменяет): '
        'usb.erase_mismatch'= 'Подтверждение не совпало. Ничего не стёрто.'

        # --- format progress ----------------------------------------------
        'fmt.start'             = 'Форматирование {0} ... (MBR, один раздел exFAT тип 0x07, метка CLAUDE)'
        'fmt.clear'             = '  - Очищаю диск (Clear-Disk)...'
        'fmt.parttable'         = '  - Инициализирую таблицу разделов MBR...'
        'fmt.partition'         = '  - Создаю один раздел...'
        'fmt.mkfs'              = '  - Форматирую в exFAT (метка CLAUDE)...'
        'fmt.done'              = 'Форматирование завершено. Флешка - диск {0}.'
        'fmt.need_admin'        = 'Для форматирования нужны права администратора. Перезапустите сборщик с повышением (Запуск от имени администратора).'

        # --- Claude binary download / verify ------------------------------
        'dl.channel_prompt' = 'Канал выпуска - [S]table (по умолчанию) или [L]atest? '
        'dl.platform'       = 'Целевая платформа бинарника: {0}'
        'dl.resolving'      = 'Определяю версию {0} с {1}...'
        'dl.resolved'       = 'Определена версия: {0}'
        'dl.manifest'       = 'Загружаю манифест для {0}...'
        'dl.downloading'    = 'Скачиваю бинарник claude ({0})...'
        'dl.verifying'      = 'Проверяю контрольную сумму SHA-256...'
        'dl.verify_ok'      = 'Контрольная сумма верна.'
        'dl.verify_fail'    = 'НЕСОВПАДЕНИЕ КОНТРОЛЬНОЙ СУММЫ - файл повреждён или подменён. Прерываю.'
        'dl.gpg_checking'   = 'gpg найден - проверяю подпись манифеста (по возможности)...'
        'dl.gpg_ok'         = 'Подпись манифеста проверена.'
        'dl.gpg_skip'       = 'gpg не найден - пропускаю проверку подписи манифеста (только по возможности).'
        'dl.gpg_warn'       = 'Подпись манифеста проверить НЕ удалось. Продолжить всё равно? [y/N]: '
        'dl.placed'         = 'Бинарник размещён в {0}.'
        'dl.net_fail'       = 'Сетевая ошибка при обращении к {0}. Проверьте соединение и запустите снова.'

        # --- setup-token instructions -------------------------------------
        'token_choice_prompt' = 'Как передать токен Claude?'
        'token_choice_paste'  = '  [1] Вставить готовый токен (у вас уже есть sk-ant-oat…)'
        'token_choice_new'    = "  [2] Получить новый сейчас - откроется браузер ('claude setup-token')"
        'token_choice_ask'    = 'Выбор [1/2]'
        'token.intro'  = 'Теперь нужен ВАШ долгоживущий токен Claude (только для инференса).'
        'token.howto'  = 'В отдельном терминале, где вы авторизованы, выполните:  claude setup-token'
        'token.howto2' = 'Он напечатает долгоживущий OAuth-токен. Скопируйте токен целиком.'
        'token.paste'  = 'Вставьте токен сюда (ввод скрыт), затем нажмите Enter: '
        'token.empty'  = 'Токен не введён. Без него флешка не сможет авторизоваться. Попробуйте снова.'
        'token.note'   = 'Токен хранится ТОЛЬКО как зашифрованный AES-файл config\oauth.enc на флешке - никогда в git и никогда в открытом виде.'

        # --- stick password set / confirm ---------------------------------
        'pw.intro'      = 'Задайте ПАРОЛЬ ФЛЕШКИ. Он шифрует токен на диске (AES-256-CBC, PBKDF2-HMAC-SHA1 300000).'
        'pw.set'        = 'Задайте пароль флешки (ввод скрыт): '
        'pw.confirm'    = 'Подтвердите пароль флешки: '
        'pw.mismatch'   = 'Пароли не совпадают. Попробуйте снова.'
        'pw.empty'      = 'Пустой пароль недопустим. Попробуйте снова.'
        'pw.weak'       = 'Этот пароль очень короткий. Использовать подлиннее? [Y/n]: '
        'pw.encrypting' = 'Шифрую токен -> config\oauth.enc ...'
        'pw.enc_done'   = 'Токен зашифрован и записан в config\oauth.enc.'

        # --- stick launcher: password UNLOCK (decrypt at run time) ---------
        'unlock.prompt' = 'Пароль флешки: '
        'unlock.fail'   = 'Неверный пароль или повреждённый токен. Разблокировать не удалось.'
        'unlock.ok'     = 'Токен разблокирован.'

        # --- Happ / VPN optional + subscription paste ---------------------
        'happ.offer'        = 'Добавить на флешку VPN Happ? (необязательно, для регионов с ограничениями) [y/N]: '
        'happ.skip'         = 'Happ пропущен. Флешка будет полагаться на VPN хоста/системы. Гео-защита всё равно действует.'
        'happ.downloading'  = 'Скачиваю Happ desktop для {0}...'
        'happ.portableize'  = 'Делаю Happ переносимым (перенаправляю его конфиг на флешку)...'
        'happ.sub_intro'    = 'Вставьте подписку. Принимается: «сырой» URL подписки или готовая ссылка happ://crypt5/...'
        'happ.sub_paste'    = 'Подписка («сырой» URL или happ://...), или оставьте пустым, чтобы добавить позже: '
        'happ.sub_empty'    = 'Подписка не введена. Её можно импортировать позже внутри Happ.'
        'happ.sub_inserting'= 'Вставляю подписку в Happ (deep link)...'
        'happ.sub_ok'       = 'Подписка импортирована (проверено по конфигу Happ).'
        'happ.sub_manual'   = 'Автоимпорт не удался. При первом запуске импортируйте эту ссылку вручную в Happ:'
        'happ.autoconnect'  = 'Совет: включите в Happ «автоподключение при запуске», чтобы флешка поднимала VPN сама.'
        'happ.win_vcredist' = 'Примечание: если «голый» Windows-ПК ругается на msvcp140.dll, добавьте в комплект DLL из VC++ redist.'

        # --- stick launcher: VPN bring-up ---------------------------------
        'vpn.none'     = 'На этой флешке нет встроенного Happ - полагаюсь на VPN хоста/системы.'
        'vpn.starting' = 'Запускаю Happ (режим прокси)...'
        'vpn.probing'  = 'Ищу порт прокси Happ (10808,10809,2080,1080,10800,8080)...'
        'vpn.up'       = 'Прокси VPN поднят на 127.0.0.1:{0}. Направляю Claude через него.'
        'vpn.timeout'  = 'Прокси Happ не поднялся вовремя. Включите Happ и «автоподключение», затем повторите.'

        # --- geo-guard config + run-time decisions ------------------------
        'guard.intro'               = 'Гео-защита (анти-бан) не даёт запуститься из заблокированной страны выхода.'
        'guard.enable'              = 'Включить гео-защиту на флешке? [Y/n]: '
        'guard.blocklist'           = 'Заблокированные страны (через запятую, по умолчанию {0}): '
        'guard.inconclusive'        = 'Если определить страну не удалось - [P] спросить (по умолчанию) / [B] блокировать / [A] разрешить? '
        'guard.disabled_note'       = 'Гео-защита отключена - флешка запустится без проверки страны.'
        'guard.checking'            = 'Гео-защита: проверяю страну выхода (напрямую)...'
        'guard.country'             = 'Гео-защита: страна выхода = {0}.'
        'guard.allowed'             = 'Гео-защита: {0} не заблокирована - запускаю напрямую (VPN не трогаю).'
        'guard.blocked_try_vpn'     = 'Гео-защита: {0} заблокирована - поднимаю VPN и перепроверяю через прокси...'
        'guard.blocked_via_vpn'     = 'Гео-защита: выход через прокси = {0}.'
        'guard.refuse'              = 'Гео-защита: страна выхода {0} заблокирована, рабочего выхода через VPN нет. Запуск отклонён.'
        'guard.inconclusive_prompt' = 'Гео-защита: не удалось определить страну выхода. Продолжить всё равно? [y/N]: '
        'guard.inconclusive_block'  = 'Гео-защита: страну выхода определить не удалось, политика=block. Запуск отклонён.'
        'guard.disabled_runtime'    = 'Гео-защита отключена (GUARD_ENABLED=0) - пропускаю проверку страны.'

        # --- done summary --------------------------------------------------
        'done.title'        = 'Готово - ваша переносимая флешка с Claude собрана.'
        'done.mount'        = 'Флешка: {0}'
        'done.howrun_posix' = 'На Linux/macOS:  откройте флешку и запустите  ./start.sh'
        'done.howrun_win'   = 'На Windows:      откройте флешку и дважды щёлкните  START.bat'
        'done.model'        = 'Модель по умолчанию, зашитая в лаунчер: {0}'
        'done.vpn_yes'      = 'VPN Happ: в комплекте.'
        'done.vpn_no'       = 'VPN Happ: не в комплекте (полагается на VPN хоста/системы).'
        'done.guard'        = 'Гео-защита: {0}  (список блокировки: {1})'
        'done.security'     = 'Напоминание: содержимое флешки лежит в открытом виде под шифрованием только токена. Для клиентских ПДн используйте шифрование всего тома (BitLocker To Go / VeraCrypt / LUKS). См. docs\SECURITY.md.'
        'done.eject'        = 'Безопасно извлеките флешку перед отключением.'

        # --- errors (generic) ---------------------------------------------
        'err.generic'           = 'Ошибка: {0}'
        'err.need_tool'         = 'Не найден необходимый инструмент: {0}. Установите его и запустите снова.'
        'err.no_internet'       = 'Интернет-соединение не обнаружено. Для сборки нужно скачать бинарник.'
        'err.write_fail'        = 'Не удалось записать в {0}. Проверьте, что флешка примонтирована и доступна для записи.'
        'err.unsupported_os'    = 'Этот сборщик не поддерживает ОС: {0}.'
        'err.macos_experimental'= 'ВНИМАНИЕ: поддержка macOS - ЭКСПЕРИМЕНТАЛЬНАЯ/по возможности (собрано без проверки на Mac). Могут потребоваться ручные обходные пути.'
    }
}

# -----------------------------------------------------------------------------
# T <key> [args...]   - accessor.
#   Looks up $Msg[$script:Lang][$key]; falls back to English; then to a loud
#   <<key>> sentinel so a missing string is visible but never throws.
#   Placeholders {0} {1} ... are filled positionally with -f. Returns a STRING
#   (no implicit newline); callers use Write-Host (adds newline) or Write-Host
#   -NoNewline for inline prompts.
# -----------------------------------------------------------------------------
function T {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $Key,
        [Parameter(ValueFromRemainingArguments = $true)]
        [object[]] $Args
    )

    $lang = $script:Lang
    $tmpl = $null

    if ($script:Msg.ContainsKey($lang) -and $script:Msg[$lang].ContainsKey($Key)) {
        $tmpl = $script:Msg[$lang][$Key]
    }
    elseif ($script:Msg['en'].ContainsKey($Key)) {
        $tmpl = $script:Msg['en'][$Key]      # English fallback
    }
    else {
        return "<<$Key>>"                     # last-resort: show the missing key
    }

    if ($null -ne $Args -and $Args.Count -gt 0) {
        # -f handles {0} {1} ...; technical tokens are passed in as args so the
        # strings themselves stay free of paths/flags. Guard against a malformed
        # format string (e.g. stray { }) so the launcher never dies on output.
        try   { return ($tmpl -f $Args) }
        catch { return $tmpl }
    }
    return $tmpl
}

# Convenience: write a translated line (Write-Host adds the trailing newline).
function Write-T { param([string]$Key) Write-Host (T $Key @($args)) }

# -----------------------------------------------------------------------------
# Invoke-PickLanguage - ask language FIRST (CONTRACTS section 9).
#   Default from Get-Culture (ru* -> ru, else en). A single keypress (E/R)
#   overrides; Enter keeps the default. Sets $script:Lang. Bilingual prompt
#   because the language is not known yet.
# -----------------------------------------------------------------------------
function Invoke-PickLanguage {
    # Default from the host culture.
    try {
        if ((Get-Culture).Name -like 'ru*') { $script:Lang = 'ru' } else { $script:Lang = 'en' }
    } catch {
        $script:Lang = 'en'
    }

    $prompt = "Select language / Выберите язык:  [E]nglish / [R]usский - E/R (Enter=$($script:Lang)): "
    Write-Host $prompt -NoNewline

    # Read a single key without requiring Enter. Fall back to Read-Host when no
    # interactive key host is available (e.g. piped input / some CI hosts).
    $choice = ''
    try {
        $k = [Console]::ReadKey($true)
        Write-Host ''   # move to next line after the silent keypress
        $choice = "$($k.KeyChar)"
    } catch {
        $choice = Read-Host
    }

    switch -Regex ($choice) {
        '^[eE]' { $script:Lang = 'en' }
        '^[rR]' { $script:Lang = 'ru' }
        default { }   # Enter / anything else -> keep the culture default
    }

    Write-Host (T 'lang.set')
}
