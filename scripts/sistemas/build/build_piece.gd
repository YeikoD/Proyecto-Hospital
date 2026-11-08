class_name BuildPiece
extends StaticBody3D

## Pieza ya colocada (suelo o pared). El controlador le ajusta las dimensiones
## segun la grilla, asi los prefabs pueden estar modelados en 1x1x1.

## Celda que ocupa (solo suelos).
var cell := Vector2i.ZERO
## Borde que ocupa (solo paredes).
var wall_key := Vector3i.ZERO
var is_wall := false

@onready var _mesh_instance: MeshInstance3D = $MeshInstance3D
@onready var _collision: CollisionShape3D = $CollisionShape3D


## Reemplaza malla y colision por una caja del tamano pedido.
func set_dimensions(size: Vector3) -> void:
	var old_mesh := _mesh_instance.mesh as BoxMesh
	var box := BoxMesh.new()
	box.size = size
	if old_mesh != null:
		box.material = old_mesh.material
	_mesh_instance.mesh = box

	var shape := BoxShape3D.new()
	shape.size = size
	_collision.shape = shape
