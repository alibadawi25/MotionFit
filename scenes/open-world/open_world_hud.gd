extends CanvasLayer
## OpenWorldHud
##
## The Open World game's on-screen stats: a centred row of dark chips
## (TIME · CALORIES · STEPS · ORBS · SECRETS) over a subtle bottom hint. Built in code so it
## matches the shared menu look (dark chips, orange accent) without a paired
## scene. It owns no game state — the game feeds it live numbers via
## [method set_stats] and asks for the pickup pop via [method pulse_orbs].
class_name OpenWorldHud

const ACCENT: Color = Color(1.0, 0.5, 0.14)
const TEXT: Color = Color(0.96, 0.97, 0.99)
const MUTED: Color = Color(0.72, 0.76, 0.82)

## Maps a stat key ("time"/"calories"/"steps"/"orbs") to its value Label so
## [method set_stats] can refresh each chip without rebuilding the bar.
var _values: Dictionary = {}
var _anton: Font
## The TURN BACK prompt shown at the world's fog border (see [method set_border_warning]).
var _warning: Control
## How deep into the border band the player is (0..1), as last reported. Drives
## the prompt's fade and its pulse.
var _haze: float = 0.0
## The heart-rate chip (hidden until a wearable streams bpm — see set_heart_rate).
var _hr_chip: Control
## The "DISCOVERED — ..." banner (see [method show_discovery]) and its fade tween.
var _discovery: Control
var _discovery_name: Label
var _discovery_tween: Tween
## Last secrets-found count, so [method set_secrets] only pulses on a new find.
var _secrets_shown: int = 0


func _ready() -> void:
	_anton = load("res://assets/fonts/Anton-Regular.ttf")
	_build()


## Lays out the top stat bar (a centred row of chips) and a subtle bottom hint.
func _build() -> void:
	var bar := HBoxContainer.new()
	bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	bar.offset_top = 22.0
	bar.offset_bottom = 118.0  # a real height so the container lays chips out
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.add_theme_constant_override("separation", 12)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bar)

	bar.add_child(_make_chip("time", "TIME", TEXT))
	bar.add_child(_make_chip("calories", "CALORIES", ACCENT))
	bar.add_child(_make_chip("steps", "STEPS", TEXT))
	bar.add_child(_make_chip("orbs", "ORBS", ACCENT))
	bar.add_child(_make_chip("secrets", "SECRETS", TEXT))
	# Live bpm from a heart-rate strap. Hidden until a wearable streams — most
	# players have none, and an empty chip would read as something broken.
	_hr_chip = _make_chip("hr", "♥ BPM", Color(0.95, 0.45, 0.5))
	_hr_chip.visible = false
	bar.add_child(_hr_chip)

	var hint := Label.new()
	hint.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	hint.offset_bottom = -22.0
	hint.offset_top = -52.0
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 16)
	hint.add_theme_color_override("font_color", Color(0.82, 0.85, 0.9, 0.62))
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.text = "ESC — PAUSE  /  END & SAVE"
	add_child(hint)

	_warning = _make_warning()
	add_child(_warning)

	_discovery = _make_discovery()
	add_child(_discovery)


## One HUD chip: a small caps caption over a large branded value, on a dark
## rounded card. Registers its value Label under [param key] for live updates.
func _make_chip(key: String, caption: String, color: Color) -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(132, 0)
	panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER  # snug height, centred in the bar
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.08, 0.12, 0.72)
	sb.set_corner_radius_all(14)
	sb.set_border_width_all(1)
	sb.border_color = Color(1, 1, 1, 0.09)
	sb.content_margin_left = 20
	sb.content_margin_right = 20
	sb.content_margin_top = 10
	sb.content_margin_bottom = 12
	sb.shadow_color = Color(0, 0, 0, 0.3)
	sb.shadow_size = 10
	panel.add_theme_stylebox_override("panel", sb)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 0)
	panel.add_child(vbox)

	var cap := Label.new()
	cap.text = caption
	cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cap.add_theme_font_size_override("font_size", 13)
	cap.add_theme_color_override("font_color", MUTED)
	vbox.add_child(cap)

	var value := Label.new()
	value.text = "0"
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	value.add_theme_font_override("font", _anton)
	value.add_theme_font_size_override("font_size", 34)
	value.add_theme_color_override("font_color", color)
	vbox.add_child(value)

	_values[key] = value
	return panel


