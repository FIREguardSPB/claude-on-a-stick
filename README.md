# claude-on-a-stick

**Carry the *real* Claude Code on a USB stick — your own subscription, no install, no trace left behind.**

`claude-on-a-stick` is an interactive **builder** that turns a USB stick into a
portable Claude Code environment. Plug it into almost any Windows, Linux, or
macOS machine, run one launcher, type your stick password — and you are inside a
genuine `claude` session running on **your own subscription token**. Nothing is
installed on the host, and nothing is left behind when you unplug.

> 🇷🇺 Russian / На русском: see **[README.ru.md](README.ru.md)**.

---

## What it actually is

- **The real Claude Code**, not a wrapper or a reimplementation. The builder
  downloads the official, self-contained `claude` binary from Anthropic's release
  channel at build time and places it on the stick.
- **Your own subscription.** Authentication uses a long-lived, inference-only
  token you mint yourself with `claude setup-token`. The builder encrypts it at
  rest with **your password** (AES-256). It is never committed, never uploaded.
- **No install, no trace.** The stick carries its own config dir, temp dir, and
  working `projects/` folder. `CLAUDE_CONFIG_DIR` and `HOME`/`TMP` are redirected
  onto the stick, so the host machine's profile is untouched.
- **An anti-ban geo-guard.** Before launching, the stick checks your exit
  country. If you are in a region where running Claude could risk your account,
  it refuses to launch (or routes you through a bundled VPN first — see below).
