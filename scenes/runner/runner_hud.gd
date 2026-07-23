extends GameHUD
## RunnerHud
##
## The Infinite Runner's on-screen feedback AND its tension overlay. It owns no
## game state — runner.gd feeds it live numbers:
##   - [method set_stats]  distance covered (score) + current pace,
##   - [method set_danger] the zombie "gap" (0 safe … 1 caught) and a heartbeat
##                          pulse value, which drive the closing dark,
##   - [method set_prompt] the big coaching line ("MARCH FASTER!", "JUMP!", …),
##   - [method flash_hit]  a red slam when an obstacle is struck.
##
## DELIBERATELY SPARSE: there is no proximity gauge and no escape-route map. A
## readout that says exactly how close the zombie is turns terror into arithmetic —
## you stop feeling hunted and start managing a bar. So the only danger channel is
## the dark itself: as the gap closes the vignette squeezes the visible world down
## to a small hole, the heartbeat throbs blood into the edges and quickens, and the
## rest is your imagination. The less you see, the more you fear. Don't add a
## number back.
##
## The layout is authored in runner_hud.tscn (see CONTEXT.md §4.1) — including
## the vignette, whose shader lives in runner_vignette.gdshader; this script only
## drives it. Instance the scene, never [code]new()[/code] the class. What is
## still built here is the briefing's four control badges, because each one is a
## different animated icon rasterized at runtime.
##
## The heartbeat is computed by runner.gd and passed in, so the whole tension
## picture stays in one place there.
class_name RunnerHud

## The briefing card's control-row badge, and the icon centred inside it. The gap
## between them is the icon's breathing room and the headroom its little
## demo-loop animation swings in.
const BADGE_PX: float = 44.0
const BADGE_ICON_PX: float = 26.0

## How far the pace fill can travel: the track's width less its 2px inset either
## side. The fill is positioned by hand inside the track (a bar that drains isn't
## a container job), so the script needs the number the scene was authored with.
const PACE_TRAVEL: float = 226.0

@onready var _vignette: ColorRect = %Vignette
@onready var _lightning: ColorRect = %Lightning
@onready var _distance_value: Label = %DistanceValue
@onready var _pace_fill: Panel = %PaceFill
@onready var _prompt: Label = %Prompt

var _prompt_text: String = ""
var _last_pace: float = 0.0
# Runtime-rasterized SVG icon textures (keyed body|px).
var _icon_cache: Dictionary = {}


func _ready() -> void:
	super()
	# The chase's shouts come fast, so they clear quickly. %Toast and %Flash are
	# authored in the scene, so the base adopts them rather than building them.
	_toast_hold = 0.9


# --- live updates ------------------------------------------------------------

func set_stats(distance_m: int, pace01: float) -> void:
	_last_pace = clampf(pace01, 0.0, 1.0)
	_distance_value.text = "%d m" % distance_m
	_pace_fill.size.x = _last_pace * PACE_TRAVEL


## Updates the danger picture from the zombie [param gap] (0 safe … 1 caught) and
## the current heartbeat [param pulse] (0..1). This is the whole tell: the dark
## closes on you. It starts biting early enough that you feel the world narrowing
## before you could name why, and it never resolves into a readable amount — you
## know you're in trouble, not how much, which is the point.
func set_danger(gap: float, pulse: float) -> void:
	var g: float = clampf(gap, 0.0, 1.0)
	var mat: ShaderMaterial = _vignette.material
	mat.set_shader_parameter("intensity", smoothstep(0.12, 1.0, g))
	mat.set_shader_parameter("pulse", pulse)


func set_prompt(text: String, color: Color = TEXT) -> void:
	_prompt.add_theme_color_override("font_color", color)
	if text == _prompt_text:
		return
	_prompt_text = text
	_prompt.text = text
	# A quick fade-up so a new instruction registers as new.
	_prompt.modulate.a = 0.25
	create_tween().tween_property(_prompt, "modulate:a", 1.0, 0.18)


## A red slam when an obstacle is hit.
func flash_hit() -> void:
	flash(Color(0.9, 0.1, 0.1), 0.45, 0.4)


## A distant lightning strike: a quick cold double-flash over the whole screen.
func flash_lightning() -> void:
	var tween := create_tween()
	tween.tween_property(_lightning, "color:a", 0.5, 0.05)
	tween.tween_property(_lightning, "color:a", 0.08, 0.08)
	tween.tween_property(_lightning, "color:a", 0.42, 0.05)
	tween.tween_property(_lightning, "color:a", 0.0, 0.45)


# --- briefing card -----------------------------------------------------------

