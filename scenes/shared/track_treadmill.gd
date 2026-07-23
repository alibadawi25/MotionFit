extends RefCounted
## TrackTreadmill
##
## The scrolling-ground illusion every forward-running game needs: a fixed ring
## of [constant TILE_COUNT] tiles that slide toward the camera and, once one
## passes behind it, jump back to the far end to be reused. The player never
## actually moves in world space, so the course can run forever on a constant
## number of nodes.
##
## Both Zombie Run ([RunnerTrack]) and Hurdle Dash ([SprintTrack]) had their own
## copy of this loop, constants and all, which is a bug waiting to happen: the
## recycle distance and the ring length must agree exactly or the ground visibly
## seams, and keeping that agreement in two places relies on nobody editing one
## without the other.
##
## What it deliberately does NOT do is decide what a tile looks like or what
## rides on it. The two games differ completely there — Zombie Run spawns
## obstacles procedurally as you go, Hurdle Dash parks fixed landmarks against a
## known race distance — so tile construction is the caller's [Callable] and
## everything above the ground stays in the game.
##
## Usage:
## [codeblock]
## _treadmill = TrackTreadmill.new()
## _treadmill.build(self, TrackTreadmill.TILE_LEN * 0.5, _make_tile)
## ...
## _treadmill.advance(speed * delta)
## [/codeblock]
class_name TrackTreadmill

## Length of one tile in metres, and how many are kept alive. Nine 16 m tiles is
## 144 m of ground — comfortably past the fog line at every speed either game
## reaches, so a tile never recycles anywhere the player can see it happen.
const TILE_LEN: float = 16.0
const TILE_COUNT: int = 9
## How far behind the camera a tile may drift before it is sent to the back of
## the ring. Positive z is toward/behind the camera.
const RECYCLE_Z: float = 24.0

## The live tiles, in creation order. Exposed so a game can decorate or query
## them; the treadmill only ever moves them.
var tiles: Array[Node3D] = []


## Builds the ring under [param host]. [param make_tile] is called once per index
## and must return the tile node — its z is assigned here, so a builder should not
## set its own. [param start_z] is where tile 0 sits; each subsequent tile is one
## TILE_LEN further away.
func build(host: Node3D, start_z: float, make_tile: Callable) -> void:
	for i in TILE_COUNT:
		var tile: Node3D = make_tile.call(i)
		if tile == null:
			push_error("TrackTreadmill: make_tile returned null for index %d" % i)
			continue
		tile.position.z = start_z - i * TILE_LEN
		host.add_child(tile)
		tiles.append(tile)


## Slides the ring [param dz] metres toward the camera, recycling anything that
## has gone past [constant RECYCLE_Z] to the far end. Wrapping by exactly the
## ring length (rather than snapping to a fixed z) preserves any sub-tile offset,
## so the ground never jitters at the seam.
func advance(dz: float) -> void:
	for tile in tiles:
		tile.position.z += dz
		if tile.position.z > RECYCLE_Z:
			tile.position.z -= TILE_COUNT * TILE_LEN
