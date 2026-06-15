#!/usr/bin/env bash
# shared/happ.sh — download + portable-ize Happ (Linux solid / macOS best-effort)
#                  + insert the subscription via the happ:// deep-link.
#
# Sourced by builders/posix/build.sh. Exposes:
#   happ_latest_tag                 -> echoes the latest happ-desktop release tag (e.g. 2.17.1)
#   happ_asset_for_os <os> <arch>   -> echoes the matching release asset filename
#   happ_download    <os> <arch> <out_dir>      -> downloads the asset, echoes its path
#   happ_portableize <os> <asset>  <dst_dir>    -> unpacks into <dst_dir> as a relocatable app
#   happ_write_runner <os> <dst_dir>            -> writes apps/happ/run-happ.sh config-redirect wrapper
#   happ_insert_sub  <os> <dst_dir> <raw_or_deeplink>  -> imports the subscription via deep-link
#
# Conventions shared with the rest of the repo:
#   - i18n via t() from shared/i18n.sh; technical tokens (Happ, flags, URLs) stay untranslated.
#   - All Happ config is redirected ONTO the stick (XDG_CONFIG_HOME/HOME), never the host home.
#   - Proxy mode only — never TUN (TUN needs admin everywhere). See CONTRACTS §6/§7.
#
# Targets (CONTRACTS §0 locked decisions): Linux = solid/verified, macOS = best-effort/guided.
set -u

# --- repo: github.com/Happ-proxy/happ-desktop (releases, ~v2.17). Tags are bare semver (no 'v'). ---
HAPP_REPO="Happ-proxy/happ-desktop"
HAPP_API="https://api.github.com/repos/${HAPP_REPO}/releases/latest"

# Soft i18n shim so this file can also be smoke-tested standalone (build.sh provides the real t()).
if ! declare -F t >/dev/null 2>&1; then t() { shift 2>/dev/null; printf '%s' "${*:-}"; }; fi
# Minimal logging helpers (build.sh may override; keep them harmless if it doesn't).
_happ_say()  { printf '%s\n' "$*" >&2; }
_happ_warn() { printf '!! %s\n' "$*" >&2; }
_happ_err()  { printf '!! %s\n' "$*" >&2; }

# --------------------------------------------------------------------------------------------------
# 1) Resolve latest release tag from the GitHub API.
#    Prefer jq; fall back to a python json parse; finally a grep so we never hard-depend on jq.
# --------------------------------------------------------------------------------------------------
happ_latest_tag() {
  local json tag
  json="$(curl -fsSL --max-time 20 -H 'Accept: application/vnd.github+json' "$HAPP_API" 2>/dev/null)" || true
  [ -n "$json" ] || { _happ_err "$(t happ_api_fail)"; return 1; }

  if command -v jq >/dev/null 2>&1; then
    tag="$(printf '%s' "$json" | jq -r '.tag_name // empty')"
  elif command -v python3 >/dev/null 2>&1; then
    tag="$(printf '%s' "$json" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null)"
  else
    # last-ditch: first tag_name in the JSON blob
    tag="$(printf '%s' "$json" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed 's/.*"\([^"]*\)"$/\1/')"
  fi
  [ -n "$tag" ] || { _happ_err "$(t happ_api_fail)"; return 1; }
  printf '%s' "$tag"
}

# --------------------------------------------------------------------------------------------------
# 2) Pick the right asset filename for an (os, arch) pair.
#    Verified names (release 2.17.1): setup-Happ.x64.exe / setup-Happ.arm64.exe,
#    Happ.macOS.universal.dmg, Happ.linux.{x64,arm64}.deb (also .rpm / .pkg.tar.zst).
#    os   ∈ linux | mac
#    arch ∈ x64 | arm64    (mac is a universal dmg regardless of arch)
#    Windows assets are handled by happ.ps1 (or by Wine in build.sh) — this is the POSIX side.
# --------------------------------------------------------------------------------------------------
happ_asset_for_os() {
  local os="$1" arch="${2:-x64}"
  case "$os" in
    linux)
      case "$arch" in
        arm64|aarch64) printf 'Happ.linux.arm64.deb' ;;
        *)             printf 'Happ.linux.x64.deb'   ;;
      esac ;;
    mac|macos|darwin)
      printf 'Happ.macOS.universal.dmg' ;;   # universal — one dmg for both arches
    *)
      _happ_err "happ_asset_for_os: unknown os '$os'"; return 1 ;;
  esac
}

