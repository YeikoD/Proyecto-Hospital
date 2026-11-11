class_name BuildController
extends Node3D

## Modo construccion estilo Sims (version basica).
##
## B toggle  |  1 suelo  |  2 pared  |  3 borrar  |  Esc salir
## Clic izquierdo coloca (y se puede arrastrar para pintar varias celdas).
##
## La grilla y la camara se resuelven automaticamente si no se asignan en el
## inspector, asi que basta con anadir `scripts/sistemas/build/build_system.tscn` a una escena
## que tenga un FPSPlayer.

enum Tool { FLOOR, WALL, OBJECT, ERASE }

## Se emite cuando cambia el conjunto de piezas colocadas (colocar, borrar o
## limpiar). La navegación lo usa para rehornear el NavMesh con debounce.
signal pieces_changed
## Se emite al colocar / borrar un SmartObject (muebles, props interactivos).
signal object_placed(object: Node)
signal object_removed(object: Node)

const FLOOR_PREFAB := preload("res://scripts/sistemas/build/prefabs/floor_tile.tscn")
const WALL_PREFAB := preload("res://scripts/sistemas/build/prefabs/wall_segment.tscn")
const COLOR_OK := Color(0.25, 1.0, 0.6, 0.35)
const COLOR_BAD := Color(1.0, 0.3, 0.25, 0.42)
const COLOR_ERASE := Color(1.0, 0.45, 0.2, 0.5)

@export var grid: BuildGrid
@export var build_camera: BuildCamera
@export var player: FPSController
@export var pieces_root: Node3D
@export var floor_scene: PackedScene = FLOOR_PREFAB
@export var wall_scene: PackedScene = WALL_PREFAB
@export var build_menu: BuildMenu
@export var items_dir: String = "res://data/build_items"

@export_group("Dimensiones")
@export var floor_thickness := 0.1
@export var wall_height := 2.8
@export var wall_thickness := 0.2

@export_group("Objetos")
## Si un objeto (mueble/prop) solo puede colocarse sobre un suelo construido.
@export var require_floor_for_objects := true
## Desplazamiento vertical extra al colocar objetos (útil si el suelo visual
## queda unos centímetros por encima del plano de la grilla).
@export var object_height_offset := 0.03

@export_group("Interfaz")
@export var show_help := true
@export var start_in_build_mode := false

var build_mode := false
var tool: Tool = Tool.FLOOR

var _floors: Dictionary = {}
var _walls: Dictionary = {}
## Celda primaria -> pieza. Para objetos de varias celdas, `_object_cells`
## guarda todas las celdas cubiertas (y sirve para colisiones de huella).
var _objects: Dictionary = {}
var _object_cells: Dictionary = {}

var build_items: Array[BuildItem] = []
var selected_item: BuildItem
var _selected_object_item: BuildItem
## Rotación del objeto en pasos de 90 grados (0..3).
var _object_rotation := 0
var _active_map_file: String = ""

var _floor_ghost: MeshInstance3D
var _wall_ghost: MeshInstance3D
var _object_ghost: MeshInstance3D
var _ghost_material: StandardMaterial3D

var _hover_cell := Vector2i.ZERO
var _hover_wall := Vector3i.ZERO
var _hovering := false
var _painting := false
var _wall_dragging := false
var _wall_drag_start := Vector3i.ZERO
var _wall_drag_start_cell := Vector2i.ZERO
var _wall_drag_ghosts: Array[MeshInstance3D] = []
var _corner_scene_cache: Dictionary = {}
## Modelos de esquina del muro activo: "IZQ"/"DER" -> PackedScene.
var _corner_scenes: Dictionary = {}
## Mallas de esquina recortadas (clave: malla + modelo + limite) -> ArrayMesh.
var _corner_trim_cache: Dictionary = {}
## Huella de cada modelo de esquina en el espacio de la pieza.
var _corner_footprint_cache: Dictionary = {}
## Esquinas visuales activas: clave de la pared duena -> BuildPiece.
var _corner_pieces: Dictionary = {}
## Paredes tapadas por una esquina (se ocultan, pero conservan su colision).
var _hidden_walls: Dictionary = {}
## Pared duena -> datos de su esquina (modelo, rotacion, posicion).
var _wall_corner_path: Dictionary = {}
var _wall_model_thickness_cache := -1.0

var _player_camera: Camera3D
var _camera_framed := false

var _ui_layer: CanvasLayer
var _ui_title: Label
var _ui_tool: Label
## Avisos breves (guardado/carga). Se muestran siempre, esté o no activo el
## modo construcción, para que el jugador tenga feedback inmediato.
var _message_layer: CanvasLayer
var _ui_message: Label


func _ready() -> void:
	BuildInput.ensure_actions()
	_resolve_references()
	_load_build_items()
	_wire_build_menu()
	_create_ghosts()
	_create_ui()

	if grid != null:
		grid.visible = false
	if _ui_layer != null:
		_ui_layer.visible = false
	set_process(false)

	call_deferred("load_construction")

	if start_in_build_mode:
		enter_build_mode()


# --------------------------------------------------------------------------
# Modo construccion
# --------------------------------------------------------------------------

func enter_build_mode() -> void:
	if build_mode:
		return
	if grid == null:
		push_warning("BuildController: falta la grilla (BuildGrid).")
		return

	if player == null:
		player = _find_player(get_tree().current_scene)
	if player == null:
		player = _find_player(get_tree().root)

	_player_camera = get_viewport().get_camera_3d()
	if _player_camera == null and player != null:
		_player_camera = _find_camera(player)

	build_mode = true
	set_process(true)

	if player != null:
		player.set_physics_process(false)
		player.set_process_unhandled_input(false)

	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	if build_camera == null:
		build_camera = _find_build_camera(get_tree().current_scene)
	if build_camera != null:
		if not _camera_framed:
			var side := maxf(grid.cells_x, grid.cells_z) * grid.cell_size
			build_camera.frame_grid(grid.center_point(), side)
			_camera_framed = true
		build_camera.current = true

	grid.visible = true
	if build_menu != null:
		build_menu.visible = true
	_update_ui()


func exit_build_mode() -> void:
	if not build_mode:
		return

	build_mode = false
	set_process(false)
	_painting = false
	_hovering = false
	_clear_wall_drag_ghosts()
	_wall_dragging = false
	_hide_ghosts()

	if build_camera != null:
		build_camera.current = false
	if grid != null:
		grid.visible = false
	if _ui_layer != null:
		_ui_layer.visible = false
	if build_menu != null:
		build_menu.visible = false

	if _player_camera != null and is_instance_valid(_player_camera):
		_player_camera.current = true

	if player != null:
		player.set_physics_process(true)
		player.set_process_unhandled_input(true)

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func set_tool(new_tool: Tool) -> void:
	tool = new_tool
	_update_ui()


# --------------------------------------------------------------------------
# Entrada
# --------------------------------------------------------------------------

## El guardado se atiende en `_input` (antes que la UI y que el resto del
## juego) para que ningún otro nodo pueda consumir la tecla.
func _input(event: InputEvent) -> void:
	if event is InputEventKey and _is_save_key(event as InputEventKey):
		save_construction()
		get_viewport().set_input_as_handled()


