extends Object
## Code-built low-poly animals for the open world's wildlife (companion file to
## scatter_meshes.gd — same rules: chunky primitives, no textures, vertex-color-
## as-albedo so MultiMesh instance tints can vary individuals, authored at
## natural size in metres). Ground dwellers keep their origin at ground level
## like the scatter meshes; the two BIRDS are authored around their body centre
## instead (a flyer has no ground to stand on — the spawner owns their height).
##
## One builder per species, each picked for a biome the island already has:
## deer + songbird for the woods, fox for the dusk treeline, rabbit for the
## meadows, gull for the shore, butterfly for the grass and flower bands. All
## face +Z; a wildlife system yaws whole instances, it never re-poses parts.

const _FAWN := Color(0.5, 0.36, 0.22)
const _CREAM := Color(0.86, 0.79, 0.67)
const _ANTLER := Color(0.24, 0.18, 0.12)
const _RUST := Color(0.72, 0.34, 0.12)
const _SNOW := Color(0.9, 0.88, 0.84)
const _SOOT := Color(0.16, 0.12, 0.1)
const _BURROW := Color(0.52, 0.45, 0.38)
const _GULL_BODY := Color(0.93, 0.94, 0.96)
const _GULL_WING := Color(0.55, 0.58, 0.63)
const _BEAK := Color(0.95, 0.55, 0.1)
const _OLIVE := Color(0.4, 0.36, 0.28)
const _ROBIN := Color(0.85, 0.45, 0.2)
const _FLUTTER := Color(0.75, 0.45, 0.9)


## A red deer, ~1.7 m to the antler tips — the woods' flagship sighting.
static func build_deer() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var hide: Array = [
		_blob(0.34, Vector3(0.85, 0.8, 1.5), Vector3(0, 0.78, 0)),
		_limb(Vector3(0, 0.95, 0.42), Vector3(0, 0.8, 0.45), 0.36, 0.12, 0.08),
		_blob(0.14, Vector3(0.85, 0.9, 1.15), Vector3(0, 1.33, 0.63)),
		_limb(Vector3(0.07, 1.40, 0.57), Vector3(0.5, 0.85, -0.1), 0.14, 0.035, 0.005),
		_limb(Vector3(-0.07, 1.40, 0.57), Vector3(-0.5, 0.85, -0.1), 0.14, 0.035, 0.005),
	]
	for x in [-0.13, 0.13]:
		for z in [-0.34, 0.34]:
			hide.append(_limb(Vector3(x, 0.02, z), Vector3.UP, 0.58, 0.055, 0.05))
	_append(mesh, hide, _material(_FAWN, 0.95))

	_append(mesh, [
		_limb(Vector3(0, 1.31, 0.72), Vector3(0, -0.05, 1), 0.14, 0.058, 0.038),
		_blob(0.07, Vector3(0.8, 1.0, 0.8), Vector3(0, 0.95, -0.52)),
	], _material(_CREAM, 0.95))

	var antlers: Array = [
		_blob(0.018, Vector3.ONE, Vector3(0.062, 1.37, 0.70)),
		_blob(0.018, Vector3.ONE, Vector3(-0.062, 1.37, 0.70)),
	]
	for side in [-1.0, 1.0]:
		antlers.append(_limb(Vector3(side * 0.06, 1.42, 0.59),
				Vector3(side * 0.25, 1.0, -0.2), 0.28, 0.02, 0.012))
		antlers.append(_limb(Vector3(side * 0.11, 1.58, 0.54),
				Vector3(side * 0.15, 0.9, 0.35), 0.16, 0.015, 0.008))
	_append(mesh, antlers, _material(_ANTLER, 0.9))
	return mesh


