@echo off
REM ============================================================================
REM  claude-on-a-stick  --  START.bat  (Windows top-level launcher)
REM ----------------------------------------------------------------------------
REM  Launcher chain (CONTRACTS.md §3), in order:
REM    1. vpnup    -> VPN bring-up. To honour the "smart skip" guarantee (§5 --
REM                   the user's whole point), the bundled VPN is NOT started
REM                   unconditionally here; geoguard owns on-demand bring-up and
REM                   calls vpnup.bat only AFTER confirming a blocked region.
REM                   (§3 marks this step "Skippable; see geoguard step 0".)
REM    2. geoguard -> direct region check; if blocked, brings the VPN up via
REM                   vpnup.bat and rechecks through the proxy. Aborts launch if
REM                   the exit country stays blocked / no working VPN.
REM    3. env      -> set CLAUDE_CONFIG_DIR/HOME/TMP, clear ANTHROPIC_API_KEY,
REM                   decrypt the token into CLAUDE_CODE_OAUTH_TOKEN (memory).
REM    4. cd projects\  and exec claude --model __MODEL__ %*
REM
REM  cmd GOTCHA (CONTRACTS.md §3): never put unescaped ( ) inside an echo that
REM  lives within an  if ( ... )  block -- it closes the block early. We use
REM  goto labels everywhere instead of parenthesised blocks.
REM
REM  Language baked at build time: __LANG__   Model baked at build time: __MODEL__
REM ============================================================================

setlocal
REM -- Keep our own console codepage UTF-8 so RU strings render -----------------
chcp 65001 >nul 2>&1

REM -- STICK = the drive/folder this .bat lives on (no trailing backslash) ------
set "STICK=%~dp0"
if "%STICK:~-1%"=="\" set "STICK=%STICK:~0,-1%"

title Claude on a Stick

echo.
echo ============================================
echo   Claude on a Stick
echo ============================================
echo.

REM ---------------------------------------------------------------------------
REM  STEP 1+2: Geo-guard (which owns on-demand VPN bring-up).
REM  geoguard.bat runs a DIRECT region check first and does NOT touch the VPN
REM  when the region is fine (smart skip). If the region is blocked it calls
REM  vpnup.bat (Happ proxy + auto-detected port -> HTTPS_PROXY) and rechecks
REM  through the proxy. Returns errorlevel 0 = OK to launch, non-zero = refuse.
REM  Any HTTPS_PROXY/HTTP_PROXY it exported survives into this session because
REM  vpnup.bat is `call`-ed without setlocal, so claude inherits the proxy.
REM ---------------------------------------------------------------------------
call "%STICK%\geoguard.bat"
if errorlevel 1 goto guard_blocked

REM ---------------------------------------------------------------------------
REM  STEP 3: Environment + token unlock. env.bat sets every CLAUDE_* / proxy /
REM  TMP var and decrypts the token into CLAUDE_CODE_OAUTH_TOKEN. It exits with
REM  errorlevel 1 if the token could not be unlocked.
REM ---------------------------------------------------------------------------
call "%STICK%\env.bat"
if errorlevel 1 goto env_failed

REM ---------------------------------------------------------------------------
REM  STEP 4: cd to projects\ and exec claude. %* forwards any extra args the
REM  user dropped onto START.bat through to claude unchanged.
REM ---------------------------------------------------------------------------
if not exist "%STICK%\projects" mkdir "%STICK%\projects" >nul 2>&1
cd /d "%STICK%\projects"

echo.
echo Launching Claude Code (model: __MODEL__) ...
echo.

REM  bin\claude.exe is the self-contained binary placed by the builder.
"%STICK%\bin\claude.exe" --model __MODEL__ %*
set "RC=%ERRORLEVEL%"

goto cleanup

REM ===========================================================================
REM  Failure / exit labels (kept OUT of any if(...) block on purpose)
REM ===========================================================================

:guard_blocked
echo.
echo [geoguard] Launch refused: exit region is blocked or no working VPN.
echo            See DIAG.bat for details, or disable the guard in geoguard.conf.
echo.
set "RC=2"
goto cleanup

:env_failed
echo.
echo [env] Could not unlock the auth token (wrong password or missing file).
echo       Run DIAG.bat to inspect config\oauth.enc / config\oauth.txt.
echo.
set "RC=3"
goto cleanup

:cleanup
REM  Scrub the secret from this process env even though setlocal will drop it.
set "CLAUDE_CODE_OAUTH_TOKEN="
echo.
echo Claude exited with code %RC%.
echo Press any key to close this window.
pause >nul
endlocal
exit /b %RC%
