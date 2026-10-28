@echo off
rem Double-click to fetch this week's flyers and open the deals report.
powershell -NoProfile -File "%~dp0app\Get-Deals.ps1" -Open
if errorlevel 1 pause
