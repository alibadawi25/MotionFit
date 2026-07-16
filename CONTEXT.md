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
| 3 | `AudioManager`  | —                         | Music/SFX playback and audio bus volumes. |
| 4 | `SettingsManager`| SaveManager, AudioManager| User prefs (volumes, fullscreen); loads, applies, persists them. |
| 5 | `ProfileManager`| SaveManager               | Player profile: XP/level, calories, achievements, per-game stats. |
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
- `_start_game()` — override for game-specific setup.
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
[Difficulty]  ← FUTURE screen; currently skipped
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
real game behind it, and 3·2·1·Go plays; then `begin()` runs. A game scene opened
directly (e.g. from the editor) skips the intro and just plays. Adding a game
needs **no intro code** — the base handles it. (The old standalone
`countdown_screen` scene is superseded by this overlay.)

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
{ "forward": 0.0, "turn": 0.0, "jump": false, "crouch": 0.0, "hands_up": false,
  "walking": false, "detected": true, "steps": 0, "cadence": 0.0, "met": 1.2,
  "hr": 0.0, "status": "ready", "ready_hint": "", "ts": 0.0 }
```
- `forward` 0..1  — marching-in-place intensity (drives forward speed).
- `turn` -1..1   — torso lean (drives turning).
- `jump` bool    — true on the single frame a vertical leap launches (edge event).
- `crouch` 0..1  — squat depth (0 = upright), from the planted foot folding up.
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
  `is_crouching()`, `consume_jump()`, `is_hands_up()`, `is_receiving()`,
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
  leap → jump), with
  a follow camera, sun shadows, procedural sky + fog, and four coloured landmark
  pillars for orientation. Steps become score/XP, and six code-spawned **glow
  orbs** (`_spawn_orbs` in `open_world.gd`) each award bonus score on touch and
  respawn ≥8 m from the player — an endless trail of walking goals. The HUD
  shows time/calories/steps/orbs; `player.gd` respawns anyone who falls off the
  60×60 ground. Ending is player-driven: Esc opens the shared PauseMenu,
  whose "End & Save" (`enable_end_option()` / `end_requested`) calls `finish()`.
  This scene doubles as the proof of the motion loop.

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

- [ ] **Build the Infinite Runner** in `scenes/runner/` (owner is building this).
	  Root node's script `extends MiniGame`; override `get_game_id()` → `"runner"`
      and `_start_game()`; call `add_score(...)` during play and `finish(calories)`
      when the session ends. The registry entry and `SceneManager.RUNNER` path
	  (`res://scenes/runner/runner.tscn`) already exist — just flip the runner's
	  `available` to `true` in `GameManager._build_registry()` once the scene is in.
- [ ] **Difficulty select screen** between Game Select and Countdown (flow §7
	  currently skips it; `GameManager` already stores difficulty).
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
- [ ] Heart-rate display/HUD (data source is future Python).
- [ ] Async loading via `LoadingScreen` for heavy game scenes.
- [x] Global UI `Theme` in `assets/ui/` for consistent styling — `assets/ui/main_theme.tres`
	  styles Button (+ a `PrimaryButton` type variation) and sets a default Rajdhani
	  font. Applied at the Main Menu root; reuse it on the other menu scenes next.
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
      Keytel HR→kcal fusion is live (§9 Calories). Next: a connection-status
      indicator in the UI, then optionally a Godot→Python control channel
      for in-app scan/pair (the current UDP is one-way). NB only live BLE HRS devices
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
