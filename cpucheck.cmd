@echo off
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -File \"%USERPROFILE%\windows-healthcheck\cpu-healthcheck.ps1\" %*'"
    exit /b
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\windows-healthcheck\cpu-healthcheck.ps1" %*
