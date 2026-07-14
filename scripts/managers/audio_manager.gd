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

const MUSIC_BUS: String = "Music"
const SFX_BUS: String = "SFX"

var _music_player: AudioStreamPlayer
var _sfx_player: AudioStreamPlayer

func _ready() -> void:
	_ensure_buses()
	_music_player = AudioStreamPlayer.new()
	_music_player.bus = MUSIC_BUS
	add_child(_music_player)
	_sfx_player = AudioStreamPlayer.new()
	_sfx_player.bus = SFX_BUS
	add_child(_sfx_player)


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


## Plays a one-shot sound effect [param stream].
func play_sfx(stream: AudioStream) -> void:
	if stream == null:
		return
	_sfx_player.stream = stream
	_sfx_player.play()


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
