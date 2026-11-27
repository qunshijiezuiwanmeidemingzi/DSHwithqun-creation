@echo off
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0mp3fix.ps1" -Mode check %*
echo.
pause
