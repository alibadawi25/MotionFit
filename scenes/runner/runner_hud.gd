extends GameHUD
## RunnerHud
##
## The Infinite Runner's on-screen feedback AND its tension overlay, built in code
## to match the shared app mood (dark chips, Anton values) with a danger layer on
## top. It owns no game state — runner.gd feeds it live numbers:
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
## The vignette is a shader ColorRect added first (so it sits behind the chips);
## the heartbeat is computed by runner.gd and passed in, so the whole tension
## picture stays in one place there.
class_name RunnerHud

## The closing dark: the game's ONLY proximity readout. [code]intensity[/code]
## (0…1, from the gap) drags the vignette's clear centre from a wide cinematic
## frame down to a narrow tunnel, so danger is felt as the world being taken away
## rather than read off a scale. Blood only bleeds in on the heartbeat, and the
## edge crawls with grain + a slow breathing wobble so the dark never sits still
## and the eye keeps hunting movement in it.
const VIGNETTE_SHADER: String = """
shader_type canvas_item;
uniform float intensity : hint_range(0.0, 1.0) = 0.0;
uniform float pulse : hint_range(0.0, 1.0) = 0.0;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(41.3, 289.1))) * 43758.5453);
}

void fragment() {
	vec2 d = UV - vec2(0.5);
	d.x *= 1.12;  // squeeze horizontally so a wide screen still tunnels
	float r = length(d) * 1.5;

	// The hole you can still see through. It clenches with the heartbeat, and
	// breathes slightly even when you're safe, so the frame is never quite still.
	float breathe = sin(TIME * 1.7) * 0.012;
	float inner = mix(0.60, 0.07, intensity) - pulse * 0.06 * intensity + breathe;
	float outer = mix(1.20, 0.46, intensity);
	float vig = smoothstep(inner, outer, r);

	// Near-black by default: it reads as the light dying, not as a red filter.
	// Blood washes in only on the beat, and only once the threat is real.
	vec3 col = mix(vec3(0.0), vec3(0.34, 0.0, 0.0), pulse * intensity);
	float a = vig * (0.42 + 0.58 * intensity);
	// Grain in the murk — gives the dark texture to hide things in.
	a += (hash(UV * vec2(640.0, 360.0) + fract(TIME) * 97.0) - 0.5) * 0.06 * intensity;
	COLOR = vec4(col, clamp(a, 0.0, 0.985));
}
"""

## The briefing card's control-row badge, and the icon centred inside it. The gap
## between them is the icon's breathing room and the headroom its little
## demo-loop animation swings in.
const BADGE_PX: float = 44.0
const BADGE_ICON_PX: float = 26.0

var _vignette: ColorRect
var _lightning: ColorRect
var _distance_value: Label
var _pace_fill: Panel
var _prompt: Label
var _prompt_text: String = ""
var _last_pace: float = 0.0
# Runtime-rasterized SVG icon textures (keyed body|px).
var _icon_cache: Dictionary = {}


func _ready() -> void:
	super()
	_build_vignette()
	_build_stats()
	_build_prompt()
	_build_toast(40, 0.9)
	_position_toast()


## The vignette goes down first so the chips sit on top of it, then the hit
## flash (from [GameHUD]) and the lightning sheet over everything.
func _build_vignette() -> void:
	var shader := Shader.new()
	shader.code = VIGNETTE_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = shader
	_vignette = ColorRect.new()
	_vignette.material = mat
	_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_vignette)

	_build_flash()

	# A cold blue-white sheet for the distant lightning scare (see flash_lightning).
	_lightning = ColorRect.new()
	_lightning.color = Color(0.7, 0.8, 1.0, 0.0)
	_lightning.set_anchors_preset(Control.PRESET_FULL_RECT)
	_lightning.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_lightning)


