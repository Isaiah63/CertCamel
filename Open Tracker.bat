@echo off
title Cert Camel
echo.
echo   Opening Cert Camel...
echo.
rem serve.ps1 decides what to do: if a server is already running - because the
rem startup task launched one at boot - it opens the browser at that one and
rem exits. Otherwise it starts a server here and this window keeps it alive.
rem Either way the double-click does the right thing.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0serve.ps1"
echo.
echo   This window no longer hosts Cert Camel.
echo   If it is installed to start at boot, it is still running in the background.
echo.
pause
