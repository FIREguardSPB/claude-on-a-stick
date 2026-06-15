# claude-on-a-stick - BUILD CONTRACTS (source of truth)

A public, MIT, cross-platform interactive **builder** that turns a USB stick into a
portable, no-install **real Claude Code** environment (the user's own subscription),
with an encrypted auth token, an anti-ban geo-guard, and an optional bundled Happ VPN.
The repo ships ONLY logic - the Claude binary, Happ, the auth token and any
subscription link are downloaded/entered **at build time** and land on the stick,
never in git.

Decisions locked (do not re-litigate):
- Targets: **Windows + Linux = solid/verified**, **macOS = best-effort/guided** (no Mac to verify; print an "experimental" notice + manual fallbacks).
- Subscription: **accept the link as the user pastes it** (raw sub URL → `happ://add/<urlenc>`, or a ready `happ://crypt5/…` verbatim). **No third-party minting** (no crypto.happ.su).
- Channel default: **stable** (option: latest). Token: **`claude setup-token`** (long-lived, inference-only). Repo: **public, MIT**. `build.ps1` is **first-class** (audience downloads on Windows). Partition: **single MBR + exFAT type 0x07**. GPG manifest verify: **best-effort** (on if `gpg` present).
- Default model on the stick: `claude-opus-4-8` (configurable via a build prompt → baked into the launcher as `--model`).

---

## 1. Repo tree (GitHub-ready)
```
claude-on-a-stick/
  README.md                 # English (primary)
  README.ru.md              # Russian
  LICENSE                   # MIT
  .gitignore                # blocks binaries/tokens/sub-links/built sticks
  CONTRACTS.md              # this file (dev source of truth)
  docs/
    ARCHITECTURE.md
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
Builder writes onto the stick: `bin/<platform>/claude(.exe)`, `config/{oauth.enc,settings.json,.claude.json}`,
`apps/happ-<os>/…` (optional), `projects/`, `tmp/`, plus the payload launchers (templated for the chosen OS(es) + language + model).
The `bin/<platform>/` layout is used for **both** single- and multi-target builds so the launcher binary-resolution path is uniform (see §12).

## 2. Stick layout (the produced artifact)
The layout is identical whether the stick was built for one OS or several - only the set of
`bin/<platform>/` subdirs and launcher files present differs (see §12).
```
<STICK>/
  START.(bat|sh)   DIAG.(bat|sh)   env.(bat|sh)   vpnup.(bat|sh)
  geoguard.(bat|sh) geoguard.ps1   geoguard.conf  decrypt.(ps1|sh)
  bin/<platform>/claude(.exe)          # one subdir per built platform, e.g. bin/win32-x64/claude.exe
  config/  oauth.enc  settings.json  .claude.json     # = CLAUDE_CONFIG_DIR (shared by every OS)
  apps/happ-<os>/ …  run-happ.(bat|sh)                # optional VPN, one per bundled OS
  projects/   tmp/   README-STICK.txt
```

## 3. Launcher chain & env protocol (MUST be identical across OSes)
`START` does, in order:
1. `vpnup` - if `apps/happ` exists: bring Happ up (proxy mode), export proxy env. (Skippable; see geoguard step 0.)
2. `geoguard` - see §5. Aborts launch if exit country is blocked.
3. token unlock (`env` calls `decrypt`) - prompt **"Stick password"**, decrypt `config/oauth.enc` to memory.
4. `cd` to `projects/`, exec `"$CLAUDE_BIN"` (resolved by `env` to the right per-OS/arch binary under `bin/<platform>/` - see §12).

Env set before claude (names are EXACT):
- `CLAUDE_CONFIG_DIR=<STICK>/config`
- `HOME=<STICK>/config` (POSIX) and `USERPROFILE` left as host on Windows but `CLAUDE_CONFIG_DIR` governs
- `TMP` and `TEMP` = `<STICK>/tmp`
- `ANTHROPIC_API_KEY=` (cleared, so it can't override the subscription token)
- `CLAUDE_CODE_OAUTH_TOKEN=<decrypted token>` (in memory only - never written to disk)
- `DISABLE_AUTOUPDATER=1` and `DISABLE_UPDATES=1`
- If VPN active: `HTTPS_PROXY=http://127.0.0.1:<port>`, `HTTP_PROXY=` same, `ALL_PROXY=socks5://127.0.0.1:<port>` (only if a SOCKS port is known), `NO_PROXY=localhost,127.0.0.1,::1`
- Launch: `"%CLAUDE_BIN%" --model <MODEL> %*` / `"$CLAUDE_BIN" --model <MODEL> "$@"`  (`CLAUDE_BIN` resolved by `env`; MODEL baked at build, default `claude-opus-4-8`)

cmd gotcha (LEARNED THE HARD WAY): **never put unescaped `(` `)` inside an `echo` that sits within a cmd `if ( … )` block** - it closes the block early ("Непредвиденное появление: then"). Use `goto` labels instead of parenthesised blocks in .bat files.

## 4. Crypto - token at rest (`oauth.enc`)  [VERIFIED round-trip]
On-disk format: `salt[16] || iv[16] || AES-256-CBC(PKCS7) ciphertext`.
KDF: **PBKDF2-HMAC-SHA1, 300000 iterations, 32-byte key**. (SHA1 chosen for universal .NET/openssl/LibreSSL compatibility.)

ENCRYPT (builder side):
- Linux/macOS (python+openssl): `key=hashlib.pbkdf2_hmac('sha1',pw,salt,300000,32)`; `openssl enc -aes-256-cbc -K <keyhex> -iv <ivhex>` over the plaintext; write `salt+iv+ct`.
- Windows (pure PowerShell): `Rfc2898DeriveBytes(pw,salt,300000)` (3-arg ctor = SHA1) → 32-byte key; `[Security.Cryptography.Aes]` CBC/PKCS7.

DECRYPT (stick launch):
- Windows `decrypt.ps1` (VERIFIED): reads bytes, `[byte[]]$salt=$all[0..15];$iv=$all[16..31];$ct=$all[32..]`; `Rfc2898DeriveBytes($pw,$salt,300000)`; Aes CBC/PKCS7 `TransformFinalBlock`; print token to stdout (no newline); prompt written to **stderr** so stdout carries only the token; exit 1 on failure.
- Linux `decrypt.sh`: read salt/iv via `head -c`/`tail -c`+`od -An -tx1` (no `xxd` on mac); derive key with `openssl kdf -keylen 32 -kdfopt digest:SHA1 -kdfopt pass:… -kdfopt salt:… -kdfopt iter:300000 PBKDF2` (OpenSSL 3); `openssl enc -d -aes-256-cbc -K <keyhex> -iv <ivhex>`.
- macOS `decrypt.sh` fallback: LibreSSL has **no `openssl kdf`** → derive the key with a one-line `perl` Digest::SHA PBKDF2-HMAC-SHA1 (VERIFIED to match), then `openssl enc -d`.

Caller captures stdout into `CLAUDE_CODE_OAUTH_TOKEN`; the password prompt is interactive+masked (PS `Read-Host -AsSecureString`; bash `read -rs`).

## 5. Geo-guard (anti-ban) - `geoguard.conf` + `geoguard.{sh,ps1}`
`geoguard.conf`: `GUARD_ENABLED=1`, `BLOCKLIST=RU,BY,CU,IR,KP,SY`, `INCONCLUSIVE=prompt` (prompt|block|allow).
Logic:
0. If `GUARD_ENABLED=0` → return OK immediately (for users in unrestricted regions).
1. Check exit country **direct** (no proxy) via `https://www.cloudflare.com/cdn-cgi/trace` (`loc=XX`), fallbacks `ipinfo.io/country`, `api.country.is`.
2. If country **not** in BLOCKLIST → **OK, do NOT touch the VPN** (smart skip - the user's whole point).
3. If blocked → bring up bundled Happ (`vpnup`) and re-check **through the proxy** (`Invoke-RestMethod -Proxy` / `curl --proxy`).
4. Still blocked or no VPN → **refuse** to launch.
5. Undetermined → per `INCONCLUSIVE`.
Detection cmds: PS `Invoke-RestMethod`/`Invoke-WebRequest -Proxy`; bash `curl --max-time 8` (+`--proxy` on recheck). Only the HTTP proxy works for the recheck (PS 5.1 has no SOCKS).

## 6. VPN bring-up - `vpnup` + Happ (optional)
- If no `apps/happ` → return OK (rely on host/system VPN; geoguard still governs).
- Launch Happ via `run-happ` wrapper that redirects its config onto the stick: Windows `set APPDATA=<STICK>\apps\happ\data`; POSIX `XDG_CONFIG_HOME`/`HOME` to a stick dir. Happ proxy mode only - **never TUN** (TUN needs admin everywhere).
- **Auto-detect the proxy port** (Happ defaults vary; observed 10808 mixed): probe `10808,10809,2080,1080,10800,8080` by making a real HTTP request through each (`http://cloudflare.com/cdn-cgi/trace`); first that returns 200 is the HTTP proxy → set `HTTPS_PROXY`.
- Wait/poll up to ~20-30s for the proxy (Happ may take a moment to connect). Tell the user to enable Happ **auto-connect on launch** (otherwise they must click connect once).

## 7. Happ - download, portable-ize, insert subscription  [verbs VERIFIED in the live binary]
Releases: github.com/Happ-proxy/happ-desktop (~v2.17). Win=`setup-Happ.x64.exe` (Inno 6.7), Linux=`.deb`/`.pkg.tar.zst`/`.rpm`, macOS=`.dmg` (universal).
Portable-ize per OS:
- **Linux** (solid): `.deb` → `ar x Happ.linux.x64.deb && tar xf data.tar.zst` (or `.deb` data member) → relocatable folder (RUNPATH `$ORIGIN/../lib`), proxy mode no admin.
- **Windows** (guided): innoextract 1.9 CANNOT read Inno 6.7 → use **silent Inno install to a dir**: `setup-Happ.x64.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /NOICONS /CURRENTUSER /DIR=<dst>` (asInvoker, no admin), then copy the folder. (Builder runs on Windows; if building a Windows stick from Linux, use Wine: `wine setup-Happ.x64.exe /VERYSILENT /DIR=Z:\…`.)
- **macOS** (best-effort/UNVERIFIED): mount `.dmg`, copy `Happ.app`; warn about Gatekeeper/quarantine (`xattr -dr com.apple.quarantine`), codesigning + proxy-mode-no-elevation unverified.
NO VC++ runtime is bundled with Happ on Windows - most Win10/11 have it; if a bare client errors `msvcp140.dll`, document bundling the VC++ redist DLLs.
**Subscription insert** (Happ is a SingleApplication, QLocalServer IPC - invoking the binary with a `happ://` URL forwards it to the running instance which imports + AES-persists to its own subs.db; **never write subs.db directly**):
- raw URL → `Happ(.exe|.app) "happ://add/<URL-ENCODED sub>"`; ready `happ://crypt5/…` → pass verbatim.
- Windows: `cmd /c start "" "happ://add/…"` or `Happ.exe "happ://…"`. Linux: `/path/Happ "happ://…"` (scheme not registered as xdg handler → call binary directly). macOS: `open "happ://…"`.
- This is **guided/best-effort**, not fully silent: needs Happ running; verify via `Happ.conf` `lastSubscription` / `subs.db` `updated_at` bump; on failure, **print the deep link** for the user to import manually once.

## 8. Claude binary download  [VERIFIED]
Manifest host: `https://downloads.claude.ai/claude-code-releases/`.
- Resolve version: GET `/stable` (or `/latest`) → bare semver.
- GET `/<ver>/manifest.json` → `platforms.<plat>.{binary,checksum,size}`. Optionally verify `manifest.json.sig` with the GPG release key when `gpg` is present.
- For **each** selected platform: download `/<ver>/<plat>/<binary>` into its own `bin/<plat>/` subdir and **sha256-verify** against `checksum`; abort on mismatch; `chmod +x` the posix ones.
- Platforms: `win32-x64`, `win32-arm64`, `darwin-x64`, `darwin-arm64`, `linux-x64`, `linux-arm64`, `linux-x64-musl`, `linux-arm64-musl`. Binary name: `claude.exe` (win) / `claude` (else). Self-contained (no Node).
- Multi-target: the target step may pick **several** platforms in one run (see §12); each lands in its own `bin/<plat>/`.

## 9. i18n (RU/EN) - builder UX
- Ask language FIRST (default from `$LANG` / `Get-Culture`; single keypress to override).
- One nested message map `msg[lang][key]` + accessor `t key` (bash) / `T key` (ps). All user-facing strings go through it; technical tokens (claude, Happ, flags, env names, paths) stay untranslated.
- bash: `declare -A` (Bash 4+). macOS `/bin/bash` is 3.2 (no assoc arrays) → re-exec under Homebrew bash 4+ OR use a `case`-based fallback. PowerShell: hashtable; save scripts **UTF-8 with BOM** for PS 5.1; `[Console]::OutputEncoding=[Text.Encoding]::UTF8`.
- Stick launcher messages: baked in the chosen language at build time (keep them short).

## 10. USB select + format (guards)  [verified detection cmds]
- Linux: `lsblk -dno NAME,TRAN,RM,TYPE,SIZE,MODEL` → keep `TYPE=disk AND TRAN=usb`; never offer internal; user picks explicitly (don't auto-pick - a USB HDD is also TRAN=usb); `wipefs -a`, partition table **MBR**, one partition **type 0x07**, `mkfs.exfat -L CLAUDE`. Needs `exfatprogs` + root. `sfdisk` may be absent → fall back to `parted` then set MBR type 7 via `sfdisk`/`fdisk` (install `fdisk` pkg if needed).
- Windows: `Get-Disk | ? BusType -eq 'USB'`; confirm by size+model; `Clear-Disk` + `New-Partition` + `Format-Volume -FileSystem exFAT -NewFileSystemLabel CLAUDE` (admin); MBR.
- macOS: `diskutil list external physical`; `diskutil eraseDisk ExFAT CLAUDE MBRFormat /dev/diskN`.
- ALL: show device id+size+model, require typed `ERASE`/`YES` confirmation echoing the device id before formatting. Never offer system/internal disks.

## 11. Security / what NOT to commit
`.gitignore` must exclude: `*.exe`, `claude`, `bin/`, `apps/`, `*.enc`, `oauth*`, `*.token`, any `*.json` that could hold creds, `dist/`, built sticks, Happ payloads. README states clearly: binaries (Claude, Happ) are downloaded from official sources at build time and are NOT redistributed here; the auth token is the user's own (`claude setup-token`), AES-encrypted with their password; transcripts/work on the stick are plaintext under token-only encryption → for client PII, use whole-volume encryption (BitLocker To Go / VeraCrypt / LUKS) - documented in SECURITY.md.

## 12. Multi-OS sticks ("one stick, any OS")
One USB that runs Claude Code on **Windows, Linux AND macOS** from the **same encrypted token**.
Built on top of the existing single-target builder/launchers; **single-target builds keep working unchanged** (the single target defaults to **this host**).

1. **Target step (multi-select).** Accept a **comma-separated** list of platforms, plus a shortcut `A` = "all common" = `win32-x64` + `linux-x64` + `darwin-arm64`. Default stays the single host target. Choosable platforms: `win32-x64`, `win32-arm64`, `linux-x64`, `linux-arm64`, `linux-x64-musl`, `linux-arm64-musl`, `darwin-x64`, `darwin-arm64`.
2. **Format ONCE.** The destructive USB format (§10) runs a **single time** regardless of how many targets are selected.
3. **Binary layout (uniform).** `bin/<platform>/claude` (posix) or `bin/<platform>/claude.exe` (windows), used for **both** single- and multi-target builds. Download + **sha256-verify** each selected platform into its own subdir; `chmod +x` the posix ones (§8).
4. **Launcher union.** Copy the **Windows** set (`START.bat DIAG.bat env.bat vpnup.bat geoguard.bat geoguard.ps1 decrypt.ps1 run-happ.bat`) if **any** `win32-*` target was chosen; copy the **POSIX** set (`start.sh diag.sh env.sh vpnup.sh geoguard.sh decrypt.sh run-happ.sh`) if **any** linux/darwin target was chosen. `geoguard.conf` + `README-STICK.txt` are **always** copied.
5. **Shared, written ONCE.** `config/` (`oauth.enc`, `settings.json`, `.claude.json`), `projects/`, `tmp/`. The AES token is **OS-agnostic** - PowerShell and openssl decrypt the same `oauth.enc` (verified; AES format and env-var names are **unchanged** from §3/§4). The token menu + encrypt step happen **once**.
6. **Launcher binary-resolution (`CLAUDE_BIN`).** `env.bat`/`env.sh` compute `CLAUDE_BIN` to the right per-OS/arch binary; `START`/`DIAG` exec `"$CLAUDE_BIN"`.
   - `env.bat`: `PROCESSOR_ARCHITECTURE` (`AMD64`→`x64`, `ARM64`→`arm64`) → `bin/win32-<arch>/claude.exe`; fall back to any present `win32-*` dir; error if none.
   - `env.sh`: `uname -s` (`Linux`→`linux`, `Darwin`→`darwin`) + `uname -m` (`x86_64`→`x64`, `aarch64|arm64`→`arm64`) + linux musl detection (`ldd --version` mentions `musl`, or `/lib/ld-musl*` exists → append `-musl`) → `bin/<os>-<arch>[-musl]/claude`; fall back to the closest present variant; error if none.
7. **Happ/VPN per-OS (optional).** Happ binaries are OS-specific and ~300MB each. In multi-OS mode VPN bundling stays **optional**; if requested, bundle Happ per selected OS into `apps/happ-<os>/` and `vpnup` resolves the right one for the running OS. **Default multi-OS = NO bundled Happ** (rely on host/system VPN; the geoguard "no `apps/happ` → host VPN" fallback stays). Keep it simple + documented.
8. **Docs.** Both READMEs headline this near the top ("One stick, every OS" / "Одна флешка - любая ОС"); the layout/flow sections and `docs/ARCHITECTURE.md` reflect multi-target + binary-resolution.

INVARIANTS: do **not** change the AES at-rest format (§4) or any env-var name (§3); single-target builds must keep working; verify by **running** `build.sh` (stubbed multi), `build.ps1` under `pwsh` StrictMode, and the env resolution - not by ParseFile alone. Never commit binaries/secrets (§11).
