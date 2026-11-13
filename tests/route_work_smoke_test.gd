extends SceneTree

## Prueba del selector de ruta: con un Escritorio de trabajo cerca, el
## NpcRouteFSM elige la affordance "work" y configura el cerebro del NPC.
## Ejecutar:
##   Godot --headless --path . --script res://tests/route_work_smoke_test.gd

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
	_check(controller.place_object_item(desk, Vector2i(6, 5), 0), "coloca el escritorio")
	_check(controller.place_object_item(chair, Vector2i(6, 6), 0), "coloca la silla")
	_check(controller.place_object_item(patients, Vector2i(6, 4), 1),
		"coloca las sillas de pacientes")
	await process_frame
	_check(controller.get_special_object_count() == 1, "se forma el escritorio de trabajo")

	var npc := demo.get_node("NPCs/NPC1") as NpcAgent
	var target := Node3D.new()
	demo.add_child(target)
	target.global_position = npc.global_position + Vector3(4, 0, 0)

	var route := NpcRouteFSM.new()
	route.target_node = target
	route.affordances = [&"work"]
	route.affordance = &"work"
	route.smart_object_chance = 1.0
	route.smart_object_radius = 50.0
	# Esta prueba aísla el desvío a `work`; el consultorio tiene sus pruebas.
	route.consult_chance = 0.0
	route.set_process(false)
	npc.add_child(route)

	# Un NPC normal no puede desviarse a la silla del operador.
	var normal_started := route._try_start_smart_object()
	_check(not normal_started,
		"un NPC normal no elige 'work' en la ruta")
	_check(route.get_state() == NpcRouteFSM.State.TRAVEL,
		"el NPC normal sigue la ruta sin ocupar el escritorio")

	# El medico si puede: la silla del operador es exclusiva de su grupo.
	npc.add_to_group(&"doctor_npcs")
	var started := route._try_start_smart_object()
	_check(started, "el medico detecta el escritorio de trabajo")
	_check(route.get_state() == NpcRouteFSM.State.USE_SMART_OBJECT,
		"la ruta entra en USE_SMART_OBJECT")
	_check(route._chosen_affordance == &"work",
		"la ruta elige la affordance 'work'")
	var brain := npc.get_node("NpcBrain") as NpcBrain
	_check(brain != null and brain.needs.has("work"),
		"el cerebro recibe la necesidad 'work'")
	_check(brain != null and brain.need_affordances.get("work") == &"work",
		"el cerebro busca la affordance 'work'")

	if _failures == 0:
		print("ROUTE_WORK_OK")
		quit(0)
	else:
		printerr("ROUTE_WORK_FAILED: ", _failures)
		quit(1)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("OK: ", message)
	else:
		_failures += 1
		printerr("FALLO: ", message)
