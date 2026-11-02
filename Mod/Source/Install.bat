@echo off
rem Installs the Oblivion Remastered Performance Fix (auto-detects your GPU tier).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-PerformanceFix.ps1" %*
pause
