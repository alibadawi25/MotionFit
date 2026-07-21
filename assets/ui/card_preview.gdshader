shader_type canvas_item;
// Rounds a game-card preview image to the card's corner radius and darkens the
// lower portion so the title/description/badge stay legible over any shot.
// `rect_size` is pushed from GameSelect on resize; `radius` should sit just
// inside the card's own StyleBox corner radius.
//
// NOTE: the corner mask and scrim are driven off VERTEX (the rect-local pixel
// position, 0..rect_size), NOT UV. The TextureRect uses KEEP_ASPECT_COVERED,
// which crops the texture and remaps UV so UV=0 no longer lands at the rect's
// corner — using UV here would round/darken the wrong place (or nowhere), which
// is why the corners looked square.

uniform vec2 rect_size = vec2(336.0, 228.0);
uniform float radius = 12.0;
// Peak darkening applied at the very bottom edge (0 = none, 1 = black).
uniform float scrim : hint_range(0.0, 1.0) = 0.95;
// Where the scrim starts fading in (0 = top, 1 = bottom). Kept low enough to
// only touch the bottom text band so the upper cinematic art stays bright.
uniform float scrim_start : hint_range(0.0, 1.0) = 0.34;
// Floor the scrim never drops below across the whole text band (title sits high
// in the band, above where the gradient would otherwise reach), so light text
// keeps contrast even over a bright shot. 0 = disabled.
uniform float scrim_floor : hint_range(0.0, 1.0) = 0.28;

// Rect-local pixel position, spanning (0,0)..rect_size regardless of the
// texture crop applied by KEEP_ASPECT_COVERED.
varying vec2 v_pos;

void vertex() {
	v_pos = VERTEX;
}

void fragment() {
	vec2 pos = v_pos;
	// Distance from the nearest horizontal/vertical edge, in pixels.
	vec2 corner = min(pos, rect_size - pos);
	// How far we are inside the quarter-circle carved out of each corner.
	vec2 d = vec2(radius) - corner;
	float dist = length(max(d, vec2(0.0)));
	float a = 1.0 - smoothstep(radius - 1.0, radius + 1.0, dist);

	// Bottom-weighted gradient scrim for text legibility. A gentle smoothstep ramp
	// (not squared — squaring left the mid-band where the description sits too
	// bright over light shots) that darkens toward the bottom text band, lifted by
	// a constant floor across that band so even the higher-sitting title/description
	// keep contrast over a bright image.
	float yn = clamp(pos.y / rect_size.y, 0.0, 1.0);
	float g = smoothstep(scrim_start, 1.0, yn);
	float band = smoothstep(scrim_start, scrim_start + 0.12, yn);
	float darken = max(g * scrim, band * scrim_floor);
	COLOR.rgb *= (1.0 - darken);
	COLOR.a *= a;
}
