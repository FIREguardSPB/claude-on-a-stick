#!/usr/bin/env bash
# shared/usb.sh — claude-on-a-stick
# ---------------------------------------------------------------------------
# Removable-disk enumeration + interactive pick + exFAT format helper.
#
# Contract refs (CONTRACTS.md §10 "USB select + format (guards)"):
#   Linux : lsblk -dno NAME,TRAN,RM,TYPE,SIZE,MODEL -> keep TYPE=disk AND TRAN=usb
#           never offer internal disks; user picks EXPLICITLY (no auto-pick:
#           a USB HDD is also TRAN=usb). Format = wipefs -a, MBR table,
#           ONE partition of type 0x07, mkfs.exfat -L CLAUDE.
#           Needs exfatprogs + root. sfdisk may be absent -> fall back to
#           parted, then set MBR partition type 7 via sfdisk/fdisk.
#   macOS : diskutil list external physical
#           diskutil eraseDisk ExFAT CLAUDE MBRFormat /dev/diskN
#   ALL   : show id+size+model, require a typed ERASE confirmation that
#           echoes the device id back, before destroying anything.
#           NEVER offer system/internal disks.
#
# i18n (CONTRACTS §9): ALL user-facing strings go through the project t()
# accessor from shared/i18n.sh, using the canonical dotted keys
# (usb.scanning, usb.row, usb.erase_prompt, fmt.start, …). t() prints WITHOUT
# a trailing newline (so it composes for prompts); tn() adds a newline.
# If shared/i18n.sh has NOT been sourced, we install a minimal English
# fallback that defines the SAME dotted keys + the same {0}/{1} placeholder
# substitution, so this library is robust standalone.
#
# This file is a LIBRARY: source it, then call usb_select_and_format (or the
# granular usb_enumerate / usb_select / usb_confirm / usb_format). It has NO
# top-level side effects (except direct-execution at the very bottom).
# ---------------------------------------------------------------------------

# --- Volume label (single source of truth, matches the produced artifact) ---
USB_LABEL="${USB_LABEL:-CLAUDE}"

# --- i18n shim --------------------------------------------------------------
# Prefer the real project accessor from shared/i18n.sh. If it is not loaded,
# define a self-contained English fallback using the SAME dotted keys this
# module emits, plus a local positional-placeholder substitution that mirrors
# i18n.sh's _i18n_subst.
if ! declare -F _i18n_subst >/dev/null 2>&1; then
  _i18n_subst() {
    local out="$1"; shift
    local i=0 arg
    for arg in "$@"; do
      out="${out//\{$i\}/$arg}"
      i=$((i + 1))
    done
    printf '%s' "$out"
  }
fi

if ! declare -F t >/dev/null 2>&1; then
  # Minimal English fallback catalogue — mirrors the usb.*/fmt.* keys from
  # shared/i18n.sh so behaviour is identical when sourced standalone.
  t() {
    local key="$1"; shift
    local tmpl
    case "$key" in
      usb.scanning)       tmpl="Scanning for removable USB disks…" ;;
      usb.none_found)     tmpl="No removable USB disk found. Plug one in and re-run." ;;
      usb.list_header)    tmpl="Detected removable disks (internal disks are NEVER offered):" ;;
      usb.row)            tmpl="  {0})  {1}   size={2}   model={3}" ;;
      usb.choose)         tmpl="Type the number of the target disk (or 'q' to quit): " ;;
      usb.bad_choice)     tmpl="Not a valid choice. Try again." ;;
      usb.is_hdd_warn)    tmpl="Note: a USB HDD also shows as a USB disk. Make ABSOLUTELY sure '{0}' is the stick you want to erase." ;;
      usb.warn_title)     tmpl="!!! DESTRUCTIVE ACTION — READ CAREFULLY !!!" ;;
      usb.warn_body)      tmpl="ALL data on {0} ({1}, {2}) will be PERMANENTLY ERASED. This cannot be undone." ;;
      usb.erase_prompt)   tmpl="To confirm, type ERASE {0} exactly (anything else cancels): " ;;
      usb.erase_mismatch) tmpl="Confirmation did not match. Nothing was erased." ;;
      fmt.start)          tmpl="Formatting {0} … (MBR, single exFAT partition type 0x07, label CLAUDE)" ;;
      fmt.wipe)           tmpl="  • Wiping existing signatures (wipefs)…" ;;
      fmt.parttable)      tmpl="  • Writing MBR partition table…" ;;
      fmt.partition)      tmpl="  • Creating one partition (type 0x07)…" ;;
      fmt.mkfs)           tmpl="  • Creating exFAT filesystem (label CLAUDE)…" ;;
      fmt.done)           tmpl="Format complete. Stick mounted at {0}." ;;
      fmt.need_root)      tmpl="Formatting needs root. Re-run with sudo, or grant passwordless sudo." ;;
      fmt.need_exfatprogs) tmpl="exfatprogs not found (need mkfs.exfat). Install exfatprogs and re-run." ;;
      fmt.need_parttool)  tmpl="Neither sfdisk nor parted found. Install util-linux/fdisk or parted and re-run." ;;
      err.macos_experimental) tmpl="NOTE: macOS is EXPERIMENTAL/best-effort (built without a Mac to verify). Manual fallbacks may be needed." ;;
      *)                  tmpl="<<$key>>" ;;
    esac
    _i18n_subst "$tmpl" "$@"
  }
