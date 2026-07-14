extends PanelScreen
## ProfileScreen
##
## Editable player profile: shows read-only progression (level, XP, lifetime
## calories) and lets the player update the physical attributes that feed calorie
## estimation. Reachable from the main menu. Uses the same ProfileForm as the
## first-run onboarding screen so the inputs stay in sync.

func _ready() -> void:
	var box := build_panel("PROFILE", "", 600.0)

	box.add_child(_build_stats())
	box.add_child(HSeparator.new())

	var form := ProfileForm.new()
	box.add_child(form)

	box.add_child(_build_buttons(form))


func _build_stats() -> Control:
	# Real lifetime activity, derived from the daily log — no gamification here.
	# Everything is 0 until the player finishes real sessions, then it grows.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 40)
	row.add_child(make_stat_tile("CALORIES", "%d" % int(ActivityManager.get_total_calories()), "kcal"))
	row.add_child(make_stat_tile("STEPS", str(ActivityManager.get_total_steps())))
	row.add_child(make_stat_tile("ACTIVE", "%d" % int(ActivityManager.get_total_active_sec() / 60.0), "min"))
	row.add_child(make_stat_tile("WORKOUTS", str(ActivityManager.get_total_sessions())))
	return row


func _build_buttons(form: ProfileForm) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)

	var back_button := Button.new()
	back_button.text = "BACK"
	back_button.custom_minimum_size = Vector2(150, 50)
	back_button.pressed.connect(SceneManager.load_main_menu)
	row.add_child(back_button)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	var save_button := Button.new()
	save_button.text = "SAVE"
	save_button.custom_minimum_size = Vector2(200, 50)
	save_button.theme_type_variation = &"PrimaryButton"
	save_button.pressed.connect(_on_save.bind(form))
	row.add_child(save_button)
	return row


func _on_save(form: ProfileForm) -> void:
	form.apply_to_profile()
	SceneManager.load_main_menu()
