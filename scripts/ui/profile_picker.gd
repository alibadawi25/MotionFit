extends Control
## ProfilePicker
##
## "Who's playing?" — the shared-device profile chooser shown once per launch
## (and from the menu's Switch Profile). Each profile is a card with a colored
## monogram badge (color derived from the profile id, so it's stable), a level
## chip and a calibration chip; the last-active profile is highlighted and
## pre-focused so Enter re-picks it. "＋ Add" creates a new one, and an Edit
## toggle reveals a ✕ on each card that asks for confirmation before deleting.
##
## Built entirely in code (like GameIntro / the results screen) so it needs only a
## bare themed root scene.

const ACCENT := Color(1, 0.5, 0.14)
const CARD_SIZE := Vector2(232, 244)
const TITLE_COLOR := Color(0.96, 0.97, 0.99)
const MUTED := Color(0.6, 0.65, 0.73)
const DANGER := Color(0.93, 0.34, 0.31)
## Identity colors for the monogram badges — picked by hashing the profile id so
## each player keeps "their" color across launches. Deliberately distinct from
## the UI accent orange so the badges read as people, not buttons.
const BADGE_COLORS: Array[Color] = [
	Color(0.35, 0.72, 0.96),  # sky
	Color(0.63, 0.52, 0.97),  # violet
	Color(0.24, 0.8, 0.66),   # teal
	Color(0.95, 0.45, 0.58),  # rose
	Color(0.97, 0.76, 0.32),  # gold
	Color(0.58, 0.84, 0.4),   # lime
]

var _edit_mode: bool = false
var _cards_row: HBoxContainer
var _edit_button: Button
var _subtitle: Label
var _header: VBoxContainer
## The delete-confirmation overlay while it's open (null otherwise); Escape
## closes it instead of quitting the app.
var _confirm_layer: Control = null

func _ready() -> void:
	_build()
	_play_entrance()


func _build() -> void:
	# Dark backdrop with a soft radial glow behind the content so the screen has
	# depth instead of a flat fill.
	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.03, 0.04, 0.07)
	add_child(bg)
	add_child(_make_glow())

	var column := VBoxContainer.new()
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", 40)
	add_child(column)

	_header = VBoxContainer.new()
	_header.add_theme_constant_override("separation", 14)
	column.add_child(_header)

	var accent := ColorRect.new()
	accent.color = ACCENT
	accent.custom_minimum_size = Vector2(72, 6)
	accent.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_header.add_child(accent)

	var title := Label.new()
	title.text = "WHO'S PLAYING?"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 52)
	title.add_theme_color_override("font_color", TITLE_COLOR)
	var anton: Font = load("res://assets/fonts/Anton-Regular.ttf")
	if anton != null:
		title.add_theme_font_override("font", anton)
	_header.add_child(title)

	_subtitle = Label.new()
	_subtitle.text = "Everyone keeps their own progress, levels and calibration."
	_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_subtitle.add_theme_font_size_override("font_size", 17)
	_subtitle.add_theme_color_override("font_color", MUTED)
	_header.add_child(_subtitle)

	_cards_row = HBoxContainer.new()
	_cards_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_cards_row.add_theme_constant_override("separation", 26)
	column.add_child(_cards_row)
	_rebuild_cards()

	# Edit toggle (reveals per-card delete), centred under the cards.
	_edit_button = Button.new()
	_edit_button.custom_minimum_size = Vector2(170, 48)
	_edit_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_edit_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_edit_button.add_theme_font_size_override("font_size", 17)
	_edit_button.pressed.connect(_on_toggle_edit)
	_style_edit_button()
	column.add_child(_edit_button)

	# This is the first screen of the launch and has no "back" — without an
	# explicit quit the only way out is Alt+F4. A corner button (and Escape)
	# closes the app, matching the main menu's QUIT.
	_build_quit_button()


## Soft radial glow centred a little above the middle, where the cards sit.
func _make_glow() -> TextureRect:
	var gradient := Gradient.new()
	gradient.colors = PackedColorArray([Color(0.11, 0.14, 0.21, 1.0), Color(0.03, 0.04, 0.07, 0.0)])
	gradient.offsets = PackedFloat32Array([0.0, 1.0])
	var tex := GradientTexture2D.new()
	tex.gradient = gradient
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.45)
	tex.fill_to = Vector2(1.0, 0.45)
	var rect := TextureRect.new()
	rect.texture = tex
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect


