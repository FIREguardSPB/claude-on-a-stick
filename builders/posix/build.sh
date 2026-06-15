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

# Parse a string JSON value for a flat key path "a.b.c" without jq.
# Pragmatic (the Claude manifest is small + flat enough). $1=json $2=dotpath
json_get() {
	if have jq; then
		printf '%s' "$1" | jq -r ".$2 // empty" 2>/dev/null && return 0
	fi
	# jq-less fallback: grab the last path segment as a "key": value pair.
	local leaf=${2##*.}
	printf '%s' "$1" \
		| tr -d '\n' \
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
# STEP B - release channel / target platform (CONTRACTS §8, §13)
# Channel default: stable. Target platform: auto-detected, user-confirmable.
# -----------------------------------------------------------------------------
CHANNEL="stable"
PLAT=""

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

choose_channel_and_target() {
	step "$(t step_channel)"
	# Channel
	if confirm "$(t ask_channel_latest)" n; then
		CHANNEL="latest"
	else
		CHANNEL="stable"
	fi
	# Target platform (auto + confirm/override)
	detect_platform
	info "$(t detected_platform): ${C_BOLD}$PLAT${C_RESET}"
	if ! confirm "$(t ask_platform_ok)" y; then
		say "$(t platform_choices):"
		say "  win32-x64  win32-arm64  darwin-x64  darwin-arm64"
		say "  linux-x64  linux-arm64  linux-x64-musl  linux-arm64-musl"
		local p; prompt_into p "$(t enter_platform)"
		[ -n "$p" ] && PLAT="$p"
	fi
	ok "$(t channel_target_set): channel=$CHANNEL platform=$PLAT"
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
# STEP F - download + sha256-verify the Claude binary (CONTRACTS §8)  [VERIFIED]
#   GET /<channel> -> bare semver
#   GET /<ver>/manifest.json -> platforms.<plat>.{binary,checksum,size}
#   optional GPG verify of manifest.json.sig when gpg present (best-effort)
#   download /<ver>/<plat>/<binary> ; sha256 == checksum ; abort on mismatch
# -----------------------------------------------------------------------------
DL_BASE="https://downloads.claude.ai/claude-code-releases"
download_claude() {
	step "$(t step_download_claude)"
	WORK_TMP=$(mktemp -d 2>/dev/null || mktemp -d -t cstick)

	# 1) resolve version
	info "$(t resolving_version) ($CHANNEL)"
	local ver
	ver=$(http_get "$DL_BASE/$CHANNEL" | tr -d '[:space:]') \
		|| die "$(t err_resolve_version)"
	[ -n "$ver" ] || die "$(t err_resolve_version)"
	ok "$(t version_is): $ver"

	# 2) fetch manifest
	local manifest_url="$DL_BASE/$ver/manifest.json"
	local manifest_file="$WORK_TMP/manifest.json"
	http_dl "$manifest_url" "$manifest_file" || die "$(t err_manifest)"
	local manifest; manifest=$(cat "$manifest_file")

	# 2b) optional GPG verify of the manifest signature (best-effort, §8/§13)
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

	# 3) pull this platform's entry
	local binname checksum size
	binname=$(json_get "$manifest" "platforms.$PLAT.binary")
	checksum=$(json_get "$manifest" "platforms.$PLAT.checksum")
	size=$(json_get "$manifest" "platforms.$PLAT.size")
	[ -n "$binname" ] && [ -n "$checksum" ] \
		|| die "$(t err_platform_missing): $PLAT"
	info "$(t binary_name): $binname  ($(t expected_sha)=$checksum)"

	# 4) download the binary
	local bin_url="$DL_BASE/$ver/$PLAT/$binname"
	local bin_tmp="$WORK_TMP/$binname"
	info "$(t downloading_binary) ($size bytes)"
	http_dl "$bin_url" "$bin_tmp" || die "$(t err_download_binary)"

	# 5) sha256 verify - ABORT on mismatch
	info "$(t verifying_sha)"
	local got; got=$(sha256_of "$bin_tmp")
	if [ "$got" != "$checksum" ]; then
		err "$(t sha_mismatch)"
		err "  expected: $checksum"
		err "  got:      $got"
		die "$(t err_sha_abort)"
	fi
	ok "$(t sha_ok)"

	# 6) place onto the stick. Windows target keeps claude.exe; else claude.
	local dest="claude"
	case "$PLAT" in win32-*) dest="claude.exe" ;; esac
	cp "$bin_tmp" "$STICK/bin/$dest"
	# chmod only meaningful for the POSIX targets.
	case "$PLAT" in win32-*) : ;; *) chmod +x "$STICK/bin/$dest" 2>/dev/null || true ;; esac
	ok "$(t claude_placed): bin/$dest"

	# Stash for the self-test / launcher templating.
	STICK_CLAUDE_BIN="$dest"
}

