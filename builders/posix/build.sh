#!/usr/bin/env bash
# =============================================================================
# claude-on-a-stick - POSIX interactive builder
#   Linux  = solid / verified
#   macOS  = best-effort / guided (no Mac to verify; prints an experimental notice)
#
# Turns a USB stick into a portable, no-install "real Claude Code" environment:
#   - downloads + sha256-verifies the official Claude Code binary  (CONTRACTS §8)
#   - runs `claude setup-token` and AES-encrypts it to config/oauth.enc (§4)
#   - optional bundled Happ VPN + subscription deep-link insert        (§6, §7)
#   - anti-ban geo-guard with a smart-skip suggestion                  (§5)
#   - copies the payload launchers, templating MODEL + language        (§3)
#
# This file ships ONLY logic. The Claude binary, Happ, the auth token and any
# subscription link are downloaded/entered at build time and land on the stick,
# never in git.
#
# Robust: `set -euo pipefail`. All user-facing text routed through t() (i18n.sh).
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 0. Locate ourselves and the repo root (resolve symlinks; no readlink -f on mac)
# -----------------------------------------------------------------------------
# Resolve the directory this script lives in, following symlinks, portably.
_resolve_dir() {
	local src=$1 dir
	while [ -h "$src" ]; do
		dir=$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)
		src=$(readlink "$src")
		case $src in
			/*) ;;                 # absolute symlink target
			*) src="$dir/$src" ;;  # relative symlink target
		esac
	done
	cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd
}

SCRIPT_DIR=$(_resolve_dir "${BASH_SOURCE[0]}")
# builders/posix/build.sh  ->  repo root is two levels up
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." >/dev/null 2>&1 && pwd)
SHARED_DIR="$REPO_ROOT/shared"
PAYLOAD_DIR="$REPO_ROOT/payload"

# -----------------------------------------------------------------------------
# 1. macOS Bash-version guard (CONTRACTS §9)
#    /bin/bash on macOS is 3.2 (no `declare -A`). i18n.sh needs Bash 4+.
#    Try to re-exec under a Homebrew bash 4+; if none, i18n.sh must fall back to
#    a case-based map. Either way, print the best-effort notice for macOS.
# -----------------------------------------------------------------------------
OS_NAME=$(uname -s 2>/dev/null || echo unknown)
IS_MACOS=0
[ "$OS_NAME" = "Darwin" ] && IS_MACOS=1

maybe_reexec_bash4() {
	# Only relevant on macOS, and only if the current bash is < 4.
	[ "$IS_MACOS" = "1" ] || return 0
	if [ "${BASH_VERSINFO:-0}" -ge 4 ] 2>/dev/null; then
		return 0
	fi
	# Guard against an infinite re-exec loop.
	if [ "${CLAUDE_STICK_REEXEC:-0}" = "1" ]; then
		return 0
	fi
	local cand
	for cand in \
		/opt/homebrew/bin/bash \
		/usr/local/bin/bash \
		"$(command -v bash 2>/dev/null || true)"; do
		# Skip candidates that are empty or not executable.
		if [ -z "$cand" ] || [ ! -x "$cand" ]; then continue; fi
		# Probe its major version without trusting BASH_VERSINFO of a child.
		local maj
		# NB: single quotes are intentional - $BASH_VERSINFO must expand inside
		# the *child* bash ($cand), not in this (possibly bash 3.2) parent.
		# shellcheck disable=SC2016
		maj=$("$cand" -c 'echo "${BASH_VERSINFO:-0}"' 2>/dev/null || echo 0)
		if [ "$maj" -ge 4 ] 2>/dev/null; then
			export CLAUDE_STICK_REEXEC=1
			exec "$cand" "$0" "$@"
		fi
	done
	# No bash 4 found - continue; i18n.sh's case fallback must carry us.
	return 0
}
maybe_reexec_bash4 "$@"

# -----------------------------------------------------------------------------
# 2. Minimal pre-i18n logging (used only until i18n.sh is sourced)
# -----------------------------------------------------------------------------
_pre() { printf '%s\n' "$*" >&2; }
_die_raw() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# 3. Source the shared helpers. Each is guarded so a missing optional helper
#    degrades gracefully rather than crashing the whole builder.
#    Required: i18n.sh (everything talks through t()).
# -----------------------------------------------------------------------------
if [ ! -f "$SHARED_DIR/i18n.sh" ]; then
	_die_raw "shared/i18n.sh not found at $SHARED_DIR/i18n.sh - cannot continue."
fi
# shellcheck source=/dev/null
. "$SHARED_DIR/i18n.sh"

# Fallback t() in case i18n.sh did not define one for some reason. The real
# i18n.sh defines a richer t(); we never want an undefined-function crash.
if ! command -v t >/dev/null 2>&1; then
	t() { printf '%s' "$*"; }
fi

# Optional helpers - present in a complete checkout, may be stubbed in dev.
HAVE_USB=0 HAVE_CRYPTO=0 HAVE_HAPP=0
if [ -f "$SHARED_DIR/usb.sh" ]; then
	# shellcheck source=/dev/null
	. "$SHARED_DIR/usb.sh" && HAVE_USB=1
fi
if [ -f "$SHARED_DIR/crypto.sh" ]; then
	# shellcheck source=/dev/null
	. "$SHARED_DIR/crypto.sh" && HAVE_CRYPTO=1
fi
if [ -f "$SHARED_DIR/happ.sh" ]; then
	# shellcheck source=/dev/null
	. "$SHARED_DIR/happ.sh" && HAVE_HAPP=1
fi

# -----------------------------------------------------------------------------
# 4. Pretty output helpers (now that t() exists). Colours only on a TTY.
# -----------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
	C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYN=$'\033[36m'
else
	C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GRN=''; C_YEL=''; C_CYN=''
fi

say()   { printf '%s\n' "$*"; }
info()  { printf '%s\n' "${C_CYN}$*${C_RESET}"; }
ok()    { printf '%s\n' "${C_GRN}$*${C_RESET}"; }
warn()  { printf '%s\n' "${C_YEL}$*${C_RESET}" >&2; }
err()   { printf '%s\n' "${C_RED}$*${C_RESET}" >&2; }
hr()    { printf '%s\n' "${C_DIM}------------------------------------------------------------${C_RESET}"; }
step()  { printf '\n%s\n' "${C_BOLD}${C_CYN}==> $*${C_RESET}"; }

# t-aware fatal: t() the key, then exit.
die() { err "$(t err_prefix): $*"; exit 1; }

# -----------------------------------------------------------------------------
# 5. Small utilities
# -----------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# Confirm yes/no with a default. Returns 0 for yes.
confirm() {
	# $1 = prompt text, $2 = default (y|n)
	local prompt=$1 def=${2:-n} ans hint
	case $def in y|Y) hint="[Y/n]";; *) hint="[y/N]";; esac
	printf '%s %s ' "$prompt" "$hint" >&2
	read -r ans || ans=''
	ans=${ans:-$def}
	case $ans in y|Y|yes|YES|Yes|д|Д|да|ДА) return 0;; *) return 1;; esac
}

# Read a (possibly masked) line into the named variable.
# $1 = varname, $2 = prompt, $3 = "mask" to hide input
prompt_into() {
	local _var=$1 _prompt=$2 _mask=${3:-} _val
	if [ "$_mask" = "mask" ]; then
		printf '%s ' "$_prompt" >&2
		read -rs _val || _val=''
		printf '\n' >&2
	else
		printf '%s ' "$_prompt" >&2
		read -r _val || _val=''
	fi
	printf -v "$_var" '%s' "$_val"
}

# sha256 of a file -> stdout (linux: sha256sum, mac: shasum -a 256)
sha256_of() {
	if have sha256sum; then
		sha256sum "$1" | awk '{print $1}'
	elif have shasum; then
		shasum -a 256 "$1" | awk '{print $1}'
	else
		die "$(t err_no_sha256)"
	fi
}

# HTTP GET to stdout (curl preferred, wget fallback). $1=url
http_get() {
	if have curl; then
		curl -fsSL --max-time 60 "$1"
	elif have wget; then
		wget -qO- --timeout=60 "$1"
	else
		die "$(t err_no_http)"
	fi
}

# HTTP download to a file. $1=url $2=dest
http_dl() {
	if have curl; then
		curl -fL --retry 3 --max-time 1800 -o "$2" "$1"
	elif have wget; then
		wget -O "$2" --tries=3 --timeout=1800 "$1"
	else
		die "$(t err_no_http)"
	fi
}

# Parse a string JSON value for a flat key path "a.b.c".  $1=json  $2=dotpath
#
# IMPORTANT: Claude release platform ids contain hyphens (e.g. "win32-x64",
# "linux-x64-musl"). An UNQUOTED jq path like `.platforms.linux-x64.binary`
# parses the hyphen as subtraction and errors out, so we must QUOTE every path
# segment for jq: `.platforms."linux-x64"."binary"`. Likewise the jq-less
# fallback must be SCOPED to the requested object (else, with several platforms
# in the manifest, the first "binary"/"checksum" leaf would be returned for ALL
# of them - which silently mixes up multi-OS downloads).
json_get() {
	local json=$1 path=$2
	if have jq; then
		# Build a jq path with each dotted segment quoted, so hyphens are literal.
		local jqpath="" seg
		local IFS=.
		for seg in $path; do
			jqpath="${jqpath}[\"$seg\"]"
		done
		unset IFS
		local out
		out=$(printf '%s' "$json" | jq -r "$jqpath // empty" 2>/dev/null) || out=""
		# jq prints "null"/"" for a genuinely-absent path; treat empty as miss and
		# fall through to the scoped-regex fallback (covers odd manifests).
		if [ -n "$out" ]; then
			printf '%s' "$out"
			return 0
		fi
	fi
	# jq-less (or jq-miss) fallback. Scope to the parent object so the right
	# platform's leaf is selected. For "platforms.<plat>.<leaf>" we first isolate
	# the <plat> object, then read <leaf> inside it.
	local leaf=${path##*.}
	local parent=${path%.*}          # e.g. "platforms.win32-x64"
	local owner=${parent##*.}        # e.g. "win32-x64"  (the object key)
	local flat; flat=$(printf '%s' "$json" | tr -d '\n')
	if [ "$parent" != "$path" ] && [ -n "$owner" ]; then
		# Carve out the object that follows  "owner":{ ... }  (non-nested objects,
		# which the flat Claude manifest satisfies) and read the leaf from it.
		local obj
		obj=$(printf '%s' "$flat" \
			| grep -oE "\"$owner\"[[:space:]]*:[[:space:]]*\{[^{}]*\}" \
			| head -n1)
		[ -n "$obj" ] && flat="$obj"
	fi
	printf '%s' "$flat" \
		| grep -oE "\"$leaf\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|[0-9]+)" \
		| head -n1 \
		| sed -E "s/\"$leaf\"[[:space:]]*:[[:space:]]*//; s/^\"//; s/\"$//"
}

