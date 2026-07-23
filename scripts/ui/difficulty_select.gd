extends Control
## DifficultySelect
##
## The intensity picker between Game Select and a game's intro. Games opt in via
## the registry's "uses_difficulty" flag (Game Select routes here only for those),
## so free-roam games never see this screen.
##
## The three cards are DifficultyCard instances authored in
## scenes/menus/difficulty_select.tscn — name, tag, pips and copy are all
## inspector properties, so re-wording an intensity is a scene edit. This script
## names the game in the header, pre-focuses the card matching the current
## setting (so keyboard players can just press Enter to keep their usual
## intensity), and plays the entrance.

@onready var _card_container: HBoxContainer = %CardContainer
@onready var _back_button: Button = %BackButton
@onready var _title: Label = %Title
@onready var _subtitle: Label = %Subtitle
@onready var _header: VBoxContainer = %Header

func _ready() -> void:
	_back_button.pressed.connect(_on_back_pressed)
	_fill_header()
	_wire_cards()
	_play_entrance()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_on_back_pressed()
		get_viewport().set_input_as_handled()


## Names the selected game in the header so the screen reads as a step of THAT
## game's launch ("ZOMBIE RUN — how hard?"), not a detached settings page. Falls
## back to the scene's generic title when opened directly (e.g. from the editor).
func _fill_header() -> void:
	var game: GameDef = GameManager.get_game(GameManager.get_current_game_id())
	if game == null:
		return
	_title.text = "%s — HOW HARD?" % game.title.to_upper()
	_subtitle.text = "Pick your intensity   ·   you can change it every run"


func _wire_cards() -> void:
	var current: int = int(GameManager.get_difficulty())
	for child in _card_container.get_children():
		var card := child as DifficultyCard
		if card == null:
			continue
		card.pressed.connect(_on_level_pressed.bind(card.difficulty))
		if card.difficulty == current:
			# Enter keeps the usual intensity; the focus style marks the card.
			card.grab_focus.call_deferred()


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


func _on_level_pressed(difficulty: int) -> void:
	GameManager.set_difficulty(difficulty as GameManager.Difficulty)
	# Opened mid-flow there's always a selected game; opened directly (editor)
	# there may not be — start_selected_game already no-ops with a warning then.
	GameManager.start_selected_game()


func _on_back_pressed() -> void:
	SceneManager.load_game_select()
