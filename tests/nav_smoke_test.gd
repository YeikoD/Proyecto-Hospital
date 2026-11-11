extends SceneTree

## Prueba del NavMesh horneado desde la grilla.
## Ejecutar:
##   Godot --headless --path . --script res://tests/nav_smoke_test.gd

var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var scene: PackedScene = load("res://scenes/demos/nav_demo.tscn")
	if scene == null:
		_fail("no se pudo cargar scenes/demos/nav_demo.tscn")
		quit(1)
		return

	var demo: Node3D = scene.instantiate() as Node3D
	get_root().add_child(demo)

	var controller: BuildController = demo.get_node("BuildSystem/BuildController")
	var nav: BuildNavigation = demo.get_node("BuildSystem/BuildNavigation")

	_check(controller.get_floor_count() > 0, "el demo construye suelos")
	_check(controller.get_wall_count() > 0, "el demo construye paredes")

	# Esperar el horneado (o forzarlo si todavia no arranco).
	if not nav.is_baking():
		nav.bake_now()
	await nav.navigation_baked

	# Dejar que el NavigationServer sincronice el mapa.
	for i in 6:
		await physics_frame

	var map := demo.get_world_3d().navigation_map
	# Forzar la sincronizacion inmediata del mapa (Godot 4.7) para que las
	# consultas de camino vean el NavMesh recien horneado en este mismo frame.
	var start := Vector3(4.5, 0.02, 4.5)
	var end := Vector3(8.5, 0.02, 7.5)
	var sync_deadline := Time.get_ticks_msec() + 2000
	while NavigationServer3D.map_get_path(map, start, end, true).size() <= 1 \
			and Time.get_ticks_msec() < sync_deadline:
		NavigationServer3D.map_force_update(map)
		await physics_frame
	NavigationServer3D.map_force_update(map)
	await physics_frame
	await physics_frame

	_check(nav.get_polygon_count() > 0, "el NavMesh tiene poligonos")

	# Las paredes deben recortar el area: ningun vertice caminable debe quedar
	# a la altura de la cara superior de una pared (2.8 m).
	var max_y := -INF
	for vertex in nav.navigation_region.navigation_mesh.get_vertices():
		max_y = maxf(max_y, vertex.y)
	_check(max_y < 1.0, "no se hornean las caras superiores de las paredes")

	var path := NavigationServer3D.map_get_path(map, start, end, true)
	_check(path.size() > 1, "hay camino entre las dos habitaciones")

	# Camino que atraviesa la puerta de 1 celda del muro interior.
	var start_angosto := Vector3(4.5, 0.02, 4.5)
	var end_angosto := Vector3(4.5, 0.02, 7.5)
	var path_angosto := NavigationServer3D.map_get_path(
		map, start_angosto, end_angosto, true
	)
	_check(path_angosto.size() > 1, "hay camino por la puerta de 1 celda")
	var largo_inicial := _path_length(path_angosto)

	# Cerrar la puerta de 1 celda: el rebake debe reflejarlo y obligar a rodear.
	var bakes_antes := nav.bake_count
	_check(controller.place_wall(Vector3i(5, 6, 1)), "se coloca el muro de prueba")

	var deadline := Time.get_ticks_msec() + 5000
	while nav.bake_count <= bakes_antes and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(nav.bake_count > bakes_antes, "el cambio dispara un rebake")

	for i in 10:
		await physics_frame

	# Esperar a que el rebake se sincronice antes de consultar el camino.
	var path_cerrado := NavigationServer3D.map_get_path(
		map, start_angosto, end_angosto, true
	)
	sync_deadline = Time.get_ticks_msec() + 2000
	while _path_length(path_cerrado) <= largo_inicial \
			and Time.get_ticks_msec() < sync_deadline:
		NavigationServer3D.map_force_update(map)
		await physics_frame
		path_cerrado = NavigationServer3D.map_get_path(
			map, start_angosto, end_angosto, true
		)
	NavigationServer3D.map_force_update(map)
	await physics_frame
	await physics_frame
	path_cerrado = NavigationServer3D.map_get_path(
		map, start_angosto, end_angosto, true
	)

	_check(path_cerrado.size() > 1, "sigue habiendo camino rodeando la puerta")
	_check(_path_length(path_cerrado) > largo_inicial * 1.2,
		"el rebake alarga el camino al cerrar la puerta")

	# El NPC acepta un destino por API y lo ajusta al NavMesh.
	var npc: NpcAgent = demo.get_node("NPCs/NPC1")
	NavigationServer3D.map_force_update(map)
	await physics_frame
	npc.move_to(Vector3(9.5, 0.02, 5.5))
	await physics_frame
	await physics_frame
	_check(npc.get_target().distance_to(Vector3(9.5, 0.02, 5.5)) < 1.0,
		"el NPC ajusta el destino al NavMesh")

	if _failures == 0:
		print("NAV_SMOKE_TEST_OK")
		quit(0)
	else:
		printerr("NAV_SMOKE_TEST_FAILED: %d fallo(s)" % _failures)
		quit(1)


func _path_length(path: PackedVector3Array) -> float:
	var length := 0.0
	for i in range(1, path.size()):
		length += path[i - 1].distance_to(path[i])
	return length


func _check(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	_failures += 1
	printerr("FALLO: " + message)