cleanup() {
	# Best-effort scrub of any temp working dir.
	[ -n "${WORK_TMP:-}" ] && [ -d "${WORK_TMP:-}" ] && rm -rf "$WORK_TMP" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# =============================================================================
#                                 MAIN FLOW
# =============================================================================

# ---- Banner --------------------------------------------------------------
print_banner() {
	hr
	say "${C_BOLD}claude-on-a-stick${C_RESET}  -  $(t banner_tagline)"
	hr
}

# ---- macOS experimental notice (§ locked decision) -----------------------
print_macos_notice() {
	[ "$IS_MACOS" = "1" ] || return 0
	warn ""
	warn "$(t macos_experimental)"
	warn "$(t macos_fallbacks)"
	warn ""
}

# -----------------------------------------------------------------------------
# STEP A - language FIRST (CONTRACTS §9). i18n.sh picks a default from $LANG;
# we let the user override with a single keypress.
# -----------------------------------------------------------------------------
choose_language() {
	# i18n.sh is expected to expose:
	#   - LANG_CODE (current selection, e.g. en|ru), seeded from $LANG
	#   - i18n_set_lang <code>   (switch the active language)
	# We degrade gracefully if those are absent.
	local default_lang="${LANG_CODE:-en}"
	printf '\n' >&2
	# Language menu is intentionally bilingual + tiny so it reads pre-selection.
	say "Select language / Выберите язык:"
	say "  [1] English   [2] Русский"
	printf 'Language [%s]: ' "$default_lang" >&2
	local pick; read -r pick || pick=''
	case "${pick:-}" in
		1|e|en|E|EN|English|english) default_lang=en ;;
		2|r|ru|R|RU|Russian|русский|Русский) default_lang=ru ;;
		'') : ;;  # keep i18n.sh default
		*) : ;;   # unknown -> keep default
	esac
	if command -v i18n_set_lang >/dev/null 2>&1; then
		i18n_set_lang "$default_lang" || true
	else
		export LANG_CODE="$default_lang"
	fi
	ok "$(t lang_selected)"
}

