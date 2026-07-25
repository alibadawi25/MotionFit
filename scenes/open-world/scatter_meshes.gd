extends Object
## Code-built low-poly meshes for the open world's scatter (see world_scatter.gd).
##
## Everything is authored at "natural" size in metres with its origin at ground
## level, so the scatterer only has to drop an instance on the surface and scale
## it. All materials use vertex-color-as-albedo so a MultiMesh instance tint can
## vary individuals without extra materials.
##
## Style matches the world: chunky primitives, no textures — the terrain carries
## the detail, the silhouettes carry the trees.
##
## Trees and shrubs come in VARIANTS, described as data below and built on
## demand. A hillside of identically-shaped cones is the loudest "this was
## generated" tell there is, and per-instance scale and tint do not fix it — a
## scaled clone still reads as the same tree seen from further away. What breaks
## the pattern is silhouette: where the crown sits, how far it spreads, whether
## the trunk is bare. So the variants differ in shape first and colour second.

const _BARK := Color(0.33, 0.23, 0.15)
const _BARK_PALE := Color(0.74, 0.72, 0.66)  # birch
const _DEADWOOD := Color(0.45, 0.42, 0.36)  # weathered snag
const _PINE := Color(0.15, 0.32, 0.16)
const _PINE_COLD := Color(0.16, 0.30, 0.25)  # blue-green, high country
const _PINE_WARM := Color(0.22, 0.35, 0.14)
const _LEAF := Color(0.24, 0.42, 0.17)
const _LEAF_DEEP := Color(0.18, 0.33, 0.14)  # oak
const _LEAF_LIGHT := Color(0.44, 0.56, 0.23)  # birch
const _SCRUB := Color(0.25, 0.35, 0.17)
const _SCRUB_DRY := Color(0.44, 0.44, 0.21)
const _STONE := Color(0.46, 0.46, 0.48)
const _CRYSTAL := Color(0.42, 0.86, 0.82)
const _DRIFT := Color(0.58, 0.52, 0.43)
const _EMBER := Color(1.0, 0.45, 0.15)
const _SPORE := Color(0.66, 0.42, 0.92)

## The conifer shapes. Per row: "trunk" [top radius, bottom radius, height],
## "tiers" [[centre y, bottom radius, height], …] of the stacked foliage cones,
## and the two colours. An empty "tiers" means a dead trunk — see
## [method _snag_branches].
const _CONIFERS: Array = [
	# 0 — SPIRE: narrow, four tight tiers, the classic high-country fir.
	{"trunk": [0.09, 0.16, 1.5], "bark": _BARK, "leaf": _PINE_COLD,
			"tiers": [[1.6, 1.05, 1.6], [2.6, 0.86, 1.6], [3.5, 0.62, 1.5],
					[4.25, 0.36, 1.3]]},
	# 1 — BROAD FIR: squat, with a wide skirt almost on the ground. Belongs in
	#     the sheltered low woods where nothing prunes the bottom branches.
	{"trunk": [0.13, 0.26, 1.0], "bark": _BARK, "leaf": _PINE_WARM,
			"tiers": [[0.95, 1.75, 1.9], [1.95, 1.32, 1.8], [2.85, 0.8, 1.6]]},
	# 2 — UMBRELLA PINE: a long bare trunk under a flat crown. The one variant
	#     that is unmistakable in silhouette at any distance, which is its job.
	{"trunk": [0.12, 0.21, 3.4], "bark": _BARK, "leaf": _PINE,
			"tiers": [[3.5, 1.55, 0.85], [4.05, 1.15, 0.75], [4.5, 0.62, 0.6]]},
	# 3 — SNAG: dead, bare, broken off partway up. Rare, and pushed toward the
	#     treeline, where a scatter of weather-killed trunks is what the real
	#     thing looks like.
	{"trunk": [0.05, 0.19, 3.9], "bark": _DEADWOOD, "leaf": _DEADWOOD,
			"tiers": []},
]

