#!/usr/bin/env bash
# diag.sh — non-destructive health check for claude-on-a-stick (POSIX side).
# Mirrors DIAG.bat. Does NOT launch Claude and does NOT prompt for the password.
#
# Reports, with PASS/WARN/FAIL markers:
#   - stick layout (bin/claude, config/oauth.enc, settings, decrypt.sh)
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

printf '%s\n' "$(t diag header '=== claude-on-a-stick diagnostics ===')"
printf '%s %s\n\n' "$(t diag stick_at 'Stick root:')" "$STICK"

# --- 1. layout ---------------------------------------------------------------
printf '%s\n' "$(t diag sec_layout '-- Layout --')"
[ -x "$STICK/bin/claude" ] && ok "bin/claude (executable)" || fail "bin/claude missing or not executable"
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
    warn "no 'openssl kdf' (LibreSSL?) — decrypt.sh uses the perl PBKDF2 fallback"
    command -v perl >/dev/null 2>&1 && ok "perl available (Digest::SHA fallback)" || fail "perl missing — decrypt fallback unavailable"
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
      warn "direct exit country: $__cc — BLOCKED (VPN required at launch)"
    else
      ok "direct exit country: $__cc — not blocked"
    fi
  else
    warn "could not determine direct exit country (network down?)"
  fi
else
  warn "curl missing — skipping geo detection"
fi
printf '\n'

# --- 4. bundled VPN ----------------------------------------------------------
printf '%s\n' "$(t diag sec_vpn '-- Bundled VPN (Happ) --')"
if [ -d "$STICK/apps/happ" ]; then
  ok "apps/happ present"
  [ -f "$STICK/apps/happ/run-happ.sh" ] && ok "run-happ.sh present" || warn "run-happ.sh missing"
  # Probe candidate ports WITHOUT launching Happ — just see if one already answers.
  if command -v curl >/dev/null 2>&1; then
    __live=""
    for __p in 10808 10809 2080 1080 10800 8080; do
      if curl -fsS --max-time 2 --proxy "http://127.0.0.1:$__p" http://cloudflare.com/cdn-cgi/trace >/dev/null 2>&1; then
        __live="$__p"; break
      fi
    done
    if [ -n "$__live" ]; then ok "live HTTP proxy detected on port $__live"; else warn "no live proxy now (Happ not connected yet — normal until START runs it)"; fi
  fi
else
  warn "apps/happ absent — will rely on host/system VPN (geoguard still governs)"
fi
printf '\n'

printf '%s\n' "$(t diag complete 'Diagnostics complete.')"
exit 0
