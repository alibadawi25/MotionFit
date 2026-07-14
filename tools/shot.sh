#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# shot.sh — MotionFit screenshot tool
#
# Launches the game (a scene, or the whole project) in a windowed instance,
# asks the running game to screenshot its own viewport via the in-engine
# MCPScreenshotBridge autoload (see addons/godot_mcp/services/
# mcp_screenshot_bridge.gd), copies the PNG out, prints any script/parse
# errors from the run log, then kills ONLY the instance it started — so an
# editor you already have open on the project is left untouched.
#
# This is our stand-in for a live MCP screenshot call: the godot-mcp *server*
# tools aren't wired up in every session, but the bridge autoload always is,
# so this file-based handshake works headlessly from the shell.
#
# Usage:
#   tools/shot.sh                         # main scene -> tools/shots/shot.png
#   tools/shot.sh menu                    # main scene -> tools/shots/menu.png
#   tools/shot.sh openworld res://scenes/open-world/open-world.tscn
#   tools/shot.sh gs res://scenes/menus/game_select.tscn
#
# Args:
#   $1  name  (optional)  basename for the PNG, dropped in tools/shots/. Default: shot
#   $2  scene (optional)  res:// path to a specific scene. Default: project main scene
#
# Env overrides:
#   GODOT   path to the Godot 4.7 executable
#   PROJ    path to the project root
#   OUTDIR  where PNGs land (default: <PROJ>/tools/shots)
#   WAIT    seconds to let the scene boot before requesting the shot (default 6)
# ---------------------------------------------------------------------------
set -u

# --- config (all overridable via env) --------------------------------------
GODOT="${GODOT:-/c/Users/aliba/OneDrive/Desktop/Godot_v4.7-stable_win64.exe}"
PROJ="${PROJ:-/c/Users/aliba/OneDrive/Documents/CardioFun}"
UD="${UD:-/c/Users/aliba/AppData/Roaming/Godot/app_userdata/MotionFit}"
OUTDIR="${OUTDIR:-$PROJ/tools/shots}"
WAIT="${WAIT:-6}"

NAME="${1:-shot}"
SCENE="${2:-}"
OUT="$OUTDIR/${NAME%.png}.png"
LOG="$OUTDIR/${NAME%.png}.log"

GODOT_PROC="$(basename "$GODOT" .exe)"    # e.g. Godot_v4.7-stable_win64
mkdir -p "$OUTDIR"

pids() { powershell.exe -NoProfile -Command \
  "(Get-Process '$GODOT_PROC' -ErrorAction SilentlyContinue).Id" | tr -d '\r' | tr '\n' ' '; }

# A per-run token addresses the screenshot request to the exact instance we
# launch, so a second running game (or an open editor) can't answer it and hand
# us the wrong scene. The instance learns its token from the --shot-token= user
# arg (after the -- separator); the in-engine bridge only answers a matching one.
TOKEN="shot-$$-${RANDOM}${RANDOM}"

# Frames to keep the instance alive as a safety net: enough to boot, get shot,
# then self-quit even if the kill below misses it, so orphans never pile up.
QUIT_FRAMES=$(( (WAIT + 20) * 60 ))

# --- capture ---------------------------------------------------------------
before=$(pids)
rm -f "$UD/mcp_screenshot_res.png" "$UD/mcp_screenshot_req.json" "$UD/mcp_screenshot_meta.json"

"$GODOT" --path "$PROJ" $SCENE --windowed --resolution 1280x720 --position 80,80 \
  --quit-after "$QUIT_FRAMES" -- --shot-token="$TOKEN" >"$LOG" 2>&1 &
sleep "$WAIT"

# Drop the request file the in-engine bridge polls for. "target":"game" makes a
# *running game* (not the editor) answer; "token" pins it to the instance above.
echo "{\"target\":\"game\",\"token\":\"$TOKEN\"}" > "$UD/mcp_screenshot_req.json"
for _ in $(seq 1 30); do [ -f "$UD/mcp_screenshot_res.png" ] && break; sleep 0.5; done
sleep 0.4

if [ -f "$UD/mcp_screenshot_res.png" ]; then
  cp "$UD/mcp_screenshot_res.png" "$OUT"
  echo "SAVED  $OUT"
else
  echo "NO PNG — the game never answered (check $LOG)"
fi

# Drop our (token-pinned) request if the instance never consumed it, so it can't
# confuse a later run that isn't looking for this token.
rm -f "$UD/mcp_screenshot_req.json"

# --- kill only the instance we launched ------------------------------------
after=$(pids)
for pid in $after; do
  case " $before " in
    *" $pid "*) ;;  # was already running (e.g. the user's editor) — leave it
    *) powershell.exe -NoProfile -Command "Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue" >/dev/null
       echo "killed  $pid" ;;
  esac
done

# --- surface any errors from the run ---------------------------------------
echo "--- errors in $LOG ---"
grep -iE "SCRIPT ERROR|ERROR|Parse Error|Invalid|Nonexistent|can't|Cannot" "$LOG" \
  | grep -viE "vulkan|VSync|WARNING: *$" | head -25 || echo "(none)"
