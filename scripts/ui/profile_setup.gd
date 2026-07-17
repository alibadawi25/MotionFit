extends PanelScreen
## ProfileSetup
##
## Creates a profile: collects a name and the player's physical attributes, then
## hands off to the (skippable) calibration step. Used both for first-run
## onboarding (no profiles yet) and for "Add profile" from the picker, so every
## person on a shared device gets their own body data and calibration.

var _name_edit: LineEdit
var _form: ProfileForm

func _ready() -> void:
	var box := build_panel("CREATE YOUR PROFILE",
		"Your name and body data stay on this device and give you accurate calories. You can change them anytime.")

	_name_edit = _add_name_row(box)

	_form = ProfileForm.new()
	box.add_child(_form)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 4)
	box.add_child(spacer)

	box.add_child(_build_buttons())
	_name_edit.grab_focus()


func _add_name_row(box: VBoxContainer) -> LineEdit:
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
	edit.placeholder_text = "e.g. Ali"
	edit.max_length = 20
	edit.custom_minimum_size = Vector2(240, 40)
	row.add_child(edit)
	box.add_child(row)
	return edit


func _build_buttons() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)

	# A way back to the picker only makes sense once other profiles exist (i.e.
	# this is "Add profile", not first-run onboarding which must create one).
	# On first run there's no picker to return to, so offer QUIT instead — this
	# is the very first screen and would otherwise be a dead end.
	if ProfileManager.has_profiles():
		var back := Button.new()
		back.text = "BACK"
		back.custom_minimum_size = Vector2(150, 54)
		back.pressed.connect(SceneManager.load_profile_picker)
		row.add_child(back)
	else:
		var quit := Button.new()
		quit.text = "QUIT"
		quit.custom_minimum_size = Vector2(150, 54)
		quit.pressed.connect(func(): get_tree().quit())
		row.add_child(quit)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	var continue_button := Button.new()
	continue_button.text = "CONTINUE"
	continue_button.custom_minimum_size = Vector2(220, 54)
	continue_button.theme_type_variation = &"PrimaryButton"
	continue_button.pressed.connect(_on_continue)
	row.add_child(continue_button)
	return row


func _unhandled_input(event: InputEvent) -> void:
	# Escape mirrors the row's leading button: back to the picker when one exists,
	# otherwise quit the app (first-run onboarding has nowhere to go back to).
	if event.is_action_pressed("ui_cancel"):
		if ProfileManager.has_profiles():
			SceneManager.load_profile_picker()
		else:
			get_tree().quit()
		get_viewport().set_input_as_handled()


func _on_continue() -> void:
	ProfileManager.create_profile(_name_edit.text)  # becomes the active profile
	_form.apply_to_profile()
	ProfileManager.mark_onboarded()
	SceneManager.profile_chosen_this_session = true
	# Straight into the optional calibration step (it can be skipped).
	SceneManager.load_calibration_setup()
