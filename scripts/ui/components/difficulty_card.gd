@tool
extends Button
class_name DifficultyCard
## DifficultyCard
##
## One intensity option on the Difficulty Select screen: the level's name, a
## short tag, a 1-3 dot intensity meter and a line of copy promising what the
## workout will feel like.
##
## Every property is an `@export`, so the three cards are authored in
## scenes/menus/difficulty_select.tscn and edited in the inspector — copy
## included. Difficulty semantics are platform-wide (see GameManager.Difficulty),
## and the copy frames each level as a workout promise, not a skill gate: harder
## means a harder workout, never a punishment.

const ACCENT: Color = Color(1, 0.5, 0.14)
const PIP_OFF: Color = Color(1, 1, 1, 0.16)
const HOVER_SCALE: float = 1.04

## Which GameManager.Difficulty this card selects. Matched against the current
## setting to pre-focus the player's usual intensity.
@export_enum("Easy", "Normal", "Hard") var difficulty: int = 1

@export var level_name: String = "NORMAL":
	set(v):
		level_name = v
		if is_node_ready():
			%NameLabel.text = v

@export var tag: String = "STEADY BURN":
	set(v):
		tag = v
		if is_node_ready():
			%TagLabel.text = v

## Filled dots on the intensity meter (1..3) — the at-a-glance ranking between
## the three cards.
@export_range(1, 3) var pips: int = 2:
	set(v):
		pips = v
		if is_node_ready():
			_refresh_pips()

@export_multiline var description: String = "":
	set(v):
		description = v
		if is_node_ready():
			%DescriptionLabel.text = v

func _ready() -> void:
	level_name = level_name
	tag = tag
	pips = pips
	description = description
	if Engine.is_editor_hint():
		return
	resized.connect(func() -> void: pivot_offset = size * 0.5)
	for signal_name in ["mouse_entered", "focus_entered"]:
		connect(signal_name, _animate.bind(HOVER_SCALE))
	for signal_name in ["mouse_exited", "focus_exited"]:
		connect(signal_name, _animate.bind(1.0))


func _refresh_pips() -> void:
	var row: HBoxContainer = %IntensityPips
	for i in row.get_child_count():
		var pip := row.get_child(i) as Label
		pip.add_theme_color_override("font_color", ACCENT if i < pips else PIP_OFF)


func _animate(target: float) -> void:
	var tween := create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "scale", Vector2(target, target), 0.12)
