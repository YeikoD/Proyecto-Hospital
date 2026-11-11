shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

// Previsualizacion plana del pincel de pisos.
//
// Se dibuja un unico quad que cubre todo el rectangulo del trazado. Las UV
// recorren el area en el sentido del pincel (0 = esquina del primer clic), asi
// el relleno avanza fila por fila igual que la colocacion real.
//
// No usa el shader holograma a proposito: un piso se lee mejor como una
// superficie plana con borde nitido, cuadricula por celda y relleno progresivo.
// Eso deja claro que area se va a cubrir y por donde va el trazado.

uniform vec4 fill_color : source_color = vec4(0.25, 1.0, 0.6, 1.0);
uniform vec4 line_color : source_color = vec4(0.78, 1.0, 0.9, 1.0);
uniform vec4 invalid_color : source_color = vec4(1.0, 0.3, 0.25, 1.0);
// Cantidad de celdas del rectangulo (columnas, filas).
uniform vec2 grid_size = vec2(1.0, 1.0);
// Celdas ya pintadas; puede ser fraccionario (fundido por celda).
uniform float reveal_cells = 1.0;
// Indice de la celda bajo el cursor en orden de trazado. -1 = ninguna.
uniform float current_index = -1.0;
// Opacidades y grosores (los grosores se miden en celdas).
uniform float base_alpha = 0.10;
uniform float fill_alpha = 0.30;
uniform float line_alpha = 0.50;
uniform float border_alpha = 0.95;
uniform float border_width = 0.075;
uniform float grid_width = 0.024;
// Mascara de validez: 1 = celda libre, 0 = ocupada / fuera de la grilla.
uniform sampler2D valid_mask : filter_nearest;

varying vec2 v_uv;

float line_mask(float dist, float width, float aa) {
	return 1.0 - smoothstep(width, width + aa, dist);
}

void vertex() {
	v_uv = UV;
}

void fragment() {
	vec2 p = v_uv * grid_size;
	vec2 cell = floor(p);
	vec2 f = fract(p);
	float index = cell.y * grid_size.x + cell.x;

	// Antialiasing segun el tamano de pixel en espacio de celdas.
	float aa = max(fwidth(p.x), fwidth(p.y));
	float safe_aa = max(aa, 0.0001);
	float grid_w = max(grid_width, safe_aa * 1.1);
	float border_w = max(border_width, safe_aa * 1.1);

	// Distancia al borde de la celda y al borde exterior del rectangulo.
	float cell_edge = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y));
	float rect_edge = min(min(p.x, grid_size.x - p.x), min(p.y, grid_size.y - p.y));

	float grid = line_mask(cell_edge, grid_w, safe_aa * 1.4);
	float border = line_mask(rect_edge, border_w, safe_aa * 1.4);

	float valid = texture(valid_mask, (cell + 0.5) / grid_size).r;

	// Progreso por celda: 0 = todavia no pintada, 1 = relleno completo.
	float t = clamp(reveal_cells - index, 0.0, 1.0);
	float is_current = step(abs(index - current_index), 0.5);

	vec3 cell_fill = mix(invalid_color.rgb, fill_color.rgb, valid);
	vec3 cell_line = mix(invalid_color.rgb, line_color.rgb, valid);

	// Relleno tenue de toda el area: el rectangulo objetivo se ve desde el
	// primer clic, aunque el trazado todavia no haya llegado a esa celda.
	float alpha = base_alpha * mix(0.55, 1.0, valid);
	alpha += fill_alpha * t * mix(0.4, 1.0, valid);

	// La celda actual se marca con un relleno algo mas fuerte.
	alpha += is_current * fill_alpha * 0.55 * mix(0.5, 1.0, valid);

	// Cuadricula: tenue antes de pintar, nitida en lo ya colocado.
	alpha += grid * line_alpha * (0.35 + 0.65 * t) * mix(0.5, 1.0, valid);

	// Borde exterior siempre visible: marca el area exacta del trazado.
	alpha += border * border_alpha;

	// Contorno mas grueso de la celda actual (borde de avance).
	float current_edge = line_mask(cell_edge, grid_w * 2.2, safe_aa * 1.4);
	alpha += is_current * current_edge * 0.6;

	vec3 color = mix(cell_fill, cell_line,
		clamp(grid + border + is_current * current_edge, 0.0, 1.0));

	ALBEDO = color;
	ALPHA = clamp(alpha, 0.0, 0.92);
}