fi

# tn(): translated line WITH a trailing newline (defined by i18n.sh; provide a
# fallback so this module works standalone).
if ! declare -F tn >/dev/null 2>&1; then
  tn() { printf '%s\n' "$(t "$@")"; }
fi

# --- small helpers ----------------------------------------------------------
# All interactive chrome goes to STDERR so the single machine-readable result
# line on STDOUT can be captured cleanly:  sel="$(usb_select)" || abort
_usb_emit() { printf '%s\n' "$*" >&2; }       # one translated/plain line -> stderr
_usb_say()  { _usb_emit "$(t "$@")"; }        # translate key (+args) -> stderr line

# Detect OS family once.
_usb_os() {
  case "$(uname -s 2>/dev/null)" in
    Darwin) echo "macos" ;;
    Linux)  echo "linux" ;;
    *)      echo "other" ;;
  esac
}

# ===========================================================================
# ENUMERATION
# ===========================================================================
# usb_enumerate_linux
#   Emits one line per candidate, TAB-separated:  /dev/sdX <TAB> SIZE <TAB> MODEL
#   Filter rule (CONTRACTS §10): TYPE==disk AND TRAN==usb. Internal NVMe/SATA
#   system disks have a non-usb TRAN and can never appear. A USB HDD is also
#   TRAN=usb, so it IS listed — but the caller forces an explicit human pick.
usb_enumerate_linux() {
  command -v lsblk >/dev/null 2>&1 || { _usb_emit "lsblk not found (util-linux)"; return 1; }
  # -d: whole disks only, -n: no header, -p: full /dev path, -o: exact columns.
  # Hard gate is TRAN==usb. We also read RM for context but do NOT gate on it
  # (some USB SSDs report RM=0).
  lsblk -dpno NAME,TRAN,RM,TYPE,SIZE,MODEL 2>/dev/null | awk '
    {
      name=$1; tran=$2; rm=$3; type=$4; size=$5;
      model="";
      for (i=6; i<=NF; i++) { model = model (i>6 ? " " : "") $i }
      if (model=="") model="(unknown model)";
      if (type=="disk" && tran=="usb") {
        printf "%s\t%s\t%s\n", name, size, model;
      }
    }'
}

# usb_enumerate_macos
#   Emits: /dev/diskN <TAB> SIZE <TAB> MODEL for EXTERNAL PHYSICAL disks only
#   ("external physical" already excludes internal/system disks).
usb_enumerate_macos() {
  command -v diskutil >/dev/null 2>&1 || { _usb_emit "diskutil not found"; return 1; }
  local dev
  for dev in $(diskutil list external physical 2>/dev/null \
                 | awk '/^\/dev\/disk[0-9]+ \(external, physical\)/{gsub(/:/,"",$1); print $1}'); do
    local size model
    size=$(diskutil info "$dev" 2>/dev/null | awk -F: '/Disk Size/{print $2; exit}' \
            | sed 's/^[[:space:]]*//;s/(.*$//;s/[[:space:]]*$//')
    model=$(diskutil info "$dev" 2>/dev/null | awk -F: '/Device \/ Media Name/{print $2; exit}' \
            | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$size" ]  && size="(?)"
    [ -z "$model" ] && model="(unknown model)"
    printf "%s\t%s\t%s\n" "$dev" "$size" "$model"
  done
}

# usb_enumerate -> dispatch by OS. Output: dev<TAB>size<TAB>model lines.
usb_enumerate() {
  case "$(_usb_os)" in
    linux) usb_enumerate_linux ;;
    macos) usb_enumerate_macos ;;
    *)     _usb_emit "Unsupported OS for USB enumeration."; return 1 ;;
  esac
}

