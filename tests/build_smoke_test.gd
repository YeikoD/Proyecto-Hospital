extends SceneTree

## Prueba rapida del sistema de construccion.
## Ejecutar:
##   Godot --headless --path . --script res://tests/build_smoke_test.gd

var _failures := 0


func _initialize() -> void:
	# Diferido: en _initialize el arbol todavia no esta montado y los nodos
	# recien instanciados no tienen transform global ni _ready ejecutado.
	_run.call_deferred()


func _run() -> void:
	var demo_scene: PackedScene = load("res://scenes/build_demo.tscn")
	if demo_scene == null:
		_fail("no se pudo cargar scenes/build_demo.tscn")
		quit(1)
		return

	var demo := demo_scene.instantiate()
	get_root().add_child(demo)

	var grid: BuildGrid = demo.get_node("BuildSystem/BuildGrid")
	var controller: BuildController = demo.get_node("BuildSystem/BuildController")

	# --- Matematica de la grilla -----------------------------------------
	# Las pruebas usan coordenadas relativas al nodo de la grilla para no
	# depender de la posicion del BuildSystem dentro del nivel.
	var base := grid.global_position
	var plane_y := grid.plane_global_y()

	_check(grid.cell_size == 1.0, "cell_size por defecto")
	_check(grid.cell_from_world(base + Vector3(0.5, plane_y - base.y, 0.5)) == Vector2i(0, 0), "celda 0,0")
	_check(grid.cell_from_world(base + Vector3(2.5, plane_y - base.y, 3.5)) == Vector2i(2, 3), "celda 2,3")
	_check(grid.is_cell_inside(Vector2i(0, 0)), "celda 0,0 dentro")
	_check(not grid.is_cell_inside(Vector2i(-1, 0)), "celda negativa fuera")
	_check(not grid.is_cell_inside(Vector2i(grid.cells_x, 0)), "celda limite fuera")

	var center := grid.cell_center(Vector2i(2, 3))
	_check(grid.cell_from_world(center) == Vector2i(2, 3), "centro en la celda")
	_check(is_equal_approx(center.x, base.x + 2.5), "centro X en la celda")
	_check(is_equal_approx(center.z, base.z + 3.5), "centro Z en la celda")

	var wall := grid.wall_from_world(base + Vector3(2.1, plane_y - base.y, 3.5))
	_check(wall == Vector3i(2, 3, 0), "borde izquierdo detectado")
	wall = grid.wall_from_world(base + Vector3(2.9, plane_y - base.y, 3.5))
	_check(wall == Vector3i(3, 3, 0), "borde derecho detectado")
	wall = grid.wall_from_world(base + Vector3(2.5, plane_y - base.y, 3.1))
	_check(wall == Vector3i(2, 3, 1), "borde inferior detectado")
	wall = grid.wall_from_world(base + Vector3(2.5, plane_y - base.y, 3.9))
	_check(wall == Vector3i(2, 4, 1), "borde superior detectado")

	# --- Colocacion ------------------------------------------------------
	controller.tool = BuildController.Tool.FLOOR
	controller._hover_cell = Vector2i(3, 4)
	controller._hover_wall = Vector3i(3, 4, 0)
	controller._apply_tool()
	_check(controller.get_floor_count() == 1, "se coloca un suelo")

	controller._apply_tool()
	_check(controller.get_floor_count() == 1, "no se duplica el suelo")

	controller._hover_cell = Vector2i(-1, 0)
	controller._apply_tool()
	_check(controller.get_floor_count() == 1, "no se construye fuera de la grilla")

	controller.tool = BuildController.Tool.WALL
	controller._hover_wall = Vector3i(3, 4, 0)
	controller._apply_tool()
	_check(controller.get_wall_count() == 1, "se coloca una pared")

	controller._apply_tool()
	_check(controller.get_wall_count() == 1, "no se duplica la pared")

	controller._hover_wall = Vector3i(-1, 0, 0)
	controller._apply_tool()
	_check(controller.get_wall_count() == 1, "no se construye pared fuera")

	# --- Borrado ---------------------------------------------------------
	controller.tool = BuildController.Tool.ERASE
	controller._hover_cell = Vector2i(3, 4)
	controller._hover_wall = Vector3i(3, 4, 0)
	controller._apply_tool()
	_check(controller.get_wall_count() == 0, "se borra la pared primero")
	_check(controller.get_floor_count() == 1, "el suelo sigue ahi")

	controller._apply_tool()
	_check(controller.get_floor_count() == 0, "se borra el suelo")

	# --- Entrar / salir del modo ----------------------------------------
	controller.enter_build_mode()
	_check(controller.build_mode, "entra en modo construccion")
	_check(grid.visible, "la grilla se muestra")
	controller.exit_build_mode()
	_check(not controller.build_mode, "sale del modo construccion")
	_check(not grid.visible, "la grilla se oculta")

	if _failures == 0:
		print("BUILD_SMOKE_TEST_OK")
		quit(0)
	else:
		printerr("BUILD_SMOKE_TEST_FAILED: %d fallo(s)" % _failures)
		quit(1)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	_failures += 1
	printerr("FALLO: " + message)