func _build_quit_button() -> void:
	var quit := Button.new()
	quit.text = "✕  QUIT"
	quit.focus_mode = Control.FOCUS_NONE
	quit.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	quit.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	quit.offset_left = -214.0
	quit.offset_top = 44.0
	quit.offset_right = -48.0
	quit.offset_bottom = 96.0
	quit.add_theme_font_size_override("font_size", 20)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.08, 0.12, 0.82)
	sb.set_corner_radius_all(10)
	sb.set_border_width_all(1)
	sb.border_color = Color(1, 1, 1, 0.16)
	var hover := sb.duplicate()
	hover.bg_color = Color(0.12, 0.15, 0.22, 0.95)
	hover.border_color = ACCENT
	quit.add_theme_stylebox_override("normal", sb)
	quit.add_theme_stylebox_override("hover", hover)
	quit.add_theme_stylebox_override("pressed", hover)
	quit.pressed.connect(_on_quit)
	add_child(quit)


func _on_quit() -> void:
	get_tree().quit()


func _unhandled_input(event: InputEvent) -> void:
	# Escape is the expected "get me out" key: it closes the confirm dialog if
	# one is open, otherwise quits (this screen has no back).
	if event.is_action_pressed("ui_cancel"):
		if is_instance_valid(_confirm_layer):
			_close_confirm()
		else:
			get_tree().quit()
		get_viewport().set_input_as_handled()


func _rebuild_cards() -> void:
	for child in _cards_row.get_children():
		child.queue_free()
	var active_id := ProfileManager.get_active_id()
	var focus_target: Control = null
	for entry in ProfileManager.list_profiles():
		var is_active := String(entry["id"]) == active_id
		var card := _make_profile_card(entry, is_active)
		_cards_row.add_child(card)
		if focus_target == null or is_active:
			focus_target = card
	# Hide "Add" while editing so a stray tap can't navigate away mid-cleanup.
	if not _edit_mode:
		_cards_row.add_child(_make_add_card())
	# Pre-focus the last-active player so Enter re-picks them instantly (and
	# arrow keys / gamepad work from the start).
	if focus_target != null and not _edit_mode:
		focus_target.grab_focus.call_deferred()


func _make_profile_card(entry: Dictionary, is_active: bool) -> Control:
	var card := Button.new()
	card.custom_minimum_size = CARD_SIZE
	card.pivot_offset = CARD_SIZE / 2.0
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	card.add_theme_stylebox_override("normal", _card_style(false, false, is_active))
	card.add_theme_stylebox_override("hover", _card_style(true))
	card.add_theme_stylebox_override("pressed", _card_style(true))
	card.add_theme_stylebox_override("focus", _card_style(true))
	card.pressed.connect(_on_pick.bind(String(entry["id"])))
	_hook_hover(card)

	var vb := VBoxContainer.new()
	vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 12)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(vb)

	var color := _badge_color(String(entry["id"]))
	vb.add_child(_make_badge(String(entry["name"]).substr(0, 1).to_upper(), color))

	var name_label := Label.new()
	name_label.text = String(entry["name"])
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 25)
	name_label.add_theme_color_override("font_color", TITLE_COLOR)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	vb.add_child(name_label)

	var chips := HBoxContainer.new()
	chips.alignment = BoxContainer.ALIGNMENT_CENTER
	chips.add_theme_constant_override("separation", 8)
	chips.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chips.add_child(_make_chip("LVL %d" % int(entry["level"]),
		Color(0.85, 0.88, 0.93), Color(1, 1, 1, 0.05), Color(1, 1, 1, 0.14)))
	if bool(entry.get("calibrated", false)):
		var green := Color(0.45, 0.85, 0.5)
		chips.add_child(_make_chip("✓ CALIBRATED",
			green, Color(green.r, green.g, green.b, 0.08), Color(green.r, green.g, green.b, 0.4)))
	vb.add_child(chips)

	# Delete affordance: a red ✕ in the corner, only in edit mode. It sits on
	# top of the card button and confirms before actually deleting.
	if _edit_mode:
		card.add_child(_make_delete_button(String(entry["id"]), String(entry["name"])))
	return card


