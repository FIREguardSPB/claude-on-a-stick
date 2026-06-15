# Architecture - claude-on-a-stick

This document explains *how* claude-on-a-stick is put together. It is a companion
to [`CONTRACTS.md`](../CONTRACTS.md) (the binding build spec) and to
[`SECURITY.md`](./SECURITY.md) (the threat model). Where this doc and `CONTRACTS.md`
disagree, **`CONTRACTS.md` wins** - it is the source of truth.

> One-line summary: a public, MIT, interactive **builder** turns a blank USB stick
> into a portable, no-install environment that runs the **real Claude Code** CLI
> against the user's **own** subscription, with the auth token stored AES-encrypted,
> an anti-ban **geo-guard**, and an **optional** bundled Happ VPN.

> **One stick, every OS.** A single build can target Windows, Linux **and** macOS at
> once: per-OS binaries land under `bin/<platform>/`, the launcher set is unioned, and
> the **same** encrypted token + `config/` are shared by every OS. At launch, `env`
> resolves `CLAUDE_BIN` to the binary that matches the running OS/arch. See §12.

The repo ships **only logic**. The Claude Code binary, the Happ VPN, the auth token,
and any subscription link are downloaded or entered **at build time** and land on the
stick - they are **never** committed to git (see `.gitignore` and
[`SECURITY.md`](./SECURITY.md)).

---

## 1. The 3-layer model

claude-on-a-stick is best understood as three layers with a clean separation of
concerns. Layer 1 runs **on the build host, once**. Layers 2 and 3 live **on the
stick** and run **every time** the stick is plugged into a target PC.

```
                         BUILD HOST (run once)                 TARGET PC (run each plug-in)
  ┌───────────────────────────────────────────┐   ┌──────────────────────────────────────────┐
  │ LAYER 1 - BUILDER                           │   │ LAYER 3 - RUNTIME GUARD                    │
  │  builders/posix/build.sh                    │   │  START → vpnup → geoguard → env/decrypt →  │
  │  builders/windows/build.ps1                 │   │         cd projects/ → exec claude         │
  │  (+ shared/: i18n, crypto, happ, usb)       │   │  (geo-guard, token unlock, proxy wiring)   │
  │                                             │   └──────────────────────────────────────────┘
  │  • pick language (RU/EN)                    │                      ▲ reads / drives
  │  • select + format USB (exFAT, MBR, 0x07)   │                      │
  │  • download claude binary (sha256-verified) │   ┌──────────────────────────────────────────┐
  │  • optionally download + portable-ize Happ  │   │ LAYER 2 - PAYLOAD (the produced artifact)  │
  │  • `claude setup-token` → AES-encrypt       │──▶│  bin/<platform>/claude(.exe)               │
  │  • paste subscription link → Happ deep-link │   │  config/{oauth.enc,settings.json,...}      │
  │  • copy payload templates onto the stick    │   │  apps/happ-<os>/… (optional)               │
  └─────────────────────────────────────────────┘   │  launchers (START/DIAG/env/vpnup/...)      │
                                                     │  projects/  tmp/  README-STICK.txt         │
                                                     └──────────────────────────────────────────┘
```

### Layer 1 - Builder (`builders/` + `shared/`)
Interactive, runs once on the user's own machine to **produce** a stick. It is the
only layer that touches the network for downloads, formats the USB, mints/encrypts the
token, and templates the launchers for the chosen OS(es) + language + model. It writes
the payload onto the stick and then exits; it leaves no daemon behind.

One build can target **one OS or several at once** (multi-select target step). When
several are chosen, the destructive USB format still runs **once**, each selected
platform's binary lands in its own `bin/<platform>/` subdir, the launcher set is the
**union** of the per-OS launchers, and `config/` + the encrypted token are written
**once** and shared by every OS. Full rules in §12.

Two first-class entry points (no shared runtime between them - only shared *design*):
- `builders/posix/build.sh` - Linux (solid/verified) + macOS (best-effort/guided).
- `builders/windows/build.ps1` - Windows. **First-class**: the Windows audience is
  expected to download and run the builder directly on Windows.

