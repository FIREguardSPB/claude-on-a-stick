@echo off
REM ============================================================================
REM  claude-on-a-stick  --  vpnup.bat  (Windows VPN bring-up, optional)
REM ----------------------------------------------------------------------------
REM  Called via  `call vpnup.bat`  so the proxy env vars it exports survive into
REM  the caller (START.bat / geoguard.bat). NO setlocal here for that reason.
REM
REM  Behaviour (CONTRACTS.md §6):
REM    * If apps\happ does NOT exist -> return OK immediately (rely on host /
REM      system VPN; geoguard still governs the launch).
REM    * Otherwise launch Happ (proxy mode) via run-happ.bat which redirects
REM      APPDATA onto the stick, then AUTO-DETECT the HTTP proxy port by making
REM      a real HTTP request through each candidate port. Poll up to ~25s
REM      because Happ may take a moment to connect.
REM    * On success, export (names EXACT, §3):
REM         HTTPS_PROXY = http://127.0.0.1:<port>
REM         HTTP_PROXY  = http://127.0.0.1:<port>
REM         NO_PROXY    = localhost,127.0.0.1,::1
REM         HAPP_PROXY_PORT = <port>   (internal signal for the rest of the chain)
REM      We do NOT set ALL_PROXY: a SOCKS port is not reliably known and PS 5.1
REM      cannot use SOCKS for the geoguard recheck anyway.
REM
REM  Port probe list (CONTRACTS.md §6): 10808,10809,2080,1080,10800,8080
REM  The actual HTTP request + 200 check is done in PowerShell (cmd has no HTTP
REM  client). PS prints the winning port to stdout, or nothing on failure.
REM
REM  cmd GOTCHA: no unescaped ( ) inside echo within if(...) -- goto labels.
REM ============================================================================

REM -- Resolve STICK from this script's own location ---------------------------
set "STICK=%~dp0"
if "%STICK:~-1%"=="\" set "STICK=%STICK:~0,-1%"

REM -- No bundled VPN? Nothing to do; geoguard will still check the region. ----
if not exist "%STICK%\apps\happ" goto skip_vpn

echo.
echo [vpn] Bringing up bundled Happ (proxy mode) ...

REM -- Start Happ with config redirected onto the stick ------------------------
REM    run-happ.bat returns 1 if Happ.exe is missing; treat that as "no VPN".
call "%STICK%\apps\happ\run-happ.bat"
if errorlevel 1 goto skip_vpn

REM ---------------------------------------------------------------------------
REM  Auto-detect the proxy port. We hand the probe to PowerShell, which loops
REM  the candidate ports, making a real HTTP GET to cloudflare's trace endpoint
REM  THROUGH each proxy, polling for up to ~25 seconds while Happ connects.
REM  PS writes only the winning port number to stdout (empty on total failure).
REM ---------------------------------------------------------------------------
echo [vpn] Auto-detecting proxy port (this can take up to ~25s) ...

set "HAPP_PROXY_PORT="
for /f "usebackq delims=" %%P in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$ports=@(10808,10809,2080,1080,10800,8080); $deadline=(Get-Date).AddSeconds(25); $found=$null; while((Get-Date) -lt $deadline -and -not $found){ foreach($p in $ports){ try{ $r=Invoke-WebRequest -Uri 'http://cloudflare.com/cdn-cgi/trace' -Proxy ('http://127.0.0.1:'+$p) -TimeoutSec 4 -UseBasicParsing -ErrorAction Stop; if($r.StatusCode -eq 200){ $found=$p; break } }catch{} } if(-not $found){ Start-Sleep -Seconds 2 } } if($found){ Write-Output $found }"`) do set "HAPP_PROXY_PORT=%%P"

if not defined HAPP_PROXY_PORT goto no_proxy

REM -- Export the proxy env (HTTP proxy only; see header note on ALL_PROXY) -----
set "HTTPS_PROXY=http://127.0.0.1:%HAPP_PROXY_PORT%"
set "HTTP_PROXY=http://127.0.0.1:%HAPP_PROXY_PORT%"
set "NO_PROXY=localhost,127.0.0.1,::1"
echo [vpn] Proxy is up on 127.0.0.1:%HAPP_PROXY_PORT%  (HTTPS_PROXY exported).
goto ok

REM ---------------------------------------------------------------------------
:no_proxy
echo [vpn] Could not detect a working Happ proxy on any candidate port.
echo       Open Happ, connect once, and enable "auto-connect on launch",
echo       then re-run START. Continuing without a proxy for now.
REM  Not fatal here -- geoguard decides whether to refuse the launch.
goto ok

REM ---------------------------------------------------------------------------
:skip_vpn
REM  No bundled Happ (or no exe). Make sure no stale proxy vars are left set.
set "HTTPS_PROXY="
set "HTTP_PROXY="
set "HAPP_PROXY_PORT="
goto ok

REM ---------------------------------------------------------------------------
:ok
REM  Never abort the chain from here; geoguard is the gate. No (set)local used.
exit /b 0
