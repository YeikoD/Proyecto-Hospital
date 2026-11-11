extends "res://scenes/demos/nav_demo.gd"

## Demo visual del sistema SmartObject.
##
## Reutiliza la construcción de habitaciones y NPCs de `nav_demo.gd`, coloca
## varias sillas y activa el cerebro de los NPC. Cada NPC reserva una silla
## libre, camina hasta ella, la usa unos segundos y la libera.

const CHAIR_ITEM := "res://data/build_items/muebles/furniture_chair.tres"


func _build_example() -> void:
	super()

	var controller := get_node_or_null(controller_path) as BuildController
	if controller == null:
		return

	var item := load(CHAIR_ITEM) as BuildItem
	if item == null:
		push_warning("SmartObjectDemo: no se pudo cargar la silla.")
		return

	# Una silla por habitación, lejos de la posición inicial de cada NPC.
	controller.place_object_item(item, Vector2i(5, 4), 0)
	controller.place_object_item(item, Vector2i(4, 7), 2)
	controller.place_object_item(item, Vector2i(9, 4), 0)
	controller.place_object_item(item, Vector2i(9, 7), 2)

	_enable_brains()


func _enable_brains() -> void:
	var npcs := get_node_or_null("NPCs")
	if npcs == null:
		return
	for child in npcs.get_children():
		if not (child is NpcAgent):
			continue
		var brain := child.get_node_or_null("NpcBrain") as NpcBrain
		if brain == null:
			continue
		# Necesidad ya urgente para que la demo arranque rápido.
		brain.needs = {"rest": randf_range(0.65, 1.0)}
		brain.need_growth = {"rest": 0.01}
		brain.set_enabled(true)