# -----------------------------------------------------------------------------
# STEP B - release channel / target platform(s) (CONTRACTS §8, §13 + MULTI-OS)
# Channel default: stable.
#
# MULTI-OS STICK ("one stick, any OS"): a single build may target MORE THAN ONE
# platform so the same encrypted token boots Claude on Windows, Linux AND macOS.
#   - The auto-detected host platform stays the single-target DEFAULT.
#   - The user may instead enter a comma-separated list of platform ids, or "A"
#     for the common set (win32-x64 + linux-x64 + darwin-arm64).
# PLAT  = the "primary" platform (host, or the first chosen) - used for the
#         host-runnable `claude setup-token` check and the self-test default.
# PLATS = the full, validated, de-duplicated, space-separated list to build.
# The destructive USB format and the one shared config/token are produced ONCE
# regardless of how many platforms are in PLATS (see select_and_format_usb /
# setup_and_encrypt_token); only the per-platform binary download loops.
# -----------------------------------------------------------------------------
CHANNEL="stable"
PLAT=""
PLATS=""

# Every Claude release platform id we accept (CONTRACTS §8). Used to validate
# user input so a typo can't silently produce an unbuildable target.
KNOWN_PLATS="win32-x64 win32-arm64 darwin-x64 darwin-arm64 linux-x64 linux-arm64 linux-x64-musl linux-arm64-musl"
# "All common" shortcut (delta point 1): one each of the three OS families.
ALL_COMMON_PLATS="win32-x64 linux-x64 darwin-arm64"

# is_known_plat <id> -> 0 if it is a recognised platform id.
is_known_plat() {
	local cand=$1 p
	for p in $KNOWN_PLATS; do
		[ "$cand" = "$p" ] && return 0
	done
	return 1
}

detect_platform() {
	# Map uname -> Claude release platform id (CONTRACTS §8).
	local m; m=$(uname -m 2>/dev/null || echo x86_64)
	local arch
	case "$m" in
		x86_64|amd64) arch="x64" ;;
		aarch64|arm64) arch="arm64" ;;
		*) arch="x64" ;;  # default; user can override below
	esac
	if [ "$IS_MACOS" = "1" ]; then
		PLAT="darwin-$arch"
	else
		# Linux: detect musl (Alpine etc.) vs glibc.
		local libc=""
		if have ldd; then
			if ldd --version 2>&1 | grep -qi musl; then libc="-musl"; fi
		fi
		[ -f /etc/alpine-release ] && libc="-musl"
		PLAT="linux-${arch}${libc}"
	fi
}

# Parse a user target spec into the validated PLATS list (+ set PLAT to the
# first entry). Accepts: "A"/"all" (common set), or a comma/space-separated
# list of platform ids. Unknown ids are dropped with a warning; if nothing
# valid remains we keep the previous PLAT/PLATS (caller re-prompts or aborts).
# $1 = raw spec. Returns 0 if at least one valid platform was parsed.
parse_target_spec() {
	local spec=$1 out="" tok
	# Normalise separators (comma -> space) and trim.
	spec=$(printf '%s' "$spec" | tr ',' ' ')
	case "$spec" in
		# "A" / "all" / "all-common" -> the common three-OS set.
		[Aa]|[Aa][Ll][Ll]|all-common|ALL-COMMON|"все"|"ВСЕ")
			out="$ALL_COMMON_PLATS"
			;;
		*)
			for tok in $spec; do
				if is_known_plat "$tok"; then
					# de-dup while preserving order
					case " $out " in *" $tok "*) ;; *) out="$out $tok" ;; esac
				else
					# No dedicated i18n key (keep this builder self-contained);
					# bilingual inline so we never leak a <<key>> sentinel.
					case "${LANG_CODE:-${I18N_LANG:-en}}" in
						ru) warn "Неизвестная платформа (пропущена): $tok" ;;
						*)  warn "Unknown platform (skipped): $tok" ;;
					esac
				fi
			done
			;;
	esac
	# strip leading space
	out=${out# }
	[ -n "$out" ] || return 1
	PLATS="$out"
	# Primary = first entry (used by the host-runnable token check + self-test).
	PLAT=${out%% *}
	return 0
}

choose_channel_and_target() {
	step "$(t step_channel)"
	# Channel
	if confirm "$(t ask_channel_latest)" n; then
		CHANNEL="latest"
	else
		CHANNEL="stable"
	fi

	# Target platform(s). Auto-detected host is the single-target default; the
	# user may accept it, or pick one/many (comma-separated) or "A" = all common.
	detect_platform
	PLATS="$PLAT"   # single-target default = this host
	info "$(t detected_platform): ${C_BOLD}$PLAT${C_RESET}"

	# Bilingual multi-OS hint (kept inline so this builder needs no new i18n keys;
	# all single-target prompts still flow through t()).
	local _lang="${LANG_CODE:-${I18N_LANG:-en}}"
	if ! confirm "$(t ask_platform_ok)" y; then
		say "$(t platform_choices):"
		say "  win32-x64  win32-arm64  darwin-x64  darwin-arm64"
		say "  linux-x64  linux-arm64  linux-x64-musl  linux-arm64-musl"
		case "$_lang" in
			ru)
				say "  Одна флешка - любая ОС: можно указать НЕСКОЛЬКО платформ через запятую,"
				say "  либо 'A' = общий набор ($ALL_COMMON_PLATS)." ;;
			*)
				say "  One stick, any OS: enter MULTIPLE platforms comma-separated,"
				say "  or 'A' = the common set ($ALL_COMMON_PLATS)." ;;
		esac
		# Re-prompt until we get at least one valid platform (or the user accepts
		# the host default by entering nothing).
		while :; do
			local p
			case "$_lang" in
				ru) prompt_into p "Платформа(ы) [Enter=$PLAT]:" ;;
				*)  prompt_into p "Platform(s) [Enter=$PLAT]:" ;;
			esac
			if [ -z "$p" ]; then
				# keep the host default (PLAT / PLATS already set)
				break
			fi
			if parse_target_spec "$p"; then
				break
			fi
			case "$_lang" in
				ru) warn "Не распознано ни одной платформы - попробуйте снова." ;;
				*)  warn "No valid platform recognised - try again." ;;
			esac
		done
	fi

	# Count + report. Single vs multi only changes the binary-download loop and
	# the launcher union; everything else (USB, token, config) is produced once.
	local n=0 _p
	for _p in $PLATS; do n=$((n + 1)); done
	if [ "$n" -gt 1 ]; then
		ok "$(t channel_target_set): channel=$CHANNEL platforms=[$PLATS] ($n)"
		case "$_lang" in
			ru) info "Мульти-ОС сборка: одна флешка - любая ОС (один зашифрованный токен)." ;;
			*)  info "Multi-OS build: one stick, any OS (one encrypted token)." ;;
		esac
	else
		ok "$(t channel_target_set): channel=$CHANNEL platform=$PLAT"
	fi
}

# -----------------------------------------------------------------------------
# STEP C - model selection (baked into the launcher as --model; default opus)
# -----------------------------------------------------------------------------
MODEL="claude-opus-4-8"
choose_model() {
	step "$(t step_model)"
	info "$(t model_default): ${C_BOLD}$MODEL${C_RESET}"
	if ! confirm "$(t ask_model_ok)" y; then
		local m; prompt_into m "$(t enter_model)"
		[ -n "$m" ] && MODEL="$m"
	fi
	ok "$(t model_set): $MODEL"
}

