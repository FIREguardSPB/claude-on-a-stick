#!/usr/bin/env bash
# vpnup.sh — bring up the bundled Happ VPN in proxy mode (POSIX side).
# Mirrors vpnup.bat. See CONTRACTS.md §3 (env) and §6 (VPN bring-up).
#
# Designed to be SOURCED (so the exported proxy vars survive into the caller),
# but also safe to run standalone for diagnostics.
#
#   - If apps/happ is absent  -> return OK (rely on host/system VPN; geoguard
#     still governs). No proxy vars are set.
#   - Otherwise: launch Happ via run-happ.sh (redirects its config onto the
#     stick), then AUTO-DETECT the live HTTP proxy port by making a real request
#     through each candidate. First port that answers 200 wins -> export it.
#   - Happ runs in PROXY MODE only, never TUN (TUN needs admin everywhere).
#
# Exports on success:
#   HTTPS_PROXY=http://127.0.0.1:<port>
#   HTTP_PROXY=http://127.0.0.1:<port>
#   ALL_PROXY=socks5://127.0.0.1:<port>   (only if that port also speaks SOCKS — best-effort)
#   NO_PROXY=localhost,127.0.0.1,::1
set -eu

__VPN_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
: "${STICK:=$__VPN_DIR}"

# Self-contained i18n stub (matches start.sh): t <ns> <key> <literal default>.
# Two shifts drop the namespace + key so only the literal default is printed
# (a single shift would leak the raw key into the message). Never sources i18n.sh.
if ! command -v t >/dev/null 2>&1; then
  t() { shift 2>/dev/null || true; shift 2>/dev/null || true; printf '%s' "${*:-}"; }
fi

__HAPP_DIR="$STICK/apps/happ"

# --- no bundled VPN -> nothing to do -----------------------------------------
if [ ! -d "$__HAPP_DIR" ]; then
  printf '%s\n' "$(t vpn none 'No bundled VPN (apps/happ absent) — using host network.')" >&2
  return 0 2>/dev/null || exit 0
fi

# --- launch Happ via the redirecting wrapper ---------------------------------
# run-happ.sh sets XDG_CONFIG_HOME/HOME into the stick so Happ never touches the
# host profile. It backgrounds Happ and returns.
if [ -x "$STICK/apps/happ/run-happ.sh" ] || [ -f "$STICK/apps/happ/run-happ.sh" ]; then
  printf '%s\n' "$(t vpn launching 'Launching bundled Happ (proxy mode)…')" >&2
  # Start it; ignore failure here — we verify by probing the proxy below.
  bash "$STICK/apps/happ/run-happ.sh" >/dev/null 2>&1 || true
else
  printf '%s\n' "$(t vpn no_wrapper 'apps/happ/run-happ.sh missing — cannot launch Happ.')" >&2
fi

# --- auto-detect the live HTTP proxy port ------------------------------------
# Happ proxy ports vary by build (10808 observed mixed). Probe each by making a
# real HTTP request through it; the first that returns the trace page wins.
__CANDIDATE_PORTS="10808 10809 2080 1080 10800 8080"

# Poll up to ~30s: Happ may take a moment to connect upstream.
# 15 rounds x ~2s of probing ≈ 30s ceiling.
__FOUND_PORT=""
__ROUNDS=15
__r=0
while [ "$__r" -lt "$__ROUNDS" ]; do
  for __p in $__CANDIDATE_PORTS; do
    # A real request through the candidate HTTP proxy. --max-time keeps each
    # probe short so the whole sweep stays responsive.
    if curl -fsS --max-time 2 --proxy "http://127.0.0.1:$__p" \
         http://cloudflare.com/cdn-cgi/trace >/dev/null 2>&1; then
      __FOUND_PORT="$__p"
      break
    fi
  done
  [ -n "$__FOUND_PORT" ] && break
  __r=$((__r + 1))
  # Brief wait between full sweeps (curl --max-time already spends real time).
  sleep 1 2>/dev/null || true
done

if [ -z "$__FOUND_PORT" ]; then
  printf '%s\n' "$(t vpn no_proxy 'Could not find a live Happ proxy port (is auto-connect on?).')" >&2
  printf '%s\n' "$(t vpn hint_autoconnect 'Enable Happ auto-connect on launch, then retry.')" >&2
  return 1 2>/dev/null || exit 1
fi

# --- export the proxy environment (names EXACT per CONTRACTS.md §3) -----------
export HTTPS_PROXY="http://127.0.0.1:$__FOUND_PORT"
export HTTP_PROXY="http://127.0.0.1:$__FOUND_PORT"
export NO_PROXY="localhost,127.0.0.1,::1"

# ALL_PROXY (SOCKS) only if the same port also answers SOCKS5 — best-effort.
if curl -fsS --max-time 3 --proxy "socks5://127.0.0.1:$__FOUND_PORT" \
     http://cloudflare.com/cdn-cgi/trace >/dev/null 2>&1; then
  export ALL_PROXY="socks5://127.0.0.1:$__FOUND_PORT"
fi

printf '%s http://127.0.0.1:%s\n' "$(t vpn up 'VPN proxy up at')" "$__FOUND_PORT" >&2
return 0 2>/dev/null || exit 0