# -----------------------------------------------------------------------------
# STEP G - auth token: run `claude setup-token`, encrypt to config/oauth.enc
# (CONTRACTS §4) - long-lived inference-only token; AES at rest.
# -----------------------------------------------------------------------------
setup_and_encrypt_token() {
	step "$(t step_token)"

	# Offer an explicit choice for how to provide the token. Option [2] runs
	# `claude setup-token` using the just-downloaded binary, but only when we can
	# run it here (i.e. the stick target matches this host); otherwise we can only
	# accept a pasted token.
	local token=""
	local host_runnable=0
	case "$PLAT" in
		linux-*) [ "$IS_MACOS" = "0" ] && host_runnable=1 ;;
		darwin-*) [ "$IS_MACOS" = "1" ] && host_runnable=1 ;;
	esac

	# Only treat the host as runnable for [2] when the target binary is present
	# and executable here.
	local can_setup_token=0
	if [ "$host_runnable" = "1" ] && [ -x "$STICK/bin/${STICK_CLAUDE_BIN:-claude}" ]; then
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
		# `claude setup-token` is interactive (opens browser / device flow) and
		# prints the long-lived token. We capture stdout and strip CR/LF, falling
		# back to manual paste if capture fails.
		set +e
		token=$("$STICK/bin/${STICK_CLAUDE_BIN:-claude}" setup-token 2>/dev/null | tr -d '\r\n')
		local rc=$?
		set -e
		if [ "$rc" -ne 0 ] || [ -z "$token" ]; then
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
# (CONTRACTS §6, §7) - proxy mode only, never TUN. Best-effort sub insert.
# -----------------------------------------------------------------------------
maybe_bundle_happ() {
	step "$(t step_happ)"
	if ! confirm "$(t ask_bundle_happ)" n; then
		info "$(t happ_skipped)"
		return 0
	fi
	if [ "$HAVE_HAPP" != "1" ]; then
		warn "$(t err_no_happ_helper)"
		return 0
	fi

	# happ.sh works in terms of (os, arch), not the Claude PLAT id. Map our
	# detected PLAT (e.g. linux-x64, darwin-arm64, linux-x64-musl) accordingly.
	local happ_os happ_arch
	case "$PLAT" in
		darwin-*) happ_os="mac" ;;
		*)        happ_os="linux" ;;
	esac
	case "$PLAT" in
		*arm64*) happ_arch="arm64" ;;
		*)       happ_arch="x64" ;;
	esac

	# Download + portable-ize Happ for the target platform onto apps/happ.
	# happ.sh handles per-OS portable-ize (Linux .deb relocate / mac .dmg) and
	# writes the run-happ.sh config-redirect wrapper.
	if command -v happ_download >/dev/null 2>&1 && command -v happ_portableize >/dev/null 2>&1; then
		local happ_asset
		happ_asset=$(happ_download "$happ_os" "$happ_arch" "$WORK_TMP") \
			|| { warn "$(t happ_download_failed)"; return 0; }
		happ_portableize "$happ_os" "$happ_asset" "$STICK/apps/happ" \
			|| { warn "$(t happ_download_failed)"; return 0; }
		if command -v happ_write_runner >/dev/null 2>&1; then
			happ_write_runner "$happ_os" "$STICK/apps/happ" >/dev/null || true
		fi
	else
		warn "$(t err_no_happ_helper)"
		return 0
	fi
	ok "$(t happ_bundled)"

	# Subscription link: accept exactly as the user pastes it (CONTRACTS §-locked).
	#   raw sub URL   -> happ://add/<urlencoded>
	#   ready happ:// -> verbatim
	# happ.sh owns url-encoding + the deep-link forward to the running instance.
	if confirm "$(t ask_insert_sub)" y; then
		local sub
		prompt_into sub "$(t paste_sub)"
		if [ -n "$sub" ]; then
			if command -v happ_insert_sub >/dev/null 2>&1; then
				if happ_insert_sub "$happ_os" "$STICK/apps/happ" "$sub"; then
					ok "$(t sub_inserted)"
				else
					# Best-effort: print the deep link for manual import (§7).
					warn "$(t sub_insert_failed)"
					if command -v _happ_build_deeplink >/dev/null 2>&1; then
						say "$(t sub_manual_link):"
						say "  $(_happ_build_deeplink "$sub")"
					fi
				fi
			else
				warn "$(t err_no_happ_helper)"
			fi
		fi
	fi
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
# STEP J - copy payload launchers, templating MODEL + language (CONTRACTS §3)
# We only copy the launchers relevant to the target OS family, plus the shared
# geoguard.conf is already written. Templating replaces:
#   __MODEL__  -> chosen model
#   __LANG__   -> chosen language code
# in each launcher. (Payload files use these tokens per the payload contract.)
# -----------------------------------------------------------------------------
LANG_FOR_STICK=""
copy_payload() {
	step "$(t step_payload)"
	[ -d "$PAYLOAD_DIR" ] || die "$(t err_no_payload): $PAYLOAD_DIR"

	# Resolve the language code we baked in.
	LANG_FOR_STICK="${LANG_CODE:-en}"

	# Which launchers does this target need?
	#   win32-* -> .bat + geoguard.ps1 + decrypt.ps1
	#   else    -> .sh  + geoguard.sh  + decrypt.sh
	local files=""
	case "$PLAT" in
		win32-*)
			files="START.bat DIAG.bat env.bat vpnup.bat geoguard.bat geoguard.ps1 decrypt.ps1 README-STICK.txt"
			;;
		*)
			files="start.sh diag.sh env.sh vpnup.sh geoguard.sh decrypt.sh README-STICK.txt"
			;;
	esac

	local f src dst
	for f in $files; do
		src="$PAYLOAD_DIR/$f"
		dst="$STICK/$f"
		if [ ! -f "$src" ]; then
			warn "$(t payload_missing): $f"
			continue
		fi
		# Template MODEL + LANG. Tokens MUST match the payload files and the
		# Windows builder, which both use __MODEL__ / __LANG__ (not @@…@@).
		sed \
			-e "s|__MODEL__|$MODEL|g" \
			-e "s|__LANG__|$LANG_FOR_STICK|g" \
			"$src" > "$dst"
		# Make POSIX launchers executable.
		case "$f" in *.sh) chmod +x "$dst" 2>/dev/null || true ;; esac
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

	# 1) binary present + (for POSIX targets) executable
	local cbin="$STICK/bin/${STICK_CLAUDE_BIN:-claude}"
	if [ -s "$cbin" ]; then
		ok "  [ok] bin/${STICK_CLAUDE_BIN:-claude}"
	else
		err "  [FAIL] $(t test_no_binary)"; fail=1
	fi

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

	# 4) launchers present for this OS family
	local launcher
	case "$PLAT" in
		win32-*) launcher="START.bat" ;;
		*)       launcher="start.sh" ;;
	esac
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

	# 5) required dirs
	local d
	for d in bin config projects tmp; do
		[ -d "$STICK/$d" ] || { err "  [FAIL] $(t test_no_dir): $d/"; fail=1; }
	done

	# 6) optional VPN bundle sanity
	if [ -d "$STICK/apps/happ" ]; then
		ok "  [ok] apps/happ ($(t test_happ_present))"
	fi

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
	say "  $(t summary_platform): $PLAT ($CHANNEL)"
	say "  $(t summary_model):    $MODEL"
	say "  $(t summary_lang):     ${LANG_FOR_STICK:-${LANG_CODE:-en}}"
	say "  $(t summary_guard):    GUARD_ENABLED=$GUARD_ENABLED  BLOCKLIST=$BLOCKLIST"
	if [ -d "$STICK/apps/happ" ]; then
		say "  $(t summary_vpn):      apps/happ ($(t bundled))"
	else
		say "  $(t summary_vpn):      -"
	fi
	say ""
	case "$PLAT" in
		win32-*) say "  $(t summary_run_win)" ;;
		*)       say "  $(t summary_run_posix): $STICK/start.sh" ;;
	esac
	hr
}

# =============================================================================
main() {
	print_banner
	choose_language          # STEP A - language FIRST
	print_macos_notice        # macOS experimental notice (after language)
	choose_channel_and_target # STEP B - channel + target platform
	choose_model             # STEP C - model baked into launcher
	select_and_format_usb    # STEP D - pick + confirm + format USB (DANGEROUS)
	scaffold_stick           # STEP E - stick layout
	download_claude          # STEP F - download + sha256-verify Claude
	setup_and_encrypt_token  # STEP G - setup-token + AES -> oauth.enc
	maybe_bundle_happ        # STEP H - optional Happ VPN + sub deep-link
	write_geoguard           # STEP I - geo smart-skip + geoguard.conf
	copy_payload             # STEP J - payload launchers (templated)
	self_test                # STEP K - final self-test
	print_summary
}

main "$@"
