@echo off
REM One-time setup: creates domains.txt, runs the first check, and offers to
REM register the daily scheduled task. Safe to run again later.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0resources\setup.ps1"
echo.
pause
