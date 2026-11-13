class_name SpecialObjectDef
extends Resource

## Receta de un objeto especial: dos BuildItems que, al estar juntos y
## orientados, forman una sola entidad interactiva.
##
## El controlador carga todas las recetas de `res://data/special_objects/` y,
## cada vez que coloca un objeto, comprueba si puede formar una. La pieza
## combinada conserva sus modelos y colliders; lo que cambia es que los
## SmartObjects individuales se suspenden y se registra un SmartObject nuevo
## para el conjunto.

## Identificador unico de la receta.
@export var id: StringName = &""

## Nombre visible del objeto resultante (por ejemplo "Escritorio de trabajo").
@export var display_name: String = ""

@export_group("Piezas")
## Item que actua como base o anfitrion (por ejemplo el escritorio).
@export var base_item_id: StringName = &""
## Item que se acopla a la base (por ejemplo la silla de escritorio).
@export var part_item_id: StringName = &""
## Piezas adicionales que deben estar en el lado opuesto de la base (por
## ejemplo, las sillas de pacientes o sillas sueltas). Vacio = no se exige.
@export var client_item_ids: Array[StringName] = []

@export_group("Resultado")
## Definicion SmartObject del objeto combinado: affordances, duracion, etc.
@export var smart_object: SmartObjectDef
## Pieza que aporta el punto de uso: "part" (la silla) o "base" (el escritorio).
@export_enum("part", "base") var slot_source := "part"
## Indice del slot que se copia de esa pieza.
@export var slot_index := 0
## Etiqueta del slot del operador (por ejemplo "work").
@export var part_slot_tag: StringName = &"work"
## Etiqueta de los slots de las piezas client (por ejemplo "seat").
@export var client_slot_tag: StringName = &"seat"

@export_group("Reglas")
## Lado local de la base donde va el operador. `(0, -1)` = frente/sur con la
## base sin rotar. `(0, 0)` = sin restriccion.
@export var operator_side := Vector2i(0, -1)
## La pieza acoplada debe mirar hacia la base para combinarse.
@export var require_facing := true
## Al formarse el conjunto, orienta automaticamente la pieza acoplada hacia la
## base (solo piezas de 1x1). Asi el fantasma puede colocarse sin pelear con la
## rotacion y la silla queda mirando al escritorio.
@export var snap_part_rotation := true
## Al borrar una pieza se borra tambien el resto del objeto especial. Si es
## false, al borrar una pieza la otra vuelve a comportarse como objeto normal.
@export var remove_together := false
## Separacion maxima entre las huellas para considerar que se tocan (metros).
@export_range(0.0, 0.5, 0.01) var max_gap := 0.08
## Producto punto minimo entre el frente de la pieza y la direccion a la base.
## `0.7` equivale a un cono de unos 45 grados.
@export_range(-1.0, 1.0, 0.01) var facing_dot := 0.7

@export_group("Reglas del cliente")
## Cantidad minima de piezas client que debe haber para formar el conjunto.
@export var client_min_count := 1
## Cantidad maxima de piezas client que se integran. `0` = sin limite.
@export var client_max_count := 1
## Celdas vacias entre la base y el cliente. `1` = una grilla mas atras.
@export_range(0, 4, 1) var client_gap := 1
## Tolerancia lateral, en celdas, para aceptar clientes a los lados.
@export_range(0.0, 3.0, 0.1) var client_lateral_tolerance := 0.5


func is_valid() -> bool:
	if id == &"" or base_item_id == &"" or part_item_id == &"" \
			or smart_object == null:
		return false
	if not client_item_ids.is_empty() and client_min_count < 1:
		return false
	return true


func requires_client() -> bool:
	return not client_item_ids.is_empty() and client_min_count > 0


func is_client_item(item_id: StringName) -> bool:
	return client_item_ids.has(item_id)
