@echo off
rem Streaming Server launcher: finds or downloads Node.js, starts the
rem server in its own window, then opens the viewer page in the browser.
setlocal
cd /d "%~dp0"

rem Reuse the portable Node.js that download-tools.cmd puts in tools\node,
rem so the two scripts never fetch two separate copies of the runtime.
if exist "tools\node\node.exe" (
  set "NODE=%CD%\tools\node\node.exe"
  goto run
)

set NODE=node
where node >nul 2>nul
if %errorlevel%==0 goto run

set NODE_VER=v22.12.0
set NODE_DIR=node-portable\node-%NODE_VER%-win-x64
set NODE=%NODE_DIR%\node.exe
if exist "%NODE%" goto run

echo Node.js not found - downloading portable %NODE_VER% ...
if not exist node-portable mkdir node-portable
powershell -NoProfile -Command "[Net.ServicePointManager]::SecurityProtocol='Tls12'; Invoke-WebRequest 'https://nodejs.org/dist/%NODE_VER%/node-%NODE_VER%-win-x64.zip' -OutFile 'node-portable\node.zip'"
if errorlevel 1 goto fail
powershell -NoProfile -Command "Expand-Archive -Force 'node-portable\node.zip' 'node-portable'"
if errorlevel 1 goto fail
del node-portable\node.zip
if not exist "%NODE%" goto fail

:run
echo Starting Streaming Server ...
start "Streaming Server" "%NODE%" server.js

rem Wait for the sticky port file, then open the viewer page.
set TRIES=0
:wait
if exist .ports.json goto open
set /a TRIES+=1
if %TRIES% gtr 30 goto nofile
timeout /t 1 /nobreak >nul
goto wait

:open
set PORT=
for /f %%p in ('powershell -NoProfile -Command "(Get-Content .ports.json | ConvertFrom-Json).viewer"') do set PORT=%%p
if "%PORT%"=="" goto nofile
echo Viewer page: http://localhost:%PORT%/
start http://localhost:%PORT%/
goto end

:nofile
echo Server started but no port file appeared - check the server window.
goto end

:fail
echo Failed to download or unpack Node.js.
echo Install Node.js from https://nodejs.org and run this script again.

:end
endlocal