## A fox, ~0.5 m at the ears — the treeline at dusk.
static func build_fox() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	_append(mesh, [
		_blob(0.16, Vector3(0.85, 0.8, 1.5), Vector3(0, 0.30, 0)),
		_blob(0.095, Vector3(0.85, 0.9, 1.0), Vector3(0, 0.42, 0.26)),
		_limb(Vector3(0, 0.40, 0.32), Vector3(0, -0.1, 1), 0.12, 0.045, 0.015),
		_limb(Vector3(0, 0.30, -0.20), Vector3(0, 0.35, -1), 0.34, 0.075, 0.05),
	], _material(_RUST, 0.95))

	_append(mesh, [
		_blob(0.10, Vector3(0.8, 0.9, 0.9), Vector3(0, 0.30, 0.18)),
		_blob(0.055, Vector3.ONE, Vector3(0, 0.41, -0.52)),
	], _material(_SNOW, 0.95))

	var darks: Array = [
		_limb(Vector3(0.055, 0.50, 0.24), Vector3(0.3, 1.0, -0.05), 0.10, 0.035, 0.004),
		_limb(Vector3(-0.055, 0.50, 0.24), Vector3(-0.3, 1.0, -0.05), 0.10, 0.035, 0.004),
		_blob(0.014, Vector3.ONE, Vector3(0.048, 0.45, 0.33)),
		_blob(0.014, Vector3.ONE, Vector3(-0.048, 0.45, 0.33)),
	]
	for x in [-0.07, 0.07]:
		for z in [-0.15, 0.15]:
			darks.append(_limb(Vector3(x, 0.01, z), Vector3.UP, 0.24, 0.032, 0.028))
	_append(mesh, darks, _material(_SOOT, 0.95))
	return mesh


## A rabbit, ~0.35 m to the ear tips — the meadows' movement in the grass.
static func build_rabbit() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	_append(mesh, [
		_blob(0.15, Vector3(0.9, 0.85, 1.15), Vector3(0, 0.15, 0)),
		_blob(0.085, Vector3(0.9, 0.9, 1.0), Vector3(0, 0.28, 0.15)),
		_limb(Vector3(0.035, 0.32, 0.12), Vector3(0.12, 1.0, -0.25), 0.17, 0.028, 0.012),
		_limb(Vector3(-0.035, 0.32, 0.12), Vector3(-0.12, 1.0, -0.25), 0.17, 0.028, 0.012),
	], _material(_BURROW, 0.95))

	_append(mesh, [
		_blob(0.05, Vector3.ONE, Vector3(0, 0.16, -0.17)),
		_blob(0.06, Vector3(0.85, 0.8, 0.9), Vector3(0, 0.13, 0.11)),
	], _material(_CREAM, 0.95))

	_append(mesh, [
		_blob(0.013, Vector3.ONE, Vector3(0.042, 0.30, 0.20)),
		_blob(0.013, Vector3.ONE, Vector3(-0.042, 0.30, 0.20)),
	], _material(_SOOT, 0.9))
	return mesh


## A gull mid-glide, ~0.9 m wingspan — the shore's traffic. Origin at the BODY
## CENTRE (see the header): spawners place it in the air.
static func build_gull() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	_append(mesh, [
		_blob(0.11, Vector3(0.8, 0.75, 1.6), Vector3.ZERO),
		_blob(0.06, Vector3(0.9, 0.9, 1.0), Vector3(0, 0.05, 0.16)),
		_slab(Vector3(0.12, 0.012, 0.14), Vector3(0, 0.01, -0.30), Basis()),
	], _material(_GULL_BODY, 0.9))

	var dihedral := 0.1
	_append(mesh, [
		_slab(Vector3(0.42, 0.015, 0.13), Vector3(-0.26, 0.045, 0),
				Basis(Vector3(0, 0, 1), dihedral)),
		_slab(Vector3(0.42, 0.015, 0.13), Vector3(0.26, 0.045, 0),
				Basis(Vector3(0, 0, 1), -dihedral)),
	], _material(_GULL_WING, 0.9))

	_append(mesh, [
		_limb(Vector3(0, 0.045, 0.21), Vector3(0, -0.05, 1), 0.07, 0.022, 0.004),
	], _material(_BEAK, 0.8))

	_append(mesh, [
		_blob(0.009, Vector3.ONE, Vector3(0.03, 0.065, 0.185)),
		_blob(0.009, Vector3.ONE, Vector3(-0.03, 0.065, 0.185)),
	], _material(_SOOT, 0.9))
	return mesh


