extends Control
## PauseMenu
##
## A reusable overlay a running game instances (or toggles) to pause. Resume
## hides it and unpauses; Restart replays the current game. Both leave-the-game
## options bank the session first — so pausing out never throws away the calories
## and XP already earned. Uses the SceneTree pause flag and processes while paused.
##
## The two exits are emitted as signals for the game (a MiniGame) to handle, since
## only the game can wrap up and bank its session:
##   • "End & Save"          → [signal end_requested] (bank → Results summary)
##   • "Quit to Game Select" → [signal quit_requested] (bank → launcher)
## MiniGame wires both automatically; see [method MiniGame.attach_pause_menu].

## Emitted when the player chooses "End & Save": bank the session and show Results.
signal end_requested

## Emitted when the player chooses "Quit to Game Select": bank the session, then
## return to the launcher without the Results screen.
signal quit_requested

@onready var _resume_button: Button = %ResumeButton
@onready var _restart_button: Button = %RestartButton
@onready var _end_button: Button = %EndButton
@onready var _quit_button: Button = %QuitButton

func _ready() -> void:
	# Keep responding to input while the tree is paused.
	process_mode = Node.PROCESS_MODE_WHEN_PAUSED
	_resume_button.pressed.connect(_on_resume_pressed)
	_restart_button.pressed.connect(_on_restart_pressed)
	_end_button.pressed.connect(_on_end_pressed)
	_quit_button.pressed.connect(_on_quit_pressed)


## Pauses the game and shows the overlay.
func open() -> void:
	visible = true
	get_tree().paused = true
	# Focus Resume so the menu is immediately keyboard/controller navigable.
	_resume_button.grab_focus()
	# A quick fade-in so the pause reads as a deliberate overlay, not a hard cut.
	modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 1.0, 0.14) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


## Hides the overlay and resumes the game.
func close() -> void:
	visible = false
	get_tree().paused = false


func _on_resume_pressed() -> void:
	close()


func _on_restart_pressed() -> void:
	get_tree().paused = false
	GameManager.start_selected_game()


func _on_end_pressed() -> void:
	end_requested.emit()


func _on_quit_pressed() -> void:
	# Hand off to the game so it banks the session before leaving; the game
	# unpauses and routes to Game Select (see MiniGame._on_pause_quit_requested).
	quit_requested.emit()
