extends Control
## DifficultySelect
##
## The intensity picker between Game Select and a game's intro. One card per
## GameManager.Difficulty; picking a card stores the difficulty and starts the
## selected game. Games opt in via the registry's "uses_difficulty" flag (Game
## Select routes here only for those), so free-roam games never see this screen.
##
## The card matching the current/last-used difficulty is pre-focused, so
## keyboard players can just press Enter to keep their usual intensity. Copy is
## deliberately about EFFORT ("how hard do you want to work?") rather than
## skill — this is a fitness platform, and harder means a harder workout, not a
## punishment.

const ACCENT := Color(1, 0.5, 0.14)
const CARD_BG := Color(0.05, 0.07, 0.11, 0.9)
const CARD_BG_HL := Color(0.11, 0.14, 0.21, 0.96)
const CARD_BG_PRESS := Color(0.14, 0.17, 0.24, 0.98)
const CARD_BORDER := Color(1, 1, 1, 0.12)
const TITLE_COLOR := Color(0.96, 0.97, 0.99)
const DESC_COLOR := Color(0.8, 0.84, 0.9, 0.92)
const TAG_COLOR := Color(1, 0.64, 0.3)
const PIP_OFF := Color(1, 1, 1, 0.16)

const CARD_SIZE := Vector2(300, 330)
const HOVER_SCALE := 1.04

## One entry per difficulty, in display order. "pips" is the 1..3 intensity
## meter; copy frames each level as a workout promise, shared by every game
## (difficulty semantics are platform-wide — see GameManager.Difficulty).
const LEVELS: Array[Dictionary] = [
	{
		"difficulty": GameManager.Difficulty.EASY,
		"name": "EASY",
		"tag": "WARM-UP",
		"desc": "A gentler pace with room to breathe. Great for first sessions and recovery days.",
		"pips": 1,
	},
	{
		"difficulty": GameManager.Difficulty.NORMAL,
		"name": "NORMAL",
		"tag": "STEADY BURN",
		"desc": "The intended challenge — a steady push that keeps your heart rate up.",
		"pips": 2,
	},
	{
		"difficulty": GameManager.Difficulty.HARD,
		"name": "HARD",
		"tag": "ALL OUT",
		"desc": "Relentless. Everything comes faster and closes in sooner. Expect to sweat.",
		"pips": 3,
	},
]

@onready var _card_container: HBoxContainer = %CardContainer
@onready var _back_button: Button = %BackButton
@onready var _title: Label = %Title
@onready var _subtitle: Label = %Subtitle
@onready var _header: VBoxContainer = %Header

func _ready() -> void:
	_back_button.pressed.connect(_on_back_pressed)
	_fill_header()
	_build_cards()
	_play_entrance()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_on_back_pressed()
		get_viewport().set_input_as_handled()


## Names the selected game in the header so the screen reads as a step of THAT
## game's launch ("ZOMBIE RUN — how hard?"), not a detached settings page. Falls
## back to a generic title when opened directly (e.g. from the editor).
func _fill_header() -> void:
	var game: Dictionary = GameManager.get_game(GameManager.get_current_game_id())
	if game.is_empty():
		return
	_title.text = "%s — HOW HARD?" % String(game["title"]).to_upper()
	_subtitle.text = "Pick your intensity   ·   you can change it every run"


func _build_cards() -> void:
	var current: GameManager.Difficulty = GameManager.get_difficulty()
	for level in LEVELS:
		var card := _build_card(level)
		_card_container.add_child(card)
		if level["difficulty"] == current:
			# Enter keeps the usual intensity; the focus style marks the card.
			card.grab_focus.call_deferred()


func _build_card(level: Dictionary) -> Button:
	var card := Button.new()
	card.custom_minimum_size = CARD_SIZE
	card.clip_contents = false  # the stylebox shadow extends past the rect
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_style_card(card)

	card.add_child(_build_card_content(level))
	card.resized.connect(func() -> void: card.pivot_offset = card.size * 0.5)
	card.pressed.connect(_on_level_pressed.bind(level["difficulty"]))
	card.mouse_entered.connect(_animate_card.bind(card, HOVER_SCALE))
	card.mouse_exited.connect(_animate_card.bind(card, 1.0))
	card.focus_entered.connect(_animate_card.bind(card, HOVER_SCALE))
	card.focus_exited.connect(_animate_card.bind(card, 1.0))
	return card


