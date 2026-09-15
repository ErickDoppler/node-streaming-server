@echo off
rem ===========================================================================
rem  run.cmd - starts the Streaming Server from this folder and opens the
rem  viewer page. Copied here by build.cmd; edit the original in
rem  scripts\run-template.cmd.
rem
rem  Node.js is looked for in this order:
rem    1. node\node.exe        (bundled by "build.cmd --bundle-node")
rem    2. ..\tools\node        (fetched by download-tools.cmd)
rem    3. node on PATH
rem ===========================================================================
setlocal EnableDelayedExpansion
cd /d "%~dp0"

set "NODE="
if exist "node\node.exe" set "NODE=%CD%\node\node.exe"
if not defined NODE if exist "..\tools\node\node.exe" set "NODE=%CD%\..\tools\node\node.exe"
if not defined NODE (
  where node >nul 2>nul
  if !errorlevel!==0 set "NODE=node"
)
if not defined NODE (
  echo No Node.js found.
  echo Run download-tools.cmd in the project folder, or install Node.js
  echo version 18 or newer from https://nodejs.org
  exit /b 1
)

echo Starting Streaming Server ...
start "Streaming Server" "%NODE%" server.js

rem The server writes .ports.json with the port it managed to bind.
set /a TRIES=0
:wait
if exist .ports.json goto open
set /a TRIES+=1
if !TRIES! gtr 30 goto noport
timeout /t 1 /nobreak >nul
goto wait

:open
rem Keep this on one line, and without a pipe: a "^" continuation inside for /f
rem breaks the quoting, and "^|" would reach PowerShell as a literal caret.
set "PORT="
for /f "delims=" %%p in ('powershell -NoProfile -ExecutionPolicy Bypass -Command "(ConvertFrom-Json (Get-Content -Raw .ports.json)).port"') do set "PORT=%%p"
if "!PORT!"=="" goto noport
echo Viewer page: http://localhost:!PORT!/
start "" "http://localhost:!PORT!/"
goto end

:noport
echo The server started but reported no port - check the server window.

:end
endlocal
exit /b 0
