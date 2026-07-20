extends Node3D
## BoxingRing
##
## The centrepiece of the Boxing arena: a regulation-style raised ring built from
## simple primitives (the same procedural-box approach as [SprintTrack]) so it
## costs almost nothing and needs no imported art. Origin sits at the centre of
## the ring at floor level; the canvas surface is at [member CANVAS_Y].
##
## Layout, from the ground up: a dark platform base skirted by a sponsor-blue
## apron, a canvas deck with painted border + centre logo, four metallic corner
## posts wrapped in turnbuckle pads (red / blue neutral / white), and four rows
## of ropes strung tautly around all four sides. Purely the set — no gameplay.
class_name BoxingRing

## Half-width of the canvas deck (the fighting surface is ~2·this metres square).
const CANVAS_HALF: float = 3.3
## Height of the canvas surface above the arena floor (a raised ring).
const CANVAS_Y: float = 1.0
## Corner posts sit this far in from the platform edge, on the diagonal.
const POST_INSET: float = 0.22
## Rope heights above the canvas (four strands, low to high).
const ROPE_HEIGHTS: Array[float] = [0.42, 0.78, 1.14, 1.5]
const POST_TOP: float = 1.72       # post height above the canvas

const PLATFORM_COLOR := Color(0.06, 0.07, 0.09)
const APRON_COLOR := Color(0.09, 0.16, 0.4)      # sponsor-blue skirt
const CANVAS_COLOR := Color(0.14, 0.24, 0.52)    # blue canvas, à la reference
const CANVAS_BORDER := Color(0.86, 0.88, 0.93)
const POST_COLOR := Color(0.75, 0.77, 0.82)      # brushed steel
const ROPE_COLORS: Array[Color] = [
	Color(0.9, 0.92, 0.95), Color(0.9, 0.92, 0.95),
	Color(0.9, 0.92, 0.95), Color(0.85, 0.16, 0.16),  # red top rope
]
## Corner pad colours, one per corner (red / blue are the fighters' corners).
const PAD_COLORS: Array[Color] = [
	Color(0.82, 0.15, 0.15), Color(0.12, 0.32, 0.75),
	Color(0.9, 0.9, 0.92), Color(0.9, 0.9, 0.92),
]

var _mats: Dictionary = {}


func _ready() -> void:
	build()


## Builds the whole ring. Idempotent-ish: intended to be called once.
func build() -> void:
	_platform()
	_canvas()
	_corners_and_ropes()


# --- Structure ---------------------------------------------------------------

## The raised base: a dark structural block, a coloured apron skirt that drapes
## over its sides, and a thin trim line where the apron meets the canvas.
func _platform() -> void:
	var edge: float = CANVAS_HALF + 0.35
	_box(Vector3(edge * 2.0, CANVAS_Y, edge * 2.0),
			Vector3(0.0, CANVAS_Y * 0.5, 0.0), PLATFORM_COLOR)
	# Apron skirt: slightly proud of the base, draping the upper two-thirds.
	var skirt: float = edge + 0.06
	_box(Vector3(skirt * 2.0, CANVAS_Y * 0.62, skirt * 2.0),
			Vector3(0.0, CANVAS_Y - CANVAS_Y * 0.31, 0.0), APRON_COLOR)


## The canvas deck: a pale border frame with the coloured fighting surface inset,
## plus a faint centre-circle logo pad.
func _canvas() -> void:
	var top: float = CANVAS_Y + 0.03
	# Border frame (full deck) then the inset fighting surface on top of it.
	_box(Vector3(CANVAS_HALF * 2.0, 0.06, CANVAS_HALF * 2.0),
			Vector3(0.0, top, 0.0), CANVAS_BORDER)
	var inner: float = CANVAS_HALF - 0.22
	_box(Vector3(inner * 2.0, 0.04, inner * 2.0),
			Vector3(0.0, top + 0.02, 0.0), CANVAS_COLOR)
	# Centre logo pad — a lighter disc-ish square, just proud of the canvas.
	_box(Vector3(1.6, 0.02, 1.6), Vector3(0.0, top + 0.05, 0.0),
			CANVAS_COLOR.lightened(0.14))


