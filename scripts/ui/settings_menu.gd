extends PanelScreen
## SettingsMenu
##
## Audio preferences, presented on the shared centred card (see PanelScreen).
## Reads/writes through SettingsManager, which applies and persists each change
## immediately, so this screen only reflects state and forwards edits.
##
## The layout (rows, labels, sliders, buttons) is authored in
## scenes/menus/settings_menu.tscn — this script just seeds the sliders from
## SettingsManager and wires them up.

@onready var _master_slider: HSlider = %MasterSlider
@onready var _master_readout: Label = %MasterReadout
@onready var _music_slider: HSlider = %MusicSlider
@onready var _music_readout: Label = %MusicReadout
@onready var _sfx_slider: HSlider = %SfxSlider
@onready var _sfx_readout: Label = %SfxReadout
@onready var _test_camera_button: Button = %TestCameraButton
@onready var _back_button: Button = %BackButton

func _ready() -> void:
	_bind_slider(_master_slider, _master_readout,
			SettingsManager.get_master_volume(), SettingsManager.set_master_volume)
	_bind_slider(_music_slider, _music_readout,
			SettingsManager.get_music_volume(), SettingsManager.set_music_volume)
	_bind_slider(_sfx_slider, _sfx_readout,
			SettingsManager.get_sfx_volume(), SettingsManager.set_sfx_volume)

	# Camera check-up lives here (it used to crowd the main menu) — it's a
	# setup/diagnostics task, so Settings is its natural home.
	_test_camera_button.pressed.connect(SceneManager.load_camera_test)
	_back_button.pressed.connect(SceneManager.load_main_menu)


## Seeds one scene-authored slider row from SettingsManager and keeps its
## percentage readout in step, forwarding edits to [param setter].
func _bind_slider(slider: HSlider, readout: Label, value: float,
		setter: Callable) -> void:
	slider.set_value_no_signal(value)
	readout.text = _format_pct(value)
	slider.value_changed.connect(setter)
	slider.value_changed.connect(
		func(v: float) -> void: readout.text = _format_pct(v))


func _format_pct(value: float) -> String:
	return "%d%%" % roundi(value * 100.0)
