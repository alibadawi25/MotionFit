extends Node
## TestRunner
##
## Discovers every [TestCase] under [constant CASES_DIR], runs them all in one
## headless boot against the real autoloads, prints a per-assertion report, and
## exits non-zero if anything failed. Driven by `tools/test.sh`.
##
## Why one boot for the whole suite: the autoloads ARE the system under test, and
## standing them up is most of the cost. Running the suite in-process also means
## a test that corrupts shared state shows up as a later failure instead of
## passing in its own private universe — which is the failure mode that matters
## for a platform where every game shares these managers.
##
## Run everything:      bash tools/test.sh
## Run one suite:       bash tools/test.sh save_test

## Folder scanned for test scripts. One `*_test.gd` per suite.
const CASES_DIR: String = "res://scenes/tests/cases/"
## Suffix a script must have to be collected, so helpers can live here too.
const CASE_SUFFIX: String = "_test.gd"

var _total: int = 0
var _failed: int = 0


func _ready() -> void:
	# Let the managers' deferred boot work settle (ProfileManager loads its
	# roster, AchievementManager runs its retroactive catch-up) so tests see a
	# fully-initialised platform rather than a half-built one.
	await get_tree().process_frame
	await get_tree().process_frame

	var only: String = _requested_suite()
	var paths: Array[String] = _find_cases()
	if paths.is_empty():
		push_error("TestRunner: no *%s found in %s" % [CASE_SUFFIX, CASES_DIR])
		get_tree().quit(1)
		return

	print("\n=== MotionFit test suite ===")
	var ran: int = 0
	for path in paths:
		var script: GDScript = load(path) as GDScript
		if script == null:
			_report_load_failure(path, "not a GDScript")
			continue
		var case: TestCase = script.new() as TestCase
		if case == null:
			_report_load_failure(path, "does not extend TestCase")
			continue
		if not only.is_empty() and case.suite_name() != only:
			case.free()
			continue
		ran += 1
		await _run_case(case)

	if not only.is_empty() and ran == 0:
		push_error("TestRunner: no suite named '%s'" % only)
		get_tree().quit(1)
		return

	print("\n--- %d assertion(s), %d failed ---" % [_total, _failed])
	print("RESULT: %s\n" % ("PASS" if _failed == 0 else "FAIL"))
	get_tree().quit(1 if _failed > 0 else 0)


## Runs one case to completion and prints its results. The case is added to the
## tree first so it can await frames and reach the autoloads normally.
func _run_case(case: TestCase) -> void:
	add_child(case)
	print("\n[%s]" % case.suite_name())
	var results: Array[Dictionary] = await case.run()
	for r in results:
		_total += 1
		if bool(r["passed"]):
			print("  PASS  %s" % r["label"])
		else:
			_failed += 1
			var detail: String = String(r["detail"])
			print("  FAIL  %s%s" % [r["label"], ("  (%s)" % detail) if detail else ""])
	if results.is_empty():
		print("  (no assertions)")
	case.queue_free()


# A case that cannot even be loaded is a failure, not a skip — otherwise a typo
# in a test file quietly shrinks the suite and the run still reports PASS.
func _report_load_failure(path: String, why: String) -> void:
	_total += 1
	_failed += 1
	print("  FAIL  %s could not be loaded (%s)" % [path, why])


## Optional suite filter: the first bare command-line argument after `--`.
func _requested_suite() -> String:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	return args[0] if args.size() > 0 else ""


func _find_cases() -> Array[String]:
	var out: Array[String] = []
	var dir: DirAccess = DirAccess.open(CASES_DIR)
	if dir == null:
		push_error("TestRunner: cannot open '%s'" % CASES_DIR)
		return out
	for file in dir.get_files():
		# Exported builds pack text resources as "<name>.remap"; scripts are not
		# remapped, but strip it defensively so the suite also runs from a build.
		var name: String = file.trim_suffix(".remap")
		if name.ends_with(CASE_SUFFIX):
			out.append(CASES_DIR + name)
	out.sort()
	return out
