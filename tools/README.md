# MotionFit dev tools

Small home-grown tools for developing MotionFit from the command line. Think of
this as our own tiny MCP: the [`godot-mcp`](../addons/godot_mcp) *server* tools
aren't connected in every session, but the addon's autoloads always run inside
the game — so these scripts talk to them over a simple file handshake and get
the same results (screenshots, error logs) headlessly from the shell.

## `shot.sh` — screenshot a scene

Launches a scene (or the whole project) in a throwaway windowed instance, asks
the running game to grab its own viewport, saves the PNG under `tools/shots/`,
prints any script/parse errors, and kills **only** the instance it started (so
an editor you already have open is left alone).

```bash
tools/shot.sh                      # main scene   -> tools/shots/shot.png
tools/shot.sh menu                 # main scene   -> tools/shots/menu.png
tools/shot.sh ow  res://scenes/open-world/open-world.tscn
tools/shot.sh gs  res://scenes/menus/game_select.tscn
```

PowerShell wrapper (primary shell on this machine):

```powershell
.\tools\shot.ps1 menu
.\tools\shot.ps1 ow res://scenes/open-world/open-world.tscn
```

**Args:** `$1` = output basename (lands in `tools/shots/`, default `shot`);
`$2` = optional `res://` scene path (default = the project's main scene).

**Env overrides:** `GODOT` (path to the Godot 4.7 exe), `PROJ` (project root),
`OUTDIR` (where PNGs go), `WAIT` (seconds to let the scene boot, default `6`).

## `check.sh` — headless error check

Boots the project **headless** (no window), which parses every script and starts
every autoload, runs a few frames so scene `_ready` code executes, then quits and
reports any script/parse errors. Our stand-in for the `godot-mcp` `validate_script`
server tool when it isn't connected — catches parse errors, bad identifiers and
`_ready()` runtime errors in a couple of seconds. Exit status is `0` when clean,
`1` when errors are found.

```bash
tools/check.sh                                    # boots the main scene
tools/check.sh res://scenes/menus/settings_menu.tscn
```

```powershell
.\tools\check.ps1
.\tools\check.ps1 res://scenes/menus/settings_menu.tscn
```

**Args:** `$1` = optional `res://` scene to boot instead of the main scene.
**Env overrides:** `GODOT`, `PROJ`, `FRAMES` (frames to run before quitting,
default `5`).

## How it works

The engine side is [`MCPScreenshotBridge`](../addons/godot_mcp/services/mcp_screenshot_bridge.gd),
an autoload registered in `project.godot`. Each frame it polls the Godot user
data dir for a request file and answers by writing a PNG back:

| file (in Godot's `user://`) | direction | meaning |
| --- | --- | --- |
| `mcp_screenshot_req.json` | tool → game | `{"target":"game","token":"…"}` asks a *specific running game* to shoot |
| `mcp_screenshot_res.png`  | game → tool | the captured viewport |
| `mcp_screenshot_meta.json`| game → tool | `{width, height}` of the shot |

`shot.sh` clears any stale files, launches Godot, drops the request, waits for
the PNG, copies it out, then cleans up.

**Instance targeting (the `token`).** The editor and any number of game instances
can all be alive at once, and every one of them polls that single request file.
Two rules in [`MCPScreenshotBridge`](../addons/godot_mcp/services/mcp_screenshot_bridge.gd)
keep exactly one instance answering:

- A runtime of the *wrong kind* for a request (editor vs. game) leaves the file
  in place instead of consuming it, so it can't swallow its sibling's request.
- `shot.sh` mints a per-run `token`, passes it to the instance it launches as a
  `--shot-token=<token>` user arg (after `--`), and puts the same token in the
  request. Only the instance whose token matches answers; every other game
  instance ignores it. So a second running game (or an open editor) can no longer
  answer and hand you the wrong scene.

The launched instance also gets `--quit-after`, so it self-terminates even if the
kill step misses it — orphaned shot instances can't pile up.

## Probes

Headless SceneTree scripts (`godot --headless --path . -s res://tools/<name>.gd`)
that print numbers instead of pixels — usually the faster way to answer "is it
even there?" than spending a screenshot on it.

- `probe_height.gd` — the open world's heightmap min/max/histogram + low spots.
- `probe_spot.gd` — `SPOTS="x,z;..."` prints ground height, slope and downhill
  direction. Use it to aim `ground_view.tscn` cameras; a guessed `GV_POS` puts
  the camera under the terrain about as often as not.
- `probe_scatter.gd` — per-MultiMesh instance counts for `WorldScatter`, plus
  overall plant density. **Do not extend it to print per-instance positions:**
  under `--headless` there is no MultiMesh buffer to read back, so
  `get_instance_transform()` returns identity for every instance of every batch
  — including ones that visibly render. It looks exactly like a placement bug.

## Gotchas

- **A running editor can clobber external scene edits.** If you hand-edit a
  `.tscn`/`.tres` while the Godot editor is open on it, the editor may
  re-serialize and revert your change on its next save. Reload the scene in the
  editor (or close it) before editing files on disk.
- **Same exe name.** The editor and the game are both
  `Godot_v4.7-stable_win64.exe`; `shot.sh` diffs the process list before/after
  launch so it only kills the child it spawned — never your editor.
- **Wrong scene in the PNG?** Historically a second running instance could answer
  the screenshot request and hand you *its* scene (e.g. the main menu) instead of
  the one you asked for. The `token` mechanism above fixes this — but if you ever
  see it again, the tell is a missing `killed <pid>` line in `shot.sh`'s output,
  meaning the shot came from an instance it didn't launch.
- **`tools/shots/` is throwaway.** PNG/log output is git-ignored; delete freely.