func _build_card_content(level: Dictionary) -> MarginContainer:
	# Overlay that ignores the mouse so clicks fall through to the Button.
	var pad := MarginContainer.new()
	pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		pad.add_theme_constant_override(side, 26)

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 10)
	pad.add_child(box)

	var name_label := Label.new()
	name_label.text = String(level["name"])
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_label.add_theme_font_size_override("font_size", 44)
	name_label.add_theme_color_override("font_color", TITLE_COLOR)
	var anton: Font = load("res://assets/fonts/Anton-Regular.ttf")
	if anton != null:
		name_label.add_theme_font_override("font", anton)
	box.add_child(name_label)

	var tag := Label.new()
	tag.text = String(level["tag"])
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tag.add_theme_font_size_override("font_size", 16)
	tag.add_theme_color_override("font_color", TAG_COLOR)
	box.add_child(tag)

	box.add_child(_build_pips(int(level["pips"])))

	var desc := Label.new()
	desc.text = String(level["desc"])
	desc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	desc.add_theme_font_size_override("font_size", 16)
	desc.add_theme_color_override("font_color", DESC_COLOR)
	box.add_child(desc)

	box.add_child(_build_go_badge())
	return pad


## The 3-dot intensity meter: filled accent pips for the level's effort, faint
## ones for the rest — the at-a-glance ranking between the three cards.
func _build_pips(filled: int) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 6)
	for i in range(3):
		var pip := Label.new()
		pip.text = "●"
		pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pip.add_theme_font_size_override("font_size", 20)
		pip.add_theme_color_override("font_color", ACCENT if i < filled else PIP_OFF)
		row.add_child(pip)
	return row


func _build_go_badge() -> Label:
	var badge := Label.new()
	badge.text = "▶  START"
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	badge.add_theme_font_size_override("font_size", 15)
	badge.add_theme_color_override("font_color", ACCENT)
	var pill := StyleBoxFlat.new()
	pill.bg_color = Color(1, 0.5, 0.14, 0.14)
	pill.set_corner_radius_all(6)
	pill.content_margin_left = 12.0
	pill.content_margin_right = 12.0
	pill.content_margin_top = 5.0
	pill.content_margin_bottom = 5.0
	badge.add_theme_stylebox_override("normal", pill)
	return badge


func _style_card(card: Button) -> void:
	card.add_theme_stylebox_override("normal",
		_card_style(CARD_BG, CARD_BORDER, 2, Color(0, 0, 0, 0.2), 10))
	card.add_theme_stylebox_override("hover",
		_card_style(CARD_BG_HL, ACCENT, 2, Color(1, 0.5, 0.14, 0.26), 22))
	card.add_theme_stylebox_override("focus",
		_card_style(CARD_BG_HL, ACCENT, 2, Color(1, 0.5, 0.14, 0.26), 22))
	card.add_theme_stylebox_override("pressed",
		_card_style(CARD_BG_PRESS, ACCENT, 2, Color(1, 0.5, 0.14, 0.18), 12))


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


func _animate_card(card: Button, target: float) -> void:
	var tween := card.create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(card, "scale", Vector2(target, target), 0.12)


## Header fades, then the cards pop in left-to-right (easy → hard, so the eye
## reads the intensity ramp in order).
func _play_entrance() -> void:
	_header.modulate.a = 0.0
	_header.create_tween().tween_property(_header, "modulate:a", 1.0, 0.25)
	var index := 0
	for card in _card_container.get_children():
		var control := card as Control
		control.modulate.a = 0.0
		control.create_tween().tween_property(control, "modulate:a", 1.0, 0.22)\
			.set_delay(0.08 + 0.07 * index)
		index += 1


func _on_level_pressed(difficulty: GameManager.Difficulty) -> void:
	GameManager.set_difficulty(difficulty)
	# Opened mid-flow there's always a selected game; opened directly (editor)
	# there may not be — start_selected_game already no-ops with a warning then.
	GameManager.start_selected_game()


func _on_back_pressed() -> void:
	SceneManager.load_game_select()
