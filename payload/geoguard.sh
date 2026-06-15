#!/usr/bin/env bash
# geoguard.sh — anti-ban geo-guard (POSIX side). Mirrors geoguard.ps1 logic.
# See CONTRACTS.md §5.
#
# Exit codes (consumed by start.sh):
#   0 = OK to launch (country safe, or guard disabled, or VPN fixed it)
#   1 = REFUSE to launch (blocked region and no working VPN exit)
#
# Logic:
#   0. GUARD_ENABLED=0 -> OK immediately.
#   1. Detect exit country DIRECT (no proxy).
#   2. Not in BLOCKLIST -> OK, do NOT touch the VPN (smart skip — the whole point).
#   3. Blocked -> bring Happ up (vpnup) and re-check THROUGH the proxy.
#   4. Still blocked / no VPN -> refuse.
#   5. Undetermined -> per INCONCLUSIVE (prompt|block|allow).
set -eu

__GG_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
: "${STICK:=$__GG_DIR}"

# Self-contained i18n stub (matches start.sh): t <ns> <key> <literal default>.
# Two shifts drop the namespace + key so only the literal default is printed
# (a single shift would leak the raw key into the message). Never sources i18n.sh.
if ! command -v t >/dev/null 2>&1; then
  t() { shift 2>/dev/null || true; shift 2>/dev/null || true; printf '%s' "${*:-}"; }
fi

# --- load config -------------------------------------------------------------
GUARD_ENABLED=1
BLOCKLIST="RU,BY,CU,IR,KP,SY"
INCONCLUSIVE="prompt"
__CONF="$STICK/geoguard.conf"
if [ -f "$__CONF" ]; then
  # shellcheck disable=SC1090
  . "$__CONF"
fi

# Marker the parent (start.sh) reads to know whether geoguard actually raised
# the VPN (blocked-region path). Cleared up front so the SAFE path leaves no
# marker -> start.sh never touches the VPN on a safe region (the smart-skip).
__VPN_MARK="$STICK/tmp/.vpn_raised"
mkdir -p "$STICK/tmp" 2>/dev/null || true
rm -f "$__VPN_MARK" 2>/dev/null || true

# --- step 0: master switch ---------------------------------------------------
if [ "${GUARD_ENABLED:-1}" = "0" ]; then
  printf '%s\n' "$(t geo disabled 'Geo-guard disabled (GUARD_ENABLED=0).')" >&2
  exit 0
fi

# --- helpers -----------------------------------------------------------------
# Probe the exit country. Arg $1 (optional) = proxy URL for a recheck.
# Echoes a 2-letter UPPERCASE code on success, nothing on failure.
detect_country() {
  __proxy_arg=""
  if [ -n "${1:-}" ]; then
    __proxy_arg="--proxy $1"
  fi
  __cc=""

  # Primary: Cloudflare trace exposes a `loc=XX` line. Most reliable.
  # shellcheck disable=SC2086
  __trace="$(curl -fsS --max-time 8 $__proxy_arg https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
  __cc="$(printf '%s\n' "$__trace" | sed -n 's/^loc=\([A-Za-z][A-Za-z]\).*/\1/p' | head -n1)"

  # Fallback 1: ipinfo.io/country returns the bare code.
  if [ -z "$__cc" ]; then
    # shellcheck disable=SC2086
    __cc="$(curl -fsS --max-time 8 $__proxy_arg https://ipinfo.io/country 2>/dev/null | tr -d ' \t\r\n' || true)"
  fi
  # Fallback 2: api.country.is returns {"ip":"…","country":"XX"}.
  if [ -z "$__cc" ]; then
    # shellcheck disable=SC2086
    __body="$(curl -fsS --max-time 8 $__proxy_arg https://api.country.is 2>/dev/null || true)"
    __cc="$(printf '%s\n' "$__body" | sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([A-Za-z][A-Za-z]\)".*/\1/p' | head -n1)"
  fi

  printf '%s' "$__cc" | tr '[:lower:]' '[:upper:]'
}

# Is $1 present in the comma list BLOCKLIST? returns 0 if blocked.
is_blocked() {
  __needle="$1"
  __old_ifs="$IFS"; IFS=','
  for __c in $BLOCKLIST; do
    __c="$(printf '%s' "$__c" | tr -d ' \t' | tr '[:lower:]' '[:upper:]')"
    if [ "$__c" = "$__needle" ]; then IFS="$__old_ifs"; return 0; fi
  done
  IFS="$__old_ifs"
  return 1
}

# --- step 1: direct detection ------------------------------------------------
COUNTRY="$(detect_country "")"

# --- step 5 (undetermined) handling, only if direct probe yielded nothing ----
if [ -z "$COUNTRY" ]; then
  printf '%s\n' "$(t geo undetermined 'Could not determine your exit country.')" >&2
  case "$INCONCLUSIVE" in
    allow)
      printf '%s\n' "$(t geo inconclusive_allow 'INCONCLUSIVE=allow — launching anyway.')" >&2
      exit 0 ;;
    block)
      printf '%s\n' "$(t geo inconclusive_block 'INCONCLUSIVE=block — refusing to launch.')" >&2
      exit 1 ;;
    *) # prompt
      printf '%s ' "$(t geo prompt_continue 'Continue without geo verification? [y/N]:')" >&2
      read -r __ans || __ans=""
      case "$__ans" in
        y|Y|yes|YES) exit 0 ;;
        *) exit 1 ;;
      esac ;;
  esac
fi

# --- step 2: smart skip ------------------------------------------------------
if ! is_blocked "$COUNTRY"; then
  printf '%s %s — %s\n' "$(t geo exit_country 'Exit country:')" "$COUNTRY" \
    "$(t geo ok_safe 'not blocked, VPN untouched.')" >&2
  exit 0
fi

# --- step 3: blocked -> bring up VPN and re-check through the proxy ----------
printf '%s %s — %s\n' "$(t geo exit_country 'Exit country:')" "$COUNTRY" \
  "$(t geo blocked_trying_vpn 'BLOCKED. Bringing up bundled VPN…')" >&2

# vpnup.sh exports HTTPS_PROXY when it succeeds. Source it so the var survives.
if [ -f "$STICK/vpnup.sh" ]; then
  # shellcheck disable=SC1090
  . "$STICK/vpnup.sh" || true
fi

if [ -z "${HTTPS_PROXY:-}" ]; then
  printf '%s\n' "$(t geo no_vpn 'No working VPN proxy available — refusing to launch.')" >&2
  exit 1
fi

# Re-check exit country THROUGH the proxy. Only the HTTP proxy works here.
COUNTRY2="$(detect_country "$HTTPS_PROXY")"
if [ -z "$COUNTRY2" ]; then
  printf '%s\n' "$(t geo recheck_failed 'VPN proxy did not answer the geo probe — refusing.')" >&2
  exit 1
fi

if is_blocked "$COUNTRY2"; then
  printf '%s %s — %s\n' "$(t geo vpn_country 'VPN exit country:')" "$COUNTRY2" \
    "$(t geo still_blocked 'still blocked. Refusing to launch.')" >&2
  exit 1
fi

# --- step 4 (positive): VPN fixed it ----------------------------------------
# Record that the VPN was raised so start.sh re-establishes the proxy vars in
# its own shell (a sourced geoguard ran in a subshell, so its exports are lost).
printf '%s' "$HTTPS_PROXY" > "$__VPN_MARK" 2>/dev/null || true
printf '%s %s — %s\n' "$(t geo vpn_country 'VPN exit country:')" "$COUNTRY2" \
  "$(t geo vpn_ok 'safe via VPN. Proceeding.')" >&2
exit 0
