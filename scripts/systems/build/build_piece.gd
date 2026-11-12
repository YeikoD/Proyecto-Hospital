class_name BuildPiece
extends StaticBody3D

## Pieza ya colocada (suelo, pared u objeto). El controlador le ajusta las
## dimensiones segun la grilla, asi los prefabs pueden estar modelados en 1x1x1.

## Celda que ocupa (suelos y objetos).
var cell := Vector2i.ZERO
## Borde que ocupa (solo paredes).
var wall_key := Vector3i.ZERO
var is_wall := false
## Identificador del BuildItem usado para crear la pieza (persistencia).
var item_id: StringName = &""
## Rotación en pasos de 90° (objetos).
var object_rotation_steps: int = 0
## Desplazamiento fino (sub-grilla) del objeto respecto del centro de su
## huella. Permite colocarlo con precision de medio metro.
var sub_offset := Vector3.ZERO

@onready var _mesh_instance: MeshInstance3D = get_node_or_null("MeshInstance3D")
@onready var _collision: CollisionShape3D = get_node_or_null("CollisionShape3D")


## Reemplaza malla y colision por una caja del tamano pedido.
## Si la pieza envuelve un modelo arbitrario (sin MeshInstance3D propio),
## no se toca la malla; solo se ajusta la colision si existe.
func set_dimensions(size: Vector3) -> void:
	if _mesh_instance == null:
		# Pieza con modelo arbitrario: conservar malla y colision ya creadas.
		return

	# Solo redimensionar mallas procedurales (cajas). Las mallas importadas
	# (esquinas, mapas) se conservan para no destruir su geometria.
	if not (_mesh_instance.mesh is BoxMesh):
		if _collision != null and _collision.shape is BoxShape3D:
			var shape := _collision.shape as BoxShape3D
			shape.size = size
		return

	var old_mesh := _mesh_instance.mesh as BoxMesh
	var box := BoxMesh.new()
	box.size = size
	if old_mesh != null:
		box.material = old_mesh.material
	_mesh_instance.mesh = box

	if _collision != null:
		var shape := BoxShape3D.new()
		shape.size = size
		_collision.shape = shape