Shared helpers, split by language because the two builders never call each other:
- `shared/i18n.sh` / `shared/i18n.ps1` - RU/EN message map + accessor.
- `shared/crypto.sh` / `shared/crypto.ps1` - token encrypt/decrypt (build side).
- `shared/happ.sh` / `shared/happ.ps1` - download, portable-ize, deep-link the sub.
- `shared/usb.sh` / `shared/usb.ps1` - enumerate removable disks, confirm, format.

### Layer 2 - Payload (the produced artifact on the stick)
The static result of a build. It contains the Claude binary, the encrypted token and
config, the optional Happ VPN, the user's `projects/`, and the launcher scripts. The
payload is templated from `payload/` at build time - the templates in the repo carry
**no** secrets; the per-stick values (OS, language, model, proxy port) are baked in by
the builder.

### Layer 3 - Runtime guard (the launcher chain on the stick)
The behaviour that runs **every time** the user double-clicks `START` on a target PC.
It brings up the VPN if present, enforces the geo-guard, unlocks the token in memory,
sets the exact environment, and execs the real `claude` binary. This layer is what
makes the stick *safe to use* (anti-ban) and *portable* (no install, config redirected
onto the stick). Details in §4-§7 below.

---

## 2. Per-OS support reality (read this before filing bugs)

The decision is locked: **Windows + Linux = solid/verified; macOS = best-effort/guided.**
We have no Mac to verify against, so the macOS paths print an "experimental" notice and
offer manual fallbacks rather than pretending to be turnkey.

| Concern                | Linux (solid)                              | Windows (solid)                                   | macOS (best-effort)                                  |
|------------------------|--------------------------------------------|---------------------------------------------------|------------------------------------------------------|
| Builder entry point    | `builders/posix/build.sh`                  | `builders/windows/build.ps1` (first-class)        | `builders/posix/build.sh` (re-exec under bash 4+)    |
| Token crypto           | python `pbkdf2_hmac` + `openssl enc`       | .NET `Rfc2898DeriveBytes` + `Aes`                 | LibreSSL: **no** `openssl kdf` → `perl` PBKDF2 fallback |
| USB format             | `wipefs`+MBR+type 0x07+`mkfs.exfat` (root) | `Clear-Disk`/`New-Partition`/`Format-Volume`(admin)| `diskutil eraseDisk ExFAT … MBRFormat`               |
| Happ portable-ize      | `.deb` → `ar x` + `tar xf` (relocatable)   | silent Inno install `/VERYSILENT /DIR=` → copy    | mount `.dmg`, copy `Happ.app`; Gatekeeper unverified |
| Bash assoc arrays      | Bash 4+ (`declare -A`)                     | n/a                                               | `/bin/bash` is 3.2 → re-exec Homebrew bash 4+ or `case` |
| Status                 | **verified**                               | **verified**                                      | **experimental / guided**                            |

macOS-specific caveats that are explicitly **unverified**: Happ codesigning,
proxy-mode-without-elevation, and the Gatekeeper/quarantine flow
(`xattr -dr com.apple.quarantine`). The macOS crypto **decrypt** path is verified to
round-trip (the `perl` Digest::SHA PBKDF2-HMAC-SHA1 matches), but the surrounding
build flow is not end-to-end tested on real hardware.

---

## 3. Repo tree

```
claude-on-a-stick/
  README.md                 # English (primary)
  README.ru.md              # Russian
  LICENSE                   # MIT
  .gitignore                # blocks binaries/tokens/sub-links/built sticks
  CONTRACTS.md              # binding dev source of truth
  docs/
    ARCHITECTURE.md         # this file
    SECURITY.md             # threat model: token-only AES vs whole-volume; PII note
  builders/
    posix/build.sh          # interactive builder for Linux (solid) + macOS (best-effort)
    windows/build.ps1       # interactive builder for Windows
  shared/
    i18n.sh                 # RU/EN message map + t() for bash
    i18n.ps1                # RU/EN message map + T() for PowerShell
    crypto.sh               # encrypt/decrypt helpers (openssl, + macOS perl PBKDF2 fallback)
    crypto.ps1              # encrypt/decrypt helpers (.NET Rfc2898 + Aes)
    happ.sh                 # download + portable-ize Happ (linux/mac) + deep-link sub insert
    happ.ps1                # download + portable-ize Happ (windows) + deep-link sub insert
    usb.sh / usb.ps1        # enumerate removable disks, confirm, format exFAT
  payload/                  # TEMPLATES copied to the stick by the builder
    START.bat  start.sh
    DIAG.bat   diag.sh
    env.bat    env.sh
    vpnup.bat  vpnup.sh
    geoguard.bat geoguard.ps1 geoguard.sh
    geoguard.conf
    decrypt.ps1 decrypt.sh
    README-STICK.txt
```