# ===========================================================================
# SELECTION (interactive, explicit pick)
# ===========================================================================
# usb_select
#   Lists candidates and makes the user type a NUMBER to pick one (never auto-
#   picks even with a single candidate — a USB HDD is also TRAN=usb).
#   On success prints ONLY the chosen "dev<TAB>size<TAB>model" to STDOUT
#   (UI goes to STDERR) and returns 0;  q/abort/no-disk -> non-zero.
usb_select() {
  _usb_say usb.scanning
  [ "$(_usb_os)" = "macos" ] && _usb_say err.macos_experimental

  # Read candidates into parallel arrays.
  local -a devs sizes models
  local dev size model
  while IFS=$'\t' read -r dev size model; do
    [ -z "$dev" ] && continue
    devs+=("$dev"); sizes+=("$size"); models+=("$model")
  done < <(usb_enumerate)

  local n=${#devs[@]}
  if [ "$n" -eq 0 ]; then
    _usb_say usb.none_found
    return 1
  fi

  _usb_say usb.list_header
  local i
  for ((i=0; i<n; i++)); do
    _usb_emit "$(t usb.row "$((i+1))" "${devs[$i]}" "${sizes[$i]}" "${models[$i]}")"
  done

  # Explicit numeric pick. 'q' aborts.
  local choice
  while :; do
    printf '%s' "$(t usb.choose)" >&2
    read -r choice
    case "$choice" in
      q|Q) _usb_say usb.erase_mismatch; return 1 ;;   # treated as a cancel
      ''|*[!0-9]*) _usb_say usb.bad_choice ;;
      *)
        if [ "$choice" -ge 1 ] && [ "$choice" -le "$n" ]; then
          break
        fi
        _usb_say usb.bad_choice
        ;;
    esac
  done

  local idx=$((choice-1))
  # The ONLY thing on stdout: the machine-readable selection line.
  printf '%s\t%s\t%s\n' "${devs[$idx]}" "${sizes[$idx]}" "${models[$idx]}"
  return 0
}

# ===========================================================================
# CONFIRMATION (typed ERASE + echoed device id)
# ===========================================================================
# usb_confirm <dev> [size] [model]
#   Shows the loud destructive warning + the USB-HDD caveat, then requires the
#   user to type literally:  ERASE <dev>   (e.g. "ERASE /dev/sdb").
#   Returns 0 only on an exact match.
usb_confirm() {
  local dev="$1" size="${2:-?}" model="${3:-?}"
  _usb_emit ""
  _usb_say usb.warn_title
  _usb_say usb.is_hdd_warn "$dev"
  _usb_emit "$(t usb.warn_body "$dev" "$size" "$model")"
  _usb_emit ""
  printf '%s' "$(t usb.erase_prompt "$dev")" >&2
  local typed
  read -r typed
  if [ "$typed" = "ERASE $dev" ]; then
    return 0
  fi
  _usb_say usb.erase_mismatch
  return 1
}