## The broadleaf shapes. "blobs" are [centre offset, radius] canopy spheres;
## "squash" scales them vertically, which is what separates a spreading oak
## (0.62) from an upright birch plume (1.25).
const _BROADLEAFS: Array = [
	# 0 — ROUND: the ordinary tree, three blobs over a straight trunk.
	{"trunk": [0.13, 0.20, 2.1], "bark": _BARK, "leaf": _LEAF, "squash": 0.8,
			"blobs": [[Vector3(0.0, 3.1, 0.0), 1.25],
					[Vector3(0.75, 2.6, 0.35), 1.15],
					[Vector3(-0.65, 2.7, -0.4), 1.1]]},
	# 1 — SPREADING OAK: a heavy short bole under a canopy far wider than it is
	#     tall. Reads as the big old tree in a meadow.
	{"trunk": [0.20, 0.34, 1.6], "bark": _BARK, "leaf": _LEAF_DEEP,
			"squash": 0.62,
			"blobs": [[Vector3(0.0, 2.6, 0.0), 1.5],
					[Vector3(1.35, 2.25, 0.3), 1.2],
					[Vector3(-1.2, 2.3, -0.5), 1.25],
					[Vector3(0.3, 2.2, -1.3), 1.1],
					[Vector3(-0.4, 2.15, 1.25), 1.05]]},
	# 2 — SLIM BIRCH: pale bark, tall, a narrow upright plume of a crown. The
	#     light trunk is what carries it — a stand of these reads bright against
	#     the dark conifers.
	{"trunk": [0.08, 0.13, 3.2], "bark": _BARK_PALE, "leaf": _LEAF_LIGHT,
			"squash": 1.25,
			"blobs": [[Vector3(0.0, 3.6, 0.0), 0.8],
					[Vector3(0.28, 4.3, 0.15), 0.62],
					[Vector3(-0.2, 3.0, 0.22), 0.66]]},
]

## The understory. What stops a wood from reading as lollipops standing on a
## lawn is something between the trunks and the grass. Same [Vector3 offset,
## radius] blob form as the broadleaf canopies, except variant 2, which is built
## from cones instead (see [method build_shrub]).
##
## Sizes are set against the TERRAIN'S GRASS, not against a person: the detail
## layer's blades stand well over a metre at eye level, and the first pass at
## these — a tidy knee-high 0.75 m bush — was completely invisible in play,
## swallowed by grass in every shot. An understory plant here has to clear the
## ground cover to exist at all.
const _SHRUBS: Array = [
	# 0 — BUSH: a rounded clump, about chest height. The default.
	{"leaf": _SCRUB, "squash": 0.82,
			"blobs": [[Vector3(0.0, 0.78, 0.0), 0.9],
					[Vector3(0.62, 0.56, 0.22), 0.66],
					[Vector3(-0.4, 0.6, -0.5), 0.7]]},
	# 1 — SCRUB: sprawling, far wider than it is tall. Breaks up ground without
	#     adding much silhouette, so it can sit in a view without blocking it.
	{"leaf": _SCRUB_DRY, "squash": 0.5,
			"blobs": [[Vector3(0.0, 0.6, 0.0), 1.15],
					[Vector3(1.05, 0.46, 0.36), 0.8],
					[Vector3(-0.9, 0.5, 0.62), 0.74],
					[Vector3(0.18, 0.46, -1.0), 0.78]]},
	# 2 — GORSE: a spiky tuft of splayed cones, head height. Built from
	#     _GORSE_SPIKES.
	{"leaf": _SCRUB, "squash": 1.0, "blobs": []},
]

## The gorse tuft's spikes: azimuth (deg), lean from vertical (rad), length,
## base radius. Fixed rather than random — one mesh serves every gorse bush in
## the world, so the variety has to come from the scatterer's per-instance yaw.
const _GORSE_SPIKES: Array = [
	[10.0, 0.15, 1.85, 0.15], [85.0, 0.5, 1.45, 0.13],
	[160.0, 0.35, 1.65, 0.125], [230.0, 0.62, 1.15, 0.12],
	[300.0, 0.28, 1.55, 0.13],
]