The builder writes onto the stick: `bin/<platform>/claude(.exe)`,
`config/{oauth.enc,settings.json,.claude.json}`, `apps/happ-<os>/…` (optional),
`projects/`, `tmp/`, plus the payload launchers (templated for the chosen OS(es) +
language + model). The `bin/<platform>/` layout is used for **both** single- and
multi-target builds so the launcher binary-resolution path is uniform (§12).

### Produced stick layout
Identical whether built for one OS or several - only the set of `bin/<platform>/`
subdirs and the launcher files present differs (§12).
```
<STICK>/
  START.(bat|sh)   DIAG.(bat|sh)   env.(bat|sh)   vpnup.(bat|sh)
  geoguard.(bat|sh) geoguard.ps1   geoguard.conf  decrypt.(ps1|sh)
  bin/<platform>/claude(.exe)          # one subdir per built platform, e.g. bin/win32-x64/claude.exe
  config/  oauth.enc  settings.json  .claude.json     # = CLAUDE_CONFIG_DIR (shared by every OS)
  apps/happ-<os>/ …  run-happ.(bat|sh)                # optional VPN, one per bundled OS
  projects/   tmp/   README-STICK.txt
```

---

## 4. The launcher chain (runtime guard, in order)

`START` is the single entry point on the stick. It orchestrates the other launchers.
The order and the env protocol are **identical across all OSes** by contract - this is
non-negotiable so that a stick behaves the same whether plugged into Windows, Linux, or
macOS.

```
START
  │
  ├─ 1. vpnup        if apps/happ exists → bring Happ up (proxy mode only, never TUN),
  │                  export proxy env. Skippable; see geoguard step 0.
  │
  ├─ 2. geoguard     check exit country (see §6). ABORTS the launch if the exit
  │                  country is in the blocklist and no working VPN can fix it.
  │
  ├─ 3. env→decrypt  prompt "Stick password", decrypt config/oauth.enc to MEMORY.
  │                  The token is never written back to disk.
  │
  └─ 4. cd projects/ ; exec "$CLAUDE_BIN" --model <MODEL> "$@"   (CLAUDE_BIN resolved by
                                                                  env to the per-OS/arch
                                                                  binary, see §12; MODEL
                                                                  baked at build, default
                                                                  claude-opus-4-8)
```

`CLAUDE_BIN` is computed by `env` (step 3) from the running OS/arch so the same stick
launches the matching binary on Windows, Linux, or macOS - see §12 for the resolution
rules.

### Env set before claude (names are EXACT - see `CONTRACTS.md` §3)
- `CLAUDE_CONFIG_DIR=<STICK>/config`
- `HOME=<STICK>/config` (POSIX). On Windows, `USERPROFILE` is left as the host's, but
  `CLAUDE_CONFIG_DIR` governs where Claude reads/writes config.
- `TMP` and `TEMP` = `<STICK>/tmp`
- `ANTHROPIC_API_KEY=` - **cleared**, so a stray host API key can't override the
  subscription token.
- `CLAUDE_CODE_OAUTH_TOKEN=<decrypted token>` - **in memory only, never on disk.**
- `DISABLE_AUTOUPDATER=1` and `DISABLE_UPDATES=1` - the stick's binary is pinned.
- If a VPN is active:
  `HTTPS_PROXY=http://127.0.0.1:<port>`, `HTTP_PROXY=` (same value),
  `ALL_PROXY=socks5://127.0.0.1:<port>` (only if a SOCKS port is known),
  `NO_PROXY=localhost,127.0.0.1,::1`.

### cmd `.bat` gotcha (learned the hard way)
**Never put an unescaped `(` or `)` inside an `echo` that sits within a cmd
`if ( … )` block** - the `)` closes the `if` block early and cmd dies with
"Непредвиденное появление: then" / "was unexpected at this time". In `.bat` launchers,
use `goto` labels instead of parenthesised `if`/`else` blocks whenever the body
contains echoed text that may include parentheses.

