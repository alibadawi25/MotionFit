shader_type canvas_item;
// Screen-edge frost for the open world's cold heights (see altitude_effects.gd).
//
// Pure alpha-blended overlay — no screen texture, no back-buffer copy — so it
// costs one fullscreen quad. `intensity` (0..1, the altitude cold factor) grows
// an icy rim inward from the frame's edges; two octaves of noise break the
// frontier into a crystalline creep instead of a clean vignette ring, which is
// what makes it read as frost on glass rather than a mere blue border.

uniform float intensity : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D frost_noise : repeat_enable, filter_linear;

void fragment() {
	vec2 c = UV - vec2(0.5);
	// Radial reach, weighted so the corners frost first (as real glass does).
	float d = length(c * vec2(1.25, 1.0)) * 1.6;
	float n = texture(frost_noise, UV * 3.0).r;
	float n2 = texture(frost_noise, UV * 9.0 + vec2(0.37)).r;
	// The frontier creeps inward with intensity; noise serrates it.
	float reach = intensity * 0.45;
	float frontier = d - (1.15 - reach) + (n - 0.5) * 0.36 + (n2 - 0.5) * 0.16;
	float frost = smoothstep(0.0, 0.35, frontier);
	// A faint cold film over the whole frame so even the centre reads chilled.
	float film = intensity * 0.07;
	vec3 ice = mix(vec3(0.62, 0.76, 0.92), vec3(0.9, 0.96, 1.0), frost);
	float alpha = clamp(frost * (0.5 + 0.35 * n2) * intensity + film, 0.0, 0.8);
	COLOR = vec4(ice, alpha);
}