## Teclas aceptadas para guardar: `°`, `º`, `ª`, la acción `build_save` o
## `Ctrl+S` (atajo alternativo por si la distribución del teclado no genera `°`).
func _is_save_key(key_event: InputEventKey) -> bool:
	if not key_event.pressed or key_event.echo:
		return false
	if key_event.ctrl_pressed and not key_event.alt_pressed and key_event.keycode == KEY_S:
		return true
	if key_event.is_action_pressed("build_save"):
		return true
	var u := key_event.unicode
	if u == 176 or u == 186 or u == 170:
		return true
	var label := key_event.as_text_key_label()
	return label == "°" or label == "º" or label == "ª"


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("build_toggle"):
		if build_mode:
			exit_build_mode()
		else:
			enter_build_mode()
		get_viewport().set_input_as_handled()
		return

	if not build_mode:
		return

	if event.is_action_pressed("ui_cancel"):
		exit_build_mode()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("build_tool_floor"):
		set_tool(Tool.FLOOR)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("build_tool_wall"):
		set_tool(Tool.WALL)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("build_tool_erase"):
		set_tool(Tool.ERASE)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("build_rotate") and tool == Tool.OBJECT:
		rotate_object()
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if not build_mode:
		return

	_hovering = _update_hover()

	# Permitir terminar un arrastre de paredes aunque el cursor salga de la grilla.
	if tool == Tool.WALL and _wall_dragging:
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			if _hovering:
				_update_wall_drag()
		else:
			_finish_wall_drag()
			_hide_ghosts()
			_update_ui()
			return

	if not _hovering:
		_painting = false
		_hide_ghosts()
		_update_ui()
		return

	if tool == Tool.WALL:
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			if not _wall_dragging:
				_start_wall_drag()
			if _wall_dragging:
				_update_wall_drag()
	elif tool == Tool.OBJECT:
		# Un clic = un objeto. Arrastrar no debe llenar la sala de muebles.
		# Ignorar clics sobre la UI (menú de items).
		var pressed := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		var over_ui := get_viewport().gui_get_hovered_control() != null
		if pressed and not _painting and not over_ui:
			_apply_tool()
		_painting = pressed
	else:
		_painting = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		if _painting:
			_apply_tool()

	_update_ghosts()
	_update_ui()


# --------------------------------------------------------------------------
# Colocacion
# --------------------------------------------------------------------------

func get_floor_count() -> int:
	return _floors.size()


func get_wall_count() -> int:
	return _walls.size()


func get_object_count() -> int:
	return _objects.size()


## Objeto colocado cuya huella cubre `cell` (o null).
func get_object_at(cell: Vector2i) -> BuildPiece:
	if not _object_cells.has(cell):
		return null
	var piece = _object_cells[cell]
	return piece as BuildPiece


func get_objects() -> Array[BuildPiece]:
	var out: Array[BuildPiece] = []
	for piece in _objects.values():
		if is_instance_valid(piece):
			out.append(piece as BuildPiece)
	return out


## Rota el objeto seleccionado 90 grados (para la herramienta OBJECT).
func rotate_object() -> void:
	_object_rotation = (_object_rotation + 1) % 4
	_update_ui()


func clear_all() -> void:
	var had_pieces := not _floors.is_empty() or not _walls.is_empty() \
		or not _objects.is_empty()
	_clear_corner_pieces()
	_wall_corner_path.clear()
	_hidden_walls.clear()
	for piece: Node in _floors.values():
		piece.queue_free()
	for piece: Node in _walls.values():
		piece.queue_free()
	for piece: Node in _objects.values():
		piece.queue_free()
	_floors.clear()
	_walls.clear()
	_objects.clear()
	_object_cells.clear()
	if had_pieces:
		pieces_changed.emit()


## Coloca un suelo por API (misma validación que la herramienta).
func place_floor(cell: Vector2i) -> bool:
	return _place_floor(cell)


## Coloca una pared por API (misma validación que la herramienta).
func place_wall(key: Vector3i) -> bool:
	return _place_wall(key)


## Coloca el objeto seleccionado por API. `rotation_steps` = cuartos de vuelta.
func place_object(cell: Vector2i, rotation_steps: int = -1) -> bool:
	if _selected_object_item == null:
		return false
	var steps := _object_rotation if rotation_steps < 0 else rotation_steps
	return _place_object(cell, _selected_object_item, steps)


## Coloca un BuildItem de tipo objeto concreto (útil para tests y scripts).
func place_object_item(
	item: BuildItem,
	cell: Vector2i,
	rotation_steps: int = 0
) -> bool:
	return _place_object(cell, item, rotation_steps)


## Borra por API respetando la prioridad de la herramienta (pared, luego suelo).
func erase_at(cell: Vector2i, wall: Vector3i) -> bool:
	return _erase_at(cell, wall)


func _apply_tool() -> void:
	match tool:
		Tool.FLOOR:
			_place_floor(_hover_cell)
		Tool.WALL:
			_place_wall(_hover_wall)
		Tool.OBJECT:
			if _selected_object_item != null:
				_place_object(_hover_cell, _selected_object_item, _object_rotation)
		Tool.ERASE:
			_erase_at(_hover_cell, _hover_wall)


func _can_place_floor(cell: Vector2i) -> bool:
	return grid.is_cell_inside(cell) and not _floors.has(cell)


func _can_place_wall(key: Vector3i) -> bool:
	return grid.is_wall_inside(key) and not _walls.has(key)


func _can_place_object(cell: Vector2i, item: BuildItem) -> bool:
	if item == null or item.scene == null:
		return false
	var footprint := Vector2i(maxi(item.footprint.x, 1), maxi(item.footprint.y, 1))
	for dx in footprint.x:
		for dz in footprint.y:
			var c := cell + Vector2i(dx, dz)
			if not grid.is_cell_inside(c):
				return false
			if _object_cells.has(c):
				return false
			if require_floor_for_objects and not _floors.has(c):
				return false
	return true


## Instancia un objeto (mueble/prop). La raíz de la escena puede ser un
## SmartObject; si no lo es, `_spawn_piece` la envuelve en un BuildPiece.
func _place_object(cell: Vector2i, item: BuildItem, rotation_steps: int) -> bool:
	if not _can_place_object(cell, item):
		return false

	var piece := _spawn_piece(item.scene)
	if piece == null:
		return false

	if piece is SmartObject:
		var smart := piece as SmartObject
		if smart.definition == null and item.smart_object != null:
			smart.definition = item.smart_object

	var steps := wrapi(rotation_steps, 0, 4)
	var yaw := float(steps) * PI * 0.5
	piece.is_wall = false
	piece.cell = cell
	piece.item_id = item.id
	piece.object_rotation_steps = steps
	piece.name = "Object_%s_%d_%d" % [String(item.id), cell.x, cell.y]
	piece.global_position = grid.cell_center(cell) + Vector3.UP * object_height_offset
	piece.global_rotation = Vector3(0.0, yaw, 0.0)

	var footprint := Vector2i(maxi(item.footprint.x, 1), maxi(item.footprint.y, 1))
	for dx in footprint.x:
		for dz in footprint.y:
			_object_cells[cell + Vector2i(dx, dz)] = piece
	_objects[cell] = piece

	object_placed.emit(piece)
	pieces_changed.emit()
	return true


