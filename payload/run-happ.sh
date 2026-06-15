#!/usr/bin/env bash
# run-happ.sh - portable launcher for the bundled Happ client (POSIX side).
# Mirrors apps/happ/run-happ.bat. See CONTRACTS.md §6 and §7.
#
# Responsibilities:
#   - Redirect Happ's config/state onto the stick (XDG_CONFIG_HOME + HOME),
#     so the host profile is never touched.
#   - Launch the Happ binary in PROXY MODE (never TUN - TUN needs admin).
#   - Optionally forward a `happ://…` subscription deep-link to the running
#     instance (SingleApplication / QLocalServer IPC imports it). The scheme is
#     NOT registered as an xdg handler, so we call the binary directly.
#
# Usage:
#   run-happ.sh                  # just launch Happ (backgrounded)
#   run-happ.sh "happ://add/…"   # launch (if needed) + forward the deep link
#
# Lives at <STICK>/apps/happ/run-happ.sh ; the stick root is two levels up.
set -eu

__SELF_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"   # …/apps/happ
__HAPP_HOME="$__SELF_DIR"
# Stick root = parent of apps/ = two levels above this script.
STICK="${STICK:-$(cd "$__SELF_DIR/../.." && pwd)}"

if ! command -v t >/dev/null 2>&1; then
  t() { shift 2>/dev/null || true; printf '%s' "${*:-}"; }
fi

# --- redirect Happ config onto the stick -------------------------------------
# Happ (Qt app) reads XDG_CONFIG_HOME for its Happ.conf / subs.db. Point both
# XDG_CONFIG_HOME and HOME at a stick dir so nothing lands in the host profile.
__HAPP_DATA="$__HAPP_HOME/data"
mkdir -p "$__HAPP_DATA" 2>/dev/null || true
export XDG_CONFIG_HOME="$__HAPP_DATA"
export XDG_DATA_HOME="$__HAPP_DATA"
export XDG_CACHE_HOME="$__HAPP_DATA/cache"
export HOME="$__HAPP_DATA"

# --- locate the Happ binary --------------------------------------------------
# Relocatable extraction from the .deb keeps a usr/bin/Happ (RUNPATH $ORIGIN/../lib).
# Accept a few likely locations + a generic search.
__HAPP_BIN=""
for __cand in \
  "$__HAPP_HOME/Happ" \
  "$__HAPP_HOME/usr/bin/Happ" \
  "$__HAPP_HOME/bin/Happ" \
  "$__HAPP_HOME/opt/Happ/Happ"; do
  if [ -x "$__cand" ]; then __HAPP_BIN="$__cand"; break; fi
done
if [ -z "$__HAPP_BIN" ]; then
  # Last resort: first executable named Happ anywhere under apps/happ.
  __HAPP_BIN="$(find "$__HAPP_HOME" -maxdepth 4 -type f -name Happ -perm -u+x 2>/dev/null | head -n1 || true)"
fi
if [ -z "$__HAPP_BIN" ] || [ ! -x "$__HAPP_BIN" ]; then
  printf '%s\n' "$(t happ no_bin 'Happ binary not found under apps/happ - VPN unavailable.')" >&2
  exit 1
fi

# --- subscription deep-link forwarding (optional) ----------------------------
# If a happ:// URL was passed, forward it to the (possibly already running)
# instance. QLocalServer IPC imports it; we MUST NOT write subs.db directly.
if [ "${1:-}" != "" ]; then
  case "$1" in
    happ://*)
      printf '%s\n' "$(t happ sub_insert 'Forwarding subscription deep-link to Happ…')" >&2
      "$__HAPP_BIN" "$1" >/dev/null 2>&1 &
      # Give IPC a moment; verification (conf lastSubscription / subs.db bump)
      # is the builder's job - here we just print the link as a manual fallback.
      sleep 2 2>/dev/null || true
      printf '%s %s\n' "$(t happ sub_fallback 'If it did not import, paste this into Happ manually:')" "$1" >&2
      exit 0 ;;
  esac
fi

# --- launch Happ in proxy mode (backgrounded) --------------------------------
# Avoid double-launch: SingleApplication will no-op a second instance, but we
# also skip if a Happ process is already running for a cleaner experience.
if command -v pgrep >/dev/null 2>&1 && pgrep -x Happ >/dev/null 2>&1; then
  printf '%s\n' "$(t happ already 'Happ already running.')" >&2
  exit 0
fi

printf '%s\n' "$(t happ start 'Starting Happ (proxy mode, no admin)…')" >&2
# nohup + background + detach so closing the launcher terminal won't kill it.
nohup "$__HAPP_BIN" >/dev/null 2>&1 &
disown 2>/dev/null || true
exit 0