static func conifer_variants() -> int:
	return _CONIFERS.size()


static func broadleaf_variants() -> int:
	return _BROADLEAFS.size()


static func shrub_variants() -> int:
	return _SHRUBS.size()


## Trunk radius in metres at scale 1, read straight off the shape data so the
## scatterer's collider matches whatever the mesh actually is: a slim birch or a
## snag must not get a spreading oak's invisible bollard around it.
static func conifer_trunk_radius(variant: int) -> float:
	return _CONIFERS[variant % _CONIFERS.size()].trunk[1]


static func broadleaf_trunk_radius(variant: int) -> float:
	return _BROADLEAFS[variant % _BROADLEAFS.size()].trunk[1]


## A conifer: tapered trunk + stacked foliage cones, 4.5-5.5 m tall depending on
## variant. Two surfaces (bark, foliage) so it stays one mesh — and therefore
## one draw call per MultiMesh.
static func build_conifer(variant: int) -> ArrayMesh:
	var spec: Dictionary = _CONIFERS[variant % _CONIFERS.size()]
	var mesh := ArrayMesh.new()
	var trunk_h: float = spec.trunk[2]
	var wood: Array = [[_cyl(spec.trunk[0], spec.trunk[1], trunk_h, 6),
			Transform3D(Basis(), Vector3(0.0, trunk_h * 0.5, 0.0))]]
	var tiers: Array = spec.tiers
	if tiers.is_empty():
		wood.append_array(_snag_branches(trunk_h))
	_append(mesh, wood, _material(spec.bark, 0.95))
	if tiers.is_empty():
		return mesh  # a snag is bark all the way up

	var cones: Array = []
	for tier in tiers:
		cones.append([_cyl(0.0, tier[1], tier[2], 7),
				Transform3D(Basis(), Vector3(0.0, tier[0], 0.0))])
	_append(mesh, cones, _material(spec.leaf, 0.9))
	return mesh


## A broadleaf: trunk + a clump of squashed spheres, 4-5.5 m tall by variant.
static func build_broadleaf(variant: int) -> ArrayMesh:
	var spec: Dictionary = _BROADLEAFS[variant % _BROADLEAFS.size()]
	var mesh := ArrayMesh.new()
	var trunk_h: float = spec.trunk[2]
	_append(mesh, [[_cyl(spec.trunk[0], spec.trunk[1], trunk_h, 6),
			Transform3D(Basis(), Vector3(0.0, trunk_h * 0.5, 0.0))]],
			_material(spec.bark, 0.95))
	# 8 x 4, not the 9 x 5 the single old broadleaf used: the oak carries five
	# canopy blobs where that had three, and at this silhouette scale the extra
	# ring is invisible while the triangles are not.
	_append(mesh, _canopy(spec.blobs, spec.squash, 8, 4),
			_material(spec.leaf, 0.9))
	return mesh


## An understory plant, 1-2.5 m tall — bushes, low scrub and spiky gorse.
##
## One surface and brutally few segments (5 x 2, against the broadleaf canopy's
## 9 x 5). These outnumber the trees two to one, so their triangle count is the
## whole layer's cost; at 5 x 2 a blob is about 20 triangles and the faceting
## reads as leaf clumps rather than as a low-poly sphere, which is the one place
## this art style pays a dividend.
static func build_shrub(variant: int) -> ArrayMesh:
	var spec: Dictionary = _SHRUBS[variant % _SHRUBS.size()]
	var mesh := ArrayMesh.new()
	var parts: Array = _canopy(spec.blobs, spec.squash, 5, 2)
	if spec.blobs.is_empty():  # gorse: cones instead of blobs
		for spike in _GORSE_SPIKES:
			var az: float = deg_to_rad(spike[0])
			var out_dir := Vector3(cos(az), 0.0, sin(az))
			var dir := (Vector3.UP * cos(spike[1])
					+ out_dir * sin(spike[1])).normalized()
			parts.append([_cyl(0.0, spike[3], spike[2], 4),
					Transform3D(_aim(dir), dir * (spike[2] * 0.5))])
	_append(mesh, parts, _material(spec.leaf, 0.95))
	return mesh


