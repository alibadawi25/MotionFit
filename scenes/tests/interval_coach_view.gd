extends Node
## IntervalCoachView
##
## Throwaway view scene for styling the Daily Challenge interval coach (shot.sh
## pairing, like results_view). Stages a synthetic plan with a very short warm-up
## so an ~8s screenshot lands inside the first WORK block — the interesting state
## (phase, countdown, effort meter with its target marker, verdict, next-up and
## progress). No camera streams headless, so the verdict reads the keyboard-only
## "move to hit target" branch, which is exactly what we want to eyeball.

func _ready() -> void:
	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.06, 0.08, 0.12)
	add_child(bg)

	var plan := {
		"blocks": [
			{"kind": "warmup", "seconds": 3, "target_met": 3.0, "label": "WARM UP"},
			{"kind": "work", "seconds": 30, "target_met": 6.0, "label": "PUSH HARD"},
			{"kind": "recover", "seconds": 30, "target_met": 2.5, "label": "RECOVER"},
		],
		"total_sec": 63,
		"push_count": 1,
	}
	var coach := IntervalCoach.new()
	coach.setup(plan)
	add_child(coach)
