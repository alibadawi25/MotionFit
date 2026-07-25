shader_type spatial;
render_mode cull_disabled, depth_draw_always, specular_schlick_ggx;
// Open-world sea: an animated plane at a fixed sea level that visually floods
// every part of the terrain beneath it. Colour deepens with the real scene
// depth behind the surface (so valleys read as deep water and beaches as
// shallows) and a soft foam line marks the shore. cull_disabled keeps the
// surface visible from below if the player wades under.

uniform vec3 shallow_color : source_color = vec3(0.22, 0.55, 0.58);
uniform vec3 deep_color : source_color = vec3(0.03, 0.14, 0.26);
uniform vec3 foam_color : source_color = vec3(0.92, 0.96, 0.97);
// Metres of water that fade shallow_color fully into deep_color.
uniform float depth_fade : hint_range(0.5, 40.0) = 10.0;
// Shore band thickness (metres of water DEPTH, not width) that reads as foam.
// This island's coasts were sculpted steep — 25-30 degrees nearly all the way
// round — so a metre of depth buys only about two metres of visible band. The
// default is set from that, not from what looks right on a gentle beach.
uniform float foam_depth : hint_range(0.05, 8.0) = 2.4;
// How ragged the swash is: 0 = a solid painted band, 1 = torn to lace. This is
// the difference between "there is pale water near the sand" and "the sea is
// running up the beach", and it costs nothing but a threshold.
uniform float foam_lace : hint_range(0.0, 1.0) = 0.75;
// Thickness of the bright leading line at the top of the run-up, as a fraction
// of the band. The eye reads the shoreline off THIS, not off the wash behind it.
uniform float foam_edge : hint_range(0.0, 0.6) = 0.16;
// Metres of depth over which a passing swell shoals into breaking surf. On a
// steep coast this — not the foam band — is what actually reads as a shoreline
// from any distance, because it spans far more water than the swash does.
uniform float surf_depth : hint_range(0.1, 20.0) = 6.0;
uniform float wave_height : hint_range(0.0, 2.0) = 0.3;
uniform float wave_speed : hint_range(0.0, 4.0) = 1.0;
// Short choppy waves riding on the broad swell (0 = glassy rolling sea).
// Their wavelengths (~20-25 m) must stay well above the sea mesh's quad size
// or the vertex grid undersamples them into shimmering moire.
uniform float chop : hint_range(0.0, 2.0) = 1.0;
// Whitecap foam dusted on breaking crests (0 disables).
uniform float whitecap : hint_range(0.0, 1.0) = 0.35;
// Surface slope at which a crest is considered to be pitching over and going
// white. The wave sum's typical slope is around 0.09, so this sits deliberately
// above it: whitecaps are meant to be the exception on open water.
uniform float whitecap_break : hint_range(0.02, 0.4) = 0.13;
// Metres of sea per pixel at which whitecaps start fading out. See the
// footprint note in fragment() — this is an anti-aliasing control, not a
// distance control, and it is why the sea stops boiling at grazing angles.
uniform float whitecap_fade : hint_range(0.2, 10.0) = 1.1;
// World-space scale of the small surface ripples that catch the sun: UV
// repeats per metre for the primary noise layer (the second layer scrolls at
// 0.38x this scale, the other way, so the pattern never visibly tiles).
uniform float ripple_scale : hint_range(0.001, 0.5) = 0.05;
uniform float ripple_strength : hint_range(0.0, 2.0) = 0.6;
uniform float roughness_value : hint_range(0.0, 1.0) = 0.08;
// Metres of sea per pixel at which the ripples stop being normals and start
// being roughness instead. Smaller than whitecap_fade because ripples are
// metre-scale features and caps are twenty-metre ones, so the two alias at
// very different footprints. See the specular-aliasing note in fragment().
uniform float ripple_aa : hint_range(0.02, 2.0) = 0.05;
// Roughness the surface settles at once its ripples have fully dissolved.
uniform float ripple_rough : hint_range(0.0, 1.0) = 0.42;

// A seamless noise normal map (NoiseTexture2D with as_normal_map, supplied by
// the scene). Real noise instead of summed sines: no interference lattices.
uniform sampler2D wave_noise : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D depth_texture : hint_depth_texture, filter_linear;

varying vec3 world_pos;

