extends Node
## BoxingInputProbe
##
## Headless self-test for the pose-event plumbing. Run with:
##   Godot --headless --path . res://scenes/tests/boxing_input_probe.tscn --quit-after 40
##
## Boxing's punch/guard/slip used to be hard-coded accessors on [MotionManager];
## they now go through the generic watch/consume pose-event channel plus
## [BoxingInput]. That path has no visual surface — a HUD screenshot proves
## nothing about it — so it gets a real test instead: synthetic packets are fed
## through MotionManager's own packet handler and read back through BoxingInput
## exactly as boxing.gd reads them.
##
## Prints PASS/FAIL lines; exits via quit() with a non-zero code on failure.

var _failures: int = 0


func _ready() -> void:
	var input := BoxingInput.new()

	# A packet with a left hook thrown at 0.8 power, gloves up, slipping left.
	_packet({
		"punch": "left", "punch_power": 0.8, "punch_kind": "hook",
		"guard": true, "lean": -0.6,
	})
	_check("punch hand latched", input.consume_punch(), "left")
	_check("punch power captured", input.get_last_punch_power(), 0.8)
	_check("punch shape captured", input.get_last_punch_kind(), "hook")
	_check("guard reads through", input.is_guarding(), true)
	_check("lean reads through", input.get_lean(), -0.6)

	# The latch is one-shot: a second read in the same frame sees nothing.
	_check("punch latch cleared", input.consume_punch(), "")

	# Power and shape must survive later packets that carry no punch — they
	# describe the throw that was consumed, not whatever arrived since.
	_packet({"guard": false, "lean": 0.0, "punch_power": 0.1,
			"punch_kind": "straight"})
	_check("no phantom punch", input.consume_punch(), "")
	_check("power still the thrown one", input.get_last_punch_power(), 0.8)
	_check("shape still the thrown one", input.get_last_punch_kind(), "hook")
	_check("guard released", input.is_guarding(), false)

	# A punch landing between polls must not be lost: two packets, one read.
	_packet({"punch": "right", "punch_power": 0.5, "punch_kind": "uppercut"})
	_packet({"punch": "", "guard": true})
	_check("punch survives a later packet", input.consume_punch(), "right")
	_check("its power survived too", input.get_last_punch_power(), 0.5)
	_check("its shape survived too", input.get_last_punch_kind(), "uppercut")

	# An older pose build sends no boxing fields at all: read as "not defending"
	# rather than erroring.
	_packet({"forward": 0.3})
	_check("absent guard defaults false", input.is_guarding(), false)
	_check("absent lean defaults zero", input.get_lean(), 0.0)

	# Lean is clamped to the documented -1..1 even if the service overshoots.
	_packet({"lean": -2.5})
	_check("lean clamped low", input.get_lean(), -1.0)
	_packet({"lean": 2.5})
	_check("lean clamped high", input.get_lean(), 1.0)

	# reset_session_stats drops leftovers so a bout can't open on a phantom hit
	# thrown at the setup screen.
	_packet({"punch": "left", "punch_power": 0.9, "punch_kind": "straight"})
	MotionManager.reset_session_stats()
	_check("session reset drops the latch", input.consume_punch(), "")

	if _failures == 0:
		print("PASS — all boxing input checks passed")
	else:
		print("FAIL — %d boxing input check(s) failed" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)


## Feeds [param data] through the real packet handler, exactly as an arriving
## UDP frame would.
func _packet(data: Dictionary) -> void:
	MotionManager._apply(data)


func _check(what: String, got: Variant, expected: Variant) -> void:
	var ok: bool = (is_equal_approx(got, expected)
			if got is float and expected is float else got == expected)
	if ok:
		print("  ok   %s" % what)
	else:
		_failures += 1
		print("  FAIL %s — got %s, expected %s" % [what, got, expected])
