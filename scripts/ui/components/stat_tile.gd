@tool
extends VBoxContainer
class_name StatTile
## StatTile
##
## The platform's standard "one number, one label" tile: a bright accent value,
## an optional small unit beside it, and a caption underneath. Used across the
## Profile, Fitness and Main Menu dashboards so every headline figure reads the
## same way.
##
## Instance `scenes/ui/components/stat_tile.tscn` and set [member caption] /
## [member unit] in the inspector; the screen's script writes [member value] at
## runtime. `@tool`, so edits show live in the editor.

## The small caps label under the number ("CALORIES", "STREAK").
@export var caption: String = "CAPTION":
	set(v):
		caption = v
		if is_node_ready():
			%CaptionLabel.text = v

## The figure itself. Screens set this from their manager.
@export var value: String = "0":
	set(v):
		value = v
		if is_node_ready():
			%ValueLabel.text = v

## Optional unit beside the value ("kcal", "days"). Empty hides it.
@export var unit: String = "":
	set(v):
		unit = v
		if is_node_ready():
			%UnitLabel.text = v
			%UnitLabel.visible = v != ""

## Accent of the value text — gold once a goal is met, for instance.
@export var value_color: Color = Color(1, 0.64, 0.3):
	set(v):
		value_color = v
		if is_node_ready():
			%ValueLabel.add_theme_color_override("font_color", v)

func _ready() -> void:
	# Re-apply the exports now the child nodes exist (setters no-op before this).
	caption = caption
	value = value
	unit = unit
	value_color = value_color
