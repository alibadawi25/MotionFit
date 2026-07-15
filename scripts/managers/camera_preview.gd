extends Node
## CameraPreview
##
## Receives the webcam preview stream from the Python pose service and exposes it
## as a [Texture2D] for the setup/countdown UI to show the player a live mirror
## of themselves.
##
## This stays inside the architecture's AI boundary (CONTEXT.md §9): Godot does
## NO computer vision. Python owns the camera and merely ships a small JPEG of
## each frame — exactly as [MotionManager] receives only processed movement
## intents. Godot just decodes the image and blits it to a texture; it never
## looks at the pixels.
##
## The stream is cosmetic and lossy by design (UDP, latest-frame-wins), so if the
## pose service isn't running the texture is simply null and callers fall back to
## a "start the camera" prompt — nothing breaks.

## UDP port — must match PREVIEW_PORT in python/pose/pose_server.py.
const PORT: int = 9991
## If no frame arrives within this long, [method is_streaming] reports false so
## the UI can show a "no camera" state.
const TIMEOUT_SEC: float = 1.0

var _udp: PacketPeerUDP = PacketPeerUDP.new()
var _texture: ImageTexture = null
var _last_frame_sec: float = -1000.0

func _ready() -> void:
	# Keep updating even while the tree is paused (e.g. a game's pause menu), so a
	# webcam view stays live wherever it's shown.
	process_mode = Node.PROCESS_MODE_ALWAYS
	var err: int = _udp.bind(PORT, "127.0.0.1")
	if err != OK:
		push_error("CameraPreview: could not bind UDP port %d (error %d)" % [PORT, err])


func _process(_delta: float) -> void:
	# Only the newest frame matters; drain the queue and keep the last datagram.
	var latest: PackedByteArray
	var got: bool = false
	while _udp.get_available_packet_count() > 0:
		latest = _udp.get_packet()
		got = true
	if not got:
		return
	var image := Image.new()
	if image.load_jpg_from_buffer(latest) != OK:
		return  # a corrupt/partial datagram — just wait for the next one
	# Reuse the texture across frames (cheap GPU upload) unless the size changed.
	# (Texture2D.get_size() is a Vector2; Image.get_size() a Vector2i — match them.)
	if _texture == null or _texture.get_size() != Vector2(image.get_size()):
		_texture = ImageTexture.create_from_image(image)
	else:
		_texture.update(image)
	_last_frame_sec = _now()


## The most recent webcam frame as a texture, or null if none has arrived yet.
## Safe to poll every frame from a [TextureRect].
func get_texture() -> Texture2D:
	return _texture


## True while fresh preview frames are arriving from the pose service.
func is_streaming() -> bool:
	return (_now() - _last_frame_sec) < TIMEOUT_SEC


func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0
