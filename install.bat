@echo off
setlocal EnableExtensions

REM ==========================================================================
REM  install.bat - deploys Clear-ShaderCache.ps1 to %SystemDrive%\, creates the boot task,
REM  and adds the desktop shortcuts. Keep this file next to the .ps1.
REM ==========================================================================

REM --- Use PowerShell 7 (pwsh) if available, otherwise Windows PowerShell ---
where pwsh >nul 2>&1 && (set "PSEXE=pwsh") || (set "PSEXE=powershell")

set "SCRIPT_NAME=Clear-ShaderCache.ps1"
set "SRC=%~dp0%SCRIPT_NAME%"
set "DST=%SystemDrive%\%SCRIPT_NAME%"

REM --- The script must sit next to this batch file ---
if not exist "%SRC%" (
    echo [ERROR] Clear-ShaderCache.ps1 was not found next to this batch file.
    echo         Expected: "%SRC%"
    echo.
    pause
    exit /b 1
)

REM --- Writing to %SystemDrive%\ root needs admin: self-elevate if necessary ---
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    %PSEXE% -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo Installing script to "%DST%" ...
copy /Y "%SRC%" "%DST%" >nul
if %errorlevel% neq 0 (
    echo [ERROR] Failed to copy the script to "%DST%".
    echo.
    pause
    exit /b 1
)

echo Generating desktop shortcuts ...
%PSEXE% -NoProfile -ExecutionPolicy Bypass -File "%DST%" -CreateDesktopShortcuts
if %errorlevel% neq 0 (
    echo [ERROR] Shortcut generation failed.
    echo.
    pause
    exit /b 1
)

echo Creating boot task ...
%PSEXE% -NoProfile -ExecutionPolicy Bypass -File "%DST%" -CreateTask
if %errorlevel% neq 0 (
    echo [ERROR] Task creation failed.
    echo.
    pause
    exit /b 1
)

echo.
echo Done. Installed: "%DST%"
echo.
pause
