extends Node3D

## Configuración de SmartObjects para la demo de construcción.
##
## Activa los cerebros de los NPC presentes y les sube la necesidad de descanso
## para que busquen las sillas animadas colocadas en la escena.

## Si esta activo, repara la receta del Escritorio de trabajo cuando el guardado
## local de la construccion la perdio (el editor puede reescribirlo). Sin la
## banca o sin la silla del operador el objeto especial no se forma: la silla del
## operador queda como una silla comun y el medico no tiene donde trabajar.
@export var ensure_work_desk := false
## Si esta activo, asegura que la zona `consult` tenga al menos una silla `sit`
## dentro. Si no hay ninguna, coloca una silla de pacientes cerca del escritorio.
@export var ensure_consult_seat := false

const WORK_DESK_ID := &"work_desk"
const WORK_DESK_BASE_ITEM := &"furniture_desktop"
const WORK_DESK_PART_ITEM := "res://data/build_items/muebles/furniture_chair_desktop.tres"
const WORK_DESK_CLIENT_ITEM := "res://data/build_items/muebles/furniture_patient_chairs.tres"
## Celdas alrededor de la base que se prueban al reponer una pieza.
const WORK_DESK_REPAIR_RADIUS := 2


func _ready() -> void:
	# El hospital usa NavMesh sobre todo el mapa para que los spawner lejanos
	# (terreno, patio) sean caminables. Se fuerza aqui (y no solo en la escena)
	# para que persista aunque el editor re-serialize la escena.
	var nav := get_node_or_null("BuildSystem/BuildNavigation") as BuildNavigation
	if nav != null:
		nav.include_scene_geometry = true
	call_deferred("_setup_npcs")
	# Antes de hornear: si el guardado perdio la banca, se repone y recien
	# despues se calcula el NavMesh (un solo horneado).
	if ensure_work_desk:
		call_deferred("_ensure_work_desk")
	if ensure_consult_seat:
		call_deferred("_ensure_consult_seat")
	if nav != null:
		nav.call_deferred("bake_now")


func _setup_npcs() -> void:
	# Dar un par de frames para que los SmartObjects y el NavMesh estén listos.
	await get_tree().physics_frame
	await get_tree().physics_frame

	for node in _collect_npcs(self):
		var brain := node.get_node_or_null("NpcBrain") as NpcBrain
		if brain == null:
			continue
		node.wander = false
		# Los NPCs normales solo descansan en sillas. La silla del operador del
		# Escritorio de trabajo (`work`) esta reservada al medico.
		brain.needs = {"rest": randf_range(0.7, 1.0)}
		brain.need_growth = {"rest": 0.01}
		brain.need_affordances = {"rest": &"sit"}
		brain.need_threshold = 0.6
		brain.search_radius = 30.0
		brain.set_enabled(true)


func _collect_npcs(node: Node) -> Array[NpcAgent]:
	var result: Array[NpcAgent] = []
	if node is NpcAgent:
		result.append(node as NpcAgent)
	for child in node.get_children():
		result.append_array(_collect_npcs(child))
	return result


## Si el guardado local perdio piezas de la receta, el Escritorio de trabajo no
## se forma y el medico no tiene donde trabajar. Reponemos la silla del
## operador y, si hace falta, la banca de pacientes hasta que la receta cierre.
func _ensure_work_desk() -> void:
	var controller := get_node_or_null("BuildSystem/BuildController") as BuildController
	if controller == null:
		return
	if _has_work_desk(controller):
		return
	var base := _find_work_desk_base(controller)
	if base == null:
		push_warning("BuildDemo: no hay un escritorio base para el Escritorio de trabajo.")
		return
	var part := load(WORK_DESK_PART_ITEM) as BuildItem
	var client := load(WORK_DESK_CLIENT_ITEM) as BuildItem
	# 1) Si el guardado conservo una banca valida, alcanza con la silla del
	#    operador.
	if part != null and _try_place_until_formed(controller, base, part, "silla del operador"):
		return
	# 2) Si tambien falta la banca, se coloca una y con ella se busca la silla.
	if part != null and client != null and _try_client_then_part(controller, base, client, part):
		return
	push_warning("BuildDemo: no se pudo reparar el Escritorio de trabajo.")


