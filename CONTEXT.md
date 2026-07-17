# MotionFit — Project Context & Architecture

> **This document is the single source of truth for the whole project.**
> Update it whenever an architectural decision is made, a system is added, or a
> convention changes. If code and this document disagree, treat it as a bug in
> one of them and reconcile.

Working title: **MotionFit** (project `config/name`, window title).
Engine: **Godot 4.7** · Renderer: **Forward+** · Target: **Desktop, 1920×1080**.

---

## 1. Project Vision

MotionFit is **not a single game**. It is a **fitness gaming platform / launcher**
that hosts many small motion-controlled mini-games which all share the same
underlying systems.

Think **Wii Sports / Mario Party for fitness**: the player opens the app, picks a
game, plays a short session using body movement (captured by a camera + Python
AI pipeline), then earns XP, calories, and achievements that persist across
every game.

Planned games: Infinite Runner, Boxing, Football, Tennis, Dance, Reflex games,
and more — the architecture must scale to **20+ games** without rework.

Every game reuses the same shared systems:
Player Profile · AI Camera Input · Calories · Heart Rate · XP · Achievements ·
Settings · Audio · Save System.

---

## 2. Design Philosophy

1. **Platform first, games second.** Shared systems are the product; individual
   games are content plugged into them.
2. **Data-driven over hardcoded.** Adding a game should mean adding *data* (a
   registry entry) + a self-contained scene — never editing menu or flow code.
3. **One responsibility per unit.** Each manager owns exactly one concern; each
   function does one thing.
4. **Godot is a thin client for AI.** All computer-vision / ML logic lives in
   **Python**. Godot only *receives processed data*. (See §9.)
5. **Scalability over speed.** When two implementations are possible, choose the
   one that still works at 20+ games. Document the reasoning here.
6. **No technical debt on purpose.** If a shortcut is taken, record it in the
   TODO list (§12) with a note on how to remove it.

---

## 3. Folder Structure

```
addons/            Third-party / editor plugins (godot_mcp lives here).
assets/            All art & media, grouped by type.
	audio/         Music and SFX.
	fonts/
	icons/
	sprites/
	ui/            UI textures, themes, nine-patches.
	animations/
	shaders/
data/
	saves/         Bundled DEFAULT/template data only. Runtime saves go to
				   user:// (see §8) because res:// is read-only when exported.
python/            Python side of the AI pipeline (runs as a separate process).
	pose/          Pose detection / gesture recognition.
	heart_rate/    Heart-rate estimation.
	calories/      Calorie estimation.
scenes/
	menus/         Shared UI/flow scenes (main menu, game select, settings,
				   pause, results, loading, countdown).
	runner/        Infinite Runner game (scene + its own gameplay script).
	boxing/        (planned)
	football/      (planned)
	tennis/        (planned)
	shared/        Reusable scene fragments used by multiple games (HUD widgets,
				   overlays, common props).
	ui/            Reusable UI component scenes (buttons, cards, meters).
scripts/
	managers/      Autoload singletons (see §5). One file per manager.
	player/        Player representation, avatars, input mapping (future).
	ui/            Controller scripts for the shared UI scenes in scenes/menus.
	utilities/     Cross-cutting helpers and base classes (e.g. MiniGame).
```

### Where does game code live? (convention)
- **Shared / platform code** → `scripts/` (managers, ui controllers, utilities).
- **Game-specific gameplay code** → co-located with its scene under
  `scenes/<game>/` (e.g. `scenes/runner/runner.gd`).

Rationale: platform code is referenced from everywhere and benefits from a flat,
predictable `scripts/` home; game code is only used by its own scene, so keeping
it beside the scene makes a game a self-contained, deletable/movable unit — which
is exactly what a 20-game platform needs.

---

## 4. Naming Conventions

| Thing                     | Convention          | Example                     |
|---------------------------|---------------------|-----------------------------|
| Classes / `class_name`    | PascalCase          | `MiniGame`, `SceneManager`  |
| Autoload singleton names  | PascalCase          | `GameManager`               |
| Files (scripts)           | snake_case.gd       | `game_manager.gd`           |
| Files (scenes)            | snake_case.tscn     | `main_menu.tscn`            |
| Functions & variables     | snake_case          | `add_xp`, `_current_game_id`|
| Private members           | `_leading_underscore`| `_settings`                |
| Constants / enums         | UPPER_SNAKE / PascalEnum | `BASE_XP_PER_LEVEL`, `Difficulty.EASY` |
| Signals                   | snake_case, past-tense verb | `game_finished`, `leveled_up` |
| Node names (in scenes)    | PascalCase          | `PlayButton`, `CardContainer` |
| Registry / save keys      | snake_case strings  | `"game_id"`, `"xp"`         |

---

## 5. Managers (Autoload Singletons)

All managers are registered as autoloads in `project.godot`. **Order matters** —
autoloads initialise top-to-bottom, so a manager must appear *after* the managers
it uses in `_ready()`.

Initialisation order (and dependencies):

| # | Autoload        | Depends on (at init)      | Responsibility |
|---|-----------------|---------------------------|----------------|
| — | MCP*Bridge ×3   | —                         | godot_mcp tooling (leave untouched). |
| 1 | `SaveManager`   | —                         | Only system that touches disk. JSON read/write to `user://saves`. |
| 2 | `SceneManager`  | —                         | Owns **every** scene path; the only place scene transitions happen. |
| — | `MotionManager` | —                         | Receives body-movement data from the Python pose service over UDP; exposes `get_forward()`/`get_turn()`. The AI-input boundary (§9). |
| — | `CameraPreview` | —                         | Receives the webcam **preview image** from the pose service over a second UDP port (9991) and exposes it as a `Texture2D` for the setup/countdown screen. Still §9-clean: Python owns the camera; Godot only blits the pixels, never inspects them. |
| 3 | `AudioManager`  | —                         | Music/SFX playback and audio bus volumes. `play_sfx(stream, volume_db, pitch, from_position)` hands out one of a **pool** of voices (so effects layer instead of cutting each other) and returns the player; `fade_out_sfx()` retires a long one-shot early. |
| 4 | `SettingsManager`| SaveManager, AudioManager| User prefs (volumes, fullscreen); loads, applies, persists them. |
| 5 | `ProfileManager`| SaveManager               | Player profile: XP/level, calories, achievements, per-game stats, character appearance. |
| — | `CharacterFactory` | ProfileManager (at call time, not init) | Personalised character model: runs the Python generator (`assets/models/generated_human/export_glb.py`) with the active profile's body attributes + appearance, caches the GLB per profile under `user://characters/`, loads it at runtime via `GLTFDocument`. Falls back to the bundled `human.glb`. Body shape is always derived from weight/height/age/sex — never chosen directly. |
| 6 | `GameManager`   | SceneManager, ProfileManager | Game registry + session state + play flow + awards progression. |
| 7 | `ActivityManager`| SaveManager, GameManager | Day-by-day fitness history (time series). Listens to `game_finished`, rolls each session into today's bucket; derives weekly totals/averages/streaks on read (never stores them). Feeds the Fitness dashboard. |

