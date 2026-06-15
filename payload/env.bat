@echo off
REM ============================================================================
REM  claude-on-a-stick  --  env.bat  (Windows env + token unlock)
REM ----------------------------------------------------------------------------
REM  Called via  `call env.bat`  from START.bat, so the variables we set here
REM  survive into the caller's session. We deliberately do NOT use setlocal:
REM  CLAUDE_CONFIG_DIR, TMP/TEMP, the cleared ANTHROPIC_API_KEY and the
REM  decrypted CLAUDE_CODE_OAUTH_TOKEN must all reach START's `claude` exec.
REM
REM  Env protocol (CONTRACTS.md §3 -- names are EXACT):
REM    CLAUDE_CONFIG_DIR = <STICK>\config
REM    HOME              = <STICK>\config   (harmless on Windows; keeps parity)
REM    TMP / TEMP        = <STICK>\tmp
REM    ANTHROPIC_API_KEY = (cleared, so it cannot override the subscription)
REM    CLAUDE_CODE_OAUTH_TOKEN = <decrypted token>  (memory only, never on disk)
REM    DISABLE_AUTOUPDATER = 1 ,  DISABLE_UPDATES = 1
REM    (proxy vars are set by vpnup.bat earlier in the chain, not here)
REM
REM  Token source (in priority order):
REM    1. config\oauth.enc  -> decrypt.ps1 prompts for the Stick password and
REM       prints the token to stdout (prompt goes to stderr per §4).
REM    2. config\oauth.txt  -> plaintext fallback (builder may write this when
REM       the user opts out of at-rest encryption). Read verbatim, first line.
REM
REM  cmd GOTCHA: no unescaped ( ) inside an echo within an if(...) block. We use
REM  goto labels for every branch below.
REM ============================================================================

REM -- Resolve STICK from this script's own location ---------------------------
set "STICK=%~dp0"
if "%STICK:~-1%"=="\" set "STICK=%STICK:~0,-1%"

REM -- Core config / scratch dirs ----------------------------------------------
set "CLAUDE_CONFIG_DIR=%STICK%\config"
set "HOME=%STICK%\config"
set "TMP=%STICK%\tmp"
set "TEMP=%STICK%\tmp"
if not exist "%STICK%\tmp" mkdir "%STICK%\tmp" >nul 2>&1
if not exist "%STICK%\config" mkdir "%STICK%\config" >nul 2>&1

REM -- Never let a host API key override the subscription token ----------------
set "ANTHROPIC_API_KEY="

REM -- Updater off: the binary is pinned by the builder ------------------------
set "DISABLE_AUTOUPDATER=1"
set "DISABLE_UPDATES=1"

REM -- Make sure no stale token lingers in this session ------------------------
set "CLAUDE_CODE_OAUTH_TOKEN="

REM ---------------------------------------------------------------------------
REM  Token unlock. Prefer the encrypted blob; fall back to plaintext oauth.txt.
REM ---------------------------------------------------------------------------
if exist "%STICK%\config\oauth.enc" goto unlock_enc
if exist "%STICK%\config\oauth.txt" goto unlock_plain
goto no_token

REM ---------------------------------------------------------------------------
:unlock_enc
echo.
echo Unlocking auth token ...
REM  decrypt.ps1 writes the prompt to stderr and the bare token to stdout, so a
REM  plain for /f capture of stdout yields exactly the token. ExecutionPolicy is
REM  forced to Bypass so the stick works on locked-down hosts without install.
set "TOKEN_TMP="
for /f "usebackq delims=" %%T in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%STICK%\decrypt.ps1" "%STICK%\config\oauth.enc"`) do set "TOKEN_TMP=%%T"

REM  decrypt.ps1 exits 1 on a bad password / failure.
if errorlevel 1 goto unlock_failed
if not defined TOKEN_TMP goto unlock_failed

set "CLAUDE_CODE_OAUTH_TOKEN=%TOKEN_TMP%"
set "TOKEN_TMP="
echo Token unlocked.
goto ok

REM ---------------------------------------------------------------------------
:unlock_plain
REM  Plaintext fallback: read the first non-empty line of oauth.txt verbatim.
echo.
echo Reading auth token (plaintext fallback) ...
set "TOKEN_TMP="
for /f "usebackq delims=" %%T in ("%STICK%\config\oauth.txt") do (
    if not defined TOKEN_TMP set "TOKEN_TMP=%%T"
)
if not defined TOKEN_TMP goto unlock_failed
set "CLAUDE_CODE_OAUTH_TOKEN=%TOKEN_TMP%"
set "TOKEN_TMP="
echo Token loaded.
goto ok

REM ---------------------------------------------------------------------------
:no_token
echo.
echo [env] No token found: neither config\oauth.enc nor config\oauth.txt exists.
echo       Re-run the builder to provision the stick's auth token.
exit /b 1

REM ---------------------------------------------------------------------------
:unlock_failed
echo.
echo [env] Token unlock failed (wrong password, corrupt blob, or empty file).
set "CLAUDE_CODE_OAUTH_TOKEN="
exit /b 1

REM ---------------------------------------------------------------------------
:ok
REM  Success. Do NOT endlocal/setlocal here -- vars must persist to the caller.
exit /b 0
