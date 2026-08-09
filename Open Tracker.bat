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

rem Exit code 10 means it attached to the server the boot task is already
rem running and put the page in front of you. This window hosted nothing, so
rem there is nothing to read and nothing to keep it open for - close and get
rem out of the way. Every other exit falls through to the message below,
rem including the ordinary one where this window WAS the server and has just
rem stopped, which is exactly when somebody wants to see why.
if "%ERRORLEVEL%"=="10" exit

echo.
echo   This window no longer hosts Cert Camel.
echo   If it is installed to start at boot, it is still running in the background.
echo.
pause
