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
	boxing/        Boxing game (ring/arena set, fighters, HUD, cinematic).
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

### 4.1 UI lives in the scene, not the script

Menu and HUD layout is **authored in `.tscn`**, so it can be seen and edited in
the Godot editor instead of only existing at runtime. A UI script should read as
"fill in and wire up", not "build".

- Every node that exists for a fixed reason gets a **clear PascalCase name**
  (`MasterVolumeRow`, `CalorieBar`, `PeakHrCard`) and is authored in the scene —
  including nodes that are conditionally shown. Prefer `visible = false` in the
  scene plus a line in `_ready()` over building the node in code.
- Scripts reach their widgets by **unique name** (`%GoalSpin`), declared with
  `unique_name_in_owner = true` on the node. Structural nodes (rows, spacers,
  padding) stay un-unique — they're layout, not API.
- Colours, fonts, styleboxes and spacing belong on the node as theme overrides or
  a `StyleBoxFlat` sub-resource, so they're tweakable in the inspector. Shared
  chrome lives in `assets/ui/styles/*.tres` (`screen_card.tres` is the centred
  menu card; `stat_card.tres` is the dashboard KPI tile).
- **Build in code only what is genuinely per-item**: one card per saved profile,
  per catalogue entry, per achievement, per registered game. Those loops append
  into a scene-authored container (`%CardsRow`, `%AchievementGrid`, `%StatGrid`).
- Reusable pieces are their own scenes — **instance them, never `Node.new()` the
  `class_name`.** Layout is:

  | Folder | Holds |
  |---|---|
  | `scenes/menus/` | One `.tscn` per full screen SceneManager can swap to. |
  | `scenes/ui/` | The in-game overlays MiniGame instances on top of a game: `game_intro`, `game_camera_hud`, `interval_coach`. |
  | `scenes/ui/components/` | Reusable widgets (below). |
  | `scripts/ui/` | One script per screen/overlay — wiring only. |
  | `scripts/ui/components/` | The components' scripts, most `@tool` + `@export`. |
  | `assets/ui/styles/` | Shared `StyleBoxFlat` `.tres` for panel surfaces. |

### 4.1a In-game HUDs extend `GameHUD`

Every game's HUD extends **`GameHUD`** (`scripts/utilities/game_hud.gd`), which
owns the chrome that must look identical in every game: the palette (`ACCENT`,
`TEXT`, `MUTED`, `SAFE`, `WARN`, `DANGER`, `PANEL_BG`, `PANEL_BORDER`), the
`chip()` / `rounded()` styleboxes, the `pop()` attention tween, the full-screen
`flash()`, the toast (`_build_toast()` + `flash_toast()`) and the briefing card
(`show_briefing()` / `hide_briefing()`).

The rule for what goes where:

- **In `GameHUD`** — anything a player should not be able to tell apart between
  games. A toast that pops differently in Boxing than in Hurdle Dash reads as a
  bug, not as character.
- **In the game's HUD** — the readouts that *are* the game: Boxing's health bars
  and round clock, Hurdle Dash's field strip and placing, Zombie Run's closing
  dark. Games stay visually distinct through *what they show*, not through
  privately re-deriving the shared chrome.

HUD layout is authored in a `.tscn` like every other screen. **All three HUDs are
ported** (`boxing_hud.tscn`, `sprint_hud.tscn`, `runner_hud.tscn`), each
instanced via a `HUD_SCENE.instantiate()` const — never `BoxingHud.new()` /
`SprintHud.new()` / `RunnerHud.new()`, because the script alone has no nodes and
would give you an empty HUD. A HUD declares the base's chrome as `%Flash` and
`%Toast` and `GameHUD` adopts them in `_adopt_scene_chrome()`; `_build_flash()` /
`_build_toast()` survive for anything that still needs to build chrome by hand.

Shader-driven HUD layers go in a `.gdshader` beside the scene, not in a GDScript
string — Zombie Run's closing dark is `runner_vignette.gdshader`, assigned to
`%Vignette` in the scene, and the script only pushes `intensity` / `pulse` at it.

Two traps when porting a HUD, both hit in practice:

