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
# Usage:
#   tools/check.sh                                   # boots the main scene
#   tools/check.sh res://scenes/menus/settings_menu.tscn
#
# Args:
#   $1  scene (optional)  res:// path to boot instead of the project main scene
#
# Env overrides (shared with shot.sh):
#   GODOT   path to the Godot 4.7 executable
#   PROJ    path to the project root
#   FRAMES  frames to run before quitting (default 5)
#
# Exit status: 0 = clean, 1 = errors found (also printed).
# ---------------------------------------------------------------------------
set -u

GODOT="${GODOT:-/c/Users/aliba/OneDrive/Desktop/Godot_v4.7-stable_win64.exe}"
PROJ="${PROJ:-/c/Users/aliba/OneDrive/Documents/CardioFun}"
OUTDIR="${OUTDIR:-$PROJ/tools/shots}"
FRAMES="${FRAMES:-5}"

SCENE="${1:-}"
LOG="$OUTDIR/check.log"
mkdir -p "$OUTDIR"

"$GODOT" --headless --path "$PROJ" $SCENE --quit-after "$FRAMES" >"$LOG" 2>&1

# Surface only real problems: script/parse errors and failed loads. Vulkan/VSync
# notes and bare WARNING lines are noise in headless runs.
HITS=$(grep -iE "SCRIPT ERROR|Parse Error|Nonexistent|Invalid (call|get|set|index|access)|Cannot|can't|Failed to load|Attempt to" "$LOG" \
  | grep -viE "vulkan|VSync|WARNING: *$")

if [ -n "$HITS" ]; then
  echo "--- errors ($LOG) ---"
  echo "$HITS" | head -40
  exit 1
fi

echo "OK — no script/parse errors (booted $FRAMES frames, see $LOG)"
