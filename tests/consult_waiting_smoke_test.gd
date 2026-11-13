extends SceneTree

## Prueba de la sala de espera:
## - con el consultorio ocupado, el paciente espera sentado;
## - si la silla de espera tambien esta ocupada, espera de pie;
## - cuando se libera el consultorio, el que espera pasa a consultar;
## - cuando se libera la silla de espera, el que estaba de pie se sienta.

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
	# Una sola silla de consultorio, separada del escritorio para que no se
	# integre al conjunto especial.
	controller.place_object_item(chair_item, Vector2i(9, 6), 0)
	# Una sola silla en la sala de espera.
	controller.place_object_item(chair_item, Vector2i(6, 10), 0)
	await process_frame

	var special := controller.get_special_object_at(Vector2i(6, 5))
	_check(special != null, "el escritorio de trabajo se forma")
	var consult_chair := controller.get_object_at(Vector2i(9, 6))
	var waiting_chair := controller.get_object_at(Vector2i(6, 10))
	_check(consult_chair != null and consult_chair.has_affordance(&"sit"),
		"hay una silla de consultorio")
	_check(waiting_chair != null and waiting_chair.has_affordance(&"sit"),
		"hay una silla de espera")

	var consult_cells: Array[Vector2i] = []
	for x in range(4, 11):
		for z in range(2, 8):
			consult_cells.append(Vector2i(x, z))
	controller.paint_zone(consult_cells, &"consult")
	var waiting_cells: Array[Vector2i] = []
	for x in range(4, 11):
		for z in range(9, 13):
			waiting_cells.append(Vector2i(x, z))
	var waiting_zone := controller.paint_zone(waiting_cells, &"waiting")
	_check(waiting_zone != &"", "pinta la zona de espera")
	_check(controller.get_zone_type_at_world(waiting_chair.global_position) == &"waiting",
		"la silla de espera queda dentro de la zona waiting")
	_check(controller.get_zone_type_at_world(consult_chair.global_position) == &"consult",
		"la silla de consultorio queda dentro de la zona consult")

	await _bake_nav(system)
	await process_frame

	# Medico trabajando.
	var doctor := _spawn_npc(system, controller, Vector2i(8, 5))
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

	# Paciente 1: consulta.
	var p1 := _spawn_npc(system, controller, Vector2i(10, 5))
	var b1 := p1.get_node("NpcBrain") as NpcBrain
	b1.set_enabled(true)
	var p1_deadline := Time.get_ticks_msec() + 25000
	while b1.get_current_object() != consult_chair \
			and Time.get_ticks_msec() < p1_deadline:
		await process_frame
	_check(b1.get_current_object() == consult_chair,
		"el primer paciente ocupa la silla de consultorio")

	# Paciente 2: espera sentado.
	var p2 := _spawn_npc(system, controller, Vector2i(10, 8))
	var b2 := p2.get_node("NpcBrain") as NpcBrain
	b2.set_enabled(true)
	var p2_deadline := Time.get_ticks_msec() + 25000
	while b2.get_current_object() != waiting_chair \
			and Time.get_ticks_msec() < p2_deadline:
		await process_frame
	_check(b2.get_current_object() == waiting_chair,
		"el segundo paciente espera sentado en la sala de espera")

	# Paciente 3: espera de pie (consultorio y silla de espera ocupados).
	var p3 := _spawn_npc(system, controller, Vector2i(10, 9))
	var b3 := p3.get_node("NpcBrain") as NpcBrain
	b3.set_enabled(true)
	var p3_deadline := Time.get_ticks_msec() + 20000
	while b3.get_state() != NpcBrain.State.WAIT \
			and Time.get_ticks_msec() < p3_deadline:
		await process_frame
	_check(b3.get_state() == NpcBrain.State.WAIT,
		"el tercer paciente espera de pie")
	_check(controller.get_zone_type_at_world(p3.global_position) == &"waiting",
		"el tercer paciente espera dentro de la zona waiting")

	# Se libera el consultorio: el que esperaba sentado pasa a consultar.
	# Pausamos al que espera de pie para que el turno sea determinista.
	b3.set_enabled(false)
	b1.set_enabled(false)
	var p2_consult_deadline := Time.get_ticks_msec() + 15000
	while b2.get_current_object() != consult_chair \
			and Time.get_ticks_msec() < p2_consult_deadline:
		await process_frame
	_check(b2.get_current_object() == consult_chair,
		"al liberarse el consultorio, el que esperaba pasa a consultar")

	# Al quedar libre la silla de espera, el que estaba de pie se sienta.
	b3.set_enabled(true)
	var p3_seat_deadline := Time.get_ticks_msec() + 15000
	while b3.get_current_object() != waiting_chair \
			and Time.get_ticks_msec() < p3_seat_deadline:
		await process_frame
	_check(b3.get_current_object() == waiting_chair,
		"al liberarse la silla de espera, el que estaba de pie se sienta")

	_finish()


func _spawn_npc(system: Node3D, controller: BuildController, cell: Vector2i) -> NpcAgent:
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
		print("CONSULT_WAITING_OK")
		quit(0)
	else:
		printerr("CONSULT_WAITING_FAILED: ", _failures)
		quit(1)
