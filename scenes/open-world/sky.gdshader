shader_type sky;

// Open World sky: a scattering-style gradient, drifting volumetric-looking
// clouds, a real sun disc with glow, and a night star field.
//
// It replaces ProceduralSkyMaterial, whose flat two-colour ramp was the single
// biggest reason every outdoor shot read as "engine default" — a plain banded
// backdrop behind an otherwise detailed world.
//
// The four palette uniforms deliberately MIRROR ProceduralSkyMaterial's
// property names, because day_night_cycle.gd drives them through the whole day
// and was written against that material. Keeping the names identical means the
// cycle needs one adapter, not a rewrite, and the authored noon palette in
// open-world.tscn still means what it used to.
//
// Cost note: this is a full-screen shader on a laptop GPU (MX550), so the cloud
// FBM is deliberately kept to 5 octaves over two layers rather than a raymarch.
// Measure with scenes/tests/perf_view.tscn before adding octaves.

// --- palette (mirrors ProceduralSkyMaterial; driven by day_night_cycle.gd) ---
uniform vec3 sky_top_color : source_color = vec3(0.19, 0.38, 0.66);
uniform vec3 sky_horizon_color : source_color = vec3(0.68, 0.76, 0.84);
uniform vec3 ground_horizon_color : source_color = vec3(0.65, 0.71, 0.76);
uniform vec3 ground_bottom_color : source_color = vec3(0.2, 0.24, 0.28);
// Height (in EYEDIR.y) over which the horizon colour falls off. Small = a tight
// bright band hugging the horizon, which is what sells distance.
uniform float sky_curve = 0.18;

// --- clouds ---
uniform vec3 cloud_lit_color : source_color = vec3(1.0, 0.99, 0.96);
uniform vec3 cloud_dark_color : source_color = vec3(0.52, 0.58, 0.67);
// 0 = clear sky, 1 = overcast.
uniform float cloud_coverage : hint_range(0.0, 1.0) = 0.46;
// Width of the density ramp: low = hard-edged cumulus, high = soft haze.
uniform float cloud_softness : hint_range(0.02, 0.8) = 0.26;
uniform float cloud_scale = 1.7;
uniform float cloud_speed = 0.004;
// Global fade, dropped toward 0 at night so clouds don't glow in the dark.
uniform float cloud_opacity : hint_range(0.0, 1.0) = 1.0;

// --- sun & stars ---
uniform float sun_glow : hint_range(0.0, 4.0) = 1.0;
uniform float star_opacity : hint_range(0.0, 1.0) = 0.0;


float hash12(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}


float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);  // smoothstep weights: no lattice creases
	float a = hash12(i);
	float b = hash12(i + vec2(1.0, 0.0));
	float c = hash12(i + vec2(0.0, 1.0));
	float d = hash12(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}


float fbm(vec2 p) {
	float v = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 5; i++) {
		v += amp * vnoise(p);
		// 2.03 rather than 2.0: an exact doubling lines the octaves up on the
		// same lattice and prints a faint grid into the cloud field.
		p *= 2.03;
		amp *= 0.5;
	}
	return v;
}


void sky() {
	float up = EYEDIR.y;

	// Vertical gradient. Exponential falloff from the horizon rather than a
	// linear ramp — real sky brightness drops off fast just above the horizon
	// and then barely changes, which is what makes the band read as distance.
	vec3 col;
	if (up >= 0.0) {
		float t = exp(-up / max(sky_curve, 0.01));
		col = mix(sky_top_color, sky_horizon_color, t);
	} else {
		float t = exp(up / max(sky_curve, 0.01));
		col = mix(ground_bottom_color, ground_horizon_color, t);
	}

	// Stars, before the clouds so cloud cover occludes them.
	if (star_opacity > 0.001 && up > 0.0) {
		vec3 cell = floor(normalize(EYEDIR) * 180.0);
		float s = hash12(cell.xy + cell.z * 37.0);
		// step() at a high threshold keeps stars sparse; the smoothstep fades
		// them out near the horizon where the haze would drown them anyway.
		float star = step(0.9965, s) * smoothstep(0.0, 0.25, up);
		col += vec3(star) * star_opacity * (0.6 + 0.4 * hash12(cell.xz));
	}

	// Clouds live on a flat plane projected onto the dome. Cheap, and correct
	// enough: real cloud decks ARE a flat-ish layer, so the perspective
	// stretching toward the horizon is the effect rather than an artifact.
	//
	// The +0.12 rather than a max(up, small) matters: dividing by a clamped y
	// blows the UVs up to ~50x right at the horizon and smears the deck into
	// infinite radial streaks. Adding a constant softens the singularity and
	// gives the natural compression a real cloud layer has toward the horizon.
	vec2 cuv = EYEDIR.xz / (up + 0.12) * cloud_scale;
	float n1 = fbm(cuv + TIME * cloud_speed * vec2(1.0, 0.35));
	// Second, larger and slower layer for depth: a single-FBM cloud field
	// drifts as one rigid sheet and reads as wallpaper.
	float n2 = fbm(cuv * 0.47 - TIME * cloud_speed * vec2(0.6, 0.2));
	float d = mix(n1, n2, 0.4);
	// Summed-octave FBM clusters tightly around 0.5 (it is a sum of means), so
	// feeding it straight into a 0..1 threshold left the deck permanently thin
	// and semi-transparent no matter what coverage was set to. Stretch the band
	// the values actually occupy across the full range first, and coverage
	// starts behaving like the 0=clear/1=overcast dial it claims to be.
	d = clamp((d - 0.30) / 0.40, 0.0, 1.0);

	float thresh = 1.0 - cloud_coverage;
	float cover = smoothstep(thresh, thresh + cloud_softness, d);
	// Still fade the deck out at the very bottom of the sky, so it meets the
	// border fog cleanly instead of fighting it.
	cover *= smoothstep(-0.02, 0.10, up) * cloud_opacity;

	// Shade the cloud by how far into the mass this pixel is: thin edges lit,
	// thick middles dark. A flat-coloured cloud looks like torn paper.
	float thickness = smoothstep(thresh, thresh + cloud_softness * 2.2, d);
	vec3 cc = mix(cloud_lit_color, cloud_dark_color, thickness * 0.85);

	if (LIGHT0_ENABLED) {
		float sd = dot(EYEDIR, LIGHT0_DIRECTION);
		// Silver lining: cloud edges facing the sun pick its colour up.
		cc += LIGHT0_COLOR * pow(max(sd, 0.0), 6.0) * (1.0 - thickness) * 0.6;
		cc *= mix(vec3(1.0), LIGHT0_COLOR, 0.3);

		col = mix(col, cc, cover);

		// Sun disc and its two-stage glow, added AFTER the clouds so the deck
		// occludes it. The tight term is the bloom-catching core; the wide, weak
		// term is the haze halo that makes the sun sit in the atmosphere.
		float occl = 1.0 - cover;
		float disc = smoothstep(0.99965, 0.99985, sd);
		float glow = pow(max(sd, 0.0), 250.0) * 0.7 + pow(max(sd, 0.0), 10.0) * 0.10;
		col += LIGHT0_COLOR * (disc * 10.0 + glow * sun_glow) * LIGHT0_ENERGY * occl;
	} else {
		col = mix(col, cc, cover);
	}

	COLOR = col;
}
