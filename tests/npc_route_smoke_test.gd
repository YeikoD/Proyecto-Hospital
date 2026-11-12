extends SceneTree

## Prueba del modo ruta de NpcSpawner + NpcRouteFSM.
## Ejecutar:
##   Godot --headless --path . --script res://tests/npc_route_smoke_test.gd
##
## Verifica:
## - Un spawner con route_target_path agrega NpcRouteFSM (no NpcSpawnCycle).
## - El cerebro arranca apagado y el NPC viaja hacia el destino.
## - Al llegar a B espera y desaparece (ruta de una sola direccion).
## - Con chance 1 y SmartObjects cerca, el selector desvia a usarlos.
## - Un spawner sin ruta sigue usando el ciclo normal.

var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var packed: PackedScene = load("res://scenes/demos/npc_spawner_demo.tscn")
	if packed == null:
		_fail("no se pudo cargar npc_spawner_demo.tscn")
		quit(1)
		return
	var demo: Node3D = packed.instantiate() as Node3D
	get_root().add_child(demo)
	current_scene = demo
	await process_frame

	var nav: BuildNavigation = demo.get_node("BuildSystem/BuildNavigation")
	if not nav.is_baking():
		nav.bake_now()
	await nav.navigation_baked

	var map: RID = demo.get_world_3d().navigation_map
	var deadline := Time.get_ticks_msec() + 3000
	while NavigationServer3D.map_get_iteration_id(map) == 0 \
			and Time.get_ticks_msec() < deadline:
		NavigationServer3D.map_force_update(map)
		await physics_frame
	for i in 6:
		await physics_frame
	NavigationServer3D.map_force_update(map)
	await physics_frame

	var a: NpcSpawner = demo.get_node("Spawners/SpawnerA")
	var b: NpcSpawner = demo.get_node("Spawners/SpawnerB")
	a.stop()
	b.stop()
	# Mantener can_spawn() habilitado pero sin el _process automatico.
	a.enabled = true
	for child in demo.get_node("NPCs").get_children():
		child.queue_free()
	await process_frame

	# --- Modo ruta ---------------------------------------------------------
	a.route_target_path = NodePath("../SpawnerB")
	a.require_objective = false
	a.route_smart_object_chance = 0.0
	a.route_loop = false
	a.route_wait_at_target = 0.0

	var npc: NpcAgent = a.spawn_now()
	_check(npc != null, "el spawner crea un NPC con ruta")
	if npc == null:
		_finish()
		return

	var route = npc.get_node_or_null("NpcRouteFSM")
	_check(route != null, "el NPC recibe NpcRouteFSM")
	_check(npc.get_node_or_null("NpcSpawnCycle") == null,
		"en modo ruta no recibe NpcSpawnCycle")
	var brain := npc.get_node_or_null("NpcBrain") as NpcBrain
	_check(brain != null and not brain.enabled,
		"el cerebro arranca apagado en modo ruta")

	for i in 4:
		await physics_frame
	_check(route.get_state() == 1, "empieza en TRAVEL") # State.TRAVEL
	_check(npc.global_position.distance_to(b.get_spawn_point()) > 1.0,
		"todavia no esta en el destino")
	_check(route.get_current_target().distance_to(b.get_spawn_point()) < 0.5,
		"el destino es el spawner B")

	# Simular la llegada a B.
	npc.global_position = b.get_spawn_point()
	route._on_arrived()
	_check(route.get_state() == 3, "al llegar pasa a WAIT") # State.WAIT
	route._tick_wait(0.1)
	await process_frame
	_check(not is_instance_valid(npc), "desaparece al terminar la ruta")

	# --- Ida y vuelta (A -> B -> A) ----------------------------------------
	a.route_loop = true
	a.route_trips = 2
	var origin_a := a.get_spawn_point()
	var npc_rt: NpcAgent = a.spawn_now()
	_check(npc_rt != null, "se crea un NPC para la ida y vuelta")
	if npc_rt != null:
		var route_rt = npc_rt.get_node("NpcRouteFSM")
		for i in 4:
			await physics_frame
		# Llega a B: espera y emprende la vuelta, no desaparece.
		npc_rt.global_position = b.get_spawn_point()
		route_rt._on_arrived()
		_check(route_rt.get_state() == 3, "en B espera antes de volver")
		route_rt._tick_wait(0.1)
		_check(route_rt.get_state() == 1, "despues de B vuelve a viajar")
		_check(route_rt.get_current_target().distance_to(origin_a) < 0.5,
			"el segundo tramo apunta de vuelta a A")
		# Llega a A: completa los dos tramos y desaparece.
		npc_rt.global_position = origin_a
		route_rt._on_arrived()
		route_rt._tick_wait(0.1)
		await process_frame
		_check(not is_instance_valid(npc_rt),
			"desaparece al completar la ida y vuelta")

	# --- Nunca desaparece fuera de un extremo de la ruta -------------------
	var npc_far: NpcAgent = a.spawn_now()
	_check(npc_far != null, "se crea un NPC para la prueba de despawn")
	if npc_far != null:
		var route_far = npc_far.get_node("NpcRouteFSM")
		npc_far.global_position = Vector3(30.0, 0.0, 30.0)
		route_far._finish_route()
		_check(is_instance_valid(npc_far), "no desaparece fuera del POI")
		_check(route_far.get_state() == 1, "vuelve a viajar hacia el extremo")
		npc_far.queue_free()
		await process_frame

	# --- Desvio aleatorio a SmartObject ------------------------------------
	var npc2: NpcAgent = a.spawn_now()
	_check(npc2 != null, "se crea un NPC para probar el desvio")
	if npc2 != null:
		var route2 = npc2.get_node("NpcRouteFSM")
		route2.smart_object_chance = 1.0
		route2.smart_object_radius = 50.0
		route2._smart_object_attempted = false
		var started: bool = route2._try_start_smart_object()
		_check(started, "con chance 1 y objetos cerca decide usar un SmartObject")
		_check(route2.get_state() == 2, "pasa a USE_SMART_OBJECT") # State.USE
		var brain2 := npc2.get_node("NpcBrain") as NpcBrain
		_check(brain2.enabled, "enciende el NpcBrain para la interaccion")
		npc2.queue_free()
		await process_frame

	# --- El modo normal sigue funcionando ---------------------------------
	b.enabled = true
	b.require_objective = false
	b.route_target_path = NodePath("")
	var npc3: NpcAgent = b.spawn_now()
	_check(npc3 != null, "el spawner sin ruta sigue creando NPCs")
	if npc3 != null:
		_check(npc3.get_node_or_null("NpcSpawnCycle") != null,
			"sin ruta usa NpcSpawnCycle")
		_check(npc3.get_node_or_null("NpcRouteFSM") == null,
			"sin ruta no usa NpcRouteFSM")
		npc3.queue_free()

	_finish()


func _finish() -> void:
	if _failures == 0:
		print("NPC_ROUTE_SMOKE_TEST_OK")
		quit(0)
	else:
		printerr("NPC_ROUTE_SMOKE_TEST_FAILED: %d fallo(s)" % _failures)
		quit(1)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	_failures += 1
	printerr("FALLO: " + message)