---

## 5. Crypto format - token at rest (`config/oauth.enc`)

The auth token comes from `claude setup-token` (a long-lived, inference-only token) and
is stored AES-encrypted on the stick, unlocked with a password the user types at every
launch. The on-disk format and KDF are fixed so that any of the three OS toolchains can
read a stick made on any other.

**On-disk byte format (verified round-trip):**
```
salt[16] || iv[16] || AES-256-CBC(PKCS7) ciphertext
```
**KDF:** PBKDF2-HMAC-**SHA1**, **300000** iterations, **32-byte** key.
SHA1 is chosen deliberately for universal .NET / OpenSSL / LibreSSL compatibility (the
3-argument `Rfc2898DeriveBytes` constructor defaults to SHA1).

**Encrypt (builder side):**
- Linux/macOS (python + openssl):
  `key = hashlib.pbkdf2_hmac('sha1', pw, salt, 300000, 32)`, then
  `openssl enc -aes-256-cbc -K <keyhex> -iv <ivhex>` over the plaintext; write
  `salt + iv + ct`.
- Windows (pure PowerShell): `Rfc2898DeriveBytes(pw, salt, 300000)` (3-arg ctor = SHA1)
  → 32-byte key; `[Security.Cryptography.Aes]` in CBC/PKCS7.

**Decrypt (stick launch):**
- Windows `decrypt.ps1` (verified): read bytes,
  `[byte[]]$salt=$all[0..15]; $iv=$all[16..31]; $ct=$all[32..]`;
  `Rfc2898DeriveBytes($pw,$salt,300000)`; Aes CBC/PKCS7 `TransformFinalBlock`; print the
  token to **stdout** with no trailing newline; write the password prompt to **stderr**
  so stdout carries only the token; exit 1 on failure.
- Linux `decrypt.sh`: read salt/iv via `head -c` / `tail -c` + `od -An -tx1`
  (no `xxd` on mac); derive the key with OpenSSL 3
  `openssl kdf -keylen 32 -kdfopt digest:SHA1 -kdfopt pass:… -kdfopt salt:… -kdfopt iter:300000 PBKDF2`;
  then `openssl enc -d -aes-256-cbc -K <keyhex> -iv <ivhex>`.
- macOS `decrypt.sh` fallback: LibreSSL has **no** `openssl kdf` → derive the key with a
  one-line `perl` Digest::SHA PBKDF2-HMAC-SHA1 (verified to match), then `openssl enc -d`.

The caller captures stdout into `CLAUDE_CODE_OAUTH_TOKEN`. The password prompt is
interactive and masked: PowerShell `Read-Host -AsSecureString`, bash `read -rs`.

---

## 6. Geo-guard flow (anti-ban)

The geo-guard is the reason this stick is *safe to use*: it refuses to launch Claude
from an exit country known to be blocked, and it leaves the host's networking untouched
when the user is already in a safe region. Rationale and limits are in
[`SECURITY.md`](./SECURITY.md); the mechanics are here.

Config - `geoguard.conf`:
```
GUARD_ENABLED=1
BLOCKLIST=RU,BY,CU,IR,KP,SY
INCONCLUSIVE=prompt        # prompt | block | allow
```

Flow - `geoguard.{sh,ps1}` (and `geoguard.bat` shim):
```
0. GUARD_ENABLED=0 ?  ──yes──▶ return OK immediately (unrestricted-region users)
        │ no
        ▼
1. Detect exit country DIRECT (no proxy):
     https://www.cloudflare.com/cdn-cgi/trace  (parse loc=XX)
     fallbacks: ipinfo.io/country , api.country.is
        │
        ▼
2. Country NOT in BLOCKLIST ?  ──yes──▶ OK, and DO NOT touch the VPN (smart skip -
        │ no                            this is the user's whole point)
        ▼
3. Blocked → bring up bundled Happ (vpnup) and RE-CHECK through the proxy
     (Invoke-RestMethod -Proxy / curl --proxy)
        │
        ├─ now safe ──▶ OK, launch through the proxy
        │
        ▼
4. Still blocked, or no VPN available  ──▶ REFUSE to launch
        │
        ▼
5. Undetermined (no network / all probes failed) ──▶ act per INCONCLUSIVE
                                                      (prompt | block | allow)
```

