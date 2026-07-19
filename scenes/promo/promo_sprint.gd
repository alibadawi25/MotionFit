extends Node3D
## PromoSprint — cinematic photo-mode for Hurdle Dash.
##
## Instances the real sprint scene (which builds the track, stadium bowl, crowd,
## rivals and athlete in code), hides the race HUD / briefing cards, and frames a
## still broadcast camera down the lanes. Shot only with tools/shot.sh; never
## launched in-game.
##
## Two things a still needs that live play doesn't:
##  1. The shipped stadium is a 9-tile (~144 m) strip that SCROLLS past the
##     athletes and recycles — great in motion, but for a fixed shot the far end
##     stops short of the distant hurdles. We duplicate the tiles into one long
##     STATIC run so the stands reach the horizon.
##  2. With no webcam the player's pace reads 0, so its run stride crawls while
##     the AI rivals sprint — it looks like it's standing. We force a convincing
##     sprint speed on its animation.
##
## Both overrides run at a high process_priority so they win over the sprint sim
## each frame. CAM_* can be overridden per shot via env PROMO_POS / PROMO_LOOK /
## PROMO_FOV. Lanes sit at x = -3/-1/1/3; athletes stay near z=0.

const WORLD := preload("res://scenes/sprint/sprint.tscn")

## Low 3/4 hero angle off lane 4, catching the pack mid-stride with the lanes and
## crowd bowl sweeping past. Shoot ~15 s in (WAIT=15) so the race is underway.
const CAM_POS: Vector3 = Vector3(4.3, 1.1, 4.5)
const CAM_LOOK: Vector3 = Vector3(-1.4, 0.9, -13.0)
const CAM_FOV: float = 60.0

## Playback rate forced on the player's run clip so it sprints convincingly with
## no live motion (the shipped range is ~1.1 idle-jog … 2.9 full sprint).
const RUN_STRIDE: float = 2.6
## How many stadium tiles to lay end-to-end (16 m each) — enough to carry the
## stands well past the farthest hurdle (~280 m out).
const STADIUM_TILES: int = 24
const TILE_LEN: float = 16.0
## Z of the nearest tile edge; the run marches off down -Z from here.
const TOP_Z: float = 24.0

var _cam: Camera3D
var _world: Node
var _track: Node
var _tiles_all: Array[Node3D] = []
var _player_anim: AnimationPlayer

func _ready() -> void:
	# Run our overrides after the sprint sim's own _process each frame.
	process_priority = 100

	_world = WORLD.instantiate()
	add_child(_world)

	_track = _world.get_node_or_null("Track")
	if _track != null:
		_extend_stadium()

	var player := _world.get_node_or_null("Player")
	if player != null:
		_player_anim = player.find_child("AnimationPlayer", true, false)

	_cam = Camera3D.new()
	_cam.fov = _env_float("PROMO_FOV", CAM_FOV)
	_cam.far = 2000.0
	add_child(_cam)
	_cam.global_position = _env_vec("PROMO_POS", CAM_POS)
	_cam.look_at(_env_vec("PROMO_LOOK", CAM_LOOK), Vector3.UP)
	_cam.current = true


## Duplicates the shipped scroll tiles until there are STADIUM_TILES of them, so
## _process can lay a continuous, static grandstand run the length of the course.
func _extend_stadium() -> void:
	for t in _track._tiles:
		_tiles_all.append(t)
	var base_n := _tiles_all.size()
	if base_n == 0:
		return
	var idx := 0
	while _tiles_all.size() < STADIUM_TILES:
		var src: Node3D = _tiles_all[idx % base_n]
		var dup: Node3D = src.duplicate()
		_track.add_child(dup)
		_tiles_all.append(dup)
		idx += 1


func _process(_delta: float) -> void:
	if _cam != null and not _cam.current:
		_cam.current = true
	if _world == null:
		return

	# Clear the 2D race layer (HUD, briefing/finish cards, pause menu, corner cam).
	for child in _world.get_children():
		if child is CanvasLayer:
			(child as CanvasLayer).visible = false
		elif child is Control:
			(child as Control).visible = false

	# Override the scroll: park the whole stadium as one long static run so the
	# stands reach the distant hurdles instead of ending after 144 m.
	for j in _tiles_all.size():
		var t := _tiles_all[j]
		if is_instance_valid(t):
			t.position.z = TOP_Z - TILE_LEN * float(j)

	# Force a convincing sprint stride on the player (pace is 0 with no webcam).
	if _player_anim != null:
		_player_anim.speed_scale = RUN_STRIDE


## Reads "x,y,z" from environment variable [param key], or returns [param fallback].
func _env_vec(key: String, fallback: Vector3) -> Vector3:
	var s := OS.get_environment(key)
	if s.is_empty():
		return fallback
	var p := s.split(",")
	if p.size() != 3:
		return fallback
	return Vector3(p[0].to_float(), p[1].to_float(), p[2].to_float())


func _env_float(key: String, fallback: float) -> float:
	var s := OS.get_environment(key)
	return s.to_float() if not s.is_empty() else fallback
