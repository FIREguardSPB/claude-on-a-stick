# shellcheck shell=bash
# ----------------------------------------------------------------------------
# claude-on-a-stick — i18n (RU/EN) for the POSIX builder (builders/posix/build.sh)
# and for the templated stick launchers that source it.
#
# Per CONTRACTS.md §9:
#   - ONE message map  msg[lang][key]  with an accessor  t key  (bash).
#   - Ask language FIRST (default from $LANG; single keypress to override).
#   - ALL user-facing strings go through t(); technical tokens
#     (claude, Happ, flags, env names, paths) stay UNTRANSLATED.
#   - Bash 4+ assoc arrays are required. macOS /bin/bash is 3.2 (no assoc
#     arrays) → either re-exec under Homebrew bash 4+, OR fall back to the
#     case()-based t() implementation provided at the bottom of this file.
#
# Design: keys are FLAT and namespaced as "lang.key", e.g. "en.usb.erase".
#         declare -A MSG holds every string; t() looks up "${I18N_LANG}.$1".
#         Placeholders {0} {1} … are substituted positionally from t()'s
#         remaining args. Untranslated tokens are passed in as args so the
#         strings themselves never hard-code paths/flags.
#
# Usage:
#   source "shared/i18n.sh"
#   i18n_pick_language          # interactive (sets I18N_LANG), or:
#   I18N_LANG=ru                # set directly (skip the prompt)
#   t lang.prompt
#   t usb.confirm "/dev/sdb" "57.6 GB" "SanDisk Ultra"
# ----------------------------------------------------------------------------

# I18N_LANG: active language, "en" or "ru". Default decided in i18n_pick_language.
: "${I18N_LANG:=en}"

# ----------------------------------------------------------------------------
# Bash-4 path: a single associative array with "lang.key" entries.
# (If this `declare -A` fails — Bash 3.2 on stock macOS — we shadow t() with a
#  case-based fallback further down. The builder also tries to re-exec under a
#  Homebrew bash 4+ first; this is the belt-and-braces second line of defence.)
# ----------------------------------------------------------------------------
declare -A MSG 2>/dev/null

if declare -A _I18N_PROBE 2>/dev/null; then
  unset _I18N_PROBE
  I18N_HAVE_ASSOC=1
else
  I18N_HAVE_ASSOC=0
fi

# Only populate the assoc array when we actually have Bash 4+. On 3.2 the array
# does not exist and we rely on the case-based t() override at the bottom.
if [ "$I18N_HAVE_ASSOC" = "1" ]; then

# ============================ ENGLISH (primary) =============================

# --- language prompt -------------------------------------------------------
MSG[en.lang.prompt]="Select language / Выберите язык:  [E]nglish (default) / [R]usский — press E or R: "
MSG[en.lang.set]="Language: English."

# --- generic / banner ------------------------------------------------------
MSG[en.app.banner]="claude-on-a-stick — portable Claude Code builder"
MSG[en.app.tagline]="Turns a USB stick into a no-install, portable Claude Code environment."
MSG[en.common.yes]="yes"
MSG[en.common.no]="no"
MSG[en.common.ok]="OK"
MSG[en.common.skip]="skip"
MSG[en.common.press_enter]="Press Enter to continue…"
MSG[en.common.aborted]="Aborted. Nothing was changed."
MSG[en.common.step]="[Step {0}/{1}] {2}"

# --- USB selection / warnings / ERASE confirm ------------------------------
MSG[en.usb.scanning]="Scanning for removable USB disks…"
MSG[en.usb.none_found]="No removable USB disk found. Plug one in and re-run."
MSG[en.usb.list_header]="Detected removable disks (internal disks are NEVER offered):"
MSG[en.usb.row]="  {0})  {1}   size={2}   model={3}"
MSG[en.usb.choose]="Type the number of the target disk (or 'q' to quit): "
MSG[en.usb.bad_choice]="Not a valid choice. Try again."
MSG[en.usb.is_hdd_warn]="Note: a USB HDD also shows as a USB disk. Make ABSOLUTELY sure '{0}' is the stick you want to erase."
MSG[en.usb.warn_title]="!!! DESTRUCTIVE ACTION — READ CAREFULLY !!!"
MSG[en.usb.warn_body]="ALL data on {0} ({1}, {2}) will be PERMANENTLY ERASED. This cannot be undone."
MSG[en.usb.erase_prompt]="To confirm, type ERASE {0} exactly (anything else cancels): "
MSG[en.usb.erase_mismatch]="Confirmation did not match. Nothing was erased."

# --- format progress -------------------------------------------------------
MSG[en.fmt.start]="Formatting {0} … (MBR, single exFAT partition type 0x07, label CLAUDE)"
MSG[en.fmt.wipe]="  • Wiping existing signatures (wipefs)…"
MSG[en.fmt.parttable]="  • Writing MBR partition table…"
MSG[en.fmt.partition]="  • Creating one partition (type 0x07)…"
MSG[en.fmt.mkfs]="  • Creating exFAT filesystem (label CLAUDE)…"
MSG[en.fmt.done]="Format complete. Stick mounted at {0}."
MSG[en.fmt.need_root]="Formatting needs root. Re-run with sudo, or grant passwordless sudo."
MSG[en.fmt.need_exfatprogs]="exfatprogs not found (need mkfs.exfat). Install exfatprogs and re-run."
MSG[en.fmt.need_parttool]="Neither sfdisk nor parted found. Install util-linux/fdisk or parted and re-run."

# --- Claude binary download / verify ---------------------------------------
MSG[en.dl.channel_prompt]="Release channel — [S]table (default) or [L]atest? "
MSG[en.dl.platform]="Target platform for the binary: {0}"
MSG[en.dl.resolving]="Resolving {0} version from {1}…"
MSG[en.dl.resolved]="Resolved version: {0}"
MSG[en.dl.manifest]="Fetching manifest for {0}…"
MSG[en.dl.downloading]="Downloading claude binary ({0})…"
MSG[en.dl.verifying]="Verifying SHA-256 checksum…"
MSG[en.dl.verify_ok]="Checksum OK."
MSG[en.dl.verify_fail]="CHECKSUM MISMATCH — download corrupted or tampered. Aborting."
MSG[en.dl.gpg_checking]="gpg present — verifying manifest signature (best-effort)…"
MSG[en.dl.gpg_ok]="Manifest signature verified."
MSG[en.dl.gpg_skip]="gpg not present — skipping manifest signature check (best-effort only)."
MSG[en.dl.gpg_warn]="Manifest signature could NOT be verified. Continue anyway? [y/N]: "
MSG[en.dl.placed]="Placed binary at {0}."
MSG[en.dl.net_fail]="Network error while contacting {0}. Check connectivity and re-run."

