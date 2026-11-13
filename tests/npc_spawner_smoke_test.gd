extends SceneTree

## Prueba del spawner de NPCs.
## Ejecutar:
##   Godot --headless --path . --script res://tests/npc_spawner_smoke_test.gd
##
## Verifica: registro de los 2 POI, tope global de 5 NPCs, intervalo entre
## apariciones, configuracion del NPC (cerebro + ciclo) y vuelta al spawner
## para desaparecer.

var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var packed: PackedScene = load("res://scenes/demos/npc_spawner_demo.tscn")
	if packed == null:
		_fail("no se pudo cargar scenes/demos/npc_spawner_demo.tscn")
		quit(1)
		return

	var demo: Node3D = packed.instantiate() as Node3D
	get_root().add_child(demo)

	var controller: BuildController = demo.get_node("BuildSystem/BuildController")
	var nav: BuildNavigation = demo.get_node("BuildSystem/BuildNavigation")

	# Las sillas del demo son los objetivos de los NPCs.
	_check(controller.get_object_count() >= 5, "el demo coloca sillas")

	if not nav.is_baking():
		nav.bake_now()
	await nav.navigation_baked

	# Sincronizar el mapa como en nav_smoke_test.
	var map := demo.get_world_3d().navigation_map
	var deadline := Time.get_ticks_msec() + 3000
	while NavigationServer3D.map_get_iteration_id(map) == 0 \
			and Time.get_ticks_msec() < deadline:
		NavigationServer3D.map_force_update(map)
		await physics_frame
	for i in 6:
		await physics_frame
	NavigationServer3D.map_force_update(map)
	await physics_frame

	var spawners := NpcSpawner.get_spawners()
	_check(spawners.size() == 2, "hay 2 POI de spawner registrados")
	if spawners.size() < 2:
		_finish()
		return

	var spawner: NpcSpawner = spawners[0]
	_check(spawner._nav_ready(), "el NavMesh esta listo para el spawner")
	_check(spawner.has_objective(), "hay un SmartObject libre como objetivo")
	_check(NpcSpawner.count_alive() == 0, "no hay NPCs generados al inicio")

	# --- Seguridad de aparicion -------------------------------------------
	# El punto de spawn queda en el POI, nunca en el origen del mundo.
	var spawn_point := spawner.get_spawn_point()
	_check(not spawn_point.is_zero_approx(), "el punto de spawn no es el origen")
	_check(spawn_point.distance_to(spawner.global_position) < 2.0,
		"el punto de spawn queda en el POI")

	# Sin jugador cerca el POI puede aparecer; con el jugador encima, no.
	var demo_player := demo.get_node("FPSPlayer") as Node3D
	var saved_player := demo_player.global_position
	spawner.min_player_distance = 8.0
	demo_player.global_position = Vector3(0.0, 0.0, 200.0)
	_check(spawner.can_spawn(), "sin jugador cerca el POI puede aparecer")
	demo_player.global_position = spawn_point
	_check(not spawner.can_spawn(), "con el jugador en el POI no aparece")
	demo_player.global_position = Vector3(0.0, 0.0, 200.0)
	_check(spawner.can_spawn(), "al alejarse el jugador vuelve a permitir spawn")
	demo_player.global_position = saved_player
	spawner.min_player_distance = 0.0

	# Un POI lejos del NavMesh conserva su posicion (no salta a la celda
	# caminable mas cercana ni al origen del mundo).
	var far_packed: PackedScene = load("res://scripts/characters/npc/npc_spawner.tscn")
	var far_spawner: NpcSpawner = far_packed.instantiate() as NpcSpawner
	demo.add_child(far_spawner)
	far_spawner.global_position = Vector3(500.0, 0.0, 500.0)
	_check(far_spawner.get_spawn_point().distance_to(far_spawner.global_position) < 0.001,
		"un POI lejos del NavMesh conserva su posicion")
	far_spawner.queue_free()
	await process_frame

	# Mientras se hornea no se permite aparecer (el NavMesh queda vacio).
	nav.bake_now()
	_check(BuildNavigation.is_any_baking(), "el horneado se marca como en curso")
	_check(not spawner._nav_ready(), "no se aparece durante un horneado")
	await nav.navigation_baked
	_check(spawner._nav_ready(), "al terminar el horneado se vuelve a permitir")

	# --- Tope global ------------------------------------------------------
	var first: NpcAgent = spawner.spawn_now()
	_check(first != null, "spawn_now crea un NPC")
	if first == null:
		_finish()
		return
	_check(first.is_in_group(NpcSpawner.NPC_GROUP), "el NPC entra al grupo de generados")
	_check(first.wander == false, "el NPC nace sin deambular")
	var brain := first.get_node_or_null("NpcBrain") as NpcBrain
	_check(brain != null and brain.enabled, "el cerebro del NPC queda activo")
	var cycle := first.get_node_or_null("NpcSpawnCycle") as NpcSpawnCycle
	_check(cycle != null, "el NPC recibe su ciclo de vida")

	# El intervalo queda programado tras aparecer (no spawnea todo el tiempo).
	_check(spawner._timer >= spawner.spawn_interval_min - 0.01,
		"tras aparecer se espera el intervalo minimo")
	_check(spawner._timer <= spawner.spawn_interval_max + 0.01,
		"el intervalo no supera el maximo")

	# Rellenar hasta el tope con el segundo spawner.
	var second: NpcSpawner = spawners[1]
	while NpcSpawner.count_alive() < 5:
		if spawner.spawn_now() == null and second.spawn_now() == null:
			break
	_check(NpcSpawner.count_alive() == 5, "se llega al tope de 5 NPCs")
	_check(spawner.spawn_now() == null, "no se pasa del tope de 5")
	_check(second.spawn_now() == null, "el segundo spawner respeta el tope")

	# --- Vuelta al spawner y desaparicion ---------------------------------
	# Pausar la generacion automatica: si aparece otro NPC durante la vuelta, el
	# contador global no baja aunque el primero desaparezca (carrera de prueba).
	for s in spawners:
		s.set_process(false)

	# Alejar al NPC para que el regreso no sea instantaneo.
	first.global_position = Vector3(7.5, 0.1, 5.5)

	var target := NpcSpawner.pick_return_spawner(first.global_position)
	_check(target != null, "hay un spawner de retorno")
	_check(spawner in spawners, "el spawner de retorno pertenece al registro")

	var alive_before := NpcSpawner.count_alive()
	cycle._begin_return()
	# El estado y el apagado del cerebro son sincronicos.
	_check(cycle.get_state() == NpcSpawnCycle.State.RETURNING,
		"el NPC pasa a volver al spawner")
	_check(brain.enabled == false, "el cerebro se apaga al volver")

	# Forzar el vencimiento del reintento de camino: NO debe desaparecer.
	cycle._timer = 0.01
	await process_frame
	await process_frame
	await process_frame
	_check(is_instance_valid(first), "el NPC no desaparece en el camino")
	_check(cycle.get_state() == NpcSpawnCycle.State.RETURNING,
		"el NPC sigue intentando volver")

	# Recien desaparece cuando llega al spawner.
	var deadline_despawn := Time.get_ticks_msec() + 10000
	while is_instance_valid(first) and Time.get_ticks_msec() < deadline_despawn:
		await physics_frame
	_check(not is_instance_valid(first), "el NPC desaparece al llegar al spawner")
	_check(NpcSpawner.count_alive() == alive_before - 1,
		"el contador de NPCs vivos baja al desaparecer")

	_finish()


func _finish() -> void:
	if _failures == 0:
		print("NPC_SPAWNER_SMOKE_TEST_OK")
		quit(0)
	else:
		printerr("NPC_SPAWNER_SMOKE_TEST_FAILED: %d fallo(s)" % _failures)
		quit(1)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	_failures += 1
	printerr("FALLO: " + message)
