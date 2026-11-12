@tool
class_name BuildGrid
extends Node3D

## Grilla de construccion, alineada a los ejes X/Z.
##
## La celda (0, 0) empieza en la posicion del nodo. El plano de construccion
## queda en `plane_y` (altura local). No rotar el nodo: la matematica asume
## que sus ejes coinciden con los del mundo.
##
## Convencion de paredes: una pared vive en un borde de celda y se identifica
## con un Vector3i(x, z, axis):
##   axis 0 -> borde vertical (normal en X), `x` es el indice del borde
##   axis 1 -> borde horizontal (normal en Z), `z` es el indice del borde

const GRID_SHADER := preload("res://scripts/systems/build/shaders/grid.gdshader")
## La grilla secundaria se dibuja justo sobre la cara superior del piso. Este
## pequeno extra evita que el slab del piso la tape o que haya z-fighting.
const FLOOR_GRID_LIFT := 0.006

@export var wall_thickness := 0.2:
	set(value):
		wall_thickness = maxf(value, 0.01)
		_refresh_overlay()

@export var cell_size := 1.0:
	set(value):
		cell_size = maxf(value, 0.05)
		_refresh_overlay()
@export var cells_x := 32:
	set(value):
		cells_x = maxi(value, 1)
		_refresh_overlay()
@export var cells_z := 32:
	set(value):
		cells_z = maxi(value, 1)
		_refresh_overlay()
## Altura del plano de construccion respecto del nodo.
@export var plane_y := 0.0:
	set(value):
		plane_y = value
		_refresh_overlay()
@export var show_border := true:
	set(value):
		show_border = value
		_refresh_overlay()

@export_group("Grilla sobre pisos")
## Dibuja una segunda grilla que solo cubre las celdas con piso colocado, a la
## altura de la cara superior del piso (para que el slab no la tape).
@export var show_floor_grid := true:
	set(value):
		show_floor_grid = value
		_rebuild_floor_overlay()
## Multiplicador de opacidad de esa segunda grilla. Menor que 1 la hace mas
## transparente que la grilla principal.
@export_range(0.0, 1.0, 0.01) var floor_grid_opacity := 0.6:
	set(value):
		floor_grid_opacity = clampf(value, 0.0, 1.0)
		_refresh_floor_material()

@export_group("Sub-grilla")
## Divisiones por celda de la sub-grilla. `2` divide cada metro cuadrado en 4
## (paso de 0,5 m), como el modo de precision de Los Sims.
@export_range(1, 8, 1) var subdivisions := 2:
	set(value):
		subdivisions = clampi(value, 1, 8)
		_refresh_overlay()
## Dibuja las lineas finas de la sub-grilla.
@export var show_subdivisions := true:
	set(value):
		show_subdivisions = value
		_refresh_overlay()
## Largo de cada guion de la sub-grilla, en celdas (0.1 = 10 cm).
@export_range(0.02, 0.5, 0.01) var sub_dash_length := 0.1:
	set(value):
		sub_dash_length = clampf(value, 0.01, 0.5)
		_refresh_overlay()
## Separacion entre guiones, en celdas (0.1 = 10 cm).
@export_range(0.0, 0.5, 0.01) var sub_dash_gap := 0.1:
	set(value):
		sub_dash_gap = clampf(value, 0.0, 0.5)
		_refresh_overlay()

## Se emite cuando cambia el tamano de la grilla (manual o automaticamente).
signal grid_resized(cells_x: int, cells_z: int)

@export_group("Expansión")
## La grilla es fija por defecto. Activa esto solo si quieres que crezca sola
## al construir cerca del borde +X/+Z.
@export var auto_expand := false
## Celdas que se anaden en cada expansion (botones y modo automatico).
@export var expand_step := 8:
	set(value):
		expand_step = maxi(value, 1)
## Distancia (en celdas) al borde que dispara la expansion automatica.
@export var expand_margin := 2:
	set(value):
		expand_margin = maxi(value, 0)
@export_tool_button("Expandir +X") var expand_x_button = _expand_inspector_x
@export_tool_button("Expandir +Z") var expand_z_button = _expand_inspector_z
@export_tool_button("Expandir ambos") var expand_both_button = _expand_inspector_both

