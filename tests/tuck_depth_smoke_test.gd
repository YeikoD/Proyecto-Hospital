extends SceneTree

## Prueba del "un paso mas" de acople: el cursor puede apuntar al centro de la
## celda del escritorio y la silla se mete hasta quedar medio debajo, sin que el
## ancla quede dentro de la base. Reproduce el layout guardado en map1.
## Ejecutar:
##   Godot --headless --path . --script res://tests/tuck_depth_smoke_test.gd

var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	SmartObjectRegistry.clear()
	var demo := (load("res://scenes/demos/nav_demo.tscn") as PackedScene).instantiate() as Node3D
	get_root().add_child(demo)
	await process_frame
	var controller: BuildController = demo.get_node("BuildSystem/BuildController")
	controller.enter_build_mode()
	await process_frame
	controller.clear_all()
	await process_frame
	SmartObjectRegistry.clear()

	var floor_item := load("res://data/build_items/construccion/floor_basic.tres") as BuildItem
	var desk := load("res://data/build_items/muebles/furniture_desktop.tres") as BuildItem
	var chair := load("res://data/build_items/muebles/furniture_chair_desktop.tres") as BuildItem
	var patients := load("res://data/build_items/muebles/furniture_patient_chairs.tres") as BuildItem
	controller._on_build_item_selected(floor_item)
	for x in range(3, 12):
		for z in range(18, 26):
			controller.place_floor(Vector2i(x, z))
	await process_frame

	# Layout exacto del save: escritorio girado y desplazado medio metro.
	var desk_cell := Vector2i(7, 21)
	_check(controller.place_object_item(
		desk, desk_cell, 3, Vector3(0.5, 0.0, -0.5)),
		"coloca el escritorio girado y desplazado")

	# El cursor apunta al centro de la celda del escritorio (offset cero). Antes
	# se rechazaba y la silla caia medio metro atras.
	controller._selected_object_item = chair
	controller._object_rotation = 3
	controller._hover_cell = desk_cell
	var hover := controller._valid_hover_offset(
		controller.grid.cell_center(desk_cell))
	_check(hover.is_equal_approx(Vector3.ZERO),
		"el snap se queda en la celda del escritorio")
	_check(controller._can_place_object(desk_cell, chair, 3, Vector3.ZERO),
		"la silla se puede meter un paso mas desde la celda del escritorio")
	_check(controller.place_object_item(chair, desk_cell, 3, Vector3.ZERO),
		"la silla se coloca apuntando al centro del escritorio")

	var placed := controller.get_object_at(Vector2i(6, 21))
	_check(placed != null and placed.item_id == chair.id,
		"el ancla de la silla se corre fuera de la base")
	if placed != null:
		_check(placed.cell == Vector2i(6, 21),
			"el ancla queda en la celda libre de al lado")
		_check(is_equal_approx(placed.sub_offset.x, 1.0),
			"el sub-offset compensa la celda corrida")
		var desk_piece := controller.get_object_at(desk_cell)
		_check(desk_piece != null and desk_piece.item_id == desk.id,
			"el escritorio conserva su celda ancla")
		var gap := placed.global_position.x - (desk_piece.global_position.x - 0.5)
		_check(is_equal_approx(gap, 0.0),
			"la silla queda justo en el borde del escritorio, medio debajo")

	# Con la banca de pacientes del lado opuesto se forma el conjunto.
	_check(controller.place_object_item(patients, Vector2i(9, 21), 3),
		"coloca la banca de pacientes del lado opuesto")
	await process_frame
	_check(controller.get_special_object_count() == 1,
		"el conjunto se forma con la silla metida un paso mas")
	var special := controller.get_special_object_at(desk_cell)
	_check(special != null and special.get_parts().size() == 3,
		"agrupa escritorio, operador y banca")
	if special != null:
		_check(special.find_free_slot(&"work") == 0,
			"el operador queda reconocido del lado correcto")

	# --- Orden inverso: la silla con offset 1,0 primero -------------------
	# Al cargar el nivel las piezas pueden venir en cualquier orden. La silla
	# ocupa la celda compartida y despues el escritorio la reclama.
	controller.clear_all()
	await process_frame
	SmartObjectRegistry.clear()
	controller._on_build_item_selected(floor_item)
	for x in range(3, 12):
		for z in range(18, 26):
			controller.place_floor(Vector2i(x, z))
	await process_frame
	_check(controller.place_object_item(
		chair, Vector2i(6, 21), 3, Vector3(1.0, 0.0, 0.0)),
		"coloca primero la silla metida con offset completo")
	_check(controller.place_object_item(
		desk, desk_cell, 3, Vector3(0.5, 0.0, -0.5)),
		"el escritorio se coloca despues sobre la celda compartida")
	var chair_rev := controller.get_object_at(Vector2i(6, 21))
	var desk_rev := controller.get_object_at(desk_cell)
	_check(chair_rev != null and chair_rev.item_id == chair.id,
		"la silla conserva su ancla en el orden inverso")
	_check(desk_rev != null and desk_rev.item_id == desk.id,
		"el escritorio reclama la celda compartida en el orden inverso")

	if _failures == 0:
		print("TUCK_DEPTH_OK")
		quit(0)
	else:
		printerr("TUCK_DEPTH_FAILED: ", _failures)
		quit(1)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("OK: ", message)
	else:
		_failures += 1
		printerr("FALLO: ", message)