# --- setup-token instructions ----------------------------------------------
MSG[en.token.intro]="Now we need YOUR long-lived Claude auth token (inference-only)."
MSG[en.token.howto]="In a separate terminal where you are logged in, run:  claude setup-token"
MSG[en.token.howto2]="It prints a long-lived OAuth token. Copy the whole token."
MSG[en.token.paste]="Paste the token here (input hidden), then press Enter: "
MSG[en.token.empty]="No token entered. The stick will not be able to authenticate. Try again."
MSG[en.token.note]="The token is stored ONLY as AES-encrypted config/oauth.enc on the stick — never in git, never in plaintext."

# --- stick password set / confirm ------------------------------------------
MSG[en.pw.intro]="Choose a STICK PASSWORD. It encrypts the token at rest (AES-256-CBC, PBKDF2-HMAC-SHA1 300000)."
MSG[en.pw.set]="Set stick password (input hidden): "
MSG[en.pw.confirm]="Confirm stick password: "
MSG[en.pw.mismatch]="Passwords do not match. Try again."
MSG[en.pw.empty]="Empty password is not allowed. Try again."
MSG[en.pw.weak]="That password is very short. Use a longer one? [Y/n]: "
MSG[en.pw.encrypting]="Encrypting token → config/oauth.enc …"
MSG[en.pw.enc_done]="Token encrypted and written to config/oauth.enc."

# --- stick launcher: password UNLOCK (decrypt at run time) ------------------
MSG[en.unlock.prompt]="Stick password: "
MSG[en.unlock.fail]="Wrong password or corrupted token. Cannot unlock."
MSG[en.unlock.ok]="Token unlocked."

# --- Happ / VPN optional + subscription paste ------------------------------
MSG[en.happ.offer]="Bundle the Happ VPN on the stick? (optional, for restricted regions) [y/N]: "
MSG[en.happ.skip]="Skipping Happ. The stick will rely on the host / system VPN. Geo-guard still applies."
MSG[en.happ.downloading]="Downloading Happ desktop for {0}…"
MSG[en.happ.portableize]="Making Happ portable (redirecting its config onto the stick)…"
MSG[en.happ.sub_intro]="Paste your subscription. Accepted: a raw sub URL, or a ready happ://crypt5/… link."
MSG[en.happ.sub_paste]="Subscription (raw URL or happ://…), or leave empty to add it later: "
MSG[en.happ.sub_empty]="No subscription entered. You can import it later inside Happ."
MSG[en.happ.sub_inserting]="Inserting subscription into Happ (deep link)…"
MSG[en.happ.sub_ok]="Subscription imported (verified via Happ config)."
MSG[en.happ.sub_manual]="Could not auto-import. On first run, import this link manually inside Happ:"
MSG[en.happ.autoconnect]="Tip: enable Happ 'auto-connect on launch' so the stick brings the VPN up by itself."
MSG[en.happ.win_vcredist]="Note: if a bare Windows PC errors on msvcp140.dll, bundle the VC++ redist DLLs."

# --- stick launcher: VPN bring-up ------------------------------------------
MSG[en.vpn.none]="No bundled Happ on this stick — relying on host/system VPN."
MSG[en.vpn.starting]="Starting Happ (proxy mode)…"
MSG[en.vpn.probing]="Probing for the Happ proxy port (10808,10809,2080,1080,10800,8080)…"
MSG[en.vpn.up]="VPN proxy is up on 127.0.0.1:{0}. Routing Claude through it."
MSG[en.vpn.timeout]="Happ proxy did not come up in time. Enable Happ and 'auto-connect', then retry."

# --- geo-guard config + run-time decisions ---------------------------------
MSG[en.guard.intro]="Geo-guard (anti-ban) prevents launching from a blocked exit country."
MSG[en.guard.enable]="Enable geo-guard on the stick? [Y/n]: "
MSG[en.guard.blocklist]="Blocked countries (comma-separated, default {0}): "
MSG[en.guard.inconclusive]="If country detection fails — [P]rompt (default) / [B]lock / [A]llow? "
MSG[en.guard.disabled_note]="Geo-guard disabled — the stick will launch without a country check."
MSG[en.guard.checking]="Geo-guard: checking exit country (direct)…"
MSG[en.guard.country]="Geo-guard: exit country = {0}."
MSG[en.guard.allowed]="Geo-guard: {0} is not blocked — launching directly (VPN left untouched)."
MSG[en.guard.blocked_try_vpn]="Geo-guard: {0} is blocked — bringing up the VPN and re-checking through the proxy…"
MSG[en.guard.blocked_via_vpn]="Geo-guard: exit via proxy = {0}."
MSG[en.guard.refuse]="Geo-guard: exit country {0} is blocked and no usable VPN exit is available. Refusing to launch."
MSG[en.guard.inconclusive_prompt]="Geo-guard: could not determine exit country. Continue anyway? [y/N]: "
MSG[en.guard.inconclusive_block]="Geo-guard: could not determine exit country and policy=block. Refusing to launch."
MSG[en.guard.disabled_runtime]="Geo-guard disabled (GUARD_ENABLED=0) — skipping country check."

# --- done summary ----------------------------------------------------------
MSG[en.done.title]="Done — your portable Claude stick is ready."
MSG[en.done.mount]="Stick: {0}"
MSG[en.done.howrun_posix]="On Linux/macOS:  open the stick and run  ./start.sh"
MSG[en.done.howrun_win]="On Windows:      open the stick and double-click  START.bat"
MSG[en.done.model]="Default model baked into the launcher: {0}"
MSG[en.done.vpn_yes]="Happ VPN: bundled."
MSG[en.done.vpn_no]="Happ VPN: not bundled (relies on host/system VPN)."
MSG[en.done.guard]="Geo-guard: {0}  (blocklist: {1})"
MSG[en.done.security]="Reminder: stick contents are plaintext under token-only encryption. For client PII use whole-volume encryption (LUKS / VeraCrypt / BitLocker To Go). See docs/SECURITY.md."
MSG[en.done.eject]="Safely eject the stick before unplugging."

