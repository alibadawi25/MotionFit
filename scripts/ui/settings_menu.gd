extends PanelScreen
## SettingsMenu
##
## Audio preferences, presented on the shared centred card (see
## PanelScreen). Reads/writes through SettingsManager, which applies and persists
## each change immediately, so this screen only reflects state and forwards edits.

const LABEL_COLOR := Color(0.86, 0.89, 0.94)
const ROW_LABEL_WIDTH := 150.0
const VALUE_WIDTH := 56.0

func _ready() -> void:
	var box := build_panel("SETTINGS", "Audio preferences.", 560.0)

	_add_slider_row(box, "Master", SettingsManager.get_master_volume(),
			SettingsManager.set_master_volume)
	_add_slider_row(box, "Music", SettingsManager.get_music_volume(),
			SettingsManager.set_music_volume)
	_add_slider_row(box, "SFX", SettingsManager.get_sfx_volume(),
			SettingsManager.set_sfx_volume)

	box.add_child(HSeparator.new())
	# Camera check-up lives here now (it used to crowd the main menu) — it's a
	# setup/diagnostics task, so Settings is its natural home.
	_add_action_row(box, "Camera", "TEST CAMERA", SceneManager.load_camera_test)

	box.add_child(HSeparator.new())
	box.add_child(_build_back())


## A labelled row whose control is a single action button (mirrors the slider
## rows' label + control layout), used for one-shot actions like opening the
## camera test.
func _add_action_row(box: VBoxContainer, label_text: String, button_text: String,
		action: Callable) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	row.add_child(_row_label(label_text))

	var button := Button.new()
	button.text = button_text
	button.custom_minimum_size = Vector2(0, 44)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(action)
	row.add_child(button)

	box.add_child(row)


## Adds a labelled 0-100% volume slider with a live percentage readout. The
## slider forwards changes to [param setter] (a SettingsManager method).
func _add_slider_row(box: VBoxContainer, label_text: String, value: float,
		setter: Callable) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	row.add_child(_row_label(label_text))

	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.01
	slider.value = value
	slider.custom_minimum_size = Vector2(0, 40)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(slider)

	var readout := Label.new()
	readout.text = _format_pct(value)
	readout.custom_minimum_size = Vector2(VALUE_WIDTH, 0)
	readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	readout.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	readout.add_theme_font_size_override("font_size", 20)
	readout.add_theme_color_override("font_color", ACCENT_TEXT)
	row.add_child(readout)

	slider.value_changed.connect(setter)
	slider.value_changed.connect(
		func(v: float) -> void: readout.text = _format_pct(v))
	box.add_child(row)


func _build_back() -> Control:
	var back_button := Button.new()
	back_button.text = "BACK"
	back_button.custom_minimum_size = Vector2(150, 50)
	back_button.pressed.connect(SceneManager.load_main_menu)
	return back_button


func _row_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(ROW_LABEL_WIDTH, 0)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 22)
	label.add_theme_color_override("font_color", LABEL_COLOR)
	return label


func _format_pct(value: float) -> String:
	return "%d%%" % roundi(value * 100.0)