## A boulder: a squashed sphere with hash-displaced vertices, faceted by flat
## per-face normals, ~1.6 m across before instance scaling. The displacement is
## keyed on vertex DIRECTION so seam-duplicated vertices move together and the
## rock stays watertight.
static func build_boulder() -> ArrayMesh:
	var sphere := SphereMesh.new()
	sphere.radius = 0.8
	sphere.height = 1.6
	sphere.radial_segments = 9
	sphere.rings = 5
	var arrays := sphere.get_mesh_arrays()
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for i in verts.size():
		var v := verts[i]
		var dir := v.normalized() if v.length() > 0.001 else Vector3.UP
		var key := dir.snapped(Vector3.ONE * 0.02)
		var f := _hash01(key)
		v *= 1.0 + 0.34 * (f - 0.5)
		v.y *= 0.72
		verts[i] = v
	arrays[Mesh.ARRAY_VERTEX] = verts
	var bumpy := ArrayMesh.new()
	bumpy.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var st := SurfaceTool.new()
	st.create_from(bumpy, 0)
	st.deindex()  # split shared verts so generate_normals() facets the faces
	st.generate_normals()
	st.set_material(_material(_STONE, 1.0))
	return st.commit()


## A crystal cluster: four five-sided spikes leaning out of one spot, ~1.3 m
## tall, self-lit — the grotto's treasure glow (see world_scatter.gd). Origin at
## ground level like everything else here.
static func build_crystal() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var spikes: Array = []
	# base offset, lean (rad), height, base radius
	var specs := [
		[Vector3(0.0, 0.0, 0.0), 0.0, 1.3, 0.20],
		[Vector3(0.28, 0.0, 0.12), 0.42, 0.85, 0.14],
		[Vector3(-0.24, 0.0, 0.18), -0.5, 0.7, 0.12],
		[Vector3(0.05, 0.0, -0.3), 0.35, 0.55, 0.11],
	]
	for s in specs:
		var lean := Basis(Vector3(1.0, 0.0, 0.4).normalized(), s[1])
		spikes.append([_cyl(0.02, s[3], s[2], 5),
				Transform3D(lean, s[0] + lean * Vector3(0.0, s[2] * 0.5, 0.0))])
	var mat := _material(_CRYSTAL, 0.25)
	mat.emission_enabled = true
	mat.emission = _CRYSTAL
	mat.emission_energy_multiplier = 1.6
	_append(mesh, spikes, mat)
	return mesh


## A collapsed driftwood lean-to over a dying fire: four bleached logs tipped
## together above a pile of still-glowing embers, one more fallen flat beside.
## The castaway camp's centrepiece (see world_scatter.gd SECRETS). ~2 m tall.
static func build_driftwood() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var logs: Array = []
	var yaw_jitter := [0.3, 0.1, 0.45, 0.2]
	for i in 4:
		var az: float = TAU * float(i) / 4.0 + yaw_jitter[i]
		var lean := 0.55 + 0.07 * float(i % 2)
		var out := Vector3(cos(az), 0.0, sin(az))
		var dir := (Vector3.UP * cos(lean) - out * sin(lean)).normalized()
		var length := 2.3 - 0.15 * float(i % 2)
		logs.append([_cyl(0.06, 0.09, length, 5),
				Transform3D(_aim(dir), out * 0.85 + dir * (length * 0.45))])
	logs.append([_cyl(0.07, 0.10, 1.7, 5), Transform3D(
			Basis(Vector3.UP, 0.5).rotated(Vector3(0.94, 0.0, 0.34), PI / 2.0),
			Vector3(1.5, 0.1, 0.6))])
	_append(mesh, logs, _material(_DRIFT, 0.95))

	var embers: Array = []
	for offset in [Vector3(0.0, 0.02, 0.0), Vector3(0.22, 0.0, 0.1),
			Vector3(-0.16, 0.0, -0.14)]:
		var coal := SphereMesh.new()
		coal.radius = 0.2
		coal.height = 0.18
		coal.radial_segments = 7
		coal.rings = 4
		embers.append([coal, Transform3D(Basis(), offset + Vector3(0.0, 0.06, 0.0))])
	var glow := _material(_EMBER, 0.7)
	glow.emission_enabled = true
	glow.emission = _EMBER
	glow.emission_energy_multiplier = 1.8
	_append(mesh, embers, glow)
	return mesh


