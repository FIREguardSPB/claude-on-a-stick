@echo off
REM ============================================================================
REM  claude-on-a-stick  --  geoguard.bat  (Windows geo-guard shim, anti-ban)
REM ----------------------------------------------------------------------------
REM  Thin cmd shim around geoguard.ps1 that ALSO owns on-demand VPN bring-up so
REM  the "smart skip" guarantee holds (CONTRACTS.md §5): the bundled VPN is only
REM  ever started AFTER we confirm the DIRECT exit region is blocked.
REM
REM  Called via  `call geoguard.bat`  from START.bat. Returns:
REM     errorlevel 0  -> OK, launch allowed.
REM     errorlevel 1  -> refuse the launch.
REM
REM  Flow:
REM    1. Run geoguard.ps1 (direct check, no proxy touched).
REM         exit 0 -> allowed (region fine, or guard disabled). Done.
REM         exit 1 -> refuse. Done.
REM         exit 2 -> direct region is blocked and no proxy is up yet.
REM    2. On exit 2: call vpnup.bat to bring Happ up (sets HTTPS_PROXY), then
REM       re-run geoguard.ps1 which now rechecks THROUGH the proxy:
REM         exit 0 -> proxy moved us out of the blocked region. Allowed.
REM         else   -> still blocked / undetermined / no proxy. Refuse.
REM
REM  cmd GOTCHA: no unescaped ( ) inside echo within if(...) -- goto labels.
REM ============================================================================

REM -- Resolve STICK from this script's own location ---------------------------
set "STICK=%~dp0"
if "%STICK:~-1%"=="\" set "STICK=%STICK:~0,-1%"

REM ---------------------------------------------------------------------------
REM  First pass: direct check.
REM ---------------------------------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass -File "%STICK%\geoguard.ps1" "%STICK%\geoguard.conf"
set "GG=%ERRORLEVEL%"

if "%GG%"=="0" goto allow
if "%GG%"=="2" goto need_vpn
goto refuse

REM ---------------------------------------------------------------------------
:need_vpn
REM  Direct region blocked, no proxy yet. Bring up the bundled VPN, then recheck.
echo [geoguard] Blocked region detected; attempting VPN bring-up...
call "%STICK%\vpnup.bat"

REM  If vpnup could not produce a proxy (no apps\happ, or no port detected),
REM  HTTPS_PROXY stays empty and the recheck below will refuse -- correct.
powershell -NoProfile -ExecutionPolicy Bypass -File "%STICK%\geoguard.ps1" "%STICK%\geoguard.conf"
set "GG=%ERRORLEVEL%"

if "%GG%"=="0" goto allow
goto refuse

REM ---------------------------------------------------------------------------
:allow
exit /b 0

REM ---------------------------------------------------------------------------
:refuse
exit /b 1