# Build the browser_download_url for <tag>/<asset>. GitHub serves release assets at this stable path.
_happ_asset_url() {
  local tag="$1" asset="$2"
  printf 'https://github.com/%s/releases/download/%s/%s' "$HAPP_REPO" "$tag" "$asset"
}

# --------------------------------------------------------------------------------------------------
# 3) Download the asset for (os, arch) into <out_dir>. Echoes the downloaded file path on stdout.
# --------------------------------------------------------------------------------------------------
happ_download() {
  local os="$1" arch="${2:-x64}" out_dir="$3"
  local tag asset url out
  mkdir -p "$out_dir" || return 1

  tag="$(happ_latest_tag)" || return 1
  asset="$(happ_asset_for_os "$os" "$arch")" || return 1
  url="$(_happ_asset_url "$tag" "$asset")"
  out="$out_dir/$asset"

  _happ_say "$(t happ_downloading) ${asset} (${tag})"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --max-time 600 -o "$out" "$url" || { _happ_err "$(t happ_dl_fail) $url"; return 1; }
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$out" "$url" || { _happ_err "$(t happ_dl_fail) $url"; return 1; }
  else
    _happ_err "need curl or wget"; return 1
  fi
  [ -s "$out" ] || { _happ_err "$(t happ_dl_fail) (empty file) $url"; return 1; }
  printf '%s' "$out"
}

# --------------------------------------------------------------------------------------------------
# 4) Portable-ize.
#    Linux (SOLID): a .deb is an `ar` archive holding control/data members. Extract the data member
#                   (data.tar.{zst,xz,gz}) which contains usr/… ; collect it into a relocatable
#                   folder. Happ's ELF uses RUNPATH $ORIGIN/../lib so a moved tree still resolves
#                   its libs; proxy mode needs no admin. (CONTRACTS §7.)
#    macOS (BEST-EFFORT/UNVERIFIED): mount the .dmg, copy Happ.app, strip the quarantine xattr.
# --------------------------------------------------------------------------------------------------

# Unpack a single data.tar.* member into $2. Handles zst/xz/gz, with a zstd-pipe fallback for
# older tar builds that lack --zstd. $1 = path to the data tarball, $2 = destination root.
_happ_untar_data() {
  local tarball="$1" dst="$2"
  mkdir -p "$dst" || return 1
  case "$tarball" in
    *.zst)
      if tar --help 2>/dev/null | grep -q -- '--zstd'; then
        tar --zstd -xf "$tarball" -C "$dst"
      elif command -v zstd >/dev/null 2>&1; then
        zstd -dc "$tarball" | tar -xf - -C "$dst"
      else
        _happ_err "need tar --zstd or the zstd tool to unpack $tarball"; return 1
      fi ;;
    *.xz)  tar -xf "$tarball" -C "$dst" ;;   # GNU/BSD tar autodetect xz
    *.gz)  tar -xf "$tarball" -C "$dst" ;;
    *)     tar -xf "$tarball" -C "$dst" ;;
  esac
}

