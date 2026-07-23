extends Node
## Isolates the Infinite Runner HUD (the stats chip, the closing-dark vignette,
## the prompt and the pre-chase briefing card) over a flat dark backdrop, so the
## 2D layer can be screenshotted and eyeballed without the track, the zombie or a
## live webcam.
## Uses the RunnerHud global rather than load()-ing the script: the HUD extends
## the GameHUD base, and a script loaded by path can't resolve a class_name base
## unless the global class cache is in play anyway.

func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.10, 0.05, 0.06)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var hud: RunnerHud = RunnerHud.new()
	add_child(hud)
	hud.set_stats(0, 0.42)
	hud.set_danger(0.35, 0.0)
	hud.show_briefing()
	hud.set_briefing_countdown(10.0)
