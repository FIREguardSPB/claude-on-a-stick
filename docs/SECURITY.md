# Security & Threat Model — claude-on-a-stick

This document describes what claude-on-a-stick protects, what it does **not** protect,
and the trade-offs behind the locked design decisions. Read it together with
[`ARCHITECTURE.md`](./ARCHITECTURE.md) (how the pieces fit) and
[`CONTRACTS.md`](../CONTRACTS.md) (the binding spec). Where this doc and `CONTRACTS.md`
disagree, **`CONTRACTS.md` wins**.

> TL;DR: the stick encrypts **one thing well** — your Claude auth token, with AES-256
> behind a password. **Everything else on the stick is plaintext**: your transcripts,
> your project files, and the Happ VPN subscription (within Happ's own store). If the
> stick can hold client PII or other sensitive data, put **whole-volume encryption**
> underneath it (BitLocker To Go / VeraCrypt / LUKS). The geo-guard reduces account-ban
> risk; it is not a privacy or anonymity tool.

---

## 1. What we are defending, and against whom

The stick exists to run the user's **own** Claude Code subscription on borrowed/client
Windows (and Linux/mac) PCs with **no install and minimal trace**. The assets and the
realistic adversaries:

| Asset                                  | Primary threat                                   | Defense in this project                              |
|----------------------------------------|--------------------------------------------------|------------------------------------------------------|
| Claude auth token (`oauth.enc`)        | Stick lost/stolen; another person reads the file | **AES-256-CBC, PBKDF2-HMAC-SHA1 ×300k, password-gated** |
| The Claude **account** (not just token)| Geo-based ban for connecting from a blocked exit | **Geo-guard** refuses to launch from a blocked country |
| Subscription / VPN sub link            | Leaking the user's paid VPN sub                  | Stored only inside Happ's own AES store on the stick |
| User's work / transcripts              | Casual read on a found stick; host forensics     | **NOT encrypted by us** — see §3, §4                 |
| The host PC                            | The stick leaving install residue                | Config redirected onto the stick; no daemons left    |

Out of scope (explicitly): defending against a compromised/malicious **host OS** (a
keylogger or memory scraper on the client PC can capture the password and the in-memory
token while Claude runs), nation-state forensic recovery, and supply-chain compromise of
the official Claude/Happ download servers (we sha256-verify the Claude binary and
best-effort GPG-verify the manifest, but we trust the upstream artifacts themselves).

---

## 2. Token-only encryption: what it is, why we chose it

The single secret we encrypt is the auth token from `claude setup-token` (a long-lived,
**inference-only** token — not full account credentials). Format and KDF are fixed (see
[`ARCHITECTURE.md`](./ARCHITECTURE.md) §5 and `CONTRACTS.md` §4):

```
on-disk:  salt[16] || iv[16] || AES-256-CBC(PKCS7) ciphertext
KDF:      PBKDF2-HMAC-SHA1, 300000 iterations, 32-byte key
```

Properties and the reasoning:
- **AES-256-CBC** with a per-file random 16-byte salt and 16-byte IV. The token is
  decrypted **to memory only** at launch and exported as `CLAUDE_CODE_OAUTH_TOKEN`; it
  is **never written back to disk**. The password prompt is masked
  (`Read-Host -AsSecureString` / `read -rs`).
- **PBKDF2-HMAC-SHA1, 300k iterations.** SHA1 (not SHA256) is a deliberate compatibility
  choice: the 3-argument .NET `Rfc2898DeriveBytes` constructor defaults to SHA1, and
  OpenSSL 3 / LibreSSL all agree on PBKDF2-HMAC-SHA1. This lets a stick built on any one
  OS be unlocked on any other. PBKDF2-HMAC-SHA1 is still a sound KDF for this use
  (HMAC-SHA1 is not affected by SHA1 collision attacks); the security rests on the
  password strength and the 300k iteration count, **not** on the hash being SHA256.
- **Why only the token?** It is the one secret whose leak directly enables abuse of the
  user's paid account. Encrypting it cheaply (one password, no whole-disk tooling)
  matches the "plug into any PC, no install" goal. Encrypting *everything* on the stick
  is a different tool (whole-volume crypto) — see §4.

### Residual risks of token-only AES
- **Offline password guessing.** A lost stick gives an attacker `oauth.enc` and unlimited
  offline guesses against PBKDF2-300k. Use a **strong, unique stick password**; 300k
  iterations slows but does not stop a determined GPU attacker on a weak password.
- **No integrity tag.** CBC has no AEAD/MAC. A wrong password yields a PKCS7 unpad
  failure (caught, exit 1), but the format does not authenticate ciphertext against
  tampering. The threat (someone editing the ciphertext on a found stick to do something
  useful) is marginal for a single encrypted token, so this is accepted.
- **Token lifetime.** `setup-token` is long-lived. If the password and stick are both
  compromised, **revoke the token** at the Anthropic account level — changing the stick
  password alone does not invalidate an already-extracted token.

---

## 3. What is plaintext on the stick (know this before carrying client data)

Token-only encryption means **the rest of the stick is readable by anyone who plugs it
in**. Specifically:

- **Transcripts and Claude state — plaintext** under `config/` (`CLAUDE_CONFIG_DIR`):
  `settings.json`, `.claude.json`, and any conversation history / session state Claude
  writes there. Whatever you discussed with Claude is on the stick in the clear.
- **Your work — plaintext** under `projects/` (the working directory Claude `cd`s into).
  Source code, documents, client files — all unencrypted.
- **Temp files — plaintext** under `tmp/` (`TMP`/`TEMP`). May contain fragments of work.
- **The Happ VPN subscription — within Happ's own store.** The sub is imported into
  Happ's `subs.db`, which Happ AES-encrypts with its **own** key, not your stick
  password. Treat it as recoverable by anyone with the stick and effort — it is not
  protected by *your* secret. The `apps/happ/data` config also lives on the stick.
- **The launchers, geoguard.conf, README** — plaintext by design (they carry no
  secrets).

Only `config/oauth.enc` is protected by your password. Plan accordingly.

---

## 4. Lost / stolen stick — token-only AES vs. whole-volume encryption

This is the central trade-off. The two layers protect different things:

| Layer                         | Protects                              | Leaves exposed                                    | Cost                                  |
|-------------------------------|---------------------------------------|---------------------------------------------------|---------------------------------------|
| **Token-only AES (built-in)** | The Claude auth token                 | Transcripts, projects, tmp, Happ sub (see §3)     | Free, one password, no install        |
| **Whole-volume encryption**   | **Everything** on the volume          | Nothing (while locked)                            | Per-OS tooling; may break portability |

**Built-in token-only AES** is enough when the stick carries only your own
non-sensitive work and you accept that a finder could read your transcripts and project
files but could **not** use your Claude account.

**For client PII or any regulated/sensitive data, that is not enough.** A lost stick
then leaks client data in the clear. Put a whole-volume encryption layer **underneath**
the exFAT volume:

- **Windows → BitLocker To Go.** Native, transparent; the stick prompts for a password
  on any Windows PC. Note: macOS/Linux read it only with extra tooling, so this trades
  some cross-platform portability.
- **Cross-platform → VeraCrypt.** A VeraCrypt container or fully-encrypted volume reads
  on Windows/macOS/Linux with the VeraCrypt app installed — best when the stick must move
  between OSes. (Requires running the VeraCrypt app on the host, which is a small install
  / portable-app footprint — weigh against the "no trace" goal.)
- **Linux → LUKS.** Strong and native on Linux, but Windows/macOS support is poor; pick
  this only for Linux-only sticks.

> **152-ФЗ / PII note.** Under Russian Federal Law No. 152-FZ "On Personal Data" (and
> similar regimes such as GDPR), personal data of clients/third parties must be protected
> in storage and transport. Carrying such data on a stick whose contents are **plaintext
> except the token** does **not** meet that bar. If the stick may ever hold personal
> data, **use whole-volume encryption (BitLocker To Go / VeraCrypt / LUKS)** and treat
> the stick as a controlled medium (inventory it, define what may be copied onto it, and
> have a lost-device procedure). The built-in token AES is **not** a compliance control
> for third-party PII.

---

## 5. Anti-ban geo-guard — rationale and limits

### Why it exists
Connecting to Claude from a sanctioned/blocked exit country can get the **account**
flagged or banned — a far more expensive loss than the stick itself. The geo-guard's job
is to make a blocked-region launch **fail loudly** rather than silently risk the account.
The default blocklist is `RU, BY, CU, IR, KP, SY`.

### How it behaves (summary; full flow in [`ARCHITECTURE.md`](./ARCHITECTURE.md) §6)
1. If `GUARD_ENABLED=0`, it returns OK immediately (for users genuinely in unrestricted
   regions who do not want the check).
2. It detects the **direct** exit country (no proxy) via `cloudflare.com/cdn-cgi/trace`,
   with `ipinfo.io` / `api.country.is` fallbacks.
3. If the country is **not** blocked, it returns OK and **does not touch the VPN** — the
   user's whole point is to avoid forcing traffic through a tunnel when they don't need
   one.
4. If blocked, it brings up the bundled Happ and **re-checks through the proxy**. Still
   blocked, or no VPN → **refuse to launch**.
5. Undetermined (no network) → act per `INCONCLUSIVE` (`prompt` | `block` | `allow`),
   default `prompt`.

### Limits — what the geo-guard is **not**
- **It is an account-safety heuristic, not anonymity or privacy.** It only checks the
  *exit IP's* country via third-party geo-IP services, which can be wrong, stale, or
  unreachable. It does not hide who you are, does not defeat traffic analysis, and does
  not guarantee Anthropic's own geo-classification matches.
- **It can be misled.** Geo-IP databases lag reality; a VPN exit may be mis-located. The
  `INCONCLUSIVE=prompt` default exists precisely because the check is best-effort.
- **It governs launch, not session.** It checks at startup; it does not re-verify if the
  network changes mid-session.
- **It is not a sanctions-compliance mechanism.** Do not treat "geo-guard passed" as
  legal clearance to use the service from any given location; that remains the user's
  responsibility under Anthropic's terms and applicable law.

---

## 6. "No trace on the host" — claims and their limits

A real goal of the stick is to leave the **host PC** as clean as possible:
- Claude's config, history, and temp are redirected onto the stick
  (`CLAUDE_CONFIG_DIR`, `HOME`/`USERPROFILE`-governed config, `TMP`/`TEMP` → `<STICK>/tmp`).
- Happ runs in **proxy mode, never TUN** (TUN needs admin and installs a network
  device); its config is redirected onto the stick (`APPDATA` / `XDG_CONFIG_HOME`).
- The auto-updater is disabled (`DISABLE_AUTOUPDATER=1`, `DISABLE_UPDATES=1`) so the
  binary doesn't mutate or phone home for updates.
- The builder leaves no daemon on the host; it runs once and exits.

**But "no trace" is best-effort, not a forensic guarantee.** Things outside our control
still record activity on the host:
- **OS artifacts:** Windows shellbags / MRU / jump lists / Prefetch, USB device
  enumeration in the registry (`USBSTOR`), Event Logs; on Linux/mac, mount logs, shell
  history, and `~/.xsession-errors`-type files.
- **Memory & swap:** while Claude runs, the **decrypted token and your password** exist
  in process memory; they can be paged to the host's swap/hibernation file. A malicious
  or instrumented host can capture them.
- **Network:** the host (or its network) sees that *a* connection happened; DNS and
  proxy bring-up touch the host's stack even though config lives on the stick.
- **Antivirus / EDR / DLP:** corporate endpoint agents may scan, log, hash, or quarantine
  the binaries you run from the stick, and may upload telemetry.

Treat the host as **untrusted**. The stick minimizes *its own* footprint; it cannot
sanitize a PC you don't control. If host secrecy matters, assume the host already logged
the basics.

---

## 7. Supply chain & what is (not) in this repo

- The repo is **public, MIT, logic-only**. The Claude binary, Happ, the auth token, and
  the subscription link are **never committed**; they are downloaded/entered at build
  time and land only on the stick.
- `.gitignore` blocks: `*.exe`, `claude`, `bin/`, `apps/`, `*.enc`, `oauth*`, `*.token`,
  any `*.json` that could hold creds, `dist/`, built sticks, and Happ payloads.
- **Download integrity:** the Claude binary is **sha256-verified** against the official
  manifest `checksum`; the manifest signature is **best-effort GPG-verified** when `gpg`
  is present. Both downloads trust the official hosts
  (`downloads.claude.ai`, `github.com/Happ-proxy`) — a compromise of those upstream is
  out of scope.
- **No third-party token/sub minting.** The token is the user's own
  (`claude setup-token`); the VPN subscription is whatever the user pastes (raw URL →
  `happ://add/<urlenc>`, or a ready `happ://crypt5/…` verbatim). We never route the sub
  through a third-party service such as `crypto.happ.su`.

---

## 8. Operator checklist (carry this on the stick mentally)

- Use a **strong, unique** stick password; it is the only thing standing between a lost
  stick and your Claude account.
- If the stick is lost **and** you fear the password is weak/known: **revoke the
  `setup-token`** at the account level — don't rely on the password alone.
- **Do not** put client PII or regulated data on a token-only stick. Add **BitLocker To
  Go / VeraCrypt / LUKS** first (§4) — this is the 152-ФЗ/GDPR-relevant control.
- Keep `GUARD_ENABLED=1` unless you are certain you are in an unrestricted region; leave
  `INCONCLUSIVE=prompt` so a failed geo-check asks rather than silently allows.
- Treat every host PC as untrusted: assume it can log USB use and, if malicious, capture
  the password/token from memory while Claude runs.