var _overlay: MeshInstance3D
var _material: ShaderMaterial
var _plane: PlaneMesh
## Segunda grilla: un quad por cada celda con piso colocado.
var _floor_overlay: MeshInstance3D
var _floor_material: ShaderMaterial
var _floor_cells: Array[Vector2i] = []
## Altura de la cara superior de cada piso, en coordenadas de mundo.
var _floor_tops := PackedFloat32Array()


func _ready() -> void:
	_build_overlay()


# --------------------------------------------------------------------------
# Celdas
# --------------------------------------------------------------------------

## Celda que contiene un punto del mundo (puede estar fuera de los limites).
func cell_from_world(world: Vector3) -> Vector2i:
	var base := global_position
	return Vector2i(
		floori((world.x - base.x) / cell_size),
		floori((world.z - base.z) / cell_size)
	)


func is_cell_inside(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < cells_x and cell.y < cells_z


func clamp_cell(cell: Vector2i) -> Vector2i:
	return Vector2i(
		clampi(cell.x, 0, cells_x - 1),
		clampi(cell.y, 0, cells_z - 1)
	)


## Centro de la celda, sobre el plano de construccion.
func cell_center(cell: Vector2i) -> Vector3:
	var base := global_position
	return Vector3(
		base.x + (cell.x + 0.5) * cell_size,
		plane_global_y(),
		base.z + (cell.y + 0.5) * cell_size
	)


func plane_global_y() -> float:
	return global_position.y + plane_y


func center_point() -> Vector3:
	return Vector3(
		global_position.x + cells_x * cell_size * 0.5,
		plane_global_y(),
		global_position.z + cells_z * cell_size * 0.5
	)


## Paso de la sub-grilla en metros (0,5 con `subdivisions = 2`).
func sub_cell_size() -> float:
	return cell_size / float(maxi(subdivisions, 1))


## Ajusta un desplazamiento XZ al paso de la sub-grilla. `max_steps` limita
## cuantos pasos finos se permite mover respecto del centro de la huella.
func snap_offset(delta: Vector2, max_steps: int = 1) -> Vector3:
	if subdivisions <= 1:
		return Vector3.ZERO
	var step := sub_cell_size()
	var limit := step * float(maxi(max_steps, 0))
	return Vector3(
		clampf(roundf(delta.x / step) * step, -limit, limit),
		0.0,
		clampf(roundf(delta.y / step) * step, -limit, limit)
	)


# --------------------------------------------------------------------------
# Tamano / expansion
# --------------------------------------------------------------------------

## Cambia el tamano de la grilla en celdas. Mantiene fijo el origen (celda 0,0),
## asi que crece hacia +X y +Z.
func set_grid_size(new_cells_x: int, new_cells_z: int) -> void:
	var cx := maxi(new_cells_x, 1)
	var cz := maxi(new_cells_z, 1)
	if cx == cells_x and cz == cells_z:
		return
	cells_x = cx
	cells_z = cz
	if _overlay != null:
		_refresh_overlay()
	grid_resized.emit(cells_x, cells_z)


## Anade celdas al tamano actual. Negativo reduce (sin bajar de 1).
func expand(add_x: int, add_z: int) -> void:
	set_grid_size(cells_x + add_x, cells_z + add_z)


## Si `cell` esta dentro de la grilla pero cerca del borde +X/+Z, la agranda
## `expand_step` celdas para que se pueda seguir construyendo. Devuelve true si
## hubo expansion.
func expand_if_near_edge(cell: Vector2i) -> bool:
	if not auto_expand:
		return false
	if cell.x < 0 or cell.y < 0 or cell.x >= cells_x or cell.y >= cells_z:
		return false
	# Al menos la ultima celda siempre dispara; si no, con pasos chicos la
	# expansion no llegaria a activarse nunca.
	var margin := maxi(clampi(expand_margin, 0, expand_step - 1), 1)
	var grow_x := expand_step if cell.x >= cells_x - margin else 0
	var grow_z := expand_step if cell.y >= cells_z - margin else 0
	if grow_x == 0 and grow_z == 0:
		return false
	expand(grow_x, grow_z)
	return true


func _expand_inspector_x() -> void:
	expand(expand_step, 0)


func _expand_inspector_z() -> void:
	expand(0, expand_step)


func _expand_inspector_both() -> void:
	expand(expand_step, expand_step)


# --------------------------------------------------------------------------
# Paredes (bordes de celda)
# --------------------------------------------------------------------------

## Borde de celda mas cercano a un punto del mundo.
func wall_from_world(world: Vector3) -> Vector3i:
	var cell := cell_from_world(world)
	var base := global_position
	var local_x := (world.x - base.x) / cell_size - float(cell.x)
	var local_z := (world.z - base.z) / cell_size - float(cell.y)
	var dist_x := minf(local_x, 1.0 - local_x)
	var dist_z := minf(local_z, 1.0 - local_z)
	if dist_x <= dist_z:
		return Vector3i(cell.x + (1 if local_x > 0.5 else 0), cell.y, 0)
	return Vector3i(cell.x, cell.y + (1 if local_z > 0.5 else 0), 1)


func is_wall_inside(key: Vector3i) -> bool:
	if key.z == 0:
		return key.x >= 0 and key.x <= cells_x and key.y >= 0 and key.y < cells_z
	return key.x >= 0 and key.x < cells_x and key.y >= 0 and key.y <= cells_z


func clamp_wall(key: Vector3i) -> Vector3i:
	if key.z == 0:
		return Vector3i(
			clampi(key.x, 0, cells_x),
			clampi(key.y, 0, cells_z - 1),
			0
		)
	return Vector3i(
		clampi(key.x, 0, cells_x - 1),
		clampi(key.y, 0, cells_z),
		1
	)


## Punto medio del borde, sobre el plano de construccion.
## El grosor se desfasa medio espesor hacia el interior de la celda para que
## las caras exteriores de las paredes que se cruzan en una esquina queden
## alineadas (estilo Sims).
func wall_center(key: Vector3i) -> Vector3:
	var base := global_position
	var half_thick := wall_thickness * 0.5
	var x := base.x
	var z := base.z
	if key.z == 0:
		x += key.x * cell_size + half_thick
		z += (key.y + 0.5) * cell_size
	else:
		x += (key.x + 0.5) * cell_size
		z += key.y * cell_size + half_thick
	return Vector3(x, plane_global_y(), z)


## Rotacion (en Y) que debe llevar una pared modelada a lo largo de X.
func wall_yaw(key: Vector3i) -> float:
	return PI * 0.5 if key.z == 0 else 0.0


## Los cuatro bordes que rodean una celda.
func wall_keys_around_cell(cell: Vector2i) -> Array[Vector3i]:
	return [
		Vector3i(cell.x, cell.y, 0),
		Vector3i(cell.x + 1, cell.y, 0),
		Vector3i(cell.x, cell.y, 1),
		Vector3i(cell.x, cell.y + 1, 1),
	]


# --------------------------------------------------------------------------
# Visual
# --------------------------------------------------------------------------

## Actualiza la grilla secundaria. `cells` son las celdas con piso colocado y
## `tops` la altura de la cara superior de cada piso en coordenadas de mundo.
func set_floor_cells(cells: Array[Vector2i], tops: PackedFloat32Array) -> void:
	_floor_cells = cells.duplicate()
	_floor_tops = tops.duplicate()
	_rebuild_floor_overlay()


## Quita por completo la grilla secundaria (no hay pisos colocados).
func clear_floor_cells() -> void:
	_floor_cells.clear()
	_floor_tops.clear()
	_rebuild_floor_overlay()


func _build_overlay() -> void:
	if _overlay != null:
		_refresh_overlay()
		return

	_plane = PlaneMesh.new()
	_material = ShaderMaterial.new()
	_material.shader = GRID_SHADER

	_overlay = MeshInstance3D.new()
	_overlay.name = "GridOverlay"
	_overlay.mesh = _plane
	_overlay.material_override = _material
	_overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_overlay)

	_floor_material = ShaderMaterial.new()
	_floor_material.shader = GRID_SHADER

	_floor_overlay = MeshInstance3D.new()
	_floor_overlay.name = "FloorGridOverlay"
	_floor_overlay.material_override = _floor_material
	_floor_overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_floor_overlay.visible = false
	add_child(_floor_overlay)

	_refresh_overlay()


