@echo off
rem Realistic Shoreline Waves - open-ocean demo (Gerstner waves only, no solver)
rem Place a Godot 4.7 (or newer) Windows binary in this folder first.
cd /d "%~dp0"
set "GODOT="
for %%G in (Godot*.exe godot*.exe) do (
	echo %%~nG | findstr /i "console" >nul
	if errorlevel 1 set "GODOT=%%G"
)
if "%GODOT%"=="" (
	echo.
	echo   Realistic Shoreline Waves
	echo   -------------------------
	echo   No Godot binary found in this folder.
	echo   Download Godot 4.7 stable for Windows from https://godotengine.org/download
	echo   drop the .exe next to this file and run the launcher again.
	echo.
	pause
	exit /b 1
)
start "" "%GODOT%" --path . scenes/gerstner_ocean.tscn
