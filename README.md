# MotionFit

> **MOVE · PLAY · LEVEL UP**

MotionFit is a **motion-controlled fitness gaming platform** built in **Godot 4.7**.
It is not a single game — it's a launcher that hosts many short, body-controlled
mini-games that all share the same underlying systems (profile, calories, heart
rate, XP, achievements, settings, audio, saves). Think *Wii Sports / Mario Party
for fitness*: pick a game, play a session using your body (captured by a camera +
a Python AI pipeline), and earn progress that persists across every game.

The engine is a thin client: **all computer-vision / ML logic lives in Python**,
and Godot only receives processed movement data over a local socket.

---

## Features so far

- **Platform shell** — main menu, game select, loading/countdown/results flow,
  pause menu, first-run profile onboarding.
- **Player profile** — physical attributes that feed calorie estimation, plus
  lifetime progression (calories, steps, active minutes, workouts).
- **Fitness dashboard** — today's calories vs. goal, streak, weekly totals and a
  7-day calorie bar chart, all derived from a single daily-activity log.
- **Settings** — master / music / SFX volume, applied and persisted live.
- **Open-world** mini-game as the first playable, driven by real motion input.
- **Motion input pipeline** — webcam → Python MediaPipe pose → UDP → in-game
  character movement.
- **Shared managers** — Save, Audio, Scene, Settings, Profile, Activity, Game and
  Motion, each owning exactly one concern.

See [`CONTEXT.md`](CONTEXT.md) for the full architecture and conventions — it is
the single source of truth for the project.

---

## Project layout

```
addons/     Editor plugins (godot_mcp).
assets/     Art & media (audio, fonts, sprites, ui themes, shaders).
data/       Bundled default/template data (runtime saves live in user://).
python/     The AI pipeline (separate process): pose, heart_rate, calories.
scenes/     Godot scenes — menus/ (shared UI & flow) and per-game folders.
scripts/    GDScript — managers/ (shared systems), ui/, utilities/.
tools/      Home-grown headless dev tools (screenshots, error checks).
datasets/   Raw training videos — NOT committed (see below).
```

---

## Running the game

1. Install **Godot 4.7** (Forward+).
2. Open the project (`project.godot`) in the Godot editor and press **Play**, or
   from the command line:
   ```bash
   godot --path . 
   ```
   The game targets desktop at 1920×1080.

## Motion input (optional, for body control)

The camera/AI side runs as a separate Python process that streams pose data to
the game.

1. Install deps: `pip install -r python/requirements.txt`
2. Download the MediaPipe pose model into `python/pose/models/`:
   [`pose_landmarker_full.task`](https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_full/float16/latest/pose_landmarker_full.task)
   (git-ignored — it's a redistributable binary, not source).
3. Start the pose server: `python python/pose/pose_server.py`

The game reads the resulting movement without a webcam attached too — see the
project notes for how to feed it recorded input.

---

## Dev tools

Small headless helpers under [`tools/`](tools/) that talk to the in-engine bridge
so you get screenshots and error checks from the shell without a live editor:

```bash
tools/shot.sh menu                                 # screenshot a scene -> tools/shots/
tools/shot.sh settings res://scenes/menus/settings_menu.tscn
tools/check.sh res://scenes/menus/settings_menu.tscn   # headless parse/error check
```

PowerShell wrappers (`tools/shot.ps1`, `tools/check.ps1`) are provided for the
primary dev machine. See [`tools/README.md`](tools/README.md) for details.

---

## What isn't in the repo

Large, non-source ML artifacts are intentionally git-ignored and must be
downloaded or regenerated locally:

- `datasets/` — raw exercise videos used to train the pose classifiers.
- `python/pose/models/*.task` — the MediaPipe pose model (download link above).
- `python/pose/recordings/` — captured landmark streams from `recording.py`.