func _refresh_overlay() -> void:
	if _overlay == null:
		return
	var size := Vector2(cells_x * cell_size, cells_z * cell_size)
	_plane.size = size
	_overlay.position = Vector3(size.x * 0.5, plane_y + 0.015, size.y * 0.5)
	_material.set_shader_parameter("cell_size", cell_size)
	_material.set_shader_parameter("grid_extent", Vector2(cells_x, cells_z))
	_material.set_shader_parameter("show_border", show_border)
	_material.set_shader_parameter("subdivisions", subdivisions)
	_material.set_shader_parameter("show_subdivisions", show_subdivisions)
	_material.set_shader_parameter("sub_dash_length", sub_dash_length)
	_material.set_shader_parameter("sub_dash_gap", sub_dash_gap)
	var reach := maxf(size.x, size.y)
	_material.set_shader_parameter("fade_start", reach * 2.0)
	_material.set_shader_parameter("fade_end", reach * 3.5)
	_refresh_floor_material()
	_rebuild_floor_overlay()


## Aplica los parametros comunes a la grilla de pisos. Las alphas salen de las
## de la grilla principal multiplicadas por `floor_grid_opacity`.
func _refresh_floor_material() -> void:
	if _floor_material == null:
		return
	_floor_material.set_shader_parameter("cell_size", cell_size)
	_floor_material.set_shader_parameter("grid_extent", Vector2(cells_x, cells_z))
	_floor_material.set_shader_parameter("show_border", show_border)
	_floor_material.set_shader_parameter("subdivisions", subdivisions)
	_floor_material.set_shader_parameter("show_subdivisions", show_subdivisions)
	_floor_material.set_shader_parameter("sub_dash_length", sub_dash_length)
	_floor_material.set_shader_parameter("sub_dash_gap", sub_dash_gap)
	var size := Vector2(cells_x * cell_size, cells_z * cell_size)
	var reach := maxf(size.x, size.y)
	_floor_material.set_shader_parameter("fade_start", reach * 2.0)
	_floor_material.set_shader_parameter("fade_end", reach * 3.5)
	var opacity := clampf(floor_grid_opacity, 0.0, 1.0)
	_floor_material.set_shader_parameter(
		"fill_color", Color(1.0, 1.0, 1.0, 0.03 * opacity)
	)
	_floor_material.set_shader_parameter(
		"minor_color", Color(1.0, 1.0, 1.0, 0.32 * opacity)
	)
	_floor_material.set_shader_parameter(
		"border_color", Color(1.0, 1.0, 1.0, 0.95 * opacity)
	)
	_floor_material.set_shader_parameter(
		"sub_color", Color(1.0, 1.0, 1.0, 0.24 * opacity)
	)


