extends SubViewport
## Boxing jumbotron fight card.
##
## Renders the "who vs who" main-event card that shows on the four faces of the
## arena's centre-hung jumbotron. It is a plain [SubViewport] whose [ColorRect] +
## [Label] children are drawn to a texture; [BoxingArena] hangs that texture on the
## screen boxes (unshaded + emissive, so it reads as a lit screen from any angle).
##
## Preloaded by path (no class_name) so it needs no global-class-cache refresh.
## Call [method configure] to set the two fighters' names and the strapline; the
## top marquee pulses so the board never looks like a frozen still.

## Card resolution — a ~3:1 landscape to match the screen boxes' proportions.
const W: int = 1024
const H: int = 340

const NAVY_L := Color(0.07, 0.12, 0.30)     # blue-corner half
const NAVY_R := Color(0.30, 0.08, 0.11)     # red-corner half
const BAR := Color(0.03, 0.03, 0.05)
const GOLD := Color(0.97, 0.81, 0.33)
const COOL := Color(0.55, 0.72, 1.0)
const HOT := Color(0.98, 0.52, 0.46)
const INK := Color(0, 0, 0, 0.75)

var _font: Font
var _marquee: Label
var _p_name: Label
var _o_name: Label
var _sub: Label
var _t: float = 0.0


func _ready() -> void:
	size = Vector2i(W, H)
	render_target_update_mode = SubViewport.UPDATE_ALWAYS
	transparent_bg = false
	_font = load("res://assets/fonts/Anton-Regular.ttf")
	_build()


## Sets the two corners' names and the strapline (e.g. "MAIN EVENT · 3 ROUNDS").
## Names are shown upper-cased; the font shrinks a step for long ones so they fit.
func configure(player_name: String, opp_name: String, subtitle: String) -> void:
	if _p_name == null:
		return
	_set_fighter(_p_name, player_name)
	_set_fighter(_o_name, opp_name)
	_sub.text = subtitle.to_upper()


## A slow pulse on the marquee so the board reads as a live screen, not a decal.
func _process(delta: float) -> void:
	_t += delta
	if _marquee != null:
		_marquee.modulate.a = 0.72 + 0.28 * (0.5 + 0.5 * sin(_t * 3.2))


func _build() -> void:
	_half(Vector2(0, 0), NAVY_L)
	_half(Vector2(W * 0.5, 0), NAVY_R)
	# Centre seam so the two corners meet on a crisp line.
	var seam := ColorRect.new()
	seam.color = BAR
	seam.position = Vector2(W * 0.5 - 3, 40)
	seam.size = Vector2(6, H - 80)
	add_child(seam)

	var top := _strip(0, 56, BAR)
	_marquee = _label("★   MAIN EVENT   ★", GOLD, 34, top.position.y + 4, 56)
	var bottom := _strip(H - 46, 46, BAR)
	_sub = _label("3 ROUNDS · TITLE BOUT", Color(0.86, 0.88, 0.95), 24,
			bottom.position.y + 2, 42)

	_p_name = _fighter_label(0)
	_o_name = _fighter_label(1)
	_corner_tag("BLUE CORNER", COOL, 0)
	_corner_tag("RED CORNER", HOT, 1)

	var vs := _label("VS", GOLD, 88, H * 0.5 - 66, 132)
	vs.add_theme_constant_override("outline_size", 16)


# --- widget helpers ----------------------------------------------------------

func _half(pos: Vector2, color: Color) -> void:
	var r := ColorRect.new()
	r.color = color
	r.position = pos
	r.size = Vector2(W * 0.5, H)
	add_child(r)


func _strip(y: float, h: float, color: Color) -> ColorRect:
	var r := ColorRect.new()
	r.color = color
	r.position = Vector2(0, y)
	r.size = Vector2(W, h)
	add_child(r)
	return r


## A full-width centred label, positioned by top edge + row height.
func _label(text: String, color: Color, font_size: int, y: float,
		h: float) -> Label:
	var l := Label.new()
	l.text = text
	l.position = Vector2(0, y)
	l.size = Vector2(W, h)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if _font != null:
		l.add_theme_font_override("font", _font)
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_constant_override("outline_size", 8)
	l.add_theme_color_override("font_outline_color", INK)
	add_child(l)
	return l


## The big fighter name centred in one half ([param col] 0 = left, 1 = right).
func _fighter_label(col: int) -> Label:
	var l := Label.new()
	l.text = "FIGHTER"
	l.position = Vector2(col * W * 0.5 + 24, H * 0.42 - 52)
	l.size = Vector2(W * 0.5 - 48, 104)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if _font != null:
		l.add_theme_font_override("font", _font)
	l.add_theme_font_size_override("font_size", 66)
	l.add_theme_color_override("font_color", Color.WHITE)
	l.add_theme_constant_override("outline_size", 10)
	l.add_theme_color_override("font_outline_color", INK)
	add_child(l)
	return l


func _corner_tag(text: String, color: Color, col: int) -> void:
	var l := Label.new()
	l.text = text
	l.position = Vector2(col * W * 0.5, H * 0.72)
	l.size = Vector2(W * 0.5, 40)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if _font != null:
		l.add_theme_font_override("font", _font)
	l.add_theme_font_size_override("font_size", 26)
	l.add_theme_color_override("font_color", color)
	l.add_theme_constant_override("outline_size", 6)
	l.add_theme_color_override("font_outline_color", INK)
	add_child(l)


## Fits a name into a corner: upper-cased, and a step smaller when it's long.
func _set_fighter(label: Label, name: String) -> void:
	var text := name.strip_edges().to_upper()
	if text.is_empty():
		text = "CHALLENGER"
	label.text = text
	label.add_theme_font_size_override("font_size", 48 if text.length() > 9 else 66)
