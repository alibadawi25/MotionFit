extends VBoxContainer
class_name ProfileForm
## ProfileForm
##
## Reusable input group for the player's physical attributes — weight, height,
## age and sex — the values calorie estimation depends on (see ProfileManager,
## CONTEXT.md §9). Used by both the first-run onboarding screen and the editable
## profile screen so the widgets, ranges and sex-value mapping live in exactly
## one place.
##
## The rows themselves are authored in scenes/ui/profile_form.tscn (instance it,
## don't `new()` it) — ranges/suffixes are set on the SpinBoxes there and mirror
## the clamps in ProfileManager.set_physical_attributes.

## Emitted whenever any input changes, so listeners (the character preview on
## the profile screen — weight/height reshape the model) can react live.
signal changed

# Option order in the Sex dropdown → the string ProfileManager stores. The last
# entry is the neutral default used when the player prefers not to say. Must
# match the popup items authored on %SexOption.
const SEX_VALUES: Array[String] = ["male", "female", "unspecified"]

@onready var _weight: SpinBox = %WeightSpin
@onready var _height: SpinBox = %HeightSpin
@onready var _age: SpinBox = %AgeSpin
@onready var _sex: OptionButton = %SexOption

func _ready() -> void:
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