# -----------------------------------------------------------------------------
# STEP D - pick + confirm + format the USB stick (CONTRACTS §10)
# Delegates the dangerous parts to shared/usb.sh, which:
#   - enumerates removable disks (lsblk TYPE=disk AND TRAN=usb / diskutil external)
#   - never offers internal disks; user picks explicitly (no auto-pick)
#   - requires a typed ERASE/YES confirmation echoing the device id
#   - wipefs + MBR + single exFAT type 0x07, label CLAUDE
# We capture the chosen mount point into STICK.
# -----------------------------------------------------------------------------
STICK=""
select_and_format_usb() {
	step "$(t step_usb)"
	if [ "$HAVE_USB" != "1" ]; then
		die "$(t err_no_usb_helper)"
	fi

	# usb.sh contract (documented behaviours of §10). We try the richest
	# entrypoint first, then fall back to discrete functions.
	if command -v usb_select_and_format >/dev/null 2>&1; then
		# Expected to print the resulting mountpoint on stdout (and do all the
		# enumerate/confirm/format work itself, talking through t()).
		STICK=$(usb_select_and_format) || die "$(t err_usb_failed)"
	else
		# Discrete-function fallback matching the §10 sequence.
		local dev=""
		if command -v usb_enumerate >/dev/null 2>&1; then usb_enumerate >&2 || true; fi
		if command -v usb_select >/dev/null 2>&1; then
			dev=$(usb_select) || die "$(t err_usb_failed)"
		else
			prompt_into dev "$(t enter_usb_device)"
		fi
		[ -n "$dev" ] || die "$(t err_usb_none)"
		if command -v usb_confirm >/dev/null 2>&1; then
			usb_confirm "$dev" || die "$(t err_usb_aborted)"
		fi
		if command -v usb_format >/dev/null 2>&1; then
			STICK=$(usb_format "$dev") || die "$(t err_usb_failed)"
		else
			die "$(t err_no_usb_helper)"
		fi
	fi

	[ -n "$STICK" ] && [ -d "$STICK" ] || die "$(t err_usb_mount)"
	ok "$(t usb_ready): $STICK"
}

# -----------------------------------------------------------------------------
# STEP E - scaffold the stick directory layout (CONTRACTS §2)
# -----------------------------------------------------------------------------
scaffold_stick() {
	step "$(t step_scaffold)"
	mkdir -p \
		"$STICK/bin" \
		"$STICK/config" \
		"$STICK/projects" \
		"$STICK/tmp" \
		"$STICK/apps"
	ok "$(t scaffold_done)"
}

# -----------------------------------------------------------------------------
# STEP F - download + sha256-verify the Claude binary(ies) (CONTRACTS §8 + MULTI-OS)
#   GET /<channel> -> bare semver                                  (ONCE)
#   GET /<ver>/manifest.json -> platforms.<plat>.{binary,checksum,size}  (ONCE)
#   optional GPG verify of manifest.json.sig when gpg present (best-effort, ONCE)
#   For EACH platform in PLATS:
#     download /<ver>/<plat>/<binary> ; sha256 == checksum ; abort on mismatch
#     place at bin/<plat>/claude (posix) or bin/<plat>/claude.exe (windows)
#     chmod +x the posix ones.
#
# The per-platform subdir layout (bin/<plat>/...) is used for BOTH single- and
# multi-target builds so the on-stick path is uniform and the launchers can
# resolve CLAUDE_BIN the same way regardless of how the stick was built
# (delta point 3; the env.sh/env.bat resolver is the consumer of this layout).
# -----------------------------------------------------------------------------
DL_BASE="https://downloads.claude.ai/claude-code-releases"

# The dest filename for a given platform id (claude.exe on Windows, else claude).
plat_bin_name() {
	case "$1" in win32-*) printf 'claude.exe' ;; *) printf 'claude' ;; esac
}

# Download + sha256-verify ONE platform binary into bin/<plat>/.
# $1 = platform id, $2 = version, $3 = manifest json text.
# Aborts (die) on checksum mismatch (§8). Sets globals only for the PRIMARY
# platform (PLAT), so the token host-check + self-test know the host binary.
download_one_platform() {
	local plat=$1 ver=$2 manifest=$3
	local binname checksum size
	binname=$(json_get "$manifest" "platforms.$plat.binary")
	checksum=$(json_get "$manifest" "platforms.$plat.checksum")
	size=$(json_get "$manifest" "platforms.$plat.size")
	[ -n "$binname" ] && [ -n "$checksum" ] \
		|| die "$(t err_platform_missing): $plat"
	info "[$plat] $(t binary_name): $binname  ($(t expected_sha)=$checksum)"

	# download
	local bin_url="$DL_BASE/$ver/$plat/$binname"
	local bin_tmp="$WORK_TMP/$plat-$binname"
	info "[$plat] $(t downloading_binary) ($size bytes)"
	http_dl "$bin_url" "$bin_tmp" || die "$(t err_download_binary)"

	# sha256 verify - ABORT on mismatch
	info "[$plat] $(t verifying_sha)"
	local got; got=$(sha256_of "$bin_tmp")
	if [ "$got" != "$checksum" ]; then
		err "$(t sha_mismatch)"
		err "  expected: $checksum"
		err "  got:      $got"
		die "$(t err_sha_abort)"
	fi
	ok "[$plat] $(t sha_ok)"

	# place into the per-platform subdir: bin/<plat>/claude(.exe)
	local dest; dest=$(plat_bin_name "$plat")
	mkdir -p "$STICK/bin/$plat"
	cp "$bin_tmp" "$STICK/bin/$plat/$dest"
	# chmod only meaningful for the POSIX targets.
	case "$plat" in win32-*) : ;; *) chmod +x "$STICK/bin/$plat/$dest" 2>/dev/null || true ;; esac
	ok "[$plat] $(t claude_placed): bin/$plat/$dest"

	# Remember the host/primary platform's binary for setup-token + self-test.
	if [ "$plat" = "$PLAT" ]; then
		STICK_CLAUDE_BIN="$dest"
	fi
}

