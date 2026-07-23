extends PanelScreen
## ProfileSetup
##
## Creates a profile: collects a name and the player's physical attributes, then
## hands off to the (skippable) calibration step. Used both for first-run
## onboarding (no profiles yet) and for "Add profile" from the picker, so every
## person on a shared device gets their own body data and calibration.
##
## Layout lives in scenes/menus/profile_setup.tscn. Both leading buttons (BACK
## and QUIT) are authored there and this script shows exactly one of them.

@onready var _name_edit: LineEdit = %NameEdit
@onready var _form: ProfileForm = %BodyForm
@onready var _back_button: Button = %BackButton
@onready var _quit_button: Button = %QuitButton
@onready var _continue_button: Button = %ContinueButton

func _ready() -> void:
	# A way back to the picker only makes sense once other profiles exist (i.e.
	# this is "Add profile", not first-run onboarding which must create one). On
	# first run there's no picker to return to, so offer QUIT instead — this is
	# the very first screen and would otherwise be a dead end.
	var has_profiles: bool = ProfileManager.has_profiles()
	_back_button.visible = has_profiles
	_quit_button.visible = not has_profiles

	_back_button.pressed.connect(SceneManager.load_profile_picker)
	_quit_button.pressed.connect(func(): get_tree().quit())
	_continue_button.pressed.connect(_on_continue)
	_name_edit.grab_focus()


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
