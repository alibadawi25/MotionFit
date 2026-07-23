extends PanelScreen
## ProfileScreen
##
## Editable player profile: read-only progression (level, XP, lifetime activity),
## editable name + physical attributes (which feed calorie estimation), character
## appearance with a live 3D preview, the body calibration status with a
## Recalibrate action, and a Switch Profile shortcut. Uses the same ProfileForm
## as first-run onboarding so the inputs stay in sync.
##
## The whole layout — stat tiles, name row, the two editor columns, the preview
## and the button row — is authored in scenes/menus/profile_screen.tscn. This
## script fills in the live numbers and wires the actions.

## Debounce before regenerating the preview model, so spinning a SpinBox doesn't
## run the (~0.15 s, blocking) Python generator on every tick.
const PREVIEW_DEBOUNCE: float = 0.35

@onready var _calories_value: Label = %CaloriesValue
@onready var _steps_value: Label = %StepsValue
@onready var _active_value: Label = %ActiveValue
@onready var _workouts_value: Label = %WorkoutsValue
@onready var _name_edit: LineEdit = %NameEdit
@onready var _form: ProfileForm = %BodyForm
@onready var _appearance: AppearanceForm = %AppearanceForm
@onready var _preview: CharacterPreview = %CharacterPreview
@onready var _calibration_status: Label = %CalibrationStatusLabel
@onready var _recalibrate_button: Button = %RecalibrateButton
@onready var _back_button: Button = %BackButton
@onready var _switch_button: Button = %SwitchProfileButton
@onready var _save_button: Button = %SaveButton

var _preview_timer: Timer

func _ready() -> void:
	_fill_stats()
	_name_edit.text = ProfileManager.get_display_name()
	_fill_calibration_row()

	_back_button.pressed.connect(SceneManager.load_main_menu)
	_switch_button.pressed.connect(SceneManager.load_profile_picker)
	_save_button.pressed.connect(_on_save)
	# Save name/attrs first so they aren't lost when we leave to calibrate.
	_recalibrate_button.pressed.connect(func():
		_apply_edits()
		SceneManager.load_calibration_setup())

	# Any edit re-renders the preview after a short debounce; body attributes
	# matter too because weight/height reshape the model.
	_preview_timer = Timer.new()
	_preview_timer.one_shot = true
	_preview_timer.wait_time = PREVIEW_DEBOUNCE
	_preview_timer.timeout.connect(_refresh_preview)
	add_child(_preview_timer)
	_form.changed.connect(_preview_timer.start)
	_appearance.changed.connect(_preview_timer.start)
	_refresh_preview()


## Real lifetime activity, derived from this profile's daily log — no gamification.
func _fill_stats() -> void:
	_calories_value.text = "%d" % int(ActivityManager.get_total_calories())
	_steps_value.text = str(ActivityManager.get_total_steps())
	_active_value.text = "%d" % int(ActivityManager.get_total_active_sec() / 60.0)
	_workouts_value.text = str(ActivityManager.get_total_sessions())


## Calibration status + the Recalibrate button's wording, so a player can see at
## a glance whether their crouch is tuned and retune it.
func _fill_calibration_row() -> void:
	if ProfileManager.has_calibration():
		_calibration_status.text = "Body calibration:  ✓ done"
		_calibration_status.add_theme_color_override("font_color", Color(0.45, 0.9, 0.5))
		_recalibrate_button.text = "RECALIBRATE"
	else:
		_calibration_status.text = "Body calibration:  not yet — recommended for accurate crouches"
		_calibration_status.add_theme_color_override("font_color", Color(1, 0.72, 0.3))
		_recalibrate_button.text = "CALIBRATE"


## Regenerates the preview model from the CURRENT (unsaved) inputs and shows it.
func _refresh_preview() -> void:
	var figure: Node3D = CharacterFactory.build_preview(
		_form.get_attributes(), _appearance.get_appearance())
	if figure != null:
		_preview.show_figure(figure)


func _apply_edits() -> void:
	ProfileManager.rename_profile("", _name_edit.text)
	_form.apply_to_profile()
	_appearance.apply_to_profile()


func _on_save() -> void:
	_apply_edits()
	SceneManager.load_main_menu()
