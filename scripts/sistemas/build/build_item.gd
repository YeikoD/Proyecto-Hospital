class_name BuildItem
extends Resource

## Dato de un item construible / collocable.
##
## El diseñador crea archivos `.tres` (Resource) con este script en
## `res://data/build_items/`. Al iniciar, el sistema los carga automáticamente
## y los muestra en el menú de construcción.

## Identificador único del item.
@export var id: StringName = &""

## Nombre visible en el menú.
@export var display_name: String = ""

## Pestaña principal: "construction", "objects", etc.
@export var category: String = "construction"

## Subpestaña: "floors", "walls", "openings", "furniture", etc.
@export var subcategory: String = "general"

## Tipo de objeto para el sistema de colocación:
## "floor", "wall", "ceiling", "opening", "furniture", "prop".
@export var object_type: String = "floor"

## Imagen de previsualización para la lista.
@export var preview: Texture2D

## Escena 3D del item (debe ser o contener un BuildPiece cuando sea construible).
@export var scene: PackedScene

@export_group("Esquinas (solo paredes)")
## Modelo de esquina para las L que giran a la izquierda. Si se deja vacío, el
## sistema busca `<muro>_IZQ.blend` junto al modelo de la pared.
@export var corner_left: PackedScene
## Modelo de esquina para las L que giran a la derecha. Si se deja vacío, el
## sistema busca `<muro>_DER.blend` junto al modelo de la pared.
@export var corner_right: PackedScene

## Archivo de mapa (.map/.vmf) de FuncGodot que se construirá como pieza.
@export_file("*.map", "*.vmf") var map_file: String = ""

@export_group("Smart Object")
## Definición de interacción del objeto (opcional). Si se asigna, la escena
## debe tener raíz SmartObject para que la IA pueda reservar sus slots.
@export var smart_object: SmartObjectDef

## Huella en celdas (para futuras piezas multi-celda).
@export var footprint: Vector2i = Vector2i(1, 1)

## Si admite rotación al colocar.
@export var can_rotate: bool = false

## Texto libre para el diseñador (notas, coste, etc.).
@export_multiline var notes: String = ""


func is_placeable_now() -> bool:
	# Tipos que el motor de colocación sabe instanciar en la grilla.
	var has_source := scene != null or map_file != ""
	return object_type in [
		"floor", "wall", "suelo", "pared",
		"furniture", "prop", "mueble", "objeto",
	] and has_source


func normalized_category() -> String:
	return category.strip_edges().to_lower()


func normalized_subcategory() -> String:
	return subcategory.strip_edges().to_lower()