extends SceneTree

## Prueba de evasion entre NPCs.
## Ejecutar:
##   Godot --headless --path . --script res://tests/npc_avoidance_smoke_test.gd
##
## Verifica:
## - Los NPC colisionan entre si (capa 2 dentro de su mascara).
## - Todos los NPC entran al grupo de evasion, aunque no los cree un spawner.
## - Detectan a otro NPC en el cono frontal.
## - El desvio guarda el destino original y lo restaura al terminar.
## - Dos NPC caminando de frente no se atraviesan y ambos llegan a destino.
##
## Usa un NavMesh sintetico (un rectangulo) para que la prueba sea rapida y no
## dependa de la construccion del hospital.

const WALK_TIMEOUT_MSEC := 12000
## Distancia mínima entre centros al cruzarse. Las cápsulas (radio 0.35)
## contactan a 0.7 m; exigimos algo más para detectar un choque real.
const MIN_PASS_DISTANCE := 0.75
## A qué distancia entre centros debe empezar el desvío. Con 3.6 m de
## anticipación y 0.15 s de reacción da ~2.7 m (≈2 m antes del contacto).
const MIN_FIRST_DETOUR_DISTANCE := 2.4

var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var root := Node3D.new()
	get_root().add_child(root)
	current_scene = root
	_make_floor(root)
	_make_navmesh(root)

	var map := root.get_world_3d().navigation_map
	for i in 8:
		NavigationServer3D.map_force_update(map)
		await physics_frame

	var packed: PackedScene = load("res://scripts/characters/npc/npc.tscn")
	if packed == null:
		_fail("no se pudo cargar npc.tscn")
		_finish()
		return

	var a: NpcAgent = packed.instantiate()
	var b: NpcAgent = packed.instantiate()
	for npc in [a, b]:
		npc.wander = false
		npc.speed = 3.0
		npc.acceleration = 20.0
		npc.turn_speed = 12.0
	root.add_child(a)
	root.add_child(b)
	a.global_position = Vector3(-5.0, 0.1, 0.0)
	b.global_position = Vector3(5.0, 0.1, 0.0)
	for i in 4:
		await physics_frame

	# --- Configuracion de colision y grupo ---------------------------------
	_check(a.collision_layer == 2, "el NPC vive en la capa 2")
	_check((a.collision_mask & 2) != 0,
		"la mascara del NPC incluye a los demas NPC (capa 2)")
	_check(a.is_in_group(NpcAgent.AGENT_GROUP),
		"el NPC entra al grupo de evasion aunque no lo cree un spawner")

	# --- Deteccion frontal -------------------------------------------------
	a.move_to(Vector3(5.0, 0.0, 0.0))
	b.global_position = Vector3(-2.2, 0.1, 0.0) # 2.8 m delante de A
	await physics_frame
	_check(a._find_npc_in_front(Vector3(1.0, 0.0, 0.0)) == b,
		"detecta a otro NPC a mas de 2 m de distancia")
	b.global_position = Vector3(-5.0, 0.1, 0.0)
	await physics_frame
	_check(a._find_npc_in_front(Vector3(1.0, 0.0, 0.0)) == null,
		"no detecta a un NPC que esta detras")

	# --- El desvio conserva el destino original ---------------------------
	b.global_position = Vector3(-4.0, 0.1, 0.0)
	await physics_frame
	var main_target := a.get_target()
	a._start_detour(b, Vector3(1.0, 0.0, 0.0))
	_check(a._detour_active, "inicia un desvio al detectar al NPC")
	_check(a.get_target() == main_target,
		"el destino original no se pierde durante el desvio")
	_check(a._agent.target_position.distance_to(main_target) > 0.1,
		"el agente apunta al punto de desvio")
	a._end_detour()
	_check(not a._detour_active, "termina el desvio")
	_check(a._agent.target_position.distance_to(main_target) < 0.01,
		"al terminar el desvio vuelve al destino original")

	# --- Decision a distancia ---------------------------------------------
	# Misma direccion: no se desvia para no zigzaguear en fila india.
	a.global_position = Vector3(-5.0, 0.1, 0.0)
	b.global_position = Vector3(-2.0, 0.1, 0.0) # 3 m delante de A
	a.move_to(Vector3(5.0, 0.0, 0.0))
	b.move_to(Vector3(10.0, 0.0, 0.0))
	await physics_frame
	for i in 4:
		a._update_npc_avoidance(0.1, Vector3(1.0, 0.0, 0.0))
	_check(not a._detour_active,
		"no se desvia de un NPC que camina en la misma direccion")

	# De frente: se desvia al detectarlo a ~3 m, antes de tocarlo.
	b.global_position = Vector3(-2.0, 0.1, 0.0)
	b.move_to(Vector3(-10.0, 0.0, 0.0))
	await physics_frame
	a._blocked_time = 0.0
	a._avoid_cooldown = 0.0
	for i in 4:
		a._update_npc_avoidance(0.1, Vector3(1.0, 0.0, 0.0))
	_check(a._detour_active,
		"empieza el desvio con ~2 m de margen antes del contacto")
	a._end_detour()

	# --- Ida y vuelta de frente: no se atraviesan --------------------------
	a.global_position = Vector3(-5.0, 0.1, 0.0)
	b.global_position = Vector3(5.0, 0.1, 0.0)
	a.move_to(Vector3(5.0, 0.0, 0.0))
	b.move_to(Vector3(-5.0, 0.0, 0.0))

	var min_distance := INF
	var first_detour_distance := INF
	var detour_a := false
	var detour_b := false
	var deadline := Time.get_ticks_msec() + WALK_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		await create_timer(0.02).timeout
		if not is_instance_valid(a) or not is_instance_valid(b):
			break
		var distance := a.global_position.distance_to(b.global_position)
		min_distance = minf(min_distance, distance)
		if a._detour_active:
			detour_a = true
		if b._detour_active:
			detour_b = true
		if first_detour_distance == INF and (detour_a or detour_b):
			first_detour_distance = distance
		if not a._has_target and not b._has_target:
			break

	_check(detour_a, "el NPC A recalcula su ruta para esquivar")
	_check(detour_b, "el NPC B recalcula su ruta para esquivar")
	_check(first_detour_distance >= MIN_FIRST_DETOUR_DISTANCE,
		"empieza el desvio con ~2 m de margen (%.2f m)" % first_detour_distance)
	_check(min_distance >= MIN_PASS_DISTANCE,
		"los NPC no se tocan al cruzarse (distancia minima %.2f m)" % min_distance)
	_check(not a._has_target, "el NPC A llega a destino")
	_check(not b._has_target, "el NPC B llega a destino")
	_check(a.global_position.distance_to(Vector3(5.0, 0.0, 0.0)) < 0.6,
		"el NPC A termina en el otro extremo")
	_check(b.global_position.distance_to(Vector3(-5.0, 0.0, 0.0)) < 0.6,
		"el NPC B termina en el otro extremo")

	_finish()


func _make_floor(root: Node3D) -> void:
	var body := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40.0, 0.5, 12.0)
	collision.shape = box
	body.add_child(collision)
	body.position = Vector3(0.0, -0.25, 0.0)
	root.add_child(body)


func _make_navmesh(root: Node3D) -> void:
	var mesh := NavigationMesh.new()
	mesh.vertices = PackedVector3Array([
		Vector3(-20.0, 0.0, -6.0),
		Vector3(20.0, 0.0, -6.0),
		Vector3(20.0, 0.0, 6.0),
		Vector3(-20.0, 0.0, 6.0),
	])
	mesh.add_polygon(PackedInt32Array([0, 1, 2, 3]))
	var region := NavigationRegion3D.new()
	region.navigation_mesh = mesh
	root.add_child(region)


func _finish() -> void:
	if _failures == 0:
		print("NPC_AVOIDANCE_SMOKE_TEST_OK")
		quit(0)
	else:
		printerr("NPC_AVOIDANCE_SMOKE_TEST_FAILED: %d fallo(s)" % _failures)
		quit(1)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	_failures += 1
	printerr("FALLO: " + message)
