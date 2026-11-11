shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

// Fantasma de colocación usado por el pincel de construccion (paredes y
// objetos).
//
// El material se aplica por `material_override` a la malla real del modelo, asi
// la previsualizacion tiene exactamente la misma forma que la pieza que se va a
// colocar. La construccion progresiva se hace recortando la geometria por encima
// de `reveal`, medido en altura de mundo (asi funciona igual para modelos
// centrados, con origen en la base o cajas procedurales).

uniform vec4 ghost_color : source_color = vec4(0.32, 1.0, 0.72, 1.0);
uniform float ghost_alpha : hint_range(0.0, 1.0) = 0.34;
// 0 = tramo normal del arrastre, 1 = tramo actual (bajo el cursor).
uniform float strength : hint_range(0.0, 1.0) = 0.65;
// 0..1: fraccion de la pared que ya se "construyo" desde el suelo.
uniform float reveal : hint_range(0.0, 1.0) = 1.0;
uniform float build_bottom = 0.0;
uniform float build_top = 3.0;

uniform float rim_power = 2.2;
uniform float rim_strength = 1.35;
uniform float scanline_strength = 0.22;
uniform float scanline_count = 14.0;
uniform float pulse_speed = 2.4;
uniform float edge_glow = 1.0;

varying vec3 v_world;
varying float v_height;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float span = max(build_top - build_bottom, 0.0001);
	v_height = clamp((v_world.y - build_bottom) / span, 0.0, 1.0);
}

void fragment() {
	// La pared crece desde el suelo: todo lo que aun no se construyo no existe.
	if (v_height > reveal) {
		discard;
	}

	float facing = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float rim = pow(1.0 - clamp(facing, 0.0, 1.0), rim_power);

	// Lineas horizontales tipo holograma.
	float scan = 0.5 + 0.5 * sin((v_world.y * scanline_count - TIME * 1.6) * 6.28318);

	// Borde brillante en el frente de construccion.
	float edge = smoothstep(reveal - 0.09, reveal, v_height);
	float pulse = 0.92 + 0.08 * sin(TIME * pulse_speed);

	vec3 color = ghost_color.rgb;
	color += ghost_color.rgb * rim * rim_strength;
	color += ghost_color.rgb * scan * scanline_strength;
	color += ghost_color.rgb * edge * edge_glow * 1.75;

	float alpha = ghost_alpha;
	alpha *= mix(0.55, 1.25, strength);
	alpha *= 0.55 + rim * 0.85;
	alpha += scan * scanline_strength * 0.35;
	alpha += edge * edge_glow * 0.5;
	alpha *= pulse;

	ALBEDO = color;
	ALPHA = clamp(alpha, 0.0, 0.92);
}
