"""Build a shippable, double-clickable MotionFit release.

    python tools/build_release.py

Produces build/MotionFit/ containing everything a player needs (no Python, no
Godot install required on their machine):

    MotionFit.exe                the launcher (this is what you double-click):
                                 starts the pose service + the game together and
                                 stops the service when the game closes
    game/MotionFit.exe           Godot runtime (copy of your Godot editor exe)
    game/MotionFit.pck           the packed game (all scenes/scripts/assets)
    pose_server/pose_server.exe  camera -> movement service (MediaPipe bundled)

Why a .pck + runtime copy instead of a one-file Godot export: a template export
needs the ~1 GB Godot 4.7 export-template download, which isn't installed. The
.pck route needs nothing extra and behaves identically. Swap in a proper export
later by installing templates and replacing the export step.

Requirements on the BUILD machine (this one): Godot 4.7 exe (GODOT env var or
the default path below) and Python 3.12. The pose service is bundled from a
dedicated clean venv (build/venv, created + populated automatically) rather
than your day-to-day site-packages — bundling from the global Python swept in
every conditional import PyInstaller could find (tensorflow, spacy, playwright,
notebook, ...) and produced a 3 GB build; the clean venv keeps it lean.

Zip the build/MotionFit folder to give the game to someone else.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
GODOT = Path(
    os.environ.get(
        "GODOT", r"C:\Users\aliba\OneDrive\Desktop\Godot_v4.7-stable_win64.exe"
    )
)
OUT = REPO / "build" / "MotionFit"
WORK = REPO / "build" / "pyinstaller"  # PyInstaller spec/work dirs (throwaway)
VENV = REPO / "build" / "venv"  # clean bundling env; survives clean_output()
MODEL = REPO / "python" / "pose" / "models" / "pose_landmarker_full.task"


def step(title: str) -> None:
    print(f"\n=== {title} ===", flush=True)


def run(cmd: list[str], **kwargs) -> None:
    print("> " + " ".join(str(c) for c in cmd), flush=True)
    subprocess.run([str(c) for c in cmd], check=True, **kwargs)


def _rmtree_retry(path: Path, attempts: int = 6) -> None:
    # This repo lives under OneDrive, whose sync engine briefly holds handles
    # on freshly-written build files - the first rmtree of a 3 GB bundle can
    # hit WinError 32. Back off and retry rather than failing the build.
    for i in range(attempts):
        try:
            shutil.rmtree(path)
            return
        except OSError:
            if i == attempts - 1:
                raise
            print(f"  {path} is busy (OneDrive sync?), retrying in 5s...")
            time.sleep(5)


def clean_output() -> None:
    step("Cleaning previous build output")
    for path in (OUT, WORK):
        if path.exists():
            _rmtree_retry(path)
    (OUT / "game").mkdir(parents=True)
    WORK.mkdir(parents=True)


def export_pck() -> None:
    step("Exporting the game to game/MotionFit.pck")
    if not GODOT.exists():
        sys.exit(f"Godot not found at {GODOT} - set the GODOT env var.")
    # Headless Godot boots re-save project.godot (autoload reordering churn,
    # see tools/README.md); snapshot and restore so builds never dirty git.
    project_godot = REPO / "project.godot"
    before = project_godot.read_bytes()
    try:
        run(
            [
                GODOT,
                "--headless",
                "--path",
                REPO,
                "--export-pack",
                "Windows Desktop",
                OUT / "game" / "MotionFit.pck",
            ]
        )
    finally:
        if project_godot.read_bytes() != before:
            project_godot.write_bytes(before)
            print("(restored project.godot after headless churn)")
    pck = OUT / "game" / "MotionFit.pck"
    if not pck.exists() or pck.stat().st_size < 1_000_000:
        sys.exit("Export produced no usable .pck - check the Godot output above.")
    print(f"pck: {pck.stat().st_size / 1e6:.1f} MB")


def copy_runtime() -> None:
    step("Copying the Godot runtime to game/MotionFit.exe")
    shutil.copy2(GODOT, OUT / "game" / "MotionFit.exe")


def venv_python() -> Path:
    return VENV / "Scripts" / "python.exe"


def ensure_venv() -> None:
    step("Preparing the clean bundling venv (build/venv)")
    if not venv_python().exists():
        run([sys.executable, "-m", "venv", VENV])
    # No-op in seconds when already satisfied, so safe to run every build.
    run(
        [
            venv_python(),
            "-m",
            "pip",
            "install",
            "-r",
            REPO / "python" / "requirements.txt",
            "pyinstaller",
        ]
    )


def build_pose_server() -> None:
    step("Bundling the pose service (this is the slow part)")
    cmd = [
        venv_python(),
        "-m",
        "PyInstaller",
        "--noconfirm",
        "--onedir",
        "--console",
        "--name",
        "pose_server",
        "--distpath",
        OUT,
        "--workpath",
        WORK / "build",
        "--specpath",
        WORK,
        # mediapipe loads .task/.tflite/.binarypb data files at runtime; pull
        # in the whole package so none are missed.
        "--collect-all",
        "mediapipe",
    ]
    if MODEL.exists():
        # pose_server resolves the model as <script dir>/models/, which in a
        # frozen build is _internal/models/ - exactly where this lands.
        cmd += ["--add-data", f"{MODEL};models"]
    else:
        print(
            "WARNING: pose model missing at "
            f"{MODEL}\n         The shipped exe will download it on first run."
        )
    cmd.append(REPO / "python" / "pose" / "pose_server.py")
    run(cmd)


def build_launcher() -> None:
    step("Building the MotionFit.exe launcher")
    run(
        [
            venv_python(),
            "-m",
            "PyInstaller",
            "--noconfirm",
            "--onefile",
            "--noconsole",
            "--name",
            "MotionFit",
            "--distpath",
            OUT,
            "--workpath",
            WORK / "build",
            "--specpath",
            WORK,
            REPO / "tools" / "launcher.py",
        ]
    )


def write_readme() -> None:
    (OUT / "README.txt").write_text(
        "MotionFit\n"
        "=========\n\n"
        "Double-click MotionFit.exe to play.\n\n"
        "It starts the camera service and the game together, and stops the\n"
        "camera service again when you close the game. The webcam only turns\n"
        "on while you are in a game, never in the menus.\n\n"
        "Keep this whole folder together - MotionFit.exe needs the game/ and\n"
        "pose_server/ folders next to it. To put it on another PC, copy or\n"
        "zip the entire folder.\n\n"
        "Troubleshooting: pose_server.log (next to MotionFit.exe) holds the\n"
        "camera service's output from the last run. Set the environment\n"
        "variable MOTIONFIT_DEBUG=1 before launching to see it live in its\n"
        "own console window.\n"
    )


def summary() -> None:
    step("Done")
    total = sum(f.stat().st_size for f in OUT.rglob("*") if f.is_file())
    print(f"Release folder: {OUT}  ({total / 1e6:.0f} MB)")
    for item in sorted(OUT.iterdir()):
        print(f"  {item.name}{'/' if item.is_dir() else ''}")
    print("\nDouble-click build\\MotionFit\\MotionFit.exe to play.")
    print("Zip the MotionFit folder to share it.")


def main() -> None:
    clean_output()
    export_pck()
    copy_runtime()
    ensure_venv()
    build_pose_server()
    build_launcher()
    write_readme()
    summary()


if __name__ == "__main__":
    main()
