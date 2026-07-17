extends Node
## AudioManager
##
## Owns global audio playback and the audio bus layout. Games and menus never
## create their own music players; they call [method play_music] / [method
## play_sfx] so audio survives scene changes and respects the user's volume
## settings.
##
## Volumes are stored and passed as LINEAR values in the range 0.0 - 1.0 and
## converted to decibels internally, because linear is what a UI slider maps to
## naturally. SettingsManager pushes the persisted volumes into this manager on
## startup; this manager itself does not read or write saves.
##
## SFX playback is POLYPHONIC: [method play_sfx] hands out one of a small pool of
## voices, so sounds layer instead of cutting each other off. A single shared
## player would make any two overlapping effects mutually exclusive — a footstep
## would silence a heartbeat — which is unusable for a game scoring a scene.

const MUSIC_BUS: String = "Music"
const SFX_BUS: String = "SFX"

## How many sound effects can sound at once. Enough for a dense moment (heartbeat
## + both sets of footsteps + thunder + a scream) with room to spare; past this
## the oldest voice is stolen, which is inaudible at these densities.
const SFX_VOICES: int = 10

var _music_player: AudioStreamPlayer
var _sfx_pool: Array[AudioStreamPlayer] = []
## Round-robin cursor, used only when every voice is busy and one must be stolen.
var _sfx_next: int = 0

func _ready() -> void:
	_ensure_buses()
	_music_player = AudioStreamPlayer.new()
	_music_player.bus = MUSIC_BUS
	add_child(_music_player)
	for i in SFX_VOICES:
		var voice := AudioStreamPlayer.new()
		voice.bus = SFX_BUS
		add_child(voice)
		_sfx_pool.append(voice)


## Plays [param stream] as looping background music, replacing anything already
## playing. Pass null to stop the music.
func play_music(stream: AudioStream) -> void:
	if stream == null:
		_music_player.stop()
		return
	_music_player.stream = stream
	_music_player.play()


## Stops the current background music.
func stop_music() -> void:
	_music_player.stop()


## Plays a one-shot sound effect [param stream] on a free voice and returns the
## player driving it (null if there was nothing to play).
##
## The optional arguments are what let one clip cover many moments: [param
## volume_db] and [param pitch] shape it (a pitched-down footstep is a zombie's
## drag; a quiet one is distance), and [param from_position] seeks into the clip,
## which both skips dead lead-in silence and lets a sound start already underway.
## The returned player is only worth keeping for a long clip you may need to
## retire early — see [method fade_out_sfx].
func play_sfx(stream: AudioStream, volume_db: float = 0.0, pitch: float = 1.0,
		from_position: float = 0.0) -> AudioStreamPlayer:
	if stream == null:
		return null
	var voice: AudioStreamPlayer = _free_voice()
	voice.stream = stream
	voice.volume_db = volume_db
	voice.pitch_scale = maxf(0.01, pitch)
	voice.play(from_position)
	return voice


## Fades [param player] (as returned by [method play_sfx]) out over [param
## seconds] and stops it. Long one-shots outlive the moment they were played for
## — an 8-second scream shouldn't wail on into the results screen — and this
## retires one without the click that a bare stop() gives.
func fade_out_sfx(player: AudioStreamPlayer, seconds: float = 0.35) -> void:
	if player == null or not player.playing:
		return
	var tween := create_tween()  # owned by this autoload, so it survives the caller
	tween.tween_property(player, "volume_db", -60.0, seconds)
	tween.tween_callback(player.stop)


## Silences every sound effect immediately.
func stop_sfx() -> void:
	for voice in _sfx_pool:
		voice.stop()


## Picks an idle voice, falling back to stealing the next one in rotation when
## they're all busy. Note that a voice mid-[method fade_out_sfx] still counts as
## busy, so it's only ever stolen under that same full-pool pressure.
func _free_voice() -> AudioStreamPlayer:
	for voice in _sfx_pool:
		if not voice.playing:
			return voice
	var stolen: AudioStreamPlayer = _sfx_pool[_sfx_next]
	_sfx_next = (_sfx_next + 1) % _sfx_pool.size()
	return stolen


## Sets the Master bus volume from a linear value in [0.0, 1.0].
func set_master_volume(linear: float) -> void:
	_set_bus_volume("Master", linear)


## Sets the Music bus volume from a linear value in [0.0, 1.0].
func set_music_volume(linear: float) -> void:
	_set_bus_volume(MUSIC_BUS, linear)


## Sets the SFX bus volume from a linear value in [0.0, 1.0].
func set_sfx_volume(linear: float) -> void:
	_set_bus_volume(SFX_BUS, linear)


func _set_bus_volume(bus_name: String, linear: float) -> void:
	var index: int = AudioServer.get_bus_index(bus_name)
	if index == -1:
		return
	AudioServer.set_bus_volume_db(index, linear_to_db(clampf(linear, 0.0, 1.0)))


func _ensure_buses() -> void:
	for bus_name in [MUSIC_BUS, SFX_BUS]:
		if AudioServer.get_bus_index(bus_name) == -1:
			AudioServer.add_bus()
			var index: int = AudioServer.bus_count - 1
			AudioServer.set_bus_name(index, bus_name)
			AudioServer.set_bus_send(index, "Master")
