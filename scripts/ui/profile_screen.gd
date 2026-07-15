extends PanelScreen
## ProfileScreen
##
## Editable player profile: read-only progression (level, XP, lifetime activity),
## editable name + physical attributes (which feed calorie estimation), the body
## calibration status with a Recalibrate action, and a Switch Profile shortcut.
## Uses the same ProfileForm as first-run onboarding so the inputs stay in sync.

var _name_edit: LineEdit
var _form: ProfileForm

func _ready() -> void:
	var box := build_panel("PROFILE", "", 600.0)

	box.add_child(_build_stats())
	box.add_child(HSeparator.new())

	_name_edit = _build_name_row()
	box.add_child(_name_edit.get_parent())

	_form = ProfileForm.new()
	box.add_child(_form)

	box.add_child(_build_calibration_row())
	box.add_child(_build_buttons())


func _build_stats() -> Control:
	# Real lifetime activity, derived from this profile's daily log — no gamification.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 40)
	row.add_child(make_stat_tile("CALORIES", "%d" % int(ActivityManager.get_total_calories()), "kcal"))
	row.add_child(make_stat_tile("STEPS", str(ActivityManager.get_total_steps())))
	row.add_child(make_stat_tile("ACTIVE", "%d" % int(ActivityManager.get_total_active_sec() / 60.0), "min"))
	row.add_child(make_stat_tile("WORKOUTS", str(ActivityManager.get_total_sessions())))
	return row


func _build_name_row() -> LineEdit:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	var label := Label.new()
	label.text = "Name"
	label.custom_minimum_size = Vector2(150, 0)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 22)
	label.add_theme_color_override("font_color", Color(0.86, 0.89, 0.94))
	row.add_child(label)
	var edit := LineEdit.new()
	edit.text = ProfileManager.get_display_name()
	edit.max_length = 20
	edit.custom_minimum_size = Vector2(240, 40)
	row.add_child(edit)
	return edit


## Calibration status + a Recalibrate button, so a player can retune their crouch.
func _build_calibration_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)

	var status := Label.new()
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	status.add_theme_font_size_override("font_size", 17)
	if ProfileManager.has_calibration():
		status.text = "Body calibration:  ✓ done"
		status.add_theme_color_override("font_color", Color(0.45, 0.9, 0.5))
	else:
		status.text = "Body calibration:  not yet — recommended for accurate crouches"
		status.add_theme_color_override("font_color", Color(1, 0.72, 0.3))
	row.add_child(status)

	var recal := Button.new()
	recal.text = "RECALIBRATE" if ProfileManager.has_calibration() else "CALIBRATE"
	recal.custom_minimum_size = Vector2(190, 46)
	# Save name/attrs first so they aren't lost when we leave to calibrate.
	recal.pressed.connect(func():
		_apply_edits()
		SceneManager.load_calibration_setup())
	row.add_child(recal)
	return row


func _build_buttons() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)

	var back_button := Button.new()
	back_button.text = "BACK"
	back_button.custom_minimum_size = Vector2(140, 50)
	back_button.pressed.connect(SceneManager.load_main_menu)
	row.add_child(back_button)

	var switch_button := Button.new()
	switch_button.text = "SWITCH PROFILE"
	switch_button.custom_minimum_size = Vector2(200, 50)
	switch_button.pressed.connect(SceneManager.load_profile_picker)
	row.add_child(switch_button)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	var save_button := Button.new()
	save_button.text = "SAVE"
	save_button.custom_minimum_size = Vector2(160, 50)
	save_button.theme_type_variation = &"PrimaryButton"
	save_button.pressed.connect(_on_save)
	row.add_child(save_button)
	return row


func _apply_edits() -> void:
	ProfileManager.rename_profile("", _name_edit.text)
	_form.apply_to_profile()


func _on_save() -> void:
	_apply_edits()
	SceneManager.load_main_menu()
