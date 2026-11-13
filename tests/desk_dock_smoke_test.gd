extends SceneTree

## Prueba del acople estricto del operador al escritorio: la silla solo puede
## quedar centrada en el lado largo y apoyada contra el borde frontal. Reproduce
## el layout guardado en map1 y comprueba que no se puede atravesar el escritorio.
## Ejecutar:
##   Godot --headless --path . --script res://tests/desk_dock_smoke_test.gd

var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	SmartObjectRegistry.clear()
	var demo := (load("res://scenes/demos/nav_demo.tscn") as PackedScene).instantiate() as Node3D
	get_root().add_child(demo)
	await process_frame
	var controller: BuildController = demo.get_node("BuildSystem/BuildController")
	controller.enter_build_mode()
	await process_frame
	controller.clear_all()
	await process_frame
	SmartObjectRegistry.clear()

	var floor_item := load("res://data/build_items/construccion/floor_basic.tres") as BuildItem
	var desk := load("res://data/build_items/muebles/furniture_desktop.tres") as BuildItem
	var chair := load("res://data/build_items/muebles/furniture_chair_desktop.tres") as BuildItem
	var patients := load("res://data/build_items/muebles/furniture_patient_chairs.tres") as BuildItem
	controller._on_build_item_selected(floor_item)
	for x in range(3, 12):
		for z in range(18, 26):
			controller.place_floor(Vector2i(x, z))
	await process_frame

	# Layout del save: escritorio girado y desplazado medio metro. Su rectangulo
	# real es x [7,5 .. 8,5] y z [20,5 .. 22,5]; el lado largo mira a Z.
	var desk_cell := Vector2i(7, 21)
	_check(controller.place_object_item(
		desk, desk_cell, 3, Vector3(0.5, 0.0, -0.5)),
		"coloca el escritorio girado y desplazado")
	var desk_piece := controller.get_object_at(desk_cell)
	var desk_rect := controller._piece_rect(desk_piece)

	# El cursor apunta al centro de la celda del escritorio. El acople tiene que
	# resolverse al borde frontal (lado opuesto a la pared), nunca al centro.
	controller._selected_object_item = chair
	controller._object_rotation = 3
	controller._hover_cell = desk_cell
	var hover := controller._valid_hover_offset(
		controller.grid.cell_center(desk_cell))
	_check(hover.is_equal_approx(Vector3(-0.5, 0.0, 0.0)),
		"el snap apoya la silla en el borde frontal, sin meterse bajo la mesa")
	_check(controller._hover_anchor_cell == Vector2i(9, 21),
		"el ancla del acople queda en la celda libre del frente")
	_check(controller._hover_rotation == 1,
		"el fantasma gira la silla para mirar al escritorio")
	_check(controller._can_place_object(desk_cell, chair, 3, Vector3.ZERO),
		"la silla se puede acoplar apuntando al centro del escritorio")

	# Una colocacion centrada dentro del escritorio (media huella adentro) se
	# rechaza aunque se intente saltear el snap.
	_check(not controller._can_place_object_at(
		Vector2i(9, 21), chair, 1, Vector3(-1.5, 0.0, 0.0)),
		"la silla no se puede colocar atravesando el escritorio")

	_check(controller.place_object_item(chair, desk_cell, 3, Vector3.ZERO),
		"la silla se coloca acoplada al borde frontal")
	var placed := controller.get_object_at(Vector2i(9, 21))
	_check(placed != null and placed.item_id == chair.id,
		"el ancla de la silla queda en la celda libre del frente")
	if placed != null and desk_piece != null:
		var chair_rect := controller._piece_rect(placed)
		_check(placed.cell == Vector2i(9, 21),
			"el ancla se guarda fuera de la base")
		_check(placed.sub_offset.is_equal_approx(Vector3(-0.5, 0.0, 0.0)),
			"el sub-offset la centra en el lado largo")
		_check(placed.object_rotation_steps == 1,
			"la silla queda girada hacia el escritorio")
		_check(is_equal_approx(placed.global_position.z,
				desk_piece.global_position.z),
			"queda centrada en el largo del escritorio")
		_check(is_equal_approx(placed.global_position.x,
				desk_piece.global_position.x + 1.0),
			"queda apoyada contra el borde frontal")
		var overlap := chair_rect.intersection(desk_rect)
		_check(overlap.size.x < 0.01 and overlap.size.y < 0.01,
			"la silla no invade la huella del escritorio")

	# Con la banca del lado opuesto se forma el conjunto.
	_check(controller.place_object_item(patients, Vector2i(5, 21), 3),
		"coloca la banca de pacientes del lado opuesto")
	await process_frame
	_check(controller.get_special_object_count() == 1,
		"el conjunto se forma con la silla apoyada en el borde")
	var special := controller.get_special_object_at(desk_cell)
	_check(special != null and special.get_parts().size() == 3,
		"agrupa escritorio, operador y banca")
	if special != null:
		_check(special.find_free_slot(&"work") == 0,
			"el operador queda reconocido del lado correcto")

	# --- Orden inverso: la silla primero, ya en el punto de acople ----------
	controller.clear_all()
	await process_frame
	SmartObjectRegistry.clear()
	controller._on_build_item_selected(floor_item)
	for x in range(3, 12):
		for z in range(18, 26):
			controller.place_floor(Vector2i(x, z))
	await process_frame
	_check(controller.place_object_item(
		chair, Vector2i(9, 21), 1, Vector3(-0.5, 0.0, 0.0)),
		"coloca primero la silla en el punto de acople")
	_check(controller.place_object_item(patients, Vector2i(5, 21), 3),
		"coloca la banca primero")
	_check(controller.place_object_item(
		desk, desk_cell, 3, Vector3(0.5, 0.0, -0.5)),
		"el escritorio se coloca despues")
	await process_frame
	_check(controller.get_special_object_count() == 1,
		"el conjunto se forma en el orden inverso si la silla ya estaba acoplada")
	var chair_rev := controller.get_object_at(Vector2i(9, 21))
	_check(chair_rev != null and chair_rev.item_id == chair.id,
		"la silla conserva su ancla en el orden inverso")

	# --- Rotacion aunque el cursor no este pegado al borde ----------------
	# Reproduce el save actual (escritorio sin offset). Aunque la silla se
	# coloque una celda mas lejos, igual gira para mirar al escritorio.
	controller.clear_all()
	await process_frame
	SmartObjectRegistry.clear()
	controller._on_build_item_selected(floor_item)
	for x in range(3, 12):
		for z in range(18, 26):
			controller.place_floor(Vector2i(x, z))
	await process_frame
	_check(controller.place_object_item(desk, desk_cell, 3),
		"coloca el escritorio sin offset")
	controller._selected_object_item = chair
	controller._object_rotation = 3
	controller._hover_cell = Vector2i(9, 21)
	var far_hover := controller._valid_hover_offset(
		controller.grid.cell_center(Vector2i(9, 21)))
	_check(controller._hover_rotation == 1,
		"el fantasma gira al escritorio aunque el cursor este mas lejos")
	_check(controller.place_object_item(
		chair, Vector2i(9, 21), 3, far_hover),
		"la silla se coloca una celda mas lejos")
	var far_chair: BuildPiece = null
	for piece in controller.get_objects():
		if piece.item_id == chair.id:
			far_chair = piece
	_check(far_chair != null and far_chair.object_rotation_steps == 1,
		"la silla igual queda girada hacia el escritorio")

	if _failures == 0:
		print("DESK_DOCK_OK")
		quit(0)
	else:
		printerr("DESK_DOCK_FAILED: ", _failures)
		quit(1)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("OK: ", message)
	else:
		_failures += 1
		printerr("FALLO: ", message)
