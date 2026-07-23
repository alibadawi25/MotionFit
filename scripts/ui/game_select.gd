extends Control
## GameSelect
##
## Builds the grid of game cards from GameManager's registry — it does NOT
## hardcode any game. Add a game to the registry and a card appears here
## automatically. Games that aren't playable yet are demoted to a compact strip
## below the hero cards, so three big empty "Coming soon" rectangles never
## compete with the real games for attention.
##
## The screen's shell (background, header, scroll region, the hero flow and the
## "coming soon" section) is authored in scenes/menus/game_select.tscn; the cards
## themselves are instances of the reusable GameCard / SoonTile components, which
## own their own look. This script only reads the registry and keeps the cards in
## step with the pose service.

const GAME_CARD: PackedScene = preload("res://scenes/ui/components/game_card.tscn")
const SOON_TILE: PackedScene = preload("res://scenes/ui/components/soon_tile.tscn")

@onready var _card_container: HFlowContainer = %CardContainer
@onready var _soon_section: VBoxContainer = %SoonSection
@onready var _soon_strip: HFlowContainer = %SoonStrip
@onready var _status_label: Label = %StatusLabel
@onready var _back_button: Button = %BackButton

## Every playable card, so [method _apply_server_state] can flip them all between
## "waiting" and "ready" as the pose service comes and goes. "Coming soon" tiles
## are never gated on the server, so they aren't tracked.
var _playable_cards: Array[GameCard] = []
## Cached pose-service state so we only restyle cards on an actual up/down change.
var _server_up: bool = false

func _ready() -> void:
	_back_button.pressed.connect(SceneManager.load_main_menu)
	_populate_cards()
	# Reflect the server's current state immediately (games launch with it down),
	# then keep it in sync from _process.
	_server_up = MotionManager.is_receiving()
	_apply_server_state(true)


func _process(_delta: float) -> void:
	# The pose service may start after this screen opens; unlock the cards the
	# moment packets begin arriving (and re-lock if it stops).
	var up: bool = MotionManager.is_receiving()
	if up != _server_up:
		_server_up = up
		_apply_server_state(false)


func _populate_cards() -> void:
	for game in GameManager.get_games():
		if game.available:
			var card: GameCard = GAME_CARD.instantiate()
			_card_container.add_child(card)
			card.bind(game)
			card.pressed.connect(_on_game_pressed.bind(game.id))
			_playable_cards.append(card)
		else:
			var tile: PanelContainer = SOON_TILE.instantiate()
			_soon_strip.add_child(tile)
			(tile.get_node("%TitleLabel") as Label).text = game.title
	_soon_section.visible = _soon_strip.get_child_count() > 0


## Locks or unlocks every playable card to match the pose service, and explains
## why in the header line (which clears once the service is up, so it doesn't
## clutter the ready screen). [param initial] suppresses the immediate focus grab
## on the very first call — it's deferred so it lands after layout settles.
func _apply_server_state(initial: bool) -> void:
	_status_label.visible = not _server_up
	if not _server_up:
		# run.bat only exists in a dev checkout; the shipped launcher starts the
		# pose service itself, so the hint is editor-only (see main_menu.gd).
		if OS.has_feature("editor"):
			_status_label.text = "◌  Waiting for the camera service…  —  run.bat starts it; games unlock when it's ready"
		else:
			_status_label.text = "◌  Waiting for the camera service…  —  games unlock when it's ready"

	for card in _playable_cards:
		card.set_ready(_server_up)

	# Give keyboard/gamepad users a clear selection once games are actually
	# launchable. Deferred so focus lands after the flow container settles.
	if _server_up and not _playable_cards.is_empty() \
			and get_viewport().gui_get_focus_owner() == null:
		if initial:
			_playable_cards[0].call_deferred("grab_focus")
		else:
			_playable_cards[0].grab_focus()


func _on_game_pressed(game_id: String) -> void:
	GameManager.select_game(game_id)
	# Games that scale with difficulty go through the intensity picker first;
	# free-roam games (no fail state) start straight away.
	if GameManager.uses_difficulty(game_id):
		SceneManager.load_difficulty_select()
	else:
		GameManager.start_selected_game()