## The border prompt: a big accent TURN BACK over a quiet line of reason. Built
## hidden and centred a little above the middle of the screen, clear of the stat
## bar and of the figure the player is watching.
func _make_warning() -> Control:
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 2)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	box.position = Vector2(0, -120)
	box.modulate.a = 0.0
	box.visible = false

	var title := Label.new()
	title.text = "TURN BACK"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_override("font", _anton)
	title.add_theme_font_size_override("font_size", 52)
	title.add_theme_color_override("font_color", ACCENT)
	# The fog behind this is near-white at full haze, which is exactly where the
	# text needs to be readable — so it carries its own shadow rather than trusting
	# the backdrop.
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.55))
	title.add_theme_constant_override("shadow_offset_y", 3)
	title.add_theme_constant_override("shadow_outline_size", 8)
	box.add_child(title)

	var reason := Label.new()
	reason.text = "THE FOG IS TOO THICK THIS WAY"
	reason.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	reason.add_theme_font_size_override("font_size", 17)
	reason.add_theme_color_override("font_color", TEXT)
	reason.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.5))
	reason.add_theme_constant_override("shadow_offset_y", 2)
	box.add_child(reason)
	return box


## The discovery banner: a quiet DISCOVERED caption over the found landmark's
## big name — same centre placement family as the border warning, parked a
## little higher so the two could coexist without stacking on each other.
func _make_discovery() -> Control:
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 2)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	box.position = Vector2(0, -190)
	box.modulate.a = 0.0
	box.visible = false

	var caption := Label.new()
	caption.text = "DISCOVERED"
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.add_theme_font_size_override("font_size", 17)
	caption.add_theme_color_override("font_color", ACCENT)
	caption.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.5))
	caption.add_theme_constant_override("shadow_offset_y", 2)
	box.add_child(caption)

	_discovery_name = Label.new()
	_discovery_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_discovery_name.add_theme_font_override("font", _anton)
	_discovery_name.add_theme_font_size_override("font_size", 44)
	_discovery_name.add_theme_color_override("font_color", TEXT)
	_discovery_name.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.55))
	_discovery_name.add_theme_constant_override("shadow_offset_y", 3)
	_discovery_name.add_theme_constant_override("shadow_outline_size", 8)
	box.add_child(_discovery_name)
	return box


## Announces a found secret: fades the banner in with the landmark's name,
## holds it long enough to read, and fades it back out. A new find mid-fade
## simply restarts the banner with the new name.
func show_discovery(title: String) -> void:
	if _discovery == null:
		return
	_discovery_name.text = title
	_discovery.visible = true
	_discovery.modulate.a = 0.0
	if _discovery_tween != null:
		_discovery_tween.kill()
	_discovery_tween = create_tween()
	_discovery_tween.tween_property(_discovery, "modulate:a", 1.0, 0.35)
	_discovery_tween.tween_interval(2.6)
	_discovery_tween.tween_property(_discovery, "modulate:a", 0.0, 0.8)
	_discovery_tween.tween_callback(func() -> void: _discovery.visible = false)


## Refreshes the SECRETS chip ("found/total"), with the pickup pop whenever the
## count grows — set_stats-style calls with an unchanged count stay silent.
func set_secrets(found: int, total: int) -> void:
	var value: Label = _values.get("secrets")
	if value == null:
		return
	value.text = "%d/%d" % [found, total]
	if found > _secrets_shown:
		_pulse_value(value)
	_secrets_shown = found


## Reports how deep into the world's fog border the player is (0..1, from
## [method WorldBorder.get_haze]) so the prompt can fade in with it — the same
## number the fog and the movement resistance run on, so the text arrives exactly
## as the world starts refusing.
func set_border_warning(haze: float) -> void:
	_haze = clampf(haze, 0.0, 1.0)
	if _warning != null:
		_warning.visible = _haze > 0.01


func _process(_delta: float) -> void:
	if _warning == null or not _warning.visible:
		return
	# Fade in with depth, and breathe once the world is genuinely holding you
	# back — a static caption reads as scenery, a pulsing one reads as a limit.
	var pulse: float = 1.0 - 0.18 * _haze * (0.5 - 0.5 * cos(Time.get_ticks_msec() / 260.0))
	_warning.modulate.a = _haze * pulse


## Refreshes each chip from the values the game measured this frame.
func set_stats(seconds: int, calories: float, steps: int, orbs: int) -> void:
	if _values.is_empty():
		return
	_values["time"].text = "%d:%02d" % [seconds / 60, seconds % 60]
	_values["calories"].text = "%.0f" % calories
	_values["steps"].text = str(steps)
	_values["orbs"].text = str(orbs)


## Shows live bpm from a heart-rate strap on its own chip; [param bpm] <= 0
## (no wearable / signal lost) hides the chip entirely.
func set_heart_rate(bpm: float) -> void:
	if _hr_chip == null:
		return
	_hr_chip.visible = bpm > 0.0
	if bpm > 0.0:
		_values["hr"].text = "%d" % roundi(bpm)


## A quick scale pop on the ORBS value when one is banked, so pickups feel felt.
func pulse_orbs() -> void:
	var value: Label = _values.get("orbs")
	if value != null:
		_pulse_value(value)


## The shared pickup pop: a quick overshoot-and-settle on a chip's value label.
func _pulse_value(value: Label) -> void:
	value.pivot_offset = value.size * 0.5
	value.scale = Vector2(1.4, 1.4)
	var tween := value.create_tween()
	tween.tween_property(value, "scale", Vector2.ONE, 0.28) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
