@echo off
rem Double-click launcher for the USB Diagnostic Toolkit.
rem Starts PowerShell with a per-process execution-policy bypass, so the
rem script runs even on systems where PowerShell scripts are disabled or
rem the downloaded file is blocked ("mark of the web").
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0_USB-Diagnostic-Toolkit.ps1" %*
if errorlevel 1 (
    echo.
    echo PowerShell exited with an error. See the message above.
    pause
)
