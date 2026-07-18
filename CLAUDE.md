# MotionFit — Claude Code guide

Motion-controlled **fitness gaming platform** (Wii-Sports-for-fitness): a launcher
hosting many small mini-games that share Profile / XP / Calories / Heart-Rate /
Achievements / Audio / Save systems. Built to scale to 20+ games.

- **Engine:** Godot **4.7**, Forward+, target Desktop 1920×1080.
- **Godot exe:** `C:\Users\aliba\OneDrive\Desktop\Godot_v4.7-stable_win64.exe`
  (bash path `/c/Users/aliba/OneDrive/Desktop/Godot_v4.7-stable_win64.exe`).
- **Source of truth:** `CONTEXT.md` (architecture, conventions, decisions). Consult
  it before designing anything cross-cutting; keep it updated when architecture changes.

## Layout
- `scenes/` — one folder per game: `runner` (Zombie Run), `sprint` (Hurdle Dash),
  `boxing`, `football`, `tennis`, `open-world`, plus `menus`, `ui`, `shared`, `tests`.
- `scripts/` — `managers/` (autoloads: game_manager, profile_manager, scene_manager,
  motion_manager, character_factory, achievement_manager…) and `ui/`.
- `python/` — MediaPipe pose pipeline (`pose/pose_server.py`, UDP :9990) + heart rate.
- `assets/models/generated_human/export_glb.py` — procedural character GLB generator.
- `tools/` — dev scripts (see below). `addons/godot_mcp` — MCP autoloads.

## Dev workflow (prefer skills)
- **`/check` [scene]** — headless parse/error check of the project (`tools/check.sh`).
  Exit 0 = clean, 1 = errors. Run after editing `.gd`.
- **`/shot <name> [scene]`** — screenshot a scene to `tools/shots/` (`tools/shot.sh`).
- **`/glb`** — generate a character GLB via `export_glb.py`.
- **`/build`** — one-command shippable exe via `tools/build_release.py`.

Raw equivalents if a skill isn't loaded:
`bash tools/check.sh res://scenes/<game>/<scene>.tscn` ·
`WAIT=8 bash tools/shot.sh <name> res://scenes/<game>/<scene>.tscn`.
PowerShell wrappers: `tools/check.ps1`, `tools/shot.ps1`.

## Conventions / gotchas
- **No religious imagery** anywhere in art or copy.
- **No Claude attribution** in commits; never push `claude/*` branches to the remote.
- Token-frugal file access: search + read slices, avoid whole-file reads.
- Rich background lives in the memory notes — see `MEMORY.md` (motion pipeline,
  async scene loading, per-game notes, release build, godot-mcp quirks).
