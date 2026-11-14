class_name OutfitDef
extends Resource

## Conjunto modular de piezas de ropa. Cada pieza reemplaza una parte del
## cuerpo por su ranura (`slot`).

@export var id: StringName = &""
@export var display_name: String = ""
## Piezas del conjunto. Se guardan como Resource para que el sistema funcione
## aunque el cache de clases globales todavia no conozca OutfitPiece.
@export var pieces: Array[Resource] = []


## Pieza de una ranura concreta, o null.
func get_piece(slot: StringName) -> Resource:
	for piece in pieces:
		if piece != null and StringName(piece.get("slot")) == slot:
			return piece
	return null


func has_slot(slot: StringName) -> bool:
	return get_piece(slot) != null
