extends VBoxContainer
class_name ProfileForm
## ProfileForm
##
## Reusable input group for the player's physical attributes — weight, height,
## age and sex — the values calorie estimation depends on (see ProfileManager,
## CONTEXT.md §9). Used by both the first-run onboarding screen and the editable
## profile screen so the widgets, ranges and sex-value mapping live in exactly
## one place. Ranges mirror the clamps in ProfileManager.set_physical_attributes.

## Emitted whenever any input changes, so listeners (the character preview on
## the profile screen — weight/height reshape the model) can react live.
signal changed

const LABEL_COLOR := Color(0.86, 0.89, 0.94)
const ROW_LABEL_WIDTH := 150.0
const INPUT_WIDTH := 240.0

# Option order in the Sex dropdown → the string ProfileManager stores. The last
# entry is the neutral default used when the player prefers not to say.
const SEX_VALUES: Array[String] = ["male", "female", "unspecified"]

var _weight: SpinBox
var _height: SpinBox
var _age: SpinBox
var _sex: OptionButton

func _ready() -> void:
	add_theme_constant_override("separation", 16)
	_weight = _add_spin_row("Weight", 20.0, 300.0, 0.5, " kg")
	_height = _add_spin_row("Height", 80.0, 250.0, 1.0, " cm")
	_age = _add_spin_row("Age", 5.0, 120.0, 1.0, " yr")
	_sex = _add_sex_row("Sex")
	load_from_profile()
	# Wire change notifications AFTER the initial fill so loading doesn't fire.
	for spin in [_weight, _height, _age]:
		spin.value_changed.connect(func(_v): changed.emit())
	_sex.item_selected.connect(func(_i): changed.emit())


## Fills the inputs from the saved profile so an edit screen shows current values.
func load_from_profile() -> void:
	_weight.value = ProfileManager.get_weight_kg()
	_height.value = ProfileManager.get_height_cm()
	_age.value = ProfileManager.get_age()
	var idx: int = SEX_VALUES.find(ProfileManager.get_sex())
	_sex.selected = idx if idx >= 0 else SEX_VALUES.find("unspecified")


## Persists the current inputs to the profile. Values are clamped to human ranges
## inside ProfileManager, so the widgets only need sensible min/max for feel.
func apply_to_profile() -> void:
	ProfileManager.set_physical_attributes(
		_weight.value, _height.value, int(_age.value), SEX_VALUES[_sex.selected])


## The current (possibly unsaved) inputs, in the shape CharacterFactory expects
## for its body parameter — lets the profile screen preview the model live.
func get_attributes() -> Dictionary:
	return {
		"sex": SEX_VALUES[_sex.selected],
		"age": int(_age.value),
		"height_cm": _height.value,
		"weight_kg": _weight.value,
	}


func _add_spin_row(label_text: String, min_v: float, max_v: float,
		step: float, suffix: String) -> SpinBox:
	var row := _make_row(label_text)
	var spin := SpinBox.new()
	spin.min_value = min_v
	spin.max_value = max_v
	spin.step = step
	spin.suffix = suffix
	spin.alignment = HORIZONTAL_ALIGNMENT_CENTER
	spin.custom_minimum_size = Vector2(INPUT_WIDTH, 40)
	row.add_child(spin)
	return spin


func _add_sex_row(label_text: String) -> OptionButton:
	var row := _make_row(label_text)
	var opt := OptionButton.new()
	opt.add_item("Male")        # -> SEX_VALUES[0]
	opt.add_item("Female")      # -> SEX_VALUES[1]
	opt.add_item("Prefer not to say")  # -> SEX_VALUES[2] ("unspecified")
	opt.custom_minimum_size = Vector2(INPUT_WIDTH, 40)
	row.add_child(opt)
	return opt


func _make_row(label_text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(ROW_LABEL_WIDTH, 0)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 22)
	label.add_theme_color_override("font_color", LABEL_COLOR)
	row.add_child(label)
	add_child(row)
	return row