func _place_floor(cell: Vector2i) -> bool:
	if not _can_place_floor(cell):
		return false

	var piece := _spawn_current_piece()
	if piece == null:
		return false

	piece.is_wall = false
	piece.cell = cell
	piece.item_id = _current_item_id("floor")
	piece.name = "Floor_%d_%d" % [cell.x, cell.y]
	var floor_mi := piece.get_node_or_null("MeshInstance3D") as MeshInstance3D
	if floor_mi != null:
		piece.global_position = grid.cell_center(cell) - Vector3.UP * (floor_thickness * 0.5)
	else:
		piece.global_position = grid.cell_center(cell)
	piece.set_dimensions(Vector3(grid.cell_size, floor_thickness, grid.cell_size))
	_floors[cell] = piece
	pieces_changed.emit()
	return true


func _place_wall(key: Vector3i) -> bool:
	if not _place_wall_silent(key):
		return false
	_refresh_wall_variants()
	_refresh_wall_shapes()
	pieces_changed.emit()
	return true


func _place_wall_silent(key: Vector3i) -> bool:
	if not _can_place_wall(key):
		return false
	return _spawn_wall_piece(key) != null


# --------------------------------------------------------------------------
# Arrastre de paredes (estilo Sims): clic y arrastrar para crear varios tramos.
# --------------------------------------------------------------------------

func _start_wall_drag() -> void:
	if not _hovering:
		return
	_wall_dragging = true
	_wall_drag_start = _hover_wall
	_wall_drag_start_cell = _hover_cell


func _update_wall_drag() -> void:
	if not _hovering:
		return
	_rebuild_wall_drag_ghosts()


func _wall_drag_segment_keys() -> Array[Vector3i]:
	var keys: Array[Vector3i] = []
	if not _wall_dragging:
		return keys

	# El eje queda fijado por la pared sobre la que se hizo el primer clic.
	# Vector3i(x, z, axis): .z es el eje (0 vertical, 1 horizontal).
	var axis := _wall_drag_start.z

	if axis == 1:
		# Pared horizontal: z fijo (frontera), x varia por celdas.
		var fixed_z := _wall_drag_start.y
		var x_min := mini(_wall_drag_start.x, _hover_cell.x)
		var x_max := maxi(_wall_drag_start.x, _hover_cell.x)
		for x in range(x_min, x_max + 1):
			var key := Vector3i(x, fixed_z, 1)
			if grid.is_wall_inside(key):
				keys.append(key)
	else:
		# Pared vertical: x fijo (frontera), z varia por celdas.
		var fixed_x := _wall_drag_start.x
		var z_min := mini(_wall_drag_start.y, _hover_cell.y)
		var z_max := maxi(_wall_drag_start.y, _hover_cell.y)
		for z in range(z_min, z_max + 1):
			var key := Vector3i(fixed_x, z, 0)
			if grid.is_wall_inside(key):
				keys.append(key)

	return keys


func _rebuild_wall_drag_ghosts() -> void:
	_clear_wall_drag_ghosts()
	for key in _wall_drag_segment_keys():
		var ghost := MeshInstance3D.new()
		ghost.name = "WallDragGhost"
		var box := BoxMesh.new()
		box.size = Vector3(grid.cell_size * 0.98, wall_height, wall_thickness * 0.7)
		ghost.mesh = box
		ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		if _can_place_wall(key):
			mat.albedo_color = COLOR_OK
		else:
			mat.albedo_color = COLOR_BAD
		ghost.material_override = mat
		ghost.global_transform = Transform3D(
			Basis(Vector3.UP, grid.wall_yaw(key)),
			grid.wall_center(key) + Vector3.UP * (wall_height * 0.5)
		)
		add_child(ghost)
		_wall_drag_ghosts.append(ghost)


func _clear_wall_drag_ghosts() -> void:
	for ghost in _wall_drag_ghosts:
		if is_instance_valid(ghost):
			ghost.queue_free()
	_wall_drag_ghosts.clear()


func _finish_wall_drag() -> void:
	var placed := false
	for key in _wall_drag_segment_keys():
		if _place_wall_silent(key):
			placed = true
	if placed:
		_refresh_wall_variants()
		_refresh_wall_shapes()
		pieces_changed.emit()
	_clear_wall_drag_ghosts()
	_wall_dragging = false


func _erase_at(cell: Vector2i, wall: Vector3i) -> bool:
	if _object_cells.has(cell):
		_erase_object_at(cell)
		pieces_changed.emit()
		return true
	if _walls.has(wall):
		_remove(_walls, wall)
		_refresh_wall_variants()
		_refresh_wall_shapes()
		pieces_changed.emit()
		return true
	if _floors.has(cell):
		_remove(_floors, cell)
		pieces_changed.emit()
		return true
	return false


func _erase_object_at(cell: Vector2i) -> void:
	if not _object_cells.has(cell):
		return
	var piece = _object_cells[cell]

	# Quitar todas las celdas cubiertas y la entrada primaria.
	for c in _object_cells.keys():
		if _object_cells[c] == piece:
			_object_cells.erase(c)
	for c in _objects.keys():
		if _objects[c] == piece:
			_objects.erase(c)

	if is_instance_valid(piece):
		if piece is SmartObject:
			(piece as SmartObject).release_all()
		object_removed.emit(piece)
		piece.queue_free()


func _remove(collection: Dictionary, key: Variant) -> void:
	var piece: Node = collection.get(key)
	if piece != null:
		piece.queue_free()
	collection.erase(key)


func _load_build_items() -> void:
	build_items = BuildItemLoader.load_items(items_dir)
	if build_menu != null:
		build_menu.reload_items(items_dir)
	# Seleccionar un item por defecto para no romper el flujo clásico.
	if selected_item == null:
		for item in build_items:
			if item.object_type in ["floor", "suelo"]:
				selected_item = item
				break
		if selected_item == null and not build_items.is_empty():
			selected_item = build_items[0]
	_apply_selected_item()


func _wire_build_menu() -> void:
	if build_menu == null:
		return
	if not build_menu.item_selected.is_connected(_on_build_item_selected):
		build_menu.item_selected.connect(_on_build_item_selected)


func _on_build_item_selected(item: BuildItem) -> void:
	selected_item = item
	_apply_selected_item()


func _apply_selected_item() -> void:
	if selected_item == null:
		return
	var scene := selected_item.scene
	_active_map_file = selected_item.map_file
	_selected_object_item = null
	match selected_item.object_type:
		"floor", "suelo":
			tool = Tool.FLOOR
			if scene != null:
				floor_scene = scene
		"wall", "pared":
			tool = Tool.WALL
			if scene != null:
				wall_scene = scene
				_wall_model_thickness_cache = -1.0
				_corner_scene_cache.clear()
				_corner_trim_cache.clear()
				_corner_footprint_cache.clear()
		"furniture", "prop", "mueble", "objeto":
			tool = Tool.OBJECT
			_selected_object_item = selected_item
		_:
			# Tipos aún no colocables (techo, aberturas, ...).
			pass
	_update_ui()


## Id del item que corresponde a la pieza que se va a instanciar. Se deduce
## de la escena/mapa activos para que el guardado no dependa de cuál sea el
## último item seleccionado en el menú.
func _current_item_id(kind: String) -> StringName:
	var types := ["floor", "suelo"] if kind == "floor" else ["wall", "pared"]
	if _active_map_file != "":
		for item in build_items:
			if item.map_file == _active_map_file:
				return item.id
	var scene: PackedScene = floor_scene if kind == "floor" else wall_scene
	if scene != null:
		for item in build_items:
			if item.object_type in types and item.scene == scene:
				return item.id
	if selected_item != null and selected_item.object_type in types:
		return selected_item.id
	return &""


