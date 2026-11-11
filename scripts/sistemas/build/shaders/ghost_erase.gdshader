shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled, depth_test_disabled;

// Variante del fantasma para los borradores. Al no testear profundidad, el rojo
// se dibuja siempre sobre la pieza real aunque el fantasma ocupe el mismo
// espacio (si no, se ve a parches por z-fighting).
#include "res://scripts/sistemas/build/shaders/ghost_common.gdshaderinc"
