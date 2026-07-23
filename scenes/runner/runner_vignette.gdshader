// The closing dark: Zombie Run's ONLY proximity readout. `intensity` (0…1, from
// the zombie gap) drags the clear centre from a wide cinematic frame down to a
// narrow tunnel, so danger is felt as the world being taken away rather than
// read off a scale. Blood only bleeds in on the heartbeat, and the edge crawls
// with grain + a slow breathing wobble so the dark never sits still and the eye
// keeps hunting movement in it.
//
// Fed by RunnerHud.set_danger(); see that script's header for why there is no
// number anywhere near this.
shader_type canvas_item;
uniform float intensity : hint_range(0.0, 1.0) = 0.0;
uniform float pulse : hint_range(0.0, 1.0) = 0.0;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(41.3, 289.1))) * 43758.5453);
}

void fragment() {
	vec2 d = UV - vec2(0.5);
	d.x *= 1.12;  // squeeze horizontally so a wide screen still tunnels
	float r = length(d) * 1.5;

	// The hole you can still see through. It clenches with the heartbeat, and
	// breathes slightly even when you're safe, so the frame is never quite still.
	float breathe = sin(TIME * 1.7) * 0.012;
	float inner = mix(0.60, 0.07, intensity) - pulse * 0.06 * intensity + breathe;
	float outer = mix(1.20, 0.46, intensity);
	float vig = smoothstep(inner, outer, r);

	// Near-black by default: it reads as the light dying, not as a red filter.
	// Blood washes in only on the beat, and only once the threat is real.
	vec3 col = mix(vec3(0.0), vec3(0.34, 0.0, 0.0), pulse * intensity);
	float a = vig * (0.42 + 0.58 * intensity);
	// Grain in the murk — gives the dark texture to hide things in.
	a += (hash(UV * vec2(640.0, 360.0) + fract(TIME) * 97.0) - 0.5) * 0.06 * intensity;
	COLOR = vec4(col, clamp(a, 0.0, 0.985));
}