# --- Posts, pads & ropes -----------------------------------------------------

## The four corner assemblies (post + stacked turnbuckle pads) and the rope runs
## strung between each adjacent pair of posts.
func _corners_and_ropes() -> void:
	var c: float = CANVAS_HALF - POST_INSET
	# Corner order: NE, NW, SW, SE (clockwise) so pads/ropes wrap consistently.
	var corners: Array[Vector3] = [
		Vector3(c, 0.0, -c), Vector3(-c, 0.0, -c),
		Vector3(-c, 0.0, c), Vector3(c, 0.0, c),
	]
	for i in corners.size():
		_corner_post(corners[i], PAD_COLORS[i])
	for i in corners.size():
		_rope_run(corners[i], corners[(i + 1) % corners.size()])


## A single corner: a steel post rising above the canvas capped with a knob, and
## three turnbuckle pads stacked up its inner face at the lower rope heights.
func _corner_post(base: Vector3, pad: Color) -> void:
	var foot := base + Vector3(0.0, CANVAS_Y + 0.03, 0.0)
	_cyl(0.06, POST_TOP, foot + Vector3(0.0, POST_TOP * 0.5, 0.0), POST_COLOR)
	# Cap knob.
	_cyl(0.09, 0.12, foot + Vector3(0.0, POST_TOP + 0.05, 0.0), POST_COLOR)
	# Padded corner: a chunky pad facing diagonally in toward ring centre.
	var inward := (-base).normalized()
	var pad_yaw := atan2(inward.x, inward.z)
	for h in [ROPE_HEIGHTS[0], ROPE_HEIGHTS[1], ROPE_HEIGHTS[2]]:
		var mi := _box(Vector3(0.34, 0.3, 0.34),
				foot + Vector3(0.0, h, 0.0), pad)
		mi.rotation.y = pad_yaw
		mi.position += inward * 0.08


## The four rope strands along one edge, from corner [param a] to corner [param b],
## each a thin taut cylinder at its rope height plus a couple of vertical lacing
## ties so the run doesn't read as four floating lines.
func _rope_run(a: Vector3, b: Vector3) -> void:
	var mid := (a + b) * 0.5
	var span := b - a
	var length: float = span.length()
	var yaw: float = atan2(span.x, span.z)
	for i in ROPE_HEIGHTS.size():
		var y: float = CANVAS_Y + 0.03 + ROPE_HEIGHTS[i]
		var mi := _cyl(0.03, length, Vector3(mid.x, y, mid.z), ROPE_COLORS[i])
		# Lay the cylinder along the edge (cylinders are Y-up by default).
		mi.rotation = Vector3(PI * 0.5, yaw, 0.0)
	# Two spiral-tie wraps binding the strands, a third and two-thirds along.
	for f in [0.34, 0.66]:
		var p: Vector3 = a.lerp(b, f)
		var lo: float = CANVAS_Y + 0.03 + ROPE_HEIGHTS[0]
		var hi: float = CANVAS_Y + 0.03 + ROPE_HEIGHTS[3]
		_box(Vector3(0.04, hi - lo, 0.04),
				Vector3(p.x, (lo + hi) * 0.5, p.z), Color(0.82, 0.82, 0.85))


# --- Primitive helpers -------------------------------------------------------

func _box(size: Vector3, pos: Vector3, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = _mat(color)
	mi.mesh = mesh
	mi.position = pos
	add_child(mi)
	return mi


func _cyl(radius: float, height: float, pos: Vector3, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 10
	mesh.material = _mat(color)
	mi.mesh = mesh
	mi.position = pos
	add_child(mi)
	return mi


## One cached material per colour (matte-ish; posts/ropes read fine without a
## dedicated metal pass and share the arena's shared spotlight).
func _mat(color: Color) -> StandardMaterial3D:
	var key := color.to_html()
	if not _mats.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = color
		m.roughness = 0.72
		m.metallic = 0.0
		_mats[key] = m
	return _mats[key]
