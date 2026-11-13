extends SceneTree

## Prueba del NPC medico manual.
## Ejecutar:
##   Godot --headless --path . --script res://tests/npc_doctor_smoke_test.gd
##
## Verifica: el spawner no genera NPCs por intervalo, la accion `summon_doctor`
## queda ligada a la tecla Y, la tecla invoca un unico medico, su cerebro solo
## tiene la necesidad `work`, elige el objeto especial "Escritorio de trabajo",
## lo usa una sola vez y vuelve a un spawner para desaparecer.

const DoctorSpawnerScript := preload("res://scripts/characters/npc/npc_doctor_spawner.gd")

var _failures := 0
var _started := false
var _used_objects: Array = []
var _used_affordances: Array = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	SmartObjectRegistry.clear()
	var packed := load("res://scenes/map1.tscn") as PackedScene
	if packed == null:
		_fail("no se pudo cargar scenes/map1.tscn")
		quit(1)
		return
	var scene := packed.instantiate() as Node3D
	get_root().add_child(scene)
	current_scene = scene
	await process_frame
	await process_frame

	# Los spawners automaticos no participan: solo se prueba el medico.
	for spawner_name in ["SpawnerA", "SpawnerB"]:
		var auto := scene.get_node_or_null("Spawners/" + spawner_name) as NpcSpawner
		if auto != null:
			auto.stop()
	for npc in get_nodes_in_group(NpcSpawner.NPC_GROUP):
		(npc as Node).queue_free()
	await process_frame

	# El medico solo aparece con el NavMesh listo (igual que los spawners).
	var nav := scene.get_node("BuildSystem/BuildNavigation") as BuildNavigation
	if not nav.is_baking():
		nav.bake_now()
	await nav.navigation_baked
	var map := scene.get_world_3d().navigation_map
	var nav_deadline := Time.get_ticks_msec() + 5000
	while NavigationServer3D.map_get_iteration_id(map) == 0 \
			and Time.get_ticks_msec() < nav_deadline:
		NavigationServer3D.map_force_update(map)
		await physics_frame
	for i in 6:
		await physics_frame
	NavigationServer3D.map_force_update(map)
	await physics_frame

	var controller := scene.get_node("BuildSystem/BuildController") as BuildController
	_check(controller.get_special_object_count() == 1,
		"map1 forma el Escritorio de trabajo al cargar")
	var special := _find_work_desk(controller)
	_check(special != null, "existe el objeto especial work_desk")
	_check(special != null and special.has_affordance(&"work"),
		"el objeto especial anuncia 'work'")
	_check(special != null and special.find_free_slot(&"work") >= 0,
		"el escritorio de trabajo tiene un slot 'work' libre")
	if special == null:
		quit(1)
		return

	var spawner = scene.get_node_or_null("Spawners/DoctorSpawner")
	_check(spawner != null, "map1 tiene Spawners/DoctorSpawner")
	if spawner == null:
		quit(1)
		return
	_check(spawner.get_script() == DoctorSpawnerScript,
		"DoctorSpawner usa npc_doctor_spawner.gd")
	_check(not spawner.is_processing(),
		"el spawner del medico no genera NPCs por intervalo")
	# Aunque alguien arranque todos los spawners, el medico sigue siendo manual.
	spawner.start()
	_check(not spawner.is_processing(),
		"start() no reactiva la aparicion automatica del medico")
	_check(spawner.is_in_group(NpcSpawner.SPAWNER_GROUP),
		"el spawner del medico se registra como POI")
	_check(spawner.has_method("summon_doctor"), "expone summon_doctor()")
	_check(spawner.get_status_text().contains("no disponible"),
		"el indicador arranca sin medico")

	# La accion de invocacion existe y la tecla fisica es Y.
	var action := StringName(spawner.get("summon_action"))
	_check(InputMap.has_action(action), "existe la accion 'summon_doctor'")
	var bound_to_y := false
	for event in InputMap.action_get_events(action):
		var key := event as InputEventKey
		if key != null and key.physical_keycode == KEY_Y:
			bound_to_y = true
	_check(bound_to_y, "la accion 'summon_doctor' esta ligada a la tecla Y")

	# Sin la tecla no aparece nadie, por mas que pasen los segundos.
	var wait_start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - wait_start < 1500:
		await process_frame
	_check(spawner.get_live_doctor() == null,
		"el medico no aparece solo")
	_check(NpcSpawner.count_alive() == 0,
		"no hay NPCs vivos antes de invocar")

	# Si el jugador esta en el POI, la invocacion falla y lo explica.
	var player := scene.get_node("FPSPlayer") as Node3D
	var saved_player := player.global_position
	player.global_position = spawner.get_spawn_point()
	var blocked: NpcAgent = spawner.summon_doctor()
	_check(blocked == null, "no invoca al medico delante del jugador")
	_check(spawner.get_last_outcome() == DoctorSpawnerScript.SummonOutcome.FAILED,
		"el intento fallido queda registrado")
	_check(spawner.get_last_feedback().contains("delante de ti"),
		"el feedback explica por que no se invoco")
	_check(spawner.is_feedback_visible(), "el fallo se muestra en pantalla")
	player.global_position = saved_player

	# La tecla Y invoca al medico.
	var event := InputEventAction.new()
	event.action = action
	event.pressed = true
	spawner._unhandled_input(event)
	await process_frame

	var doctor: NpcAgent = spawner.get_live_doctor()
	_check(doctor != null, "la tecla Y invoca al medico")
	if doctor == null:
		quit(1)
		return
	_check(spawner.get_last_outcome() == DoctorSpawnerScript.SummonOutcome.SUMMONED,
		"la invocacion queda registrada como exitosa")
	_check(spawner.get_last_feedback().contains("invocado"),
		"el feedback avisa que el medico fue invocado")
	_check(spawner.is_feedback_visible(), "el aviso se muestra en pantalla")
	_check(doctor.is_in_group(spawner.DOCTOR_GROUP),
		"el medico queda en el grupo doctor_npcs")
	_check(doctor.is_in_group(NpcSpawner.NPC_GROUP),
		"el medico cuenta como NPC vivo")
	_check(NpcSpawner.count_alive() == 1,
		"hay exactamente un NPC vivo")

	var brain := doctor.get_node("NpcBrain") as NpcBrain
	_check(brain != null, "el medico trae NpcBrain")
	if brain == null:
		quit(1)
		return
	_check(brain.needs.size() == 1 and brain.needs.has(&"work"),
		"el medico solo tiene la necesidad 'work'")
	_check(brain.need_affordances.get(&"work", StringName()) == &"work",
		"la necesidad 'work' apunta a la affordance 'work'")
	_check(brain.search_radius == 0.0,
		"el medico no limita la busqueda por distancia")

	# La tecla otra vez no duplica al medico.
	var again: NpcAgent = spawner.summon_doctor()
	_check(again == doctor, "invocar de nuevo devuelve el medico existente")
	_check(NpcSpawner.count_alive() == 1,
		"la tecla nunca duplica medicos")
	_check(spawner.get_last_outcome() == DoctorSpawnerScript.SummonOutcome.ALREADY_PRESENT,
		"el segundo intento se registra como 'ya presente'")
	_check(spawner.get_last_feedback().contains("ya está"),
		"el feedback avisa que el medico ya esta en el hospital")

	# El uso del escritorio dura 1 s para que la prueba sea rapida.
	var work: AffordanceDef = special.get_affordance(&"work")
	if work != null:
		work.duration = 1.0
	brain.interaction_started.connect(_on_interaction_started)

	# Espera a que empiece la interaccion.
	var deadline := Time.get_ticks_msec() + 25000
	while not _started and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(_started, "el medico empieza a usar el Escritorio de trabajo")
	var status_deadline := Time.get_ticks_msec() + 1200
	while not spawner.get_status_text().contains("atendiendo") \
			and Time.get_ticks_msec() < status_deadline:
		await process_frame
	_check(spawner.get_status_text().contains("atendiendo"),
		"el indicador muestra 'Médico atendiendo' cuando trabaja")
	_check(brain.get_current_object() == special,
		"el medico eligio el objeto especial work_desk")
	var current := brain.get_current_affordance()
	_check(current != null and current.id == &"work",
		"el medico usa la affordance 'work'")

	# El medico es permanente: al terminar la interaccion no vuelve al spawner
	# para desaparecer, se queda en la escena.
	_check(spawner.despawn_after_use == false,
		"el spawner del medico no programa la desaparicion")
	_check(not doctor.has_node("NpcSpawnCycle"),
		"el medico no tiene ciclo de desaparicion")
	var alive_deadline := Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < alive_deadline:
		await process_frame
	_check(is_instance_valid(doctor) and not doctor.is_queued_for_deletion(),
		"el medico permanece en la escena despues de trabajar")
	_check(spawner.get_live_doctor() == doctor,
		"el medico vivo sigue siendo el mismo")
	_check(_used_only_special(special),
		"el medico nunca uso sillas ni otros objetos")

	# Al seguir teniendo la necesidad `work`, vuelve a usar el escritorio.
	var uses_before := _used_objects.size()
	deadline = Time.get_ticks_msec() + 15000
	while _used_objects.size() <= uses_before \
			and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(_used_objects.size() > uses_before,
		"el medico sigue trabajando en el escritorio")

	# Un NPC normal nunca puede ocupar la silla del operador (`work`).
	var normal_npc := (load("res://scripts/characters/npc/npc.tscn") as PackedScene) \
		.instantiate() as NpcAgent
	scene.get_node("NPCs").add_child(normal_npc)
	normal_npc.global_position = spawner.get_spawn_point()
	var normal_brain := normal_npc.get_node("NpcBrain") as NpcBrain
	_check(normal_brain != null, "el NPC normal trae NpcBrain")
	if normal_brain != null:
		_check(not normal_brain.can_use_affordance(&"work"),
			"un NPC normal no puede usar la affordance 'work'")
		var normal_started := [false]
		normal_brain.interaction_started.connect(
			func(_object: Node, _affordance: AffordanceDef) -> void:
				normal_started[0] = true
		)
		normal_brain.needs = {"work": 1.0}
		normal_brain.need_growth = {"work": 0.0}
		normal_brain.need_affordances = {"work": &"work"}
		normal_brain.need_threshold = 0.0
		normal_brain.search_radius = 0.0
		# Esta prueba aisla la restriccion de `work`; el consultorio tiene su
		# propia prueba.
		normal_brain.consult_enabled = false
		normal_brain.set_enabled(true)
		var normal_deadline := Time.get_ticks_msec() + 2000
		while Time.get_ticks_msec() < normal_deadline:
			await process_frame
		_check(not normal_started[0],
			"un NPC normal no se sienta en la silla del operador")
		_check(normal_brain.get_current_object() == null,
			"un NPC normal no reserva el escritorio como operador")
		# El operador (`work`) sigue reservado al medico. Las sillas de
		# pacientes del conjunto pueden usarse durante una consulta.
		var normal_work := SmartObjectRegistry.find_candidates(
			&"work", normal_npc.global_position, 0.0, normal_npc.get_instance_id()
		)
		var claims_operator := false
		for candidate in normal_work:
			if candidate["object"] == special:
				claims_operator = true
		_check(not claims_operator,
			"un NPC normal no puede reservar el operador del escritorio")
		_check(not special.allows_agent(normal_npc.get_instance_id(), &"work"),
			"el operador del escritorio esta restringido al medico")
		_check(special.allows_agent(normal_npc.get_instance_id(), &"sit"),
			"las sillas de pacientes admiten NPCs normales en consulta")
		_check(special.allows_agent(doctor.get_instance_id(), &"work"),
			"el medico si puede reservar el operador")
		normal_npc.queue_free()

	_check(doctor.has_node("DoctorTag"),
		"el medico lleva una etiqueta visible para distinguirlo")

	if _failures == 0:
		print("NPC_DOCTOR_SMOKE_TEST_OK")
		quit(0)
	else:
		printerr("NPC_DOCTOR_SMOKE_TEST_FAILED: ", _failures)
		quit(1)


func _find_work_desk(controller: BuildController) -> SpecialObject:
	for obj in controller.get_special_objects():
		if obj != null and obj.get_special_id() == &"work_desk":
			return obj
	return null


func _on_interaction_started(object: Node, affordance: AffordanceDef) -> void:
	_started = true
	_used_objects.append(object)
	_used_affordances.append(affordance.id if affordance != null else &"")


func _used_only_special(special: SpecialObject) -> bool:
	if _used_objects.is_empty():
		return false
	for object in _used_objects:
		if object != special:
			return false
	for affordance_id in _used_affordances:
		if affordance_id != &"work":
			return false
	return true


func _check(condition: bool, message: String) -> void:
	if condition:
		print("OK: ", message)
	else:
		_failures += 1
		printerr("FALLO: ", message)


func _fail(message: String) -> void:
	_failures += 1
	printerr("FALLO: ", message)
