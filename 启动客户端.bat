@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
where powershell >nul 2>nul
if %errorlevel%==0 (
  powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0llama-launcher.ps1" %*
) else (
  where pwsh >nul 2>nul
  if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0llama-launcher.ps1" %*
  ) else (
    echo [ERROR] No PowerShell found.
    pause
  )
)
if errorlevel 1 pause
