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

const CARD_SIZE := Vector2(340, 232)
## Not-yet-playable games render as small tiles in a strip below the hero cards,
## so the real, playable games own the top of the grid instead of sharing weight
## with a wall of large "Coming soon" rectangles.
const SOON_TILE_SIZE := Vector2(214, 104)
const HOVER_SCALE := 1.035
## Badge/status accent shown while the pose service isn't up yet.
const WAIT_COLOR := Color(1, 0.72, 0.3)

## Cinematic preview shot per game id (the promo captures used on the website).
## A game without an entry simply renders as a plain dark card.
const PREVIEWS := {
	"open_world": "res://assets/game_previews/open_world.png",
	"runner": "res://assets/game_previews/runner.png",
	"sprint": "res://assets/game_previews/sprint.png",
}
const PREVIEW_SHADER := preload("res://assets/ui/card_preview.gdshader")
## Card corner radius; the preview rounds just inside it so no square pokes out.
const CARD_RADIUS := 14
## Preview is dimmed while its card is locked (pose service still down).
const PREVIEW_DIM := Color(0.5, 0.52, 0.56)

@onready var _card_container: Container = %CardContainer
@onready var _back_button: Button = %BackButton
## Built in code under the header; tells the player why cards are locked when the
## pose service isn't up yet (and clears once it is).
var _status_label: Label

# One entry per registry-available card: { button, badge } — the "Coming soon"
# cards are never gated on the server, so they aren't tracked here. Used by
# [method _apply_server_state] to flip every playable card between "waiting" and
# "ready" as the pose service comes and goes.
var _playable_cards: Array[Dictionary] = []
# Cached pose-service state so we only restyle cards on an actual up/down change.
var _server_up: bool = false

func _ready() -> void:
	_back_button.pressed.connect(_on_back_pressed)
	_build_status_label()
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


## A line under the header explaining the locked state. Kept quiet (empty) once
## the service is up so it doesn't clutter the ready screen.
func _build_status_label() -> void:
	var header := get_node("Content/Layout/Header")
	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 18)
	header.add_child(_status_label)


func _populate_cards() -> void:
	# Playable games become full cinematic hero cards; everything not yet available
	# is collected and demoted to a compact strip beneath them (see _add_soon_section).
	var soon: Array[Dictionary] = []
	for game in GameManager.get_games():
		if bool(game["available"]):
			_card_container.add_child(_build_card(game))
		else:
			soon.append(game)
	if not soon.is_empty():
		_add_soon_section(soon)


## Re-parents the hero flow under a VBox and drops a small "more games coming"
## caption + a row of compact tiles below it. Keeping the not-yet-playable games
## small stops three big empty "Coming soon" rectangles from competing with the
## real games for attention. %CardContainer stays in the tree (still resolves).
func _add_soon_section(games: Array[Dictionary]) -> void:
	var pad := _card_container.get_parent()  # CardPad (MarginContainer)
	pad.remove_child(_card_container)

	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 22)
	pad.add_child(column)

	# The hero flow only takes the height it needs, so the strip sits right under it
	# rather than being shoved to the bottom of the scroll area.
	_card_container.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	column.add_child(_card_container)

	var caption := Label.new()
	caption.text = "MORE GAMES COMING"
	caption.add_theme_font_size_override("font_size", 16)
	caption.add_theme_color_override("font_color", Color(0.7, 0.74, 0.8, 0.85))
	column.add_child(caption)

	var strip := HFlowContainer.new()
	strip.add_theme_constant_override("h_separation", 16)
	strip.add_theme_constant_override("v_separation", 16)
	column.add_child(strip)
	for game in games:
		strip.add_child(_build_soon_tile(game))


## A compact locked tile for a not-yet-available game: just the title over a small
## "Coming soon" line, in the same dimmed dark styling as before but a fraction of
## the size of a hero card.
func _build_soon_tile(game: Dictionary) -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = SOON_TILE_SIZE
	var sb := _card_style(CARD_BG_OFF, CARD_BORDER_OFF, 1)
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	sb.content_margin_top = 14
	sb.content_margin_bottom = 14
	panel.add_theme_stylebox_override("panel", sb)

	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 5)
	panel.add_child(box)

	var title := Label.new()
	title.text = String(game["title"])
	title.add_theme_font_size_override("font_size", 21)
	title.add_theme_color_override("font_color", TITLE_OFF)
	box.add_child(title)

	var badge := Label.new()
	badge.text = "COMING SOON"
	badge.add_theme_font_size_override("font_size", 13)
	badge.add_theme_color_override("font_color", DESC_OFF)
	box.add_child(badge)
	return panel


