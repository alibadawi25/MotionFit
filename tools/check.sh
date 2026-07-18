#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# check.sh — MotionFit headless error check
#
# Boots the project headless (no window), which parses every script and starts
# every autoload, runs a few frames so scene `_ready` code executes, then quits
# and reports any script/parse errors. This is our stand-in for the godot-mcp
# `validate_script` server tool when it isn't connected: it catches parse errors,
# bad identifiers, and _ready() runtime errors from the shell in a couple of
# seconds, with no display needed.
#
# When booting the whole project (no explicit scene), a scene whose script
# references an autoload can throw a *fake* "Parse Error: Failed" — the threaded
# loader compiles the script before the autoload singletons resolve (see
# scene_manager.gd and the async-scene-loading note). To keep the exit code
# trustworthy, every failing .tscn is re-booted directly (autoloads-first): if it
# loads clean on its own it is reported as a KNOWN FALSE POSITIVE and does NOT
# fail the run. Only genuine errors set exit 1.
#
# Usage:
#   tools/check.sh                                   # boots the main scene
#   tools/check.sh res://scenes/menus/settings_menu.tscn
#
# Args:
#   $1  scene (optional)  res:// path to boot instead of the project main scene.
#                         An explicit scene is an authoritative direct boot, so
#                         no false-positive re-verification is done.
#
# Env overrides (shared with shot.sh):
#   GODOT   path to the Godot 4.7 executable
#   PROJ    path to the project root
#   FRAMES  frames to run before quitting (default 5)
#
# Exit status: 0 = clean (or only known false positives), 1 = real errors found.
# ---------------------------------------------------------------------------
set -u

GODOT="${GODOT:-/c/Users/aliba/OneDrive/Desktop/Godot_v4.7-stable_win64.exe}"
PROJ="${PROJ:-/c/Users/aliba/OneDrive/Documents/CardioFun}"
OUTDIR="${OUTDIR:-$PROJ/tools/shots}"
FRAMES="${FRAMES:-5}"

SCENE="${1:-}"
LOG="$OUTDIR/check.log"
mkdir -p "$OUTDIR"

# Filter a boot log down to real problems (shared by the main + verify passes).
# Vulkan/VSync notes, bare WARNING lines, and the headless UDP port-bind errors
# (MotionManager/CameraPreview with no pose server) are expected noise.
filter_hits() {
  grep -iE "SCRIPT ERROR|Parse Error|Nonexistent|Invalid (call|get|set|index|access)|Cannot|can't|Failed to load|Attempt to" "$1" \
    | grep -viE "vulkan|VSync|WARNING: *$"
}

"$GODOT" --headless --path "$PROJ" $SCENE --quit-after "$FRAMES" >"$LOG" 2>&1
HITS=$(filter_hits "$LOG")

if [ -z "$HITS" ]; then
  echo "OK — no script/parse errors (booted $FRAMES frames, see $LOG)"
  exit 0
fi

# Verify each failing .tscn by direct-booting it (only on a full-project run;
# an explicit scene arg is already an authoritative direct boot).
REAL="$HITS"
FALSE=""
if [ -z "$SCENE" ]; then
  SCENES=$(echo "$HITS" | grep -oE "res://[^\" ]+\.tscn" | sort -u)
  for s in $SCENES; do
    vlog="$OUTDIR/verify_$(echo "$s" | tr '/:.' '___').log"
    "$GODOT" --headless --path "$PROJ" "$s" --quit-after "$FRAMES" >"$vlog" 2>&1
    if [ -z "$(filter_hits "$vlog")" ]; then
      # Clean on its own -> every hit line naming this scene is a false positive.
      FALSE="${FALSE}${s}"$'\n'
      REAL=$(echo "$REAL" | grep -vF "$s")
    fi
  done
fi

FALSE=$(echo "$FALSE" | sed '/^$/d')
REAL=$(echo "$REAL" | sed '/^$/d')

if [ -n "$FALSE" ]; then
  echo "--- known false positives (autoload-referencing scenes that load clean on direct boot) ---"
  echo "$FALSE" | sed 's/^/  OK on direct boot: /'
fi

if [ -n "$REAL" ]; then
  echo "--- errors ($LOG) ---"
  echo "$REAL" | head -40
  exit 1
fi

echo "OK — no real errors ($FRAMES frames; $(echo "$FALSE" | grep -c .) known false positive(s) verified clean, see $LOG)"
exit 0
