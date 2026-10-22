@echo off
REM Build script for Windows platforms
setlocal enabledelayedexpansion

REM SCons flags: precision=double matches the engine ABI; disable_exceptions=no keeps
REM C++ exceptions on so libpqxx query errors are catchable.
set "BUILD_FLAGS=precision=double disable_exceptions=no"

echo Building PostgreSQL GDExtension for Windows...

REM Check for required dependencies
echo Checking dependencies...

REM Check for Visual Studio Build Tools
where cl >nul 2>nul
if %errorlevel% neq 0 (
    echo Visual Studio Build Tools not found in PATH
    echo    Please run this from a Visual Studio Developer Command Prompt
    echo    or install Visual Studio Build Tools
    exit /b 1
)

REM Check for SCons
where scons >nul 2>nul
if %errorlevel% neq 0 (
    echo SCons not found. Install with:
    echo    pip install scons
    exit /b 1
)

REM Check for PostgreSQL
if not defined POSTGRESQL_PATH (
    if exist "C:\Program Files\PostgreSQL\16" (
        set POSTGRESQL_PATH=C:\Program Files\PostgreSQL\16
    ) else if exist "C:\Program Files\PostgreSQL\15" (
        set POSTGRESQL_PATH=C:\Program Files\PostgreSQL\15
    ) else if exist "C:\Program Files\PostgreSQL\14" (
        set POSTGRESQL_PATH=C:\Program Files\PostgreSQL\14
    ) else (
        echo PostgreSQL not found. Please:
        echo    1. Install PostgreSQL from https://www.postgresql.org/download/windows/
        echo    2. Or set POSTGRESQL_PATH environment variable
        exit /b 1
    )
)

echo Dependencies found
echo Using PostgreSQL at: %POSTGRESQL_PATH%

REM Build the extension. The root SConstruct builds godot-cpp itself against .\extension_api.json;
REM building inside godot-cpp\ directly would generate bindings from godot-cpp's bundled API instead.
echo Building PostgreSQL extension for Windows...
scons platform=windows target=template_debug arch=x86_64 %BUILD_FLAGS%
if %errorlevel% neq 0 exit /b %errorlevel%

scons platform=windows target=template_release arch=x86_64 %BUILD_FLAGS%
if %errorlevel% neq 0 exit /b %errorlevel%

echo Windows build completed!
echo Debug library: addons\godot-postgresql\bin\lib_postgresql_adapter.windows.template_debug.double.x86_64.dll
echo Release library: addons\godot-postgresql\bin\lib_postgresql_adapter.windows.template_release.double.x86_64.dll