Detection commands: PowerShell `Invoke-RestMethod` / `Invoke-WebRequest -Proxy`; bash
`curl --max-time 8` (plus `--proxy` on the recheck). **Only the HTTP proxy works for the
recheck** - PowerShell 5.1 has no SOCKS support, so the recheck always goes through
`HTTPS_PROXY`.

---

## 7. Happ (the optional bundled VPN)

Happ is **optional**. If the stick has no `apps/happ`, `vpnup` returns OK and the
geo-guard simply relies on the host or system VPN (and still governs the launch). When
Happ *is* bundled, it is always run in **proxy mode, never TUN** - TUN needs admin on
every OS, which breaks the no-install promise.

### Bring-up - `vpnup`
- Launch Happ via a `run-happ` wrapper that **redirects Happ's config onto the stick**
  so nothing is written to the host profile:
  - Windows: `set APPDATA=<STICK>\apps\happ\data`
  - POSIX: `XDG_CONFIG_HOME` / `HOME` → a stick directory
- **Auto-detect the proxy port** - Happ's default varies (10808 observed, mixed). Probe
  `10808, 10809, 2080, 1080, 10800, 8080` by making a *real* HTTP request through each
  (`http://cloudflare.com/cdn-cgi/trace`); the first that returns 200 is the HTTP proxy
  → set `HTTPS_PROXY` to it.
- Poll up to ~20-30s for the proxy to come up (Happ may take a moment to connect). Tell
  the user to enable **auto-connect on launch** in Happ; otherwise they must click
  connect once.

### Download + portable-ize (build time)
Releases: `github.com/Happ-proxy/happ-desktop` (~v2.17). Per OS:
- **Linux (solid):** `.deb` → `ar x Happ.linux.x64.deb && tar xf data.tar.zst` → a
  relocatable folder (RUNPATH `$ORIGIN/../lib`); proxy mode, no admin.
- **Windows (guided):** innoextract 1.9 **cannot** read Inno 6.7 installers → use a
  silent Inno install to a directory:
  `setup-Happ.x64.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /NOICONS /CURRENTUSER /DIR=<dst>`
  (asInvoker, no admin), then copy the folder. (If building a Windows stick from Linux,
  run the installer under Wine: `wine setup-Happ.x64.exe /VERYSILENT /DIR=Z:\…`.)
  Note: Happ on Windows bundles **no** VC++ runtime - most Win10/11 have it; if a bare
  client errors `msvcp140.dll`, bundle the VC++ redist DLLs (documented).
- **macOS (best-effort/unverified):** mount the `.dmg`, copy `Happ.app`; warn about
  Gatekeeper/quarantine (`xattr -dr com.apple.quarantine`). Codesigning and
  proxy-mode-without-elevation are unverified.

### Subscription insert (deep-link, guided/best-effort)
Happ is a `SingleApplication` using a `QLocalServer` for IPC: invoking the binary with a
`happ://` URL forwards it to the running instance, which imports the sub and
**AES-persists it to its own `subs.db`**. We **never write `subs.db` directly**.
- Accept the link **as the user pastes it**: a raw subscription URL is wrapped as
  `happ://add/<URL-ENCODED sub>`; a ready `happ://crypt5/…` is passed **verbatim**.
  **No third-party minting** (no `crypto.happ.su`).
- Invocation per OS:
  - Windows: `cmd /c start "" "happ://add/…"` or `Happ.exe "happ://…"`
  - Linux: `/path/Happ "happ://…"` (the scheme is not registered as an xdg handler, so
    call the binary directly)
  - macOS: `open "happ://…"`
- This is guided, not fully silent: Happ must be running. Verify success via
  `Happ.conf` `lastSubscription` / a `subs.db` `updated_at` bump; on failure, **print the
  deep link** so the user can import it manually once.

---

## 8. Claude binary download (build time)

Manifest host: `https://downloads.claude.ai/claude-code-releases/`.
1. Resolve the version: GET `/stable` (default) or `/latest` → a bare semver string.
2. GET `/<ver>/manifest.json` → `platforms.<plat>.{binary,checksum,size}`. When `gpg` is
   present, best-effort verify `manifest.json.sig` against the GPG release key.
