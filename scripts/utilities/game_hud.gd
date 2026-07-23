extends CanvasLayer
## GameHUD
##
## The base every in-game HUD extends. It owns the chrome that is meant to look
## the same in every game — the palette, the translucent slate chip, the
## full-screen hit flash, the upper-centre toast and the pre-game briefing card —
## so a new game's HUD only has to build the part that is actually that game.
##
## What belongs here vs. in the game's own HUD:
##   - HERE: anything a player should not be able to tell apart between games.
##     If Boxing's toast popped differently from Hurdle Dash's, that would read as
##     a bug, not as character.
##   - THERE: the readouts that ARE the game — Boxing's health bars and round
##     clock, Hurdle Dash's field strip and placing, Zombie Run's closing dark.
##     Those are the point; this class deliberately says nothing about them.
##
## Before this existed the three HUDs each carried their own copy of the six
## palette colours and their own [method chip] (two of them byte-identical, the
## third quietly shipping a heavier shadow), so the shared look drifted apart by
## accident. Add shared chrome here, not in a fourth copy.
##
## Subclasses MUST call [code]super()[/code] from their own [method _ready] — the
## base loads the display font every HUD builds its values from.
class_name GameHUD

## The app palette. Identical in every game by design; change it once here.
const ACCENT: Color = Color(1.0, 0.5, 0.14)
const TEXT: Color = Color(0.96, 0.97, 0.99)
const MUTED: Color = Color(0.72, 0.76, 0.82)
const SAFE: Color = Color(0.30, 0.75, 0.42)
const WARN: Color = Color(0.95, 0.65, 0.15)
const DANGER: Color = Color(0.90, 0.16, 0.16)

## The shared surface treatment: every HUD block sits on the same translucent
## slate chip (matching the main menu's profile chip) so nothing floats as raw
## text over the scene.
const PANEL_BG: Color = Color(0.05, 0.07, 0.11, 0.72)
const PANEL_BORDER: Color = Color(1, 1, 1, 0.10)

const BRIEFING_SCENE: PackedScene = preload(
		"res://scenes/ui/components/hud_briefing.tscn")

## The display face used for values and shouts across every HUD.
const ANTON_PATH: String = "res://assets/fonts/Anton-Regular.ttf"

var _anton: Font
var _flash: ColorRect
var _toast: Label
## How long a toast holds at full opacity before fading. Games tune this in
## [method _build_toast]; a race can afford a longer read than a chase can.
var _toast_hold: float = 0.9
var _briefing: HudBriefing


func _ready() -> void:
	_anton = load(ANTON_PATH)
	_adopt_scene_chrome()


## HUDs authored as a .tscn (the direction every HUD is moving — see
## CONTEXT.md §4.1) declare the shared chrome as nodes named %Flash and %Toast,
## and the base adopts them here. The HUDs still built in code call
## [method _build_flash] / [method _build_toast] from their own _ready instead.
func _adopt_scene_chrome() -> void:
	var flash_node: Node = get_node_or_null("%Flash")
	if flash_node is ColorRect:
		_flash = flash_node
	var toast_node: Node = get_node_or_null("%Toast")
	if toast_node is Label:
		_toast = toast_node


# --- Styleboxes --------------------------------------------------------------

func rounded(color: Color, radius: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(radius)
	return sb


## The shared HUD chip: translucent slate, hairline border, soft drop shadow —
## the same treatment the app's menu chips use, so the HUD belongs to the app.
## Corner radius and padding are per-block (a tall stats chip and a one-line
## clock chip want different breathing room); the colours and shadow are not.
func chip(radius: int = 10, margin_h: float = 18.0, margin_top: float = 10.0,
		margin_bottom: float = 12.0) -> StyleBoxFlat:
	var sb := rounded(PANEL_BG, radius)
	sb.set_border_width_all(1)
	sb.border_color = PANEL_BORDER
	sb.content_margin_left = margin_h
	sb.content_margin_right = margin_h
	sb.content_margin_top = margin_top
	sb.content_margin_bottom = margin_bottom
	sb.shadow_color = Color(0, 0, 0, 0.25)
	sb.shadow_size = 8
	return sb


# --- Motion ------------------------------------------------------------------

## The shared "this is new, look at it" pop: [param control] snaps to
## [param from] scale and springs back. Used by prompts, combo tallies, starter
## calls and result cards, which is why it lives here rather than being written
## out at each call site.
func pop(control: Control, from: float = 1.25, duration: float = 0.18) -> void:
	control.pivot_offset = control.size * 0.5
	control.scale = Vector2(from, from)
	var tween := create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(control, "scale", Vector2.ONE, duration)


# --- Full-screen flash -------------------------------------------------------

## Adds the full-screen flash sheet. Call it early: it is drawn in child order,
## so anything added after it sits on top.
func _build_flash() -> void:
	_flash = ColorRect.new()
	_flash.color = Color(0.9, 0.1, 0.1, 0.0)
	_flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_flash)


## A full-screen colour slam that fades out — red when the player is hurt, but
## games use it for their own beats too (Boxing slams gold on a landed hit).
func flash(color: Color, alpha: float = 0.4, duration: float = 0.4) -> void:
	if _flash == null:
		return
	_flash.color = Color(color.r, color.g, color.b, alpha)
	create_tween().tween_property(_flash, "color:a", 0.0, duration)


# --- Toast -------------------------------------------------------------------

## Creates the toast label with the shared treatment (display face, heavy
## outline, soft shadow, starts invisible) and adds it. The caller positions it
## afterwards — where the shout belongs depends on what else that game's HUD is
## using the upper screen for.
func _build_toast(font_size: int, hold: float = 0.9) -> Label:
	_toast_hold = hold
	_toast = Label.new()
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_toast.add_theme_font_override("font", _anton)
	_toast.add_theme_font_size_override("font_size", font_size)
	_toast.add_theme_constant_override("outline_size", 8)
	_toast.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.78))
	_toast.add_theme_constant_override("shadow_offset_x", 2)
	_toast.add_theme_constant_override("shadow_offset_y", 4)
	_toast.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	_toast.modulate.a = 0.0
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_toast)
	return _toast


## A short-lived shout in the upper screen (milestones, HIT, hurdle bonuses). It
## springs in, holds, and fades; a new call interrupts the last.
func flash_toast(text: String, color: Color = TEXT) -> void:
	if _toast == null:
		return
	_toast.text = text
	_toast.add_theme_color_override("font_color", color)
	_toast.pivot_offset = _toast.size * 0.5
	_toast.scale = Vector2(1.25, 1.25)
	_toast.modulate.a = 0.0
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(_toast, "modulate:a", 1.0, 0.14)
	tween.tween_property(_toast, "scale", Vector2.ONE, 0.28) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.set_parallel(false)
	tween.tween_interval(_toast_hold)
	tween.tween_property(_toast, "modulate:a", 0.0, 0.4)


# --- Briefing ----------------------------------------------------------------

## Instantiates the shared pre-game briefing card and returns it for the game to
## fill in (header, control rows, countdown wording). Returns the existing card
## if one is already up, so a double call can't stack two.
func show_briefing() -> HudBriefing:
	if _briefing == null:
		_briefing = BRIEFING_SCENE.instantiate()
		add_child(_briefing)
	return _briefing


func hide_briefing() -> void:
	if _briefing == null:
		return
	_briefing.dismiss()
	_briefing = null
