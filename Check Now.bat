@echo off
REM Refresh the SSL certificate data, then leave the window open so you can
REM read the results. %~dp0 is this file's own folder, so the bundle stays
REM portable no matter where it's copied. The scripts live in resources\ -
REM this file is one of the few things at the root you are meant to run.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0resources\check-ssl.ps1"
echo.
pause
