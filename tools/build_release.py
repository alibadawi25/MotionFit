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

The runtime next to the .pck is the official windows_release_x86_64 export
template (~109 MB, vs ~178 MB for a copy of the editor exe). It is fetched
once via tools/fetch_template.py, which pulls JUST that member out of the
~1 GB export-templates .tpz with HTTP range requests (a ~38 MB transfer) and
caches it in build/templates/. If the fetch fails (offline build machine),
the script falls back to copying the editor exe so a build always succeeds.

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
# Cached player runtime (fetched once by tools/fetch_template.py) and the
# system-wide install location Godot's editor would put templates in.
TEMPLATE_CACHE = REPO / "build" / "templates" / "windows_release_x86_64.exe"
TEMPLATE_INSTALLED = (
    Path(os.environ.get("APPDATA", ""))
    / "Godot" / "export_templates" / "4.7.stable" / "windows_release_x86_64.exe"
)
ICON_ICO = REPO / "build" / "icons" / "motionfit.ico"


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
    """Places the player runtime at game/MotionFit.exe (it auto-loads the
    same-named MotionFit.pck beside it).

    Preference order: the official release export template (installed copy,
    then our cached ranged-download), falling back to a copy of the editor exe
    (~70 MB bigger, but always available) so an offline machine still builds.
    """
    step("Placing the Godot runtime at game/MotionFit.exe")
    runtime: Path | None = None
    for candidate in (TEMPLATE_INSTALLED, TEMPLATE_CACHE):
        if candidate.exists():
            runtime = candidate
            break
    if runtime is None:
        try:
            sys.path.insert(0, str(REPO / "tools"))
            import fetch_template

            runtime = fetch_template.fetch_member(
                fetch_template.TPZ_URL, fetch_template.MEMBER, TEMPLATE_CACHE
            )
        except Exception as exc:  # noqa: BLE001 - any network failure
            print(f"  template fetch failed ({exc}); falling back to the editor exe")
            runtime = None
    if runtime is not None:
        print(f"  using release template: {runtime}")
        shutil.copy2(runtime, OUT / "game" / "MotionFit.exe")
    else:
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
    # Swap the fat GUI/contrib OpenCV that mediapipe drags in for the headless
    # build (~70 MB smaller; the shipped service never opens a window - the
    # --window debug flag downgrades gracefully, see pose_server.py). Also drop
    # matplotlib + pillow: mediapipe only imports matplotlib for an unused
    # plotting helper, which pose_server stubs out before `import mediapipe`.
    run(
        [
            venv_python(), "-m", "pip", "uninstall", "-y",
            "opencv-contrib-python", "opencv-python", "matplotlib", "pillow",
        ]
    )
    # --force-reinstall (--no-deps to leave numpy alone): opencv-python and the
    # headless build share the same cv2/ files, so the uninstall above deletes
    # them. On a reused venv pip still sees leftover headless *metadata* and would
    # no-op a plain install, shipping a service that can't `import cv2`. Forcing
    # the reinstall rewrites cv2/ every build.
    run([
        venv_python(), "-m", "pip", "install", "--force-reinstall", "--no-deps",
        "opencv-python-headless>=4.8",
    ])


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
        # Never used at runtime (matplotlib is stubbed in pose_server.py);
        # excluding keeps stray imports from sweeping them back in.
        "--exclude-module", "matplotlib",
        "--exclude-module", "PIL",
        "--exclude-module", "tkinter",
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


def prune_pose_server() -> None:
    """Removes bundle payload the pose service never loads.

    - cv2's ffmpeg dll (30 MB): only backs file/stream decoding; the webcam
      capture path uses the MSMF/DSHOW backends built into cv2 itself.
    - tcl/tk data dirs, if the tkinter exclude left any behind.
    Do NOT prune mediapipe/tasks/c: since mediapipe ~0.10.3x the Python
    pose landmarker loads libmediapipe.dll through those C bindings — without
    it the service dies at startup ("No module named 'mediapipe.tasks.c'").
    verify_pose_server() below guards against this class of mistake.
    """
    step("Pruning unused payload from pose_server/")
    internal = OUT / "pose_server" / "_internal"
    doomed: list[Path] = [
        internal / "_tcl_data",
        internal / "_tk_data",
    ]
    doomed += list((internal / "cv2").glob("opencv_videoio_ffmpeg*.dll"))
    reclaimed = 0
    for path in doomed:
        if not path.exists():
            continue
        if path.is_dir():
            reclaimed += sum(f.stat().st_size for f in path.rglob("*") if f.is_file())
            _rmtree_retry(path)
        else:
            reclaimed += path.stat().st_size
            path.unlink()
    print(f"  reclaimed {reclaimed / 1e6:.0f} MB")


