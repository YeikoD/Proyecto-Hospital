extends SceneTree

## Prueba del FSM de ruta esperando turno:
## - con el consultorio ocupado, el NPC de ruta se sienta en la sala de espera;
## - al liberarse el consultorio, pasa a consultar.

const Consult := preload("res://scripts/characters/npc/npc_consult.gd")

var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	SmartObjectRegistry.clear()
	var system := (load("res://scripts/systems/build/build_system.tscn") as PackedScene) \
		.instantiate() as Node3D
	get_root().add_child(system)
	current_scene = system
	await process_frame
	await process_frame

	var controller := system.get_node("BuildController") as BuildController
	controller.clear_all()
	var floor_item := load("res://data/build_items/construccion/floor_basic.tres") as BuildItem
	var desk_item := load("res://data/build_items/muebles/furniture_desktop.tres") as BuildItem
	var chair_item := load("res://data/build_items/muebles/furniture_chair_desktop.tres") as BuildItem

	controller._on_build_item_selected(floor_item)
	for x in range(0, 16):
		for z in range(0, 16):
			controller.place_floor(Vector2i(x, z))
	await process_frame

	controller.place_object_item(desk_item, Vector2i(6, 5), 0)
	controller.place_object_item(chair_item, Vector2i(6, 4), 0)
	controller.place_object_item(chair_item, Vector2i(9, 6), 0)
	controller.place_object_item(chair_item, Vector2i(6, 10), 0)
	await process_frame

	var special := controller.get_special_object_at(Vector2i(6, 5))
	var consult_chair := controller.get_object_at(Vector2i(9, 6))
	var waiting_chair := controller.get_object_at(Vector2i(6, 10))
	_check(special != null and consult_chair != null and waiting_chair != null,
		"consulta, espera y escritorio existen")

	var consult_cells: Array[Vector2i] = []
	for x in range(4, 11):
		for z in range(2, 8):
			consult_cells.append(Vector2i(x, z))
	controller.paint_zone(consult_cells, &"consult")
	var waiting_cells: Array[Vector2i] = []
	for x in range(4, 11):
		for z in range(9, 13):
			waiting_cells.append(Vector2i(x, z))
	controller.paint_zone(waiting_cells, &"waiting")

	await _bake_nav(system)
	await process_frame

	var doctor := _spawn(system, controller, Vector2i(8, 5))
	doctor.add_to_group(&"doctor_npcs")
	var doctor_brain := doctor.get_node("NpcBrain") as NpcBrain
	doctor_brain.needs = {&"work": 1.0}
	doctor_brain.need_growth = {&"work": 0.0}
	doctor_brain.need_affordances = {&"work": &"work"}
	doctor_brain.need_threshold = 0.0
	doctor_brain.search_radius = 0.0
	doctor_brain.consult_enabled = false
	doctor_brain.set_enabled(true)
	var doctor_deadline := Time.get_ticks_msec() + 20000
	while doctor_brain.get_state() != NpcBrain.State.USE \
			and Time.get_ticks_msec() < doctor_deadline:
		await process_frame
	_check(doctor_brain.get_state() == NpcBrain.State.USE,
		"el medico esta trabajando")

	# Paciente que ocupa el consultorio.
	var patient := _spawn(system, controller, Vector2i(10, 5))
	var patient_brain := patient.get_node("NpcBrain") as NpcBrain
	patient_brain.set_enabled(true)
	var patient_deadline := Time.get_ticks_msec() + 25000
	while patient_brain.get_current_object() != consult_chair \
			and Time.get_ticks_msec() < patient_deadline:
		await process_frame
	_check(patient_brain.get_current_object() == consult_chair,
		"el consultorio esta ocupado")

	# NPC de ruta: debe esperar sentado en la sala de espera.
	var target := Node3D.new()
	system.add_child(target)
	target.global_position = controller.grid.cell_center(Vector2i(13, 13))
	var routed := _spawn(system, controller, Vector2i(10, 8))
	var routed_brain := routed.get_node("NpcBrain") as NpcBrain
	routed_brain.consult_enabled = false
	var route := NpcRouteFSM.new()
	route.target_node = target
	route.loop_route = false
	route.consult_willingness = 1.0
	route.consult_chance = 1.0
	route.consult_radius = 0.0
	route.smart_object_chance = 0.0
	routed.add_child(route)

	var wait_deadline := Time.get_ticks_msec() + 25000
	while (route.get_state() != NpcRouteFSM.State.WAIT_CONSULT
			or routed_brain.get_current_object() != waiting_chair) \
			and Time.get_ticks_msec() < wait_deadline:
		await process_frame
	_check(route.get_state() == NpcRouteFSM.State.WAIT_CONSULT,
		"el NPC de ruta entra en espera de consulta")
	_check(routed_brain.get_current_object() == waiting_chair,
		"el NPC de ruta espera sentado en la sala de espera")

	# Se libera el consultorio: pasa a consultar.
	patient_brain.set_enabled(false)
	var consult_deadline := Time.get_ticks_msec() + 15000
	while routed_brain.get_current_object() != consult_chair \
			and Time.get_ticks_msec() < consult_deadline:
		await process_frame
	_check(routed_brain.get_current_object() == consult_chair,
		"al liberarse el consultorio, el NPC de ruta pasa a consultar")

	_finish()


func _spawn(system: Node3D, controller: BuildController, cell: Vector2i) -> NpcAgent:
	var npc := (load("res://scripts/characters/npc/npc.tscn") as PackedScene) \
		.instantiate() as NpcAgent
	system.add_child(npc)
	npc.global_position = controller.grid.cell_center(cell)
	return npc


func _bake_nav(system: Node3D) -> void:
	var nav := system.get_node("BuildNavigation") as BuildNavigation
	if not nav.is_baking():
		nav.bake_now()
	await nav.navigation_baked
	var map := system.get_world_3d().navigation_map
	var deadline := Time.get_ticks_msec() + 5000
	while NavigationServer3D.map_get_iteration_id(map) == 0 \
			and Time.get_ticks_msec() < deadline:
		NavigationServer3D.map_force_update(map)
		await physics_frame
	for i in 6:
		await physics_frame
	NavigationServer3D.map_force_update(map)
	await physics_frame


func _check(condition: bool, message: String) -> void:
	if condition:
		print("OK: ", message)
	else:
		_failures += 1
		printerr("FALLO: ", message)


func _finish() -> void:
	if _failures == 0:
		print("CONSULT_ROUTE_WAIT_OK")
		quit(0)
	else:
		printerr("CONSULT_ROUTE_WAIT_FAILED: ", _failures)
		quit(1)
