@echo off
REM ============================================================================
REM  MotionFit one-click launcher.
REM  Starts the Python pose service (camera -> movement) and the game together.
REM  Double-click this file, or make a desktop shortcut to it.
REM
REM  When you close the game window, the pose service is stopped too.
REM ============================================================================
setlocal
cd /d "%~dp0"

REM --- 1) Pose service, in its OWN terminal window ----------------------------
REM  --game = managed mode: NO OpenCV preview window, and the webcam is switched
REM  on/off by the game (dark in menus, live only while you play). The console
REM  still shows its text logs. Run "python python\pose\pose_server.py" WITHOUT
REM  --game to test the pose service alone with its preview window.
start "MotionFit Pose Service" cmd /k python python\pose\pose_server.py --game

REM --- 2) The game ------------------------------------------------------------
REM  Point GODOT at your editor executable. If it's on your PATH, the fallback
REM  below ("godot") is used instead. To open the EDITOR rather than run the
REM  game, add  -e  to the end of the line (e.g. ... --path "%CD%" -e).
set "GODOT=C:\Users\aliba\OneDrive\Desktop\Godot_v4.7-stable_win64.exe"
if not exist "%GODOT%" set "GODOT=godot"

echo Launching the game with %GODOT% ...
REM  Use %CD% (this folder, no trailing backslash) rather than %~dp0 — a trailing
REM  "\" right before the closing quote gets swallowed as an escaped quote and
REM  Godot never sees a valid project path. No START, so this waits until you
REM  quit the game, letting the next line tidy up the pose service.
"%GODOT%" --path "%CD%"
if errorlevel 1 (
    echo.
    echo Could not start Godot. Edit the GODOT path near the top of run.bat.
    pause
)

REM --- 3) Game closed: stop the pose service ----------------------------------
taskkill /FI "WINDOWTITLE eq MotionFit Pose Service*" /T /F >nul 2>&1
endlocal