**Rules**
- Use managers instead of loose global variables.
- Managers communicate downward (later → earlier) or via **signals** upward.
  Never create a circular `_ready()` dependency.
- A game/scene talks to managers, **never** directly to another game.

### SceneManager — the path authority
- Holds a `const` for every scene path (UI scenes **and** game scenes).
- Exposes `change_scene(path)` plus named loaders (`load_main_menu()`, …).
- Every `change_scene` dips through a short black **fade** (out `0.16 s` → swap →
  in `0.24 s`) on a high CanvasLayer owned by SceneManager, so screens hand over
  smoothly app-wide with zero per-screen wiring. Calls made while a fade is
  running are ignored (button-mash guard); the fade tweens are pause-immune so a
  paused tree can't wedge the transition. `change_scene` is now `void`/async —
  the swap lands a fade later, which no caller depended on.
- **No other file may contain a `res://….tscn` literal or call
  `get_tree().change_scene_*` directly.** Games are launched generically from a
  path stored in the GameManager registry, which itself references SceneManager
  constants.

### GameManager — the registry
- `_games` is an `Array[Dictionary]`; each entry:
  `{ id, title, description, scene, available }`.
- `available:false` renders as a disabled "Coming Soon" card and cannot start.
- **Adding a game = adding one dictionary entry** (see §13).
- Owns session state: selected game, difficulty (`EASY/NORMAL/HARD`), last result.
- `finish_game(result)` records progression via ProfileManager, then routes to
  the results screen.

---

## 6. The MiniGame Contract (`scripts/utilities/mini_game.gd`)

Every game's root node extends `MiniGame`. This is what lets any game plug into
the shared countdown → play → results → XP pipeline.

- `begin()` — platform starts the game (called after the countdown).
- `_prepare_world()` — override for setup that must be VISIBLE during the intro
  (runs in `_ready`, before the countdown freezes the scene) — e.g. standing the
  player at their spawn point so the count reveals them ready. Gameplay start
  belongs in `_start_game()`, not here.
- `_start_game()` — override for game-specific setup (runs after the countdown).
- `add_score(points)` / `get_score()` / `get_elapsed_sec()`.
- `get_difficulty()` — reads the launcher's chosen difficulty.
- `get_game_id()` — override to return the registry id (e.g. `"runner"`).
- `finish(calories)` — builds the standard **GameResult** and hands it to
  GameManager.

### GameResult schema (the contract between a game and the platform)
```gdscript
{
	"game_id":      String,   # registry id, e.g. "runner"
	"score":        int,      # game-defined points
	"duration_sec": float,    # seconds played
	"calories":     float,    # from the calorie system (0.0 until Python is wired)
	"xp_earned":    int,      # computed by MiniGame from score
}
```
Because every game emits this exact shape, the results screen, profile stats, and
XP maths are written **once** and work for all games.

---

## 7. Scene Architecture & Game Flow

```
Application launch
   ↓
Main Menu ── Settings
   ↓ (Play)
Game Select   ← builds cards from GameManager registry (data-driven)
   ↓ (pick a game)
Difficulty    ← intensity picker (EASY/NORMAL/HARD); only for games whose
			   registry entry has uses_difficulty:true — free-roam games
			   (Open World) skip straight to the intro
   ↓
Game scene loads (a MiniGame), frozen on its first frame
   ↓
Game Intro    ← overlay the MiniGame base shows before play (shared by all games):
				Setup (live webcam mirror; raise both hands to start) → 3·2·1·Go
				over the game's translucent first frame → begin()
   ↓
Game plays
   ↓ finish(result)
Results        ← shows GameResult; awards XP + calories + stats
   ↓
back to Game Select
```

**Get-into-position intro (setup + countdown).** Because every game is played
with the body, the moment before play is where the player frames themselves in
the camera and signals ready. `GameManager.start_selected_game()` loads the game
scene **directly** (setting an `intro_pending` flag); the `MiniGame` base, in
`_ready()`, freezes the world on its first frame and shows a reusable `GameIntro`
overlay (`scripts/ui/game_intro.gd`) on top. Phase 1 **Setup**: a live mirror of
the webcam (from `CameraPreview`) fills the screen; holding the *ready gesture*
(both hands above the head, detected in Python — see §9) for ~1 s starts the
count (or press Space, so it works with no camera). Phase 2 **Countdown**: the
mirror shrinks to a corner thumbnail, the dim fades to translucent to reveal the
real game behind it, and 3·2·1·Go plays; then `begin()` runs. Because the count
reveals the actual (frozen) game, `MiniGame._ready` calls `_prepare_world()`
*before* freezing, so a game can pose its world play-ready for the reveal (the
Open World stands the player at its spawn point and frames the camera there — see
§9). A game scene opened directly (e.g. from the editor) skips the intro and just
plays. Adding a game needs **no intro code** — the base handles it. (The old
standalone `countdown_screen` scene is superseded by this overlay.)

Shared scenes live in `scenes/menus/`:
`main_menu`, `game_select`, `settings_menu`, `pause_menu`, `results_screen`,
`loading_screen`, `countdown_screen`.

**Pause** is a reusable overlay (`PauseMenu`) a game instances; it sets
`get_tree().paused` and processes while paused.

UI controller scripts live in `scripts/ui/` and use `%UniqueName` node access so
scene restructuring rarely breaks code.

---

## 8. Save System

- `SaveManager` is the **only** file-I/O system. Format is JSON.
- Runtime saves live in `user://saves/` (writable in exported builds).
- `data/saves/` in the project tree is for **bundled defaults/templates** only.
- Current save files:
  - `profile.json`  — owned by ProfileManager.
  - `settings.json` — owned by SettingsManager.
  - `activity.json` — owned by ActivityManager. A `days` map keyed by ISO date
	(`"YYYY-MM-DD"` → `{calories, active_sec, steps, xp, sessions}`) plus a
	`daily_calorie_goal`. The daily rows are the source of truth; weekly/average/
	streak figures are computed on read, never stored. Local JSON is the right
	store here (single-user, offline, ~365 tiny rows/year) — no DB/cloud needed
	unless cross-device sync is ever required.
- Missing keys are backfilled from a manager's `DEFAULTS`/`_default_*()` so old
  saves survive new fields. Never assume a loaded save has every key.

---

## 9. Python AI Pipeline (movement input — IMPLEMENTED)

