shader_type spatial;
// The Hurdle Dash crowd. One draw call per stand's MultiMesh drives thousands of
// spectators; this vertex shader gives every one of them its own life so the
// stands read as a living crowd instead of a colour speckle.
//
// Per-instance data (set by sprint_track.gd):
//   INSTANCE_CUSTOM.x — a 0..1 phase, so neighbours are out of step (shimmer),
//   INSTANCE_CUSTOM.y — a small rate jitter, so nobody bobs in lockstep.
// The instance COLOR carries the jersey (bodies) or skin tone (heads).
//
// A single [code]excitement[/code] uniform — shared across every stand's
// material — swings the whole stadium from an idle murmur (gentle sway) to a
// roaring, out-of-seat cheer (big upward bob). sprint.gd drives it from race
// pace and spikes it on clean hurdles and at the line.
render_mode cull_disabled, diffuse_lambert, specular_disabled;

uniform float excitement : hint_range(0.0, 1.0) = 0.12;

void vertex() {
	float phase = INSTANCE_CUSTOM.x * 6.2831853;
	float rate = 2.0 + INSTANCE_CUSTOM.y * 1.6 + excitement * 4.5;
	float t = TIME * rate + phase;
	// Always a small idle sway; the excited term only ever lifts (out of seat).
	float sway = sin(t) * 0.02;
	float cheer = max(sin(t), 0.0) * excitement * 0.24;
	VERTEX.y += sway + cheer;
	VERTEX.x += sin(t * 0.5 + phase) * (0.012 + excitement * 0.03);
}

void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = 0.92;
}
