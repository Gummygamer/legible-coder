@echo off
rem One-click bootstrap: runs install.ps1 with the execution policy bypass for this process.
rem Everything after the script name is forwarded, e.g. install.cmd -Runtime build

setlocal
set "HERE=%~dp0"

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" (
  echo Windows PowerShell was not found at %PS% 1>&2
  exit /b 1
)

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%HERE%install.ps1" %*
set "RC=%ERRORLEVEL%"
endlocal & exit /b %RC%
