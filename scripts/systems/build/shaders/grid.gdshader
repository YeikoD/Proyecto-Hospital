shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

// Grilla dibujada sobre un plano. Se calcula en espacio local para que siga
// al nodo sin uniforms extra. La distancia a la camara solo se usa para
// desvanecer las lineas lejanas.

uniform float cell_size = 1.0;
uniform vec2 grid_extent = vec2(32.0, 32.0); // cantidad de celdas
// Grilla blanca: un velo muy tenue y lineas blancas de distinta intensidad.
uniform vec4 fill_color : source_color = vec4(1.0, 1.0, 1.0, 0.03);
uniform vec4 minor_color : source_color = vec4(1.0, 1.0, 1.0, 0.32);
uniform vec4 border_color : source_color = vec4(1.0, 1.0, 1.0, 0.95);
// Sub-grilla: divide cada celda para mover objetos con mas precision.
uniform int subdivisions = 2;
uniform bool show_subdivisions = true;
uniform vec4 sub_color : source_color = vec4(1.0, 1.0, 1.0, 0.24);
// Guiones de la sub-grilla, en celdas. Con 0.1 + 0.1 se ven 5 guiones por
// metro, como la grilla fina de Los Sims.
uniform float sub_dash_length = 0.1;
uniform float sub_dash_gap = 0.1;
uniform float line_width = 1.2;
uniform bool show_border = true;
uniform float fade_start = 60.0;
uniform float fade_end = 120.0;

varying vec2 local_xz;
varying vec3 world_pos;

void vertex() {
	local_xz = VERTEX.xz;
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float grid_mask(vec2 coord) {
	vec2 aa = max(fwidth(coord), vec2(0.00001));
	vec2 grid = abs(fract(coord - 0.5) - 0.5) / aa;
	return 1.0 - clamp(min(grid.x, grid.y) / line_width, 0.0, 1.0);
}

// Mascara de guiones a lo largo de una linea. `t` avanza en la direccion de la
// linea (en celdas) y `period` es largo + separacion.
float dash_mask(float t, float period, float duty) {
	float f = fract(t / period);
	float aa = clamp(fwidth(t) / period, 0.0001, max(duty * 0.5, 0.0001));
	float start = smoothstep(0.0, aa, f);
	float end = 1.0 - smoothstep(duty - aa, duty + aa, f);
	return start * end;
}

void fragment() {
	vec2 local_cells = (local_xz + grid_extent * cell_size * 0.5) / cell_size;

	float minor = grid_mask(local_cells);

	float border = 0.0;
	if (show_border) {
		float edge = min(
			min(local_cells.x, grid_extent.x - local_cells.x),
			min(local_cells.y, grid_extent.y - local_cells.y)
		);
		float width = max(0.035 / cell_size, fwidth(local_cells.x) * 2.0);
		border = 1.0 - smoothstep(0.0, width, edge);
	}

	vec3 color = fill_color.rgb;
	float alpha = fill_color.a;
	if (show_subdivisions && subdivisions > 1) {
		vec2 sub_coord = local_cells * float(subdivisions);
		vec2 sub_aa = max(fwidth(sub_coord), vec2(0.00001));
		vec2 sub_grid = abs(fract(sub_coord - 0.5) - 0.5) / sub_aa;
		vec2 sub_line = 1.0 - clamp(sub_grid / line_width, 0.0, 1.0);
		float period = max(sub_dash_length + sub_dash_gap, 0.001);
		float duty = sub_dash_length / period;
		float dash_x = dash_mask(local_cells.x, period, duty);
		float dash_y = dash_mask(local_cells.y, period, duty);
		float sub = max(sub_line.x * dash_y, sub_line.y * dash_x);
		color = mix(color, sub_color.rgb, sub * sub_color.a);
		alpha = max(alpha, sub * sub_color.a);
	}
	color = mix(color, minor_color.rgb, minor * minor_color.a);
	alpha = max(alpha, minor * minor_color.a);
	color = mix(color, border_color.rgb, border * border_color.a);
	alpha = max(alpha, border * border_color.a);

	float fade = 1.0 - smoothstep(fade_start, fade_end, distance(world_pos, CAMERA_POSITION_WORLD));

	ALBEDO = color;
	ALPHA = alpha * fade;
}