## Round monogram badge: translucent tint + colored ring + colored initial.
func _make_badge(letter: String, color: Color) -> Control:
	var wrap := CenterContainer.new()
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var circle := Panel.new()
	circle.custom_minimum_size = Vector2(86, 86)
	circle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(color.r, color.g, color.b, 0.13)
	sb.set_corner_radius_all(43)
	sb.set_border_width_all(2)
	sb.border_color = Color(color.r, color.g, color.b, 0.85)
	circle.add_theme_stylebox_override("panel", sb)
	var label := Label.new()
	label.text = letter
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 42)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	circle.add_child(label)
	wrap.add_child(circle)
	return wrap


## Small rounded status chip ("LVL 5", "✓ CALIBRATED").
func _make_chip(text: String, fg: Color, bg: Color, border: Color) -> Control:
	var chip := PanelContainer.new()
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(9)
	sb.set_border_width_all(1)
	sb.border_color = border
	sb.content_margin_left = 9
	sb.content_margin_right = 9
	sb.content_margin_top = 3
	sb.content_margin_bottom = 4
	chip.add_theme_stylebox_override("panel", sb)
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", fg)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.add_child(label)
	return chip


func _make_delete_button(id: String, name: String) -> Button:
	var del := Button.new()
	del.text = "✕"
	del.tooltip_text = "Remove %s" % name
	del.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	del.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	del.offset_left = -44.0
	del.offset_top = 8.0
	del.offset_right = -8.0
	del.offset_bottom = 44.0
	del.add_theme_font_size_override("font_size", 17)
	del.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(DANGER.r, DANGER.g, DANGER.b, 0.85)
	sb.set_corner_radius_all(18)
	var hover := sb.duplicate()
	hover.bg_color = DANGER
	hover.shadow_color = Color(DANGER.r, DANGER.g, DANGER.b, 0.4)
	hover.shadow_size = 8
	del.add_theme_stylebox_override("normal", sb)
	del.add_theme_stylebox_override("hover", hover)
	del.add_theme_stylebox_override("pressed", hover)
	del.pressed.connect(_confirm_delete.bind(id, name))
	return del


func _make_add_card() -> Control:
	var card := Button.new()
	card.custom_minimum_size = CARD_SIZE
	card.pivot_offset = CARD_SIZE / 2.0
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	card.add_theme_stylebox_override("normal", _card_style(false, true))
	card.add_theme_stylebox_override("hover", _card_style(true, true))
	card.add_theme_stylebox_override("pressed", _card_style(true, true))
	card.add_theme_stylebox_override("focus", _card_style(true, true))
	card.pressed.connect(_on_add)
	_hook_hover(card)

	# Mirrors the profile-card layout (circle / name / sub) so the row scans as
	# one family of cards.
	var vb := VBoxContainer.new()
	vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 12)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(_make_badge("＋", Color(0.75, 0.79, 0.86)))

	var label := Label.new()
	label.text = "ADD PROFILE"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 20)
	label.add_theme_color_override("font_color", Color(0.82, 0.85, 0.9))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(label)

	var sub := Label.new()
	sub.text = "New player"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 14)
	sub.add_theme_color_override("font_color", MUTED)
	sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(sub)
	card.add_child(vb)
	return card


# --- Interaction -------------------------------------------------------------

func _on_pick(id: String) -> void:
	if _edit_mode:
		return  # in edit mode a card tap shouldn't switch — use the ✕ button
	ProfileManager.select_profile(id)
	SceneManager.profile_chosen_this_session = true
	if ProfileManager.is_onboarded():
		SceneManager.load_main_menu()
	else:
		SceneManager.load_profile_setup()


func _on_add() -> void:
	# ProfileSetup creates the new profile (name + body data), then calibration.
	SceneManager.load_profile_setup()