# --- errors (generic) ------------------------------------------------------
MSG[en.err.generic]="Error: {0}"
MSG[en.err.need_tool]="Required tool not found: {0}. Install it and re-run."
MSG[en.err.no_internet]="No internet connection detected. A build needs to download the binary."
MSG[en.err.write_fail]="Could not write to {0}. Check that the stick is mounted and writable."
MSG[en.err.unsupported_os]="Unsupported OS for this builder: {0}."
MSG[en.err.macos_experimental]="NOTE: macOS support is EXPERIMENTAL/best-effort (built without a Mac to verify). Manual fallbacks may be required."

# ============================== RUSSIAN ====================================

# --- language prompt -------------------------------------------------------
MSG[ru.lang.prompt]="Select language / Выберите язык:  [E]nglish / [R]usский (по умолчанию) — нажмите E или R: "
MSG[ru.lang.set]="Язык: русский."

# --- generic / banner ------------------------------------------------------
MSG[ru.app.banner]="claude-on-a-stick — сборщик переносимого Claude Code"
MSG[ru.app.tagline]="Превращает USB-флешку в переносимое окружение Claude Code без установки."
MSG[ru.common.yes]="да"
MSG[ru.common.no]="нет"
MSG[ru.common.ok]="ОК"
MSG[ru.common.skip]="пропустить"
MSG[ru.common.press_enter]="Нажмите Enter для продолжения…"
MSG[ru.common.aborted]="Прервано. Ничего не изменено."
MSG[ru.common.step]="[Шаг {0}/{1}] {2}"

# --- USB selection / warnings / ERASE confirm ------------------------------
MSG[ru.usb.scanning]="Поиск съёмных USB-дисков…"
MSG[ru.usb.none_found]="Съёмный USB-диск не найден. Подключите флешку и запустите снова."
MSG[ru.usb.list_header]="Найденные съёмные диски (внутренние диски НИКОГДА не предлагаются):"
MSG[ru.usb.row]="  {0})  {1}   размер={2}   модель={3}"
MSG[ru.usb.choose]="Введите номер целевого диска (или 'q' для выхода): "
MSG[ru.usb.bad_choice]="Неверный выбор. Попробуйте ещё раз."
MSG[ru.usb.is_hdd_warn]="Внимание: USB-HDD тоже отображается как USB-диск. Убедитесь АБСОЛЮТНО точно, что '{0}' — это именно та флешка, которую нужно стереть."
MSG[ru.usb.warn_title]="!!! РАЗРУШИТЕЛЬНОЕ ДЕЙСТВИЕ — ЧИТАЙТЕ ВНИМАТЕЛЬНО !!!"
MSG[ru.usb.warn_body]="ВСЕ данные на {0} ({1}, {2}) будут БЕЗВОЗВРАТНО СТЁРТЫ. Отменить это будет невозможно."
MSG[ru.usb.erase_prompt]="Для подтверждения введите в точности  ERASE {0}  (любой другой ввод отменяет): "
MSG[ru.usb.erase_mismatch]="Подтверждение не совпало. Ничего не стёрто."

# --- format progress -------------------------------------------------------
MSG[ru.fmt.start]="Форматирование {0} … (MBR, один раздел exFAT тип 0x07, метка CLAUDE)"
MSG[ru.fmt.wipe]="  • Стираю существующие сигнатуры (wipefs)…"
MSG[ru.fmt.parttable]="  • Записываю таблицу разделов MBR…"
MSG[ru.fmt.partition]="  • Создаю один раздел (тип 0x07)…"
MSG[ru.fmt.mkfs]="  • Создаю файловую систему exFAT (метка CLAUDE)…"
MSG[ru.fmt.done]="Форматирование завершено. Флешка примонтирована в {0}."
MSG[ru.fmt.need_root]="Для форматирования нужны права root. Запустите через sudo или настройте sudo без пароля."
MSG[ru.fmt.need_exfatprogs]="Не найден exfatprogs (нужен mkfs.exfat). Установите exfatprogs и запустите снова."
MSG[ru.fmt.need_parttool]="Не найдены ни sfdisk, ни parted. Установите util-linux/fdisk или parted и запустите снова."

# --- Claude binary download / verify ---------------------------------------
MSG[ru.dl.channel_prompt]="Канал выпуска — [S]table (по умолчанию) или [L]atest? "
MSG[ru.dl.platform]="Целевая платформа бинарника: {0}"
MSG[ru.dl.resolving]="Определяю версию {0} с {1}…"
MSG[ru.dl.resolved]="Определена версия: {0}"
MSG[ru.dl.manifest]="Загружаю манифест для {0}…"
MSG[ru.dl.downloading]="Скачиваю бинарник claude ({0})…"
MSG[ru.dl.verifying]="Проверяю контрольную сумму SHA-256…"
MSG[ru.dl.verify_ok]="Контрольная сумма верна."
MSG[ru.dl.verify_fail]="НЕСОВПАДЕНИЕ КОНТРОЛЬНОЙ СУММЫ — файл повреждён или подменён. Прерываю."
MSG[ru.dl.gpg_checking]="gpg найден — проверяю подпись манифеста (по возможности)…"
MSG[ru.dl.gpg_ok]="Подпись манифеста проверена."
MSG[ru.dl.gpg_skip]="gpg не найден — пропускаю проверку подписи манифеста (только по возможности)."
MSG[ru.dl.gpg_warn]="Подпись манифеста проверить НЕ удалось. Продолжить всё равно? [y/N]: "
MSG[ru.dl.placed]="Бинарник размещён в {0}."
MSG[ru.dl.net_fail]="Сетевая ошибка при обращении к {0}. Проверьте соединение и запустите снова."

# --- setup-token instructions ----------------------------------------------
MSG[ru.token.intro]="Теперь нужен ВАШ долгоживущий токен Claude (только для инференса)."
MSG[ru.token.howto]="В отдельном терминале, где вы авторизованы, выполните:  claude setup-token"
MSG[ru.token.howto2]="Он напечатает долгоживущий OAuth-токен. Скопируйте токен целиком."
MSG[ru.token.paste]="Вставьте токен сюда (ввод скрыт), затем нажмите Enter: "
MSG[ru.token.empty]="Токен не введён. Без него флешка не сможет авторизоваться. Попробуйте снова."
MSG[ru.token.note]="Токен хранится ТОЛЬКО как зашифрованный AES-файл config/oauth.enc на флешке — никогда в git и никогда в открытом виде."

