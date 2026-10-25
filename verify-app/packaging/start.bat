@echo off
rem Recon Verify - starts the app on this PC and opens it in the browser. No installation needed.
cd /d "%~dp0"
title Recon Verify

if not exist ".env" (
  echo .env is missing in %~dp0
  echo Copy .env.example to .env and fill in the values.
  pause
  exit /b 1
)

rem Only reachable from this PC (127.0.0.1). Change PORT if 3000 is already used.
set HOSTNAME=127.0.0.1
if "%PORT%"=="" set PORT=3000
set NODE_ENV=production

echo Starting Recon Verify on http://localhost:%PORT% ...
echo Keep this window open while you use the app. Close it to stop the app.
start "" /b cmd /c "timeout /t 3 /nobreak >nul & start http://localhost:%PORT%"
"%~dp0node.exe" --env-file=.env server.js
echo.
echo The app stopped.
pause