// Broad swell + short chop: a few offset sines in different directions so
// crests drift instead of marching in rows. Height and slope must come from
// the SAME sum, so each term lives here once and _wave_eval returns both:
// h in .x, d/dx in .y, d/dz in .z.
vec3 _wave_term(vec2 p, vec2 k, float speed, float amp, float t) {
	float phase = dot(p, k) + t * speed;
	return vec3(sin(phase) * amp, cos(phase) * amp * k.x, cos(phase) * amp * k.y);
}

vec3 wave_eval(vec2 p, float t) {
	// Broad swell (wavelengths 57-103 m) — the slow breathing of the surface.
	vec3 w = _wave_term(p, vec2(0.11, 0.0), 1.0, 0.45, t)
			+ _wave_term(p, vec2(0.0, 0.087), -1.27, 0.35, t)
			+ _wave_term(p, vec2(0.061, 0.061), 0.73, 0.2, t);
	// Chop (wavelengths ~20-25 m) — what actually reads as "waves" in motion.
	w += (_wave_term(p, vec2(0.21, 0.14), 1.7, 0.20, t)
			+ _wave_term(p, vec2(0.16, -0.23), -1.4, 0.16, t)
			+ _wave_term(p, vec2(-0.09, 0.31), 2.1, 0.12, t)) * chop;
	return w * wave_height;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX.y += wave_eval(world_pos.xz, TIME * wave_speed).x;
}

