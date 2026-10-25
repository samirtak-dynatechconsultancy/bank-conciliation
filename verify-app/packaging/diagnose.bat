@echo off
rem Recon Verify - connection test (token, warehouse, lakehouse). Never prints the secret.
cd /d "%~dp0"
"%~dp0node.exe" scripts\diagnose.mjs
echo.
pause
