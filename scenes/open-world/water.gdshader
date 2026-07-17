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
// Shore band thickness (metres of water depth) that reads as foam.
uniform float foam_depth : hint_range(0.05, 5.0) = 0.9;
uniform float wave_height : hint_range(0.0, 2.0) = 0.3;
uniform float wave_speed : hint_range(0.0, 4.0) = 1.0;
// World-space scale of the small surface ripples that catch the sun: UV
// repeats per metre for the primary noise layer (the second layer scrolls at
// 0.38x this scale, the other way, so the pattern never visibly tiles).
uniform float ripple_scale : hint_range(0.001, 0.5) = 0.05;
uniform float ripple_strength : hint_range(0.0, 2.0) = 0.6;
uniform float roughness_value : hint_range(0.0, 1.0) = 0.08;

// A seamless noise normal map (NoiseTexture2D with as_normal_map, supplied by
// the scene). Real noise instead of summed sines: no interference lattices.
uniform sampler2D wave_noise : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D depth_texture : hint_depth_texture, filter_linear;

varying vec3 world_pos;

// Broad swell: a few offset sines so crests drift instead of marching in rows.
float swell(vec2 p, float t) {
	return sin(p.x * 0.11 + t) * 0.45
			+ sin(p.y * 0.087 - t * 1.27) * 0.35
			+ sin((p.x + p.y) * 0.061 + t * 0.73) * 0.2;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX.y += swell(world_pos.xz, TIME * wave_speed) * wave_height;
}

void fragment() {
	float t = TIME * wave_speed;
	// Two noise layers at different scales drifting in different directions;
	// their sum never repeats visibly and mipmaps handle distance for free.
	vec2 uv1 = world_pos.xz * ripple_scale + t * vec2(0.021, 0.014);
	vec2 uv2 = world_pos.xz * ripple_scale * 0.38 - t * vec2(0.012, 0.017);
	vec3 n1 = texture(wave_noise, uv1).rgb * 2.0 - 1.0;
	vec3 n2 = texture(wave_noise, uv2).rgb * 2.0 - 1.0;
	// Normals are still sub-pixel noise far away; ease them off so the far
	// water reads as a smooth fresnel sheet instead of shimmer.
	float detail = clamp(1.0 - length(VERTEX) / 250.0, 0.15, 1.0);
	vec2 nxy = (n1.xy + n2.xy * 0.8) * ripple_strength * detail;
	vec3 n = normalize(NORMAL + TANGENT * nxy.x + BINORMAL * nxy.y);
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

	// Shore foam, with a little noise wobble so the line isn't a hard contour.
	float foam_edge = foam_depth * (0.8 + 0.5 * n1.x);
	float foam = 1.0 - smoothstep(0.0, foam_edge, water_depth);
	color = mix(color, foam_color, foam * 0.85);

	ALBEDO = color;
	ROUGHNESS = roughness_value;
	SPECULAR = 0.5;
	// Shallows stay translucent so the terrain shows through; deep water and
	// foam go near-opaque, which is what actually "covers everything under it".
	ALPHA = clamp(mix(0.55, 0.97, max(deep_mix, foam)) + fresnel * 0.3, 0.0, 1.0);
}
