extends Control
## ProfilePicker
##
## "Who's playing?" — the shared-device profile chooser shown once per launch
## (and from the menu's Switch Profile). Lists every profile as a card; picking one
## makes it active and enters the menu, "＋ Add" creates a new one, and an Edit
## toggle reveals a delete on each card so a wrong pick isn't destructive.
##
## Built entirely in code (like GameIntro / the results screen) so it needs only a
## bare themed root scene.

const ACCENT := Color(1, 0.5, 0.14)
const CARD_SIZE := Vector2(220, 200)
const TITLE_COLOR := Color(0.96, 0.97, 0.99)

var _edit_mode: bool = false
var _cards_row: HBoxContainer
var _edit_button: Button

func _ready() -> void:
	_build()


func _build() -> void:
	# Full-screen dark backdrop.
	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.03, 0.04, 0.07)
	add_child(bg)

	var column := VBoxContainer.new()
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", 36)
	add_child(column)

	var accent := ColorRect.new()
	accent.color = ACCENT
	accent.custom_minimum_size = Vector2(72, 6)
	accent.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	column.add_child(accent)

	var title := Label.new()
	title.text = "WHO'S PLAYING?"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 52)
	title.add_theme_color_override("font_color", TITLE_COLOR)
	var anton: Font = load("res://assets/fonts/Anton-Regular.ttf")
	if anton != null:
		title.add_theme_font_override("font", anton)
	column.add_child(title)

	_cards_row = HBoxContainer.new()
	_cards_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_cards_row.add_theme_constant_override("separation", 24)
	column.add_child(_cards_row)
	_rebuild_cards()

	# Edit toggle (reveals per-card delete), centred under the cards.
	_edit_button = Button.new()
	_edit_button.text = "EDIT"
	_edit_button.custom_minimum_size = Vector2(140, 44)
	_edit_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_edit_button.pressed.connect(_on_toggle_edit)
	column.add_child(_edit_button)

	# This is the first screen of the launch and has no "back" — without an
	# explicit quit the only way out is Alt+F4. A corner button (and Escape)
	# closes the app, matching the main menu's QUIT.
	_build_quit_button()


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
	# Escape is the expected "get me out" key on a screen with no back.
	if event.is_action_pressed("ui_cancel"):
		get_tree().quit()
		get_viewport().set_input_as_handled()


func _rebuild_cards() -> void:
	for child in _cards_row.get_children():
		child.queue_free()
	for entry in ProfileManager.list_profiles():
		_cards_row.add_child(_make_profile_card(entry))
	_cards_row.add_child(_make_add_card())


func _make_profile_card(entry: Dictionary) -> Control:
	var card := Button.new()
	card.custom_minimum_size = CARD_SIZE
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	card.add_theme_stylebox_override("normal", _card_style(false))
	card.add_theme_stylebox_override("hover", _card_style(true))
	card.add_theme_stylebox_override("pressed", _card_style(true))
	card.add_theme_stylebox_override("focus", _card_style(true))
	card.pressed.connect(_on_pick.bind(String(entry["id"])))

	var vb := VBoxContainer.new()
	vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 8)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(vb)

	# A round monogram badge with the initial.
	var badge := Label.new()
	badge.text = String(entry["name"]).substr(0, 1).to_upper()
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.custom_minimum_size = Vector2(0, 72)
	badge.add_theme_font_size_override("font_size", 56)
	badge.add_theme_color_override("font_color", ACCENT)
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(badge)

	var name_label := Label.new()
	name_label.text = String(entry["name"])
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 24)
	name_label.add_theme_color_override("font_color", TITLE_COLOR)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(name_label)

	var sub := Label.new()
	var calib := "  ·  ✓ calibrated" if bool(entry.get("calibrated", false)) else ""
	sub.text = "Level %d%s" % [int(entry["level"]), calib]
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 15)
	sub.add_theme_color_override("font_color", Color(0.7, 0.74, 0.8))
	sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(sub)

	# Delete affordance, only in edit mode.
	if _edit_mode:
		var del := Button.new()
		del.text = "✕ Remove"
		del.custom_minimum_size = Vector2(0, 34)
		del.add_theme_color_override("font_color", Color(1, 0.5, 0.5))
		del.pressed.connect(_on_delete.bind(String(entry["id"])))
		vb.add_child(del)
	return card


func _make_add_card() -> Control:
	var card := Button.new()
	card.text = "＋\nADD PROFILE"
	card.custom_minimum_size = CARD_SIZE
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	card.add_theme_font_size_override("font_size", 22)
	card.add_theme_color_override("font_color", Color(0.8, 0.84, 0.9))
	card.add_theme_stylebox_override("normal", _card_style(false, true))
	card.add_theme_stylebox_override("hover", _card_style(true, true))
	card.add_theme_stylebox_override("pressed", _card_style(true, true))
	card.add_theme_stylebox_override("focus", _card_style(true, true))
	card.pressed.connect(_on_add)
	return card


func _on_pick(id: String) -> void:
	if _edit_mode:
		return  # in edit mode a card tap shouldn't switch — use the Remove button
	ProfileManager.select_profile(id)
	SceneManager.profile_chosen_this_session = true
	if ProfileManager.is_onboarded():
		SceneManager.load_main_menu()
	else:
		SceneManager.load_profile_setup()


func _on_add() -> void:
	# ProfileSetup creates the new profile (name + body data), then calibration.
	SceneManager.load_profile_setup()


func _on_delete(id: String) -> void:
	ProfileManager.delete_profile(id)
	if not ProfileManager.has_profiles():
		# Deleted the last one — back to first-run onboarding.
		SceneManager.load_profile_setup()
		return
	_rebuild_cards()


func _on_toggle_edit() -> void:
	_edit_mode = not _edit_mode
	_edit_button.text = "DONE" if _edit_mode else "EDIT"
	_rebuild_cards()


func _card_style(hover: bool, dashed: bool = false) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.11, 0.16, 0.96) if not dashed else Color(0.05, 0.06, 0.1, 0.6)
	sb.set_corner_radius_all(14)
	sb.set_border_width_all(2)
	sb.border_color = ACCENT if hover else Color(1, 1, 1, 0.12)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 14
	sb.content_margin_bottom = 14
	return sb
