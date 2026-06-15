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

# --- 2b. resolve CLAUDE_BIN for THIS OS/arch ---------------------------------
# Multi-OS layout: the per-platform binary lives at bin/<os>-<arch>[-musl]/claude
#   os   = linux | darwin    (uname -s)
#   arch = x64 | arm64       (uname -m: x86_64->x64, aarch64|arm64->arm64)
#   -musl appended on Linux when the C library is musl (ldd mentions musl, or a
#         /lib/ld-musl* loader exists - e.g. Alpine).
# We try the exact native variant first, then a sensible fallback list (drop
# musl<->glibc, then any present <os>-* dir of the right OS), then the legacy
# flat bin/claude (single-target builds before subdirs), and finally error.
# Exported as CLAUDE_BIN; start.sh exec's "$CLAUDE_BIN".
__cas_resolve_bin() {
  __os="linux"; __arch="x64"; __musl=""
  case "$(uname -s 2>/dev/null)" in
    Linux*)  __os="linux"  ;;
    Darwin*) __os="darwin" ;;
    *)       __os="linux"  ;;  # best-effort default
  esac
  case "$(uname -m 2>/dev/null)" in
    x86_64|amd64)        __arch="x64"   ;;
    aarch64|arm64)       __arch="arm64" ;;
    *)                   __arch="x64"   ;;
  esac
  if [ "$__os" = "linux" ]; then
    # musl detection: ldd --version output mentions musl, or a musl loader exists.
    if (ldd --version 2>&1 | grep -qi musl) || ls /lib/ld-musl-* >/dev/null 2>&1; then
      __musl="-musl"
    fi
  fi

  # Candidate plats, most-specific first. On darwin __musl is always empty.
  if [ -n "$__musl" ]; then
    __cands="${__os}-${__arch}-musl ${__os}-${__arch}"
  else
    __cands="${__os}-${__arch} ${__os}-${__arch}-musl"
  fi
  # Also try the same-OS other arch as a last structured guess (e.g. x64 binary
  # under Rosetta on darwin-arm64), keeping OS correct.
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
  # Next: ANY present <os>-* subdir (closest by OS), then legacy flat bin/claude.
  if [ -z "$CLAUDE_BIN" ]; then
    for __d in "$STICK/bin/${__os}-"*/; do
      if [ -x "${__d}claude" ]; then CLAUDE_BIN="${__d}claude"; break; fi
    done
  fi
  if [ -z "$CLAUDE_BIN" ] && [ -x "$STICK/bin/claude" ]; then
    CLAUDE_BIN="$STICK/bin/claude"
  fi
  # Expose the detected plat label for diagnostics / error messages.
  CLAUDE_PLAT="${__os}-${__arch}${__musl}"
}
__cas_resolve_bin
export CLAUDE_BIN CLAUDE_PLAT
if [ -z "${CLAUDE_BIN:-}" ]; then
  printf '%s\n' "$(t err no_binary "No claude binary for this host (detected ${CLAUDE_PLAT}); looked under bin/${CLAUDE_PLAT}/claude and same-OS fallbacks - re-run the builder for a ${CLAUDE_PLAT} target.")" >&2
  return 1 2>/dev/null || exit 1
fi

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
