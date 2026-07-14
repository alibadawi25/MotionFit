extends Control
## GameSelect
##
## Builds the grid of game cards from GameManager's registry — it does NOT
## hardcode any game. Add a game to the registry and a card appears here
## automatically. Unavailable games render as disabled "Coming Soon" cards.
##
## Card visuals are built in code (styleboxes + hover lift) so they stay in sync
## with the registry; the scene only provides the themed shell (background,
## header, container) matching the main menu.

const ACCENT := Color(1, 0.5, 0.14)
const CARD_BG := Color(0.05, 0.07, 0.11, 0.9)
const CARD_BG_HL := Color(0.11, 0.14, 0.21, 0.96)
const CARD_BG_PRESS := Color(0.14, 0.17, 0.24, 0.98)
const CARD_BORDER := Color(1, 1, 1, 0.12)
const CARD_BG_OFF := Color(0.04, 0.05, 0.08, 0.82)
const CARD_BORDER_OFF := Color(1, 1, 1, 0.06)
const TITLE_ON := Color(0.96, 0.97, 0.99)
const TITLE_OFF := Color(0.78, 0.81, 0.86, 0.85)
const DESC_ON := Color(0.8, 0.84, 0.9, 0.92)
const DESC_OFF := Color(0.68, 0.72, 0.78, 0.78)

const CARD_SIZE := Vector2(320, 188)
const HOVER_SCALE := 1.035

@onready var _card_container: Container = %CardContainer
@onready var _back_button: Button = %BackButton

func _ready() -> void:
	_back_button.pressed.connect(_on_back_pressed)
	_populate_cards()


func _populate_cards() -> void:
	var first_playable: Button = null
	for game in GameManager.get_games():
		var card := _build_card(game)
		_card_container.add_child(card)
		if first_playable == null and bool(game["available"]):
			first_playable = card
	# Start with the first playable card focused so keyboard/gamepad users have a
	# clear selection. Deferred so focus lands after the layout settles.
	if first_playable != null:
		first_playable.call_deferred("grab_focus")


func _build_card(game: Dictionary) -> Button:
	var available: bool = bool(game["available"])

	var card := Button.new()
	card.custom_minimum_size = CARD_SIZE
	card.disabled = not available
	card.focus_mode = Control.FOCUS_ALL if available else Control.FOCUS_NONE
	# NOTE: do NOT clip_contents here. The card's StyleBoxFlat draws a drop shadow
	# that extends beyond the button rect; clipping cuts that soft rounded glow
	# into a hard rectangle and fills the rounded-corner notches with dark squares.
	# The inner content is inset 22px (corner radius is only 14) so it never
	# reaches the rounded corners — clipping isn't needed.
	card.clip_contents = false
	card.mouse_default_cursor_shape = (
		Control.CURSOR_POINTING_HAND if available else Control.CURSOR_ARROW
	)

	_style_card(card, available)
	card.add_child(_build_card_content(game, available))

	# Keep the scale pivot centred so the hover "lift" grows evenly, even after
	# the flow container resizes the card.
	card.resized.connect(func() -> void: card.pivot_offset = card.size * 0.5)

	if available:
		card.pressed.connect(_on_game_pressed.bind(String(game["id"])))
		card.mouse_entered.connect(_animate_card.bind(card, HOVER_SCALE))
		card.mouse_exited.connect(_animate_card.bind(card, 1.0))
		card.focus_entered.connect(_animate_card.bind(card, HOVER_SCALE))
		card.focus_exited.connect(_animate_card.bind(card, 1.0))
	return card


func _build_card_content(game: Dictionary, available: bool) -> MarginContainer:
	# An overlay that ignores the mouse so clicks fall through to the Button.
	var pad := MarginContainer.new()
	pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		pad.add_theme_constant_override(side, 22)

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 8)
	pad.add_child(box)

	var title := Label.new()
	title.text = String(game["title"])
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", TITLE_ON if available else TITLE_OFF)
	box.add_child(title)

	var desc := Label.new()
	desc.text = String(game["description"]) if available else "Coming soon"
	desc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	desc.add_theme_font_size_override("font_size", 16)
	desc.add_theme_color_override("font_color", DESC_ON if available else DESC_OFF)
	box.add_child(desc)

	box.add_child(_build_badge(available))
	return pad


func _build_badge(available: bool) -> Label:
	# A small pill-style status line at the bottom of each card.
	var badge := Label.new()
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.text = "▶  PLAY" if available else "LOCKED"
	badge.add_theme_font_size_override("font_size", 15)
	badge.add_theme_color_override("font_color", ACCENT if available else DESC_OFF)

	var pill := StyleBoxFlat.new()
	pill.bg_color = Color(1, 0.5, 0.14, 0.14) if available else Color(1, 1, 1, 0.04)
	pill.set_corner_radius_all(6)
	pill.content_margin_left = 12.0
	pill.content_margin_right = 12.0
	pill.content_margin_top = 5.0
	pill.content_margin_bottom = 5.0
	badge.add_theme_stylebox_override("normal", pill)
	badge.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	return badge


func _style_card(card: Button, available: bool) -> void:
	if available:
		# Soft dark shadow at rest for depth; a gentle orange glow on hover/focus.
		card.add_theme_stylebox_override("normal",
			_card_style(CARD_BG, CARD_BORDER, 2, Color(0, 0, 0, 0.2), 10))
		card.add_theme_stylebox_override("hover",
			_card_style(CARD_BG_HL, ACCENT, 2, Color(1, 0.5, 0.14, 0.26), 22))
		card.add_theme_stylebox_override("focus",
			_card_style(CARD_BG_HL, ACCENT, 2, Color(1, 0.5, 0.14, 0.26), 22))
		card.add_theme_stylebox_override("pressed",
			_card_style(CARD_BG_PRESS, ACCENT, 2, Color(1, 0.5, 0.14, 0.18), 12))
	else:
		var off := _card_style(CARD_BG_OFF, CARD_BORDER_OFF, 1, Color(0, 0, 0, 0.16), 7)
		card.add_theme_stylebox_override("disabled", off)
		card.add_theme_stylebox_override("normal", off)


func _card_style(bg: Color, border: Color, border_w: int,
		shadow_color := Color(0, 0, 0, 0), shadow_size := 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(14)
	sb.set_border_width_all(border_w)
	sb.border_color = border
	if shadow_size > 0:
		sb.shadow_color = shadow_color
		sb.shadow_size = shadow_size
	return sb


func _animate_card(card: Control, target: float) -> void:
	var tween := create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(card, "scale", Vector2(target, target), 0.12)


func _on_game_pressed(game_id: String) -> void:
	GameManager.select_game(game_id)
	# Difficulty selection is a future screen; for now go straight to countdown.
	GameManager.start_selected_game()


func _on_back_pressed() -> void:
	SceneManager.load_main_menu()