3. For **each** selected platform, download `/<ver>/<plat>/<binary>` into its own
   `bin/<plat>/` subdir and **sha256-verify** against `checksum`; abort on mismatch;
   `chmod +x` the posix ones.

Platforms: `win32-x64`, `win32-arm64`, `darwin-x64`, `darwin-arm64`, `linux-x64`,
`linux-arm64`, `linux-x64-musl`, `linux-arm64-musl`. Binary name is `claude.exe` on
Windows, `claude` elsewhere. The binary is self-contained (no Node runtime needed). A
multi-OS build (§12) selects several platforms in one run; each lands in its own
`bin/<plat>/`.

---

## 9. i18n (builder UX)

- Ask the **language first** (default derived from `$LANG` / `Get-Culture`; a single
  keypress overrides).
- One nested message map `msg[lang][key]` with an accessor: `t key` (bash) /
  `T key` (PowerShell). **All** user-facing strings go through it. Technical tokens
  (claude, Happ, flags, env-var names, paths) stay **untranslated**.
- bash: `declare -A` needs Bash 4+. macOS `/bin/bash` is 3.2 (no associative arrays) →
  re-exec under Homebrew bash 4+ **or** use a `case`-based fallback.
- PowerShell: a hashtable; save the scripts **UTF-8 with BOM** for PS 5.1 and set
  `[Console]::OutputEncoding=[Text.Encoding]::UTF8`.
- Stick launcher messages are **baked in the chosen language at build time** (kept
  short).

---

## 10. USB selection + format (guards)

Single partition, **MBR**, one partition of **type 0x07**, formatted **exFAT** with
label `CLAUDE`. Per OS:
- **Linux:** `lsblk -dno NAME,TRAN,RM,TYPE,SIZE,MODEL` → keep only `TYPE=disk AND
  TRAN=usb`; never offer internal disks; the user picks **explicitly** (do **not**
  auto-pick - a USB HDD is also `TRAN=usb`). `wipefs -a`, MBR table, partition type
  0x07, `mkfs.exfat -L CLAUDE`. Needs `exfatprogs` + root. `sfdisk` may be absent → fall
  back to `parted`, then set MBR type 7 via `sfdisk`/`fdisk` (install the `fdisk`
  package if needed).
- **Windows:** `Get-Disk | ? BusType -eq 'USB'`; confirm by size + model;
  `Clear-Disk` + `New-Partition` + `Format-Volume -FileSystem exFAT -NewFileSystemLabel
  CLAUDE` (admin); MBR.
- **macOS:** `diskutil list external physical`; `diskutil eraseDisk ExFAT CLAUDE
  MBRFormat /dev/diskN`.
- **All OSes:** show device id + size + model and require a typed `ERASE`/`YES`
  confirmation that echoes the device id before formatting. Never offer system/internal
  disks.

---

## 11. Locked decisions (do not re-litigate)

- Targets: **Windows + Linux = solid/verified**, **macOS = best-effort/guided** (no Mac
  to verify → print an "experimental" notice + manual fallbacks).
- Subscription: **accept the link as the user pastes it** (raw sub URL →
  `happ://add/<urlenc>`, or a ready `happ://crypt5/…` verbatim). **No third-party
  minting** (no `crypto.happ.su`).
- Channel default: **stable** (option: latest). Token: **`claude setup-token`**
  (long-lived, inference-only). Repo: **public, MIT**. `build.ps1` is **first-class**
  (the audience downloads on Windows). Partition: **single MBR + exFAT type 0x07**. GPG
  manifest verify: **best-effort** (on if `gpg` is present).
- Default model on the stick: `claude-opus-4-8` (configurable via a build prompt →
  baked into the launcher as `--model`).

---

## 12. Multi-OS sticks ("one stick, any OS")

One USB that runs Claude Code on **Windows, Linux AND macOS** from the **same encrypted
token**. This is built **on top of** the single-target builder/launchers - single-target
builds keep working unchanged, and the single target still defaults to **this host**.