## Locks or unlocks every playable card to match the pose service. Games stay
## disabled until the service is up and streaming, so a player never starts a
## body game with no tracking; unavailable ("Coming soon") cards are untouched.
## [param initial] suppresses the focus grab on the very first call (deferred so
## it lands after the layout settles instead).
func _apply_server_state(initial: bool) -> void:
	if _server_up:
		_status_label.text = ""
	else:
		# run.bat only exists in a dev checkout; the shipped launcher starts the
		# pose service itself, so the hint is editor-only (see main_menu.gd).
		if OS.has_feature("editor"):
			_status_label.text = "◌  Waiting for the camera service…  —  run.bat starts it; games unlock when it's ready"
		else:
			_status_label.text = "◌  Waiting for the camera service…  —  games unlock when it's ready"
		_status_label.add_theme_color_override("font_color", WAIT_COLOR)

	var first_ready: Button = null
	for entry in _playable_cards:
		var card: Button = entry["button"]
		_set_card_ready(card, entry["badge"], entry["preview"], _server_up)
		if first_ready == null and _server_up:
			first_ready = card

	# Give keyboard/gamepad users a clear selection once games are actually
	# launchable. Deferred so focus lands after the flow container settles.
	if first_ready != null and get_viewport().gui_get_focus_owner() == null:
		if initial:
			first_ready.call_deferred("grab_focus")
		else:
			first_ready.grab_focus()


## Applies the ready/waiting look to a single playable card: toggles interactivity
## and rewrites its badge. The card's normal/hover styles stay; when disabled,
## Godot swaps to the "disabled" stylebox set in [method _style_card].
func _set_card_ready(card: Button, badge: Label, preview: TextureRect, ready: bool) -> void:
	card.disabled = not ready
	card.focus_mode = Control.FOCUS_ALL if ready else Control.FOCUS_NONE
	card.mouse_default_cursor_shape = (
		Control.CURSOR_POINTING_HAND if ready else Control.CURSOR_ARROW
	)
	if not ready:
		card.scale = Vector2.ONE  # drop any leftover hover lift
	# Grey the cinematic still down while the game is locked so it matches the
	# dimmed "not yet" look of the rest of the card; full colour once playable.
	if preview != null:
		preview.modulate = Color.WHITE if ready else PREVIEW_DIM
	badge.text = "▶  PLAY" if ready else "◌  WAITING FOR SERVER"
	badge.add_theme_color_override("font_color", ACCENT if ready else WAIT_COLOR)
	_style_badge_pill(badge, ready)


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
	var badge := _build_badge(available)
	# The cinematic preview (if any) sits behind the text, filling the card face.
	var preview := _build_preview(String(game["id"]))
	if preview != null:
		card.add_child(preview)
	card.add_child(_build_card_content(game, available, badge))

	# Keep the scale pivot centred so the hover "lift" grows evenly.
	card.resized.connect(func() -> void: card.pivot_offset = card.size * 0.5)

	if available:
		# Registry-available, but launchability is gated on the pose service: track
		# the card so _apply_server_state can lock/unlock it, and start it locked.
		_playable_cards.append({"button": card, "badge": badge, "preview": preview})
		card.pressed.connect(_on_game_pressed.bind(String(game["id"])))
		card.mouse_entered.connect(_animate_card.bind(card, HOVER_SCALE))
		card.mouse_exited.connect(_animate_card.bind(card, 1.0))
		card.focus_entered.connect(_animate_card.bind(card, HOVER_SCALE))
		card.focus_exited.connect(_animate_card.bind(card, 1.0))
	return card


