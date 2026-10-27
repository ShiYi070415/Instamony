@echo off
rem ============================================================================
rem  Start cloudflared quick tunnel for the local dsh Web UI, then start dsh with
rem  that tunnel domain as a trusted host, then print the phone-ready URL
rem  (https://<random>.trycloudflare.com/?token=<per-process token>).
rem
rem  Usage:  start-dsh-tunnel.bat          (port 3080)
rem          start-dsh-tunnel.bat 3099     (another port)
rem
rem  Real logic lives in tools\dsh-tunnel.ps1 (batch has no quoting-safe way to
rem  parse logs). This file is intentionally ASCII-only so cmd never mojibakes it.
rem ============================================================================
setlocal
chcp 65001 >nul

set "PORT=%~1"
if "%PORT%"=="" set "PORT=3080"
rem Bind only to loopback: cloudflared runs on this machine, so nothing else needs
rem to reach the port. Set to 0.0.0.0 if you also want direct LAN access.
set "BIND_HOST=127.0.0.1"

pushd "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\dsh-tunnel.ps1" -Port %PORT% -BindHost %BIND_HOST%
set "RC=%ERRORLEVEL%"
popd

if not "%RC%"=="0" (
  echo.
  echo [start-dsh-tunnel] exited with code %RC%
  pause
)
endlocal