# ===========================================================================
# FORMAT
# ===========================================================================
# usb_format_linux <dev>
#   wipefs -a -> MBR table -> one partition type 0x07 -> mkfs.exfat -L CLAUDE.
#   Tries sfdisk first (clean scriptable MBR + type 07); if sfdisk is absent,
#   falls back to parted, then forces partition type 0x07 via fdisk.
#   Echoes the partition node on stdout on success.
usb_format_linux() {
  local dev="$1"

  # --- prerequisite checks (fail loud, fail early) ---
  if [ "$(id -u)" -ne 0 ]; then
    _usb_say fmt.need_root
    return 1
  fi
  if ! command -v mkfs.exfat >/dev/null 2>&1; then
    _usb_say fmt.need_exfatprogs
    return 1
  fi
  if ! command -v sfdisk >/dev/null 2>&1 && ! command -v parted >/dev/null 2>&1; then
    _usb_say fmt.need_parttool
    return 1
  fi

  # Partition node naming: /dev/sdb -> /dev/sdb1, but /dev/mmcblk0 ->
  # /dev/mmcblk0p1 and /dev/nvme0n1 -> …p1 (kernel convention: 'p' suffix when
  # the device name ends in a digit).
  local part
  if [[ "$dev" =~ [0-9]$ ]]; then part="${dev}p1"; else part="${dev}1"; fi

  _usb_emit "$(t fmt.start "$dev")"

  # Best-effort unmount of any mounted partitions on this device.
  if command -v lsblk >/dev/null 2>&1; then
    local p
    for p in $(lsblk -lnpo NAME "$dev" 2>/dev/null | tail -n +2); do
      umount "$p" 2>/dev/null || true
    done
  fi

  # 1) Wipe all existing filesystem/partition signatures.
  _usb_say fmt.wipe
  wipefs -a "$dev" >&2 || { _usb_emit "$(t fmt.start "$dev"): wipefs failed"; return 1; }

  # 2) MBR table + single primary partition of type 0x07 (exFAT/NTFS/IFS).
  _usb_say fmt.parttable
  if command -v sfdisk >/dev/null 2>&1; then
    # sfdisk dos dialect: label=dos, one partition spanning the disk, type=7.
    printf 'label: dos\n,,7\n' | sfdisk --wipe always "$dev" >&2 \
      || { _usb_emit "sfdisk failed"; return 1; }
  else
    parted -s "$dev" mklabel msdos >&2 \
      || { _usb_emit "parted mklabel failed"; return 1; }
    # parted's "ntfs" fs-type sets the MBR type byte to 0x07 — correct for
    # exFAT too (there is no dedicated exFAT MBR id; 0x07 is the right one).
    parted -s -a optimal "$dev" mkpart primary ntfs 1MiB 100% >&2 \
      || { _usb_emit "parted mkpart failed"; return 1; }
    # Belt-and-braces: force type 0x07 via fdisk if available.
    if command -v fdisk >/dev/null 2>&1; then
      printf 't\n07\nw\n' | fdisk "$dev" >/dev/null 2>&1 || true
    fi
  fi
  _usb_say fmt.partition

  # Re-read the partition table so the new node appears.
  command -v partprobe >/dev/null 2>&1 && partprobe "$dev" 2>/dev/null || true
  command -v udevadm   >/dev/null 2>&1 && udevadm settle 2>/dev/null   || true
  local tries=0
  while [ ! -b "$part" ] && [ "$tries" -lt 10 ]; do
    sleep 1; tries=$((tries+1))
  done
  if [ ! -b "$part" ]; then
    _usb_emit "Partition node $part did not appear."
    return 1
  fi

  # 3) exFAT filesystem labelled CLAUDE.
  _usb_say fmt.mkfs
  mkfs.exfat -L "$USB_LABEL" "$part" >&2 \
    || { _usb_emit "mkfs.exfat failed"; return 1; }

  _usb_emit "$(t fmt.done "$part")"
  printf '%s\n' "$part"   # stdout: the partition node now labelled CLAUDE
  return 0
}

# usb_format_macos <dev>
#   diskutil eraseDisk ExFAT CLAUDE MBRFormat /dev/diskN (one shot: MBR scheme
#   + exFAT volume labelled CLAUDE). Echoes the device id on stdout on success.
usb_format_macos() {
  local dev="$1"
  command -v diskutil >/dev/null 2>&1 || { _usb_emit "diskutil not found"; return 1; }
  _usb_say err.macos_experimental
  _usb_emit "$(t fmt.start "$dev")"
  diskutil unmountDisk force "$dev" 2>/dev/null || true
  if diskutil eraseDisk ExFAT "$USB_LABEL" MBRFormat "$dev" >&2; then
    _usb_emit "$(t fmt.done "$dev")"
    printf '%s\n' "$dev"
    return 0
  fi
  _usb_emit "diskutil eraseDisk failed"
  return 1
}

# usb_format <dev> -> dispatch by OS.
usb_format() {
  local dev="$1"
  [ -z "$dev" ] && { _usb_emit "usb_format: missing device argument"; return 2; }
  case "$(_usb_os)" in
    linux) usb_format_linux "$dev" ;;
    macos) usb_format_macos "$dev" ;;
    *)     _usb_emit "Unsupported OS for USB format."; return 1 ;;
  esac
}

# ===========================================================================
# ORCHESTRATOR (the one the builder usually calls)
# ===========================================================================
# usb_select_and_format
#   Full guarded flow: enumerate -> explicit pick -> typed ERASE confirm ->
#   format. On success prints the produced partition/device node to STDOUT
#   (so the caller knows what to mount/copy onto). Non-zero on any abort/fail.
usb_select_and_format() {
  local sel dev size model
  sel="$(usb_select)" || return 1          # captures the single stdout line
  IFS=$'\t' read -r dev size model <<<"$sel"
  [ -z "$dev" ] && { _usb_say usb.bad_choice; return 1; }

  usb_confirm "$dev" "$size" "$model" || return 1
  local node
  node="$(usb_format "$dev")" || return 1

  # Tell the caller (stdout) the device/partition node that is now CLAUDE.
  printf '%s\n' "${node:-$dev}"
  return 0
}

# ---------------------------------------------------------------------------
# Allow direct execution for manual testing:  bash shared/usb.sh
# (When sourced, $0 is the parent script, so this block is skipped.)
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  usb_select_and_format
fi
