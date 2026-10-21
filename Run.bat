@echo off
:: Launcher for WinSlim. Double-click to start (it will ask for admin rights).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0WinSlim.ps1" %*