## Reconstruye la malla de la grilla de pisos: un quad por celda, a la altura
## de la cara superior de su piso. Las coordenadas se centran igual que el
## plano principal para que el patron del shader quede alineado.
func _rebuild_floor_overlay() -> void:
	if _floor_overlay == null:
		return
	var count := mini(_floor_cells.size(), _floor_tops.size())
	if not show_floor_grid or count == 0:
		_floor_overlay.mesh = null
		_floor_overlay.visible = false
		return

	var half := Vector2(cells_x * cell_size, cells_z * cell_size) * 0.5
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in count:
		var cell := _floor_cells[i]
		var y := _floor_tops[i] + FLOOR_GRID_LIFT - global_position.y
		var x0 := float(cell.x) * cell_size - half.x
		var z0 := float(cell.y) * cell_size - half.y
		_add_floor_quad(st, x0, x0 + cell_size, z0, z0 + cell_size, y)
	_floor_overlay.mesh = st.commit()

	_floor_overlay.position = Vector3(half.x, 0.0, half.y)
	_floor_overlay.visible = true


static func _add_floor_quad(
	st: SurfaceTool, x0: float, x1: float, z0: float, z1: float, y: float
) -> void:
	st.set_normal(Vector3.UP)
	st.add_vertex(Vector3(x0, y, z0))
	st.add_vertex(Vector3(x0, y, z1))
	st.add_vertex(Vector3(x1, y, z1))
	st.add_vertex(Vector3(x0, y, z0))
	st.add_vertex(Vector3(x1, y, z1))
	st.add_vertex(Vector3(x1, y, z0))
