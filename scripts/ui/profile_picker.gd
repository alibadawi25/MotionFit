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
## The screen's fixed furniture — backdrop, glow, header, the cards row, the Edit
## and Quit buttons and the delete-confirmation dialog — is authored in
## scenes/menus/profile_picker.tscn. Only the cards themselves are built here,
## since there is one per saved profile.

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

@onready var _cards_row: HBoxContainer = %CardsRow
@onready var _edit_button: Button = %EditProfilesButton
@onready var _subtitle: Label = %SubtitleLabel
@onready var _header: VBoxContainer = %Header
@onready var _quit_button: Button = %QuitButton
@onready var _confirm_layer: ColorRect = %DeleteConfirmLayer
@onready var _confirm_title: Label = %ConfirmTitleLabel
@onready var _cancel_button: Button = %CancelButton
@onready var _remove_button: Button = %RemoveButton

var _edit_mode: bool = false
## The profile the open confirmation dialog would delete ("" when it's closed).
var _pending_delete_id: String = ""

func _ready() -> void:
	_edit_button.pressed.connect(_on_toggle_edit)
	# This is the first screen of the launch and has no "back" — without an
	# explicit quit the only way out is Alt+F4. The corner button (and Escape)
	# closes the app, matching the main menu's QUIT.
	_quit_button.pressed.connect(_on_quit)
	_cancel_button.pressed.connect(_close_confirm)
	_remove_button.pressed.connect(_on_delete_confirmed)
	# A click on the dimmed backdrop also dismisses the dialog.
	_confirm_layer.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed:
			_close_confirm())
	_style_edit_button()
	_rebuild_cards()
	_play_entrance()


func _on_quit() -> void:
	get_tree().quit()


func _unhandled_input(event: InputEvent) -> void:
	# Escape is the expected "get me out" key: it closes the confirm dialog if
	# one is open, otherwise quits (this screen has no back).
	if event.is_action_pressed("ui_cancel"):
		if _confirm_layer.visible:
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

## Opens the scene's confirmation overlay (styled like the rest of the screen,
## unlike a stock ConfirmationDialog) so deleting a person's progress takes two
## clicks. The card that asked is remembered until the dialog is answered.
func _confirm_delete(id: String, name: String) -> void:
	if _confirm_layer.visible:
		return
	_pending_delete_id = id
	_confirm_title.text = "Remove %s's profile?" % name
	_confirm_layer.visible = true
	_confirm_layer.modulate.a = 0.0
	_confirm_layer.create_tween().tween_property(_confirm_layer, "modulate:a", 1.0, 0.15)
	_cancel_button.grab_focus.call_deferred()


func _close_confirm() -> void:
	_confirm_layer.visible = false
	_pending_delete_id = ""


func _on_delete_confirmed() -> void:
	var id := _pending_delete_id
	_close_confirm()
	if id == "":
		return
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
