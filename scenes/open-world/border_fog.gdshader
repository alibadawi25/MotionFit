shader_type spatial;
render_mode blend_mix, cull_disabled, unshaded, depth_draw_never, shadows_disabled;
// The wall of fog that closes the open world off at its rim (see
// scenes/open-world/world_border.gd, which builds two nested square rings of
// these, four inward-facing walls each).
//
// The whole job is to never read as a wall. Three things do that work:
//   * the bank BILLOWS — three octaves of seamless noise drifting at different
//     speeds, thresholded into fluffy clumps rather than used as a haze value;
//   * it MELTS into the scene — a soft-particle depth fade dissolves it wherever
//     real geometry sits just behind, so a hill poking through the bank has no
//     cut line against it;
//   * it THINS OUT at the top on a noise-wobbled edge, so the bank dissolves
//     into the sky's own fog instead of ending on a straight horizontal.
// It is unshaded on purpose: the colours below are already picked to sit in the
// scene's lit range, and a lit fog shell flickers as the cascades cross it.

// Bright, sun-facing fog. Should stay close to the environment's fog_light_color
// or the bank reads as a separate object hanging in the world.
uniform vec3 fog_color : source_color = vec3(0.8, 0.86, 0.92);
// The shaded heart of a clump. The gap between the two is what gives the bank
// its sense of volume — flatten it and you get a grey sheet.
uniform vec3 deep_color : source_color = vec3(0.44, 0.52, 0.62);

// Seamless noise (a NoiseTexture2D, supplied by world_border.gd).
uniform sampler2D fog_noise : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D depth_texture : hint_depth_texture, filter_linear;

// How many times the noise repeats across a wall's width. The noise texture is
// seamless, so any value tiles cleanly along the wall.
uniform float tiles_across = 8.0;
// Noise tiles per metre of height.
uniform float tiles_up = 0.012;
uniform float scroll : hint_range(0.0, 4.0) = 1.0;
uniform float density : hint_range(0.0, 3.0) = 1.4;
// Noise level that counts as "cloud". Lower = a thicker, more solid bank.
uniform float coverage : hint_range(0.0, 1.0) = 0.42;
// Summed FBM lands in a narrow band around 0.5 — thresholding it raw gives a
// bank that's either entirely there or entirely gone. Stretch it about its
// midpoint first so `coverage` has real range to bite on.
uniform float contrast : hint_range(1.0, 6.0) = 2.4;
// Alpha where the noise says "no cloud" — i.e. how much of this shell is solid
// mass rather than clumps. The outer shell keeps this high because it is the
// thing actually hiding the world's rim, and a fog border with a hole in it is
// just a window. The inner shell keeps it at 0 so it reads as loose wisps
// drifting across that mass.
uniform float floor_density : hint_range(0.0, 1.0) = 0.0;
// Height fraction (0 = SHELL_BOTTOM, 1 = SHELL_TOP) where the bank starts to
// thin, and how much the noise wobbles that edge.
uniform float top_start : hint_range(0.0, 1.0) = 0.34;
uniform float raggedness : hint_range(0.0, 1.0) = 0.4;
// World-space Y of the shell's bottom and top rims; the vertical gradient is
// anchored to these rather than to UV.y so it stays put if the mesh changes.
uniform float base_y = -30.0;
uniform float top_y = 130.0;
// Metres of depth over which the bank dissolves into geometry behind it.
uniform float soft_distance : hint_range(1.0, 80.0) = 24.0;
// Fades the shell out point-blank, so clipping the near plane can't flash a
// hard-edged slab across the frame.
uniform float near_fade : hint_range(0.0, 20.0) = 4.0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// UV.x runs across the wall; the vertical is metres of world height, so the
	// gradient is anchored in the world rather than to the mesh's proportions.
	vec2 base = vec2(UV.x * tiles_across, world_pos.y * tiles_up);
	float t = TIME * scroll;
	// Three octaves, each drifting its own way, so the bank churns instead of
	// sliding past as one sheet.
	float n1 = texture(fog_noise, base + vec2(t * 0.0040, t * 0.0021)).r;
	float n2 = texture(fog_noise, base * 2.0 - vec2(t * 0.0090, t * 0.0035)).r;
	float n3 = texture(fog_noise, base * 4.0 + vec2(t * 0.0170, -t * 0.0060)).r;
	float billow = n1 * 0.55 + n2 * 0.30 + n3 * 0.15;
	billow = clamp((billow - 0.5) * contrast + 0.5, 0.0, 1.0);

	// Threshold into clumps rather than using the noise as density directly:
	// that's the difference between rolling smoke and dirty glass. The clumps
	// ride on floor_density rather than starting from nothing, so a shell can be
	// opaque and still churn.
	float shape = mix(floor_density, 1.0, smoothstep(coverage, coverage + 0.4, billow));

	// Solid at the base, dissolving into the sky above — on a wobbled edge.
	float h = clamp((world_pos.y - base_y) / max(top_y - base_y, 0.001), 0.0, 1.0);
	float vert = 1.0 - smoothstep(top_start, 1.0, h + (billow - 0.5) * raggedness);

	// Soft particle: how much real scene sits behind this pixel. Fading the fog
	// as that gap closes is what stops the bank slicing a line across the hills
	// and the sea it stands in.
	float raw = texture(depth_texture, SCREEN_UV).r;
	vec4 view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, raw, 1.0);
	float scene_depth = -(view.xyz / view.w).z;
	float frag_depth = -VERTEX.z;
	float soft = clamp((scene_depth - frag_depth) / soft_distance, 0.0, 1.0);
	float near = smoothstep(0.0, near_fade, frag_depth);

	vec3 col = mix(deep_color, fog_color, clamp(billow * 1.4, 0.0, 1.0));
	col = mix(col * 0.9, col, h);  // the base of a bank sits in its own shadow

	ALBEDO = col;
	ALPHA = clamp(shape * vert * soft * near * density, 0.0, 1.0);
}
