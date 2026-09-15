@echo off
rem ===========================================================================
rem  download-tools.cmd - fetches every tool needed to build and run this
rem  project on Windows.
rem
rem  The server has zero npm dependencies, so the one and only build tool is
rem  the Node.js runtime. It is fetched as a portable ZIP into tools\node\ -
rem  nothing is installed system-wide, nothing touches the registry or PATH.
rem
rem    download-tools.cmd           reuse the Node.js already on PATH if it is
rem                                 new enough, otherwise download a portable one
rem    download-tools.cmd --force   always download the portable Node.js
rem
rem  Override the version with:  set NODE_VERSION=v20.18.1
rem ===========================================================================
setlocal EnableDelayedExpansion
cd /d "%~dp0"

if "%NODE_VERSION%"=="" set "NODE_VERSION=v22.12.0"
set "MIN_MAJOR=18"
set "TOOLS=%CD%\tools"
set "NODE_HOME=%TOOLS%\node"
set "NODE_EXE=%NODE_HOME%\node.exe"
set "FORCE="
if /i "%~1"=="--force" set "FORCE=1"
if /i "%~1"=="-f" set "FORCE=1"

echo === node-streaming-server : download-tools ===
echo.

rem --------------------------------------------------------------- already?
if defined FORCE goto want_portable
if not exist "%NODE_EXE%" goto check_path
for /f "delims=" %%v in ('"%NODE_EXE%" --version 2^>nul') do set "HAVE=%%v"
if "!HAVE!"=="" goto want_portable
echo [ok]   portable Node.js !HAVE! is already in tools\node
goto summary

rem ------------------------------------------------------- Node.js on PATH?
:check_path
set "SYSVER="
for /f "delims=" %%v in ('node --version 2^>nul') do set "SYSVER=%%v"
if "!SYSVER!"=="" (
  echo [..]   no Node.js on PATH
  goto want_portable
)
set "TRIM=!SYSVER:v=!"
for /f "tokens=1 delims=." %%a in ("!TRIM!") do set "SYSMAJOR=%%a"
if !SYSMAJOR! GEQ %MIN_MAJOR% (
  echo [ok]   Node.js !SYSVER! found on PATH - new enough, no download needed
  echo        ^(run "download-tools.cmd --force" to get a portable copy anyway^)
  goto summary
)
echo [..]   Node.js !SYSVER! on PATH is older than v%MIN_MAJOR%

rem --------------------------------------------------- download portable Node
:want_portable
set "ARCH=x64"
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "ARCH=arm64"
if /i "%PROCESSOR_ARCHITECTURE%"=="x86" (
  if not defined PROCESSOR_ARCHITEW6432 set "ARCH=x86"
)

set "PKG=node-%NODE_VERSION%-win-%ARCH%"
set "ZIP=%PKG%.zip"
set "BASE=https://nodejs.org/dist/%NODE_VERSION%"
set "DL=%TOOLS%\download"

echo [..]   downloading Node.js %NODE_VERSION% ^(win-%ARCH%^) ...
if not exist "%TOOLS%" mkdir "%TOOLS%"
if not exist "%DL%" mkdir "%DL%"

call :fetch "%BASE%/%ZIP%" "%DL%\%ZIP%"
if errorlevel 1 goto fail_download
call :fetch "%BASE%/SHASUMS256.txt" "%DL%\SHASUMS256.txt"
if errorlevel 1 goto fail_download

rem --- verify the archive against the checksums published by nodejs.org ---
echo [..]   verifying SHA-256 ...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$line = Get-Content '%DL%\SHASUMS256.txt' | Where-Object { $_.EndsWith('  %ZIP%') } | Select-Object -First 1; if (-not $line) { Write-Host ('no checksum published for %ZIP%'); exit 1 }; $want = $line.Substring(0, 64).ToLower(); $got = (Get-FileHash -Algorithm SHA256 '%DL%\%ZIP%').Hash.ToLower(); if ($want -ne $got) { Write-Host ('want ' + $want); Write-Host ('got  ' + $got); exit 1 }; exit 0"
if errorlevel 1 goto fail_checksum
echo [ok]   checksum matches nodejs.org SHASUMS256.txt

rem --- unpack ------------------------------------------------------------
echo [..]   unpacking ...
if exist "%DL%\unpack" rmdir /s /q "%DL%\unpack"
mkdir "%DL%\unpack"
where tar >nul 2>nul
if %errorlevel%==0 (
  tar -xf "%DL%\%ZIP%" -C "%DL%\unpack"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Expand-Archive -LiteralPath '%DL%\%ZIP%' -DestinationPath '%DL%\unpack' -Force"
)
if not exist "%DL%\unpack\%PKG%\node.exe" goto fail_unpack

if exist "%NODE_HOME%" rmdir /s /q "%NODE_HOME%"
move "%DL%\unpack\%PKG%" "%NODE_HOME%" >nul
if not exist "%NODE_EXE%" goto fail_unpack

rmdir /s /q "%DL%\unpack" 2>nul
del /q "%DL%\%ZIP%" 2>nul
del /q "%DL%\SHASUMS256.txt" 2>nul
rmdir "%DL%" 2>nul

for /f "delims=" %%v in ('"%NODE_EXE%" --version 2^>nul') do set "HAVE=%%v"
echo [ok]   portable Node.js !HAVE! installed in tools\node

rem ------------------------------------------------------------------ done
:summary
echo.
echo All build tools are in place.
echo Next:  build.cmd
echo.
endlocal
exit /b 0

rem ----------------------------------------------------------------- helper
rem fetch <url> <destination file> - curl.exe when present, else PowerShell.
:fetch
where curl >nul 2>nul
if %errorlevel%==0 (
  curl -fL --retry 3 --proto "=https" -o "%~2" "%~1"
  exit /b %errorlevel%
)
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; $ProgressPreference = 'SilentlyContinue'; try { Invoke-WebRequest -Uri '%~1' -OutFile '%~2' -UseBasicParsing; exit 0 } catch { Write-Host $_.Exception.Message; exit 1 }"
exit /b %errorlevel%

rem ---------------------------------------------------------------- failures
:fail_download
echo.
echo [FAIL] could not download from nodejs.org.
echo        Check the network / proxy, or install Node.js ^>= v%MIN_MAJOR%
echo        yourself from https://nodejs.org and re-run this script.
endlocal
exit /b 1

:fail_checksum
echo.
echo [FAIL] SHA-256 of %ZIP% does not match nodejs.org SHASUMS256.txt.
echo        The download was corrupted or tampered with - nothing installed.
endlocal
exit /b 1

:fail_unpack
echo.
echo [FAIL] could not unpack %ZIP%.
endlocal
exit /b 1
