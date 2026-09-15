@echo off
rem ===========================================================================
rem  build.cmd - builds node-streaming-server on Windows.
rem
rem  There is nothing to compile: the server is plain Node.js with zero npm
rem  dependencies. "Building" therefore means
rem
rem    1. find a Node.js runtime (tools\node first, then PATH)
rem    2. check every source file parses
rem    3. stage a self-contained, runnable dist\ folder
rem    4. actually start that dist\ and stream a frame through it
rem
rem    build.cmd                  build and smoke-test
rem    build.cmd --no-test        build only, skip the smoke test
rem    build.cmd --bundle-node    also copy tools\node into dist\node, so the
rem                               dist\ folder runs on a machine with no Node
rem ===========================================================================
setlocal EnableDelayedExpansion
cd /d "%~dp0"

set "MIN_MAJOR=18"
set "DIST=%CD%\dist"
set "NODE="
set "SKIPTEST="
set "BUNDLE="

:args
if "%~1"=="" goto args_done
if /i "%~1"=="--no-test" set "SKIPTEST=1"
if /i "%~1"=="--skip-tests" set "SKIPTEST=1"
if /i "%~1"=="--bundle-node" set "BUNDLE=1"
shift
goto args

:args_done
echo === node-streaming-server : build ===
echo.

rem ------------------------------------------------------ [1/5] the toolchain
echo [1/5] locating Node.js ...
if exist "tools\node\node.exe" set "NODE=%CD%\tools\node\node.exe"
if not defined NODE (
  where node >nul 2>nul
  if !errorlevel!==0 set "NODE=node"
)
if not defined NODE (
  echo.
  echo [FAIL] no Node.js found.
  echo        Run  download-tools.cmd  first, or install Node.js ^>= v%MIN_MAJOR%
  echo        from https://nodejs.org
  goto die
)
for /f "delims=" %%v in ('"!NODE!" --version 2^>nul') do set "NODEVER=%%v"
if "!NODEVER!"=="" (
  echo [FAIL] "!NODE!" is not a working Node.js binary.
  goto die
)
set "TRIM=!NODEVER:v=!"
for /f "tokens=1 delims=." %%a in ("!TRIM!") do set "NODEMAJOR=%%a"
if !NODEMAJOR! LSS %MIN_MAJOR% (
  echo [FAIL] Node.js !NODEVER! is too old - v%MIN_MAJOR% or newer is required.
  echo        Run  download-tools.cmd --force  to fetch a supported version.
  goto die
)
echo       Node.js !NODEVER!  ^(!NODE!^)

rem ------------------------------------------------------- [2/5] the sources
echo [2/5] checking sources ...
set "MISSING="
if not exist "server.js" set "MISSING=!MISSING! server.js"
if not exist "package.json" set "MISSING=!MISSING! package.json"
if not exist "public\index.html" set "MISSING=!MISSING! public\index.html"
if not "!MISSING!"=="" (
  echo [FAIL] missing source file^(s^):!MISSING!
  goto die
)

"!NODE!" --check server.js || goto fail_syntax
"!NODE!" --check scripts\smoke-test.js || goto fail_syntax
rem NB: no "!" anywhere in the snippet below - delayed expansion would eat it.
"!NODE!" -e "const p = JSON.parse(require('fs').readFileSync('package.json', 'utf8')); if (p.name === undefined || p.version === undefined) { throw new Error('package.json needs a name and a version'); } console.log('      ' + p.name + ' v' + p.version);" || goto fail_syntax
echo       server.js parses, package.json is valid

rem -------------------------------------------------------- [3/5] stage dist
echo [3/5] staging dist\ ...
if exist "%DIST%" rmdir /s /q "%DIST%"
mkdir "%DIST%" || goto fail_stage
copy /y "server.js" "%DIST%\" >nul || goto fail_stage
copy /y "package.json" "%DIST%\" >nul || goto fail_stage
xcopy "public" "%DIST%\public\" /E /I /Y /Q >nul || goto fail_stage
copy /y "scripts\run-template.cmd" "%DIST%\run.cmd" >nul || goto fail_stage
copy /y "scripts\run-template.sh" "%DIST%\run.sh" >nul || goto fail_stage
if exist "readme.md" copy /y "readme.md" "%DIST%\README.md" >nul
if exist "LICENSE" copy /y "LICENSE" "%DIST%\" >nul
echo       server.js + public\ + run.cmd / run.sh

if defined BUNDLE (
  if not exist "tools\node\node.exe" (
    echo [FAIL] --bundle-node needs tools\node - run download-tools.cmd --force
    goto die
  )
  echo       bundling the portable Node.js runtime ...
  xcopy "tools\node" "%DIST%\node\" /E /I /Y /Q >nul || goto fail_stage
)

rem --------------------------------------------------------- [4/5] smoke test
if defined SKIPTEST (
  echo [4/5] smoke test skipped ^(--no-test^)
  goto report
)
echo [4/5] smoke test - starting dist\server.js and relaying a frame ...
"!NODE!" "scripts\smoke-test.js" "%DIST%"
if errorlevel 1 (
  echo.
  echo [FAIL] the built server did not pass the smoke test.
  goto die
)

rem -------------------------------------------------------------- [5/5] done
:report
echo [5/5] done
echo.
echo BUILD OK
echo.
echo   Run it:            dist\run.cmd
echo   Or directly:       "!NODE!" dist\server.js
echo.
echo   The viewer page and the stream endpoint share one TCP port; the server
echo   prints it on startup (it prefers 80, then 8080, then 8000).
echo.
endlocal
exit /b 0

rem ---------------------------------------------------------------- failures
:fail_syntax
echo.
echo [FAIL] a source file did not parse - see the error above.
goto die

:fail_stage
echo.
echo [FAIL] could not stage dist\ - is a file in it open or read-only?
goto die

:die
echo.
echo BUILD FAILED
endlocal
exit /b 1
