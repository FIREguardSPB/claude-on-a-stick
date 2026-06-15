#!/usr/bin/env bash
# env.sh - environment protocol for claude-on-a-stick (POSIX side).
# Mirrors env.bat EXACTLY (same variable names, same order). See CONTRACTS.md §3.
#
# This script is *sourced* (not executed) by start.sh AFTER vpnup + geoguard have
# run, so that any proxy variables vpnup exported are already present in the
# environment. Its job:
#   - point Claude Code at the stick's own config / tmp dirs,
#   - clear ANTHROPIC_API_KEY so it can never override the subscription token,
#   - disable the auto-updater,
#   - unlock the encrypted OAuth token (via decrypt.sh) into memory only.
#
# The decrypted token lives ONLY in this shell's environment
# (CLAUDE_CODE_OAUTH_TOKEN) - it is never written to disk.
#
# Requires STICK to be exported by the caller (start.sh sets it).
set -eu

# --- self-contained launcher i18n (literal English defaults) -----------------
__ENV_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [ -z "${STICK:-}" ]; then
  STICK="$__ENV_DIR"
fi
# t() may already be defined by start.sh (same self-contained fallback);
# otherwise define the inline-default stub here. We never source shared/i18n.sh.
if ! command -v t >/dev/null 2>&1; then
  # t <ns> <key> <literal...> -> prints the literal default (drops ns + key).
  t() { shift 2>/dev/null || true; shift 2>/dev/null || true; printf '%s' "${*:-}"; }
fi

# --- 1. config / cache / tmp redirection onto the stick ----------------------
# CLAUDE_CONFIG_DIR governs where Claude Code reads settings.json / .claude.json.
# HOME is also redirected so any stray dotfiles land on the stick, not the host.
export CLAUDE_CONFIG_DIR="$STICK/config"
export HOME="$STICK/config"
export TMP="$STICK/tmp"
export TEMP="$STICK/tmp"
mkdir -p "$STICK/tmp" "$STICK/config" "$STICK/projects" 2>/dev/null || true

# --- 2. neutralise competing auth + updates ----------------------------------
# Cleared so a host-set API key can't silently override the subscription token.
export ANTHROPIC_API_KEY=""
export DISABLE_AUTOUPDATER=1
export DISABLE_UPDATES=1

# --- 3. unlock the OAuth token -----------------------------------------------
# Token source (mirrors env.bat, in priority order):
#   1. config/oauth.enc  -> decrypt.sh prompts for the Stick password on stderr
#      and prints ONLY the decrypted token to stdout (no trailing newline), so
#      command-substitution captures the token cleanly.
#   2. config/oauth.txt  -> plaintext fallback (defensive: the builder writes
#      oauth.enc, but if a user opted out of at-rest encryption this is read
#      verbatim, first non-empty line). We never echo the token ourselves.
__OAUTH_ENC="$STICK/config/oauth.enc"
__OAUTH_TXT="$STICK/config/oauth.txt"
if [ -f "$__OAUTH_ENC" ]; then
  # Prompt label is "Stick password" (see CONTRACTS.md §3.3); decrypt.sh owns the
  # masked read. Capture stdout into the env var; abort the whole launch on error.
  CLAUDE_CODE_OAUTH_TOKEN="$(bash "$STICK/decrypt.sh" "$__OAUTH_ENC")" || {
    printf '%s\n' "$(t err decrypt_failed 'Could not unlock token (wrong password?).')" >&2
    return 1 2>/dev/null || exit 1
  }
elif [ -f "$__OAUTH_TXT" ]; then
  # Plaintext fallback: first non-empty line, verbatim (no newline carried over).
  CLAUDE_CODE_OAUTH_TOKEN="$(grep -m1 . "$__OAUTH_TXT" 2>/dev/null | tr -d '\r\n')"
else
  printf '%s\n' "$(t err no_token 'No token found: neither config/oauth.enc nor config/oauth.txt exists - was the stick built correctly?')" >&2
  return 1 2>/dev/null || exit 1
fi
export CLAUDE_CODE_OAUTH_TOKEN
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  printf '%s\n' "$(t err decrypt_empty 'Token is empty - aborting.')" >&2
  return 1 2>/dev/null || exit 1
fi

# Note: proxy variables (HTTPS_PROXY / HTTP_PROXY / ALL_PROXY / NO_PROXY) are NOT
# set here - vpnup.sh exports them when a VPN is active, before this is sourced.