# --- stick password set / confirm ------------------------------------------
MSG[ru.pw.intro]="Задайте ПАРОЛЬ ФЛЕШКИ. Он шифрует токен на диске (AES-256-CBC, PBKDF2-HMAC-SHA1 300000)."
MSG[ru.pw.set]="Задайте пароль флешки (ввод скрыт): "
MSG[ru.pw.confirm]="Подтвердите пароль флешки: "
MSG[ru.pw.mismatch]="Пароли не совпадают. Попробуйте снова."
MSG[ru.pw.empty]="Пустой пароль недопустим. Попробуйте снова."
MSG[ru.pw.weak]="Этот пароль очень короткий. Использовать подлиннее? [Y/n]: "
MSG[ru.pw.encrypting]="Шифрую токен → config/oauth.enc …"
MSG[ru.pw.enc_done]="Токен зашифрован и записан в config/oauth.enc."

# --- stick launcher: password UNLOCK (decrypt at run time) ------------------
MSG[ru.unlock.prompt]="Пароль флешки: "
MSG[ru.unlock.fail]="Неверный пароль или повреждённый токен. Разблокировать не удалось."
MSG[ru.unlock.ok]="Токен разблокирован."

# --- Happ / VPN optional + subscription paste ------------------------------
MSG[ru.happ.offer]="Добавить на флешку VPN Happ? (необязательно, для регионов с ограничениями) [y/N]: "
MSG[ru.happ.skip]="Happ пропущен. Флешка будет полагаться на VPN хоста/системы. Гео-защита всё равно действует."
MSG[ru.happ.downloading]="Скачиваю Happ desktop для {0}…"
MSG[ru.happ.portableize]="Делаю Happ переносимым (перенаправляю его конфиг на флешку)…"
MSG[ru.happ.sub_intro]="Вставьте подписку. Принимается: «сырой» URL подписки или готовая ссылка happ://crypt5/…"
MSG[ru.happ.sub_paste]="Подписка («сырой» URL или happ://…), или оставьте пустым, чтобы добавить позже: "
MSG[ru.happ.sub_empty]="Подписка не введена. Её можно импортировать позже внутри Happ."
MSG[ru.happ.sub_inserting]="Вставляю подписку в Happ (deep link)…"
MSG[ru.happ.sub_ok]="Подписка импортирована (проверено по конфигу Happ)."
MSG[ru.happ.sub_manual]="Автоимпорт не удался. При первом запуске импортируйте эту ссылку вручную в Happ:"
MSG[ru.happ.autoconnect]="Совет: включите в Happ «автоподключение при запуске», чтобы флешка поднимала VPN сама."
MSG[ru.happ.win_vcredist]="Примечание: если «голый» Windows-ПК ругается на msvcp140.dll, добавьте в комплект DLL из VC++ redist."

# --- stick launcher: VPN bring-up ------------------------------------------
MSG[ru.vpn.none]="На этой флешке нет встроенного Happ — полагаюсь на VPN хоста/системы."
MSG[ru.vpn.starting]="Запускаю Happ (режим прокси)…"
MSG[ru.vpn.probing]="Ищу порт прокси Happ (10808,10809,2080,1080,10800,8080)…"
MSG[ru.vpn.up]="Прокси VPN поднят на 127.0.0.1:{0}. Направляю Claude через него."
MSG[ru.vpn.timeout]="Прокси Happ не поднялся вовремя. Включите Happ и «автоподключение», затем повторите."

# --- geo-guard config + run-time decisions ---------------------------------
MSG[ru.guard.intro]="Гео-защита (анти-бан) не даёт запуститься из заблокированной страны выхода."
MSG[ru.guard.enable]="Включить гео-защиту на флешке? [Y/n]: "
MSG[ru.guard.blocklist]="Заблокированные страны (через запятую, по умолчанию {0}): "
MSG[ru.guard.inconclusive]="Если определить страну не удалось — [P] спросить (по умолчанию) / [B] блокировать / [A] разрешить? "
MSG[ru.guard.disabled_note]="Гео-защита отключена — флешка запустится без проверки страны."
MSG[ru.guard.checking]="Гео-защита: проверяю страну выхода (напрямую)…"
MSG[ru.guard.country]="Гео-защита: страна выхода = {0}."
MSG[ru.guard.allowed]="Гео-защита: {0} не заблокирована — запускаю напрямую (VPN не трогаю)."
MSG[ru.guard.blocked_try_vpn]="Гео-защита: {0} заблокирована — поднимаю VPN и перепроверяю через прокси…"
MSG[ru.guard.blocked_via_vpn]="Гео-защита: выход через прокси = {0}."
MSG[ru.guard.refuse]="Гео-защита: страна выхода {0} заблокирована, рабочего выхода через VPN нет. Запуск отклонён."
MSG[ru.guard.inconclusive_prompt]="Гео-защита: не удалось определить страну выхода. Продолжить всё равно? [y/N]: "
MSG[ru.guard.inconclusive_block]="Гео-защита: страну выхода определить не удалось, политика=block. Запуск отклонён."
MSG[ru.guard.disabled_runtime]="Гео-защита отключена (GUARD_ENABLED=0) — пропускаю проверку страны."

# --- done summary ----------------------------------------------------------
MSG[ru.done.title]="Готово — ваша переносимая флешка с Claude собрана."
MSG[ru.done.mount]="Флешка: {0}"
MSG[ru.done.howrun_posix]="На Linux/macOS:  откройте флешку и запустите  ./start.sh"
MSG[ru.done.howrun_win]="На Windows:      откройте флешку и дважды щёлкните  START.bat"
MSG[ru.done.model]="Модель по умолчанию, зашитая в лаунчер: {0}"
MSG[ru.done.vpn_yes]="VPN Happ: в комплекте."
MSG[ru.done.vpn_no]="VPN Happ: не в комплекте (полагается на VPN хоста/системы)."
MSG[ru.done.guard]="Гео-защита: {0}  (список блокировки: {1})"
MSG[ru.done.security]="Напоминание: содержимое флешки лежит в открытом виде под шифрованием только токена. Для клиентских ПДн используйте шифрование всего тома (LUKS / VeraCrypt / BitLocker To Go). См. docs/SECURITY.md."
MSG[ru.done.eject]="Безопасно извлеките флешку перед отключением."

# --- errors (generic) ------------------------------------------------------
MSG[ru.err.generic]="Ошибка: {0}"
MSG[ru.err.need_tool]="Не найден необходимый инструмент: {0}. Установите его и запустите снова."
MSG[ru.err.no_internet]="Интернет-соединение не обнаружено. Для сборки нужно скачать бинарник."
MSG[ru.err.write_fail]="Не удалось записать в {0}. Проверьте, что флешка примонтирована и доступна для записи."
MSG[ru.err.unsupported_os]="Этот сборщик не поддерживает ОС: {0}."
MSG[ru.err.macos_experimental]="ВНИМАНИЕ: поддержка macOS — ЭКСПЕРИМЕНТАЛЬНАЯ/по возможности (собрано без проверки на Mac). Могут потребоваться ручные обходные пути."

