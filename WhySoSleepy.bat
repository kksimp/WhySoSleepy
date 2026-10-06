@echo off
rem Starts WhySoSleepy.ps1 from this folder. "-ExecutionPolicy Bypass" applies to
rem this run only; it does not change the system execution policy.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0WhySoSleepy.ps1" %*
if errorlevel 1 pause