download_claude() {
	step "$(t step_download_claude)"
	# Re-use an existing WORK_TMP if a previous step created one; else make ours.
	if [ -z "${WORK_TMP:-}" ] || [ ! -d "${WORK_TMP:-}" ]; then
		WORK_TMP=$(mktemp -d 2>/dev/null || mktemp -d -t cstick)
	fi

	# 1) resolve version (ONCE, shared across all platforms)
	info "$(t resolving_version) ($CHANNEL)"
	local ver
	ver=$(http_get "$DL_BASE/$CHANNEL" | tr -d '[:space:]') \
		|| die "$(t err_resolve_version)"
	[ -n "$ver" ] || die "$(t err_resolve_version)"
	ok "$(t version_is): $ver"

	# 2) fetch manifest (ONCE)
	local manifest_url="$DL_BASE/$ver/manifest.json"
	local manifest_file="$WORK_TMP/manifest.json"
	http_dl "$manifest_url" "$manifest_file" || die "$(t err_manifest)"
	local manifest; manifest=$(cat "$manifest_file")

	# 2b) optional GPG verify of the manifest signature (best-effort, §8/§13; ONCE)
	if have gpg; then
		local sig_url="$manifest_url.sig" sig_file="$WORK_TMP/manifest.json.sig"
		if http_dl "$sig_url" "$sig_file" 2>/dev/null; then
			if gpg --verify "$sig_file" "$manifest_file" >/dev/null 2>&1; then
				ok "$(t gpg_ok)"
			else
				warn "$(t gpg_unverified)"  # best-effort: warn, don't abort
			fi
		else
			warn "$(t gpg_no_sig)"
		fi
	else
		info "$(t gpg_absent)"
	fi

	# 3) per-platform download loop. PLATS holds 1..N validated platform ids; for
	#    a single-target build it is just the host platform, so this loop runs
	#    exactly once and produces the same per-plat layout as the multi case.
	STICK_CLAUDE_BIN=""
	local _p
	for _p in $PLATS; do
		download_one_platform "$_p" "$ver" "$manifest"
	done

	# Safety net: if for some reason the primary wasn't in PLATS, adopt the first
	# built platform so downstream steps (token host-check, self-test) resolve.
	if [ -z "${STICK_CLAUDE_BIN:-}" ]; then
		PLAT=${PLATS%% *}
		STICK_CLAUDE_BIN=$(plat_bin_name "$PLAT")
	fi
}

# -----------------------------------------------------------------------------
# STEP G - auth token: run `claude setup-token`, encrypt to config/oauth.enc
# (CONTRACTS §4) - long-lived inference-only token; AES at rest.
# -----------------------------------------------------------------------------
setup_and_encrypt_token() {
	step "$(t step_token)"

	# Offer an explicit choice for how to provide the token. Option [2] runs
	# `claude setup-token` using a just-downloaded binary, but only when we can
	# run it here. With the per-platform bin/<plat>/ layout (single OR multi), we
	# locate THIS HOST's own platform binary on the stick - which exists only if
	# the host platform was among the selected targets - and use that to run
	# setup-token. Otherwise (cross-build only, or host platform not selected) we
	# can only accept a pasted token. The token + config are written ONCE here
	# regardless of how many platforms the stick targets.
	local token=""
	# Recompute THIS host's own Claude platform id (detect_platform stores it in
	# PLAT, but in a multi pick PLAT becomes the first *chosen* platform, which may
	# not be the host - so derive the host id independently here).
	local host_plat="" _save_plat="$PLAT"
	detect_platform        # sets PLAT = host platform id
	host_plat="$PLAT"
	PLAT="$_save_plat"     # restore the primary used elsewhere

	local host_runnable=0
	case "$host_plat" in
		linux-*) [ "$IS_MACOS" = "0" ] && host_runnable=1 ;;
		darwin-*) [ "$IS_MACOS" = "1" ] && host_runnable=1 ;;
	esac

	# The host binary on the stick lives at bin/<host_plat>/claude (posix).
	local host_bin
	host_bin="$STICK/bin/$host_plat/$(plat_bin_name "$host_plat")"

	# Only treat the host as runnable for [2] when the host's own binary was
	# actually built onto the stick and is executable here.
	local can_setup_token=0
	if [ "$host_runnable" = "1" ] && [ -x "$host_bin" ]; then
		can_setup_token=1
	fi

	# Print the menu and read the (non-sensitive) choice. Default to [2] when we
	# can run setup-token here; force [1] when cross-building.
	local choice
	say "$(t token_choice_prompt)"
	say "$(t token_choice_paste)"
	if [ "$can_setup_token" = "1" ]; then
		say "$(t token_choice_new)"
		printf '%s ' "$(t token_choice_ask)" >&2
		# guard against set -e / EOF: never let a closed stdin abort the build.
		read -r choice || true
		[ -n "$choice" ] || choice=2
	else
		info "$(t setup_token_cross)"  # cross-building: cannot run target binary here
		choice=1
	fi

	if [ "$choice" = "2" ]; then
		info "$(t running_setup_token)"
		# `claude setup-token` is interactive (opens browser / device flow).
		# It MUST run with the console FULLY INHERITED - capturing its stdout
		# (e.g. `token=$("$host_bin" setup-token)`) breaks the OAuth flow: the
		# browser login completes but the process hangs forever because the
		# redirected pipe never lets it finish printing. So we let it write
		# straight to the terminal exactly as a manual run does. On success it
		# PRINTS the long-lived token here; the user copies it and pastes it at
		# the masked prompt below (same paste path as choice [1]).
		warn "$(t setup_token_launch_hint)"
		printf '\n' >&2
		set +e
		"$host_bin" setup-token   # NO command substitution - fully inherited
		set -e
		printf '\n' >&2
		prompt_into token "$(t paste_token)" mask
		if [ -z "$token" ]; then
			warn "$(t setup_token_capture_failed)"
			token=""
		fi
	fi

	# Manual paste path: explicit choice [1], any other input, or a setup-token
	# capture that failed / produced nothing.
	if [ -z "$token" ]; then
		say "$(t setup_token_manual_hint)"
		prompt_into token "$(t paste_token)" mask
	fi
	[ -n "$token" ] || die "$(t err_no_token)"

	# Password to protect the token at rest (prompted twice, masked).
	local pw pw2
	while :; do
		prompt_into pw  "$(t stick_password_set)" mask
		prompt_into pw2 "$(t stick_password_confirm)" mask
		[ -n "$pw" ] || { warn "$(t password_empty)"; continue; }
		[ "$pw" = "$pw2" ] && break
		warn "$(t password_mismatch)"
	done

	# Encrypt -> config/oauth.enc using shared/crypto.sh (salt|iv|ct, PBKDF2-
	# HMAC-SHA1 300k, AES-256-CBC PKCS7) - CONTRACTS §4. Token flows via stdin so
	# it never lands in argv / process list.
	local enc_out="$STICK/config/oauth.enc"
	if [ "$HAVE_CRYPTO" = "1" ] && command -v cas_encrypt >/dev/null 2>&1; then
		# cas_encrypt <password> <outfile>  (plaintext token on stdin)
		printf '%s' "$token" | cas_encrypt "$pw" "$enc_out" \
			|| die "$(t err_encrypt)"
	else
		die "$(t err_no_crypto_helper)"
	fi

	# Lock down perms (token at rest, even if encrypted) - POSIX stick targets.
	chmod 600 "$enc_out" 2>/dev/null || true

	# Scrub the plaintext token from this shell's memory.
	token=""; pw=""; pw2=""
	unset token pw pw2

	[ -s "$enc_out" ] || die "$(t err_encrypt_empty)"
	ok "$(t token_encrypted): config/oauth.enc"
}