# ===========================================================================
# FLAT KEYS used directly by builders/posix/build.sh (and mirrored by the flat
# map baked into builders/windows/build.ps1). These are the builder-UX strings;
# t() looks up the bare key (no dotted namespace). They are kept here so every
# key build.sh passes to t() resolves in BOTH en AND ru — no <<key>> sentinel
# ever leaks. (The dotted "ns.key" entries above remain for shared/usb.sh,
# shared/happ.sh and any launcher that uses the namespaced scheme.)
# ===========================================================================

# --------------------------------- ENGLISH ---------------------------------
# generic / banner / errors
MSG[en.banner_tagline]="portable, no-install Claude Code on a USB stick"
MSG[en.err_prefix]="Error"
MSG[en.bytes]="bytes"
MSG[en.bundled]="bundled"
# language
MSG[en.lang_selected]="Language set."
# step headers
MSG[en.step_channel]="Release channel + target platform"
MSG[en.step_model]="Default model (baked into the launcher)"
MSG[en.step_usb]="Select + format the USB stick"
MSG[en.step_scaffold]="Create the stick layout"
MSG[en.step_download_claude]="Download + verify the Claude binary"
MSG[en.step_token]="Auth token: setup-token + AES-encrypt"
MSG[en.step_happ]="Optional Happ VPN bundle"
MSG[en.step_geoguard]="Geo-guard (anti-ban)"
MSG[en.step_payload]="Copy the payload launchers"
MSG[en.step_selftest]="Final self-test"
# channel / platform / model
MSG[en.ask_channel_latest]="Use the 'latest' channel instead of 'stable'?"
MSG[en.detected_platform]="Detected platform"
MSG[en.ask_platform_ok]="Is this platform correct?"
MSG[en.platform_choices]="Available platforms"
MSG[en.enter_platform]="Enter the platform id:"
MSG[en.channel_target_set]="Channel + platform set"
MSG[en.model_default]="Default model"
MSG[en.ask_model_ok]="Keep this model?"
MSG[en.enter_model]="Enter the model id:"
MSG[en.model_set]="Model set"
# USB
MSG[en.enter_usb_device]="Enter the USB device node (e.g. /dev/sdb):"
MSG[en.usb_ready]="USB stick ready at"
# scaffold
MSG[en.scaffold_done]="Stick layout created."
# download + verify
MSG[en.resolving_version]="Resolving the version…"
MSG[en.version_is]="Version"
MSG[en.gpg_ok]="Manifest signature verified."
MSG[en.gpg_unverified]="Manifest signature could NOT be verified (continuing, best-effort)."
MSG[en.gpg_no_sig]="No manifest signature found (continuing, best-effort)."
MSG[en.gpg_absent]="gpg not present — skipping the signature check (best-effort only)."
MSG[en.binary_name]="Binary"
MSG[en.expected_sha]="expected sha256"
MSG[en.downloading_binary]="Downloading the binary"
MSG[en.verifying_sha]="Verifying the SHA-256 checksum…"
MSG[en.sha_mismatch]="CHECKSUM MISMATCH — the download is corrupted or tampered."
MSG[en.sha_ok]="Checksum OK."
MSG[en.claude_placed]="Claude binary placed at"
# token
MSG[en.running_setup_token]="Running 'claude setup-token' (interactive login)…"
MSG[en.token_choice_prompt]="How do you want to provide your Claude token?"
MSG[en.token_choice_paste]="  [1] Paste an existing token (you already have an sk-ant-oat… token)"
MSG[en.token_choice_new]="  [2] Get a new one now — opens your browser via 'claude setup-token'"
MSG[en.token_choice_ask]="Choice [1/2]"
MSG[en.setup_token_capture_failed]="Could not auto-capture the token from setup-token. Paste it manually."
MSG[en.setup_token_cross]="Cross-platform build: cannot run the target binary here — paste the token manually."
MSG[en.setup_token_manual_hint]="In a logged-in terminal run:  claude setup-token  — then paste the token."
MSG[en.paste_token]="Paste the token (input hidden):"
MSG[en.stick_password_set]="Set the stick password (input hidden):"
MSG[en.stick_password_confirm]="Confirm the stick password:"
MSG[en.password_empty]="Empty password is not allowed. Try again."
MSG[en.password_mismatch]="Passwords do not match. Try again."
MSG[en.token_encrypted]="Token encrypted to"
# happ
MSG[en.ask_bundle_happ]="Bundle the Happ VPN on the stick? (optional)"
MSG[en.happ_skipped]="Skipping Happ — the stick relies on the host/system VPN."
MSG[en.happ_bundled]="Happ bundled."
MSG[en.happ_download_failed]="Happ download/portable-ize failed — continuing without a bundled VPN."
MSG[en.ask_insert_sub]="Insert a subscription link into Happ now?"
MSG[en.paste_sub]="Paste the subscription (raw URL or happ://… link):"
MSG[en.sub_inserted]="Subscription imported into Happ."
MSG[en.sub_insert_failed]="Could not auto-import the subscription."
MSG[en.sub_manual_link]="Import this deep-link manually inside Happ once"
# geo-guard
MSG[en.probing_country]="Probing the current exit country (direct)…"
MSG[en.exit_country_is]="Exit country"
MSG[en.country_blocked_here]="This exit country is in the blocklist — keeping the guard ON."
MSG[en.ask_smart_skip]="This region is not blocked. Disable the guard for a faster launch (smart skip)?"
MSG[en.guard_disabled_smart]="Geo-guard disabled (smart skip)."
MSG[en.country_unknown]="Could not determine the exit country — keeping the guard ON (safe default)."
MSG[en.ask_edit_blocklist]="Edit the blocklist / inconclusive policy?"
MSG[en.enter_blocklist]="Blocked countries (comma-separated)"
MSG[en.inconclusive_choices]="When detection is inconclusive"
MSG[en.enter_inconclusive]="Inconclusive policy"
MSG[en.geoguard_written]="geoguard.conf written"
# payload
MSG[en.payload_missing]="Payload file missing (skipped)"
MSG[en.payload_copied]="Payload launchers copied + templated."
# self-test
MSG[en.test_no_binary]="claude binary missing or empty"
MSG[en.test_enc_small]="config/oauth.enc is too small"
MSG[en.test_no_enc]="config/oauth.enc missing"
MSG[en.test_no_geoconf]="geoguard.conf missing or has no GUARD_ENABLED"
MSG[en.test_launcher_syntax]="launcher passes bash -n"
MSG[en.test_launcher_syntax_bad]="launcher failed bash -n"
MSG[en.test_no_launcher]="launcher missing"
MSG[en.test_no_dir]="required directory missing"
MSG[en.test_happ_present]="bundled VPN present"
MSG[en.selftest_pass]="Self-test PASSED."
MSG[en.selftest_fail]="Self-test FAILED — see the messages above."
# summary
MSG[en.build_complete]="Build complete — your portable Claude stick is ready."
MSG[en.summary_stick]="Stick"
MSG[en.summary_platform]="Platform"
MSG[en.summary_model]="Model"
MSG[en.summary_lang]="Language"
MSG[en.summary_guard]="Geo-guard"
MSG[en.summary_vpn]="VPN"
MSG[en.summary_run_posix]="Run it"
MSG[en.summary_run_win]="On Windows: open the stick and double-click START.bat"
# errors (flat)
MSG[en.err_no_sha256]="No SHA-256 tool found (need sha256sum or shasum). Install one and re-run."
MSG[en.err_no_http]="No HTTP downloader found (need curl or wget). Install one and re-run."
MSG[en.err_no_usb_helper]="shared/usb.sh is missing or did not load — cannot select/format the USB."
MSG[en.err_usb_failed]="USB selection/format failed."
MSG[en.err_usb_none]="No USB device was selected."
MSG[en.err_usb_aborted]="USB format aborted (confirmation did not match)."
MSG[en.err_usb_mount]="The formatted stick did not appear as a writable directory."
MSG[en.err_resolve_version]="Could not resolve the release version from the manifest host."
MSG[en.err_manifest]="Could not download the release manifest."
MSG[en.err_platform_missing]="This platform is not present in the manifest"
MSG[en.err_download_binary]="Could not download the Claude binary."
MSG[en.err_sha_abort]="Aborting on checksum mismatch."
MSG[en.err_no_token]="No token was provided — cannot build the stick."
MSG[en.err_encrypt]="Token encryption failed."
MSG[en.err_no_crypto_helper]="shared/crypto.sh is missing or did not load — cannot encrypt the token."
MSG[en.err_encrypt_empty]="config/oauth.enc is empty after encryption."
MSG[en.err_no_happ_helper]="shared/happ.sh is missing or did not load — cannot bundle Happ."
MSG[en.err_no_payload]="Payload directory not found"
# macOS best-effort notice (flat keys used by build.sh print_macos_notice)
MSG[en.macos_experimental]="NOTE: macOS support is EXPERIMENTAL/best-effort (built without a Mac to verify)."
MSG[en.macos_fallbacks]="If something fails, manual fallbacks may be required (see docs/ARCHITECTURE.md)."