## A perched songbird, ~0.13 m — the woods' soundtrack made visible.
static func build_songbird() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	_append(mesh, [
		_blob(0.055, Vector3(0.9, 0.95, 1.2), Vector3(0, 0.055, 0)),
		_blob(0.038, Vector3.ONE, Vector3(0, 0.10, 0.035)),
		_slab(Vector3(0.03, 0.008, 0.09), Vector3(0, 0.055, -0.075),
				Basis(Vector3(1, 0, 0), -0.35)),
	], _material(_OLIVE, 0.95))

	_append(mesh, [
		_blob(0.042, Vector3(0.85, 0.9, 0.9), Vector3(0, 0.05, 0.035)),
	], _material(_ROBIN, 0.95))

	_append(mesh, [
		_limb(Vector3(0, 0.10, 0.07), Vector3(0, -0.1, 1), 0.03, 0.012, 0.002),
		_blob(0.007, Vector3.ONE, Vector3(0.02, 0.11, 0.058)),
		_blob(0.007, Vector3.ONE, Vector3(-0.02, 0.11, 0.058)),
	], _material(_SOOT, 0.9))
	return mesh


## A butterfly, ~0.16 m wingspan, wings half-raised. Faintly self-lit (mushroom-
## style, subtle) so a drift of them still reads in the flower band at dusk.
## Instance tints repaint the wings — violet, orange, white drifts.
static func build_butterfly() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	_append(mesh, [
		_limb(Vector3(0, 0.05, 0.032), Vector3(0, 0, -1), 0.062, 0.01, 0.005),
	], _material(_SOOT, 0.9))

	var wings: Array = []
	var lift := 0.45
	for side in [-1.0, 1.0]:
		wings.append(_slab(Vector3(0.055, 0.002, 0.045),
				Vector3(side * 0.028, 0.062, 0.018), Basis(Vector3(0, 0, 1), -side * lift)))
		wings.append(_slab(Vector3(0.04, 0.002, 0.035),
				Vector3(side * 0.024, 0.06, -0.014), Basis(Vector3(0, 0, 1), -side * lift)))
	var mat := _material(_FLUTTER, 0.6)
	mat.emission_enabled = true
	mat.emission = _FLUTTER
	mat.emission_energy_multiplier = 0.5
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED  # wings visible from below too
	_append(mesh, wings, mat)
	return mesh


# --- shared part builders ----------------------------------------------------

## A low-poly cylinder "limb" growing [param length] metres from [param base]
## along [param dir] — legs, necks, ears, tails, beaks, antlers.
static func _limb(base: Vector3, dir: Vector3, length: float,
		r_bottom: float, r_top: float) -> Array:
	var cyl := CylinderMesh.new()
	cyl.top_radius = r_top
	cyl.bottom_radius = r_bottom
	cyl.height = length
	cyl.radial_segments = 5
	cyl.rings = 1
	var d := dir.normalized()
	var basis := Basis()
	var axis := Vector3.UP.cross(d)
	if axis.length() > 0.001:
		basis = Basis(axis.normalized(), Vector3.UP.angle_to(d))
	elif d.y < 0.0:
		basis = Basis(Vector3.RIGHT, PI)
	return [cyl, Transform3D(basis, base + d * (length * 0.5))]


## A low-poly squashed sphere — bodies and heads.
static func _blob(radius: float, squash: Vector3, at: Vector3) -> Array:
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.radial_segments = 9
	sphere.rings = 5
	return [sphere, Transform3D(Basis().scaled(squash), at)]


## A thin box — wings and tail fans.
static func _slab(size: Vector3, at: Vector3, basis: Basis) -> Array:
	var box := BoxMesh.new()
	box.size = size
	return [box, Transform3D(basis, at)]


static func _append(mesh: ArrayMesh, parts: Array, mat: StandardMaterial3D) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for part in parts:
		st.append_from(part[0], 0, part[1])
	st.set_material(mat)
	st.commit(mesh)


static func _material(albedo: Color, rough: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = albedo
	mat.roughness = rough
	mat.vertex_color_use_as_albedo = true  # MultiMesh instance tints
	return mat
