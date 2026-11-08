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

## Archivo de mapa (.map/.vmf) de FuncGodot que se construirá como pieza.
@export_file("*.map", "*.vmf") var map_file: String = ""

## Huella en celdas (para futuras piezas multi-celda).
@export var footprint: Vector2i = Vector2i(1, 1)

## Si admite rotación al colocar.
@export var can_rotate: bool = false

## Texto libre para el diseñador (notas, coste, etc.).
@export_multiline var notes: String = ""


func is_placeable_now() -> bool:
	# Por ahora el motor de colocación soporta suelo y pared.
	var has_source := scene != null or map_file != ""
	return object_type in ["floor", "wall", "suelo", "pared"] and has_source


func normalized_category() -> String:
	return category.strip_edges().to_lower()


func normalized_subcategory() -> String:
	return subcategory.strip_edges().to_lower()