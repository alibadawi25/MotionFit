extends Control
## CountdownScreen
##
## Shown between selecting a game and playing it. Counts 3-2-1-Go, then asks
## GameManager to launch the selected game's scene. Keeps the "get ready"
## moment identical for every game.

@onready var _label: Label = %CountLabel

const START_FROM: int = 3
const TICK_SECONDS: float = 1.0

var _remaining: int = START_FROM

func _ready() -> void:
	_show(_remaining)
	var timer := Timer.new()
	timer.wait_time = TICK_SECONDS
	timer.autostart = true
	timer.timeout.connect(_on_tick)
	add_child(timer)


func _on_tick() -> void:
	_remaining -= 1
	if _remaining > 0:
		_show(_remaining)
	elif _remaining == 0:
		_label.text = "Go!"
	else:
		GameManager.launch_current_game_scene()


func _show(value: int) -> void:
	_label.text = str(value)
