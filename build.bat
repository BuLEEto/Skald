@echo off
REM Build one of the Skald examples on Windows.
REM
REM Usage:
REM   build.bat                   builds 01_hello (default)
REM   build.bat 01_hello          builds examples\01_hello
REM   build.bat 01_hello run      builds and runs
REM
REM Prerequisites (one-time):
REM   1. Odin installed and on PATH.
REM   2. MSVC build tools installed; launch from the Developer command prompt.
REM   3. Vulkan loader on PATH (bundled with recent GPU drivers; otherwise
REM      install the Vulkan SDK from https://vulkan.lunarg.com/).
REM
REM The SDL3 runtime DLL is copied next to the built .exe automatically.

setlocal
cd /d %~dp0

set EXAMPLE=%1
if "%EXAMPLE%"=="" set EXAMPLE=01_hello

set ACTION=%2
if "%ACTION%"=="" set ACTION=build

if not exist build mkdir build

odin build "examples\%EXAMPLE%" -collection:gui=. -out:"build\%EXAMPLE%.exe"
if errorlevel 1 exit /b 1

REM Locate Odin's install tree to find SDL3.dll. `where odin` returns the
REM path to odin.exe; the vendor SDL3 DLL ships under vendor\sdl3\ next to
REM it. We walk up one directory from odin.exe to reach the Odin root.
for /f "delims=" %%I in ('where odin') do set ODIN_EXE=%%I
for %%I in ("%ODIN_EXE%") do set ODIN_ROOT=%%~dpI

set SDL3_DLL=%ODIN_ROOT%vendor\sdl3\SDL3.dll

if exist "%SDL3_DLL%" (
    copy /Y "%SDL3_DLL%" "build\" >nul
) else (
    echo WARNING: SDL3.dll not found at %SDL3_DLL%
    echo          Copy it into build\ manually or the exe will fail to start.
)

if /i "%ACTION%"=="run" (
    "build\%EXAMPLE%.exe"
)
