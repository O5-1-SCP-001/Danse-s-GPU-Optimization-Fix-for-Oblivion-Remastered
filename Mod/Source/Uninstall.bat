@echo off
rem Restores settings recorded by the Oblivion Remastered Performance Fix installer.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-PerformanceFix.ps1" -Uninstall %*
pause
