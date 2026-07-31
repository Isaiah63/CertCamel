@echo off
title SSL Certificate Tracker
echo.
echo   Starting the tracker. Your browser will open in a moment.
echo   Keep this window open - closing it stops the server.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0serve.ps1"
echo.
echo   Server stopped.
pause
