extends SceneTree

## Prueba del requisito de sillas de pacientes: el Escritorio de trabajo solo
## se forma con al menos una pieza client en el lado opuesto, y el conjunto
## expone slots de operador y de pacientes.
## Ejecutar:
##   Godot --headless --path . --script res://tests/patient_desk_smoke_test.gd

var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	SmartObjectRegistry.clear()
	var demo := (load("res://scenes/demos/nav_demo.tscn") as PackedScene).instantiate() as Node3D
	get_root().add_child(demo)
	await process_frame

	var controller: BuildController = demo.get_node("BuildSystem/BuildController")
	var desk := load("res://data/build_items/muebles/furniture_desktop.tres") as BuildItem
	var chair := load("res://data/build_items/muebles/furniture_chair_desktop.tres") as BuildItem
	var patients := load("res://data/build_items/muebles/furniture_patient_chairs.tres") as BuildItem
	_check(desk != null and chair != null and patients != null,
		"carga escritorio, silla y sillas de pacientes")

	_check(controller.place_object_item(desk, Vector2i(6, 5), 0), "coloca el escritorio")
	_check(controller.place_object_item(chair, Vector2i(6, 4), 0),
		"coloca la silla del operador")
	await process_frame
	_check(controller.get_special_object_count() == 1,
		"escritorio + operador ya forman el objeto especial")

	_check(controller.place_object_item(patients, Vector2i(6, 6), 1),
		"coloca las sillas de pacientes al otro lado")
	await process_frame
	_check(controller.get_special_object_count() == 1,
		"con la silla de pacientes se integra la banca")
	var special := controller.get_special_object_at(Vector2i(6, 4))
	_check(special != null, "el objeto especial existe")
	if special != null:
		_check(special.get_parts().size() == 3,
			"el objeto especial agrupa escritorio, operador y pacientes")
		_check(special.has_affordance(&"work"), "ofrece 'work'")
		_check(special.has_affordance(&"sit"), "ofrece 'sit' para pacientes")
		_check(special.get_slot_count() == 4,
			"tiene 1 slot de operador y 3 de pacientes")
		var work_slot := special.find_free_slot(&"work")
		var sit_slot := special.find_free_slot(&"sit")
		_check(work_slot == 0, "el operador usa el slot 0")
		_check(sit_slot >= 1, "los pacientes usan slots separados")
		var slot := special.reserve(&"sit", 21)
		_check(slot >= 1, "un paciente reserva un asiento")
		special.release_agent(21)

	_check(controller.erase_at(Vector2i(6, 6), Vector3i.ZERO,
		BuildController.EraseKind.OBJECT), "borra las sillas de pacientes")
	await process_frame
	_check(controller.get_special_object_count() == 1,
		"sin pacientes el conjunto sigue con escritorio + operador")
	var without_clients := controller.get_special_object_at(Vector2i(6, 4))
	_check(without_clients != null and without_clients.get_parts().size() == 2,
		"el conjunto queda solo con escritorio y operador")
	_check(controller.get_object_at(Vector2i(6, 5)) != null,
		"el escritorio sigue colocado")
	_check(controller.get_object_at(Vector2i(6, 4)) != null,
		"la silla del operador sigue colocada")

	# --- Dos sillas sueltas del lado de pacientes -------------------------
	# Usa el mismo escritorio y operador que quedaron colocados. Las sillas de
	# escritorio tambien cuentan como piezas client.
	var chair1 := controller.place_object_item(chair, Vector2i(6, 6), 0)
	var chair2 := controller.place_object_item(chair, Vector2i(7, 6), 0)
	_check(chair1, "coloca la primera silla de paciente")
	_check(chair2, "coloca la segunda silla de paciente")
	await process_frame
	_check(controller.get_special_object_count() == 1,
		"las dos sillas sueltas forman un solo conjunto")
	var two := controller.get_special_object_at(Vector2i(6, 4))
	_check(two != null, "el conjunto con dos sillas existe")
	if two != null:
		_check(two.get_parts().size() == 4,
			"agrupa escritorio, operador y dos sillas")
		_check(two.get_slot_count() == 3,
			"tiene 1 slot de operador y 2 de pacientes")
		_check(two.find_free_slot(&"work") == 0,
			"el operador conserva su slot")
		var s1 := two.reserve(&"sit", 31)
		var s2 := two.reserve(&"sit", 32)
		_check(s1 >= 1 and s2 >= 1 and s1 != s2,
			"los dos pacientes tienen asientos distintos")
		two.release_agent(31)
		two.release_agent(32)
	_check(SmartObjectRegistry.get_count() == 1,
		"solo el conjunto queda registrado")

	# --- Operador primero, luego la banca de pacientes al otro lado ---------
	_check(controller.place_object_item(desk, Vector2i(8, 5), 0),
		"coloca otro escritorio")
	_check(controller.place_object_item(chair, Vector2i(8, 6), 0),
		"coloca el operador del segundo escritorio")
	await process_frame
	_check(controller.get_special_object_count() == 2,
		"escritorio + operador forman el segundo conjunto")
	_check(controller.place_object_item(patients, Vector2i(8, 4), 1),
		"coloca la banca de pacientes al otro lado")
	await process_frame
	var late := controller.get_special_object_at(Vector2i(8, 5))
	_check(late != null, "el segundo conjunto con pacientes existe")
	if late != null:
		_check(late.get_parts().size() == 3,
			"agrupa escritorio, operador y banca")
		_check(late.get_slot_count() == 4,
			"tiene 1 slot de operador y 3 de pacientes")
		_check(late.find_free_slot(&"work") == 0,
			"el operador queda delante")
		_check(late.find_free_slot(&"sit") >= 1,
			"la banca queda como asiento de pacientes")

	# --- Escritorio girado: la banca define el lado del operador -----------
	# El escritorio mira hacia +X segun su rotacion, pero la banca de pacientes
	# esta de ese lado. El operador debe ir del lado opuesto igual.
	_check(controller.place_object_item(desk, Vector2i(8, 7), 1),
		"coloca un escritorio girado")
	_check(controller.place_object_item(patients, Vector2i(9, 7), 0),
		"coloca la banca del lado hacia donde mira el escritorio")
	_check(controller.place_object_item(chair, Vector2i(7, 7), 3),
		"coloca el operador del lado opuesto")
	await process_frame
	_check(controller.get_special_object_count() == 3,
		"el conjunto se forma con el escritorio girado")
	var rotated := controller.get_special_object_at(Vector2i(8, 7))
	_check(rotated != null, "el conjunto girado existe")
	if rotated != null:
		_check(rotated.get_parts().size() == 3,
			"agrupa escritorio, banca y operador")
		_check(rotated.find_free_slot(&"work") == 0,
			"el operador queda del lado opuesto a la banca")
		_check(rotated.find_free_slot(&"sit") >= 1,
			"la banca queda como asiento de pacientes")

	if _failures == 0:
		print("PATIENT_DESK_OK")
		quit(0)
	else:
		printerr("PATIENT_DESK_FAILED: ", _failures)
		quit(1)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("OK: ", message)
	else:
		_failures += 1
		printerr("FALLO: ", message)