## Shows the "how to play" card for the pre-chase grace period: the goal, the four
## body controls, and a live countdown to the chase. Reassuring in tone — the
## briefing is where the player is set up to succeed before the scare kicks in.
##
## The card shell is the shared [HudBriefing]; what's specific to the chase is the
## four animated control badges, which go in as rows.
func show_briefing() -> HudBriefing:
	var card := super()
	card.set_kicker("A ZOMBIE IS ON YOUR HEELS", DANGER,
			_icon(ICON_ZOMBIE, 24.0))
	card.set_header("OUTRUN THE DEAD", "You've got this. Here's how you stay alive:")
	card.add_row(_brief_row(ICON_RUN_A, "run", "MARCH IN PLACE",
			"run — march harder to pull ahead", SAFE))
	card.add_row(_brief_row(ICON_UP, "rise", "JUMP", "leap the low barriers", TEXT))
	card.add_row(_brief_row(ICON_DOWN, "sink", "DUCK",
			"bow forward to slide under the bars", TEXT))
	card.add_row(_brief_row(ICON_LEAN, "sway", "LEAN", "dodge the wreckage", TEXT))
	card.set_countdown("CHASE BEGINS IN 10")
	# The grace period is long and the player is already marching, so back the
	# number with a draining bar — reading a digit mid-march is hard.
	card.enable_time_bar()
	return card


## One control row in the briefing card: an animated icon badge on a dark tile,
## the move name, and what it does. The badge's icon sits in a fixed Panel
## (a Panel doesn't own its children's positions, so the animation can move the
## INNER TextureRect) and loops a little demo of the move: sprint frames, a hop,
## a dip, or a sway.
func _brief_row(icon_body: String, anim: String, move_name: String, desc: String,
		accent: Color) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var badge := Panel.new()
	badge.custom_minimum_size = Vector2(BADGE_PX, BADGE_PX)
	var badge_sb := rounded(Color(0.10, 0.13, 0.19, 0.9), 12)
	badge_sb.set_border_width_all(1)
	badge_sb.border_color = PANEL_BORDER
	badge.add_theme_stylebox_override("panel", badge_sb)
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(badge)

	# Rest position: dead centre of the badge. Every animation below swings a
	# short way either side of it, so the icon never drifts out of its tile.
	var home: Vector2 = Vector2.ONE * (BADGE_PX - BADGE_ICON_PX) * 0.5
	var icon := _icon_rect(icon_body, BADGE_ICON_PX, accent)
	icon.position = home
	badge.add_child(icon)
	var tw := icon.create_tween().set_loops()
	match anim:
		"run":  # alternate the two sprint frames
			tw.tween_interval(0.24)
			tw.tween_callback(func() -> void:
				var a := _icon(ICON_RUN_A, BADGE_ICON_PX)
				icon.texture = _icon(ICON_RUN_B, BADGE_ICON_PX) \
						if icon.texture == a else a)
		"rise":  # a hop
			tw.tween_property(icon, "position:y", home.y - 4.0, 0.45) \
					.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
			tw.tween_property(icon, "position:y", home.y + 3.0, 0.45) \
					.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		"sink":  # a dip
			tw.tween_property(icon, "position:y", home.y + 4.0, 0.45) \
					.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
			tw.tween_property(icon, "position:y", home.y - 1.0, 0.45) \
					.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		_:  # "sway": lean left, lean right
			tw.tween_property(icon, "position:x", home.x - 4.0, 0.55) \
					.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
			tw.tween_property(icon, "position:x", home.x + 4.0, 0.55) \
					.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

	var move := Label.new()
	move.text = move_name
	move.custom_minimum_size = Vector2(196, 44)
	move.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	move.add_theme_font_override("font", _anton)
	move.add_theme_font_size_override("font_size", 26)
	move.add_theme_color_override("font_color", accent)
	row.add_child(move)

	var what := Label.new()
	what.text = desc
	what.custom_minimum_size = Vector2(0, 44)
	what.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	what.add_theme_font_size_override("font_size", 20)
	what.add_theme_color_override("font_color", MUTED)
	row.add_child(what)
	return row


## Updates the briefing card's live countdown (and its draining time bar) from
## the seconds remaining.
func set_briefing_countdown(seconds: float) -> void:
	if _briefing == null:
		return
	var s: int = maxi(0, int(ceil(seconds)))
	_briefing.set_countdown("GET READY…" if s <= 0 else "CHASE BEGINS IN %d" % s)
	_briefing.set_time_remaining(seconds)


# --- vector icons --------------------------------------------------------------
# Hand-drawn 24x24 SVG pictograms rasterized at runtime (no import step), drawn
# white so self_modulate tints them. One language throughout: filled heads over
# round-capped strokes, torso (SB) a touch heavier than limbs and arrows (SL).
#
# Every glyph is drawn small — 22..32px on the HUD, 28px in the briefing badges —
# so the strokes are deliberately light and the limbs kept well apart. Heavier
# strokes merge into an unreadable blob at these sizes; check any edit at TRUE
# size, not zoomed in, and keep the arrows stroked rather than solid so they
# carry the same weight as the figures beside them.