func _find_build_menu(node: Node) -> BuildMenu:
	if node == null:
		return null
	if node is BuildMenu:
		return node as BuildMenu
	for child in node.get_children():
		var found := _find_build_menu(child)
		if found != null:
			return found
	return null

# --------------------------------------------------------------------------
# Recorte dinamico de paredes: evita solapamientos en esquinas.
# --------------------------------------------------------------------------

func _has_perp_neighbor(key: Vector3i, end: int) -> bool:
	var axis := key.z
	if axis == 1:
		# Pared horizontal: extremos en x y x+1, frontera z = key.y
		var bx := key.x if end == 0 else key.x + 1
		var bz_boundary := key.y
		for k in [bz_boundary - 1, bz_boundary]:
			if k < 0 or k >= grid.cells_z:
				continue
			if _walls.has(Vector3i(bx, k, 0)):
				return true
	else:
		# Pared vertical: extremos en z y z+1, frontera x = key.x
		var bz := key.y if end == 0 else key.y + 1
		var bx_boundary := key.x
		for k in [bx_boundary - 1, bx_boundary]:
			if k < 0 or k >= grid.cells_x:
				continue
			if _walls.has(Vector3i(k, bz, 1)):
				return true
	return false


func _refresh_wall_shapes() -> void:
	if grid == null:
		return
	# Los modelos importados no se redimensionan: su posicion ya la fija
	# _spawn_wall_piece. Solo las cajas procedurales se recortan en las
	# uniones que no llevan pieza de esquina.
	for key in _walls.keys():
		var piece: BuildPiece = _walls[key]
		if not is_instance_valid(piece):
			continue
		var piece_mi := piece.get_node_or_null("MeshInstance3D") as MeshInstance3D
		if piece_mi == null or not (piece_mi.mesh is BoxMesh):
			continue
		var trim := wall_thickness * 0.5
		var has_left := _has_perp_neighbor(key, 0)
		var has_right := _has_perp_neighbor(key, 1)
		var length := grid.cell_size
		var offset := 0.0
		if has_left:
			length -= trim
			offset += trim * 0.5
		if has_right:
			length -= trim
			offset -= trim * 0.5
		if length < 0.05:
			length = 0.05
		piece.set_dimensions(Vector3(length, wall_height, wall_thickness))
		var center := grid.wall_center(key)
		if key.z == 1:
			piece.global_position = center + Vector3(offset, wall_height * 0.5, 0.0)
		else:
			piece.global_position = center + Vector3(0.0, wall_height * 0.5, offset)
		piece.global_rotation = Vector3(0.0, grid.wall_yaw(key), 0.0)


## Crea la pieza fisica de una pared (siempre el muro normal, con colision).
## La esquina, si toca, se anade aparte como pieza puramente visual.
func _spawn_wall_piece(key: Vector3i, keep_item_id: StringName = &"") -> BuildPiece:
	var piece: BuildPiece
	if _active_map_file != "":
		piece = _spawn_map_piece(_active_map_file)
	else:
		piece = _spawn_piece(wall_scene)
	if piece == null:
		return null

	piece.is_wall = true
	piece.wall_key = key
	piece.item_id = keep_item_id if keep_item_id != &"" else _current_item_id("wall")
	piece.name = "Wall_%d_%d_%d" % [key.x, key.y, key.z]
	piece.set_dimensions(Vector3(grid.cell_size, wall_height, wall_thickness))
	var piece_mi := piece.get_node_or_null("MeshInstance3D") as MeshInstance3D
	if piece_mi != null:
		piece.global_position = grid.wall_center(key) + Vector3.UP * (wall_height * 0.5)
	else:
		piece.global_position = grid.wall_center(key)
	piece.global_rotation = Vector3(0.0, grid.wall_yaw(key), 0.0)
	_walls[key] = piece
	return piece


func _load_corner_scene(path: String) -> PackedScene:
	if _corner_scene_cache.has(path):
		return _corner_scene_cache[path] as PackedScene
	var res := load(path)
	if res is PackedScene:
		_corner_scene_cache[path] = res
		return res as PackedScene
	_corner_scene_cache[path] = null
	return null


func _find_mesh_instance(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node as MeshInstance3D
	for child in node.get_children():
		var found := _find_mesh_instance(child)
		if found != null:
			return found
	return null


## Ruta de los modelos de esquina derivada del muro actual. Si el muro no
## tiene variantes _IZQ/_DER, no se usan esquinas.
func _corner_model_paths() -> Dictionary:
	if wall_scene == null or _active_map_file != "":
		return {}
	var path := wall_scene.resource_path
	if path.get_extension() != "blend":
		return {}
	var base := path.get_basename()
	var izq := "%s_IZQ.blend" % base
	var der := "%s_DER.blend" % base
	if not ResourceLoader.exists(izq) or not ResourceLoader.exists(der):
		return {}
	return {"IZQ": izq, "DER": der}


## Modelos de esquina a usar. Primero manda lo asignado en el item
## (`corner_left` / `corner_right`); lo que falte se busca por convencion de
## nombre junto al modelo de la pared.
func _resolve_corner_scenes() -> Dictionary:
	var scenes := {}
	if selected_item != null:
		if selected_item.corner_left != null:
			scenes["IZQ"] = selected_item.corner_left
		if selected_item.corner_right != null:
			scenes["DER"] = selected_item.corner_right
	if scenes.size() == 2:
		return scenes
	var paths := _corner_model_paths()
	for model_name in paths.keys():
		if scenes.has(model_name):
			continue
		var loaded := _load_corner_scene(paths[model_name])
		if loaded != null:
			scenes[model_name] = loaded
	return scenes


## Grosor real del modelo de muro (no siempre coincide con wall_thickness).
func _wall_model_thickness() -> float:
	if _wall_model_thickness_cache > 0.0:
		return _wall_model_thickness_cache
	if wall_scene != null:
		var instance := wall_scene.instantiate()
		if instance is Node3D:
			var aabb := _compute_aabb(instance)
			if aabb.size.z > 0.001:
				_wall_model_thickness_cache = aabb.size.z
		instance.free()
	if _wall_model_thickness_cache <= 0.0:
		_wall_model_thickness_cache = wall_thickness
	return _wall_model_thickness_cache


## Huella del modelo de esquina en el espacio de la pieza (sin la rotacion de
## la pieza). Se acumulan las transformaciones a mano porque el nodo esta
## fuera del arbol y `global_transform` devolveria la identidad.
func _corner_footprint(model: String) -> AABB:
	var scene: PackedScene = _corner_scenes.get(model)
	if scene == null:
		return AABB()
	var key := "%d|%s" % [scene.get_instance_id(), model]
	if _corner_footprint_cache.has(key):
		return _corner_footprint_cache[key]
	var instance := scene.instantiate()
	var aabb := _compute_aabb(instance)
	instance.free()
	_corner_footprint_cache[key] = aabb
	return aabb


## Punto concavo del modelo (donde se juntan las caras interiores) en el
## espacio de la pieza sin rotar. Se deduce de la huella real, asi que sigue
## siendo valido aunque el modelo se mueva o se redimensione en Blender.
func _corner_inner_point(model: String) -> Vector2:
	var footprint := _corner_footprint(model)
	if footprint.size == Vector3.ZERO:
		return Vector2.ZERO
	var t := _wall_model_thickness()
	if model == "IZQ":
		# El brazo horizontal sale hacia -X: su cara interior es el extremo +X.
		return Vector2(footprint.end.x - t, footprint.position.z + t)
	return Vector2(footprint.position.x + t, footprint.position.z + t)


## Calcula que paredes forman esquina y con que modelo/rotacion. En cada
## esquina una pared se convierte en la pieza de esquina y la otra se oculta,
## de modo que nunca hay dos esquinas superpuestas.
func _rebuild_wall_corners() -> void:
	_wall_corner_path.clear()
	_hidden_walls.clear()
	# Los modelos pueden cambiar con el item seleccionado: resolver siempre.
	_corner_scenes = _resolve_corner_scenes()
	if grid == null or _corner_scenes.size() < 2:
		_corner_scenes.clear()
		return

	var candidates: Array[Dictionary] = []
	for key: Vector3i in _walls.keys():
		if key.z != 1:
			continue
		for end: int in [0, 1]:
			# Si el muro sigue recto, este vertice no es una L.
			var neighbor_x := key.x - 1 if end == 0 else key.x + 1
			if _walls.has(Vector3i(neighbor_x, key.y, 1)):
				continue
			var vx := key.x + end
			var hz := key.y
			var plus_key := Vector3i(vx, hz, 0)
			var minus_key := Vector3i(vx, hz - 1, 0)
			var has_plus := _walls.has(plus_key)
			var has_minus := _walls.has(minus_key)
			# Ninguna pared perpendicular (recta) o dos (cruz/T): no es L.
			if has_plus == has_minus:
				continue
			var quadrant := 0
			if end == 0 and has_plus:
				quadrant = 0 # +X, +Z
			elif end == 1 and has_plus:
				quadrant = 1 # -X, +Z
			elif end == 1 and has_minus:
				quadrant = 2 # -X, -Z
			else:
				quadrant = 3 # +X, -Z
			candidates.append({
				"h_key": key,
				"v_key": plus_key if has_plus else minus_key,
				"vertex": Vector2i(vx, hz),
				"quadrant": quadrant,
			})

	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var va: Vector2i = a.vertex
		var vb: Vector2i = b.vertex
		if va.x != vb.x:
			return va.x < vb.x
		return va.y < vb.y
	)

	# Cada esquina consume las dos paredes que se cruzan. Si una ya fue usada
	# por otra esquina, se deja como muro normal (ya queda tapada por ella).
	var used := {}
	for candidate in candidates:
		var h_key: Vector3i = candidate.h_key
		var v_key: Vector3i = candidate.v_key
		if used.has(h_key) or used.has(v_key):
			continue
		used[h_key] = true
		used[v_key] = true
		_wall_corner_path[h_key] = _make_corner_info(candidate)
		_hidden_walls[v_key] = true


