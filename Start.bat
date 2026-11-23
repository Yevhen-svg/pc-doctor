@echo off
cd /d "%~dp0"
if not exist "%~dp0scan.ps1" (
  echo scan.ps1 was not found. Extract the WHOLE zip archive first, then run this file from the extracted folder.
  pause
  exit /b 1
)
rem Check administrator rights (fltmc works even when the Server service is disabled)
fltmc >nul 2>&1
if errorlevel 1 (
  if /i "%~1"=="/elevated" (
    echo Could not get administrator rights. Right-click this file and choose Run as administrator.
    pause
    exit /b 1
  )
  set "PCD_SELF=%~f0"
  powershell -NoProfile -Command "try { Start-Process -FilePath $env:PCD_SELF -ArgumentList '/elevated' -WorkingDirectory (Split-Path $env:PCD_SELF) -Verb RunAs -ErrorAction Stop } catch { Write-Host 'Administrator permission was not granted. PC Doctor needs it to read sensors and apply fixes.'; Start-Sleep 8 }"
  exit /b
)
cd /d "%~dp0"
rem Remove the Windows download block from the extracted files (prevents repeated security warnings)
powershell -NoProfile -Command "Get-ChildItem -LiteralPath '%~dp0.' -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue" >nul 2>&1
rem Stop older PC Doctor windows so an old version cannot keep serving the page
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'powershell.exe' -and $_.CommandLine -match 'scan\.ps1' -and $_.ProcessId -ne $PID } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"
timeout /t 1 /nobreak >nul
chcp 65001 >nul
title PC Doctor
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scan.ps1"
echo.
pause