## Limb and arrow stroke.
const SL: String = 'fill="none" stroke="#fff" stroke-width="2.4" ' \
		+ 'stroke-linecap="round" stroke-linejoin="round"'
## Body-mass (torso) stroke.
const SB: String = 'fill="none" stroke="#fff" stroke-width="3.2" ' \
		+ 'stroke-linecap="round" stroke-linejoin="round"'

## Shambling zombie: head dropped forward off a heavy hunched spine, both arms
## reaching out, one leg dragging.
const ICON_ZOMBIE: String = '<circle cx="16.2" cy="5" r="2.1" fill="#fff"/>' \
		+ '<path d="M9.6 15 C10.2 11.2, 12 8.8, 14.8 8" ' + SB + '/>' \
		+ '<path d="M14 9.6 L21.4 11" ' + SL + '/>' \
		+ '<path d="M13.4 11.8 L20.4 14.2" ' + SL + '/>' \
		+ '<path d="M9.6 15 L12.8 18.2 L12.2 22" ' + SL + '/>' \
		+ '<path d="M9.6 15 L6.4 18.4 L3.2 19" ' + SL + '/>'

## Sprinting figure, frame A: full stride.
const ICON_RUN_A: String = '<circle cx="15" cy="4" r="2.1" fill="#fff"/>' \
		+ '<path d="M14.4 7 L11.2 13.8" ' + SB + '/>' \
		+ '<path d="M13.4 9 L17.6 10.4 L20 7.6" ' + SL + '/>' \
		+ '<path d="M13.4 9 L9 10.2 L6.2 13" ' + SL + '/>' \
		+ '<path d="M11.2 13.8 L15.6 16 L17.2 21" ' + SL + '/>' \
		+ '<path d="M11.2 13.8 L6.8 15.4 L4 12.8" ' + SL + '/>'

## Sprinting figure, frame B: legs passing under the body.
const ICON_RUN_B: String = '<circle cx="15" cy="4" r="2.1" fill="#fff"/>' \
		+ '<path d="M14.4 7 L11.2 13.8" ' + SB + '/>' \
		+ '<path d="M13.4 9 L16.6 11.2 L15 14" ' + SL + '/>' \
		+ '<path d="M13.4 9 L10 10.8 L9.6 13.6" ' + SL + '/>' \
		+ '<path d="M11.2 13.8 L13.4 17.4 L12.6 21.4" ' + SL + '/>' \
		+ '<path d="M11.2 13.8 L8.4 17.2 L10.4 20.6" ' + SL + '/>'

## Jump: an up arrow.
const ICON_UP: String = '<path d="M12 20.4 L12 5.2" ' + SL + '/>' \
		+ '<path d="M6.4 10.6 L12 4.6 L17.6 10.6" ' + SL + '/>'

## Squat/slide: a down arrow ducking under a bar.
const ICON_DOWN: String = '<path d="M4.6 3.6 L19.4 3.6" ' + SL + '/>' \
		+ '<path d="M12 8.4 L12 20.4" ' + SL + '/>' \
		+ '<path d="M6.4 14.8 L12 20.8 L17.6 14.8" ' + SL + '/>'

## Lean: a double-headed side-to-side arrow.
const ICON_LEAN: String = '<path d="M4.6 12 L19.4 12" ' + SL + '/>' \
		+ '<path d="M9.4 6.6 L3.6 12 L9.4 17.4" ' + SL + '/>' \
		+ '<path d="M14.6 6.6 L20.4 12 L14.6 17.4" ' + SL + '/>'


## Rasterizes (and caches) one icon body at [param px] square.
func _icon(body: String, px: float) -> ImageTexture:
	var key := "%s|%d" % [body, int(px)]
	if _icon_cache.has(key):
		return _icon_cache[key]
	var svg := '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">' \
			+ body + '</svg>'
	var img := Image.new()
	img.load_svg_from_string(svg, px * 2.0 / 24.0)  # 2x for crispness when scaled
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_icon_cache[key] = tex
	return tex


## A [param px]-square TextureRect showing an icon, tinted [param tint], with its
## pivot centred so rotation/scale animations swing naturally.
func _icon_rect(body: String, px: float, tint: Color = Color.WHITE) -> TextureRect:
	var tr := TextureRect.new()
	# expand_mode MUST be set before size: while it is still the default
	# EXPAND_KEEP_SIZE, the texture's own (2x-supersampled) resolution acts as the
	# minimum size, and set_size() silently clamps up to it — which drew every
	# icon at double its px and pushed it off-centre in its badge.
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.texture = _icon(body, px)
	tr.custom_minimum_size = Vector2(px, px)
	tr.size = Vector2(px, px)
	tr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	tr.pivot_offset = Vector2(px, px) * 0.5
	tr.self_modulate = tint
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tr
