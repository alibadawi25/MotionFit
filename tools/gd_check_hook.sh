#!/usr/bin/env bash
# PostToolUse hook: after Claude edits a .gd file, run the headless error check
# so parse/script errors surface immediately. Exits 0 (silent) unless the edited
# file was a .gd AND check.sh reported errors, in which case it exits 2 and prints
# the failures to stderr (Claude reads stderr on exit 2).
set -u

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
INPUT="$(cat)"

# Pull tool_input.file_path out of the hook JSON on stdin.
FILE="$(printf '%s' "$INPUT" | python -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))" 2>/dev/null)"

# Only care about GDScript edits.
case "$FILE" in
  *.gd) ;;
  *) exit 0 ;;
esac

OUT="$(bash "$PROJ/tools/check.sh" 2>&1)"
STATUS=$?
if [ "$STATUS" -ne 0 ]; then
  {
    echo "gd_check_hook: tools/check.sh found errors after editing $FILE"
    printf '%s\n' "$OUT" | tail -25
  } >&2
  exit 2
fi
exit 0
