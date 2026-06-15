==============================================================================
  claude-on-a-stick  —  portable Claude Code on this USB drive
==============================================================================

This stick runs the REAL Claude Code CLI (your own subscription) with no
install and no trace left on the host computer. Everything — the binary, your
config, your projects, the temp files, and the optional VPN — lives on the
stick itself.

Model baked into this stick:  __MODEL__
Interface language:           __LANG__

------------------------------------------------------------------------------
HOW TO USE
------------------------------------------------------------------------------

Linux / macOS:
  1. Plug in the stick.
  2. Open a terminal in the stick's root folder.
  3. Run:   ./start.sh
       (first time only, if it won't run:  chmod +x start.sh decrypt.sh
        diag.sh env.sh vpnup.sh geoguard.sh apps/happ/run-happ.sh )
  4. Enter your "Stick password" when prompted. Claude Code starts in the
     projects/ folder.

Windows:
  Double-click START.bat (or run it from a Command Prompt).

To check the stick is healthy WITHOUT launching Claude:
  Linux/macOS:  ./diag.sh        Windows:  DIAG.bat

------------------------------------------------------------------------------
WHAT HAPPENS AT LAUNCH (start.sh / START.bat)
------------------------------------------------------------------------------
  1. vpnup    If a VPN is bundled (apps/happ), Happ is started in PROXY mode
              and the proxy is auto-detected. If not, your host network is used.
  2. geoguard Your exit country is checked. If you are NOT in a blocked region
              (RU, BY, CU, IR, KP, SY by default) the VPN is left untouched. If
              you ARE, the bundled VPN is brought up and the exit re-checked;
              if it still resolves to a blocked region, launch is REFUSED.
  3. unlock   You are asked for the "Stick password". It decrypts the token in
              memory only — the token is NEVER written to disk in the clear.
  4. launch   Claude Code starts in projects/, using model __MODEL__.

------------------------------------------------------------------------------
THE VPN (optional)
------------------------------------------------------------------------------
If this stick was built with a bundled Happ VPN:
  - Open Happ once and turn ON "auto-connect on launch", otherwise you must
    click Connect each time before the proxy becomes available.
  - Happ runs in PROXY mode only (no admin rights needed). TUN mode is never
    used.

------------------------------------------------------------------------------
GEO-GUARD SETTINGS  (geoguard.conf)
------------------------------------------------------------------------------
You can edit geoguard.conf on the stick:
  GUARD_ENABLED=1            set 0 to disable all geo checks (and skip the VPN)
  BLOCKLIST=RU,BY,CU,IR,KP,SY  comma-separated ISO country codes to refuse
  INCONCLUSIVE=prompt        prompt | block | allow  (when country is unknown)

------------------------------------------------------------------------------
SECURITY — PLEASE READ
------------------------------------------------------------------------------
  * Your auth token (oauth.enc) is encrypted with YOUR password (AES-256).
    Without the password it cannot be used. Choose a strong one.
  * Your transcripts, settings and project files on this stick are stored in
    PLAINTEXT, protected only by that token password. If you handle client or
    personal data (PII), put the whole stick inside a full-volume encrypted
    container — BitLocker To Go (Windows), VeraCrypt (cross-platform), or LUKS
    (Linux). Token-only encryption does NOT protect your work files.
  * The Claude and Happ binaries were downloaded from their official sources at
    build time. They are not modified.
  * If you lose the stick, anyone who learns the password can use your Claude
    subscription. Revoke the token from your Anthropic account if that happens.

------------------------------------------------------------------------------
TROUBLESHOOTING
------------------------------------------------------------------------------
  * "wrong password" — re-run and retype the Stick password carefully.
  * VPN won't come up — open Happ manually, connect once, enable auto-connect,
    then re-run start.sh / START.bat.
  * Launch refused on geo — you are in (or your VPN exits in) a blocked region.
    Use a VPN exit outside the blocklist, or adjust geoguard.conf if you
    understand the risk.
  * Run ./diag.sh (DIAG.bat) for a full health report.
==============================================================================
