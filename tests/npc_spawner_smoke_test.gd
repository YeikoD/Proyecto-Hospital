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
	var packed: PackedScene = load("res://scenes/demo/npc_spawner_demo.tscn")
	if packed == null:
		_fail("no se pudo cargar scenes/demo/npc_spawner_demo.tscn")
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
