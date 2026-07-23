extends Node
## TestCase
##
## Base class for the platform's headless self-tests. A test is a script under
## `scenes/tests/cases/` that extends this and overrides [method _run], calling
## the `check_*` helpers; TestRunner discovers every one of them, runs them in a
## single boot, and turns the aggregate into a process exit code.
##
## The point is that the shared systems — save, profile, XP, the registry, the
## result schema — are used by every game at once, so a regression in one of them
## breaks all of them silently. Screenshots can't catch that; assertions can.
##
## [b]Tests run against the REAL autoloads and the REAL save directory.[/b] There
## is no test double layer, because the thing worth testing IS the wiring between
## the managers. That makes cleanup mandatory, not optional: anything a test
## creates it must remove in [method _teardown], which the runner calls even when
## the test fails. Use [method throwaway_profile] for the common case.
class_name TestCase

## One entry per assertion: { passed: bool, label: String, detail: String }.
var _results: Array[Dictionary] = []
# Profiles created via throwaway_profile(), removed again by _teardown_base().
var _throwaway_ids: Array[String] = []
# The profile that was active before this test ran, restored afterwards.
var _original_profile: String = ""


## Human-readable name for this suite, shown in the runner's output. Defaults to
## the script's filename without extension ("save_test").
func suite_name() -> String:
	return get_script().resource_path.get_file().get_basename()


## Runs the case and returns its assertion results. Called by TestRunner; the
## setup/teardown pair runs even if [method _run] fails an assertion, so one
## broken test cannot poison the next by leaving state behind.
func run() -> Array[Dictionary]:
	_results = []
	_original_profile = ProfileManager.get_active_id()
	await _setup()
	await _run()
	await _teardown()
	_teardown_base()
	return _results


## Optional per-test setup. Override for fixtures; default does nothing.
func _setup() -> void:
	pass


## The assertions. Override this — it may await.
func _run() -> void:
	pass


## Optional per-test cleanup. Override to delete anything the test created that
## [method throwaway_profile] doesn't already cover.
func _teardown() -> void:
	pass


# Removes the throwaway profiles and restores the previously active one, so a
# developer running the suite against their own install keeps their profile.
func _teardown_base() -> void:
	for id in _throwaway_ids:
		ProfileManager.delete_profile(id)
	_throwaway_ids.clear()
	if not _original_profile.is_empty() and ProfileManager.get_active_id() != _original_profile:
		ProfileManager.select_profile(_original_profile)


## Creates a scratch profile, makes it active, and registers it for automatic
## deletion when the test ends. Use this for anything that records progression,
## so the assertions run against a known-empty starting state.
func throwaway_profile(label: String = "test") -> String:
	var id: String = ProfileManager.create_profile("__%s_%d__" % [label, _throwaway_ids.size()])
	_throwaway_ids.append(id)
	return id


# --- Assertions -------------------------------------------------------------

## Passes when [param condition] is true.
func check(label: String, condition: bool) -> bool:
	return _record(label, condition, "expected true, got false")


## Passes when [param actual] equals [param expected], reporting both on failure
## (which is the difference between a useful test run and a puzzle).
func check_eq(label: String, actual: Variant, expected: Variant) -> bool:
	return _record(label, actual == expected,
			"expected %s, got %s" % [_show(expected), _show(actual)])


## Passes when [param actual] is within [param epsilon] of [param expected].
## Use for anything the float pipeline touches (calories, cadence, XP curves).
func check_near(label: String, actual: float, expected: float,
		epsilon: float = 0.0001) -> bool:
	return _record(label, absf(actual - expected) <= epsilon,
			"expected %f ± %f, got %f" % [expected, epsilon, actual])


## Records an outright failure with [param detail]. For paths that should be
## unreachable ("loaded a game that does not exist").
func fail(label: String, detail: String = "") -> void:
	_record(label, false, detail)


func _record(label: String, passed: bool, detail: String) -> bool:
	_results.append({
		"passed": passed,
		"label": label,
		"detail": "" if passed else detail,
	})
	return passed


func _show(value: Variant) -> String:
	return "'%s'" % value if value is String else str(value)