# -----------------------------------------------------------------------------
# STEP H - optional Happ VPN bundle + subscription deep-link insert
# (CONTRACTS §6, §7 + MULTI-OS) - proxy mode only, never TUN. Best-effort sub insert.
#
# Happ binaries are OS-specific and ~300MB each, so for a MULTI-OS stick VPN
# bundling stays OPTIONAL and defaults to OFF (rely on the host/system VPN; the
# geoguard "no apps/happ -> host VPN" fallback still governs). If the user opts
# in for a multi build, each selected OS gets its own apps/happ-<os>/ tree and a
# multi-OS-aware vpnup resolves the right one per running OS. A SINGLE-target
# build keeps the historical apps/happ/ path so existing launchers are unchanged.
# (Windows-only Happ is handled by build.ps1; this builder bundles linux/mac.)
# -----------------------------------------------------------------------------

# Map a Claude platform id -> happ OS / arch tokens used by happ.sh.
plat_happ_os()   { case "$1" in darwin-*) printf 'mac' ;; *) printf 'linux' ;; esac; }
plat_happ_arch() { case "$1" in *arm64*) printf 'arm64' ;; *) printf 'x64' ;; esac; }

# Bundle Happ for one OS into <dst_dir>, then offer the (single) subscription
# insert against it. $1 = happ os (linux|mac), $2 = happ arch, $3 = dst dir,
# $4 = subscription string ("" to skip). Returns 0 on success (or graceful skip).
bundle_happ_into() {
	local happ_os=$1 happ_arch=$2 dst=$3 sub=$4
	if command -v happ_download >/dev/null 2>&1 && command -v happ_portableize >/dev/null 2>&1; then
		local happ_asset
		happ_asset=$(happ_download "$happ_os" "$happ_arch" "$WORK_TMP") \
			|| { warn "$(t happ_download_failed) [$happ_os]"; return 1; }
		happ_portableize "$happ_os" "$happ_asset" "$dst" \
			|| { warn "$(t happ_download_failed) [$happ_os]"; return 1; }
		if command -v happ_write_runner >/dev/null 2>&1; then
			happ_write_runner "$happ_os" "$dst" >/dev/null || true
		fi
	else
		warn "$(t err_no_happ_helper)"
		return 1
	fi
	ok "$(t happ_bundled) [$happ_os] -> ${dst#"$STICK"/}"

	# Subscription deep-link (accept exactly as pasted - CONTRACTS §-locked).
	if [ -n "$sub" ] && command -v happ_insert_sub >/dev/null 2>&1; then
		if happ_insert_sub "$happ_os" "$dst" "$sub"; then
			ok "$(t sub_inserted) [$happ_os]"
		else
			warn "$(t sub_insert_failed) [$happ_os]"
			if command -v _happ_build_deeplink >/dev/null 2>&1; then
				say "$(t sub_manual_link):"
				say "  $(_happ_build_deeplink "$sub")"
			fi
		fi
	fi
	return 0
}

maybe_bundle_happ() {
	step "$(t step_happ)"

	# How many platforms? Drives single (apps/happ) vs multi (apps/happ-<os>).
	local n=0 _p
	for _p in $PLATS; do n=$((n + 1)); done

	if ! confirm "$(t ask_bundle_happ)" n; then
		info "$(t happ_skipped)"
		return 0
	fi
	if [ "$HAVE_HAPP" != "1" ]; then
		warn "$(t err_no_happ_helper)"
		return 0
	fi

	# One subscription string for the whole stick (asked once).
	local sub=""
	if confirm "$(t ask_insert_sub)" y; then
		prompt_into sub "$(t paste_sub)"
	fi

	if [ "$n" -le 1 ]; then
		# ---- single-target: historical apps/happ/ layout (launchers unchanged) --
		local happ_os happ_arch
		happ_os=$(plat_happ_os "$PLAT")
		happ_arch=$(plat_happ_arch "$PLAT")
		bundle_happ_into "$happ_os" "$happ_arch" "$STICK/apps/happ" "$sub" || true
		return 0
	fi

	# ---- multi-OS: one apps/happ-<os>/ tree per selected linux/mac OS ------------
	# Collapse the selected platforms down to the distinct happ OS families this
	# builder can bundle (linux + mac). Windows Happ is build.ps1's job; we note
	# it so the user isn't surprised that a win32 target has no bundled Happ here.
	local os_set="" saw_win=0
	for _p in $PLATS; do
		case "$_p" in
			win32-*) saw_win=1; continue ;;
		esac
		local os; os=$(plat_happ_os "$_p")
		case " $os_set " in *" $os "*) ;; *) os_set="$os_set $os" ;; esac
	done
	os_set=${os_set# }

	if [ "$saw_win" = "1" ]; then
		local _lang="${LANG_CODE:-${I18N_LANG:-en}}"
		case "$_lang" in
			ru) warn "  (Happ для Windows бандлится сборщиком build.ps1, не здесь.)" ;;
			*)  warn "  (Windows Happ is bundled by build.ps1, not here.)" ;;
		esac
	fi

	local os
	for os in $os_set; do
		# Pick a representative arch for this OS from the selected platforms
		# (prefer arm64 for mac, x64 otherwise - matches the common set defaults).
		local arch="x64"
		case "$os" in
			mac) arch="arm64" ;;
		esac
		# If the user explicitly chose only an arm64 linux, honour it.
		for _p in $PLATS; do
			[ "$(plat_happ_os "$_p")" = "$os" ] || continue
			arch=$(plat_happ_arch "$_p")
		done
		bundle_happ_into "$os" "$arch" "$STICK/apps/happ-$os" "$sub" || true
	done
}

# -----------------------------------------------------------------------------
# STEP I - geo-guard: smart-skip suggestion + write geoguard.conf (CONTRACTS §5)
# We detect the *current* exit country (direct, no proxy) and, if it is NOT in
# the blocklist, suggest disabling the guard (GUARD_ENABLED=0) - that is the
# user's whole point: don't touch the VPN in an unrestricted region.
# -----------------------------------------------------------------------------
GUARD_ENABLED=1
BLOCKLIST="RU,BY,CU,IR,KP,SY"
INCONCLUSIVE="prompt"