Godot communicates with a separate **Python** process that does all computer
vision. **Hard rule: Godot contains NO AI logic** — it only receives processed
data.

**Transport:** UDP on `127.0.0.1:9990` (latest-packet-wins, ideal for realtime
pose). Python is the sender; Godot's `MotionManager` binds and reads.
`MotionManager.PORT` and `pose_server.py`'s `UDP_PORT` must match.

**Packet schema (Python → Godot), newline-free JSON per datagram:**
```json
{ "forward": 0.0, "turn": 0.0, "jump": false, "crouch": 0.0, "duck": 0.0,
  "hands_up": false,
  "walking": false, "detected": true, "steps": 0, "cadence": 0.0, "met": 1.2,
  "hr": 0.0, "status": "ready", "ready_hint": "", "ts": 0.0 }
```
- `forward` 0..1  — marching-in-place intensity (drives forward speed).
- `turn` -1..1   — torso lean (drives turning).
- `jump` bool    — true on the single frame a vertical leap launches (edge event).
- `crouch` 0..1  — squat depth (0 = upright), from the planted foot folding up.
  Suppressed while marching (`CROUCH_FORWARD_GATE`), so it is NOT reachable
  mid-run — that's what `duck` is for.
- `duck` 0..1    — forward bow of the torso ("lean down"), from world-landmark
  torso pitch. Legs play no part, so it stays live while running in place — the
  runner's slide reads `max(duck, crouch)`. `MotionManager.get_duck()`.
- `hands_up` bool — the **"ready" gesture**: both wrists raised above the head.
  The setup screen (§7) times how long it's held to start the countdown; exposed
  as `MotionManager.is_hands_up()`. Checked independently of the marching stance,
  so you can signal ready before getting into position.
- `steps` int / `cadence` float — cumulative steps and current pace (steps/min).
- `met` float    — effort as a metabolic equivalent (body-mass-independent).
  Godot turns this into calories via `ProfileManager` weight × time; MET is used
  precisely so Python needs no player data. ~1.2 still, ~4-5 march, ~8+ vigorous.
