@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0Mission-Centre.ps1"
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo *** Mission Centre exited with error code %ERRORLEVEL% ***
    pause
)
