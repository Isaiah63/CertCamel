@echo off
REM Refresh the SSL certificate data, then leave the window open so you can
REM read the results. %~dp0 is this file's own folder, so the bundle stays
REM portable no matter where it's copied.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0check-ssl.ps1"
echo.
pause