void fragment() {
	float t = TIME * wave_speed;
	// Two noise layers at different scales drifting in different directions;
	// their sum never repeats visibly and mipmaps handle distance for free.
	vec2 uv1 = world_pos.xz * ripple_scale + t * vec2(0.021, 0.014);
	vec2 uv2 = world_pos.xz * ripple_scale * 0.38 - t * vec2(0.012, 0.017);
	vec3 n1 = texture(wave_noise, uv1).rgb * 2.0 - 1.0;
	vec3 n2 = texture(wave_noise, uv2).rgb * 2.0 - 1.0;
	// --- specular anti-aliasing ---------------------------------------------
	// How much sea one pixel covers, in metres. Look ALONG the water instead of
	// down at it and this explodes: a single pixel can span metres of surface,
	// while the ripple normal map cheerfully keeps handing back full-strength
	// normals for detail that pixel cannot possibly resolve. Under a near-mirror
	// roughness that turns the sun into a field of white sparks — the "boiling
	// sea" that made low camera angles look like churn rather than water. (It
	// was NOT the whitecaps: setting whitecap to 0 changed the shot not at all,
	// setting ripple_strength to 0 cleared it completely.)
	//
	// The fix is not to delete the detail but to MOVE it. Sub-pixel normal
	// variation and gloss spread are physically the same thing, so as the
	// ripples fade the surface gets rougher by exactly as much. Fading alone
	// would leave a mirror, which trades a field of sparks for one hard sun
	// blob — no better. And it keys on FOOTPRINT rather than distance because
	// the same water at the same range aliases when you look along it and is
	// fine when you look down at it; a distance fade cannot tell those apart.
	float footprint = length(fwidth(world_pos.xz));
	float blur = smoothstep(ripple_aa, ripple_aa * 8.0, footprint);
	vec2 nxy = (n1.xy + n2.xy * 0.8) * ripple_strength * (1.0 - blur);
	// The wave sum's analytic slope tilts the surface normal, which is what
	// makes the swell and chop visible as light: crests catch the sun and
	// troughs hold the sky colour. Without this the displacement is a silent
	// wobble the shading never sees.
	vec3 wave = wave_eval(world_pos.xz, t);
	vec3 n_world = normalize(vec3(-wave.y + nxy.x, 1.0, -wave.z + nxy.y));
	vec3 n = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);
	NORMAL = n;

	// Water column depth behind this pixel: scene depth minus surface depth.
	float depth_raw = texture(depth_texture, SCREEN_UV).r;
	vec4 view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth_raw, 1.0);
	float scene_depth = -(view.xyz / view.w).z;
	float water_depth = max(scene_depth - (-VERTEX.z), 0.0);

	float deep_mix = clamp(water_depth / depth_fade, 0.0, 1.0);
	vec3 color = mix(shallow_color, deep_color, deep_mix);

	// Fresnel: glancing angles reflect the sky and look more opaque.
	float fresnel = pow(1.0 - clamp(dot(n, VIEW), 0.0, 1.0), 4.0);
	color = mix(color, vec3(0.62, 0.72, 0.8), fresnel * 0.4);

	// --- the swash: foam running up and down the beach ----------------------
	// The band SURGES on its own, for free. water_depth is measured from the
	// DISPLACED surface, so every crest that rolls in thins the water over the
	// sand and throws the whole band inland; the trough drags it back out. All
	// this code has to do is give the band an edge worth watching.
	//
	// Guarded, and the guard is not a micro-optimisation. The swash needs two
	// more noise fetches to break the foam into lace, and the shore is a thin
	// ribbon around a sea plane 1600 m on a side — paying for those across all
	// of it cost ~16% of the frame on the shoreline leg of scenes/tests/
	// perf_view.tscn, for pixels hundreds of metres from any sand. The branch
	// is screen-coherent (whole tiles are either shore or open water), so the
	// open sea skips it outright.
	//
	// textureLod, NOT texture: an implicit-LOD sample inside divergent control
	// flow has no valid derivatives, so the driver takes a slow path and the
	// guard gives back much of what it saves. The foam noise is read at full
	// resolution anyway — it only ever runs on pixels a few metres from land.
	float foam = 0.0;
	if (water_depth < foam_depth) {
		// Churn mask, coarser than the specular ripples and scrolling the other
		// way, so the foam boils rather than sliding along as one sheet.
		float lace = textureLod(wave_noise,
						world_pos.xz * 0.09 + t * vec2(0.004, -0.007), 0.0).x
				+ textureLod(wave_noise,
						world_pos.xz * 0.26 - t * vec2(0.011, 0.006), 0.0).x;
		lace = clamp(lace * 0.5 + 0.5, 0.0, 1.0);

		// 0 at the seaward edge of the band, 1 at the run-up limit on the sand.
		float run_up = 1.0 - water_depth / max(foam_depth, 0.001);
		// Body: torn into streaks and holes, and denser the closer to the sand.
		// The threshold slides with run_up, so foam thickens up the beach
		// rather than dissolving evenly across the whole band.
		float body = smoothstep(0.5, 0.95,
				run_up * mix(1.0, 0.55 + 0.9 * lace, foam_lace));
		// Leading edge: the bright line the last of the run-up leaves behind.
		float edge = smoothstep(1.0 - foam_edge, 1.0 - foam_edge * 0.35, run_up);
		foam = clamp(body * 0.92 + edge * 0.85, 0.0, 1.0);
		color = mix(color, foam_color, foam);
	}

	// --- whitecaps ----------------------------------------------------------
	// Foam on crests that are BREAKING, which is not the same as crests that
	// are tall: a big glassy swell just lifts you, and what actually goes white
	// is the face pitching over. Keying on height alone put a cap on every
	// swell top; keying on the slope as well — free, it comes out of the same
	// sum as the height — keeps open water mostly clean and picks out the
	// steep chop, which is where foam belongs.
	float lift = smoothstep(0.6, 1.05, wave.x / max(wave_height, 0.001));
	float pitch = smoothstep(0.55, 1.05,
			length(wave.yz) / max(wave_height * whitecap_break, 0.001));
	float cap = lift * pitch * smoothstep(0.1, 0.5, n1.x + n2.y * 0.5) * whitecap;
	// Shoaling: the same crest that only glints in open water turns to
	// whitewater once the seabed comes up under it. This is what makes the
	// approach to the shore read as surf instead of a flat sheet that ends.
	cap *= 1.0 + 3.0 * (1.0 - smoothstep(0.0, surf_depth, water_depth));

	// Caps alias the same way the ripples do (analytic sum, no mip chain to
	// protect it), so they fade on the same footprint measure — just later,
	// being much larger features.
	float crisp = 1.0 - smoothstep(whitecap_fade, whitecap_fade * 6.0, footprint);
	color = mix(color, foam_color, clamp(cap, 0.0, 1.0) * crisp);

	ALBEDO = color;
	// Two roughness effects, innermost first: ripples that have gone sub-pixel
	// come back as gloss spread (see the specular-aliasing note above), and
	// foam on top of that is air in water — it scatters rather than reflects,
	// and left at the open sea's near-mirror value it reads as spilled paint.
	ROUGHNESS = mix(mix(roughness_value, ripple_rough, blur), 0.85, foam);
	SPECULAR = 0.5;
	// Shallows stay translucent so the terrain shows through; deep water and
	// foam go near-opaque, which is what actually "covers everything under it".
	ALPHA = clamp(mix(0.55, 0.97, max(deep_mix, foam)) + fresnel * 0.3, 0.0, 1.0);
}
