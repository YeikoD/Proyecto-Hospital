extends SceneTree

## Prueba de ampliacion de un Escritorio de trabajo ya formado: se puede agregar
## otra silla del lado de los pacientes aunque quede medio metro metida hacia el
## escritorio y comparta celdas con el conjunto existente.
## Ejecutar:
##   Godot --headless --path . --script res://tests/chair_extension_smoke_test.gd

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
	controller._on_build_item_selected(floor_item)
	_build_floors(controller)
	await process_frame

	# Escritorio con el operador al sur (+Z) y dos sillas de pacientes al norte
	# (-Z), las dos metidas medio metro hacia el escritorio.
	var desk_cell := Vector2i(5, 5)
	var tuck := Vector3(0.0, 0.0, 0.5)
	_check(controller.place_object_item(desk, desk_cell, 0), "coloca el escritorio")
	_check(controller.place_object_item(chair, Vector2i(5, 6), 2),
		"coloca el operador")
	_check(controller.place_object_item(chair, Vector2i(5, 4), 0, tuck),
		"coloca la primera silla de pacientes metida medio metro")
	await process_frame
	_check(controller.get_special_object_count() == 1,
		"se forma el conjunto con la primera silla")
	var first := controller.get_special_object_at(Vector2i(5, 6))
	_check(first != null and first.get_parts().size() == 3,
		"el conjunto agrupa escritorio, operador y silla")

	# La segunda silla va al lado de la primera, con el mismo medio metro.
	var next_cell := Vector2i(6, 4)
	_check(controller._can_place_object(next_cell, chair, 0, tuck),
		"la segunda silla metida medio metro se considera valida")
	_check(controller.place_object_item(chair, next_cell, 0, tuck),
		"la segunda silla se coloca al lado de la primera")
	await process_frame
	_check(controller.get_special_object_count() == 1,
		"el conjunto se rehace con la segunda silla")
	var second := controller.get_special_object_at(Vector2i(5, 6))
	_check(second != null and second.get_parts().size() == 4,
		"el conjunto agrupa escritorio, operador y dos sillas")
	if second != null:
		_check(second.get_slot_count() == 3,
			"expone 1 slot de operador y 2 de pacientes")
		_check(second.find_free_slot(&"work") == 0,
			"el operador conserva su slot")
		var s1 := second.reserve(&"sit", 41)
		var s2 := second.reserve(&"sit", 42)
		_check(s1 >= 1 and s2 >= 1 and s1 != s2,
			"las dos sillas dan asientos distintos")

	# Una silla fuera del lado de los pacientes tambien se puede acomodar
	# contra el escritorio: queda suelta y no cambia el conjunto.
	var guest_cell := Vector2i(6, 6)
	var guest_tuck := Vector3(0.0, 0.0, -0.5)
	_check(controller._can_place_object(guest_cell, chair, 0, guest_tuck),
		"una silla fuera del lado de pacientes tambien se puede acomodar")
	_check(controller.place_object_item(chair, guest_cell, 0, guest_tuck),
		"la silla se coloca como mueble suelto")
	await process_frame
	var after_guest := controller.get_special_object_at(Vector2i(5, 6))
	_check(after_guest != null and after_guest.get_parts().size() == 4,
		"la silla suelta no entra al conjunto")
	_check(controller.erase_at(guest_cell, Vector3i.ZERO,
		BuildController.EraseKind.OBJECT), "borra la silla suelta")
	await process_frame
	_check(controller.get_special_object_at(Vector2i(5, 6)) != null,
		"el conjunto sobrevive al borrar la silla suelta")

	# La segunda silla debe existir y poder borrarse sin romper el conjunto.
	_check(controller.get_object_at(next_cell) != null,
		"la celda ancla de la segunda silla le pertenece")
	_check(controller.erase_at(next_cell, Vector3i.ZERO,
		BuildController.EraseKind.OBJECT), "borra la segunda silla")
	await process_frame
	_check(controller.get_object_at(Vector2i(5, 4)) != null,
		"la primera silla sigue colocada")
	_check(controller.get_object_at(desk_cell) != null,
		"el escritorio sigue colocado")

	if _failures == 0:
		print("CHAIR_EXTENSION_OK")
		quit(0)
	else:
		printerr("CHAIR_EXTENSION_FAILED: ", _failures)
		quit(1)


func _build_floors(controller: BuildController) -> void:
	for x in range(3, 10):
		for z in range(2, 9):
			controller.place_floor(Vector2i(x, z))


func _check(condition: bool, message: String) -> void:
	if condition:
		print("OK: ", message)
	else:
		_failures += 1
		printerr("FALLO: ", message)