## Top-left: DISTANCE (the score) as a big Anton value over a small pace bar,
## sitting on a shared chip so it reads as an instrument, not floating text.
func _build_stats() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.offset_left = 36.0
	panel.offset_top = 28.0
	panel.add_theme_stylebox_override("panel", chip(16, 22.0, 14.0, 14.0))
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(box)

	var cap := Label.new()
	cap.text = "DISTANCE"
	cap.add_theme_font_size_override("font_size", 14)
	cap.add_theme_color_override("font_color", MUTED)
	box.add_child(cap)

	_distance_value = Label.new()
	_distance_value.text = "0 m"
	_distance_value.add_theme_font_override("font", _anton)
	_distance_value.add_theme_font_size_override("font_size", 52)
	_distance_value.add_theme_color_override("font_color", TEXT)
	box.add_child(_distance_value)

	box.add_child(_spacer(6))

	# A slim pace bar so the player sees marching harder = running faster.
	var pace_cap := Label.new()
	pace_cap.text = "PACE"
	pace_cap.add_theme_font_size_override("font_size", 12)
	pace_cap.add_theme_color_override("font_color", MUTED)
	box.add_child(pace_cap)

	var track := Panel.new()
	track.custom_minimum_size = Vector2(230, 14)
	var track_sb := rounded(Color(0.03, 0.04, 0.07, 0.9), 7)
	track_sb.set_border_width_all(1)
	track_sb.border_color = PANEL_BORDER
	track.add_theme_stylebox_override("panel", track_sb)
	box.add_child(track)
	_pace_fill = Panel.new()
	_pace_fill.position = Vector2(2, 2)
	_pace_fill.size = Vector2(0, 10)
	_pace_fill.add_theme_stylebox_override("panel", rounded(ACCENT, 5))
	track.add_child(_pace_fill)


## Bottom-centre coaching line over a soft dark gradient band, outlined so it
## stays readable whatever the road behind it is doing.
func _build_prompt() -> void:
	var band := TextureRect.new()
	band.texture = _hband_texture()
	band.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	band.offset_bottom = -84.0
	band.offset_top = -156.0
	band.stretch_mode = TextureRect.STRETCH_SCALE
	band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(band)

	_prompt = Label.new()
	_prompt.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_prompt.offset_bottom = -90.0
	_prompt.offset_top = -150.0
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_prompt.add_theme_font_override("font", _anton)
	_prompt.add_theme_font_size_override("font_size", 46)
	_prompt.add_theme_color_override("font_color", TEXT)
	_prompt.add_theme_constant_override("outline_size", 10)
	_prompt.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_prompt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_prompt)


## The chase's shouts span the top of the screen, under the distance chip.
func _position_toast() -> void:
	_toast.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_toast.offset_top = 168.0
	_toast.offset_bottom = 240.0


# --- live updates ------------------------------------------------------------

func set_stats(distance_m: int, pace01: float) -> void:
	_last_pace = clampf(pace01, 0.0, 1.0)
	if _distance_value != null:
		_distance_value.text = "%d m" % distance_m
	if _pace_fill != null:
		_pace_fill.size.x = _last_pace * 226.0


## Updates the danger picture from the zombie [param gap] (0 safe … 1 caught) and
## the current heartbeat [param pulse] (0..1). This is the whole tell: the dark
## closes on you. It starts biting early enough that you feel the world narrowing
## before you could name why, and it never resolves into a readable amount — you
## know you're in trouble, not how much, which is the point.
func set_danger(gap: float, pulse: float) -> void:
	if _vignette == null:
		return
	var g: float = clampf(gap, 0.0, 1.0)
	var mat: ShaderMaterial = _vignette.material
	mat.set_shader_parameter("intensity", smoothstep(0.12, 1.0, g))
	mat.set_shader_parameter("pulse", pulse)


func set_prompt(text: String, color: Color = TEXT) -> void:
	if _prompt == null:
		return
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
	if _lightning == null:
		return
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


func _spacer(height: int) -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, height)
	s.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return s


## Updates the briefing card's live countdown (and its draining time bar) from
## the seconds remaining.
func set_briefing_countdown(seconds: float) -> void:
	if _briefing == null:
		return
	var s: int = maxi(0, int(ceil(seconds)))
	_briefing.set_countdown("GET READY…" if s <= 0 else "CHASE BEGINS IN %d" % s)
	_briefing.set_time_remaining(seconds)


## A wide soft horizontal gradient band (transparent → dark → transparent), used
## to ground the coaching line against the busy road.
func _hband_texture() -> GradientTexture2D:
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.28, 0.72, 1.0])
	grad.colors = PackedColorArray([
		Color(0, 0, 0, 0.0), Color(0, 0, 0, 0.45),
		Color(0, 0, 0, 0.45), Color(0, 0, 0, 0.0),
	])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.width = 512
	tex.height = 8
	tex.fill_from = Vector2(0.0, 0.0)
	tex.fill_to = Vector2(1.0, 0.0)
	return tex


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