_happ_portableize_linux() {
  local deb="$1" dst="$2"
  command -v ar >/dev/null 2>&1 || { _happ_err "need 'ar' (binutils) to open the .deb"; return 1; }

  local work; work="$(mktemp -d)" || return 1
  # `ar x` extracts into CWD, so run it inside the temp dir against an absolute .deb path.
  local deb_abs; deb_abs="$(cd "$(dirname "$deb")" && pwd)/$(basename "$deb")"
  ( cd "$work" && ar x "$deb_abs" ) || { _happ_err "ar x failed on $deb"; rm -rf "$work"; return 1; }

  # Find the data member (name varies by dpkg version / compressor).
  local data
  data="$(ls "$work"/data.tar.* 2>/dev/null | head -n1)"
  [ -n "$data" ] || { _happ_err "no data.tar.* member in $deb"; rm -rf "$work"; return 1; }

  local payload="$work/payload"
  _happ_untar_data "$data" "$payload" || { rm -rf "$work"; return 1; }

  # The .deb lays files under /usr (usr/lib/Happ, usr/bin/happ, usr/share/...). Relocate that
  # tree wholesale into <dst> so the app keeps its internal relative layout (and RUNPATH).
  mkdir -p "$dst"
  if [ -d "$payload/usr" ]; then
    cp -a "$payload/usr/." "$dst/"
  else
    cp -a "$payload/." "$dst/"   # unexpected layout — relocate everything, don't lose files
  fi
  rm -rf "$work"

  # Locate the runnable Happ binary and remember it (run-happ wrapper + sub-insert need it).
  local bin
  bin="$(_happ_find_bin_linux "$dst")"
  [ -n "$bin" ] || { _happ_warn "$(t happ_bin_notfound)"; }
  [ -n "$bin" ] && chmod +x "$bin" 2>/dev/null || true
  _happ_say "$(t happ_portable_ok) -> $dst"
  printf '%s' "$dst"
}

# Find the actual executable inside an extracted Linux tree. Prefer a capitalised 'Happ',
# fall back to lowercase 'happ'; skip obvious non-launchers.
_happ_find_bin_linux() {
  local dst="$1" b
  for b in "$dst/bin/Happ" "$dst/bin/happ" "$dst/lib/Happ/Happ" "$dst/opt/Happ/Happ"; do
    [ -f "$b" ] && { printf '%s' "$b"; return 0; }
  done
  # Generic search: an executable file literally named Happ or happ.
  b="$(find "$dst" -maxdepth 5 -type f \( -name 'Happ' -o -name 'happ' \) 2>/dev/null | head -n1)"
  [ -n "$b" ] && printf '%s' "$b"
}

_happ_portableize_mac() {
  # BEST-EFFORT / UNVERIFIED — no Mac to verify (CONTRACTS §0). Mount, copy, de-quarantine.
  local dmg="$1" dst="$2"
  _happ_warn "$(t happ_mac_experimental)"
  command -v hdiutil >/dev/null 2>&1 || { _happ_err "hdiutil missing (not macOS?)"; return 1; }

  local mnt; mnt="$(mktemp -d)" || return 1
  if ! hdiutil attach "$dmg" -nobrowse -mountpoint "$mnt" >/dev/null 2>&1; then
    _happ_err "$(t happ_dmg_mount_fail) $dmg"; rm -rf "$mnt"; return 1
  fi

  local app; app="$(find "$mnt" -maxdepth 2 -name '*.app' 2>/dev/null | head -n1)"
  if [ -z "$app" ]; then
    _happ_err "$(t happ_no_app_in_dmg)"; hdiutil detach "$mnt" >/dev/null 2>&1; rm -rf "$mnt"; return 1
  fi

  mkdir -p "$dst"
  cp -a "$app" "$dst/" || { _happ_err "copy .app failed"; hdiutil detach "$mnt" >/dev/null 2>&1; rm -rf "$mnt"; return 1; }
  hdiutil detach "$mnt" >/dev/null 2>&1
  rm -rf "$mnt"

  local copied="$dst/$(basename "$app")"
  # Strip Gatekeeper quarantine so it launches without the "unidentified developer" block.
  if command -v xattr >/dev/null 2>&1; then
    xattr -dr com.apple.quarantine "$copied" 2>/dev/null || true
  fi
  _happ_warn "$(t happ_mac_gatekeeper_note)"
  _happ_say "$(t happ_portable_ok) -> $copied"
  printf '%s' "$copied"
}

# Dispatcher: happ_portableize <os> <asset_path> <dst_dir>
happ_portableize() {
  local os="$1" asset="$2" dst="$3"
  case "$os" in
    linux)            _happ_portableize_linux "$asset" "$dst" ;;
    mac|macos|darwin) _happ_portableize_mac   "$asset" "$dst" ;;
    *) _happ_err "happ_portableize: unknown os '$os'"; return 1 ;;
  esac
}