### How a build picks targets
The target step accepts a **comma-separated list** of platforms, plus a shortcut `A` =
"all common" = `win32-x64` + `linux-x64` + `darwin-arm64`. Selectable platforms:
`win32-x64`, `win32-arm64`, `linux-x64`, `linux-arm64`, `linux-x64-musl`,
`linux-arm64-musl`, `darwin-x64`, `darwin-arm64`.

What changes per build phase when multiple targets are chosen:

| Phase            | Single target              | Multiple targets                                                  |
|------------------|----------------------------|-------------------------------------------------------------------|
| USB format       | once                       | **once** (the destructive step never repeats)                     |
| Claude binary    | `bin/<plat>/claude(.exe)`  | one `bin/<plat>/` per selected platform, each sha256-verified     |
| Launchers        | the chosen OS's set        | **union**: Windows set if any `win32-*`, POSIX set if any linux/darwin |
| Token + `config/`| written once               | written **once**, shared (the AES token is OS-agnostic)           |
| Happ / VPN       | optional, for that OS      | optional; if requested, one `apps/happ-<os>/` per OS (default: none) |

### Why the layout is uniform
The `bin/<platform>/` layout is used for **both** single- and multi-target builds. That
keeps the launcher binary-resolution path identical in every case: a single-OS stick is
just a multi-OS stick with one `bin/<platform>/` subdir.

### Launcher union (what gets copied)
- **Windows set** (copied if any `win32-*` target was chosen):
  `START.bat DIAG.bat env.bat vpnup.bat geoguard.bat geoguard.ps1 decrypt.ps1 run-happ.bat`.
- **POSIX set** (copied if any linux/darwin target was chosen):
  `start.sh diag.sh env.sh vpnup.sh geoguard.sh decrypt.sh run-happ.sh`.
- **Always:** `geoguard.conf` + `README-STICK.txt`.

### Shared, written once
`config/` (`oauth.enc`, `settings.json`, `.claude.json`), `projects/`, and `tmp/` are
written a single time and shared by every OS. The AES token is **OS-agnostic**:
PowerShell (`decrypt.ps1`) and openssl/`perl` (`decrypt.sh`) decrypt the **same**
`oauth.enc` - the on-disk format (§5) and every env-var name (§4) are **unchanged**. So
the token menu + encrypt step run **once** no matter how many OSes the stick targets.

### Binary-resolution at launch (`CLAUDE_BIN`)
`env.bat` / `env.sh` compute `CLAUDE_BIN` to the binary that matches the **running**
OS/arch, and `START` / `DIAG` exec `"$CLAUDE_BIN"`:

- **`env.bat`** reads `PROCESSOR_ARCHITECTURE` (`AMD64`→`x64`, `ARM64`→`arm64`) →
  `bin/win32-<arch>/claude.exe`. If that exact subdir is missing it falls back to any
  present `win32-*` dir; if no `win32-*` binary exists at all, it errors out.
- **`env.sh`** reads `uname -s` (`Linux`→`linux`, `Darwin`→`darwin`) and `uname -m`
  (`x86_64`→`x64`, `aarch64`/`arm64`→`arm64`), plus **linux musl detection** (`ldd
  --version` mentions `musl`, or `/lib/ld-musl*` exists → append `-musl`) →
  `bin/<os>-<arch>[-musl]/claude`. If that variant is missing it falls back to the
  closest present variant; if none is present, it errors out.

### Happ / VPN per OS (optional)
Happ binaries are OS-specific and ~300MB each, so multi-OS VPN bundling stays
**optional** and is **off by default**. If the user asks for it, the builder bundles Happ
per selected OS into `apps/happ-<os>/`, and `vpnup` resolves the right one for the
running OS. With no bundled Happ, the existing geoguard fallback applies: "no `apps/happ`
→ rely on the host/system VPN" (geoguard still governs the launch). Kept simple and
documented on purpose.

### Invariants (do not break)
- The AES at-rest format (§5) and every env-var name (§4) are **frozen** - multi-OS reuse
  depends on them.
- **Single-target builds must keep working** exactly as before.
- Verify by **running** `build.sh` (stubbed multi-target), `build.ps1` under `pwsh`
  StrictMode, and the env resolution - not by ParseFile alone.
- Never commit binaries or secrets (see [`SECURITY.md`](./SECURITY.md) and `.gitignore`).
