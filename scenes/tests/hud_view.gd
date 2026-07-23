extends Node
## Isolates the Infinite Runner HUD (the stats chip, the closing-dark vignette,
## the prompt and the pre-chase briefing card) over a flat dark backdrop, so the
## 2D layer can be screenshotted and eyeballed without the track, the zombie or a
## live webcam.
## Instances runner_hud.tscn: the HUD's layout lives in the scene now, so a bare
## RunnerHud.new() would come up with no nodes at all.
const HUD_SCENE: PackedScene = preload("res://scenes/runner/runner_hud.tscn")


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.10, 0.05, 0.06)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var hud: RunnerHud = HUD_SCENE.instantiate()
	add_child(hud)
	hud.set_stats(0, 0.42)
	hud.set_danger(0.35, 0.0)
	hud.show_briefing()
	hud.set_briefing_countdown(10.0)
