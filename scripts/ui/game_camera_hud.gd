extends CanvasLayer
## GameCameraHUD
##
## A persistent little camera window shown in the top-right corner during play, so
## the player can always see themselves the way the game sees them. It picks up
## right where [GameIntro]'s countdown thumbnail left off (same corner, same size),
## so the mirror feels continuous from setup into the game.
##
## Beyond a mirror, it coaches: when the pose service reports the player has
## drifted out of a good stance (stepped too close, legs out of frame, leaning),
## it surfaces that hint right under the thumbnail — [MotionManager.get_ready_hint]
## — so they can fix their framing mid-game without pausing, and keep tracking
## accurate. When everything's good it shows a calm "TRACKING" tick.
##
## It's a reusable component with no per-game code: [MiniGame] instantiates
## scenes/ui/game_camera_hud.tscn after the intro, so every game gets the in-game
## camera for free. The mirror itself is the shared [CameraMirror] component, so
## it reads the picture from [CameraPreview] and Godot does no vision (§9). With
## no pose service running nothing streams, so the whole widget simply hides — the
## platform stays fully playable keyboard-only. Press C to hide/show it.
class_name GameCameraHUD

const TRACKING_COLOR: Color = Color(0.45, 0.9, 0.5)
const WARN_COLOR: Color = Color(1.0, 0.72, 0.3)

@onready var _root: Control = %Root
@onready var _mirror: CameraMirror = %CameraMirror
@onready var _hint: Label = %HintLabel

var _hidden_by_user: bool = false

func _process(_delta: float) -> void:
	# Nothing to show without a live feed (keyboard-only play): hide the widget so
	# it never presents a dark rectangle claiming to be the camera.
	_root.visible = _mirror.is_live() and not _hidden_by_user
	if not _root.visible:
		return

	# Coach on the pose service's readiness: an amber fix when the stance drifts
	# (out of frame, too close, legs hidden), a calm green tick when it's clean.
	var hint: String = MotionManager.get_ready_hint()
	var color: Color = WARN_COLOR if not hint.is_empty() else TRACKING_COLOR
	_hint.text = hint if not hint.is_empty() else "✓  TRACKING"
	_hint.add_theme_color_override("font_color", color)
	_mirror.set_frame_color(color)


## C toggles the mirror off/on, for players who'd rather not watch themselves. Uses
## a raw key check so it needs no project input action.
func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode == KEY_C:
		_hidden_by_user = not _hidden_by_user
		get_viewport().set_input_as_handled()