detect_exit_country() {
	# Direct (no proxy). cloudflare trace -> ipinfo -> country.is. Empty if all fail.
	local loc=""
	loc=$(http_get "https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null \
		| sed -n 's/^loc=//p' | head -n1 || true)
	if [ -z "$loc" ]; then
		loc=$(http_get "https://ipinfo.io/country" 2>/dev/null | tr -d '[:space:]' || true)
	fi
	if [ -z "$loc" ]; then
		loc=$(http_get "https://api.country.is" 2>/dev/null \
			| json_get "$(cat)" "country" 2>/dev/null || true)
		# api.country.is returns {"ip":..,"country":"XX"}; reparse cleanly:
		loc=$(http_get "https://api.country.is" 2>/dev/null \
			| grep -oE '"country"[[:space:]]*:[[:space:]]*"[A-Z]{2}"' \
			| grep -oE '[A-Z]{2}' | head -n1 || true)
	fi
	printf '%s' "$loc"
}

write_geoguard() {
	step "$(t step_geoguard)"

	# Smart-skip: probe the current exit country.
	info "$(t probing_country)"
	local cc; cc=$(detect_exit_country)
	if [ -n "$cc" ]; then
		info "$(t exit_country_is): ${C_BOLD}$cc${C_RESET}"
		# Is it blocked?
		case ",$BLOCKLIST," in
			*",$cc,"*)
				warn "$(t country_blocked_here)"
				# Keep the guard on; user clearly needs the VPN path.
				GUARD_ENABLED=1
				;;
			*)
				# Unrestricted region - suggest the smart skip.
				if confirm "$(t ask_smart_skip)" y; then
					GUARD_ENABLED=0
					ok "$(t guard_disabled_smart)"
				else
					GUARD_ENABLED=1
				fi
				;;
		esac
	else
		warn "$(t country_unknown)"
		# Could not determine; leave the guard on (safe default).
		GUARD_ENABLED=1
	fi

	# Allow the user to fine-tune the blocklist / inconclusive policy.
	if confirm "$(t ask_edit_blocklist)" n; then
		local bl; prompt_into bl "$(t enter_blocklist) [$BLOCKLIST]"
		[ -n "$bl" ] && BLOCKLIST="$bl"
		say "$(t inconclusive_choices): prompt | block | allow"
		local ic; prompt_into ic "$(t enter_inconclusive) [$INCONCLUSIVE]"
		case "${ic:-}" in prompt|block|allow) INCONCLUSIVE="$ic" ;; esac
	fi

	# Write geoguard.conf onto the stick (consumed by geoguard.sh / .ps1).
	cat > "$STICK/geoguard.conf" <<EOF
# geoguard.conf - anti-ban exit-country guard (CONTRACTS §5)
# GUARD_ENABLED=0 -> return OK immediately (unrestricted region; smart-skip).
GUARD_ENABLED=$GUARD_ENABLED
# Comma-separated ISO country codes that must NOT be the exit country.
BLOCKLIST=$BLOCKLIST
# What to do when the country can't be determined: prompt | block | allow
INCONCLUSIVE=$INCONCLUSIVE
EOF
	ok "$(t geoguard_written): geoguard.conf (GUARD_ENABLED=$GUARD_ENABLED)"
}

# -----------------------------------------------------------------------------
# STEP J - copy payload launchers, templating MODEL + language (CONTRACTS §3 + MULTI-OS)
# Launcher UNION (delta point 4): a multi-OS stick carries BOTH launcher sets so
# the SAME stick boots on every targeted OS.
#   - Copy the WINDOWS set if ANY win32-* target was chosen:
#       START.bat DIAG.bat env.bat vpnup.bat geoguard.bat geoguard.ps1
#       decrypt.ps1 run-happ.bat
#   - Copy the POSIX set if ANY linux/darwin target was chosen:
#       start.sh diag.sh env.sh vpnup.sh geoguard.sh decrypt.sh run-happ.sh
#   - geoguard.conf (already written by write_geoguard) + README-STICK.txt: ALWAYS.
# A single-target build copies exactly one set, so it is byte-for-byte the same
# behaviour as before. Templating replaces __MODEL__ / __LANG__ in each file.
# run-happ.{sh,bat} live under apps/happ(-os)/ (they self-locate two levels up),
# so they are routed there - and only when a matching apps/happ tree exists -
# rather than to the stick root, which would break their self-location.
# -----------------------------------------------------------------------------
LANG_FOR_STICK=""

# Copy one templated payload file to a destination path. $1=basename $2=destpath.
_copy_one_payload() {
	local f=$1 dst=$2 src="$PAYLOAD_DIR/$1"
	if [ ! -f "$src" ]; then
		warn "$(t payload_missing): $f"
		return 0
	fi
	# Template MODEL + LANG. Tokens MUST match the payload files and the Windows
	# builder, which both use __MODEL__ / __LANG__ (not @@…@@).
	sed \
		-e "s|__MODEL__|$MODEL|g" \
		-e "s|__LANG__|$LANG_FOR_STICK|g" \
		"$src" > "$dst"
	case "$f" in *.sh) chmod +x "$dst" 2>/dev/null || true ;; esac
}

copy_payload() {
	step "$(t step_payload)"
	[ -d "$PAYLOAD_DIR" ] || die "$(t err_no_payload): $PAYLOAD_DIR"

	# Resolve the language code we baked in.
	LANG_FOR_STICK="${LANG_CODE:-en}"

	# Decide which launcher families to include from the FULL target list.
	local want_win=0 want_posix=0 _p
	for _p in $PLATS; do
		case "$_p" in
			win32-*) want_win=1 ;;
			*)       want_posix=1 ;;
		esac
	done

	# Root-level launcher sets (run-happ.* are handled separately below).
	local f
	if [ "$want_win" = "1" ]; then
		for f in START.bat DIAG.bat env.bat vpnup.bat geoguard.bat geoguard.ps1 decrypt.ps1; do
			_copy_one_payload "$f" "$STICK/$f"
		done
	fi
	if [ "$want_posix" = "1" ]; then
		for f in start.sh diag.sh env.sh vpnup.sh geoguard.sh decrypt.sh; do
			_copy_one_payload "$f" "$STICK/$f"
		done
	fi

	# Always present (delta point 4): README-STICK.txt. (geoguard.conf was already
	# written by write_geoguard, so it is intentionally not re-copied here.)
	_copy_one_payload README-STICK.txt "$STICK/README-STICK.txt"

	# run-happ wrappers belong inside each Happ tree (they self-locate to
	# .../apps/happ as the stick root two levels up). The Happ-bundling step
	# generates them via happ_write_runner when Happ is actually bundled; here we
	# additionally ensure the relevant template lands in any existing apps/happ*
	# dir so the union set is complete even if a future helper relied on it.
	local d
	for d in "$STICK"/apps/happ "$STICK"/apps/happ-*; do
		[ -d "$d" ] || continue
		if [ "$want_posix" = "1" ] && [ ! -e "$d/run-happ.sh" ]; then
			_copy_one_payload run-happ.sh "$d/run-happ.sh"
		fi
		if [ "$want_win" = "1" ] && [ ! -e "$d/run-happ.bat" ]; then
			_copy_one_payload run-happ.bat "$d/run-happ.bat"
		fi
	done

	ok "$(t payload_copied)"
}