def verify_pose_server() -> None:
    """Smoke-tests the bundled service: spawn it in --game mode and require a
    status heartbeat on UDP 9990 within 40 s. Catches missing-module/pruned-dll
    breakage at build time instead of on a friend's machine."""
    step("Verifying pose_server.exe heartbeats")
    import json
    import socket

    exe = OUT / "pose_server" / "pose_server.exe"
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.bind(("127.0.0.1", 9990))
    except OSError:
        sock.close()
        print("  port 9990 is busy (a pose service is already running?) - skipping")
        return
    sock.settimeout(1.0)
    proc = subprocess.Popen(
        [str(exe), "--game"],
        cwd=str(exe.parent),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    ok = False
    try:
        deadline = time.time() + 40
        while time.time() < deadline:
            if proc.poll() is not None:
                out = (proc.stdout.read() or b"").decode(errors="replace")
                sys.exit(
                    "pose_server.exe exited at startup (code "
                    f"{proc.returncode}):\n{out[-2000:]}"
                )
            try:
                data, _ = sock.recvfrom(65536)
            except socket.timeout:
                continue
            packet = json.loads(data.decode())
            print(f"  heartbeat OK (status={packet.get('status')!r})")
            ok = True
            break
    finally:
        subprocess.run(
            ["taskkill", "/PID", str(proc.pid), "/T", "/F"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        sock.close()
    if not ok:
        sys.exit("pose_server.exe produced no UDP heartbeat within 40 s")


def ensure_icon() -> None:
    """Renders icon.svg to build/icons/motionfit.ico (launcher + installer icon)."""
    step("Building the app icon")
    if ICON_ICO.exists():
        print(f"  using cached {ICON_ICO}")
        return
    project_godot = REPO / "project.godot"
    before = project_godot.read_bytes()
    try:
        run([GODOT, "--headless", "--path", REPO, "-s", "res://tools/render_icon.gd"])
    finally:
        if project_godot.read_bytes() != before:
            project_godot.write_bytes(before)
    run([sys.executable, REPO / "tools" / "make_ico.py", ICON_ICO])


def build_launcher() -> None:
    step("Building the MotionFit.exe launcher")
    cmd = [
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
    ]
    if ICON_ICO.exists():
        cmd += ["--icon", ICON_ICO]
    cmd.append(REPO / "tools" / "launcher.py")
    run(cmd)


def find_iscc() -> Path | None:
    candidates = [
        Path(os.environ.get("LOCALAPPDATA", "")) / "Programs" / "Inno Setup 6" / "ISCC.exe",
        Path(r"C:\Program Files (x86)\Inno Setup 6\ISCC.exe"),
    ]
    found = shutil.which("ISCC")
    if found:
        return Path(found)
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return None


def build_installer() -> None:
    step("Compiling MotionFit-Setup.exe (Inno Setup)")
    iscc = find_iscc()
    if iscc is None:
        print(
            "Inno Setup not found - skipping the installer.\n"
            "Install it with:  winget install -e --id JRSoftware.InnoSetup --scope user\n"
            "The plain release folder above is still complete and shippable."
        )
        return
    run(
        [
            iscc,
            f"/DSourceDir={OUT}",
            f"/O{REPO / 'build'}",
            REPO / "tools" / "installer.iss",
        ]
    )
    setup = REPO / "build" / "MotionFit-Setup.exe"
    print(f"installer: {setup}  ({setup.stat().st_size / 1e6:.0f} MB)")


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
    print(
        "Share build\\MotionFit-Setup.exe with friends (or zip the MotionFit "
        "folder)."
    )


def main() -> None:
    clean_output()
    export_pck()
    copy_runtime()
    ensure_venv()
    build_pose_server()
    prune_pose_server()
    verify_pose_server()
    ensure_icon()
    build_launcher()
    write_readme()
    build_installer()
    summary()


if __name__ == "__main__":
    main()
