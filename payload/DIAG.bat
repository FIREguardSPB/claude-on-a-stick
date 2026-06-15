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

echo --- Files ----------------------------------
call :checkfile "bin\claude.exe"
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
if not exist "%STICK%\bin\claude.exe" goto claude_missing
echo   Path: %STICK%\bin\claude.exe
"%STICK%\bin\claude.exe" --version 2>nul
goto claude_done
:claude_missing
echo   [MISSING] bin\claude.exe not found -- re-run the builder.
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
if exist "%STICK%\apps\happ" goto happ_present
echo   [none] no apps\happ -- relying on host/system VPN; geoguard still runs.
goto happ_done
:happ_present
echo   [OK] apps\happ present.
if exist "%STICK%\apps\happ\run-happ.bat" echo        run-happ.bat present.
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
