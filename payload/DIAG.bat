@echo off
REM ============================================================================
REM  claude-on-a-stick  --  DIAG.bat  (Windows diagnostics, read-only)
REM ----------------------------------------------------------------------------
REM  Prints the health of the stick so the user can troubleshoot a refused or
REM  failed launch. Touches nothing; never decrypts the token (only reports
REM  whether the blob/plaintext exists). Safe to run on any host.
REM
REM  Reports:
REM    * resolved STICK path + presence of every expected file/dir
REM    * claude binary + version
REM    * token source (oauth.enc vs oauth.txt vs none)
REM    * geoguard.conf contents
REM    * bundled Happ presence
REM    * current direct exit country (via cloudflare trace)
REM    * if a proxy is set, the proxied exit country too
REM
REM  cmd GOTCHA: no unescaped ( ) inside echo within if(...) -- goto labels.
REM ============================================================================

setlocal
chcp 65001 >nul 2>&1

set "STICK=%~dp0"
if "%STICK:~-1%"=="\" set "STICK=%STICK:~0,-1%"

echo ============================================
echo   Claude on a Stick -- DIAGNOSTICS
echo ============================================
echo.
echo STICK path : %STICK%
echo Model      : __MODEL__
echo Language   : __LANG__
echo.

REM -- Resolve CLAUDE_BIN exactly as env.bat does (per-OS/arch, with fallbacks)
REM    so this report shows the same binary START.bat would actually exec.
set "CLAUDE_BIN="
set "WINARCH=x64"
if /I "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "WINARCH=arm64"
if /I "%PROCESSOR_ARCHITEW6432%"=="ARM64" set "WINARCH=arm64"
if exist "%STICK%\bin\win32-%WINARCH%\claude.exe" set "CLAUDE_BIN=%STICK%\bin\win32-%WINARCH%\claude.exe"
if not defined CLAUDE_BIN if exist "%STICK%\bin\win32-x64\claude.exe" set "CLAUDE_BIN=%STICK%\bin\win32-x64\claude.exe"
if not defined CLAUDE_BIN if exist "%STICK%\bin\win32-arm64\claude.exe" set "CLAUDE_BIN=%STICK%\bin\win32-arm64\claude.exe"
if not defined CLAUDE_BIN if exist "%STICK%\bin\claude.exe" set "CLAUDE_BIN=%STICK%\bin\claude.exe"

echo --- Files ----------------------------------
if defined CLAUDE_BIN goto df_binok
echo   [MISSING] no claude.exe under bin\win32-x64, bin\win32-arm64, or bin\
goto df_bindone
:df_binok
call :reportbin
:df_bindone
call :checkfile "config\settings.json"
call :checkfile "config\.claude.json"
call :checkdir  "config"
call :checkdir  "projects"
call :checkdir  "tmp"
call :checkfile "env.bat"
call :checkfile "vpnup.bat"
call :checkfile "geoguard.bat"
call :checkfile "geoguard.ps1"
call :checkfile "geoguard.conf"
call :checkfile "decrypt.ps1"
echo.

echo --- Auth token source ----------------------
if exist "%STICK%\config\oauth.enc" goto tok_enc
if exist "%STICK%\config\oauth.txt" goto tok_plain
echo   [MISSING] no oauth.enc and no oauth.txt -- re-run the builder.
goto tok_done
:tok_enc
echo   [OK] config\oauth.enc present (encrypted; password required at launch).
goto tok_done
:tok_plain
echo   [WARN] config\oauth.txt present (PLAINTEXT token, no encryption).
:tok_done
echo.

echo --- Claude binary --------------------------
echo   Host arch  : %WINARCH%  (looked for bin\win32-%WINARCH%\claude.exe first)
if not defined CLAUDE_BIN goto claude_missing
echo   Resolved   : %CLAUDE_BIN%
"%CLAUDE_BIN%" --version 2>nul
goto claude_done
:claude_missing
echo   [MISSING] no claude.exe under bin\win32-x64, bin\win32-arm64, or bin\ -- re-run the builder.
:claude_done
echo.

echo --- geoguard.conf --------------------------
if not exist "%STICK%\geoguard.conf" goto gg_missing
type "%STICK%\geoguard.conf"
goto gg_done
:gg_missing
echo   [MISSING] geoguard.conf not found (guard will use built-in defaults).
:gg_done
echo.

echo --- Bundled VPN (Happ) ---------------------
REM  Resolve the Happ dir as vpnup.bat does: prefer apps\happ-win32 (multi-OS
REM  layout) then fall back to flat apps\happ (single-target build).
set "HAPP_DIR="
if exist "%STICK%\apps\happ-win32" set "HAPP_DIR=%STICK%\apps\happ-win32"
if not defined HAPP_DIR if exist "%STICK%\apps\happ" set "HAPP_DIR=%STICK%\apps\happ"
if defined HAPP_DIR goto happ_present
echo   [none] no apps\happ -- relying on host/system VPN; geoguard still runs.
goto happ_done
:happ_present
echo   [OK] %HAPP_DIR% present.
if exist "%HAPP_DIR%\run-happ.bat" echo        run-happ.bat present.
:happ_done
echo.

echo --- Region check (direct) ------------------
REM  Pipe-free PS (avoids cmd ^| escaping headaches): regex-extract loc= and ip=.
powershell -NoProfile -ExecutionPolicy Bypass -Command "try{ $r=Invoke-WebRequest 'https://www.cloudflare.com/cdn-cgi/trace' -TimeoutSec 8 -UseBasicParsing; $loc=[regex]::Match($r.Content,'(?m)^loc=([A-Z]{2})$').Groups[1].Value; $ip=[regex]::Match($r.Content,'(?m)^ip=(.+)$').Groups[1].Value; Write-Host ('   loc=' + $loc + '  ip=' + $ip) } catch { Write-Host '   (no internet or blocked)'}"
echo.

echo --- Region check (through proxy, if any) ---
if not defined HTTPS_PROXY goto proxy_none
echo   HTTPS_PROXY = %HTTPS_PROXY%
powershell -NoProfile -ExecutionPolicy Bypass -Command "try{ $r=Invoke-WebRequest 'https://www.cloudflare.com/cdn-cgi/trace' -Proxy $env:HTTPS_PROXY -TimeoutSec 8 -UseBasicParsing; $loc=[regex]::Match($r.Content,'(?m)^loc=([A-Z]{2})$').Groups[1].Value; Write-Host ('   loc=' + $loc) } catch { Write-Host '   (proxy not reachable)'}"
goto proxy_done
:proxy_none
echo   HTTPS_PROXY not set in this session (run vpnup.bat or START.bat first).
:proxy_done
echo.

echo ============================================
echo   Diagnostics complete.
echo ============================================
echo.
pause >nul
endlocal
exit /b 0

REM ===========================================================================
REM  Subroutines (called with `call :label "relpath"`).
REM ===========================================================================
:reportbin
REM  Report the resolved binary relative to STICK (strip the STICK prefix).
set "RELBIN=%CLAUDE_BIN:*bin\=bin\%"
echo   [OK]      %RELBIN%
goto :eof

:checkfile
if exist "%STICK%\%~1" goto cf_ok
echo   [MISSING] %~1
goto :eof
:cf_ok
echo   [OK]      %~1
goto :eof

:checkdir
if exist "%STICK%\%~1\" goto cd_ok
echo   [MISSING] %~1\  (dir)
goto :eof
:cd_ok
echo   [OK]      %~1\  (dir)
goto :eof
