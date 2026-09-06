@echo off
setlocal

rem The current Legible Windows runtime executes shell tools through sh.
if exist "C:\Program Files\Git\usr\bin\sh.exe" set "PATH=C:\Program Files\Git\usr\bin;%PATH%"

legible run "%~dp0coder.lbl" %*
exit /b %ERRORLEVEL%