func _on_toggle_edit() -> void:
	_edit_mode = not _edit_mode
	_style_edit_button()
	_subtitle.text = ("Tap ✕ to remove a player — this deletes their progress." if _edit_mode
		else "Everyone keeps their own progress, levels and calibration.")
	_subtitle.add_theme_color_override("font_color",
		Color(1, 0.72, 0.5) if _edit_mode else MUTED)
	_rebuild_cards()


func _style_edit_button() -> void:
	_edit_button.text = "✓  DONE" if _edit_mode else "✎  EDIT PROFILES"
	var normal := StyleBoxFlat.new()
	normal.set_corner_radius_all(24)
	normal.set_border_width_all(1)
	normal.content_margin_left = 22
	normal.content_margin_right = 22
	normal.content_margin_top = 11
	normal.content_margin_bottom = 11
	if _edit_mode:
		# Filled accent while active, so "you are editing" is unmissable.
		normal.bg_color = ACCENT
		normal.border_color = Color(1, 0.66, 0.3)
		_edit_button.add_theme_color_override("font_color", Color(0.12, 0.06, 0.02))
		_edit_button.add_theme_color_override("font_hover_color", Color(0.12, 0.06, 0.02))
		_edit_button.add_theme_color_override("font_pressed_color", Color(0.12, 0.06, 0.02))
	else:
		normal.bg_color = Color(0.08, 0.1, 0.15, 0.7)
		normal.border_color = Color(1, 1, 1, 0.14)
		_edit_button.add_theme_color_override("font_color", Color(0.85, 0.88, 0.93))
		_edit_button.add_theme_color_override("font_hover_color", Color(1, 1, 1))
		_edit_button.add_theme_color_override("font_pressed_color", Color(1, 1, 1))
	var hover := normal.duplicate()
	if not _edit_mode:
		hover.bg_color = Color(0.13, 0.16, 0.23, 0.9)
		hover.border_color = ACCENT
	_edit_button.add_theme_stylebox_override("normal", normal)
	_edit_button.add_theme_stylebox_override("hover", hover)
	_edit_button.add_theme_stylebox_override("pressed", hover)
	_edit_button.add_theme_stylebox_override("focus", hover)


# --- Delete confirmation -----------------------------------------------------

## In-scene confirmation overlay (styled like the rest of the screen, unlike a
## stock ConfirmationDialog) so deleting a person's progress takes two clicks.
func _confirm_delete(id: String, name: String) -> void:
	if is_instance_valid(_confirm_layer):
		return
	var overlay := ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.62)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed:
			_close_confirm())
	_confirm_layer = overlay
	add_child(overlay)

	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.1, 0.15, 0.98)
	sb.set_corner_radius_all(18)
	sb.set_border_width_all(1)
	sb.border_color = Color(1, 1, 1, 0.14)
	sb.shadow_color = Color(0, 0, 0, 0.5)
	sb.shadow_size = 24
	sb.content_margin_left = 36
	sb.content_margin_right = 36
	sb.content_margin_top = 30
	sb.content_margin_bottom = 30
	panel.add_theme_stylebox_override("panel", sb)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(center)
	center.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	panel.add_child(vb)

	var title := Label.new()
	title.text = "Remove %s's profile?" % name
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", TITLE_COLOR)
	vb.add_child(title)

	var body := Label.new()
	body.text = "Their level, stats and body calibration will be deleted.\nThis can't be undone."
	body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_theme_font_size_override("font_size", 15)
	body.add_theme_color_override("font_color", MUTED)
	vb.add_child(body)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 14)
	vb.add_child(buttons)

	var cancel := Button.new()
	cancel.text = "CANCEL"
	cancel.custom_minimum_size = Vector2(150, 46)
	cancel.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var cancel_sb := StyleBoxFlat.new()
	cancel_sb.bg_color = Color(1, 1, 1, 0.06)
	cancel_sb.set_corner_radius_all(12)
	cancel_sb.set_border_width_all(1)
	cancel_sb.border_color = Color(1, 1, 1, 0.18)
	var cancel_hover := cancel_sb.duplicate()
	cancel_hover.bg_color = Color(1, 1, 1, 0.12)
	cancel.add_theme_stylebox_override("normal", cancel_sb)
	cancel.add_theme_stylebox_override("hover", cancel_hover)
	cancel.add_theme_stylebox_override("pressed", cancel_hover)
	cancel.pressed.connect(_close_confirm)
	buttons.add_child(cancel)

	var remove := Button.new()
	remove.text = "REMOVE"
	remove.custom_minimum_size = Vector2(150, 46)
	remove.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	remove.add_theme_color_override("font_color", Color(1, 1, 1))
	var remove_sb := StyleBoxFlat.new()
	remove_sb.bg_color = Color(DANGER.r, DANGER.g, DANGER.b, 0.9)
	remove_sb.set_corner_radius_all(12)
	var remove_hover := remove_sb.duplicate()
	remove_hover.bg_color = DANGER
	remove_hover.shadow_color = Color(DANGER.r, DANGER.g, DANGER.b, 0.35)
	remove_hover.shadow_size = 10
	remove.add_theme_stylebox_override("normal", remove_sb)
	remove.add_theme_stylebox_override("hover", remove_hover)
	remove.add_theme_stylebox_override("pressed", remove_hover)
	remove.pressed.connect(_on_delete_confirmed.bind(id))
	buttons.add_child(remove)

	# Fade the whole overlay in.
	overlay.modulate.a = 0.0
	overlay.create_tween().tween_property(overlay, "modulate:a", 1.0, 0.15)
	cancel.grab_focus.call_deferred()


