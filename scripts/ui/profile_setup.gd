extends PanelScreen
## ProfileSetup
##
## First-run onboarding. Collects the player's physical attributes once so
## calorie estimation isn't stuck on neutral defaults, then marks the profile
## onboarded and enters the main menu. Only shown while ProfileManager reports
## the profile is not yet onboarded (gated by the main menu); it can be revisited
## later through the editable profile screen.

func _ready() -> void:
	var box := build_panel("TELL US ABOUT YOU",
		"We use this to estimate your calories accurately. You can change it anytime.")

	var form := ProfileForm.new()
	box.add_child(form)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 4)
	box.add_child(spacer)

	var continue_button := Button.new()
	continue_button.text = "CONTINUE"
	continue_button.custom_minimum_size = Vector2(0, 54)
	continue_button.theme_type_variation = &"PrimaryButton"
	continue_button.pressed.connect(_on_continue.bind(form))
	box.add_child(continue_button)
	continue_button.grab_focus()


func _on_continue(form: ProfileForm) -> void:
	form.apply_to_profile()
	ProfileManager.mark_onboarded()
	SceneManager.load_main_menu()
