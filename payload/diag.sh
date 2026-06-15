#!/usr/bin/env bash
# diag.sh - non-destructive health check for claude-on-a-stick (POSIX side).
# Mirrors DIAG.bat. Does NOT launch Claude and does NOT prompt for the password.
#
# Reports, with PASS/WARN/FAIL markers:
#   - stick layout (resolved per-OS/arch bin, config/oauth.enc, settings, decrypt.sh)
#   - required CLI tools (curl, openssl/perl for decrypt)
#   - geoguard config + DIRECT exit-country detection (no proxy, no VPN touched)
#   - bundled Happ presence + live proxy-port probe (if apps/happ exists)
# Always exits 0 (it's a report); problems are shown inline.
set -u  # not -e: we want to run every check even if one fails.

STICK="$(cd "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
export STICK

# Self-contained launcher i18n: t <ns> <key> '<literal default>'. We do NOT
# source shared/i18n.sh (different t() signature + key scheme would shadow this
# and leak <<key>> sentinels). diag.sh runs the same with or without it present.
if ! command -v t >/dev/null 2>&1; then
  t() { shift 2>/dev/null || true; shift 2>/dev/null || true; printf '%s' "${*:-}"; }
fi

PASS="[PASS]"; WARN="[WARN]"; FAIL="[FAIL]"

ok()   { printf '%s %s\n' "$PASS" "$1"; }
warn() { printf '%s %s\n' "$WARN" "$1"; }
fail() { printf '%s %s\n' "$FAIL" "$1"; }

# Resolve CLAUDE_BIN exactly as env.sh does (per-OS/arch + musl, with fallbacks)
# so this report names the same binary start.sh would actually exec. Kept in
# lockstep with env.sh::__cas_resolve_bin.
__cas_resolve_bin() {
  __os="linux"; __arch="x64"; __musl=""
  case "$(uname -s 2>/dev/null)" in
    Linux*)  __os="linux"  ;;
    Darwin*) __os="darwin" ;;
    *)       __os="linux"  ;;
  esac
  case "$(uname -m 2>/dev/null)" in
    x86_64|amd64)  __arch="x64"   ;;
    aarch64|arm64) __arch="arm64" ;;
    *)             __arch="x64"   ;;
  esac
  if [ "$__os" = "linux" ]; then
    if (ldd --version 2>&1 | grep -qi musl) || ls /lib/ld-musl-* >/dev/null 2>&1; then
      __musl="-musl"
    fi
  fi
  if [ -n "$__musl" ]; then
    __cands="${__os}-${__arch}-musl ${__os}-${__arch}"
  else
    __cands="${__os}-${__arch} ${__os}-${__arch}-musl"
  fi
  case "$__arch" in
    x64)   __other="arm64" ;;
    arm64) __other="x64"   ;;
    *)     __other=""      ;;
  esac
  [ -n "$__other" ] && __cands="$__cands ${__os}-${__other} ${__os}-${__other}-musl"
  CLAUDE_BIN=""
  for __p in $__cands; do
    if [ -x "$STICK/bin/$__p/claude" ]; then CLAUDE_BIN="$STICK/bin/$__p/claude"; break; fi
  done
  if [ -z "$CLAUDE_BIN" ]; then
    for __d in "$STICK/bin/${__os}-"*/; do
      if [ -x "${__d}claude" ]; then CLAUDE_BIN="${__d}claude"; break; fi
    done
  fi
  if [ -z "$CLAUDE_BIN" ] && [ -x "$STICK/bin/claude" ]; then
    CLAUDE_BIN="$STICK/bin/claude"
  fi
  CLAUDE_PLAT="${__os}-${__arch}${__musl}"
}
__cas_resolve_bin

printf '%s\n' "$(t diag header '=== claude-on-a-stick diagnostics ===')"
printf '%s %s\n\n' "$(t diag stick_at 'Stick root:')" "$STICK"

# --- 1. layout ---------------------------------------------------------------
printf '%s\n' "$(t diag sec_layout '-- Layout --')"
printf '   host platform: %s\n' "$CLAUDE_PLAT"
if [ -n "${CLAUDE_BIN:-}" ] && [ -x "$CLAUDE_BIN" ]; then
  ok "claude binary: ${CLAUDE_BIN#"$STICK/"} (executable)"
else
  fail "no claude binary for $CLAUDE_PLAT under bin/ (looked for bin/$CLAUDE_PLAT/claude + fallbacks)"
fi
# Token source (mirrors DIAG.bat): encrypted blob preferred; plaintext is a
# defensive fallback; neither is a build failure.
if [ -f "$STICK/config/oauth.enc" ]; then
  ok "config/oauth.enc present (encrypted; password required at launch)"
elif [ -f "$STICK/config/oauth.txt" ]; then
  warn "config/oauth.txt present (PLAINTEXT token, no encryption)"
else
  fail "no token: neither config/oauth.enc nor config/oauth.txt present"