func _close_confirm() -> void:
	if is_instance_valid(_confirm_layer):
		_confirm_layer.queue_free()
	_confirm_layer = null


func _on_delete_confirmed(id: String) -> void:
	_close_confirm()
	ProfileManager.delete_profile(id)
	if not ProfileManager.has_profiles():
		# Deleted the last one — back to first-run onboarding.
		SceneManager.load_profile_setup()
		return
	_rebuild_cards()


# --- Styling & animation -----------------------------------------------------

func _badge_color(id: String) -> Color:
	return BADGE_COLORS[absi(id.hash()) % BADGE_COLORS.size()]


func _card_style(hover: bool, dashed: bool = false, active: bool = false) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = (Color(0.12, 0.145, 0.21, 0.98) if hover
		else (Color(0.05, 0.06, 0.1, 0.6) if dashed else Color(0.085, 0.105, 0.155, 0.96)))
	sb.set_corner_radius_all(18)
	sb.set_border_width_all(2)
	if hover:
		sb.border_color = ACCENT
		sb.shadow_color = Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.22)
		sb.shadow_size = 16
	elif active:
		# The last-active profile gets a quiet accent ring: "this was you".
		sb.border_color = Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.45)
	else:
		sb.border_color = Color(1, 1, 1, 0.16) if _edit_mode else Color(1, 1, 1, 0.1)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 14
	sb.content_margin_bottom = 14
	return sb


## Gentle grow on hover/focus so the cards feel physical.
func _hook_hover(card: Button) -> void:
	card.mouse_entered.connect(_scale_card.bind(card, 1.05))
	card.mouse_exited.connect(_scale_card.bind(card, 1.0))
	card.focus_entered.connect(_scale_card.bind(card, 1.05))
	card.focus_exited.connect(_scale_card.bind(card, 1.0))


func _scale_card(card: Control, target: float) -> void:
	# Tween owned by the card so a rebuild can't animate a freed node.
	var tween := card.create_tween()
	tween.tween_property(card, "scale", Vector2(target, target), 0.16)\
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


## One-shot staggered entrance: header fades, then cards pop in left-to-right.
func _play_entrance() -> void:
	_header.modulate.a = 0.0
	_header.create_tween().tween_property(_header, "modulate:a", 1.0, 0.3)
	_edit_button.modulate.a = 0.0
	var eb := _edit_button.create_tween()
	eb.tween_interval(0.35)
	eb.tween_property(_edit_button, "modulate:a", 1.0, 0.25)
	# Fade only — scale is owned by the hover/focus tweens, and the pre-focused
	# card grows the moment it grabs focus, so animating scale here would fight it.
	var index := 0
	for card in _cards_row.get_children():
		var control := card as Control
		control.modulate.a = 0.0
		control.create_tween().tween_property(control, "modulate:a", 1.0, 0.25)\
			.set_delay(0.1 + 0.07 * index)
		index += 1