# --------------------------------- RUSSIAN ---------------------------------
# generic / banner / errors
MSG[ru.banner_tagline]="переносимый Claude Code на USB-флешке без установки"
MSG[ru.err_prefix]="Ошибка"
MSG[ru.bytes]="байт"
MSG[ru.bundled]="в комплекте"
# language
MSG[ru.lang_selected]="Язык выбран."
# step headers
MSG[ru.step_channel]="Канал выпуска + целевая платформа"
MSG[ru.step_model]="Модель по умолчанию (зашивается в лаунчер)"
MSG[ru.step_usb]="Выбор + форматирование USB-флешки"
MSG[ru.step_scaffold]="Создание структуры флешки"
MSG[ru.step_download_claude]="Скачивание + проверка бинарника Claude"
MSG[ru.step_token]="Токен: setup-token + шифрование AES"
MSG[ru.step_happ]="Опциональный VPN Happ"
MSG[ru.step_geoguard]="Гео-защита (анти-бан)"
MSG[ru.step_payload]="Копирование лаунчеров payload"
MSG[ru.step_selftest]="Финальная самопроверка"
# channel / platform / model
MSG[ru.ask_channel_latest]="Использовать канал «latest» вместо «stable»?"
MSG[ru.detected_platform]="Определена платформа"
MSG[ru.ask_platform_ok]="Платформа определена верно?"
MSG[ru.platform_choices]="Доступные платформы"
MSG[ru.enter_platform]="Введите идентификатор платформы:"
MSG[ru.channel_target_set]="Канал + платформа заданы"
MSG[ru.model_default]="Модель по умолчанию"
MSG[ru.ask_model_ok]="Оставить эту модель?"
MSG[ru.enter_model]="Введите идентификатор модели:"
MSG[ru.model_set]="Модель задана"
# USB
MSG[ru.enter_usb_device]="Введите узел USB-устройства (например, /dev/sdb):"
MSG[ru.usb_ready]="USB-флешка готова"
# scaffold
MSG[ru.scaffold_done]="Структура флешки создана."
# download + verify
MSG[ru.resolving_version]="Определяю версию…"
MSG[ru.version_is]="Версия"
MSG[ru.gpg_ok]="Подпись манифеста проверена."
MSG[ru.gpg_unverified]="Подпись манифеста проверить НЕ удалось (продолжаю, по возможности)."
MSG[ru.gpg_no_sig]="Подпись манифеста не найдена (продолжаю, по возможности)."
MSG[ru.gpg_absent]="gpg не найден — пропускаю проверку подписи (только по возможности)."
MSG[ru.binary_name]="Бинарник"
MSG[ru.expected_sha]="ожидаемая sha256"
MSG[ru.downloading_binary]="Скачиваю бинарник"
MSG[ru.verifying_sha]="Проверяю контрольную сумму SHA-256…"
MSG[ru.sha_mismatch]="НЕСОВПАДЕНИЕ КОНТРОЛЬНОЙ СУММЫ — файл повреждён или подменён."
MSG[ru.sha_ok]="Контрольная сумма верна."
MSG[ru.claude_placed]="Бинарник Claude размещён"
# token
MSG[ru.running_setup_token]="Запускаю «claude setup-token» (интерактивный вход)…"
MSG[ru.token_choice_prompt]="Как передать токен Claude?"
MSG[ru.token_choice_paste]="  [1] Вставить готовый токен (у вас уже есть sk-ant-oat…)"
MSG[ru.token_choice_new]="  [2] Получить новый сейчас — откроется браузер ('claude setup-token')"
MSG[ru.token_choice_ask]="Выбор [1/2]"
MSG[ru.setup_token_capture_failed]="Не удалось автоматически получить токен из setup-token. Вставьте его вручную."
MSG[ru.setup_token_cross]="Сборка под другую платформу: целевой бинарник здесь не запустить — вставьте токен вручную."
MSG[ru.setup_token_manual_hint]="В терминале, где вы авторизованы, выполните:  claude setup-token  — затем вставьте токен."
MSG[ru.paste_token]="Вставьте токен (ввод скрыт):"
MSG[ru.stick_password_set]="Задайте пароль флешки (ввод скрыт):"
MSG[ru.stick_password_confirm]="Подтвердите пароль флешки:"
MSG[ru.password_empty]="Пустой пароль недопустим. Попробуйте снова."
MSG[ru.password_mismatch]="Пароли не совпадают. Попробуйте снова."
MSG[ru.token_encrypted]="Токен зашифрован в"
# happ
MSG[ru.ask_bundle_happ]="Добавить на флешку VPN Happ? (необязательно)"
MSG[ru.happ_skipped]="Happ пропущен — флешка полагается на VPN хоста/системы."
MSG[ru.happ_bundled]="Happ добавлен."
MSG[ru.happ_download_failed]="Скачивание/портативизация Happ не удалась — продолжаю без встроенного VPN."
MSG[ru.ask_insert_sub]="Вставить ссылку подписки в Happ сейчас?"
MSG[ru.paste_sub]="Вставьте подписку («сырой» URL или ссылку happ://…):"
MSG[ru.sub_inserted]="Подписка импортирована в Happ."
MSG[ru.sub_insert_failed]="Не удалось автоматически импортировать подписку."
MSG[ru.sub_manual_link]="Импортируйте этот deep-link в Happ вручную один раз"
# geo-guard
MSG[ru.probing_country]="Определяю текущую страну выхода (напрямую)…"
MSG[ru.exit_country_is]="Страна выхода"
MSG[ru.country_blocked_here]="Эта страна выхода в списке блокировки — оставляю защиту ВКЛ."
MSG[ru.ask_smart_skip]="Этот регион не заблокирован. Отключить защиту для более быстрого запуска (умный пропуск)?"
MSG[ru.guard_disabled_smart]="Гео-защита отключена (умный пропуск)."
MSG[ru.country_unknown]="Не удалось определить страну выхода — оставляю защиту ВКЛ (безопасно по умолчанию)."
MSG[ru.ask_edit_blocklist]="Изменить список блокировки / политику при неопределённости?"
MSG[ru.enter_blocklist]="Заблокированные страны (через запятую)"
MSG[ru.inconclusive_choices]="Когда определить не удалось"
MSG[ru.enter_inconclusive]="Политика при неопределённости"
MSG[ru.geoguard_written]="geoguard.conf записан"
# payload
MSG[ru.payload_missing]="Файл payload отсутствует (пропущен)"
MSG[ru.payload_copied]="Лаунчеры payload скопированы и шаблонизированы."
# self-test
MSG[ru.test_no_binary]="бинарник claude отсутствует или пуст"
MSG[ru.test_enc_small]="config/oauth.enc слишком мал"
MSG[ru.test_no_enc]="config/oauth.enc отсутствует"
MSG[ru.test_no_geoconf]="geoguard.conf отсутствует или без GUARD_ENABLED"
MSG[ru.test_launcher_syntax]="лаунчер проходит bash -n"
MSG[ru.test_launcher_syntax_bad]="лаунчер не прошёл bash -n"
MSG[ru.test_no_launcher]="лаунчер отсутствует"
MSG[ru.test_no_dir]="отсутствует необходимый каталог"
MSG[ru.test_happ_present]="встроенный VPN присутствует"
MSG[ru.selftest_pass]="Самопроверка ПРОЙДЕНА."
MSG[ru.selftest_fail]="Самопроверка НЕ ПРОЙДЕНА — см. сообщения выше."
# summary
MSG[ru.build_complete]="Сборка завершена — ваша переносимая флешка с Claude готова."
MSG[ru.summary_stick]="Флешка"
MSG[ru.summary_platform]="Платформа"
MSG[ru.summary_model]="Модель"
MSG[ru.summary_lang]="Язык"
MSG[ru.summary_guard]="Гео-защита"
MSG[ru.summary_vpn]="VPN"
MSG[ru.summary_run_posix]="Запуск"
MSG[ru.summary_run_win]="На Windows: откройте флешку и дважды щёлкните START.bat"
# errors (flat)
MSG[ru.err_no_sha256]="Не найден инструмент SHA-256 (нужен sha256sum или shasum). Установите и запустите снова."
MSG[ru.err_no_http]="Не найден HTTP-загрузчик (нужен curl или wget). Установите и запустите снова."
MSG[ru.err_no_usb_helper]="shared/usb.sh отсутствует или не загрузился — выбор/форматирование USB невозможно."
MSG[ru.err_usb_failed]="Выбор/форматирование USB не удались."
MSG[ru.err_usb_none]="USB-устройство не выбрано."
MSG[ru.err_usb_aborted]="Форматирование USB отменено (подтверждение не совпало)."
MSG[ru.err_usb_mount]="Отформатированная флешка не появилась как доступный для записи каталог."
MSG[ru.err_resolve_version]="Не удалось определить версию выпуска с хоста манифеста."
MSG[ru.err_manifest]="Не удалось скачать манифест выпуска."
MSG[ru.err_platform_missing]="Эта платформа отсутствует в манифесте"
MSG[ru.err_download_binary]="Не удалось скачать бинарник Claude."
MSG[ru.err_sha_abort]="Прерываю из-за несовпадения контрольной суммы."
MSG[ru.err_no_token]="Токен не предоставлен — собрать флешку нельзя."
MSG[ru.err_encrypt]="Шифрование токена не удалось."
MSG[ru.err_no_crypto_helper]="shared/crypto.sh отсутствует или не загрузился — зашифровать токен нельзя."
MSG[ru.err_encrypt_empty]="config/oauth.enc пуст после шифрования."
MSG[ru.err_no_happ_helper]="shared/happ.sh отсутствует или не загрузился — добавить Happ нельзя."
MSG[ru.err_no_payload]="Каталог payload не найден"
# macOS best-effort notice (flat keys used by build.sh print_macos_notice)
MSG[ru.macos_experimental]="ВНИМАНИЕ: поддержка macOS — ЭКСПЕРИМЕНТАЛЬНАЯ/по возможности (собрано без проверки на Mac)."
MSG[ru.macos_fallbacks]="Если что-то не сработает, могут потребоваться ручные обходные пути (см. docs/ARCHITECTURE.md)."