# -----------------------------------------------------------------------------
# STEP K - final self-test (CONTRACTS §3 launcher chain sanity)
# Non-destructive checks that the produced stick is internally consistent.
# -----------------------------------------------------------------------------
self_test() {
	step "$(t step_selftest)"
	local fail=0

	# 1) binary present per platform at the uniform bin/<plat>/claude(.exe) path.
	#    For a single-target build this is one entry; for multi, one per target.
	local _p _bn _cbin
	for _p in $PLATS; do
		_bn=$(plat_bin_name "$_p")
		_cbin="$STICK/bin/$_p/$_bn"
		if [ -s "$_cbin" ]; then
			ok "  [ok] bin/$_p/$_bn"
			# Posix targets must be executable.
			case "$_p" in
				win32-*) : ;;
				*) [ -x "$_cbin" ] || { err "  [FAIL] bin/$_p/$_bn not executable"; fail=1; } ;;
			esac
		else
			err "  [FAIL] $(t test_no_binary): bin/$_p/$_bn"; fail=1
		fi
	done

	# 2) encrypted token present + correctly sized (>= salt16+iv16+1 block16)
	local enc="$STICK/config/oauth.enc"
	if [ -s "$enc" ]; then
		local sz
		sz=$(wc -c < "$enc" 2>/dev/null | tr -d '[:space:]')
		if [ "${sz:-0}" -ge 48 ]; then
			ok "  [ok] config/oauth.enc ($sz $(t bytes))"
		else
			err "  [FAIL] $(t test_enc_small) ($sz)"; fail=1
		fi
	else
		err "  [FAIL] $(t test_no_enc)"; fail=1
	fi

	# 3) geoguard.conf present + has GUARD_ENABLED
	if grep -q '^GUARD_ENABLED=' "$STICK/geoguard.conf" 2>/dev/null; then
		ok "  [ok] geoguard.conf"
	else
		err "  [FAIL] $(t test_no_geoconf)"; fail=1
	fi

	# 4) launchers present for EVERY targeted OS family (union). A stick that
	#    targets Windows must carry START.bat; one that targets linux/mac must
	#    carry start.sh; a multi-OS stick carries both.
	local want_win=0 want_posix=0
	for _p in $PLATS; do
		case "$_p" in win32-*) want_win=1 ;; *) want_posix=1 ;; esac
	done
	local launcher launchers=""
	[ "$want_win" = "1" ]   && launchers="$launchers START.bat"
	[ "$want_posix" = "1" ] && launchers="$launchers start.sh"
	for launcher in $launchers; do
		if [ -s "$STICK/$launcher" ]; then
			ok "  [ok] $launcher"
			# bash-syntax check the .sh launchers (best-effort).
			case "$launcher" in
				*.sh) if bash -n "$STICK/$launcher" 2>/dev/null; then
						ok "  [ok] $(t test_launcher_syntax)"
					else
						warn "  [warn] $(t test_launcher_syntax_bad)"
					fi ;;
			esac
		else
			err "  [FAIL] $(t test_no_launcher): $launcher"; fail=1
		fi
	done

	# 5) required dirs
	local d
	for d in bin config projects tmp; do
		[ -d "$STICK/$d" ] || { err "  [FAIL] $(t test_no_dir): $d/"; fail=1; }
	done

	# 6) optional VPN bundle sanity (single apps/happ or multi apps/happ-<os>).
	for d in "$STICK"/apps/happ "$STICK"/apps/happ-*; do
		[ -d "$d" ] || continue
		ok "  [ok] ${d#"$STICK"/} ($(t test_happ_present))"
	done

	hr
	if [ "$fail" -eq 0 ]; then
		ok "$(t selftest_pass)"
	else
		err "$(t selftest_fail)"
		return 1
	fi
}

# -----------------------------------------------------------------------------
# Final summary
# -----------------------------------------------------------------------------
print_summary() {
	hr
	ok "$(t build_complete)"
	say ""
	say "  $(t summary_stick):    $STICK"
	# Single -> "platform", multi -> the full list (one stick, any OS).
	local n=0 _p
	for _p in $PLATS; do n=$((n + 1)); done
	if [ "$n" -gt 1 ]; then
		say "  $(t summary_platform): [$PLATS] ($CHANNEL)"
	else
		say "  $(t summary_platform): $PLAT ($CHANNEL)"
	fi
	say "  $(t summary_model):    $MODEL"
	say "  $(t summary_lang):     ${LANG_FOR_STICK:-${LANG_CODE:-en}}"
	say "  $(t summary_guard):    GUARD_ENABLED=$GUARD_ENABLED  BLOCKLIST=$BLOCKLIST"
	# VPN: single apps/happ or one-or-more apps/happ-<os>.
	local vpn_dirs="" d
	for d in "$STICK"/apps/happ "$STICK"/apps/happ-*; do
		[ -d "$d" ] || continue
		vpn_dirs="$vpn_dirs ${d#"$STICK"/}"
	done
	if [ -n "$vpn_dirs" ]; then
		say "  $(t summary_vpn):     $vpn_dirs ($(t bundled))"
	else
		say "  $(t summary_vpn):      -"
	fi
	say ""
	# Tell the user how to launch on each targeted OS family.
	local want_win=0 want_posix=0
	for _p in $PLATS; do
		case "$_p" in win32-*) want_win=1 ;; *) want_posix=1 ;; esac
	done
	[ "$want_win" = "1" ]   && say "  $(t summary_run_win)"
	[ "$want_posix" = "1" ] && say "  $(t summary_run_posix): $STICK/start.sh"
	hr
}

# =============================================================================
main() {
	print_banner
	choose_language          # STEP A - language FIRST
	print_macos_notice        # macOS experimental notice (after language)
	choose_channel_and_target # STEP B - channel + target platform(s) (multi-OS)
	choose_model             # STEP C - model baked into launcher
	select_and_format_usb    # STEP D - pick + confirm + format USB ONCE (DANGEROUS)
	scaffold_stick           # STEP E - stick layout
	download_claude          # STEP F - download + sha256-verify Claude (per platform)
	setup_and_encrypt_token  # STEP G - setup-token + AES -> oauth.enc
	maybe_bundle_happ        # STEP H - optional Happ VPN + sub deep-link
	write_geoguard           # STEP I - geo smart-skip + geoguard.conf
	copy_payload             # STEP J - payload launchers (templated)
	self_test                # STEP K - final self-test
	print_summary
}

main "$@"
