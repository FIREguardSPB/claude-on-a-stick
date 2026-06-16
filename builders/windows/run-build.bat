@echo off
REM ============================================================
REM  claude-on-a-stick - Windows build launcher.
REM  - bypasses the PowerShell ExecutionPolicy for build.ps1
REM  - self-elevates to Administrator (needed to format the USB)
REM  - keeps the window OPEN on exit so you can read any message/error
REM ============================================================

REM --- self-elevate if we are not already Administrator ---
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting administrator rights ^(a UAC prompt will appear^)...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

REM --- elevated: run the builder with the execution policy bypassed for this script only ---
pushd "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
set "_rc=%errorlevel%"
popd

echo.
echo ============================================================
echo  Builder finished or stopped (exit code %_rc%).
echo  Read the output above. This window will stay open.
echo ============================================================
pause
