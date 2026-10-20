@echo off
rem Clean-installs the VexelRay stack in dependency order, then tests every application and builds its
rem release native image. Run from anywhere; the sibling checkouts must sit beside this folder.
rem Logs land in logs\. Stops at the first library that fails; an application that fails is reported and skipped.
setlocal
set "ROOT=%~dp0.."
set "LOGS=%~dp0logs"
if not exist "%LOGS%" mkdir "%LOGS%"
call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
where cl >nul 2>&1 || ( echo vcvars64 did not set up MSVC; run this from PowerShell or a developer prompt, not Git Bash & exit /b 1 )
rem vexplore's RemotesTest runs Git's sftp-server.exe, which needs msys-2.0.dll from Git's usr\bin. Appended, not
rem prepended: usr\bin has its own link.exe, and native-image must find MSVC's first.
set "PATH=%PATH%;C:\Program Files\Git\usr\bin"

for %%r in (vexelray-build intrabuf atchung supirvast dxgi-bridge kronometer tactroller vexelray imagelib-wrapper vexelray-gui vexelray-framework ffmpeg-wrapper vexelray-codec vex-suite-common cott-engine cardinal concordance-indexer vexelray-sim-core vexelray-installer) do (
  echo [%%r] clean install
  pushd "%ROOT%\%%r"
  call mvn -B clean install > "%LOGS%\%%r.log" 2>&1
  if errorlevel 1 ( echo [%%r] FAILED, see logs\%%r.log & popd & goto :failed )
  popd
)

set FAILED=
for %%r in (mainframe text-editor-vexel-demo Pix vexplore vexelray-sim-fluid vexelray-sim-rigid calculator-vexel-demo vexelray-maistro vexelray-inspector) do (
  pushd "%ROOT%\%%r"
  echo [%%r] tests
  call mvn -B clean install > "%LOGS%\app-%%r.log" 2>&1
  if errorlevel 1 ( echo [%%r] FAILED, see logs\app-%%r.log & set FAILED=1 ) else (
    echo [%%r] native image
    call mvn -B -Pnative-release clean package -DskipTests > "%LOGS%\native-%%r.log" 2>&1
    if errorlevel 1 ( echo [%%r] NATIVE FAILED, see logs\native-%%r.log & set FAILED=1 )
  )
  popd
)
if defined FAILED ( echo Some applications failed. & goto :failed )
echo Build done.
exit /b 0

rem An exit /b inside a block that has more commands after it (the loop's popd) loses its code when this runs
rem under cmd /c without call: cmd /c then returns 0. So every failure exits from here, outside any block.
:failed
exit /b 1