func _make_corner_info(candidate: Dictionary) -> Dictionary:
	var quadrant: int = candidate.quadrant
	var model_name := "DER"
	var rotation := 0.0
	match quadrant:
		0:
			model_name = "DER"
			rotation = 0.0
		1:
			model_name = "IZQ"
			rotation = 0.0
		2:
			model_name = "DER"
			rotation = PI
		3:
			model_name = "IZQ"
			rotation = PI

	var vertex: Vector2i = candidate.vertex
	var thick := _wall_model_thickness()
	var half := wall_thickness * 0.5
	var bx := grid.global_position.x + vertex.x * grid.cell_size
	var bz := grid.global_position.z + vertex.y * grid.cell_size
	# Cara interior de los muros normales en ese cuadrante.
	var inner_x := bx + half - (thick if quadrant in [1, 2] else 0.0)
	var inner_z := bz + half - (thick if quadrant in [2, 3] else 0.0)
	# Punto concavo del modelo, rotado igual que la pieza, para que el modelo
	# quede apoyado en las caras interiores reales.
	var inner := _corner_inner_point(model_name).rotated(rotation)
	var position := Vector3(
		inner_x - inner.x,
		grid.plane_global_y(),
		inner_z - inner.y
	)
	# Extremo libre de cada brazo medido en mundo: el borde de la celda que
	# cierra la L. Recortar contra este valor absoluto (y no contra la AABB
	# del modelo) evita que cualquier desfase del modelo vuelva a solaparse.
	var far_x := grid.global_position.x + float(vertex.x + (1 if quadrant in [0, 3] else -1)) * grid.cell_size
	var far_z := grid.global_position.z + float(vertex.y + (1 if quadrant in [0, 1] else -1)) * grid.cell_size
	return {
		"model": model_name,
		"rotation": rotation,
		"position": position,
		"target_x": far_x,
		"target_z": far_z,
		"vertex": vertex,
		"owner_key": candidate.h_key,
		"covered_key": candidate.v_key,
	}


func _clear_corner_pieces() -> void:
	for piece in _corner_pieces.values():
		if is_instance_valid(piece):
			piece.queue_free()
	_corner_pieces.clear()


## Recorta el extremo libre de los brazos del modelo de esquina para que
## termine justo en el borde de la celda. Sin esto el brazo (una celda mas el
## espesor de la pared) se mete unos centimetros en la pared contigua y las
## dos mallas coplanares producen z-fighting de texturas.
##
## `limit_x` / `limit_z` estan en el espacio de la pieza y salen del borde de
## celda absoluto, no de la AABB del modelo: asi el recorte sigue siendo exacto
## aunque el modelo se mueva o cambie de tamano en Blender.
func _trimmed_corner_mesh(
	mesh_instance: MeshInstance3D,
	piece: Node3D,
	model: String,
	limit_x: float,
	limit_z: float
) -> Mesh:
	var source := mesh_instance.mesh
	if source == null:
		return null
	var key := "%d|%s|%.4f|%.4f" % [source.get_instance_id(), model, limit_x, limit_z]
	if _corner_trim_cache.has(key):
		return _corner_trim_cache[key]

	# Transformacion del mesh respecto de la raiz de la pieza (el nodo
	# importado puede traer su propia rotacion/offset).
	var xform := _relative_transform(piece, mesh_instance)
	var xform_inverse := xform.affine_inverse()
	var clamp_x_min := model != "IZQ"

	var trimmed := ArrayMesh.new()
	trimmed.resource_name = source.resource_name
	for s in range(source.get_surface_count()):
		var arrays := source.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for i in range(verts.size()):
			var p := xform * verts[i]
			p.x = minf(p.x, limit_x) if clamp_x_min else maxf(p.x, limit_x)
			p.z = minf(p.z, limit_z)
			verts[i] = xform_inverse * p
		arrays[Mesh.ARRAY_VERTEX] = verts
		trimmed.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mat := source.surface_get_material(s)
		if mat != null:
			trimmed.surface_set_material(trimmed.get_surface_count() - 1, mat)
	_corner_trim_cache[key] = trimmed
	return trimmed


## Transformacion de `node` relativa a `root`, sin usar transformaciones
## globales (los nodos importados se miden antes de entrar al arbol).
static func _relative_transform(root: Node, node: Node) -> Transform3D:
	var chain: Array[Node] = []
	var current := node
	while current != null and current != root:
		chain.append(current)
		current = current.get_parent()
	var xform := Transform3D.IDENTITY
	for i in range(chain.size() - 1, -1, -1):
		if chain[i] is Node3D:
			xform = xform * (chain[i] as Node3D).transform
	return xform


