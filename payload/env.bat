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
REM  Binary resolution (multi-OS stick): the per-platform binary lives at
REM    bin\win32-<arch>\claude.exe   (arch = x64 | arm64)
REM  We map PROCESSOR_ARCHITECTURE (AMD64->x64, ARM64->arm64; WOW64 honoured) to
REM  the native subdir, fall back to ANY present win32-* subdir, then to the
REM  legacy flat bin\claude.exe (single-target builds), and error if none. The
REM  resolved path is exported as CLAUDE_BIN; START.bat exec's "%CLAUDE_BIN%".
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
REM  Resolve CLAUDE_BIN = the right per-OS/arch claude.exe for THIS host.
REM  Layout: bin\win32-<arch>\claude.exe  (arch x64|arm64). Order:
REM    1. native arch subdir (from PROCESSOR_ARCHITECTURE / WOW64)
REM    2. the OTHER win32 arch subdir present (x64 binaries run under WOW64 on
REM       ARM64; arm64 won't run on x64 but we still surface it so DIAG matches)
REM    3. legacy flat bin\claude.exe  (single-target builds before subdirs)
REM  Sets CLAUDE_BIN and jumps to :bin_ok, or :no_binary if nothing is present.
REM ---------------------------------------------------------------------------
set "CLAUDE_BIN="
set "WINARCH=x64"
if /I "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "WINARCH=arm64"
if /I "%PROCESSOR_ARCHITEW6432%"=="ARM64" set "WINARCH=arm64"

if exist "%STICK%\bin\win32-%WINARCH%\claude.exe" goto bin_native
REM  Native subdir absent: try the other arch, then any win32-* dir, then flat.
if exist "%STICK%\bin\win32-x64\claude.exe" set "CLAUDE_BIN=%STICK%\bin\win32-x64\claude.exe"
if not defined CLAUDE_BIN if exist "%STICK%\bin\win32-arm64\claude.exe" set "CLAUDE_BIN=%STICK%\bin\win32-arm64\claude.exe"
if not defined CLAUDE_BIN if exist "%STICK%\bin\claude.exe" set "CLAUDE_BIN=%STICK%\bin\claude.exe"
if defined CLAUDE_BIN goto bin_ok
goto no_binary

:bin_native
set "CLAUDE_BIN=%STICK%\bin\win32-%WINARCH%\claude.exe"
goto bin_ok

:no_binary
echo.
echo [env] No claude.exe found under bin\win32-x64, bin\win32-arm64, or bin\
echo       (host arch: %WINARCH%). Re-run the builder for a win32-%WINARCH% target.
exit /b 1

:bin_ok
REM  CLAUDE_BIN now points at a real file; START.bat exec's it.

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
