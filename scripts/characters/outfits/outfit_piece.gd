class_name OutfitPiece
extends Resource

## Una pieza de atuendo que reemplaza una parte de la malla del personaje.
##
## `slot` identifica la ranura (por ejemplo `torso` o `legs`) y `base_part` es
## el nombre del MeshInstance3D del cuerpo que se oculta. La pieza se puede
## volver a exportar desde Blender con otra escala/orientacion: el
## `CharacterOutfit` la transforma al espacio del esqueleto antes de asignarle
## los pesos.

@export var slot: StringName = &""
## Nombre del MeshInstance3D base que se oculta (por ejemplo `torso`).
@export var base_part: StringName = &""
## Escena de la pieza (GLB o escena con un MeshInstance3D).
@export var scene: PackedScene
