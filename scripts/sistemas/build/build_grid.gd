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

const GRID_SHADER := preload("res://scripts/sistemas/build/shaders/grid.gdshader")

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

var _overlay: MeshInstance3D
var _material: ShaderMaterial
var _plane: PlaneMesh


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
	var reach := maxf(size.x, size.y)
	_material.set_shader_parameter("fade_start", reach * 2.0)
	_material.set_shader_parameter("fade_end", reach * 3.5)