- The old code set `position`, which fixes an element's **top** edge. A
  bottom-anchored container defaults to `grow_vertical = 0` (grow *upward*), so
  it must be set to `1` (`GROW_DIRECTION_END`) or the block rides up by its own
  height and collides with whatever is above it.
- Anything genuinely per-item still gets built in code — Hurdle Dash's strip dots
  are one per runner, so `setup_strip()` stays; so do Zombie Run's four briefing
  badges, each a different runtime-rasterized SVG on its own looping tween. The
  scene owns the track they move along, not the items.

Port a HUD by screenshotting the same state before and after and diffing the two
PNGs. Boxing and Hurdle Dash both came out at **0 changed pixels of 2,073,600**,
which is the bar. Zombie Run's HUD animates by design (the vignette's grain and
breathing wobble are driven by `TIME`, and the briefing badges loop tweens), so
an exact match is unreachable — there, shoot the scene **twice on each side** and
require the cross-version difference to be no larger than the same-code
run-to-run difference. It came in strictly smaller on every measure.

Subclasses **must call `super()` from `_ready()`** (the base loads the display
font and adopts any scene-authored chrome). Before this base existed each HUD carried its own copy of the palette and
its own `_chip()` — two byte-identical, the third quietly shipping a heavier
shadow — and Hurdle Dash's briefing had lost its backdrop dim entirely. Add
shared chrome to the base, never to a fourth copy.

> New `class_name` globals are not visible to a directly-booted scene
> (`tools/shot.sh`) until the class cache is rebuilt:
> `godot --headless --path . --import`.

### 4.2 The component catalogue (`scenes/ui/components/`)

| Component | What it is | Used by |
|---|---|---|
| `stat_tile` | Value + optional unit over a caption. `@export caption/value/unit/value_color`. | Profile, Fitness, Main Menu |
| `form_row` | Fixed-width label, then whatever control you add as a child. `@export label_text`. | Profile Form, Appearance Form, Settings, Profile, Create Profile |
| `meter_bar` | Track + coloured fill with an optional target marker. `set_fraction(v, color)`. | Game Intro, Calibration, Interval Coach |
| `camera_mirror` | The webcam mirror plus its frame and LIVE badge; reads [CameraPreview] itself, `is_live()` / `set_frame_color()`. | Game Intro, Camera HUD, Camera Test, Calibration |
| `game_card` | One registry game: preview still, title, description, status pill. `bind(game)` / `set_ready()`. | Game Select |
| `soon_tile` | Compact locked tile for a not-yet-built game. | Game Select |
| `difficulty_card` | One intensity option; every string and the pip count are `@export`s. | Difficulty Select |
| `profile_form` / `appearance_form` | The body-attribute and character-look input groups. | Profile, Create Profile |
| `character_preview` | Self-contained 3D turntable (own World3D, key light, camera). | Profile |
| `hud_briefing` | The pre-game "how to play" card: kicker, title/subtitle, a body the game fills (`add_row` / `add_line` / `add_section` / `add_note`), countdown and optional draining time bar. Instanced by `GameHUD.show_briefing()`. | Zombie Run, Hurdle Dash, Boxing |

