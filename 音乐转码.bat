@echo off
chcp 65001 >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0mp3fix.ps1" -Mode menu %*
echo.
pause
