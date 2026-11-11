extends SceneTree

## Prueba del NavMesh sobre todo el mapa y de la entrada por la grilla.
## Ejecutar:
##   Godot --headless --path . --script res://tests/nav_map_smoke_test.gd
##
## Carga el nivel real (`scenes/demos/build_demo.tscn`) con su construccion guardada y
## verifica que:
##   - el NavMesh cubre el terreno, no solo la grilla;
##   - hay camino desde fuera de la grilla hasta una silla;
##   - la IA puede consultar la grilla activa para entrar por la celda mas
##     cercana.

var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var packed: PackedScene = load("res://scenes/demos/build_demo.tscn")
	if packed == null:
		_fail("no se pudo cargar scenes/demos/build_demo.tscn")
		_finish()
		return

	var demo: Node3D = packed.instantiate() as Node3D
	get_root().add_child(demo)
	current_scene = demo

	var nav := demo.get_node_or_null("BuildSystem/BuildNavigation") as BuildNavigation
	var controller := demo.get_node_or_null("BuildSystem/BuildController") as BuildController
	if nav == null or controller == null:
		_fail("faltan BuildNavigation / BuildController")
		_finish()
		return

	_check(nav.include_scene_geometry, "el nivel hornea la geometria del mapa")

	await physics_frame
	await physics_frame
	controller.load_construction()
	controller.exit_build_mode()
	_check(controller.get_floor_count() > 0, "se carga la construccion guardada")

	# Esperar el horneado (puede tardar por el tamano del mapa).
	var deadline := Time.get_ticks_msec() + 90000
	nav.bake_now()
	while nav.is_baking() and Time.get_ticks_msec() < deadline:
		await physics_frame
	_check(not nav.is_baking(), "el horneado termina")
	_check(nav.get_polygon_count() > 0, "el NavMesh tiene poligonos")

	var map := demo.get_world_3d().navigation_map
	NavigationServer3D.map_force_update(map)
	for i in 6:
		await physics_frame

	# Un punto fuera del hospital, sobre el terreno.
	var outside := Vector3(20.0, 0.1, 12.0)
	var closest_out := NavigationServer3D.map_get_closest_point(map, outside)
	_check(closest_out.distance_to(outside) < 1.0,
		"el NavMesh llega fuera de la grilla")

	# La silla de la sala (celda 7,17 de la grilla).
	var chair_cell := Vector3(7.5, 0.1, -4.5)
	var path := NavigationServer3D.map_get_path(map, outside, chair_cell, true)
	_check(path.size() > 2, "hay camino desde el terreno hasta la silla")

	# La IA encuentra la grilla activa y distingue dentro/fuera.
	var active := BuildController.get_active()
	_check(active != null, "hay un BuildController activo para la IA")
	if active != null:
		_check(active.has_floor_at_world(chair_cell),
			"la silla esta sobre una celda construida")
		_check(not active.has_floor_at_world(outside),
			"el punto del terreno queda fuera de la grilla")
		_check(not active.get_floor_points().is_empty(),
			"la grilla expone sus celdas para entrar")

	# Los spawners del nivel siguen operativos con el mapa completo.
	var spawners := NpcSpawner.get_spawners()
	_check(spawners.size() == 2, "el nivel tiene 2 POI de spawner")
	if spawners.size() == 2:
		var outside_spawner: NpcSpawner = spawners[0]
		_check(not active.has_floor_at_world(outside_spawner.global_position),
			"un spawner queda fuera de la grilla")
		_check(outside_spawner._nav_ready(), "el NavMesh esta listo para el spawner")
		_check(outside_spawner.has_objective(),
			"hay un SmartObject libre como objetivo")

	_finish()


func _finish() -> void:
	if _failures == 0:
		print("NAV_MAP_SMOKE_TEST_OK")
		quit(0)
	else:
		printerr("NAV_MAP_SMOKE_TEST_FAILED: %d fallo(s)" % _failures)
		quit(1)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	_failures += 1
	printerr("FALLO: " + message)
