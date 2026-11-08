class_name BuildPiece
extends StaticBody3D

## Pieza ya colocada (suelo o pared). El controlador le ajusta las dimensiones
## segun la grilla, asi los prefabs pueden estar modelados en 1x1x1.

## Celda que ocupa (solo suelos).
var cell := Vector2i.ZERO
## Borde que ocupa (solo paredes).
var wall_key := Vector3i.ZERO
var is_wall := false

@onready var _mesh_instance: MeshInstance3D = get_node_or_null("MeshInstance3D")
@onready var _collision: CollisionShape3D = get_node_or_null("CollisionShape3D")


## Reemplaza malla y colision por una caja del tamano pedido.
## Si la pieza envuelve un modelo arbitrario (sin MeshInstance3D propio),
## no se toca la malla; solo se ajusta la colision si existe.
func set_dimensions(size: Vector3) -> void:
	if _mesh_instance == null:
		# Pieza con modelo arbitrario: conservar malla y colision ya creadas.
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
