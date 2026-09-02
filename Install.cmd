@echo off
setlocal
title redrive setup
echo.
echo  redrive - keeps your reMarkable tablet and OneNote in sync over the USB cable.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0redrive.ps1" setup %*
echo.
pause