func _spawn_corner_visual(info: Dictionary) -> void:
	var model: String = info.get("model", "DER")
	var scene: PackedScene = _corner_scenes.get(model)
	if scene == null:
		return
	var piece := _spawn_piece(scene, false)
	if piece == null:
		return
	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(piece, meshes)
	if not meshes.is_empty():
		var rotation: float = info.get("rotation", 0.0)
		var position: Vector3 = info.position
		# La pieza se rota 0 o PI: pasar el borde de celda de mundo al espacio
		# local invierte el signo cuando la pieza esta girada.
		var sign := -1.0 if rotation > 1.0 else 1.0
		var limit_x := (float(info.target_x) - position.x) * sign
		var limit_z := (float(info.target_z) - position.z) * sign
		# El modelo puede venir dividido en varias mallas (una por material u
		# objeto de Blender): hay que recortarlas todas, no solo la primera.
		for mesh_instance in meshes:
			mesh_instance.mesh = _trimmed_corner_mesh(mesh_instance, piece, model, limit_x, limit_z)
	var vertex: Vector2i = info.vertex
	piece.name = "WallCorner_%d_%d" % [vertex.x, vertex.y]
	piece.is_wall = true
	piece.global_transform = Transform3D(
		Basis(Vector3.UP, info.rotation),
		info.position
	)
	_corner_pieces[info.owner_key] = piece


func _refresh_wall_variants() -> void:
	if grid == null:
		return
	_clear_corner_pieces()
	_rebuild_wall_corners()

	var keys := _walls.keys().duplicate()
	for key in keys:
		var old_piece = _walls[key]
		var keep_id: StringName = &""
		if is_instance_valid(old_piece):
			keep_id = old_piece.item_id
			old_piece.queue_free()
		var piece := _spawn_wall_piece(key, keep_id)
		if piece == null:
			continue
		piece.visible = not _hidden_walls.has(key) and not _wall_corner_path.has(key)

	for owner_key in _wall_corner_path.keys():
		_spawn_corner_visual(_wall_corner_path[owner_key])


func _spawn_current_piece() -> BuildPiece:
	if _active_map_file != "":
		return _spawn_map_piece(_active_map_file)
	var scene := floor_scene if tool == Tool.FLOOR else wall_scene
	return _spawn_piece(scene)


func _spawn_map_piece(map_path: String) -> BuildPiece:
	var fgmap := FuncGodotMap.new()
	fgmap.local_map_file = map_path
	var default_settings_path: String = ProjectSettings.get_setting(
		"func_godot/default_map_settings",
		"res://addons/func_godot/func_godot_default_map_settings.tres"
	)
	fgmap.map_settings = load(default_settings_path)
	fgmap.build()

	var piece := BuildPiece.new()
	piece.name = map_path.get_file().get_basename()
	var aabb := _compute_aabb(fgmap)
	if aabb.size == Vector3.ZERO:
		aabb.size = Vector3.ONE

	# Extraer las mallas para no conservar el FuncGodotMap ni su cuerpo fisico.
	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(fgmap, meshes)
	for mi in meshes:
		var parent := mi.get_parent()
		if parent != null:
			parent.remove_child(mi)
		mi.owner = null
		# Conservar el origen del modelo.
		piece.add_child(mi)

	fgmap.queue_free()

	var collision := CollisionShape3D.new()
	collision.name = "CollisionShape3D"
	var box := BoxShape3D.new()
	box.size = aabb.size
	collision.shape = box
	collision.position = aabb.position + aabb.size * 0.5
	piece.add_child(collision)

	var parent: Node = pieces_root if pieces_root != null else self
	parent.add_child(piece)
	return piece


func _spawn_piece(scene: PackedScene, with_collision: bool = true) -> BuildPiece:
	if scene == null:
		push_warning("BuildController: falta un prefab de pieza.")
		return null

	var instance := scene.instantiate()
	var piece: BuildPiece
	if instance is BuildPiece:
		piece = instance as BuildPiece
		if not with_collision:
			var old_collision := piece.get_node_or_null("CollisionShape3D") as CollisionShape3D
			if old_collision != null:
				old_collision.queue_free()
	else:
		if not (instance is Node3D):
			push_warning("BuildController: el prefab no es una pieza ni un nodo 3D.")
			instance.queue_free()
			return null
		for child in (instance as Node3D).get_children():
			if child is Camera3D or child is Light3D:
				child.queue_free()
		piece = BuildPiece.new()
		piece.name = instance.name
		# Conservar el origen del modelo; no recentrarlo.
		piece.add_child(instance)
		if with_collision:
			var aabb := _compute_aabb(instance)
			if aabb.size == Vector3.ZERO:
				aabb.size = Vector3.ONE
			var collision := CollisionShape3D.new()
			collision.name = "CollisionShape3D"
			var box := BoxShape3D.new()
			box.size = aabb.size
			collision.shape = box
			collision.position = aabb.position + aabb.size * 0.5
			piece.add_child(collision)

	var parent: Node = pieces_root if pieces_root != null else self
	parent.add_child(piece)
	return piece


