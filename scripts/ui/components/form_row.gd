@tool
extends HBoxContainer
class_name FormRow
## FormRow
##
## One labelled settings/profile row: a fixed-width caption on the left, then
## whatever control the screen drops in beside it. Every form row on the
## platform (weight, height, master volume, name, …) is one of these, so the
## label column stays aligned across screens.
##
## Instance `scenes/ui/components/form_row.tscn`, set [member label_text], and
## add the control as a child of the instance — it lands to the right of the
## label automatically. `@tool`, so the label updates live in the editor.

## The row's caption. Sentence case ("Weight", "Master") — these read as form
## fields, not headings.
@export var label_text: String = "Label":
	set(v):
		label_text = v
		if is_node_ready():
			%RowLabel.text = v

## Width of the label column. Rows sharing a screen must agree, so this is
## exposed rather than hard-coded.
@export var label_width: float = 150.0:
	set(v):
		label_width = v
		if is_node_ready():
			%RowLabel.custom_minimum_size.x = v

func _ready() -> void:
	label_text = label_text
	label_width = label_width
