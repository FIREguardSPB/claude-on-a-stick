#!/usr/bin/env bash
# start.sh - entry point for claude-on-a-stick (POSIX side).
# Mirrors START.bat and the launcher chain in CONTRACTS.md §3, in order:
#   1. vpnup    - bring Happ up if bundled (proxy mode), export proxy env.
#   2. geoguard - refuse to launch from a blocked exit country (§5).
#   3. env      - redirect config/tmp onto the stick, clear API key, unlock the
#                 encrypted OAuth token via decrypt.sh into memory only.
#   4. cd projects/ and exec claude --model <MODEL> "$@".
#
# Placeholders baked at build time:
#   __MODEL__  -> the default model (e.g. claude-opus-4-8)
#   __LANG__   -> "en" or "ru" (selects baked launcher messages)
#
# Robust: set -eu, absolute self-location, clear errors at each step.
set -eu

# --- locate the stick root (this script lives at <STICK>/start.sh) -----------
STICK="$(cd "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
export STICK

# Baked-in defaults (the builder substitutes these).
MODEL="__MODEL__"
LANG_CHOICE="__LANG__"
export LANG_CHOICE

# --- i18n: self-contained launcher messages ----------------------------------
# The stick launchers use a self-contained t() with the signature
#   t <ns> <key> '<literal English default>'
# and DO NOT source shared/i18n.sh: that builder-side module uses a DIFFERENT
# t() signature (t <dotted.key> [args]) and a different key scheme, so sourcing
# it here would shadow this t() and leak <<key>> sentinels. Keeping the launcher
# self-contained means start.sh runs identically whether or not i18n.sh is on
# the stick - and never errors if it is absent. (vpnup/geoguard/env/diag agree.)
if ! command -v t >/dev/null 2>&1; then
  # t <ns> <key> <literal...> -> prints the literal default (drops ns + key).
  t() { shift 2>/dev/null || true; shift 2>/dev/null || true; printf '%s' "${*:-}"; }
fi

printf '%s\n' "$(t start banner '=== claude-on-a-stick ===')" >&2

# --- steps 1+2: geo-guard (which OWNS on-demand VPN bring-up) -----------------
# To honour the §5 "smart skip" guarantee (the user's whole point), the bundled
# VPN is NOT started unconditionally here. geoguard.sh does a DIRECT region
# check first; only if the region is blocked does it source vpnup.sh to raise
# Happ and re-check through the proxy. This mirrors START.bat exactly.
#
# We SOURCE geoguard (not run it as a child) so that any HTTPS_PROXY/HTTP_PROXY
# it exported on the blocked-region path survives into THIS shell and is
# inherited by claude. But geoguard calls `exit` to signal its verdict, which
# would tear down start.sh - so we run it in a subshell purely to capture the
# OK/refuse verdict, then (only when the VPN was needed) re-source vpnup here to
# re-establish the proxy vars in this shell. vpnup smart-detects the already-live
# port, so the re-source is cheap and idempotent.
if [ -f "$STICK/geoguard.sh" ]; then
  if ( . "$STICK/geoguard.sh" ); then
    : # OK to launch (safe region, guard disabled, or VPN fixed it)
  else
    printf '%s\n' "$(t start aborted_geo 'Aborted: exit region is blocked and no safe VPN exit. Refusing to launch.')" >&2
    exit 1
  fi
  # If geoguard's verdict relied on the bundled VPN it left a marker (with the
  # detected proxy URL). ONLY then do we re-establish the proxy vars in this
  # shell. On a SAFE region geoguard leaves no marker, so the VPN is never
  # touched here - preserving the §5 smart-skip guarantee.
  __VPN_MARK="$STICK/tmp/.vpn_raised"
  if [ -f "$__VPN_MARK" ] && [ -z "${HTTPS_PROXY:-}" ]; then
    # Re-source vpnup to smart-detect the already-live port (cheap; Happ is up).
    if [ -f "$STICK/vpnup.sh" ]; then
      # shellcheck disable=SC1090
      . "$STICK/vpnup.sh" || true
    fi
    # Fallback: if the re-probe somehow missed it, adopt the URL geoguard saved.
    if [ -z "${HTTPS_PROXY:-}" ]; then
      __saved="$(cat "$__VPN_MARK" 2>/dev/null || true)"
      if [ -n "$__saved" ]; then
        export HTTPS_PROXY="$__saved"
        export HTTP_PROXY="$__saved"
        export NO_PROXY="localhost,127.0.0.1,::1"
      fi
    fi
  fi
  rm -f "$__VPN_MARK" 2>/dev/null || true
fi

# --- step 3: environment + token unlock --------------------------------------
# env.sh sets CLAUDE_CONFIG_DIR/HOME/TMP/TEMP, clears ANTHROPIC_API_KEY, disables
# updates, and unlocks CLAUDE_CODE_OAUTH_TOKEN (prompts "Stick password"). It is
# sourced so the token + env live in THIS shell only (never written to disk).
if [ ! -f "$STICK/env.sh" ]; then
  printf '%s\n' "$(t start no_env 'env.sh missing - stick is incomplete.')" >&2
  exit 1
fi
# shellcheck disable=SC1090
. "$STICK/env.sh" || {
  printf '%s\n' "$(t start env_failed 'Environment setup / token unlock failed. Aborting.')" >&2
  exit 1
}

# --- step 4: locate the claude binary, cd to projects, exec ------------------
CLAUDE_BIN="$STICK/bin/claude"
if [ ! -x "$CLAUDE_BIN" ]; then
  printf '%s\n' "$(t start no_binary 'bin/claude not found or not executable - was the stick built?')" >&2
  exit 1
fi

cd "$STICK/projects" 2>/dev/null || {
  mkdir -p "$STICK/projects" && cd "$STICK/projects"
}

printf '%s %s\n' "$(t start launching 'Launching Claude Code, model:')" "$MODEL" >&2

# exec replaces this shell so signals (Ctrl-C) go straight to claude, and the
# decrypted token is handed off without leaving an extra process holding it.
exec "$CLAUDE_BIN" --model "$MODEL" "$@"