## Prueba cada celda/rotacion de la banca; con la banca puesta busca la silla
## del operador. Si la pareja no cierra la receta, deshace todo y sigue.
func _try_client_then_part(
	controller: BuildController, base: BuildPiece, client: BuildItem, part: BuildItem
) -> bool:
	var base_cell := base.cell
	var before := _piece_ids(controller)
	for dy in range(-WORK_DESK_REPAIR_RADIUS, WORK_DESK_REPAIR_RADIUS + 1):
		for dx in range(-WORK_DESK_REPAIR_RADIUS, WORK_DESK_REPAIR_RADIUS + 1):
			var cell := base_cell + Vector2i(dx, dy)
			for rot in 4:
				if not controller.place_object_item(client, cell, rot):
					continue
				if _has_work_desk(controller) or _try_place_until_formed(
						controller, base, part, "silla del operador"):
					if OS.is_debug_build():
						print("[BuildDemo] Repuesta la banca y la silla del Escritorio de trabajo.")
					return true
				_erase_new_pieces(controller, before)
				before = _piece_ids(controller)
	return false


func _find_work_desk_base(controller: BuildController) -> BuildPiece:
	for piece in controller.get_objects():
		if piece != null and piece.item_id == WORK_DESK_BASE_ITEM:
			return piece
	return null


## Prueba colocar `item` alrededor de la base hasta que la receta cierre. Si una
## colocacion no forma el conjunto, se deshace antes de probar la siguiente.
func _try_place_until_formed(
	controller: BuildController, base: BuildPiece, item: BuildItem, label: String
) -> bool:
	var base_cell := base.cell
	var before := _piece_ids(controller)
	for dy in range(-WORK_DESK_REPAIR_RADIUS, WORK_DESK_REPAIR_RADIUS + 1):
		for dx in range(-WORK_DESK_REPAIR_RADIUS, WORK_DESK_REPAIR_RADIUS + 1):
			var cell := base_cell + Vector2i(dx, dy)
			for rot in 4:
				if not controller.place_object_item(item, cell, rot):
					continue
				if _has_work_desk(controller):
					if OS.is_debug_build():
						print("[BuildDemo] Repuesta la %s del Escritorio de trabajo en %s." % [
							label, cell])
					return true
				_erase_new_pieces(controller, before)
				before = _piece_ids(controller)
	return false


func _piece_ids(controller: BuildController) -> Dictionary:
	var ids := {}
	for piece in controller.get_objects():
		if piece != null and is_instance_valid(piece):
			ids[piece.get_instance_id()] = true
	return ids


## Borra solo las piezas que aparecieron despues de `before`.
func _erase_new_pieces(controller: BuildController, before: Dictionary) -> void:
	for piece in controller.get_objects():
		if piece == null or not is_instance_valid(piece):
			continue
		if before.has(piece.get_instance_id()):
			continue
		controller.erase_at(piece.cell, Vector3i.ZERO, BuildController.EraseKind.OBJECT)


func _has_work_desk(controller: BuildController) -> bool:
	for special in controller.get_special_objects():
		if special.get_special_id() == WORK_DESK_ID:
			return true
	return false


## Si la zona `consult` no tiene ninguna silla `sit`, agrega una silla de
## pacientes cerca del escritorio para que el medico pueda atender.
func _ensure_consult_seat() -> void:
	var controller := get_node_or_null("BuildSystem/BuildController") as BuildController
	if controller == null:
		return
	var zones := controller.get_zone_ids_of_type(&"consult")
	if zones.is_empty() or _has_consult_seat(controller, zones):
		return
	var special := _find_work_desk_special(controller)
	if special == null:
		return
	var parts := special.get_parts()
	if parts.is_empty():
		return
	var base := parts[0]
	var item := load(WORK_DESK_CLIENT_ITEM) as BuildItem
	if item == null:
		return
	var before := _piece_ids(controller)
	for dy in range(-WORK_DESK_REPAIR_RADIUS, WORK_DESK_REPAIR_RADIUS + 1):
		for dx in range(-WORK_DESK_REPAIR_RADIUS, WORK_DESK_REPAIR_RADIUS + 1):
			var cell := base.cell + Vector2i(dx, dy)
			if controller.get_zone_type_at_world(
					controller.grid.cell_center(cell)) != &"consult":
				continue
			for rot in 4:
				if not controller.place_object_item(item, cell, rot):
					continue
				if _has_consult_seat(controller, zones):
					if OS.is_debug_build():
						print("[BuildDemo] Repuesta una silla de consultorio en ", cell)
					return
				_erase_new_pieces(controller, before)
				before = _piece_ids(controller)


func _find_work_desk_special(controller: BuildController) -> SpecialObject:
	for special in controller.get_special_objects():
		if special.get_special_id() == WORK_DESK_ID:
			return special
	return null


func _has_consult_seat(
	controller: BuildController, zones: Array[StringName]
) -> bool:
	for obj in SmartObjectRegistry.get_objects():
		if obj == null or not is_instance_valid(obj):
			continue
		if not obj.has_affordance(&"sit"):
			continue
		for slot in obj.get_slot_count():
			if not obj.slot_has_affordance(slot, &"sit"):
				continue
			if zones.has(controller.get_zone_id_at_world(obj.get_use_position(slot))):
				return true
	return false