- `hr` float     — heart rate bpm from a wearable, `0` = none (motion fallback).
- `status` string — service/camera state so Godot can show the right loading /
  permission UI even when no pose is streaming: `ready` (camera on, tracking),
  `idle` (camera off, e.g. in menus), `opening` (warming up), `error` (the webcam
  couldn't open — in use or access blocked). Sent as a ~10 Hz heartbeat while the
  camera is off so `MotionManager.is_receiving()` stays true; exposed as
  `get_status()` / `is_camera_ready()` / `is_camera_error()`.
- `ready_hint` string — the setup screen's coaching line: a short instruction to
  reach a valid, trackable stance (`STEP INTO VIEW`, `SHOW YOUR LEGS`, `STAND
  UPRIGHT`, `STAND UP`, `GET CLOSER`, `STEP BACK`, `STEP BACK — SHOW YOUR FEET`),
  or `""` once the player is fully framed and ready. Comes from `_assess_pose`,
  which now also checks apparent distance (torso size in frame) and feet framing.
  Exposed as `MotionManager.get_ready_hint()` / `is_pose_ready()`; `GameIntro`
  gates the "raise your hands to start" hold on it, so the camera is verified
  ready — standing, legs in view, good distance — before any game begins.

**Camera control channel (Godot → Python), UDP port 9992:** the one channel that
flows *back* to Python (everything else streams out). Godot's `MotionManager`
sends tiny JSON commands `{"cmd": "camera_on"}` / `{"cmd": "camera_off"}` so the
webcam is powered on **only while you're playing** — the LED stays dark in menus
(the user found an always-on camera off-putting). The camera turns on when a
game's setup screen appears (`GameIntro._ready` → `camera_on()`) and off on the
next scene change (`MotionManager` hooks `SceneManager.scene_changing`), which
covers every menu/results/pause-quit exit with no per-screen wiring. Commands are
idempotent and re-asserted as a ~1 Hz keepalive, so a dropped datagram — or a
pose service that started after Godot — still converges. **Honoured only when the
pose service runs in `--game` (managed) mode**; run standalone it opens the camera
immediately and ignores commands, so testing the pose service alone isn't
disrupted. Windows can't be *prompted* for camera permission programmatically, so
"ask for permission" is: a blocked/in-use camera reports `status:"error"` and the
UI (setup screen + main-menu banner) points the player at Windows Settings ▸
Privacy ▸ Camera, noting they can still play keyboard-only.

**Webcam preview stream (Python → Godot), separate UDP port 9991:** so the
setup/countdown screen can show the player a live mirror of themselves, the pose
service also ships a small downscaled JPEG of each frame (~15 fps) on a *second*
port — kept off the control port so a fat image never delays a control datagram.
`CameraPreview` (autoload, §5) decodes it to a `Texture2D`. This is still §9-clean:
Python owns the camera and only sends pixels; Godot blits the texture and never
runs vision on it. Disable with `pose_server.py --no-preview`. Cosmetic and lossy
by design — with no service running the texture is null and the UI falls back to a
"start the camera / press Space" prompt.

**Files:**
- `python/pose/pose_server.py` — webcam + MediaPipe Pose → computes forward/turn
  → UDP. Run it alone (no `--game`) to test: it shows the OpenCV preview window
  (press `q` to quit) and opens the camera immediately. `run.bat` passes `--game`
  (managed mode): **no** preview window and the camera is switched on/off by Godot
  over port 9992 (see the camera control channel above), so a camera-open failure
  reports `status:"error"` instead of exiting. `python/requirements.txt` lists
  deps (opencv-python, mediapipe). CLI flags: `--game` (managed) / `--window`
  (force the window in managed mode for debugging), `--record [PATH]`,
  `--metronome BPM` / `--no-beep`, `--heart-rate` / `--hr-address`, `--camera N`,
  `--model lite|full|heavy` (pose model size; auto-downloads on first use — pick
  `lite` if the HUD's fps readout is low). Capture runs on its own thread
  (latest-frame-wins) so inference never waits on the camera; short tracking
  losses are coasted through a grace window instead of resetting the filters.
- `python/pose/recording.py` — recording-harness support (stdlib only): JSONL
  `Recorder`, `Metronome`, the number-key→move label map, and the shared feature
  schema (`build_feature_row` / `FEATURE_NAMES`) used by both the logger and the
  trainer, so there's no train/serve skew.
- `python/pose/label_tool.py` — post-hoc labeller. Replays a `--record` JSONL as
  the tracked skeleton and lets you mark move labels onto time-ranges *after*
  recording (so you don't type while exercising), writing `<name>.labeled.jsonl`
  for the trainer. Scrub/play, `i`/`o` span marks, number keys to label.
- `python/pose/video_to_features.py` — bootstraps training data from public
  exercise-video datasets (e.g. Kaggle) with no self-recording: runs folder-per-
  label clips through the SAME MediaPipe + `_compute_controls` pipeline the live
  server uses (no train/serve skew) and writes per-label JSONL in the shared
  schema. Skips the marching-stance gate by default so squats/jacks aren't
  rejected. NB public sets lack the in-place cardio moves (march/high-knees/jog).
- `python/pose/train_classifier.py` — offline move classifier. Trains + evaluates
  a RandomForest on labelled JSONL (windowed features for periodic moves),
  saves to `python/pose/models/move_classifier.joblib`. Deps in
  `python/requirements-train.txt` (numpy, scikit-learn, joblib).
- `python/heart_rate/ble_heart_rate.py` — optional BLE heart-rate reader
  (standard GATT Heart Rate Service 0x180D, device-agnostic). Runs on a daemon
  thread; feeds real bpm into the packet's `hr` field. Deps in
  `python/requirements-hr.txt` (bleak). Runs standalone (`--scan`) too.
- `scripts/managers/camera_preview.gd` — `CameraPreview` autoload. Binds UDP 9991,
  decodes the latest preview JPEG to an `ImageTexture`, exposes `get_texture()` /
  `is_streaming()`. Consumed by the `GameIntro` setup screen (§7).
- `scripts/managers/motion_manager.gd` — `MotionManager` autoload. Exposes
  `get_forward()`, `get_turn()`, `is_walking()`, `get_crouch()`,
  `is_crouching()`, `get_duck()`, `is_ducking()`, `consume_jump()`,
  `is_hands_up()`, `is_receiving()`,
  `is_hr_connected()`, the camera-control API `camera_on()` / `camera_off()` and
  state readouts `get_status()` / `is_camera_ready()` / `is_camera_error()`, and
  the `motion_updated` / `jumped` / `crouch_changed` signals. `get_forward()` /
  `get_turn()` / `get_crouch()` are time-smoothed (`SMOOTH_TIME`) so ~20-30 Hz
  packets drive 60+ fps games without stair-stepping (`get_forward_raw()` etc.
  give the exact packet values). If the service isn't running, values stay 0 and
  nothing breaks (values also ease to 0 after `TIMEOUT_SEC`).
- `scenes/open-world/` — the **Open World game** (registered in GameManager,
  `available:true`): a free-roam "vibing" mode with no fail state. Its root
  (`open_world.gd`) `extends MiniGame`, so it plugs into the normal
  countdown → play → results pipeline; a `CharacterBody3D` (`player.gd`) reads
  `MotionManager` (march → walk/run on a curved speed ramp, lean → turn,
  leap → jump), with a spring-arm follow camera and a lit, fogged sky (see the
  feel & atmosphere pass below).
  The world is a **sculpted HTerrain heightmap** (`addons/zylann.hterrain`,
  data in `Terrain/`, grass/stone/iced-stone splat textures) — real hills and
  valleys to roam. `open_world.gd` handles the terrain plumbing itself: in
  `_prepare_world()` (before the intro — §7) it stands the player at the
  `SpawnPoint` Marker3D and frames the camera behind them, so the countdown
  reveals them ready at the start line; then in `_start_game()` it waits a physics
  tick (so the terrain collider is live) and ground-snaps the player precisely
  onto the surface via a downward raycast (`_ground_y` / `_drop_player_to_ground`).
  Every orb is likewise snapped to the ground so none float or bury in a slope.
  Steps become score/XP, and six code-spawned **glow orbs** (`_spawn_orbs`) each
  award bonus score on touch and respawn 8–26 m **from the player** (not the world
  origin — on a large terrain the player is rarely at the centre) — an endless
  trail of walking goals. The stat HUD (time/calories/steps/orbs) is its own
  `OpenWorldHud` component (`open_world_hud.gd`, a code-built CanvasLayer the game
  feeds via `set_stats`); `player.gd` respawns anyone who falls below
  `FALL_RESET_Y` back to their ground-snapped spawn.
  Ending is player-driven: Esc opens the shared PauseMenu, whose "End & Save"
  (`enable_end_option()` / `end_requested`) calls `finish()`. This scene doubles
  as the proof of the motion loop. (The earlier flat box-ground sandbox and a
  separate `scenes/tests/` terrain subclass were consolidated into this one
  scene + script.)
  **Feel & atmosphere pass (2026-07-17):** the guiding rule is that pose data is
  a noisy ~20-30 Hz estimate of a human body, so nothing reads it and assigns —
  everything eases.
  *Camera* (`camera_controller.gd`): rebuilt from a world-position lerp into a
  **spring arm** — an anchor tracks the player, a yaw tracks their facing, and the
  camera hangs off that. This buys three things the lerp could not: (1) the arm is
  raycast each frame and shortened to what's actually clear, so it never renders
  from inside the heightmap (verified: forced to 40 m it clamped 329× on a run;
  at the stock 6 m it never fires on the current gentle hills — the collision is
  insurance for steeper terrain, not everyday behaviour); (2) smoothing the yaw
  instead of a world position stops the camera cutting the inside of every turn;
  (3) the anchor smooths vertically far slower than horizontally (`rise_speed` vs
  `follow_speed`) so sculpted ground doesn't shake the frame. Framing is now
  continuous off the player's `get_run_ratio()` (arm eases back + FOV 70→78), not
  a binary walk/idle toggle — the old `walking_state_changed` signal is **gone**,
  replaced by that getter plus a `landed(impact)` signal driving a landing dip.
  *Player* (`player.gd`): ground speed ramps through `ACCEL`/`DECEL` instead of
  being assigned (a march is noisy; direct assignment starts/stops like a switch);
  `floor_snap_length` is raised to 0.6 because the 0.1 default launches the capsule
  off every hummock, which drops `is_on_floor()` and stutters both the ground-align
  and the camera. The walk clip is now paced and gated on **actual** ground speed,
  not raw march intensity, or the feet slide while coasting to a halt. The visible
  model hangs off a `ModelPivot` planted at the soles (so tilt rotates about the
  feet, not the waist) that banks into turns, pitches into runs, and partially
  matches the slope (`GROUND_ALIGN` 0.65 — full alignment reads as falling over).
  All of it is presentation: the physics capsule stays upright.
  *Environment* (`open-world.tscn`): glow (the orbs were emissive but nothing
  bloomed — they now carry an OmniLight3D and `cast_shadow` OFF, since a light
  source dropping a shadow blotted the hillside), SSAO, sky ambient, height fog +
  aerial perspective, a sun disk with soft cascaded shadows, and a
  `CameraAttributesPractical` far-DOF. Orb `emission_energy_multiplier` must stay
  above `glow_hdr_threshold` (0.95) or orbs go back to being flat dots.
  **Fog border pass (2026-07-17):** the terrain is a finite 512 m square, so
  `world_border.gd` (`WorldBorder`, a node in the scene) closes it off the Black Flag
  way — the world doesn't end, it gets too thick to walk into. The boundary is a
  **square hugging the terrain's own rim**: `HALF_EXTENT` 248 caps |x| and |z|, so
  ~94% of the map stays walkable and you can reach the coast on every side. It was a
  circle first and that was wrong — a circle inscribed in a square cuts every corner
  (r=224 kept ~60% of the map and left only ~40 m between the spawn and the wall).
  **The boundary must follow the shape of the thing it bounds.** Four systems keyed
  off ONE number — `get_haze(pos)`, 0 inside `SOFT_EXTENT` (218 m) → 1 at
  `HALF_EXTENT` — so they always agree:
  (1) two nested square rings of `border_fog.gdshader` walls at ±254/±266 (three
  octaves of seamless noise, thresholded into clumps; the OUTER carries
  `floor_density` 0.8 so it genuinely occludes, the INNER is pure wisps drifting
  across it at a different rate — the parallax between them is what reads as volume).
  Rings, not cylinders: a cylinder big enough to clear the corners would stand 100 m
  out to sea at the edge midpoints, leaving the rim it exists to hide in plain view;
  (2) the WorldEnvironment's own `fog_density` ramped 0.0022 → 0.05, which is what
  actually sells it (geometry alone always looks like a thing you stand *next to*,
  never weather you are *inside*);
  (3) `limit_velocity()`, called from `player.gd` right before `move_and_slide`,
  plus `clamp_position()` right after as the guaranteed backstop;
  (4) `OpenWorldHud.set_border_warning()`'s TURN BACK prompt.
  Non-obvious things that cost real time here, all load-bearing:
  * The walls **must** out-rank the sea in `render_priority` (sea 0 → outer 1 →
	inner 2). They share a centre with the sea plane, so Godot's transparent sort
	can't order them and drew 800 m of open water straight over the bank.
  * `limit_velocity` **caps** outward speed at `room / STOP_TIME`; it must not
	*scale* it. Scaling by `(1 - haze)` each frame compounds against `player.gd`'s
	ACCEL ramp and settles at ~0.3 m/s — entering the band nailed you to the spot.
	The cap decays to an exponential glide instead. The two axes are capped
	**separately**, which is what makes corners need no special case. Verified by
	driving the maths diagonally at a corner for 60 s: converges to 247.999 on both
	axes, never crosses 248, and turning back is released untouched (8.0 of 8.0).
  * The fog/prompt start at SOFT_EXTENT but the cap only bites in the last ~16 m,
	so you are always WARNED before you are HELD.
  * A wall is ~5× wider than it is tall, so `tiles_up` is derived from the wall's
    real width (`across / width`) to keep a noise tile SQUARE in world metres. Any
    fixed vertical rate stretches the clumps into vertical streaks.
  * `_place_orb` pulls its anchor back inside (`pull_inside`) when the player is in
    the band — the band is wider than `ORB_RANGE`, so otherwise every candidate
	fails and the fallback strands a goal in the fog where it can't be reached.
  * Shader noise tiling must stay on WHOLE numbers (`tiles_around`, and the 1/2/4
	octave scales) — no longer a seam constraint now the walls are flat, but the noise texture stays `seamless` so a wall tiles without a join.
  Tuning rule: the player must never feel the moment they were stopped. A change
  that makes the boundary crisper is wrong.
  **Climate & day/night pass (2026-07-17):** two more scene-level systems, both
  following the fog border's one-driver rule.
  *Altitude weather* (`altitude_effects.gd`, `AltitudeEffects` node): climbing is
  the hardest exercise the mode offers, so height gets its own reward register —
  wind and cold, all presentational (nothing slows the player; a cardio game must
  never punish the climb). One eased number — `get_factor()`,
  `smoothstep(COLD_START 55, COLD_FULL 105, player.y)`; summits top out ~129 m,
  valley floors ~20-50 — drives: a looping wind bed
  (`assets/audio/wind_loop.wav`, spectrally-synthesized in numpy so the loop is
  periodic by construction; a dedicated `AudioStreamPlayer` on the SFX bus, NOT
  an AudioManager voice, which would get stolen under pool pressure) with
  two-incommensurate-sine gusting shared between what you hear and the streak
  speed you see; velocity-stretched wind-streak particles
  (`TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY` on Y-long sliver quads); summit
  snow above factor 0.55; and a frost vignette (`frost_overlay.gdshader`, a
  pure alpha overlay on CanvasLayer **0** — above the 3D view, below the HUD's
  layer 1) whose noise-serrated frontier creeps in from the frame corners.
  *Day/night* (`day_night_cycle.gd`, `DayNightCycle` node): a full 24 h day per
  `day_length_sec` (720 s) from `start_hour` 8.5, everything a function of the
  sun's elevation (sine of its arc): sun energy/colour (reddening at the
  horizon), a code-built moon (opposite point of the arc, cool, shadowless —
  and with `light_angular_distance` 2.0, because ProceduralSky draws every
  directional light's disc and a 0°-size light blooms into a hard square blob),
  ambient floor `NIGHT_AMBIENT` 0.34 (never unreadably dark — no fail states,
  no unreadable ones either), and dawn/dusk tints as a bell band around
  elevation 0. The DAY palette is **captured from the authored scene at
  `_ready`**, so editor tuning of sky/sun/fog keeps working; only night/dusk
  live as constants. Two non-obvious constraints: the WorldEnvironment's
  `environment` must be **deep-duplicated** at `_ready` (scene-cache resources
  are shared, so tonight's mutated sky would otherwise leak into the next
  session's captured "day" palette), and it coexists with `world_border.gd` by
  property split — the border owns fog *density*, the cycle owns fog *colour*.
  Verified via `scenes/tests/climate_view.tscn` (raycast-scans for the summit,
  parks the player on it; `VIEW_HOUR=18.4 bash tools/shot.sh climate
  scenes/tests/climate_view.tscn` picks the time of day).

**How to run the camera control:**
1. `pip install -r python/requirements.txt` (once).
2. `python python/pose/pose_server.py` — stand ~2 m back so knees/hips are
   visible; the preview shows `forward`/`turn` values.
3. Play the open-world scene in Godot. March in place to move (a harder march
   runs faster), lean to turn, jump to hop. (`player.gd` has an `invert_turn`
   export if leaning steers the wrong way, plus `jump_velocity`/`move_speed`
   tunables.)

**Calories (wired 2026-07-14, upgraded 2026-07-15):** Python emits `met`
(motion-based effort); `MotionManager` integrates it against the player's weight
(`ProfileManager`) into a per-session kcal total (`get_session_calories()`);
`MiniGame.finish()` banks that into the `GameResult.calories` field automatically
for every game, and `ProfileManager` rolls it into the lifetime total. The
cadence→MET leg is anchored to published measurements (CADENCE-Adults /
Tudor-Locke: 100 steps/min = 3 MET, +1 MET per +10 spm), and slow squats now
count via a vertical-work term. **Heart-rate fusion is live:** when a wearable
streams `hr` ≥ 90 bpm, `MotionManager` switches to the Keytel et al. 2005
equation (sex-specific, uses profile weight/age/sex, captured at
`reset_session_stats()`), floored at the motion estimate — so calories stay
accurate even if the camera loses the player. Below 90 bpm (or no strap) the
motion-MET path is used. Set real attributes via
`ProfileManager.set_physical_attributes()` for accuracy. The non-cadence motion
terms are still reasoned estimates pending a calibration/recording pass.

**Recording & training harness (added 2026-07-14):** the accuracy phase runs on
labelled data, so `pose_server.py --record` logs every frame — raw landmarks +
world landmarks + the live feature vector + a move label — to JSONL under
`python/pose/recordings/`. You can label two ways: live, by pressing a
number key (on-screen legend; `0` idle … `6` jump) — handy if a helper types —
or, since you can't march *and* type solo, record freely and label afterward
with `label_tool.py`, which replays the skeleton and paints labels onto
time-ranges. `--metronome BPM` adds a paced beat so stepping has a ground-truth
tempo. `train_classifier.py` then trains a first move classifier offline. This stays inside §9: all learning is Python-side, and
the trained model will crisp up events (feel) and give per-move METs (calorie
accuracy) as a layer on top of the heuristics, which remain the fallback. BLE
heart-rate ingestion is likewise Python-side — `--heart-rate` sends real bpm in
`hr`, and Godot fuses it against the profile it already holds.

Still to come on the Python side (same UDP boundary, no Godot AI): more gesture
recognition (the "hands up to start" ready gesture is done — see the `hands_up`
field above), wiring the trained classifier into the live server, per-user
runtime calibration, and validating the calorie numbers against a reference.

Any game reads movement from `MotionManager` instead of the keyboard, so the
same controller works with the camera today or another input source later.

---

## 10. Coding Conventions

- **Typed GDScript everywhere** (typed params, returns, and vars).
- Keep each script **under ~300 lines**; split responsibilities if it grows.
- **Document public methods** with `##` doc comments.
- No duplicate code — factor shared behaviour into `utilities/` or a base class.
- Prefer **signals** for upward/decoupled communication.
- `PascalCase` classes, `snake_case` functions/vars (see §4).
- Access scene nodes via `%UniqueName` where practical.

---

## 11. Things To Avoid

- ❌ Hardcoding scene paths anywhere but `SceneManager`.
- ❌ Calling `get_tree().change_scene_*` outside `SceneManager`.
- ❌ Global variables instead of managers.
- ❌ AI / computer-vision logic inside Godot.
- ❌ One game reaching into another game's code.
- ❌ Reading/writing files anywhere but `SaveManager`.
- ❌ Menu/flow code that must change when a new game is added.
- ❌ Untyped variables and undocumented public methods.
- ❌ God-classes; keep managers single-purpose and under ~300 lines.

---

## 12. Current TODO

- [x] **Zombie Run — the Infinite Runner** (`scenes/runner/`, registry id `runner`,
	  `available:true`). A cardio chase: a zombie pursues you and you escape by
	  MARCHING — `MotionManager.get_forward()` sets your run speed, which the world
	  scrolls at and which decides whether you out-run the pursuer. The chase is a
	  0..1 "gap": the zombie's speed ramps with time + difficulty, the gap grows when
	  it out-runs you and shrinks when you out-run it; reach `CAUGHT_GAP` and it
	  lunges and the run ends (a real fail state, unlike Open World). Along the way
	  you jump low barriers (`consume_jump`), slide under bars by bowing the torso
	  forward (`max(get_duck(), get_crouch())` — the lean-down duck was added because
	  the squat-based crouch is march-gated and near-impossible mid-run) and lean
	  to dodge side wreckage (`get_turn`) — a hit stumbles you and lets the zombie
	  gain. Score = distance in metres. **Tension is all feedback, and deliberately
	  unquantified**: as the gap closes the vignette squeezes the
	  visible world down to a narrow tunnel and a heartbeat — quickening, throbbing
	  blood into the edges — pulses the camera zoom, and dragging footsteps rise out
	  of the silence behind you. There is NO proximity gauge and
	  NO escape-route map (both existed and were cut on 2026-07-17, see below). The world scrolls PAST a
	  stationary player (`RunnerTrack` recycles a handful of graveyard-corridor tiles
	  + streams obstacles), so "infinite" is cheap and origin-stable. The rear camera
	  only reveals the zombie in the last stretch of the gap, when it rears up huge
	  and reaching in the foreground — the UI carries the threat until then.
	  Files: `runner.gd` (MiniGame orchestrator: chase, tension, camera, flow),
	  `runner_track.gd` (`RunnerTrack`: scrolling world + obstacles + collisions),
	  `runner_player.gd` (`RunnerPlayer`: strafe/jump/slide, personalised model),
	  `zombie.gd` (`RunnerZombie`: loads the zombie GLB, shamble/lunge, self-glow),
	  `runner_hud.gd` (`RunnerHud`: closing-dark vignette + stats + prompts),
	  `runner_audio.gd` (`RunnerAudio`: the sound director), `runner.tscn`.
	  The **zombie model** is generated by `assets/models/generated_human/
	  export_zombie_glb.py` → `assets/models/zombie/zombie.glb`: it reuses the player
	  rig from `export_glb.py` (now takes a `clip_builders` arg) with a gaunt green
	  reskin and bespoke hunched shamble / lunge / idle clips. Shared feet-planting
	  lives in `scripts/utilities/rig_utils.gd` (`RigUtils`). Verified end-to-end via
	  fake UDP march packets + `tools/shot.sh`: escape, loom, catch→Results all clean.
	  **10s briefing + scarier/encouraging pass (2026-07-17):** `runner.gd` now opens
	  every run with a ~10s **grace period** (`BRIEFING_SEC`) before the chase — the
	  world scrolls so you can warm up marching and watch the pace bar, but nothing is
	  scored and the gap is pinned at 0. A centred "OUTRUN THE DEAD" how-to card
	  (`RunnerHud.show_briefing`) lists the four body moves + a live "CHASE BEGINS IN
	  N" countdown, then `_begin_chase()` starts hazards/scoring. The zombie speed ramp
	  is now keyed to `_chase_time` (chase-only elapsed), NOT total elapsed, so the
	  briefing doesn't secretly pre-accelerate the pursuer. Briefing scrolls scenery
	  via `RunnerTrack.scroll(delta, speed, spawn=false)`. Feedback is both scarier and
	  more hyping: distant lightning double-flashes + "IT'S RIGHT BEHIND YOU" groan
	  toasts that quicken with the gap (`_update_scares`), 100m milestone toasts, and a
	  reworked prompt that praises ("YOU'RE PULLING AWAY!", "GREAT PACE") when you're
	  holding it off, not only scolds. New HUD bits: `flash_toast`/`flash_lightning`.
	  **"The less you see, the more you fear" pass (2026-07-17):** the top PROXIMITY
	  gauge and the bottom-right "ESCAPE ROUTE" minimap are **deleted**. Both told you
	  exactly how close the zombie was, which turned terror into arithmetic — you
	  managed a bar instead of feeling hunted. The gap's ONLY channel now is the
	  closing dark: `VIGNETTE_SHADER` drags its clear centre from a wide cinematic
	  frame (`intensity` 0) down to a narrow tunnel (`intensity` 1), clenching on each
	  heartbeat, with grain + a slow breathing wobble so the murk never sits still.
	  Near-black by default — blood washes in only on the beat, so it reads as the
	  light dying rather than a red filter. The beat is the other readout: `hz`
	  0.75→3.2 with the gap. Groan toasts pull from `runner.gd`'s `GROANS` and stay
	  vague on purpose ("SOMETHING'S GAINING"). Don't reintroduce a number.
	  Environment enriched in `runner_track.gd` (`_scenery` seeds varied graves /
	  broken pillars / crypts / broken fences / dead trees per tile + a low
	  ground-fog slab — no crosses or other religious imagery, by request)
	  and `runner.tscn` (a pale emissive **moon** in the upper-left fog, deeper fog).
	  **Sound pass (2026-07-17):** `runner_audio.gd` (`RunnerAudio`) is the run's
	  sound director — four one-shot clips in `assets/audio/` (`heartbeat_single`,
	  `step_single`, `thunder`, `zombie_scream`) re-voiced by pitch/volume/seek into
	  a whole scene, played through AudioManager's voice pool. Sound is the THIRD
	  channel of the unquantified tension and obeys the same rule — nothing reports a
	  distance; the mix just creeps. The heartbeat is **phase-locked** to `runner.gd`'s
	  `_beat_phase` (the same one driving the camera zoom and the vignette clench), so
	  the thump you hear is the thump you see — don't give it a private clock — and it
	  hardens `-17→-2 dB` / `0.9→1.45` pitch with the gap (seeked past the clip's
	  0.19 s of lead silence so the "lub" lands ON the beat). `step_single` covers
	  four things by re-voicing: player strides, jump landings, the hazard crash
	  (pitch 0.45) and the **zombie's drag** (pitch 0.58, inaudible below gap 0.22 then
	  climbing to −8 dB — the creep that replaces a proximity number). Player steps
	  hang off a new `RunnerPlayer.footfall` signal read from the walk clip's own
	  playback position (a foot plants at the start of each half-cycle), not a
	  parallel cadence timer, because the stride runs up to ~3× authored speed and
	  anything else visibly drifts off the legs. `zombie_scream` is the catch and the
	  cinematic's lunge-at-lens (full), and the groan cues (−21 dB, pitch 0.7, seeked
	  0.9 s past its attack so it reads as already-howling, then faded). Thunder
	  trails its flash by 0.35-1.1 s. Long clips (8 s scream, 5.5 s thunder) are
	  tracked and `hush()`ed on teardown/cinematic-skip or they follow the player into
	  the results screen. Verified headless by logging every voice through a full run
	  (fake UDP pace ~0.19 keeps the gap climbing slowly enough to reach the groans).
- [x] **Difficulty select screen** (`scenes/menus/difficulty_select.tscn`,
	  `scripts/ui/difficulty_select.gd`) between Game Select and the game intro.
	  Three cards (EASY "WARM-UP" / NORMAL "STEADY BURN" / HARD "ALL OUT") with a
	  3-pip intensity meter; copy frames difficulty as EFFORT, not skill — this is
	  a fitness platform. The card matching the current difficulty is pre-focused
	  so Enter keeps it; the header names the selected game ("ZOMBIE RUN — HOW
	  HARD?"). Routing is data-driven: a registry entry's `uses_difficulty` flag
	  (default true) decides whether Game Select routes through it — Open World
	  (free-roam, no fail state) sets false and starts directly. Picking a card
	  stores the difficulty and calls `start_selected_game()`.
- [x] **Scene fade transitions** — every `SceneManager.change_scene` dips through
	  a short black fade (see §5 SceneManager). One overlay, whole app.
- [ ] Real calorie value in `MiniGame.finish()` (currently a time-based stub).
- [ ] Extend the Python pipeline (§9) beyond movement — same UDP boundary:
	  - ✅ calorie/effort estimation (motion MET), heart-rate field wired.
	  - ✅ recording harness (`--record`) + offline `train_classifier.py`.
	  - ✅ BLE heart-rate ingestion stub (`--heart-rate`, standard GATT HRS).
	  - [ ] Record a multi-person labelled dataset and train the real classifier.
	  - [ ] Wire the trained move classifier into the live server (crisper events
			+ per-move METs; keep the heuristics as fallback).
	  - [ ] Per-user runtime calibration (stand → march → squat) for thresholds.
	  - [ ] Validate the calorie numbers against a reference (HR / calorimetry).
- [ ] Tune pose thresholds in `pose_server.py` for the target play space/camera.
- [ ] Achievements definitions + unlock triggers (ProfileManager supports the
	  storage; no achievements defined yet).
- [x] Heart-rate display/HUD (first pass): a live "♥ BPM" chip in the Open World
	  HUD (`OpenWorldHud.set_heart_rate`, fed from `_update_hud`) and a "♥ N bpm —
	  heart-rate connected" status line on the main menu, both hidden unless a
	  wearable is actually streaming (`MotionManager.is_hr_connected()`) — most
	  players have no strap, and an absent-state row would be noise. Still open:
	  an HR chip in the Zombie Run HUD (kept out for now — that HUD's rule is
	  "no numbers that quantify the tension") and per-day HR on the dashboard.
- [ ] Async loading via `LoadingScreen` for heavy game scenes.
- [x] Global UI `Theme` in `assets/ui/` for consistent styling — `assets/ui/main_theme.tres`
	  styles Button (+ a `PrimaryButton` type variation) and sets a default Rajdhani
	  font. Applied across the menu scenes (Main Menu, Game Select, Settings, Profile,
	  Fitness, and now the Pause Menu and Loading Screen). The shared "app mood" is a
	  dark navy field (≈`0.05,0.07,0.11` → `0.02,0.03,0.05` gradient), a single orange
	  accent (`1,0.5,0.14`) used sparingly (accent bar + PrimaryButton), the Anton
	  display font for big all-caps titles/values over Rajdhani body text, and dark
	  rounded cards (`~0.07,0.09,0.13`, 14–20px radius, hairline `1,1,1,0.1` border).
	  New screens should reuse `main_theme.tres` + this palette.
- [x] **Styled the Pause Menu, Loading Screen, and Open World HUD** to the app mood
	  (above). The Pause Menu (`scenes/menus/pause_menu.tscn`) is now a centred dark
	  card over a vignette dim: an accent bar, an Anton "PAUSED" title, RESUME as the
	  PrimaryButton, then Restart / End & Save / Quit; `pause_menu.gd` grabs focus on
	  RESUME and fades the overlay in (its node processes while paused so the tween
	  runs). The Loading Screen gets the gradient background, accent bar, Anton title
	  and an orange-filled progress bar. The Open World HUD
	  (`OpenWorldHud` in `scenes/open-world/open_world_hud.gd`) is no longer one crammed label — it's a centred row
	  of dark stat chips (TIME · CALORIES · STEPS · ORBS; caption over an Anton value,
	  calories/orbs in accent) with a subtle bottom "ESC — PAUSE / END & SAVE" hint and
	  a scale-pop on the ORBS chip when one is banked. The Results screen was already
	  code-styled to this look.
- [x] **Player profile UI + first-run onboarding.** `scenes/menus/profile_setup.tscn`
	  (one-time onboarding) and `scenes/menus/profile_screen.tscn` (editable) collect
	  weight/height/age/sex into `ProfileManager` (data layer already existed). A new
	  `onboarded` flag (`ProfileManager.is_onboarded()`/`mark_onboarded()`) gates the
	  one-time setup; the main menu redirects to it on first run and otherwise shows a
	  PROFILE button. Screens are code-built on a shared `PanelScreen` base
	  (`scripts/ui/panel_screen.gd`) using a reusable `ProfileForm`
	  (`scripts/ui/profile_form.gd`); paths/loaders live in `SceneManager`
	  (`PROFILE_SETUP`/`PROFILE`). The profile screen's top row shows REAL lifetime
	  fitness totals derived from `ActivityManager` (calories, steps, active minutes,
	  workouts) — deliberately NOT XP/Level. XP/Level still accrue in ProfileManager
	  for progression but are kept off the profile UI (no gamification placeholders).
	  Still TODO: name entry. (HR-based Keytel calories are now wired in
	  `MotionManager` — see §9 Calories.)
- [x] **Fitness dashboard + daily/weekly history.** `ActivityManager` (§5) logs a
	  per-day record on every `game_finished` and derives week totals, daily
	  averages and streaks. `scenes/menus/fitness_screen.tscn` (FitnessScreen, on
	  the `PanelScreen` base) shows a KPI row (today-vs-goal, streak, week total,
	  daily avg) and a 7-day calorie bar chart (`scripts/ui/bar_chart.gd`,
	  `BarChart`, code-drawn) with the goal line and today highlighted. Reachable
	  from the main menu (FITNESS). Future: editable daily goal UI, monthly/yearly
	  views + consistency heat-calendar, steps/active-minutes charts, per-day HR.
- [ ] **Watch / heart-rate connection UX.** BLE stays Python-side (§9); `hr` already
	  flows through `MotionManager.get_heart_rate()`, `is_hr_connected()` exists, and
	  Keytel HR→kcal fusion is live (§9 Calories), and the connection-status
	  indicator now exists (main-menu status line + Open World HUD chip — see the
	  heart-rate display TODO above). Next: optionally a Godot→Python control
	  channel for in-app scan/pair (the current UDP is one-way). NB only live BLE HRS devices
	  (chest straps / broadcast-mode watches) work — Apple Watch/Fitbit don't expose
	  real-time HR to third parties.
- [ ] Boxing / Football / Tennis game scenes (flip `available` to true).

## 13. Rules for Adding a Future Game

1. Create `scenes/<game>/<game>.tscn` with a root node whose script
   **extends `MiniGame`**; put gameplay code in `scenes/<game>/<game>.gd`.
2. Override `get_game_id()` (return the registry id) and `_start_game()`.
   Call `add_score(...)` during play and `finish(calories)` when the session ends.
3. Add a path constant for the scene in **`SceneManager`** (e.g. `const DANCE`).
4. Add one entry to **`GameManager._build_registry()`** referencing that constant;
   set `available:true` when it's ready to ship.
5. **Do not touch** Game Select, Countdown, Results, or Profile code — the
   data-driven pipeline picks the new game up automatically.
6. Put game-only assets under `assets/…`; reuse `scenes/shared/` for common HUD.
7. Add any new shared system as a manager (§5), respecting init order.
8. Update this document (§12 TODO and anywhere a decision changed).

---

## 14. Completed

- ✅ Project configured for Forward+, 1920×1080, windowed, Keep aspect,
	  canvas-items/fractional scaling, VSync on, 60 physics FPS, title "MotionFit".
- ✅ Full folder structure created (§3).
- ✅ Six manager autoloads implemented and registered in dependency order (§5).
- ✅ `SceneManager` owns all scene paths; no paths hardcoded elsewhere.
- ✅ Data-driven `GameManager` registry (Open World available; others "Coming Soon").
- ✅ `MiniGame` base contract + `GameResult` schema (§6).
- ✅ Shared UI scenes: Main Menu, Game Select, Settings, Pause, Results, Loading,
	  Countdown, with controller scripts. Main Menu is themed (`assets/ui/main_theme.tres`);
	  the other menus still use the default theme (next up).
- ✅ Full launcher flow wired and verified end-to-end (Menu → Game Select →
	  Countdown → **Open World** → End & Save → Results). Open World is the first
	  playable game and completes the loop; the other games show "Coming Soon".
- ✅ PauseMenu gained an optional "End & Save" (`enable_end_option()` +
	  `end_requested`) so endless/no-fail games can bank a session to Results.
- ✅ Save system (`SaveManager`) with Profile + Settings persistence.
- ✅ **Camera movement pipeline** (§9): Python pose service (MediaPipe) →
	  UDP → `MotionManager` → `CharacterBody3D`. Godot side verified end-to-end
	  with simulated packets (character moves/turns; halts on signal loss).
	  Real webcam run is user-side.
- ✅ This CONTEXT.md.
