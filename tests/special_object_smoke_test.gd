extends SceneTree

## Prueba de objetos especiales: escritorio + silla de escritorio + sillas de
## pacientes al otro lado. La receta solo se forma con al menos una pieza client.
## Ejecutar:
##   Godot --headless --path . --script res://tests/special_object_smoke_test.gd

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
	_check(floor_item != null, "carga el suelo")
	_check(desk != null and chair != null and patients != null,
		"carga escritorio, silla y sillas de pacientes")
	_check(chair != null and chair.id == &"furniture_chair_desktop_01",
		"la silla de escritorio tiene su propio id")
	_check(patients != null and patients.id == &"furniture_patient_chairs_01",
		"las sillas de pacientes tienen su propio id")

	var work_def: SpecialObjectDef = null
	for def in controller.special_object_defs:
		if def.id == &"work_desk":
			work_def = def
	_check(work_def != null, "carga la receta 'work_desk'")
	_check(work_def != null and work_def.is_valid(), "la receta es valida")
	_check(work_def != null and work_def.requires_client(),
		"la receta exige una pieza client")
	_check(work_def != null
			and work_def.client_item_ids.has(&"furniture_patient_chairs_01"),
		"la pieza client son las sillas de pacientes")
	_check(work_def != null
			and work_def.client_item_ids.has(&"furniture_chair_desktop_01"),
		"una silla de escritorio suelta tambien cuenta como client")

	controller._on_build_item_selected(floor_item)
	_build_floors(controller)
	await process_frame

	# --- Combinacion: escritorio, operador y pacientes --------------------
	_check(controller.place_object_item(desk, Vector2i(5, 5), 0),
		"coloca el escritorio")
	_check(controller.get_special_object_count() == 0,
		"el escritorio solo no forma un objeto especial")
	# La silla mira al escritorio: frente -Z (rotacion 0).
	_check(controller.place_object_item(chair, Vector2i(5, 6), 0),
		"coloca la silla de escritorio mirando al escritorio")
	await process_frame
	_check(controller.get_special_object_count() == 0,
		"sin sillas de pacientes todavia no se forma")
	# Banca de pacientes al lado opuesto, pegada al escritorio y a lo ancho.
	_check(controller.place_object_item(patients, Vector2i(5, 4), 1),
		"coloca las sillas de pacientes al otro lado")
	await process_frame

	_check(controller.get_special_object_count() == 1,
		"escritorio + operador + pacientes forman el objeto especial")
	var special := controller.get_special_object_at(Vector2i(5, 6))
	_check(special != null, "la silla pertenece al objeto especial")
	_check(controller.get_special_object_at(Vector2i(5, 5)) == special,
		"el escritorio pertenece al mismo objeto especial")
	_check(controller.get_special_object_at(Vector2i(5, 4)) == special,
		"las sillas de pacientes pertenecen al mismo objeto especial")
	_check(special != null and special.get_special_id() == &"work_desk",
		"el objeto especial es 'work_desk'")
	_check(special != null and special.get_display_name() == "Escritorio de trabajo",
		"el nombre visible es 'Escritorio de trabajo'")
	_check(special != null and special.has_affordance(&"work"),
		"el objeto especial anuncia la affordance 'work'")
	_check(special != null and special.has_affordance(&"sit"),
		"el objeto especial anuncia 'sit' para los pacientes")
	_check(special != null and special.get_parts().size() == 3,
		"agrupa escritorio, operador y sillas de pacientes")
	_check(special != null and special.get_slot_count() == 4,
		"expone 1 slot de operador y 3 de pacientes")
	_check(special != null and special.find_free_slot(&"work") == 0,
		"el operador usa el primer slot")
	_check(special != null and special.find_free_slot(&"sit") >= 1,
		"los pacientes usan slots separados del operador")

	var chair_piece := controller.get_object_at(Vector2i(5, 6)) as SmartObject
	var desk_piece := controller.get_object_at(Vector2i(5, 5)) as SmartObject
	var patient_piece := controller.get_object_at(Vector2i(5, 4)) as SmartObject
	_check(chair_piece != null and desk_piece != null and patient_piece != null,
		"las tres piezas siguen existiendo en la escena")
	_check(chair_piece != null and not SmartObjectRegistry.get_objects().has(chair_piece),
		"la silla del operador no se registra por separado")
	_check(desk_piece != null and not SmartObjectRegistry.get_objects().has(desk_piece),
		"el escritorio no se registra por separado")
	_check(patient_piece != null
			and not SmartObjectRegistry.get_objects().has(patient_piece),
		"las sillas de pacientes no se registran por separado")
	_check(SmartObjectRegistry.get_count() == 1,
		"solo el objeto especial queda registrado para la IA")

	if special != null and chair_piece != null:
		var chair_slot := chair_piece.get_use_position(0)
		_check(special.get_use_position(0).distance_to(chair_slot) < 0.001,
			"el slot 0 se copia del asiento del operador")
	if special != null and patient_piece != null:
		var patient_slot := patient_piece.get_use_position(0)
		_check(special.get_use_position(1).distance_to(patient_slot) < 0.001,
			"el slot 1 se copia del primer asiento de pacientes")
	if special != null:
		var slot := special.reserve(&"work", 11)
		_check(slot == 0, "un agente reserva 'work' en el slot del operador")
		special.release_agent(11)
		var sit_slot := special.reserve(&"sit", 12)
		_check(sit_slot >= 1, "un paciente reserva un asiento de pacientes")
		special.release_agent(12)

	# --- Una silla que mira al lado opuesto se auto-orienta --------------
	_check(controller.place_object_item(desk, Vector2i(7, 3), 0),
		"coloca un segundo escritorio")
	# Frente +Z (rotacion 2), alejandose del escritorio: debe auto-orientarse.
	_check(controller.place_object_item(chair, Vector2i(7, 4), 2),
		"coloca una silla que mira al lado opuesto")
	_check(controller.place_object_item(patients, Vector2i(7, 2), 1),
		"coloca pacientes del segundo escritorio")
	await process_frame
	_check(controller.get_special_object_count() == 2,
		"la silla se auto-orienta y forma un segundo conjunto")
	var special2 := controller.get_special_object_at(Vector2i(7, 4))
	_check(special2 != null, "el segundo objeto especial existe")
	var chair2 := controller.get_object_at(Vector2i(7, 4)) as SmartObject
	_check(chair2 != null and chair2.object_rotation_steps == 0,
		"la silla se gira para mirar al escritorio")
	_check(SmartObjectRegistry.get_count() == 2,
		"solo los dos conjuntos quedan registrados para la IA")

	# --- Separar al borrar una pieza --------------------------------------
	_check(controller.erase_at(Vector2i(5, 6), Vector3i.ZERO,
		BuildController.EraseKind.OBJECT), "borra la silla del primer conjunto")
	await process_frame
	_check(controller.get_special_object_count() == 1,
		"borrar una pieza disuelve solo su objeto especial")
	_check(controller.get_special_object_at(Vector2i(5, 5)) == null,
		"el primer escritorio ya no pertenece a un objeto especial")
	_check(controller.get_special_object_at(Vector2i(7, 4)) == special2,
		"el segundo conjunto sigue activo")
	var restored_desk := controller.get_object_at(Vector2i(5, 5)) as SmartObject
	var restored_patients := controller.get_object_at(Vector2i(5, 4)) as SmartObject
	_check(restored_desk != null, "el primer escritorio sigue colocado")
	_check(restored_desk != null and SmartObjectRegistry.get_objects().has(restored_desk),
		"el primer escritorio vuelve a registrarse como SmartObject normal")
	_check(restored_desk != null and restored_desk.has_affordance(&"use"),
		"el escritorio recupera su affordance 'use'")
	_check(restored_patients != null, "las sillas de pacientes siguen colocadas")
	_check(restored_patients != null
			and SmartObjectRegistry.get_objects().has(restored_patients),
		"las sillas de pacientes vuelven a registrarse")
	_check(SmartObjectRegistry.get_count() == 3,
		"el registry queda con el segundo conjunto y las dos piezas restauradas")

	# --- Combinacion: silla y pacientes primero, escritorio despues -------
	controller.clear_all()
	await process_frame
	SmartObjectRegistry.clear()
	controller._on_build_item_selected(floor_item)
	_build_floors(controller)
	await process_frame

	_check(controller.place_object_item(chair, Vector2i(5, 6), 0),
		"coloca la silla primero")
	_check(controller.place_object_item(patients, Vector2i(5, 4), 1),
		"coloca los pacientes primero")
	_check(controller.get_special_object_count() == 0,
		"sin escritorio todavia no se forma")
	_check(controller.place_object_item(desk, Vector2i(5, 5), 0),
		"coloca el escritorio despues")
	await process_frame
	_check(controller.get_special_object_count() == 1,
		"el escritorio completa la receta al colocarse despues")

	if _failures == 0:
		print("SPECIAL_OBJECT_SMOKE_TEST_OK")
		quit(0)
	else:
		printerr("SPECIAL_OBJECT_SMOKE_TEST_FAILED: %d fallo(s)" % _failures)
		quit(1)


func _build_floors(controller: BuildController) -> void:
	for x in range(4, 10):
		for z in range(2, 8):
			controller.place_floor(Vector2i(x, z))


func _check(condition: bool, message: String) -> void:
	if condition:
		print("OK: ", message)
	else:
		_failures += 1
		printerr("FALLO: ", message)
