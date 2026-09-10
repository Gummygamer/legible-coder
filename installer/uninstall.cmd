@echo off
rem One-click bootstrap for uninstall.ps1 with the execution policy bypass.
rem Everything after the script name is forwarded, e.g. uninstall.cmd -Force -RemoveEnvVars

setlocal
set "HERE=%~dp0"

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" (
  echo Windows PowerShell was not found at %PS% 1>&2
  exit /b 1
)

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%HERE%uninstall.ps1" %*
set "RC=%ERRORLEVEL%"
endlocal & exit /b %RC%