static func _collect_meshes(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		out.append(node as MeshInstance3D)
	for child in node.get_children():
		_collect_meshes(child, out)


static func _compute_aabb(node: Node, parent_transform: Transform3D = Transform3D.IDENTITY) -> AABB:
	var node_transform := parent_transform
	if node is Node3D:
		node_transform = parent_transform * (node as Node3D).transform

	var aabb := AABB()
	var first := true
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			aabb = node_transform * mi.mesh.get_aabb()
			first = false
	for child in node.get_children():
		var child_aabb := _compute_aabb(child, node_transform)
		if first:
			if child_aabb.size != Vector3.ZERO:
				aabb = child_aabb
				first = false
		elif child_aabb.size != Vector3.ZERO:
			aabb = aabb.merge(child_aabb)
	if first:
		return AABB()
	return aabb


# --------------------------------------------------------------------------
# Hover / fantasmas
# --------------------------------------------------------------------------

func _update_hover() -> bool:
	if build_camera == null or not build_camera.current:
		return false

	var mouse := get_viewport().get_mouse_position()
	var from := build_camera.project_ray_origin(mouse)
	var normal := build_camera.project_ray_normal(mouse)
	var plane := Plane(Vector3.UP, grid.plane_global_y())
	var hit: Variant = plane.intersects_ray(from, normal)
	if hit == null:
		return false

	_hover_cell = grid.cell_from_world(hit)
	_hover_wall = grid.wall_from_world(hit)
	return true


func _update_ghosts() -> void:
	_hide_ghosts()
	if not _hovering:
		return
	if tool == Tool.WALL and _wall_dragging:
		if _wall_ghost != null:
			_wall_ghost.visible = false
		return

	match tool:
		Tool.FLOOR:
			_show_floor_ghost(grid.clamp_cell(_hover_cell),
				_can_place_floor(_hover_cell), false)
		Tool.WALL:
			_show_wall_ghost(grid.clamp_wall(_hover_wall),
				_can_place_wall(_hover_wall), false)
		Tool.OBJECT:
			_show_object_ghost(grid.clamp_cell(_hover_cell),
				_can_place_object(_hover_cell, _selected_object_item), false)
		Tool.ERASE:
			if _object_cells.has(_hover_cell):
				_show_object_ghost(grid.clamp_cell(_hover_cell), true, true)
			elif _walls.has(_hover_wall):
				_show_wall_ghost(_hover_wall, true, true)
			else:
				_show_floor_ghost(grid.clamp_cell(_hover_cell),
					_floors.has(_hover_cell), true)


func _show_floor_ghost(cell: Vector2i, valid: bool, erasing: bool) -> void:
	_floor_ghost.visible = true
	var box := _floor_ghost.mesh as BoxMesh
	box.size = Vector3(grid.cell_size * 0.94, 0.06, grid.cell_size * 0.94)
	_floor_ghost.global_position = grid.cell_center(cell) \
		+ Vector3.UP * (0.05 if not erasing else 0.09)
	_set_ghost_color(valid, erasing)


func _show_wall_ghost(key: Vector3i, valid: bool, erasing: bool) -> void:
	_wall_ghost.visible = true
	var box := _wall_ghost.mesh as BoxMesh
	box.size = Vector3(grid.cell_size * 0.98, wall_height, wall_thickness * 0.7)
	_wall_ghost.global_transform = Transform3D(
		Basis(Vector3.UP, grid.wall_yaw(key)),
		grid.wall_center(key) + Vector3.UP * (wall_height * 0.5)
	)
	_set_ghost_color(valid, erasing)


func _show_object_ghost(cell: Vector2i, valid: bool, erasing: bool) -> void:
	_object_ghost.visible = true
	var box := _object_ghost.mesh as BoxMesh
	var footprint := Vector2i(1, 1)
	if _selected_object_item != null:
		footprint = Vector2i(
			maxi(_selected_object_item.footprint.x, 1),
			maxi(_selected_object_item.footprint.y, 1)
		)
	box.size = Vector3(
		grid.cell_size * 0.8 * footprint.x,
		0.9,
		grid.cell_size * 0.8 * footprint.y
	)
	_object_ghost.global_transform = Transform3D(
		Basis(Vector3.UP, float(_object_rotation) * PI * 0.5),
		grid.cell_center(cell) + Vector3.UP * 0.45
	)
	_set_ghost_color(valid, erasing)


func _set_ghost_color(valid: bool, erasing: bool) -> void:
	if erasing:
		_ghost_material.albedo_color = COLOR_ERASE
	elif valid:
		_ghost_material.albedo_color = COLOR_OK
	else:
		_ghost_material.albedo_color = COLOR_BAD


func _hide_ghosts() -> void:
	if _floor_ghost != null:
		_floor_ghost.visible = false
	if _wall_ghost != null:
		_wall_ghost.visible = false
	if _object_ghost != null:
		_object_ghost.visible = false


# --------------------------------------------------------------------------
# Construccion de nodos
# --------------------------------------------------------------------------

func _resolve_references() -> void:
	var scene_root: Node = get_tree().current_scene
	if scene_root == null:
		scene_root = get_parent()

	if grid == null:
		grid = _find_grid(scene_root)
	if grid != null:
		wall_thickness = grid.wall_thickness
	if build_camera == null:
		build_camera = _find_build_camera(scene_root)
	if build_camera == null:
		build_camera = BuildCamera.new()
		build_camera.name = "BuildCamera"
		add_child(build_camera)
	if player == null:
		player = _find_player(scene_root)
	if pieces_root == null:
		# Reutilizar el contenedor que ya exista (por ejemplo, dentro del
		# NavigationRegion3D) antes de crear uno nuevo. Buscar primero en el
		# BuildSystem local para no mezclar varias instancias.
		pieces_root = _find_named(get_parent(), "PlacedPieces") as Node3D
	if pieces_root == null:
		pieces_root = _find_named(scene_root, "PlacedPieces") as Node3D
	if pieces_root == null:
		pieces_root = Node3D.new()
		pieces_root.name = "PlacedPieces"
		add_child(pieces_root)

	if build_menu == null:
		build_menu = _find_build_menu(get_parent())
	if build_menu == null:
		build_menu = _find_build_menu(get_tree().current_scene if get_tree() != null else null)
	if build_menu == null:
		build_menu = BuildMenu.new()
		build_menu.items_dir = items_dir
		add_child(build_menu)

func _create_ghosts() -> void:
	_ghost_material = StandardMaterial3D.new()
	_ghost_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_ghost_material.albedo_color = COLOR_OK

	_floor_ghost = _make_ghost("FloorGhost")
	_wall_ghost = _make_ghost("WallGhost")
	_object_ghost = _make_ghost("ObjectGhost")


func _make_ghost(node_name: String) -> MeshInstance3D:
	var ghost := MeshInstance3D.new()
	ghost.name = node_name
	ghost.mesh = BoxMesh.new()
	ghost.material_override = _ghost_material
	ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ghost.visible = false
	add_child(ghost)
	return ghost


func _create_ui() -> void:
	_ui_layer = CanvasLayer.new()
	_ui_layer.name = "BuildUI"
	_ui_layer.layer = 10
	add_child(_ui_layer)

	_ui_title = _make_label("MODO CONSTRUCCIÓN", 20, Color(0.7, 0.95, 1.0))
	_ui_title.position = Vector2(18, 12)
	_ui_layer.add_child(_ui_title)

	_ui_tool = _make_label("", 17, Color(0.95, 0.97, 1.0))
	_ui_tool.position = Vector2(18, 40)
	_ui_layer.add_child(_ui_tool)

	var hint := _make_label(
		"WASD: mover cámara   ·   clic derecho: orbitar   ·   rueda: zoom   ·   Q/E: altura\n"
		+ "1: suelo   ·   2: pared   ·   3: borrar   ·   M: menú   ·   R: rotar   ·   ° / Ctrl+S: guardar   ·   B / Esc: salir",
		15, Color(0.85, 0.9, 0.95, 0.9)
	)
	hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	hint.offset_left = 18
	hint.offset_top = -72
	hint.offset_right = 980
	hint.offset_bottom = -14
	_ui_layer.add_child(hint)

	# Avisos de guardado/carga: capa propia, visible siempre.
	_message_layer = CanvasLayer.new()
	_message_layer.name = "BuildMessages"
	_message_layer.layer = 11
	add_child(_message_layer)

	_ui_message = _make_label("", 20, Color(0.6, 1.0, 0.7))
	_ui_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_ui_message.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_ui_message.offset_left = -360
	_ui_message.offset_right = 360
	_ui_message.offset_top = 16
	_ui_message.offset_bottom = 52
	_ui_message.visible = false
	_message_layer.add_child(_ui_message)


func _make_label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.9))
	label.add_theme_constant_override("outline_size", 5)
	return label


func _update_ui() -> void:
	if _ui_layer == null:
		return
	_ui_layer.visible = build_mode and show_help
	if not build_mode:
		return

	var tool_name := _tool_name()
	if _hovering:
		_ui_tool.text = "%s   ·   celda (%d, %d)" % [
			tool_name, _hover_cell.x, _hover_cell.y
		]
	else:
		_ui_tool.text = tool_name


func _tool_name() -> String:
	match tool:
		Tool.FLOOR:
			return "Herramienta: suelo"
		Tool.WALL:
			return "Herramienta: pared"
		Tool.OBJECT:
			if _selected_object_item != null:
				return "Herramienta: objeto (%s)" % _selected_object_item.display_name
			return "Herramienta: objeto"
		Tool.ERASE:
			return "Herramienta: borrar"
	return ""


