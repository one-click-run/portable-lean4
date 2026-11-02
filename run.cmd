@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Enter-PortableLean4.ps1"
exit /b %ERRORLEVEL%