fi  # end Bash-4 assoc-array population

# ----------------------------------------------------------------------------
# _i18n_subst <template> [args…]
#   Replace {0} {1} {2} … in <template> with positional args. Pure-bash, no
#   sed/printf-format pitfalls (token text may contain % or backslashes).
# ----------------------------------------------------------------------------
_i18n_subst() {
  local out="$1"; shift
  local i=0 arg
  for arg in "$@"; do
    # Replace EVERY occurrence of {i} with the arg (parameter-expansion, global).
    out="${out//\{$i\}/$arg}"
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# ----------------------------------------------------------------------------
# t <key> [args…]   — Bash 4+ accessor (assoc-array lookup).
#   Looks up "${I18N_LANG}.<key>"; falls back to English; then to the raw key
#   so a missing string is loud but never crashes the builder/launcher.
#   Prints WITHOUT a trailing newline so it composes for prompts; callers add
#   "echo" or use $(t …) for line output.
# ----------------------------------------------------------------------------
if [ "$I18N_HAVE_ASSOC" = "1" ]; then
  t() {
    local key="$1"; shift
    local tmpl="${MSG[${I18N_LANG}.$key]-}"
    if [ -z "$tmpl" ]; then
      tmpl="${MSG[en.$key]-}"          # English fallback
    fi
    if [ -z "$tmpl" ]; then
      tmpl="<<$key>>"                  # last-resort: show the missing key
    fi
    _i18n_subst "$tmpl" "$@"
  }
fi

# Convenience: print a translated line WITH a trailing newline.
tn() { printf '%s\n' "$(t "$@")"; }

# ----------------------------------------------------------------------------
# i18n_pick_language — ask language FIRST (CONTRACTS §9).
#   Default is taken from $LANG (ru* → ru, else en). A single keypress (E/R)
#   overrides; Enter keeps the default. Sets the global I18N_LANG.
#   The prompt itself is bilingual (we don't know the language yet).
# ----------------------------------------------------------------------------
i18n_pick_language() {
  # Default from the host locale.
  case "${LANG:-}${LC_ALL:-}" in
    ru_*|RU_*|ru|*ru_RU*) I18N_LANG=ru ;;
    *)                    I18N_LANG=en ;;
  esac
  # Bilingual prompt (single key, no Enter needed thanks to -n1).
  printf '%s' "Select language / Выберите язык:  [E]nglish / [R]usский — E/R (Enter=${I18N_LANG}): "
  local key=""
  # -n1 reads a single char; if stdin is not a TTY just keep the default.
  if read -rsn1 key 2>/dev/null; then printf '\n'; fi
  case "$key" in
    e|E) I18N_LANG=en ;;
    r|R) I18N_LANG=ru ;;
    *)   : ;;   # Enter / anything else → keep locale default
  esac
  export LANG_CODE="$I18N_LANG"
  tn lang.set
}

