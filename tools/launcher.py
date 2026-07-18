"""MotionFit release launcher.

This is the small program behind the shipped MotionFit.exe (built by
tools/build_release.py). It expects to sit in a folder laid out like:

    MotionFit.exe            <- this launcher
    game/MotionFit.exe       <- Godot runtime
    game/MotionFit.pck       <- the packed game
    pose_server/pose_server.exe  <- the bundled camera/pose service

It starts the pose service in managed (--game) mode, then runs the game and
waits for it; when the game window closes, the pose service is shut down too
(taskkill /T so the whole process tree goes, mirroring run.bat).

The pose service runs hidden with its output logged to pose_server.log next to
this exe. Set MOTIONFIT_DEBUG=1 to give it a visible console instead.
"""
from __future__ import annotations

import ctypes
import os
import subprocess
import sys
from pathlib import Path


def _fatal(message: str) -> None:
    # No console in the shipped exe, so surface errors as a message box.
    ctypes.windll.user32.MessageBoxW(None, message, "MotionFit", 0x10)
    sys.exit(1)


def main() -> None:
    if getattr(sys, "frozen", False):
        root = Path(sys.executable).resolve().parent
    else:
        root = Path(__file__).resolve().parent

    pose_exe = root / "pose_server" / "pose_server.exe"
    game_exe = root / "game" / "MotionFit.exe"
    game_pck = root / "game" / "MotionFit.pck"
    for required in (pose_exe, game_exe, game_pck):
        if not required.exists():
            _fatal(
                "Missing file:\n%s\n\nMotionFit.exe must stay inside its "
                "folder next to game/ and pose_server/." % required
            )

    debug = os.environ.get("MOTIONFIT_DEBUG") == "1"
    # Unbuffered, or the log stays empty: the service is block-buffered when
    # piped to a file, and the final taskkill /F discards whatever is pending.
    pose_env = {**os.environ, "PYTHONUNBUFFERED": "1"}
    if debug:
        pose_proc = subprocess.Popen(
            [str(pose_exe), "--game"],
            cwd=str(pose_exe.parent),
            env=pose_env,
            creationflags=subprocess.CREATE_NEW_CONSOLE,
        )
        log = None
    else:
        log = open(root / "pose_server.log", "w", buffering=1)
        pose_proc = subprocess.Popen(
            [str(pose_exe), "--game"],
            cwd=str(pose_exe.parent),
            env=pose_env,
            stdout=log,
            stderr=subprocess.STDOUT,
            creationflags=subprocess.CREATE_NO_WINDOW,
        )

    try:
        # No --main-pack: the runtime auto-loads the MotionFit.pck sitting next
        # to it, and the 4.7 release template actively refuses path-override
        # flags (built with disable_path_overrides).
        subprocess.run(
            [str(game_exe)],
            cwd=str(game_exe.parent),
        )
    finally:
        # /T takes the whole tree down so no camera-holding child survives.
        subprocess.run(
            ["taskkill", "/PID", str(pose_proc.pid), "/T", "/F"],
            creationflags=subprocess.CREATE_NO_WINDOW,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if log is not None:
            log.close()


if __name__ == "__main__":
    main()
