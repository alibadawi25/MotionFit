#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test.sh — MotionFit headless test suite
#
# Boots the project headless and runs every TestCase under
# scenes/tests/cases/ against the REAL autoloads, then reports a pass/fail
# summary. This is the regression net for the shared platform layer (save,
# profile, XP, registry, result schema) — the code every game depends on, where
# a break is invisible on screen but affects all 20+ games at once.
#
# Complements check.sh: check.sh proves the project still PARSES, test.sh proves
# it still BEHAVES. Run both before a release build.
#
# Usage:
#   tools/test.sh                # every suite
#   tools/test.sh registry_test  # one suite, by its file basename
#
# Env overrides (shared with check.sh / shot.sh):
#   GODOT   path to the Godot 4.7 executable
#   PROJ    path to the project root
#
# NOTE: tests use the real save directory and clean up after themselves
# (TestCase._teardown_base restores the previously active profile). Don't kill
# the run mid-way if you care about the profiles on this machine.
#
# Exit status: 0 = all assertions passed, 1 = failures (or the suite failed to
# boot).
# ---------------------------------------------------------------------------
set -u

GODOT="${GODOT:-/c/Users/aliba/OneDrive/Desktop/Godot_v4.7-stable_win64.exe}"
PROJ="${PROJ:-/c/Users/aliba/OneDrive/Documents/CardioFun}"
OUTDIR="${OUTDIR:-$PROJ/tools/shots}"
LOG="$OUTDIR/test.log"
SUITE="${1:-}"

mkdir -p "$OUTDIR"

if [[ ! -x "$GODOT" ]]; then
	echo "test.sh: Godot not found at '$GODOT' (set GODOT=...)" >&2
	exit 1
fi

# The suite filter is passed after `--` so Godot hands it to the game rather
# than trying to interpret it (read back via OS.get_cmdline_user_args()).
ARGS=(--headless --path "$PROJ" res://scenes/tests/test_runner.tscn)
if [[ -n "$SUITE" ]]; then
	ARGS+=(-- "$SUITE")
fi

"$GODOT" "${ARGS[@]}" >"$LOG" 2>&1
STATUS=$?

# Show the suite report (everything from the banner on), not the engine's boot
# noise — but keep the whole thing in the log for when a boot error is the
# actual problem.
if grep -q "=== MotionFit test suite ===" "$LOG"; then
	sed -n '/=== MotionFit test suite ===/,$p' "$LOG" | grep -v "^\s*$" | grep -v "ObjectDB instances\|resources still in use\|   at: "
else
	echo "test.sh: the suite did not start — see $LOG"
	tail -30 "$LOG"
	exit 1
fi

if [[ $STATUS -ne 0 ]]; then
	echo ""
	echo "test.sh: FAILURES (full log: $LOG)"
	exit 1
fi

exit 0