# --------------------------------------------------------------------------------------------------
# 5) run-happ wrapper — redirects Happ's config ONTO the stick and launches it in proxy mode.
#    Written to <dst_dir>/run-happ.sh. <dst_dir> = .../apps/happ on the stick.
#    Config redirect (CONTRACTS §6): XDG_CONFIG_HOME + HOME both point at apps/happ/data so Happ
#    writes Happ.conf / subs.db there instead of the host's home — true portability, no host trace.
# --------------------------------------------------------------------------------------------------
happ_write_runner() {
  local os="$1" dst="$2"
  local runner="$dst/run-happ.sh"
  cat > "$runner" <<'RUNHAPP'
#!/usr/bin/env bash
# run-happ.sh — launch the bundled, portable Happ with its config redirected onto the stick.
# Proxy mode only (never TUN — TUN needs admin). Generated by shared/happ.sh.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"   # .../apps/happ

# Redirect ALL config writes into apps/happ/data so nothing lands in the host home dir.
export XDG_CONFIG_HOME="$HERE/data"
export HOME="$HERE/data"
mkdir -p "$XDG_CONFIG_HOME" 2>/dev/null || true

# Locate the Happ executable inside this portable tree (layout: bin/Happ, lib/Happ/Happ, …).
HAPP_BIN=""
for c in "$HERE/bin/Happ" "$HERE/bin/happ" "$HERE/lib/Happ/Happ" "$HERE/opt/Happ/Happ" "$HERE/Happ.app/Contents/MacOS/Happ"; do
  [ -x "$c" ] && { HAPP_BIN="$c"; break; }
done
if [ -z "$HAPP_BIN" ]; then
  HAPP_BIN="$(find "$HERE" -maxdepth 5 -type f \( -name 'Happ' -o -name 'happ' \) 2>/dev/null | head -n1)"
fi
if [ -z "$HAPP_BIN" ]; then
  echo "run-happ: Happ binary not found under $HERE" >&2
  exit 1
fi

# Pass through any args (e.g. a happ:// deep-link forwarded to the running instance).
exec "$HAPP_BIN" "$@"
RUNHAPP
  chmod +x "$runner" 2>/dev/null || true
  _happ_say "$(t happ_runner_written) $runner"
  printf '%s' "$runner"
}

# --------------------------------------------------------------------------------------------------
# 6) Insert the subscription via the happ:// deep-link.
#    Happ is a SingleApplication (QLocalServer IPC): invoking the binary with a happ:// URL forwards
#    it to the already-running instance, which imports the sub and AES-persists it to its own subs.db.
#    NEVER write subs.db directly. (CONTRACTS §7.)
#      - raw subscription URL  -> "happ://add/<URL-ENCODED url>"
#      - ready "happ://crypt5/…" (or any happ://…) -> passed VERBATIM (accept-as-pasted, no minting)
#    Accept-as-pasted ONLY — we never call third-party minting (no crypto.happ.su).
# --------------------------------------------------------------------------------------------------

# Percent-encode a raw subscription URL for embedding after happ://add/.
_happ_urlencode() {
  local s="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys,urllib.parse; sys.stdout.write(urllib.parse.quote(sys.argv[1], safe=""))' "$s"
    return
  fi
  # Pure-bash fallback (POSIX-safe; LC_ALL=C so we iterate raw bytes).
  local out= c i LC_ALL=C
  for (( i=0; i<${#s}; i++ )); do
    c="${s:$i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) out+="$(printf '%%%02X' "'$c")" ;;
    esac
  done
  printf '%s' "$out"
}

# Turn whatever the user pasted into a happ:// deep-link.
#   already-a-deeplink  -> verbatim
#   raw http(s) sub URL -> happ://add/<urlenc>
_happ_build_deeplink() {
  local raw="$1"
  case "$raw" in
    happ://*) printf '%s' "$raw" ;;                         # crypt5 / add / any happ:// — verbatim
    *)        printf 'happ://add/%s' "$(_happ_urlencode "$raw")" ;;
  esac
}

# Re-find the binary for the given os/dst (used by the inserter independently of portableize).
_happ_locate_bin() {
  local os="$1" dst="$2" b
  case "$os" in
    mac|macos|darwin)
      b="$(find "$dst" -maxdepth 4 -path '*/Contents/MacOS/Happ' 2>/dev/null | head -n1)"
      [ -n "$b" ] && { printf '%s' "$b"; return 0; }
      # also allow a copied Happ.app dir
      b="$(find "$dst" -maxdepth 2 -name '*.app' 2>/dev/null | head -n1)"
      [ -n "$b" ] && { printf '%s' "$b"; return 0; } ;;
    *)
      _happ_find_bin_linux "$dst" ;;
  esac
}

