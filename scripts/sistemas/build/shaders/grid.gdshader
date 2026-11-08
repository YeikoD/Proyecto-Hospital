shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

// Grilla dibujada sobre un plano. Se calcula en espacio local para que siga
// al nodo sin uniforms extra. La distancia a la camara solo se usa para
// desvanecer las lineas lejanas.

uniform float cell_size = 1.0;
uniform vec2 grid_extent = vec2(32.0, 32.0); // cantidad de celdas
uniform vec4 fill_color : source_color = vec4(0.18, 0.45, 0.65, 0.05);
uniform vec4 minor_color : source_color = vec4(0.35, 0.78, 0.95, 0.30);
uniform vec4 major_color : source_color = vec4(0.55, 0.92, 1.0, 0.70);
uniform vec4 border_color : source_color = vec4(0.65, 1.0, 1.0, 0.95);
uniform int major_every = 5;
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

void fragment() {
	vec2 local_cells = (local_xz + grid_extent * cell_size * 0.5) / cell_size;

	float minor = grid_mask(local_cells);
	float major = grid_mask(local_cells / float(major_every));

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
	color = mix(color, minor_color.rgb, minor * minor_color.a);
	alpha = max(alpha, minor * minor_color.a);
	color = mix(color, major_color.rgb, major * major_color.a);
	alpha = max(alpha, major * major_color.a);
	color = mix(color, border_color.rgb, border * border_color.a);
	alpha = max(alpha, border * border_color.a);

	float fade = 1.0 - smoothstep(fade_start, fade_end, distance(world_pos, CAMERA_POSITION_WORLD));

	ALBEDO = color;
	ALPHA = alpha * fade;
}
