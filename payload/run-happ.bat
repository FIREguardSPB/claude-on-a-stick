@echo off
REM ============================================================================
REM  claude-on-a-stick  --  run-happ.bat  (Windows Happ wrapper)
REM ----------------------------------------------------------------------------
REM  Lives at  apps\happ\run-happ.bat  on the stick (CONTRACTS.md §2/§6).
REM  Single job: launch the bundled, portable-ized Happ client with its config
REM  redirected ONTO the stick so nothing is written to the host profile.
REM
REM  Redirect (CONTRACTS.md §6): on Windows we point APPDATA (and LOCALAPPDATA
REM  for good measure) at  apps\happ\data  so Happ.conf / subs.db land there.
REM  Proxy mode only -- never TUN (TUN needs admin everywhere).
REM
REM  Usage:
REM    run-happ.bat                 -> just start the client (used by vpnup)
REM    run-happ.bat "happ://add/.." -> forward a deep link to the running
REM                                    instance (SingleApplication IPC import).
REM
REM  Because this is launched with `start` and APPDATA is set inside our own
REM  setlocal scope, the redirect applies to the Happ process we spawn without
REM  polluting the rest of the chain.
REM
REM  cmd GOTCHA: no unescaped ( ) inside echo within if(...) -- goto labels used.
REM ============================================================================

setlocal

REM -- HAPPDIR = the folder this wrapper lives in (apps\happ) ------------------
set "HAPPDIR=%~dp0"
if "%HAPPDIR:~-1%"=="\" set "HAPPDIR=%HAPPDIR:~0,-1%"

REM -- Redirect Happ's config onto the stick -----------------------------------
set "APPDATA=%HAPPDIR%\data"
set "LOCALAPPDATA=%HAPPDIR%\data"
if not exist "%HAPPDIR%\data" mkdir "%HAPPDIR%\data" >nul 2>&1

REM -- Locate the Happ executable. The builder unpacks it under apps\happ. -----
REM    Most builds drop Happ.exe at the root of the install dir; some nest it.
set "HAPP_EXE="
if exist "%HAPPDIR%\Happ.exe" set "HAPP_EXE=%HAPPDIR%\Happ.exe"
if not defined HAPP_EXE if exist "%HAPPDIR%\happ.exe" set "HAPP_EXE=%HAPPDIR%\happ.exe"
if not defined HAPP_EXE goto find_nested
goto have_exe

:find_nested
REM  Fall back to a recursive search for the first Happ.exe under apps\happ.
for /f "delims=" %%F in ('dir /b /s "%HAPPDIR%\Happ.exe" 2^>nul') do (
    if not defined HAPP_EXE set "HAPP_EXE=%%F"
)
if not defined HAPP_EXE goto no_exe

:have_exe
REM ---------------------------------------------------------------------------
REM  Branch: deep-link forward vs plain start.
REM  %~1 is the optional happ:// URL. We pass it as a single quoted arg so the
REM  running SingleApplication instance imports it (subs.db AES-persist). If no
REM  arg, we just start the client. asInvoker -- no elevation.
REM ---------------------------------------------------------------------------
if "%~1"=="" goto start_plain
goto start_link

:start_plain
start "" "%HAPP_EXE%"
goto ok

:start_link
REM  Forward the deep link. `start "" "Happ.exe" "happ://..."` keeps the URL as
REM  one argument; Happ's QLocalServer IPC hands it to the live instance.
start "" "%HAPP_EXE%" "%~1"
goto ok

REM ---------------------------------------------------------------------------
:no_exe
echo [run-happ] Happ.exe not found under "%HAPPDIR%". Skipping VPN bring-up.
endlocal
exit /b 1

:ok
endlocal
exit /b 0
