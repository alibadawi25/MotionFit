@tool
extends Control
class_name MeterBar
## MeterBar
##
## A flat track with a coloured fill, sized in pixels rather than driven by a
## theme — the platform's "hold this gesture" / "capture progress" / "effort vs
## target" bar. Used by the game intro, the calibration screen and the interval
## coach, all of which recolour the fill to signal state.
##
## Instance `scenes/ui/components/meter_bar.tscn` and call [method set_fraction]
## each frame. [member target] draws an optional marker line — the interval
## coach's "hit this MET" tick.

## 0..1 fill, clamped. Set through [method set_fraction] at runtime.
@export_range(0.0, 1.0) var fraction: float = 0.0:
	set(v):
		fraction = clampf(v, 0.0, 1.0)
		if is_node_ready():
			_layout()

## Fill colour. Screens swap this to say "good" / "push harder" / "done".
@export var fill_color: Color = Color(1, 0.5, 0.14):
	set(v):
		fill_color = v
		if is_node_ready():
			%Fill.color = v

## Optional target marker at 0..1 of the track. Negative hides it.
@export var target: float = -1.0:
	set(v):
		target = v
		if is_node_ready():
			_layout()

func _ready() -> void:
	resized.connect(_layout)
	fill_color = fill_color
	_layout()


## Convenience for per-frame drivers: sets the fill and (optionally) its colour.
func set_fraction(value: float, color: Color = fill_color) -> void:
	fill_color = color
	fraction = value


func _layout() -> void:
	var track: ColorRect = %Fill
	track.position = Vector2.ZERO
	track.size = Vector2(size.x * fraction, size.y)
	var marker: ColorRect = %TargetMarker
	marker.visible = target >= 0.0
	if marker.visible:
		marker.position = Vector2(clampf(target, 0.0, 1.0) * size.x - 1.0, -2.0)
		marker.size = Vector2(2.0, size.y + 4.0)
