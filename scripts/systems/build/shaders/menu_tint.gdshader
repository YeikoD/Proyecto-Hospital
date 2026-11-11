shader_type canvas_item;

// Tinta las previsualizaciones del menu conservando su forma (pasa a escala de
// grises y aplica el color). Los borradores lo usan en rojo para indicar que
// eliminan la pieza en lugar de colocarla.

uniform vec4 tint_color : source_color = vec4(1.0, 0.32, 0.28, 1.0);
uniform float tint_strength : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	float lum = dot(tex.rgb, vec3(0.299, 0.587, 0.114));
	vec3 shaded = tint_color.rgb * (0.22 + 0.78 * lum);
	COLOR = vec4(mix(tex.rgb, shaded, tint_strength), tex.a);
}