# Snapshot the newest mtime among Happ's persisted state files (Happ.conf / subs.db) so we can
# detect that the import actually landed (CONTRACTS §7: verify via subs.db updated_at bump).
_happ_state_mtime() {
  local datadir="$1" m=0 f
  for f in "$datadir"/Happ.conf "$datadir"/*/Happ.conf "$datadir"/subs.db "$datadir"/*/subs.db; do
    [ -f "$f" ] || continue
    local fm
    fm="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)"
    [ "${fm:-0}" -gt "$m" ] && m="$fm"
  done
  printf '%s' "$m"
}

# happ_insert_sub <os> <dst_dir> <raw_url_or_deeplink>
# <dst_dir> = .../apps/happ (the portable tree containing run-happ.sh + data/).
happ_insert_sub() {
  local os="$1" dst="$2" raw="$3"
  local datadir="$dst/data"
  local deeplink; deeplink="$(_happ_build_deeplink "$raw")"

  local bin; bin="$(_happ_locate_bin "$os" "$dst")"
  if [ -z "$bin" ]; then
    _happ_warn "$(t happ_bin_notfound)"
    _happ_print_manual "$deeplink"
    return 1
  fi

  # Make sure Happ is running with its config on the stick (the deep-link is forwarded over IPC to
  # the live instance). Launch via run-happ.sh so the config redirect is identical to runtime.
  mkdir -p "$datadir" 2>/dev/null || true
  local before; before="$(_happ_state_mtime "$datadir")"

  local runner="$dst/run-happ.sh"
  if [ ! -x "$runner" ]; then happ_write_runner "$os" "$dst" >/dev/null; fi

  _happ_say "$(t happ_starting)"
  # Start (or no-op if already running) the portable instance in the background, give it a moment.
  ( "$runner" >/dev/null 2>&1 & ) || true
  local waited=0
  while [ "$waited" -lt 8 ]; do
    sleep 1; waited=$((waited+1))
  done

  _happ_say "$(t happ_inserting_sub)"
  case "$os" in
    mac|macos|darwin)
      # macOS forwards URL schemes through `open`; fall back to the binary directly.
      if command -v open >/dev/null 2>&1; then open "$deeplink" >/dev/null 2>&1 || "$bin" "$deeplink" >/dev/null 2>&1 || true
      else "$bin" "$deeplink" >/dev/null 2>&1 || true; fi ;;
    *)
      # Linux: the happ:// scheme is NOT registered as an xdg handler on the stick → call the
      # binary directly so SingleApplication IPC forwards the URL to the running instance.
      "$runner" "$deeplink" >/dev/null 2>&1 || "$bin" "$deeplink" >/dev/null 2>&1 || true ;;
  esac

  # Give the running instance time to import + AES-persist to subs.db, then verify the mtime bumped.
  waited=0
  while [ "$waited" -lt 12 ]; do
    sleep 1; waited=$((waited+1))
    local now; now="$(_happ_state_mtime "$datadir")"
    if [ "${now:-0}" -gt "${before:-0}" ]; then
      _happ_say "$(t happ_sub_ok)"
      return 0
    fi
  done

  # Could not confirm the import (Happ not connected / first-run dialog / autoconnect off).
  _happ_warn "$(t happ_sub_unverified)"
  _happ_print_manual "$deeplink"
  return 1
}

# On any failure, print the deep-link so the user can import it manually once.
_happ_print_manual() {
  local deeplink="$1"
  _happ_say "$(t happ_manual_hint)"
  printf '    %s\n' "$deeplink" >&2
}
