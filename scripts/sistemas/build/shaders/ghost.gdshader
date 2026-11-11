shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

// Fantasma de colocacion (paredes y objetos). Con test de profundidad normal.
#include "res://scripts/sistemas/build/shaders/ghost_common.gdshaderinc"