## A luminous toadstool: pale stalk under a softly glowing violet cap, ~0.55 m
## tall at scale 1 — the glowing hollow grows a ring of them at varied scales.
static func build_mushroom() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	_append(mesh, [[_cyl(0.07, 0.10, 0.4, 6),
			Transform3D(Basis(), Vector3(0.0, 0.2, 0.0))]],
			_material(Color(0.82, 0.78, 0.7), 0.9))

	var cap := SphereMesh.new()
	cap.radius = 0.27
	cap.height = 0.3
	cap.radial_segments = 9
	cap.rings = 5
	var mat := _material(_SPORE, 0.45)
	mat.emission_enabled = true
	mat.emission = _SPORE
	mat.emission_energy_multiplier = 1.3
	_append(mesh, [[cap, Transform3D(Basis(), Vector3(0.0, 0.42, 0.0))]], mat)
	return mesh


## Canopy blobs as [mesh, transform] parts: squashed spheres at the given
## offsets. Shared by the broadleaf crowns and the shrubs, which differ only in
## how coarse the spheres are allowed to be.
static func _canopy(blobs: Array, squash: float, segments: int,
		rings: int) -> Array:
	var parts: Array = []
	var basis := Basis().scaled(Vector3(1.0, squash, 1.0))
	for blob in blobs:
		var sphere := SphereMesh.new()
		sphere.radius = blob[1]
		sphere.height = blob[1] * 2.0
		sphere.radial_segments = segments
		sphere.rings = rings
		parts.append([sphere, Transform3D(basis, blob[0])])
	return parts


## The broken branch stubs that make a dead trunk read as a tree instead of a
## fence post. Angles are fixed for the same reason the gorse spikes are.
static func _snag_branches(trunk_h: float) -> Array:
	var out: Array = []
	# azimuth (deg), fraction of the way up the trunk, length, lean (rad)
	var stubs := [[20.0, 0.55, 0.85, 1.15], [155.0, 0.72, 0.62, 0.95],
			[265.0, 0.42, 0.7, 1.3], [300.0, 0.86, 0.4, 1.0]]
	for s in stubs:
		var az: float = deg_to_rad(s[0])
		var out_dir := Vector3(cos(az), 0.0, sin(az))
		var dir := (Vector3.UP * cos(s[3]) + out_dir * sin(s[3])).normalized()
		out.append([_cyl(0.02, 0.06, s[2], 4), Transform3D(_aim(dir),
				Vector3(0.0, trunk_h * s[1], 0.0) + dir * (s[2] * 0.5))])
	return out


## Basis that tips a Y-up primitive onto [param dir]. Callers keep [param dir]
## clear of straight up, where the cross product degenerates.
static func _aim(dir: Vector3) -> Basis:
	return Basis(Vector3.UP.cross(dir).normalized(), Vector3.UP.angle_to(dir))


static func _cyl(top_r: float, bottom_r: float, height: float,
		segments: int) -> CylinderMesh:
	var cyl := CylinderMesh.new()
	cyl.top_radius = top_r
	cyl.bottom_radius = bottom_r
	cyl.height = height
	cyl.radial_segments = segments
	cyl.rings = 1
	return cyl


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


static func _hash01(v: Vector3) -> float:
	var h := sin(v.dot(Vector3(12.9898, 78.233, 37.719))) * 43758.5453
	return h - floor(h)
