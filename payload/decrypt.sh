#!/usr/bin/env bash
# payload/decrypt.sh — STICK-SIDE token decryptor (Linux solid, macOS best-effort).
#
# Copied verbatim onto the stick by the builder. Invoked by env.sh:
#     CLAUDE_CODE_OAUTH_TOKEN="$("$STICK/decrypt.sh" "$STICK/config/oauth.enc")" || exit 1
#     export CLAUDE_CODE_OAUTH_TOKEN
#
# CONTRACT (do not change without re-verifying the round-trip):
#   * Reads  salt[16] || iv[16] || AES-256-CBC(PKCS7) ciphertext  from $1.
#   * KDF = PBKDF2-HMAC-SHA1, 300000 iters, 32-byte key.
#   * The password PROMPT (masked, read -rs) and all errors go to STDERR.
#   * The decrypted token is the ONLY thing on STDOUT, NO trailing newline,
#     so the caller can capture it straight into CLAUDE_CODE_OAUTH_TOKEN.
#   * Exit code 1 on any failure (missing file, no backend, wrong password / bad padding).
#
# Key derivation backends, tried in this order (first that works wins):
#   1. openssl 3  `openssl kdf ... PBKDF2`     — Linux (LibreSSL has NO kdf subcommand)
#   2. perl Digest::SHA PBKDF2-HMAC-SHA1       — macOS LibreSSL fallback (VERIFIED identical)
#   3. python3 hashlib.pbkdf2_hmac            — universal last resort
# salt/iv are read WITHOUT xxd (macOS lacks xxd) using head -c / dd / tail -c + od.

set -u

# --- prompt text (builder may string-replace for other languages) ---
PROMPT_TEXT="Stick password"

die() { printf '%s\n' "decrypt.sh: $*" >&2; exit 1; }

ENC_PATH="${1:-}"
[ -n "$ENC_PATH" ] || die "usage: decrypt.sh <oauth.enc>"
[ -f "$ENC_PATH" ] || die "file not found: $ENC_PATH"

# oauth.enc must be at least salt(16)+iv(16)+one AES block(16) = 48 bytes.
_size=$(wc -c < "$ENC_PATH" | tr -d ' ')
[ "$_size" -ge 48 ] || die "oauth.enc too short / corrupt ($_size bytes)"

# --- read salt (bytes 0..15) and iv (bytes 16..31) as hex, NO xxd ---
salthex=$(head -c 16 "$ENC_PATH" | od -An -v -tx1 | tr -d ' \n')
ivhex=$(dd if="$ENC_PATH" bs=1 skip=16 count=16 2>/dev/null | od -An -v -tx1 | tr -d ' \n')
[ ${#salthex} -eq 32 ] || die "could not read salt"
[ ${#ivhex} -eq 32 ]   || die "could not read iv"

have() { command -v "$1" >/dev/null 2>&1; }

# --- masked password prompt -> STDERR ---
printf '%s: ' "$PROMPT_TEXT" >&2
# read -rs masks input; -r keeps backslashes literal. Append a newline on stderr after entry.
IFS= read -rs PW
printf '\n' >&2

# ---------------------------------------------------------------------------
# derive_keyhex : echo the 64-char lowercase hex key (32 bytes) for $PW + $salthex
# ---------------------------------------------------------------------------
derive_keyhex() {
  # 1) OpenSSL 3 `openssl kdf` (Linux). hexsalt: (not salt:) and -binary are REQUIRED.
  if have openssl && openssl kdf -help >/dev/null 2>&1; then
    openssl kdf -keylen 32 -binary \
      -kdfopt digest:SHA1 \
      -kdfopt pass:"$PW" \
      -kdfopt hexsalt:"$salthex" \
      -kdfopt iter:300000 PBKDF2 \
      | od -An -v -tx1 | tr -d ' \n'
    return 0
  fi

  # 2) macOS LibreSSL fallback: pure-perl PBKDF2-HMAC-SHA1 (VERIFIED bit-identical).
  if have perl && perl -MDigest::SHA -e 1 >/dev/null 2>&1; then
    CAS_PW="$PW" CAS_SALTHEX="$salthex" perl -MDigest::SHA=hmac_sha1 -e '
      my $pw   = $ENV{CAS_PW};
      my $salt = pack("H*", $ENV{CAS_SALTHEX});
      my ($iter,$dklen) = (300000, 32);
      my $out = ""; my $i = 1;
      while (length($out) < $dklen) {
        my $u = hmac_sha1($salt . pack("N",$i), $pw);   # U1
        my $t = $u;
        for (2..$iter) { $u = hmac_sha1($u, $pw); $t ^= $u; }  # XOR-fold U2..Uc
        $out .= $t; $i++;
      }
      print unpack("H*", substr($out,0,$dklen));
    '
    return 0
  fi

  # 3) python3 last resort (matches all of the above).
  if have python3; then
    CAS_PW="$PW" CAS_SALTHEX="$salthex" python3 - <<'PY'
import os, hashlib
pw   = os.environ['CAS_PW'].encode('utf-8')
salt = bytes.fromhex(os.environ['CAS_SALTHEX'])
print(hashlib.pbkdf2_hmac('sha1', pw, salt, 300000, 32).hex())
PY
    return 0
  fi

  return 1
}

keyhex=$(derive_keyhex) || die "no PBKDF2 backend (need openssl 3, perl Digest::SHA, or python3)"
[ ${#keyhex} -eq 64 ] || die "key derivation failed"

# We are done with the plaintext password.
unset PW

have openssl || die "openssl is required to decrypt"

# --- decrypt: ciphertext is everything from byte 32 (tail -c +33 = 1-based offset) ---
# openssl errors (e.g. bad padding from a wrong password) go to /dev/null; we detect via exit code.
token=$(tail -c +33 "$ENC_PATH" | openssl enc -d -aes-256-cbc -K "$keyhex" -iv "$ivhex" 2>/dev/null) \
  || die "decryption failed (wrong password or corrupt file)."

# token -> STDOUT with NO trailing newline.
printf '%s' "$token"
exit 0