# ----------------------------------------------------------------------------
# i18n_set_lang <code>  — programmatic language switch (no prompt).
#   Canonical name expected by builders/posix/build.sh. Keeps the single source
#   of truth (I18N_LANG) and the convenience alias LANG_CODE in lock-step.
# ----------------------------------------------------------------------------
i18n_set_lang() {
  case "${1:-}" in
    ru) I18N_LANG=ru ;;
    en) I18N_LANG=en ;;
    *)  return 1 ;;
  esac
  export LANG_CODE="$I18N_LANG"
  return 0
}

# LANG_CODE mirrors I18N_LANG so `${LANG_CODE:-en}` reads correctly even before
# a language is explicitly picked (seeded from the locale default above).
export LANG_CODE="$I18N_LANG"

# ----------------------------------------------------------------------------
# Bash 3.2 (stock macOS) FALLBACK
# --------------------------------
# If `declare -A` is unavailable, the assoc array above was never populated and
# t() was never defined. We define a case()-based t() so the builder still runs.
# We mirror ONLY the keys; to avoid duplicating ~120 strings twice in one file,
# the fallback re-uses the SAME catalogue by re-sourcing under Homebrew bash
# when possible; otherwise it degrades to English-only echo of the key plus a
# clear note. The posix build.sh is expected to re-exec under bash 4+ first
# (see CONTRACTS §9); this block is the safety net so nothing hard-crashes.
# ----------------------------------------------------------------------------
if [ "$I18N_HAVE_ASSOC" != "1" ]; then
  # Try to relaunch the current script under a Bash 4+ if one exists (Homebrew
  # ships /usr/local/bin/bash or /opt/homebrew/bin/bash). Only do this if we
  # have an entry script to re-exec; libraries sourced standalone just warn.
  for _b4 in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [ -x "$_b4" ] && [ -n "${BASH_SOURCE[1]:-}" ] && [ "${I18N_NO_REEXEC:-0}" != "1" ]; then
      export I18N_NO_REEXEC=1
      exec "$_b4" "${BASH_SOURCE[1]}" "$@"
    fi
  done

  # No Bash 4+ available: minimal English-only fallback so the script survives.
  # NOTE (macOS bash-3.2): associative arrays are unavailable, so the full RU/EN
  # catalogue cannot be loaded here. Install a modern bash:  brew install bash
  I18N_LANG=en
  t() {
    local key="$1"; shift
    local tmpl
    case "$key" in
      lang.set)        tmpl="Language: English (bash 3.2 fallback — run under bash 4+ for full i18n).";;
      app.banner)      tmpl="claude-on-a-stick — portable Claude Code builder";;
      common.aborted)  tmpl="Aborted. Nothing was changed.";;
      err.macos_experimental) tmpl="NOTE: macOS is EXPERIMENTAL/best-effort. Install bash 4+ (brew install bash) for full RU/EN messages.";;
      *)               tmpl="<<$key>>";;
    esac
    _i18n_subst "$tmpl" "$@"
  }
  i18n_pick_language() { I18N_LANG=en; export LANG_CODE=en; tn lang.set; }
  # Canonical setter expected by build.sh (bash-3.2 path: en-only catalogue).
  i18n_set_lang() { case "${1:-}" in en|ru) I18N_LANG="$1";; *) return 1;; esac; export LANG_CODE="$I18N_LANG"; return 0; }
  export LANG_CODE="$I18N_LANG"
fi
