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
  - `scenes/menus/` one `.tscn` per screen · `scenes/ui/` in-game overlays ·
    `scenes/ui/components/` reusable widgets (stat_tile, form_row, meter_bar,
    camera_mirror, game_card, …).
- `scripts/` — `managers/` (autoloads: game_manager, profile_manager, scene_manager,
  motion_manager, character_factory, achievement_manager…), `ui/` (one per screen)
  and `ui/components/`, `data/` (typed data: `GameDef`, `AchievementDef`/`Set`,
  `GameResult`), `utilities/` (base classes + static helpers like
  `CharacterFactory`).
- **Games are discovered, not listed.** Each game folder holds a `game.tres`
  (`GameDef`) that GameManager finds by scanning `scenes/*/`, and may hold an
  `achievements.gd` contributing its own achievements. Adding a game means adding
  a folder — never editing GameManager, SceneManager, or any menu. See
  CONTEXT.md §5/§13.
- **UI is authored in `.tscn`, not built in `_ready()`** — see CONTEXT.md §4.1/§4.2
  for the rule, the component catalogue and the theme variations
  (`CornerButton`, `CardButton`, `TabButton`, …). Build in code only what is
  genuinely per-item (one card per profile / game / achievement).
- `python/` — MediaPipe pose pipeline (`pose/pose_server.py`, UDP :9990) + heart rate.
- `assets/models/generated_human/export_glb.py` — procedural character GLB generator.
- `tools/` — dev scripts (see below). `addons/godot_mcp` — MCP autoloads.

## Dev workflow (prefer skills)
- **`/check` [scene]** — headless parse/error check of the project (`tools/check.sh`).
  Exit 0 = clean, 1 = errors. Run after editing `.gd`.
- **`bash tools/test.sh` [suite]** — headless assertion suite for the shared
  platform layer (save, profile/XP, registry, achievements). Exit 0 = pass.
  Run after touching anything in `scripts/managers/` or `mini_game.gd`.
  check.sh proves it *parses*; test.sh proves it *behaves*. See CONTEXT.md §10a.
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
