@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Configurar.ps1" %*
pause