- Repeated *button* looks are **theme variations** in `assets/ui/main_theme.tres`,
  not per-scene styleboxes: `PrimaryButton`, `CornerButton` (the dark ◄ MENU /
  ✕ QUIT corner affordances), `CardButton` (the big selectable cards),
  `TabButton` / `TabButtonActive` (the Store's category strip), `GhostButton` /
  `DangerButton` (the destructive-confirm pair). Restyling every card or corner
  button is a theme edit. **Never mutate a stylebox you got from the theme** —
  it's shared; `duplicate()` it into a local override first (see
  `game_intro.gd`'s calibrate button).
- The centred-card screens share `PanelScreen` (`scripts/ui/panel_screen.gd`),
  which is now just the palette plus `set_header()`; each screen's `.tscn`
  supplies `%TitleLabel`, `%SubtitleLabel` and `%ContentBox`, and its card uses
  `assets/ui/styles/screen_card.tres`.

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
| 8 | `AchievementManager`| GameManager, ProfileManager, ActivityManager | Achievement + discovery system. Definitions are DATA (career/session/streak/discovery entries, ~25); unlocks are evaluated automatically on `game_finished` against stats the other managers already track, so no game contains achievement code. Storage stays in ProfileManager (`get_achievements`/`has_achievement`/`unlock_achievement`). Registered AFTER ActivityManager so evaluated streaks/totals include the session that just ended. Retroactive: re-evaluates at boot and on profile switch, so definitions added in an update unlock from stored stats. Open World finds persist via `report_discovery(id)` (achievement ids `secret_*`, built at _ready from WorldScatter's SECRETS so the page can't drift from the world). `take_recent_unlocks()` is the not-yet-celebrated queue the Results screen drains for its gold pills; `get_next_goal()` returns the closest locked career achievement (the "chase this next" line). |

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
- The target scene is loaded on a **background thread**
  (`ResourceLoader.load_threaded_request` behind the black; `use_sub_threads`
  must stay **false** — parallel sub-thread loading fails to compile scripts
  that reference autoloads, surfacing as a bogus "Parse Error: Failed" on the
  scene). If a load outlasts `LOADING_UI_DELAY_SEC` (0.2 s), SceneManager
  overlays `loading_screen.tscn` above the fade and feeds its bar real
  progress via `set_progress()` — menus never see it, heavy game scenes do.
  So the app never freezes on a scene swap, and `loading_screen.tscn` is no
  longer a routed-to standalone screen.
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
`get_tree().paused` and processes while paused. Both of its leave options bank the
session first, so pausing out never discards measured effort: "End & Save" emits
`end_requested` (→ `finish()` → Results) and "Quit to Game Select" emits
`quit_requested` (→ `bank_and_exit()` → launcher, no Results). Games don't wire
this themselves — `MiniGame.attach_pause_menu(parent)` instantiates the overlay and
connects both signals. `GameManager.finish_game(result, show_results)` records the
session either way; `show_results=false` routes to Game Select instead of Results.

UI controller scripts live in `scripts/ui/` and use `%UniqueName` node access so
scene restructuring rarely breaks code.

---

## 8. Save System

- `SaveManager` is the **only** file-I/O system. Format is JSON.
- Runtime saves live in `user://saves/` (writable in exported builds).
- **Writes are atomic.** The JSON goes to a `<name>.tmp` scratch file which is
  renamed over the real save only once it is closed. Opening the save directly
  with `FileAccess.WRITE` truncates it first, so a crash mid-write would take
  every profile with it.
- **Every save is stamped** with `SaveManager.SCHEMA_VERSION` under a
  `_schema_version` key. `load_data()` strips the stamp before returning (several
  managers iterate what they load, and a bookkeeping key would read as a phantom
  profile or setting); `get_saved_version(file)` reads it without loading —
  **0** = written before stamping existed, **-1** = no file at all, which
  migration code has to be able to tell apart. Bump the version only when an
  existing key's *meaning* changes; a new optional key needs no bump, since every
  manager already backfills from its own defaults.
- **Numbers load back as floats.** JSON has one number type, so `7` returns
  `7.0`. Cast on read (`int(data["level"])`) — never assign a loaded value
  straight into a typed `int`. `scenes/tests/save_probe.tscn` pins all of the
  above.
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
  "hands_up": false, "punch": "", "punch_power": 0.0,
  "punch_kind": "straight", "guard": false, "lean": 0.0,
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
- `punch` string / `punch_power` 0..1 — the **Boxing** upper-body intent: `"left"`
  or `"right"` on the single frame a punch (fast arm extension to full reach) is
  thrown (edge event, like `jump`), else `""`; `punch_power` is how hard it
  snapped. Read from `detected` (no marching gate — a standing boxer). Exposed as
  `BoxingInput.consume_punch()` / `get_last_punch_power()` (see §5.1).
- `punch_kind` string — the **shape** of that punch: `"straight"` (jab/cross),
  `"hook"` (the wide swing) or `"uppercut"`, classified from how far the glove
  travelled forward / sideways / upward between its resting guard and full
  extension (torso-normalised, so it needs no calibration). Deliberately lenient
  and biased to `"straight"`: Boxing is for players who have never boxed, so a
  scrappy throw is named, never rejected. Only meaningful on a frame where
  `punch` is set. `BoxingInput.get_last_punch_kind()`.
- `guard` bool — **Boxing defence**: both gloves up covering the face (each wrist
  above the shoulder line *and* tucked in near the head, so a wide-flung arm or a
  punch at full extension doesn't count). A held state, not an edge.
  `BoxingInput.is_guarding()`.
- `lean` -1..1 — **Boxing defence**: the waist slip, from the shoulder centre's
  sideways offset from the hip centre. `-1` = leaning to the player's on-screen
  LEFT (mirrored preview, same convention as `punch` sides). Distinct from
  `turn`, which is rotating the torso to steer. `BoxingInput.get_lean()`.
- `steps` int / `cadence` float — cumulative steps and current pace (steps/min).
- `met` float    — effort as a metabolic equivalent (body-mass-independent).
  Godot turns this into calories via `ProfileManager` weight × time; MET is used
  precisely so Python needs no player data. ~1.2 still, ~4-5 march, ~8+ vigorous.
  Four channels are read and the strongest wins: stepping cadence, marching
  vigour, squat work, and **boxing work** (punch rate + guard hold + slip work),
  which exists because the first three all under-read a player throwing hard
  combos without stepping. The boxing channel is anchored to the Compendium of
  Physical Activities' boxing entries — bag ~5.5 MET, sparring ~7.8, in-ring
  ~12.8 — landing at 40/60/100 punches per minute respectively.
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

  **Shared movement only.** Moves belonging to ONE game do not get an accessor
  here — Boxing's punch/guard/slip used to, which would have made this singleton
  the union of twenty games' vocabularies by the time the roster filled. A game
  instead registers the packet fields its moves are made of and reads them back
  through its own adapter:

  - `watch_pose_event(key, payload_keys)` — latch a one-shot field so a caller
	polling once a frame can't miss one that landed between frames.
	`payload_keys` are captured at the same instant (a punch's power and shape),
	which is the part a later read can't recover.
  - `consume_pose_event(key) -> Dictionary` — the latched payload, cleared.
  - `get_pose_bool/float/string(key, default)` — continuously-streamed fields.
	Absent fields return the default, so an older pose build degrades to "not
	doing that" instead of breaking.
  - `pose_event(key, payload)` signal for event-driven listeners.

  `scenes/boxing/boxing_input.gd` (`BoxingInput`) is the reference adapter: it
  owns the words *punch*, *guard* and *slip*, and `boxing.gd` talks to it, not to
  MotionManager. A new game with its own moves adds an adapter beside its scene
  and changes nothing shared. Covered by
  `scenes/tests/boxing_input_probe.tscn` — a headless PASS/FAIL self-test that
  feeds synthetic packets through the real handler (this path has no visual
  surface, so a screenshot proves nothing about it).
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
  (`end_requested` → `finish()`) banks the free-roam session. This scene doubles
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
  **Fog border pass (2026-07-17):** the terrain is a finite ~1 km square, so
  `world_border.gd` (`WorldBorder`, a node in the scene) closes it off the Black Flag
  way — the world doesn't end, it gets too thick to walk into. The boundary is a
  **square hugging the terrain's own rim**: `HALF_EXTENT` 496 caps |x| and |z|, so
  ~94% of the map stays walkable and you can reach the coast on every side. It was a
  circle first and that was wrong — a circle inscribed in a square cuts every corner
  (r=224 kept ~60% of the map and left only ~40 m between the spawn and the wall).
  **The boundary must follow the shape of the thing it bounds.** Four systems keyed
  off ONE number — `get_haze(pos)`, 0 inside `SOFT_EXTENT` (466 m) → 1 at
  `HALF_EXTENT` — so they always agree:
  (1) two nested square rings of `border_fog.gdshader` walls at ±508/±532 (three
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
  **Flora & ground-cover pass (2026-07-18):** the world stopped being bare
  geometry — sand shores, waving grass, and code-scattered woods, all driven by
  the SAME height/slope/splat rules so every layer agrees on what grows where.
  *Data maps* (`tools/paint_terrain.gd`, a headless one-shot painter — rerun it
  then `--headless --import` whenever the heightmap is resculpted): paints the
  4th splat weight (SAND, alpha channel) below ~world y 15 fading out by ~17
  with noise-jittered thresholds (wandering coastline) and slope damping (cliff
  shores stay stone), and writes `Terrain/detail.png` (L8), the grass detail
  layer's density map — grass-splat weight × shore/altitude/slope fades ×
  patch noise. The detail map had to be REGISTERED in `Terrain/data.hterrain`
  (JSON: `maps[4] = [{"id":0}]`) — the PNG alone is not enough. Data maps
  import lossless (like splat.png); surface textures VRAM-compressed + mipmaps.
  *Textures* (`assets/textures/terrain/`): `gen_sand.py` (sand albedo+bump /
  normal+rough pair, same packing as gen_grass.py) and `gen_grass_blades.py`
  (the blade billboard, tips at texture-top because the detail shader's wind
  displaces `1 - uv.y`; alpha re-hardened after downscale since the shader
  alpha-scissors at 0.5).
  *Grass rendering*: an `HTerrainDetailLayer` node (`GrassLayer`) under
  HTerrain — layer 0, density 3, view_distance 115 — plus `ambient_wind 0.15`
  on the terrain node, which is what makes the blades sway.
  *Scatter* (`scenes/open-world/world_scatter.gd` + `scatter_meshes.gd`, a
  `WorldScatter` node): deterministic (fixed-seed) jittered-grid placement of
  ~1k trees + boulders into three MultiMeshes (one draw call each, subtle
  per-instance tints via vertex-color-as-albedo), with slim trunk/boulder
  colliders pushed straight through the PhysicsServer onto ONE StaticBody3D
  (node-per-shape would cost more than the shapes). Trees clump into woods via
  a low-frequency noise mask; conifers own the upper band, broadleafs the
  valleys; the wood thins toward the treeline instead of stopping dead.
  Non-obvious numbers: the roamable midlands INCLUDING THE SPAWN PLATEAU sit
  at world y ~64-68 — vegetation bands tuned "sensibly" against sea level
  (13.5) left the first meadow the player ever sees bare; the treeline runs to
  66 and full grass to ~65 for exactly that reason.
  *The crystal grotto (2026-07-18)*: the walkable cave prototype, built by
  `world_scatter.gd` (`GROTTO_POS` (228, 47.4, −60), mountain's east flank,
  ~195 m west of spawn). Heightmap terrain cannot hold true caves, so it is a
  hemisphere shell of oversized scatter boulders (three rings; ±62° mouth gap
  facing east — wide because webcam steering is imprecise) with an amber
  OmniLight + emissive crystal clusters (`ScatterMeshes.build_crystal`) inside.
  It rides the existing boulder MultiMesh + PhysicsServer collider path and is
  appended AFTER the MAX_ROCKS cap so thinning can never delete the landmark;
  ordinary scatter keeps clear (per-secret `clear` radius). Site found with
  `tools/probe_spot.gd` (`SPOTS="x,z;..."` prints height/slope/downhill). Verified via
  `scenes/tests/ground_view.tscn` (`GV_POS="x,y,z" GV_AT="x,y,z" bash
  tools/shot.sh name scenes/tests/ground_view.tscn` — head-height camera,
  defaults to the spawn meadow). NB a camera placed below the terrain surface
  sees straight through backface-culled ground to the sea plane — it reads as
  "standing at a shoreline" and cost a debugging detour; probe heights first
  (`tools/probe_height.gd` conventions: world ≈ (pixel − 256) × 2, world y =
  map value × 1.5).
  *Hidden secrets (2026-07-18)*: five discoverable landmarks, listed in
  `world_scatter.gd` `SECRETS` (id/name/pos/trigger `radius`/scatter `clear`) —
  the grotto plus the summit cairn (−60, −120, y≈80: stacked boulders, pale
  crystal + cold beacon light), the standing stones (−240, 240: eight menhirs =
  tall-anisotropic boulders + fallen slab on the west plateau), the castaway
  camp (60, 250: `build_driftwood` lean-to, ember glow, stone fire ring in a
  beach cove) and the glowing hollow (−405, −285: `build_mushroom` ring +
  violet light in the far-corner woods). Landmark stones ride the same
  post-cap boulder MultiMesh; because menhirs are scaled thin-x/z tall-y,
  `_build_colliders` sizes rock spheres from the HORIZONTAL scale (y only
  gates the ≥0.75 "big enough to block" check). `open_world.gd` reads
  `SECRETS`, plants silent Area3D triggers (`_spawn_secret_triggers`), and a
  find = +50 score, a SECRETS x/5 HUD chip pulse and a fading "DISCOVERED —
  NAME" banner (`OpenWorldHud.show_discovery`); finds are per-session on
  purpose (rediscovery = another walk). Verified headless by teleporting the
  player into a trigger and checking `_secrets_found`.

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
	  `runner_hud.gd` + `runner_hud.tscn` (`RunnerHud`: closing-dark vignette +
	  stats + prompts) and `runner_vignette.gdshader`,
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
	  closing dark: `runner_vignette.gdshader` drags its clear centre from a wide cinematic
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
- [x] **Achievements + discoveries (2026-07-18).** `AchievementManager` (§5 #8)
	  holds the data-driven catalog and unlock triggers; the ACHIEVEMENTS screen
	  (`scenes/menus/achievements_screen.tscn`, `scripts/ui/achievements_screen.gd`
	  on the PanelScreen base, reachable from the main menu) shows a WORLD
	  DISCOVERIES shelf (the five Open World landmarks — an unfound one shows
	  "???" but its treasure-hunt HINT is always visible, because the hint is the
	  invitation to go walking) over a two-column achievement grid (earned = gold
	  edge; locked = dimmed but always shows how to earn it + live progress for
	  career stats, e.g. "36 / 100 workouts" — a menu of things to do, never a
	  wall of failure). **Encouragement pass, same date:** the Results screen
	  gained a warm one-liner picked from what actually happened (level-up >
	  record > daily goal > streak > honest rotating praise), gold "achievement
	  earned" pills (capped at 3 + "+N more"; drained from `take_recent_unlocks`,
	  so a find from a session that never reached Results is celebrated on the
	  next one rather than lost), and a quiet "NEXT GOAL — FULL WEEK · 5 / 7
	  days" line so leaving the screen always hands the player a next purpose.
	  The main menu profile card gained a "why play today" line (streak + today
	  vs daily-goal kcal, goal-done variant in gold). All copy frames effort and
	  consistency, never skill. Verified by
	  `scenes/tests/achievement_probe.tscn` (headless self-test: pushes a fake
	  GameResult through the real finish pipeline, asserts unlocks/non-unlocks/
	  queue/discoveries, then deletes its throwaway profile — 14 PASS) plus
	  shot.sh view scenes `results_view.tscn` (stages a result + pills with NO
	  writes to real saves) and `menu_view.tscn` (skips the profile-picker boot
	  gate).
- [x] Heart-rate display/HUD (first pass): a live "♥ BPM" chip in the Open World
	  HUD (`OpenWorldHud.set_heart_rate`, fed from `_update_hud`) and a "♥ N bpm —
	  heart-rate connected" status line on the main menu, both hidden unless a
	  wearable is actually streaming (`MotionManager.is_hr_connected()`) — most
	  players have no strap, and an absent-state row would be noise. Still open:
	  an HR chip in the Zombie Run HUD (kept out for now — that HUD's rule is
	  "no numbers that quantify the tension") and per-day HR on the dashboard.
- [x] Async loading via `LoadingScreen` for heavy game scenes — SceneManager
	  threads every scene load and overlays the loading screen with real
	  progress when a load runs long (see §5 SceneManager).
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
	  PROFILE button. Screens are laid out in their own `.tscn` on a shared
	  `PanelScreen` base (`scripts/ui/panel_screen.gd`, see §4.1) and instance the
	  reusable `ProfileForm` scene (`scenes/ui/profile_form.tscn` +
	  `scripts/ui/profile_form.gd`); paths/loaders live in `SceneManager`
	  (`PROFILE_SETUP`/`PROFILE`). The profile screen's top row shows REAL lifetime
	  fitness totals derived from `ActivityManager` (calories, steps, active minutes,
	  workouts) — deliberately NOT XP/Level. XP/Level still accrue in ProfileManager
	  for progression but are kept off the profile UI (no gamification placeholders).
	  Name entry is collected at onboarding (`profile_setup.gd` → `create_profile`)
	  and surfaced in the menu greeting and the Results screen (personalised by
	  first name). (HR-based Keytel calories are now wired in `MotionManager` — see
	  §9 Calories.)
- [x] **Fitness dashboard + daily/weekly history.** `ActivityManager` (§5) logs a
	  per-day record on every `game_finished` and derives week totals, daily
	  averages and streaks. `scenes/menus/fitness_screen.tscn` (FitnessScreen, on
	  the `PanelScreen` base) shows a KPI row (today-vs-goal, streak, week total,
	  daily avg) and a 7-day calorie bar chart (`scripts/ui/bar_chart.gd`,
	  `BarChart`, code-drawn) with the goal line and today highlighted. Reachable
	  from the main menu (FITNESS). The daily goal is now editable inline (a SpinBox
	  that writes back through `ActivityManager.set_daily_calorie_goal` and rebuilds
	  every goal-derived figure), and a code-drawn GitHub-style consistency
	  heat-calendar (`scripts/ui/heat_calendar.gd`, `HeatCalendar`, fed by
	  `ActivityManager.get_calendar()`) sits under the bar chart — the classic
	  streak-retention view. The daily goal **auto-adapts** by default: rather than a
	  flat 300 that some players can't reach, `ActivityManager.get_daily_calorie_goal()`
	  in "auto" mode returns `get_adaptive_calorie_goal()` — the average of the
	  player's *active* days over the last 14 (`get_average_active_day_calories`),
	  nudged ~10% and floored at a friendly 120 (a 150 onboarding goal before any
	  history). The FitnessScreen SpinBox gains an **AUTO** toggle; turning it off
	  makes the shown number a manual override (`set_daily_calorie_goal` → mode
	  "manual"), and old saves that had customised the goal migrate to manual.
	  Future: monthly/yearly views, steps/active-minutes charts, per-day HR.
- [x] **Daily Challenge — structured HIIT retention layer.** A deterministic
	  interval workout prescribed per calendar day (`WorkoutManager`, autoload): the
	  date seeds both the host game (from an endless / time-based eligible set —
	  Open World, Zombie Run) and one of four interval templates (Classic / Pyramid
	  / Ladder / Tabata-style), so today's challenge is stable all day, refreshes at
	  midnight, and needs nothing stored to describe it. It's surfaced as the top
	  card on the main menu (above PLAY) with its structure, length, push count and
	  pending/done state, and launched via `GameManager.start_daily_challenge()`
	  (which arms `_pending_workout`, consumed once by `take_pending_workout`).
	  In-game, `IntervalCoach` (`scripts/ui/interval_coach.gd`, a CanvasLayer the
	  `MiniGame` base overlays when a plan is pending — same hook as the camera HUD)
	  runs the block timeline and coaches the player toward each block's MET target
	  using the live effort read (`MotionManager.get_met()`, the estimator that also
	  drives calories); keyboard-only players still get the timeline, only the
	  pass/fail verdict is withheld. **Intensity is personalised, not one-size-fits-all:**
	  the template structure/game are date-deterministic, but `WorkoutManager._scale_targets`
	  multiplies every block's `target_met` by `_effort_scale()` (0.80–1.12, from the
	  player's recent active-day calories vs a 350 reference; 0.85 before any history),
	  so "on target" is reachable for a beginner and still a push for the very active,
	  and rises on its own as activity climbs. The coach copy is **encouragement, never
	  scolding** ("GREAT PACE — HOLD IT", "FIND A LITTLE MORE — YOU'VE GOT THIS"), with
	  no alarming red on the work verdict. Its panel sits below the game's top stat bar
	  (`STAT_BAR_CLEARANCE`) so it doesn't overlap the HUD chips. Completing the timeline
	  ends the session and banks the day via `WorkoutManager.mark_today_complete()`
	  (per-profile, with its own challenge streak, scoped/reloaded like the activity
	  log). Results celebrates a completed challenge with a gold kicker and a
	  personalised line. Verified by `scenes/tests/interval_coach_view.tscn` (WAIT=8
	  lands mid-work-block).
- [ ] **Watch / heart-rate connection UX.** BLE stays Python-side (§9); `hr` already
	  flows through `MotionManager.get_heart_rate()`, `is_hr_connected()` exists, and
	  Keytel HR→kcal fusion is live (§9 Calories), and the connection-status
	  indicator now exists (main-menu status line + Open World HUD chip — see the
	  heart-rate display TODO above). Next: optionally a Godot→Python control
	  channel for in-app scan/pair (the current UDP is one-way). NB only live BLE HRS devices
	  (chest straps / broadcast-mode watches) work — Apple Watch/Fitbit don't expose
	  real-time HR to third parties.
- [ ] **Open World wildlife (models + behaviour DONE 2026-07-18, sound pending).**
	  `scenes/open-world/animal_meshes.gd` is a ScatterMeshes-style companion
	  (chunky primitives, vertex-color-as-albedo for MultiMesh tints, metres,
	  ground origin — birds are authored around the BODY CENTRE since a flyer
	  has no ground) with six species, one per biome: deer + songbird (woods),
	  fox (dusk treeline), rabbit (meadows), gull (shore, mid-glide pose),
	  butterfly (grass/flower bands, faint self-glow for dusk). All face +Z.
	  `scenes/open-world/wildlife.gd` (a node in open-world.tscn) spawns ~50 of
	  them into the right biomes — same height/splat/clump-noise sources as
	  world_scatter.gd, deterministic seed — and drives them per physics frame
	  as records behind one MultiMesh per species: ground animals wander a
	  leash and FLEE the player (walk/flee speeds per species), songbirds
	  flush into a flight arc and re-perch 20-35 m away, gulls fly banked
	  soaring loops off the shore, butterflies drift a Lissajous wander with a
	  wing-beat roll. All motion is whole-body (yaw, hop/trot bob) — parts are
	  never re-posed. Ground animals >160 m from the player freeze (LOD).
	  Verified by `scenes/tests/animals_view.tscn` (static lineup) and
	  `scenes/tests/wildlife_view.tscn` (LIVE system: frames a species chosen
	  via WL_SPECIES env, prints populations + wander/flee displacement probes
	  to the shot log — needs WAIT=17). Still to build: the ambient sound
	  layer keyed to the same biomes (birdsong in the woods, surf + gulls on
	  the shore).
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

- ✅ Project configured for Forward+, 1920×1080 base, fullscreen,
	  canvas-items/fractional scaling, VSync on, 60 physics FPS, title "MotionFit".
	  Stretch aspect is **`expand`**, not `keep`: at `keep`, a player on a 16:10
	  laptop or an ultrawide got black bars, because the frame was forced back to
	  16:9. With `expand` the viewport takes the window's real aspect and the UI
	  reflows into it — verified at 5:4, 16:10 and 21:9, all reflowing with nothing
	  clipped. This works because every menu root is a full-rect Control and no
	  scene hardcodes 1920/1080; keep it that way. `SettingsManager.MIN_WINDOW`
	  (1280×720) floors the window so the UI can't be shrunk past readable.
	  > The app boots fullscreen, and **fullscreen ignores `--resolution`**, so
	  > `RES=` in `tools/shot.sh` only bites if you temporarily set
	  > `window/size/mode=0` in project.godot. That is how the above was checked.
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
- ✅ PauseMenu leave options both bank the session (never discard): "End & Save"
	  (`end_requested` → Results) and "Quit to Game Select" (`quit_requested` →
	  launcher). `MiniGame.attach_pause_menu()` wires both for every game.
- ✅ Save system (`SaveManager`) with Profile + Settings persistence.
- ✅ **Camera movement pipeline** (§9): Python pose service (MediaPipe) →
	  UDP → `MotionManager` → `CharacterBody3D`. Godot side verified end-to-end
	  with simulated packets (character moves/turns; halts on signal loss).
	  Real webcam run is user-side.
- ✅ This CONTEXT.md.