# --------------------------------------------------------------------------
# Busquedas
# --------------------------------------------------------------------------

func _find_grid(node: Node) -> BuildGrid:
	if node == null:
		return null
	if node is BuildGrid:
		return node as BuildGrid
	for child in node.get_children():
		var found := _find_grid(child)
		if found != null:
			return found
	return null


func _find_build_camera(node: Node) -> BuildCamera:
	if node == null:
		return null
	if node is BuildCamera:
		return node as BuildCamera
	for child in node.get_children():
		var found := _find_build_camera(child)
		if found != null:
			return found
	return null


func _find_player(node: Node) -> FPSController:
	if node == null:
		return null
	if node is FPSController:
		return node as FPSController
	for child in node.get_children():
		var found := _find_player(child)
		if found != null:
			return found
	return null


func _find_named(node: Node, node_name: String) -> Node:
	if node == null:
		return null
	if node.name == node_name:
		return node
	for child in node.get_children():
		var found := _find_named(child, node_name)
		if found != null:
			return found
	return null


func _find_camera(node: Node) -> Camera3D:
	if node == null:
		return null
	if node is Camera3D:
		return node as Camera3D
	for child in node.get_children():
		var found := _find_camera(child)
		if found != null:
			return found
	return null


# --------------------------------------------------------------------------
# Guardado / carga por nivel
# --------------------------------------------------------------------------

func _find_item_by_id(id: StringName) -> BuildItem:
	if id == &"":
		return null
	for item in build_items:
		if item.id == id:
			return item
	return null


func get_build_save_path() -> String:
	var scene := get_tree().current_scene if get_tree() != null else null
	var scene_path := scene.scene_file_path if scene != null else ""
	if scene_path.begins_with("res://"):
		return scene_path.get_basename() + ".build.json"
	return _get_user_build_save_path()


func _get_user_build_save_path() -> String:
	var scene := get_tree().current_scene if get_tree() != null else null
	var scene_path := scene.scene_file_path if scene != null else ""
	var base := scene_path.get_file().get_basename() if scene_path != "" else ""
	if base == "" and scene != null:
		base = String(scene.name).to_snake_case()
	if base == "":
		base = "level"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://build_saves"))
	return "user://build_saves/%s.build.json" % base


func save_construction() -> void:
	var data := {
		"version": 1,
		"floors": [],
		"walls": [],
		"objects": [],
	}
	for cell in _floors.keys():
		var piece: BuildPiece = _floors[cell]
		if not is_instance_valid(piece):
			continue
		data["floors"].append({
			"x": cell.x,
			"y": cell.y,
			"item_id": String(piece.item_id),
		})
	for key in _walls.keys():
		var piece: BuildPiece = _walls[key]
		if not is_instance_valid(piece):
			continue
		data["walls"].append({
			"x": key.x,
			"y": key.y,
			"axis": key.z,
			"item_id": String(piece.item_id),
		})
	for cell in _objects.keys():
		var piece: BuildPiece = _objects[cell]
		if not is_instance_valid(piece):
			continue
		data["objects"].append({
			"x": cell.x,
			"y": cell.y,
			"item_id": String(piece.item_id),
			"rotation": piece.object_rotation_steps,
		})

	var path := get_build_save_path()
	if not _write_build_save(path, data):
		var fallback := _get_user_build_save_path()
		if fallback != path and _write_build_save(fallback, data):
			path = fallback
		else:
			push_warning("BuildController: no se pudo guardar la construcción en %s" % path)
			_show_build_message("No se pudo guardar la construcción", Color(1.0, 0.5, 0.4))
			return
	var total := int(data["floors"].size()) + int(data["walls"].size()) + int(data["objects"].size())
	print("BuildController: construcción guardada en %s (%d suelos, %d paredes, %d objetos)" % [
		path, data["floors"].size(), data["walls"].size(), data["objects"].size()
	])
	_show_build_message(
		"Construcción guardada: %d piezas  ·  %s" % [total, path],
		Color(0.6, 1.0, 0.7)
	)


func _write_build_save(path: String, data: Dictionary) -> bool:
	var dir_path := path.get_base_dir()
	if dir_path.begins_with("res://"):
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))
	elif dir_path.begins_with("user://"):
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	return true


## Muestra un aviso breve centrado arriba. Funciona también con el modo
## construcción desactivado, así el jugador ve que el guardado ocurrió.
func _show_build_message(text: String, color: Color = Color(0.95, 0.97, 1.0)) -> void:
	if _ui_message == null:
		return
	_ui_message.text = text
	_ui_message.add_theme_color_override("font_color", color)
	_ui_message.visible = true
	if get_tree() == null:
		return
	await get_tree().create_timer(2.5).timeout
	if is_instance_valid(self) and _ui_message != null:
		_ui_message.visible = false


func load_construction() -> void:
	if grid == null:
		return
	var path := get_build_save_path()
	if not FileAccess.file_exists(path):
		var fallback := _get_user_build_save_path()
		if fallback != path and FileAccess.file_exists(fallback):
			path = fallback
		else:
			return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("BuildController: no se pudo leer la construcción desde %s" % path)
		return
	var text := file.get_as_text()
	file.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("BuildController: datos de construcción inválidos en %s" % path)
		return
	var data: Dictionary = parsed

	var prev_selected := selected_item
	var prev_active_map := _active_map_file
	var prev_tool := tool
	var changed := false

	# Suelos
	for entry in data.get("floors", []):
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var cell := Vector2i(int(entry.get("x", 0)), int(entry.get("y", 0)))
		if _floors.has(cell):
			continue
		var item := _find_item_by_id(StringName(String(entry.get("item_id", ""))))
		if item != null:
			selected_item = item
		if selected_item != null:
			_apply_selected_item()
		if _place_floor(cell):
			changed = true

	# Paredes
	for entry in data.get("walls", []):
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var key := Vector3i(int(entry.get("x", 0)), int(entry.get("y", 0)), int(entry.get("axis", 0)))
		if _walls.has(key):
			continue
		var item := _find_item_by_id(StringName(String(entry.get("item_id", ""))))
		if item != null:
			selected_item = item
		if selected_item != null:
			_apply_selected_item()
		if _place_wall_silent(key):
			changed = true
	if not _walls.is_empty():
		_refresh_wall_variants()
		_refresh_wall_shapes()

	# Objetos
	for entry in data.get("objects", []):
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var cell := Vector2i(int(entry.get("x", 0)), int(entry.get("y", 0)))
		if _objects.has(cell):
			continue
		var item := _find_item_by_id(StringName(String(entry.get("item_id", ""))))
		if item == null:
			continue
		var rot := int(entry.get("rotation", 0))
		if _place_object(cell, item, rot):
			changed = true

	selected_item = prev_selected
	_active_map_file = prev_active_map
	if prev_selected != null:
		_apply_selected_item()
	else:
		tool = prev_tool
	if changed:
		pieces_changed.emit()
		var total := get_floor_count() + get_wall_count() + get_object_count()
		print("BuildController: construcción cargada desde %s (%d piezas)" % [path, total])
		_show_build_message(
			"Construcción cargada: %d piezas" % total,
			Color(0.7, 0.95, 1.0)
		)
