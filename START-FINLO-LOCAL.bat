@echo off
setlocal
cd /d "%~dp0public"

where py >nul 2>nul
if %errorlevel%==0 (
  start "Finlo local server" /min py -m http.server 8765
) else (
  where python >nul 2>nul
  if %errorlevel%==0 (
    start "Finlo local server" /min python -m http.server 8765
  ) else (
    echo Python is required to run Finlo locally.
    echo Install Python from https://www.python.org/downloads/windows/
    pause
    exit /b 1
  )
)

timeout /t 2 /nobreak >nul
start "Finlo" http://localhost:8765/index.html
echo Finlo is running at http://localhost:8765/index.html
echo Close the server window to stop Finlo.
endlocal
