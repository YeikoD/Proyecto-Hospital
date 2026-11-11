class_name SmartObjectDef
extends Resource

## Definición de datos de un objeto interactivo.
##
## Se referencia desde un BuildItem (`smart_object`) y se puede reutilizar en
## varios muebles: una misma definición "seat" sirve para sillas, bancos, etc.

## Identificador de la definición.
@export var id: StringName = &""

## Acciones que el objeto anuncia a la IA.
@export var affordances: Array[AffordanceDef] = []

## Si el collider del objeto debe recortar el NavMesh al hornear.
@export var blocks_navigation := true


func get_affordance(affordance_id: StringName) -> AffordanceDef:
	for affordance in affordances:
		if affordance != null and affordance.id == affordance_id:
			return affordance
	return null


func has_affordance(affordance_id: StringName) -> bool:
	return get_affordance(affordance_id) != null