fi
[ -f "$STICK/config/settings.json" ] && ok "config/settings.json present" || warn "config/settings.json missing"
[ -f "$STICK/config/.claude.json" ] && ok "config/.claude.json present" || warn "config/.claude.json missing"
[ -f "$STICK/decrypt.sh" ] && ok "decrypt.sh present" || fail "decrypt.sh missing"
[ -f "$STICK/env.sh" ] && ok "env.sh present" || fail "env.sh missing"
[ -f "$STICK/geoguard.sh" ] && ok "geoguard.sh present" || fail "geoguard.sh missing"
[ -f "$STICK/geoguard.conf" ] && ok "geoguard.conf present" || warn "geoguard.conf missing (defaults apply)"
[ -d "$STICK/projects" ] && ok "projects/ present" || warn "projects/ missing (will be created)"
[ -d "$STICK/tmp" ] && ok "tmp/ present" || warn "tmp/ missing (will be created)"
printf '\n'

# --- 2. tools ----------------------------------------------------------------
printf '%s\n' "$(t diag sec_tools '-- Required tools --')"
if command -v curl >/dev/null 2>&1; then ok "curl ($(curl --version 2>/dev/null | head -n1))"; else fail "curl not found (needed for geoguard/vpn)"; fi
if command -v openssl >/dev/null 2>&1; then
  ok "openssl ($(openssl version 2>/dev/null))"
  # OpenSSL 3 has `openssl kdf`; LibreSSL (macOS) does not -> perl fallback.
  if openssl kdf -help >/dev/null 2>&1; then
    ok "openssl kdf available (PBKDF2 path)"
  else
    warn "no 'openssl kdf' (LibreSSL?) - decrypt.sh uses the perl PBKDF2 fallback"
    command -v perl >/dev/null 2>&1 && ok "perl available (Digest::SHA fallback)" || fail "perl missing - decrypt fallback unavailable"
  fi
else
  fail "openssl not found (needed to decrypt the token)"
fi
printf '\n'

# --- 3. geoguard config + direct detection -----------------------------------
printf '%s\n' "$(t diag sec_geo '-- Geo-guard --')"
GUARD_ENABLED=1; BLOCKLIST="RU,BY,CU,IR,KP,SY"; INCONCLUSIVE="prompt"
if [ -f "$STICK/geoguard.conf" ]; then
  # shellcheck disable=SC1090
  . "$STICK/geoguard.conf"
fi
printf '   GUARD_ENABLED=%s  BLOCKLIST=%s  INCONCLUSIVE=%s\n' "$GUARD_ENABLED" "$BLOCKLIST" "$INCONCLUSIVE"
if command -v curl >/dev/null 2>&1; then
  __cc="$(curl -fsS --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^loc=\([A-Za-z][A-Za-z]\).*/\1/p' | head -n1 | tr '[:lower:]' '[:upper:]')"
  if [ -n "$__cc" ]; then
    # Is it blocked?
    __blocked=0
    __old_ifs="$IFS"; IFS=','
    for __c in $BLOCKLIST; do
      __c="$(printf '%s' "$__c" | tr -d ' \t' | tr '[:lower:]' '[:upper:]')"
      [ "$__c" = "$__cc" ] && __blocked=1
    done
    IFS="$__old_ifs"
    if [ "$__blocked" = "1" ]; then
      warn "direct exit country: $__cc - BLOCKED (VPN required at launch)"
    else
      ok "direct exit country: $__cc - not blocked"
    fi
  else
    warn "could not determine direct exit country (network down?)"
  fi
else
  warn "curl missing - skipping geo detection"
fi
printf '\n'

# --- 4. bundled VPN ----------------------------------------------------------
# Resolve the Happ dir the same way vpnup.sh does: prefer this OS's per-OS tree
# (apps/happ-<os>, multi-OS layout) then fall back to flat apps/happ.
printf '%s\n' "$(t diag sec_vpn '-- Bundled VPN (Happ) --')"
case "$(uname -s 2>/dev/null)" in
  Darwin*) __HAPP_OS="mac" ;;
  *)       __HAPP_OS="linux" ;;
esac
if [ -d "$STICK/apps/happ-$__HAPP_OS" ]; then __HAPP_DIR="$STICK/apps/happ-$__HAPP_OS"; else __HAPP_DIR="$STICK/apps/happ"; fi
if [ -d "$__HAPP_DIR" ]; then
  ok "${__HAPP_DIR#"$STICK/"} present"
  [ -f "$__HAPP_DIR/run-happ.sh" ] && ok "run-happ.sh present" || warn "run-happ.sh missing"
  # Probe candidate ports WITHOUT launching Happ - just see if one already answers.
  if command -v curl >/dev/null 2>&1; then
    __live=""
    for __p in 10808 10809 2080 1080 10800 8080; do
      if curl -fsS --max-time 2 --proxy "http://127.0.0.1:$__p" http://cloudflare.com/cdn-cgi/trace >/dev/null 2>&1; then
        __live="$__p"; break
      fi
    done
    if [ -n "$__live" ]; then ok "live HTTP proxy detected on port $__live"; else warn "no live proxy now (Happ not connected yet - normal until START runs it)"; fi
  fi
else
  warn "apps/happ absent - will rely on host/system VPN (geoguard still governs)"
fi
printf '\n'

printf '%s\n' "$(t diag complete 'Diagnostics complete.')"
exit 0
