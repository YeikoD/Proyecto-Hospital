extends SceneTree

## Prueba de objetos especiales con celdas compartidas: el operador se acopla
## centrado en el borde frontal del escritorio (nunca dentro de su huella) y las
## piezas client pueden seguir compartiendo celdas medio metro.
## Ejecutar:
##   Godot --headless --path . --script res://tests/special_object_overlap_smoke_test.gd

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
	_build_floors(controller)
	await process_frame

	var chair_cell := Vector2i(5, 4)
	var desk_cell := Vector2i(5, 5)
	var patient_cell := Vector2i(5, 6)
	var overlap_offset := Vector3(0.0, 0.0, 0.5)
	# Acople esperado del operador: centrado en el lado largo (x = 6,0) y
	# apoyado contra el borde frontal (z = 5,0). El ancla (5,4) compensa con
	# medio metro en X.
	var dock_offset := Vector3(0.5, 0.0, 0.0)

	# --- Orden normal: escritorio primero, silla acoplada al frente ---------
	_check(controller.place_object_item(desk, desk_cell, 0),
		"coloca el escritorio")
	controller._selected_object_item = chair
	controller._object_rotation = 0
	controller._hover_cell = chair_cell
	var point := controller.grid.cell_center(chair_cell) + Vector3(0.0, 0.0, 0.49)
	var hover_offset := controller._valid_hover_offset(point)
	_check(hover_offset.is_equal_approx(dock_offset),
		"el snap centra la silla en el borde frontal del escritorio")
	_check(controller._hover_rotation == 2,
		"el fantasma gira la silla para mirar al escritorio")
	_check(controller._can_place_object(chair_cell, chair, 0, overlap_offset),
		"la silla se acopla al escritorio")
	_check(controller._can_place_object(chair_cell, chair, 2, overlap_offset),
		"la silla se puede colocar aunque todavia no mire al escritorio")
	_check(controller.place_object_item(chair, chair_cell, 0, overlap_offset),
		"la silla se coloca acoplada al borde frontal")
	await process_frame
	_check(controller.get_special_object_count() == 1,
		"escritorio + operador ya forman el conjunto")
	_check(controller.place_object_item(patients, patient_cell, 1),
		"coloca las sillas de pacientes al otro lado")
	await process_frame

	var chair_piece := controller.get_object_at(chair_cell)
	var desk_piece := controller.get_object_at(desk_cell)
	var patient_piece := controller.get_object_at(patient_cell)
	_check(chair_piece != null and chair_piece.item_id == chair.id,
		"la celda ancla sigue siendo de la silla")
	_check(desk_piece != null and desk_piece.item_id == desk.id,
		"la celda compartida sigue siendo del escritorio")
	_check(patient_piece != null and patient_piece.item_id == patients.id,
		"las sillas de pacientes quedan colocadas")
	_check(controller.get_object_count() == 3,
		"se cuentan las tres piezas fisicas")
	_check(controller.get_special_object_count() == 1,
		"se forma el objeto especial con la silla solapada")
	var special := controller.get_special_object_at(chair_cell)
	_check(special != null and special.get_special_id() == &"work_desk",
		"el objeto especial es work_desk")
	_check(special != null and special.get_parts().size() == 3,
		"el objeto especial referencia las tres piezas")
	_check(special != null and special.get_slot_count() == 4,
		"el conjunto expone 4 slots (operador + pacientes)")

	# --- Borrar la silla separa el conjunto -------------------------------
	_check(controller.erase_at(chair_cell, Vector3i.ZERO,
		BuildController.EraseKind.OBJECT), "borra la silla")
	await process_frame
	_check(controller.get_special_object_count() == 0,
		"el conjunto se disuelve al borrar la silla")
	var restored_desk := controller.get_object_at(desk_cell)
	var restored_patients := controller.get_object_at(patient_cell)
	_check(restored_desk != null and restored_desk.item_id == desk.id,
		"el escritorio sigue colocado en su celda")
	_check(restored_patients != null and restored_patients.item_id == patients.id,
		"las sillas de pacientes siguen colocadas")

	# --- Orden inverso: silla y pacientes primero, escritorio despues -----
	controller.clear_all()
	await process_frame
	SmartObjectRegistry.clear()
	controller._on_build_item_selected(floor_item)
	_build_floors(controller)
	await process_frame

	_check(controller.place_object_item(chair, chair_cell, 2, overlap_offset),
		"coloca primero la silla solapada mirando al lado opuesto")
	_check(controller.place_object_item(patients, patient_cell, 1),
		"coloca primero las sillas de pacientes")
	_check(controller.place_object_item(desk, desk_cell, 0),
		"el escritorio se coloca despues sobre la celda compartida")
	await process_frame
	_check(controller.get_special_object_count() == 1,
		"la receta se forma en el orden inverso")
	var chair_after := controller.get_object_at(chair_cell)
	var desk_after := controller.get_object_at(desk_cell)
	var patients_after := controller.get_object_at(patient_cell)
	_check(chair_after != null and chair_after.item_id == chair.id,
		"la silla conserva su celda ancla")
	_check(chair_after != null and chair_after.object_rotation_steps == 2,
		"la silla se auto-orienta hacia el escritorio")
	_check(desk_after != null and desk_after.item_id == desk.id,
		"el escritorio reclama la celda compartida")
	_check(patients_after != null and patients_after.item_id == patients.id,
		"las sillas de pacientes conservan su celda")

	# --- Cursor sobre la celda del escritorio -----------------------------
	# El cursor apunta al centro de la base; el operador se acopla al borde
	# frontal y su ancla se resuelve en la celda libre del lado de la silla.
	var cursor_cell := Vector2i(7, 5)
	var cursor_offset := Vector3(0.0, 0.0, 0.5)
	_check(controller.place_object_item(desk, cursor_cell, 0),
		"coloca un escritorio para el cursor sobre su celda")
	_check(controller._can_place_object(cursor_cell, chair, 0, cursor_offset),
		"la silla con el ancla bajo el escritorio se considera valida")
	_check(controller.place_object_item(chair, cursor_cell, 0, cursor_offset),
		"la silla se coloca partiendo de la celda del escritorio")
	_check(controller.get_object_at(Vector2i(7, 4)) != null,
		"el ancla se resuelve en la celda libre del lado de la silla")
	_check(controller.place_object_item(patients, Vector2i(7, 6), 1),
		"coloca la banca del lado opuesto")
	await process_frame
	_check(controller.get_special_object_count() == 2,
		"el conjunto se forma con el ancla corregida")

	if _failures == 0:
		print("SPECIAL_OVERLAP_OK")
		quit(0)
	else:
		printerr("SPECIAL_OVERLAP_FAILED: ", _failures)
		quit(1)


func _build_floors(controller: BuildController) -> void:
	for x in range(4, 9):
		for z in range(2, 8):
			controller.place_floor(Vector2i(x, z))


func _check(condition: bool, message: String) -> void:
	if condition:
		print("OK: ", message)
	else:
		_failures += 1
		printerr("FALLO: ", message)
