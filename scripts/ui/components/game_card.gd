extends Button
class_name GameCard
## GameCard
##
## One game in the launcher grid: a cinematic still filling the card face, the
## title and description clustered over its darkened lower edge, and a status
## pill saying whether it can be played right now.
##
## Game Select instances one of these per entry in GameManager's registry — it
## never hardcodes a game — so adding a game to the registry adds a card here.
## The card's look comes from the `CardButton` theme variation, so restyling
## every card is a theme edit, not a code change.

## Cinematic preview per game id (the promo captures used on the website). A
## game without an entry keeps a plain dark card face.
const PREVIEWS: Dictionary = {
	"open_world": "res://assets/game_previews/open_world.png",
	"runner": "res://assets/game_previews/runner.png",
	"sprint": "res://assets/game_previews/sprint.png",
	"boxing": "res://assets/game_previews/boxing.png",
}
const PREVIEW_SHADER: Shader = preload("res://assets/ui/card_preview.gdshader")

const ACCENT: Color = Color(1, 0.5, 0.14)
const WAIT_COLOR: Color = Color(1, 0.72, 0.3)
const TITLE_ON: Color = Color(0.96, 0.97, 0.99)
const TITLE_OFF: Color = Color(0.78, 0.81, 0.86, 0.85)
const DESC_ON: Color = Color(0.8, 0.84, 0.9, 0.92)
const DESC_OFF: Color = Color(0.68, 0.72, 0.78, 0.78)
## The still is greyed while the card is locked, matching the dimmed card face.
const PREVIEW_DIM: Color = Color(0.5, 0.52, 0.56)
## Card corner radius (mirrors the CardButton theme variation); the preview
## rounds just inside it so no square corner pokes out.
const CARD_RADIUS: float = 14.0
const HOVER_SCALE: float = 1.035

@onready var _preview: TextureRect = %Preview
@onready var _title: Label = %TitleLabel
@onready var _description: Label = %DescriptionLabel
@onready var _badge: Label = %StatusBadge

## True for a game the registry marks available. A not-yet-built game is a
## permanently locked card; an available one is only gated on the pose service.
var _available: bool = false

func _ready() -> void:
	resized.connect(func() -> void: pivot_offset = size * 0.5)
	for signal_name in ["mouse_entered", "focus_entered"]:
		connect(signal_name, _animate.bind(HOVER_SCALE))
	for signal_name in ["mouse_exited", "focus_exited"]:
		connect(signal_name, _animate.bind(1.0))


## Fills the card from one GameManager registry entry. Call right after
## instancing, before the card is shown.
func bind(game: Dictionary) -> void:
	_available = bool(game["available"])
	_title.text = String(game["title"])
	_title.add_theme_color_override("font_color", TITLE_ON if _available else TITLE_OFF)
	_description.text = String(game["description"]) if _available else "Coming soon"
	_description.add_theme_color_override("font_color", DESC_ON if _available else DESC_OFF)
	_apply_preview(String(game["id"]))
	if not _available:
		disabled = true
		focus_mode = Control.FOCUS_NONE
		mouse_default_cursor_shape = Control.CURSOR_ARROW
		_badge.text = "LOCKED"
		_badge.add_theme_color_override("font_color", DESC_OFF)
		_style_badge(false)
	else:
		# Registry-available, but launchability is gated on the pose service —
		# start locked and let set_ready() unlock once packets arrive.
		set_ready(false)


## Locks or unlocks the card to match the pose service. Games stay disabled until
## it's up and streaming, so a player never starts a body game with no tracking.
func set_ready(ready: bool) -> void:
	if not _available:
		return
	disabled = not ready
	focus_mode = Control.FOCUS_ALL if ready else Control.FOCUS_NONE
	mouse_default_cursor_shape = (
		Control.CURSOR_POINTING_HAND if ready else Control.CURSOR_ARROW
	)
	if not ready:
		scale = Vector2.ONE  # drop any leftover hover lift
	if _preview.texture != null:
		_preview.modulate = Color.WHITE if ready else PREVIEW_DIM
	_badge.text = "▶  PLAY" if ready else "◌  WAITING FOR SERVER"
	_badge.add_theme_color_override("font_color", ACCENT if ready else WAIT_COLOR)
	_style_badge(ready)


## Loads the game's promo still into the scene's preview rect and hands the
## rounded-corner shader the rect's real pixel size. That size feed MUST hang off
## the rect's OWN resize: when the card first emits `resized` this child hasn't
## been re-laid-out yet, so reading its size there returns (0,0) — which collapses
## the mask and renders the whole preview transparent.
func _apply_preview(game_id: String) -> void:
	if not PREVIEWS.has(game_id):
		return
	var tex := load(PREVIEWS[game_id]) as Texture2D
	if tex == null:
		return
	_preview.texture = tex
	var mat := ShaderMaterial.new()
	mat.shader = PREVIEW_SHADER
	mat.set_shader_parameter("radius", CARD_RADIUS - 2.0)
	mat.set_shader_parameter("rect_size", _preview.size)
	_preview.material = mat
	_preview.resized.connect(func() -> void:
		if _preview.material is ShaderMaterial:
			_preview.material.set_shader_parameter("rect_size", _preview.size))


## The status pill's background: a warm accent fill when the game is ready to
## play, a faint neutral fill while it's locked or waiting.
func _style_badge(ready: bool) -> void:
	var pill := _badge.get_theme_stylebox("normal") as StyleBoxFlat
	pill.bg_color = Color(1, 0.5, 0.14, 0.14) if ready else Color(1, 1, 1, 0.04)


## A locked (waiting-for-server) card still emits hover/focus signals; don't let
## it lift, so it reads as un-playable.
func _animate(target: float) -> void:
	if disabled and target != 1.0:
		return
	var tween := create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "scale", Vector2(target, target), 0.12)
