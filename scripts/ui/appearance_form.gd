extends VBoxContainer
class_name AppearanceForm
## AppearanceForm
##
## Reusable input group for the character's look — hair/top/bottom styles,
## their colors, and skin tone. Options and swatch colors come from
## CharacterFactory's catalogs (mirroring export_glb.py), so a style added to
## the generator shows up here by updating one place. Body SHAPE has no inputs
## here on purpose: it is derived from the physical attributes in ProfileForm.
##
## Styled to line up with ProfileForm rows, since the two stack on the profile
## screen.

## Emitted whenever any picker changes, so the profile screen can refresh its
## live character preview.
signal changed

const LABEL_COLOR := Color(0.86, 0.89, 0.94)
const ROW_LABEL_WIDTH := 150.0
## Style and color pickers share a row (Hair: [style][color]) to keep the form
## short enough that the profile screen fits 1080p with the preview beside it.
const STYLE_WIDTH := 190.0
const COLOR_WIDTH := 160.0

## Catalog names → friendlier labels; anything not listed is shown capitalized.
const PRETTY_NAMES: Dictionary = {
	"auto": "Auto (by sex)",
	"tshirt": "T-shirt",
	"longsleeve": "Long sleeve",
	"tank": "Tank top",
}

var _hair: OptionButton
var _hair_color: OptionButton
var _top: OptionButton
var _top_color: OptionButton
var _bottom: OptionButton
var _bottom_color: OptionButton
var _skin: OptionButton

func _ready() -> void:
	add_theme_constant_override("separation", 16)
	var hair_row := _make_row("Hair")
	_hair = _add_options(hair_row, CharacterFactory.HAIR_STYLES, {}, STYLE_WIDTH)
	_hair_color = _add_options(hair_row,
			CharacterFactory.HAIR_COLORS.keys(), CharacterFactory.HAIR_COLORS, COLOR_WIDTH)
	var top_row := _make_row("Top")
	_top = _add_options(top_row, CharacterFactory.TOP_STYLES, {}, STYLE_WIDTH)
	_top_color = _add_options(top_row,
			CharacterFactory.TOP_COLORS.keys(), CharacterFactory.TOP_COLORS, COLOR_WIDTH)
	var bottom_row := _make_row("Bottom")
	_bottom = _add_options(bottom_row, CharacterFactory.BOTTOM_STYLES, {}, STYLE_WIDTH)
	_bottom_color = _add_options(bottom_row,
			CharacterFactory.BOTTOM_COLORS.keys(), CharacterFactory.BOTTOM_COLORS, COLOR_WIDTH)
	var skin_row := _make_row("Skin tone")
	_skin = _add_options(skin_row,
			CharacterFactory.SKIN_TONES.keys(), CharacterFactory.SKIN_TONES, STYLE_WIDTH)
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

## Builds a labelled row (matching ProfileForm's row styling) that pickers are
## then appended to via [method _add_options].
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


## Appends an OptionButton to [param row]. [param names] are the catalog values
## (stored as item metadata; display text is prettified); when [param swatches]
## maps a name to a Color, the item gets a swatch icon.
func _add_options(row: HBoxContainer, names: Array, swatches: Dictionary,
		width: float) -> OptionButton:
	var opt := OptionButton.new()
	opt.custom_minimum_size = Vector2(width, 40)
	for name in names:
		var value := String(name)
		if swatches.has(value):
			opt.add_icon_item(_swatch(swatches[value]), _pretty(value))
		else:
			opt.add_item(_pretty(value))
		opt.set_item_metadata(opt.item_count - 1, value)
	row.add_child(opt)
	return opt


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