- **An optional, bundled VPN.** You can fold a portable copy of the
  [Happ](https://github.com/Happ-proxy/happ-desktop) proxy client onto the stick
  and import *your own* subscription, so the geo-guard has something to fall back
  on. This is entirely optional and bring-your-own.

---

## Honesty up front (read this)

This project does not pretend everything works equally everywhere. Here is the
real status:

| Area | Status |
|------|--------|
| **Windows** stick + builder (`build.ps1`) | ✅ Solid / verified |
| **Linux** stick + builder (`build.sh`) | ✅ Solid / verified |
| **macOS** stick + builder | 🧪 **Experimental / best-effort.** We have no Mac to verify on. The macOS paths print an "experimental" notice and give manual fallbacks. Gatekeeper/quarantine, codesigning, and Happ's proxy-without-elevation behaviour are **unverified** on macOS. |
| **VPN (Happ)** | Optional. **Bring your own** subscription link. Not required if you are in an unrestricted region or already use a system/host VPN. |
| **Subscription auto-insert** | **Guided, not fully silent.** The builder forwards your `happ://` link to a running Happ instance over its local IPC. If the import does not "take," the builder prints the deep link so you can import it manually once. |

If you need a guarantee, use Windows or Linux. macOS users: it may well work,
but you are the test pilot.

---

## Quick start (using a stick someone already built)

You received (or built) a stick labelled `CLAUDE`. Plug it in and:

### Windows
1. Open the stick in Explorer.
2. Double-click **`START.bat`** (it runs as your normal user — no admin needed).
3. Enter your **stick password** when prompted.
4. Claude Code opens in a console, working out of the stick's `projects/` folder.

### Linux
```sh
cd /run/media/$USER/CLAUDE     # or wherever the stick mounted
./start.sh
# enter your stick password when prompted
```
If `start.sh` is not executable: `chmod +x start.sh` first.

### macOS (experimental)
```sh
cd /Volumes/CLAUDE
./start.sh
```
You may have to clear quarantine on the bundled binaries the first time:
`xattr -dr com.apple.quarantine /Volumes/CLAUDE`. See the experimental notice the
script prints.

### When something is off
Run **`DIAG.bat`** / **`diag.sh`** on the stick — it reports the detected exit
country, whether the VPN/proxy is up, the config paths in use, and whether the
token decrypts. Start there before filing an issue.

---

## Build flow (creating a stick)

You build the stick once, on a machine you trust, then carry it. The builder is
interactive and walks you through every step.

> ⚠️ Formatting a stick **erases it completely.** The builder shows the device
> id, size, and model, and makes you type a confirmation (`ERASE`/`YES`) that
> echoes the device id before it touches anything. It will never offer your
> internal/system disks.

### On Linux / macOS
```sh
git clone https://github.com/<you>/claude-on-a-stick.git
cd claude-on-a-stick
sudo ./builders/posix/build.sh      # root needed to format the USB
```

### On Windows
```powershell
git clone https://github.com/<you>/claude-on-a-stick.git
cd claude-on-a-stick
# Run an elevated PowerShell (admin needed to format the USB):
powershell -ExecutionPolicy Bypass -File .\builders\windows\build.ps1
```

The builder will, in order:

1. **Pick a language** (RU/EN, defaulting to your system locale).
2. **Select the USB stick** from removable disks only, confirm by size+model,
   and format it as a single MBR + exFAT volume labelled `CLAUDE`.
3. **Download the official `claude` binary** for your chosen target platform
   and channel (default: **stable**; **latest** optional), verifying its
   SHA-256 checksum (and the GPG-signed manifest when `gpg` is available).
4. **Take your auth token.** Run `claude setup-token` if you have not already,
   paste the token, choose a **stick password**, and the builder AES-encrypts
   it to `config/oauth.enc`.
5. **Choose the default model** (baked into the launcher as `--model`; default
   `claude-opus-4-8`).
6. **Optionally add the Happ VPN:** download + portable-ize Happ for the target
   OS and import *your* subscription link (raw sub URL → `happ://add/…`, or a
   ready `happ://crypt5/…` verbatim).
7. **Copy the launcher payload** (templated for the chosen OS, language, and
   model) onto the stick.

Result: a self-contained `CLAUDE` stick you can hand to any supported machine.

---

## Security model (please understand this)

`claude-on-a-stick` encrypts **the auth token only**. Here is the precise threat
model — and its sharp edge:

- **Token at rest is AES-256 encrypted with your password.** The on-disk format
  is `salt(16) || iv(16) || AES-256-CBC(PKCS7) ciphertext`, key derived with
  PBKDF2-HMAC-SHA1, 300 000 iterations. The decrypted token lives only in memory
  during a session (env var `CLAUDE_CODE_OAUTH_TOKEN`) and is never written to
  disk. `ANTHROPIC_API_KEY` is cleared so it cannot override your subscription.
- **Your transcripts and work are NOT encrypted.** Everything under the stick's
  `projects/` and `config/` (chat history, files you create, `.claude.json`) is
  stored **in plaintext**. Token-only encryption protects your *account*, not
  your *data*.
- **For client/PII data, use whole-volume encryption.** If the stick will ever
  hold sensitive or client data, put the whole volume behind **BitLocker To Go**
  (Windows), **VeraCrypt** (cross-platform), or **LUKS** (Linux). The
  token-vs-volume trade-off is documented in **`docs/SECURITY.md`**.
- **The geo-guard is a safety rail, not a cloak.** It checks your exit country
  and can refuse to launch in blocked regions, optionally routing through the
  bundled VPN first. It reduces account-risk; it is not anonymity.

---

## Legal & honesty note

- **No third-party binaries are redistributed in this repository.** The Claude
  Code binary is downloaded from Anthropic's official release host, and the Happ
  client from its official GitHub releases — **at build time, onto your stick.**
  This repo contains only build logic, launcher templates, and docs.
- **The subscription is yours.** The auth token is minted by *you* with
  `claude setup-token` against *your own* Anthropic subscription. No tokens are
  minted, brokered, or proxied by this project, and no third-party token service
  is used.
- **The VPN subscription is yours too.** You bring your own Happ subscription
  link. This project neither sells nor provides VPN access.
- Use of Claude Code is governed by Anthropic's terms; use of Happ by Happ's
  terms. Respect the laws and account terms that apply to you. This software is
  provided "as is" under the **[MIT License](LICENSE)** with no warranty.

---

## Documentation

- **[README.ru.md](README.ru.md)** — этот README на русском.
- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — how the pieces fit together.
- **[docs/SECURITY.md](docs/SECURITY.md)** — full threat model and PII guidance.
- **[CONTRACTS.md](CONTRACTS.md)** — the binding build specification (for contributors).
