extends SceneTree

## Prueba del consultorio por zonas.
##
## Un paciente debe sentarse en una silla libre dentro de una zona `consult`
## cuando un medico esta trabajando en el escritorio de esa misma zona.

var _failures := 0
var _patient_uses: Array = []

const Consult := preload("res://scripts/characters/npc/npc_consult.gd")


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
	var patients_item := load("res://data/build_items/muebles/furniture_patient_chairs.tres") as BuildItem

	controller._on_build_item_selected(floor_item)
	for x in range(0, 14):
		for z in range(0, 14):
			controller.place_floor(Vector2i(x, z))
	await process_frame

	# Escritorio + operador + banca de pacientes, igual que un consultorio.
	controller.place_object_item(desk_item, Vector2i(6, 5), 0)
	controller.place_object_item(chair_item, Vector2i(6, 4), 0)
	controller.place_object_item(patients_item, Vector2i(6, 6), 1)
	await process_frame

	var special := controller.get_special_object_at(Vector2i(6, 5))
	_check(special != null, "el escritorio de trabajo se forma")
	if special == null:
		_finish()
		return
	_check(special.get_parts().size() == 3, "agrupa escritorio, operador y banca")

	# Zona de consultorio alrededor del escritorio y la banca.
	var zone_cells: Array[Vector2i] = []
	for x in range(4, 10):
		for z in range(3, 8):
			zone_cells.append(Vector2i(x, z))
	var zone_id := controller.paint_zone(zone_cells, &"consult")
	_check(zone_id != &"", "pinta la zona de consultorio")
	_check(controller.get_zone_type_at_world(special.global_position) == &"consult",
		"el escritorio queda dentro de la zona consult")
	_check(controller.get_zone_ids_of_type(&"consult").has(zone_id),
		"la zona queda registrada como consultorio")

	await _bake_nav(system)
	await process_frame

	# Medico trabajando en el escritorio.
	var doctor := (load("res://scripts/characters/npc/npc.tscn") as PackedScene) \
		.instantiate() as NpcAgent
	system.add_child(doctor)
	doctor.global_position = controller.grid.cell_center(Vector2i(8, 5))
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
	while (doctor_brain.get_state() != NpcBrain.State.USE
			or doctor_brain.get_current_object() != special) \
			and Time.get_ticks_msec() < doctor_deadline:
		await process_frame
	_check(doctor_brain.get_state() == NpcBrain.State.USE,
		"el medico esta trabajando en el escritorio")
	_check(doctor_brain.get_current_affordance() != null
			and doctor_brain.get_current_affordance().id == &"work",
		"el medico usa la affordance work")

	# Paciente: debe encontrar una silla dentro del consultorio.
	var patient := (load("res://scripts/characters/npc/npc.tscn") as PackedScene) \
		.instantiate() as NpcAgent
	system.add_child(patient)
	patient.global_position = controller.grid.cell_center(Vector2i(9, 4))
	var patient_brain := patient.get_node("NpcBrain") as NpcBrain
	patient_brain.consult_enabled = true
	patient_brain.interaction_started.connect(_on_patient_interaction)
	patient_brain.set_enabled(true)

	var patient_deadline := Time.get_ticks_msec() + 30000
	while _patient_uses.is_empty() and Time.get_ticks_msec() < patient_deadline:
		await process_frame
	_check(not _patient_uses.is_empty(), "el paciente va a una silla del consultorio")
	if not _patient_uses.is_empty():
		var used = _patient_uses[0]
		_check(used["object"] == special,
			"el paciente usa el objeto especial del consultorio")
		_check(used["affordance"] != null and used["affordance"].id == &"sit",
			"el paciente se sienta con la affordance sit")

	# Un NPC de ruta tambien debe desviarse al consultorio.
	var target := Node3D.new()
	target.name = "RouteTarget"
	system.add_child(target)
	target.global_position = controller.grid.cell_center(Vector2i(12, 12))
	var routed := (load("res://scripts/characters/npc/npc.tscn") as PackedScene) \
		.instantiate() as NpcAgent
	system.add_child(routed)
	routed.global_position = controller.grid.cell_center(Vector2i(9, 5))
	var routed_brain := routed.get_node("NpcBrain") as NpcBrain
	routed_brain.consult_enabled = false
	routed_brain.interaction_started.connect(_on_patient_interaction)
	var route := NpcRouteFSM.new()
	route.name = "NpcRouteFSM"
	route.target_node = target
	route.loop_route = false
	route.smart_object_chance = 0.0
	route.consult_willingness = 1.0
	route.consult_chance = 1.0
	route.consult_radius = 0.0
	route.consult_duration = 20.0
	routed.add_child(route)

	var route_deadline := Time.get_ticks_msec() + 30000
	while _patient_uses.size() < 2 and Time.get_ticks_msec() < route_deadline:
		await process_frame
	_check(_patient_uses.size() >= 2,
		"un NPC de ruta tambien va al consultorio")
	if _patient_uses.size() >= 2:
		var routed_use = _patient_uses[1]
		_check(routed_use["object"] == special,
			"el NPC de ruta usa el objeto especial del consultorio")
		_check(routed_use["affordance"] != null
				and routed_use["affordance"].id == &"sit",
			"el NPC de ruta se sienta en la silla del consultorio")

	# Sin el medico trabajando, el consultorio no ofrece sillas.
	doctor_brain.set_enabled(false)
	await process_frame
	var seat_after := Consult.find_active_seat(
		patient, 0.0, false
	)
	_check(seat_after.is_empty(),
		"sin medico trabajando el consultorio no ofrece asientos")

	# Fuera de la zona tampoco.
	_check(not controller.get_zone_ids_of_type(&"waiting").has(zone_id),
		"la zona de consultorio no es de espera")

	_finish()


func _on_patient_interaction(object: Node, affordance: AffordanceDef) -> void:
	_patient_uses.append({"object": object, "affordance": affordance})


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
		print("CONSULT_ZONE_OK")
		quit(0)
	else:
		printerr("CONSULT_ZONE_FAILED: ", _failures)
		quit(1)