## The full-bleed cinematic still for a card, rounded to the card's corners with a
## bottom scrim baked in (see card_preview.gdshader). Returns null when the game
## has no promo shot, so those cards keep their plain dark face. The TextureRect
## is inset by the card border so no square corner pokes past the rounded edge.
func _build_preview(game_id: String) -> TextureRect:
	if not PREVIEWS.has(game_id):
		return null
	var tex := load(PREVIEWS[game_id]) as Texture2D
	if tex == null:
		return null

	var rect := TextureRect.new()
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Sit inside the 2px border so the border reads as a clean frame around the art.
	for side in ["offset_left", "offset_top"]:
		rect.set(side, 2)
	for side in ["offset_right", "offset_bottom"]:
		rect.set(side, -2)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.texture = tex
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED

	var mat := ShaderMaterial.new()
	mat.shader = PREVIEW_SHADER
	mat.set_shader_parameter("radius", float(CARD_RADIUS) - 2.0)
	mat.set_shader_parameter("rect_size", CARD_SIZE - Vector2(4, 4))
	rect.material = mat

	# Feed the shader the rect's real pixel size so its rounded-corner mask tracks
	# any resize. This MUST hang off the rect's OWN resize, not the parent card's:
	# when the card first emits `resized`, this child hasn't been re-laid-out yet, so
	# reading its size there returns (0,0) — which collapses the mask and renders the
	# whole preview fully transparent (COLOR.a *= 0).
	rect.resized.connect(func() -> void:
		if rect.material is ShaderMaterial:
			rect.material.set_shader_parameter("rect_size", rect.size)
	)
	return rect


func _build_card_content(game: Dictionary, available: bool, badge: Label) -> MarginContainer:
	# An overlay that ignores the mouse so clicks fall through to the Button.
	var pad := MarginContainer.new()
	pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		pad.add_theme_constant_override(side, 22)

	# Cluster the text at the bottom of the card so it reads over the preview's
	# darkened lower edge rather than washing out against the bright upper art.
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.alignment = BoxContainer.ALIGNMENT_END
	box.add_theme_constant_override("separation", 8)
	pad.add_child(box)

	var title := Label.new()
	title.text = String(game["title"])
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", TITLE_ON if available else TITLE_OFF)
	# Legibility over cinematic stills.
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	title.add_theme_constant_override("shadow_offset_x", 1)
	title.add_theme_constant_override("shadow_offset_y", 2)
	box.add_child(title)

	var desc := Label.new()
	desc.text = String(game["description"]) if available else "Coming soon"
	desc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.add_theme_font_size_override("font_size", 16)
	desc.add_theme_color_override("font_color", DESC_ON if available else DESC_OFF)
	desc.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.55))
	desc.add_theme_constant_override("shadow_offset_x", 1)
	desc.add_theme_constant_override("shadow_offset_y", 1)
	box.add_child(desc)

	box.add_child(badge)
	return pad


func _build_badge(available: bool) -> Label:
	# A small pill-style status line at the bottom of each card. Playable cards
	# start in the "waiting" look; _apply_server_state flips them to "PLAY" once the
	# pose service is up. "Coming soon" cards stay LOCKED regardless.
	var badge := Label.new()
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.add_theme_font_size_override("font_size", 15)
	badge.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	if available:
		badge.text = "◌  WAITING FOR SERVER"
		badge.add_theme_color_override("font_color", WAIT_COLOR)
		_style_badge_pill(badge, false)
	else:
		badge.text = "LOCKED"
		badge.add_theme_color_override("font_color", DESC_OFF)
		_style_badge_pill(badge, false)
	return badge


## Sets the badge's pill background: a warm orange fill when the game is ready to
## play, a faint neutral fill while it's locked/waiting.
func _style_badge_pill(badge: Label, ready: bool) -> void:
	var pill := StyleBoxFlat.new()
	pill.bg_color = Color(1, 0.5, 0.14, 0.14) if ready else Color(1, 1, 1, 0.04)
	pill.set_corner_radius_all(6)
	pill.content_margin_left = 12.0
	pill.content_margin_right = 12.0
	pill.content_margin_top = 5.0
	pill.content_margin_bottom = 5.0
	badge.add_theme_stylebox_override("normal", pill)


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
		# Shown while the pose service is down and the card is locked (disabled):
		# dimmed like a "Coming soon" card so the whole grid reads as "not yet".
		card.add_theme_stylebox_override("disabled",
			_card_style(CARD_BG_OFF, CARD_BORDER_OFF, 1, Color(0, 0, 0, 0.16), 7))
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


func _animate_card(card: Button, target: float) -> void:
	# A locked (waiting-for-server) card still emits hover/focus signals; don't let
	# it lift, so it reads as un-playable.
	if card.disabled and target != 1.0:
		return
	var tween := create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(card, "scale", Vector2(target, target), 0.12)


func _on_game_pressed(game_id: String) -> void:
	GameManager.select_game(game_id)
	# Games that scale with difficulty go through the intensity picker first;
	# free-roam games (no fail state) start straight away.
	if GameManager.uses_difficulty(game_id):
		SceneManager.load_difficulty_select()
	else:
		GameManager.start_selected_game()


func _on_back_pressed() -> void:
	SceneManager.load_main_menu()
