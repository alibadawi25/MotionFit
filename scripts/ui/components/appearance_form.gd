extends VBoxContainer
class_name AppearanceForm
## AppearanceForm
##
## Reusable input group for the character's look — hair/top/bottom styles,
## their colors, and skin tone. Body SHAPE has no inputs here on purpose: it is
## derived from the physical attributes in ProfileForm.
##
## The rows and pickers are authored in scenes/ui/appearance_form.tscn (instance
## it, don't `new()` it), styled to line up with ProfileForm's rows since the two
## stack on the profile screen. Only the picker ITEMS are filled in code: they
## come from CharacterFactory's catalogs (mirroring export_glb.py), so a style
## added to the generator shows up here without touching the scene.

## Emitted whenever any picker changes, so the profile screen can refresh its
## live character preview.
signal changed

## Catalog names → friendlier labels; anything not listed is shown capitalized.
const PRETTY_NAMES: Dictionary = {
	"auto": "Auto (by sex)",
	"tshirt": "T-shirt",
	"longsleeve": "Long sleeve",
	"tank": "Tank top",
}

@onready var _hair: OptionButton = %HairStyleOption
@onready var _hair_color: OptionButton = %HairColorOption
@onready var _top: OptionButton = %TopStyleOption
@onready var _top_color: OptionButton = %TopColorOption
@onready var _bottom: OptionButton = %BottomStyleOption
@onready var _bottom_color: OptionButton = %BottomColorOption
@onready var _skin: OptionButton = %SkinToneOption

func _ready() -> void:
	_fill_options(_hair, CharacterFactory.HAIR_STYLES, {})
	_fill_options(_hair_color, CharacterFactory.HAIR_COLORS.keys(), CharacterFactory.HAIR_COLORS)
	_fill_options(_top, CharacterFactory.TOP_STYLES, {})
	_fill_options(_top_color, CharacterFactory.TOP_COLORS.keys(), CharacterFactory.TOP_COLORS)
	_fill_options(_bottom, CharacterFactory.BOTTOM_STYLES, {})
	_fill_options(_bottom_color, CharacterFactory.BOTTOM_COLORS.keys(), CharacterFactory.BOTTOM_COLORS)
	_fill_options(_skin, CharacterFactory.SKIN_TONES.keys(), CharacterFactory.SKIN_TONES)
	load_from_profile()
	# Wire change notifications AFTER the initial fill so loading doesn't fire.
	for opt in [_hair, _hair_color, _top, _top_color, _bottom, _bottom_color, _skin]:
		(opt as OptionButton).item_selected.connect(func(_i): changed.emit())


## Fills the pickers from the saved profile so the screen shows the current look.
func load_from_profile() -> void:
	var a: Dictionary = ProfileManager.get_appearance()
	_select_named(_hair, String(a["hair"]))
	_select_named(_hair_color, String(a["hair_color"]))
	_select_named(_top, String(a["top"]))
	_select_named(_top_color, String(a["top_color"]))
	_select_named(_bottom, String(a["bottom"]))
	_select_named(_bottom_color, String(a["bottom_color"]))
	_select_named(_skin, String(a["skin"]))


## Persists the current pickers to the active profile.
func apply_to_profile() -> void:
	ProfileManager.set_appearance(get_appearance())


## The current (possibly unsaved) picker state, in the shape CharacterFactory
## expects for its appearance parameter.
func get_appearance() -> Dictionary:
	return {
		"hair": _selected_name(_hair),
		"hair_color": _selected_name(_hair_color),
		"top": _selected_name(_top),
		"top_color": _selected_name(_top_color),
		"bottom": _selected_name(_bottom),
		"bottom_color": _selected_name(_bottom_color),
		"skin": _selected_name(_skin),
	}


# --- Internals ----------------------------------------------------------------

## Fills a scene-authored OptionButton from a CharacterFactory catalog. [param
## names] are the catalog values (stored as item metadata; display text is
## prettified); when [param swatches] maps a name to a Color, the item gets a
## swatch icon.
func _fill_options(opt: OptionButton, names: Array, swatches: Dictionary) -> void:
	opt.clear()
	for name in names:
		var value := String(name)
		if swatches.has(value):
			opt.add_icon_item(_swatch(swatches[value]), _pretty(value))
		else:
			opt.add_item(_pretty(value))
		opt.set_item_metadata(opt.item_count - 1, value)


## The catalog name behind the selected item ("" only if nothing is selected,
## which OptionButton prevents once items exist).
func _selected_name(opt: OptionButton) -> String:
	return String(opt.get_item_metadata(opt.selected)) if opt.selected >= 0 else ""


## Selects the item whose metadata equals [param name]; leaves item 0 selected
## when the save holds a value this build no longer offers.
func _select_named(opt: OptionButton, name: String) -> void:
	for i in opt.item_count:
		if String(opt.get_item_metadata(i)) == name:
			opt.selected = i
			return
	opt.selected = 0


func _pretty(name: String) -> String:
	return String(PRETTY_NAMES.get(name, name.capitalize()))


## A small solid-color square used as the dropdown item's icon.
func _swatch(color: Color) -> Texture2D:
	var img := Image.create(20, 20, false, Image.FORMAT_RGB8)
	img.fill(color)
	return ImageTexture.create_from_image(img)
