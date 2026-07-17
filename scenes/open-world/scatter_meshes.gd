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

const _BARK := Color(0.33, 0.23, 0.15)
const _PINE := Color(0.15, 0.32, 0.16)
const _LEAF := Color(0.24, 0.42, 0.17)
const _STONE := Color(0.46, 0.46, 0.48)


## A conifer: tapered trunk + three stacked cones, ~5 m tall. Two surfaces
## (bark, foliage) so it stays one mesh — and one draw call per MultiMesh.
static func build_conifer() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.10
	trunk.bottom_radius = 0.17
	trunk.height = 1.6
	trunk.radial_segments = 6
	trunk.rings = 1
	_append(mesh, [[trunk, Transform3D(Basis(), Vector3(0, 0.8, 0))]],
			_material(_BARK, 0.95))

	var tiers: Array = []
	var tier_y := [1.8, 2.9, 3.9]
	var tier_r := [1.35, 1.0, 0.62]
	for i in 3:
		var cone := CylinderMesh.new()
		cone.top_radius = 0.0
		cone.bottom_radius = tier_r[i]
		cone.height = 1.7
		cone.radial_segments = 7
		cone.rings = 1
		tiers.append([cone, Transform3D(Basis(), Vector3(0, tier_y[i], 0))])
	_append(mesh, tiers, _material(_PINE, 0.9))
	return mesh


## A broadleaf: trunk + a clump of three squashed spheres, ~4.5 m tall.
static func build_broadleaf() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.13
	trunk.bottom_radius = 0.20
	trunk.height = 2.1
	trunk.radial_segments = 6
	trunk.rings = 1
	_append(mesh, [[trunk, Transform3D(Basis(), Vector3(0, 1.05, 0))]],
			_material(_BARK, 0.95))

	var blobs: Array = []
	var squash := Basis().scaled(Vector3(1.0, 0.8, 1.0))
	for offset in [Vector3(0, 3.1, 0), Vector3(0.75, 2.6, 0.35),
			Vector3(-0.65, 2.7, -0.4)]:
		var blob := SphereMesh.new()
		blob.radius = 1.25
		blob.height = 2.5
		blob.radial_segments = 9
		blob.rings = 5
		blobs.append([blob, Transform3D(squash, offset)])
	_append(mesh, blobs, _material(_LEAF, 0.9))
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
