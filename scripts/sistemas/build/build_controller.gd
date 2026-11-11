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
const GHOST_SHADER := preload("res://scripts/sistemas/build/shaders/ghost.gdshader")
## Previsualizacion del pincel de pisos: plana, con borde y cuadricula por celda
## (a diferencia del holograma, que queda mejor para volumenes).
const FLOOR_PREVIEW_SHADER := preload("res://scripts/sistemas/build/shaders/floor_preview.gdshader")
const COLOR_OK := Color(0.25, 1.0, 0.6, 0.35)
const COLOR_BAD := Color(1.0, 0.3, 0.25, 0.42)
const COLOR_ERASE := Color(1.0, 0.45, 0.2, 0.5)

## Colores de la previsualizacion plana del piso (mas claros que el holograma
## para que se lean sobre el cesped y otros suelos claros).
const FLOOR_PREVIEW_FILL := Color(0.25, 1.0, 0.62)
const FLOOR_PREVIEW_LINE := Color(0.72, 1.0, 0.92)
const FLOOR_ERASE_FILL := Color(1.0, 0.42, 0.18)
const FLOOR_ERASE_LINE := Color(1.0, 0.72, 0.45)
## Altura de la previsualizacion de piso sobre el plano (por encima del suelo).
const FLOOR_PREVIEW_LIFT := 0.09

## Fuerza del fantasma: las piezas ya dibujadas son suaves y la pieza actual
## (la que esta en el borde de avance) se ve mas solida.
const GHOST_PREVIEW_STRENGTH := 0.5
const GHOST_CURRENT_STRENGTH := 1.0
## Tiempo que tarda cada tramo del arrastre en "construirse" desde el suelo.
const WALL_REVEAL_SEGMENT_TIME := 0.065
## Pequeno retardo entre paredes al confirmar el dibujo (efecto de obra).
const WALL_BUILD_STAGGER := 0.035
const WALL_BUILD_TIME := 0.16
## Pincel de piso: tiempo por celda del trazado y del efecto de obra.
const FLOOR_REVEAL_CELL_TIME := 0.04
const FLOOR_BUILD_STAGGER := 0.018
const FLOOR_BUILD_TIME := 0.14

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

## Controllers vivos. La IA consulta la grilla activa sin autoload (igual que
## `SmartObjectRegistry`), asi funciona tambien en tests headless.
static var _active_controllers: Array = []

var build_items: Array[BuildItem] = []
var selected_item: BuildItem
var _selected_object_item: BuildItem
## Rotación del objeto en pasos de 90 grados (0..3).
var _object_rotation := 0
var _active_map_file: String = ""

var _floor_preview: MeshInstance3D
var _floor_preview_material: ShaderMaterial
## Celdas que tiene dibujadas la previsualizacion actual (para reconstruirla
## solo cuando cambia el rectangulo).
var _floor_preview_cells: Array[Vector2i] = []
var _floor_preview_cols := 1
var _floor_preview_rows := 1
var _wall_ghost: Node3D
var _object_ghost: Node3D

## Modelo real usado por el fantasma de paredes (misma escena que la pieza).
var _wall_ghost_model: Node3D
var _wall_ghost_material: ShaderMaterial
var _wall_ghost_aabb := AABB()
var _wall_ghost_scene: PackedScene
## Desfase vertical del origen del modelo (las cajas procedurales se centran).
var _wall_ghost_base_offset := 0.0

## Modelo real usado por el fantasma de objetos (misma escena que la pieza).
var _object_ghost_model: Node3D
var _object_ghost_material: ShaderMaterial
var _object_ghost_aabb := AABB()
var _object_ghost_scene: PackedScene
var _object_ghost_footprint := Vector2i(1, 1)

var _hover_cell := Vector2i.ZERO
var _hover_wall := Vector3i.ZERO
var _hovering := false
var _painting := false
var _floor_dragging := false
var _floor_drag_start := Vector2i.ZERO
var _floor_drag_cells: Array[Vector2i] = []
## Progreso del "pintado" del rectangulo, en celdas completas.
var _floor_drag_reveal := 0.0
var _wall_dragging := false
var _wall_drag_start := Vector3i.ZERO
var _wall_drag_start_cell := Vector2i.ZERO
var _wall_drag_ghosts: Array[Node3D] = []
var _wall_drag_ghost_materials: Array[ShaderMaterial] = []
var _wall_drag_keys: Array[Vector3i] = []
var _wall_drag_local_aabb := AABB()
var _wall_drag_base_offset := 0.0
## Progreso del "trazado" durante el arrastre, en tramos completos.
var _wall_drag_reveal := 0.0
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
	if not _active_controllers.has(self):
		_active_controllers.append(self)
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


func _exit_tree() -> void:
	_active_controllers.erase(self)


## Primer controller valido de la escena (o null). Pensado para la IA.
static func get_active() -> BuildController:
	for candidate in _active_controllers:
		if is_instance_valid(candidate) and not candidate.is_queued_for_deletion():
			return candidate as BuildController
	return null


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
	_clear_floor_drag_preview()
	_floor_dragging = false
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
	# Cambiar de herramienta cancela cualquier arrastre en curso.
	if new_tool != Tool.WALL and _wall_dragging:
		_clear_wall_drag_ghosts()
		_wall_dragging = false
	if new_tool != Tool.FLOOR and _floor_dragging:
		_clear_floor_drag_preview()
		_floor_dragging = false
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
				_update_wall_drag(_delta)
		else:
			_finish_wall_drag()
			_hide_ghosts()
			_update_ui()
			return

	# Lo mismo para el pincel de pisos.
	if tool == Tool.FLOOR and _floor_dragging:
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			if _hovering:
				_update_floor_drag(_delta)
		else:
			_finish_floor_drag()
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
				_update_wall_drag(_delta)
	elif tool == Tool.FLOOR:
		# Clic y arrastrar: rectangulo de celdas con vista previa progresiva.
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			var over_ui := get_viewport().gui_get_hovered_control() != null
			if not _floor_dragging and not over_ui:
				_start_floor_drag()
			if _floor_dragging:
				_update_floor_drag(_delta)
	elif tool == Tool.OBJECT:
		# Un clic = un objeto. Arrastrar no debe llenar la sala de muebles.
		# Ignorar clics sobre la UI (menú de items).
		var pressed := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		var over_ui := get_viewport().gui_get_hovered_control() != null
		if pressed and not _painting and not over_ui:
			_apply_tool()
		_painting = pressed
	else:
		# ERASE: pintar borrando celda a celda.
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


## Punto central de cada celda con suelo. La IA lo usa para entrar a la grilla
## desde fuera (por ejemplo, viniendo del terreno).
func get_floor_points() -> PackedVector3Array:
	var points := PackedVector3Array()
	if grid == null:
		return points
	for cell in _floors.keys():
		points.append(grid.cell_center(cell))
	return points


## Hay un suelo construido en la celda que contiene `world`.
func has_floor_at_world(world: Vector3) -> bool:
	if grid == null:
		return false
	return _floors.has(grid.cell_from_world(world))


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


func _place_floor(cell: Vector2i, silent: bool = false) -> bool:
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
	if not silent:
		pieces_changed.emit()
	return true


func _place_wall(key: Vector3i) -> bool:
	if not _place_wall_silent(key):
		return false
	_refresh_wall_variants()
	_refresh_wall_shapes()
	_animate_walls_build([key])
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
	_wall_drag_reveal = 0.0
	_clear_wall_drag_ghosts(false)
	_wall_drag_keys.clear()


func _update_wall_drag(delta: float = 0.0) -> void:
	if not _hovering:
		return
	if delta > 0.0:
		_wall_drag_reveal += delta / WALL_REVEAL_SEGMENT_TIME

	var keys := _wall_drag_segment_keys()
	# Si el arrastre se alarga, el tramo nuevo empieza a construirse desde cero.
	if keys.size() > _wall_drag_keys.size():
		_wall_drag_reveal = minf(_wall_drag_reveal, float(_wall_drag_keys.size()))
	_wall_drag_reveal = minf(_wall_drag_reveal, float(keys.size()))

	if not _same_wall_keys(keys, _wall_drag_keys):
		_rebuild_wall_drag_ghosts(keys)
	_update_wall_drag_ghosts(keys)


## Devuelve los tramos en orden de dibujo: desde el primer clic hasta el cursor.
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
		var end_x := _hover_cell.x
		var step_x := 1 if end_x >= _wall_drag_start.x else -1
		for x in range(_wall_drag_start.x, end_x + step_x, step_x):
			var key := Vector3i(x, fixed_z, 1)
			if grid.is_wall_inside(key):
				keys.append(key)
	else:
		# Pared vertical: x fijo (frontera), z varia por celdas.
		var fixed_x := _wall_drag_start.x
		var end_z := _hover_cell.y
		var step_z := 1 if end_z >= _wall_drag_start.y else -1
		for z in range(_wall_drag_start.y, end_z + step_z, step_z):
			var key := Vector3i(fixed_x, z, 0)
			if grid.is_wall_inside(key):
				keys.append(key)

	return keys


static func _same_wall_keys(a: Array[Vector3i], b: Array[Vector3i]) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if a[i] != b[i]:
			return false
	return true


func _rebuild_wall_drag_ghosts(keys: Array[Vector3i]) -> void:
	# Se reutilizan los fantasmas existentes: al cruzar de celda solo cambia la
	# cantidad de tramos, no hace falta reinstanciar el modelo entero.
	if _wall_ghost_scene != wall_scene or _active_map_file != "":
		_clear_wall_drag_ghosts(false)
		_wall_ghost_scene = wall_scene
		_wall_drag_local_aabb = AABB()
		_wall_drag_base_offset = 0.0

	while _wall_drag_ghosts.size() > keys.size():
		var extra: Node3D = _wall_drag_ghosts.pop_back()
		_wall_drag_ghost_materials.pop_back()
		if is_instance_valid(extra):
			extra.queue_free()

	while _wall_drag_ghosts.size() < keys.size():
		var built := _build_wall_ghost_visual()
		if built.is_empty():
			break
		if _wall_drag_local_aabb.size == Vector3.ZERO:
			_wall_drag_local_aabb = built.get("aabb", AABB())
			_wall_drag_base_offset = float(built.get("base_offset", 0.0))
		var ghost: Node3D = built["root"]
		var mat: ShaderMaterial = built["mat"]
		ghost.visible = false
		add_child(ghost)
		_wall_drag_ghosts.append(ghost)
		_wall_drag_ghost_materials.append(mat)

	_wall_drag_keys = keys.duplicate()


func _update_wall_drag_ghosts(keys: Array[Vector3i]) -> void:
	var count := mini(keys.size(), _wall_drag_ghosts.size())
	if count <= 0:
		return

	var progress := minf(_wall_drag_reveal, float(count))
	var current := clampi(int(ceil(progress)) - 1, 0, count - 1)

	for i in count:
		var ghost := _wall_drag_ghosts[i]
		var mat := _wall_drag_ghost_materials[i]
		if not is_instance_valid(ghost):
			continue
		var t := clampf(progress - float(i), 0.0, 1.0)
		ghost.visible = t > 0.0
		if not ghost.visible:
			continue
		var key := keys[i]
		ghost.global_transform = _wall_ghost_transform(key, _wall_drag_base_offset)
		_update_ghost_material(
			mat, ghost, _wall_drag_local_aabb,
			_can_place_wall(key), false,
			GHOST_CURRENT_STRENGTH if i == current else GHOST_PREVIEW_STRENGTH,
			t
		)


func _clear_wall_drag_ghosts(reset_reveal: bool = true) -> void:
	for ghost in _wall_drag_ghosts:
		if is_instance_valid(ghost):
			ghost.queue_free()
	_wall_drag_ghosts.clear()
	_wall_drag_ghost_materials.clear()
	_wall_drag_keys.clear()
	if reset_reveal:
		_wall_drag_reveal = 0.0


func _finish_wall_drag() -> void:
	var keys := _wall_drag_segment_keys()
	var placed := false
	for key in keys:
		if _place_wall_silent(key):
			placed = true
	if placed:
		_refresh_wall_variants()
		_refresh_wall_shapes()
		_animate_walls_build(keys)
		pieces_changed.emit()
	_clear_wall_drag_ghosts()
	_wall_dragging = false


# --------------------------------------------------------------------------
# Pincel de pisos (estilo Sims): clic y arrastrar para rellenar un rectangulo.
# --------------------------------------------------------------------------

func _start_floor_drag() -> void:
	if not _hovering or not grid.is_cell_inside(_hover_cell):
		return
	_floor_dragging = true
	_floor_drag_start = _hover_cell
	_floor_drag_reveal = 0.0
	_clear_floor_drag_preview(false)
	_floor_drag_cells.clear()


func _update_floor_drag(delta: float = 0.0) -> void:
	if not _hovering:
		return
	if delta > 0.0:
		_floor_drag_reveal += delta / FLOOR_REVEAL_CELL_TIME

	var cells := _floor_drag_rect_cells()
	# Si el rectangulo crece, las celdas nuevas empiezan a pintarse desde cero.
	if not _same_floor_cells(cells, _floor_drag_cells):
		if cells.size() > _floor_drag_cells.size():
			_floor_drag_reveal = minf(_floor_drag_reveal, float(_floor_drag_cells.size()))
		_floor_drag_cells = cells.duplicate()
	_floor_drag_reveal = minf(_floor_drag_reveal, float(cells.size()))

	if not _same_floor_cells(cells, _floor_preview_cells):
		_rebuild_floor_preview(cells, _floor_drag_start, false)
	_update_floor_preview(cells, _floor_drag_reveal, false)


## Celdas del rectangulo definido por el primer clic y el cursor, en orden de
## barrido (fila por fila) desde la esquina inicial hacia el cursor.
func _floor_drag_rect_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	if not _floor_dragging:
		return cells

	var start := grid.clamp_cell(_floor_drag_start)
	var end := grid.clamp_cell(_hover_cell)
	var x0 := mini(start.x, end.x)
	var x1 := maxi(start.x, end.x)
	var z0 := mini(start.y, end.y)
	var z1 := maxi(start.y, end.y)

	var rows: Array[int] = []
	for z in range(z0, z1 + 1):
		rows.append(z)
	if end.y < start.y:
		rows.reverse()
	for z in rows:
		var columns: Array[int] = []
		for x in range(x0, x1 + 1):
			columns.append(x)
		if end.x < start.x:
			columns.reverse()
		for x in columns:
			cells.append(Vector2i(x, z))
	return cells


static func _same_floor_cells(a: Array[Vector2i], b: Array[Vector2i]) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if a[i] != b[i]:
			return false
	return true


## Reconstruye la malla plana del rectangulo y su mascara de validez. Solo se
## llama cuando cambia el conjunto de celdas, no en cada frame.
func _rebuild_floor_preview(
	cells: Array[Vector2i], start: Vector2i, erasing: bool
) -> void:
	if _floor_preview == null:
		return
	if cells.is_empty():
		_floor_preview.visible = false
		_floor_preview_cells.clear()
		return

	var min_cell := cells[0]
	var max_cell := cells[0]
	for cell in cells:
		min_cell.x = mini(min_cell.x, cell.x)
		min_cell.y = mini(min_cell.y, cell.y)
		max_cell.x = maxi(max_cell.x, cell.x)
		max_cell.y = maxi(max_cell.y, cell.y)
	var cols := max_cell.x - min_cell.x + 1
	var rows := max_cell.y - min_cell.y + 1
	_floor_preview_cols = cols
	_floor_preview_rows = rows

	# Quad que cubre el rectangulo completo. Las UV van de 0 a 1 en el sentido
	# del trazado: u = 0 en la columna del primer clic, v = 0 en su fila.
	var cs := grid.cell_size
	var half_w := float(cols) * cs * 0.5
	var half_h := float(rows) * cs * 0.5
	var end := cells[cells.size() - 1]
	var neg_u := 0.0 if end.x >= start.x else 1.0
	var neg_v := 0.0 if end.y >= start.y else 1.0
	var pos_u := 1.0 - neg_u
	var pos_v := 1.0 - neg_v

	var corners := [
		[Vector3(-half_w, 0.0, -half_h), Vector2(neg_u, neg_v)],
		[Vector3(half_w, 0.0, -half_h), Vector2(pos_u, neg_v)],
		[Vector3(half_w, 0.0, half_h), Vector2(pos_u, pos_v)],
		[Vector3(-half_w, 0.0, half_h), Vector2(neg_u, pos_v)],
	]
	# Orden de vertices para que la cara mire hacia arriba.
	var order := [0, 2, 1, 0, 3, 2]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in order:
		var corner: Array = corners[i]
		st.set_normal(Vector3.UP)
		st.set_uv(corner[1])
		st.add_vertex(corner[0])
	_floor_preview.mesh = st.commit()

	var base := grid.global_position
	_floor_preview.global_transform = Transform3D(
		Basis.IDENTITY,
		Vector3(
			base.x + (float(min_cell.x) + float(cols) * 0.5) * cs,
			grid.plane_global_y() + FLOOR_PREVIEW_LIFT,
			base.z + (float(min_cell.y) + float(rows) * 0.5) * cs
		)
	)

	# Mascara: una pixel por celda, en el mismo orden de trazado que las UV.
	var image := Image.create(cols, rows, false, Image.FORMAT_L8)
	for i in cells.size():
		var ok := erasing or _can_place_floor(cells[i])
		image.set_pixel(i % cols, i / cols, Color(1, 1, 1) if ok else Color(0, 0, 0))
	var texture := ImageTexture.create_from_image(image)
	_floor_preview_material.set_shader_parameter("valid_mask", texture)
	_floor_preview_material.set_shader_parameter("grid_size", Vector2(cols, rows))

	_floor_preview_cells = cells.duplicate()


## Actualiza color, revelado y celda actual de la previsualizacion ya dibujada.
func _update_floor_preview(
	cells: Array[Vector2i], reveal_cells: float, erasing: bool
) -> void:
	if _floor_preview == null or _floor_preview_material == null or cells.is_empty():
		return
	var mat := _floor_preview_material
	var fill := FLOOR_ERASE_FILL if erasing else FLOOR_PREVIEW_FILL
	var line := FLOOR_ERASE_LINE if erasing else FLOOR_PREVIEW_LINE
	mat.set_shader_parameter("fill_color", Color(fill.r, fill.g, fill.b, 1.0))
	mat.set_shader_parameter("line_color", Color(line.r, line.g, line.b, 1.0))
	mat.set_shader_parameter("invalid_color", Color(COLOR_BAD.r, COLOR_BAD.g, COLOR_BAD.b, 1.0))
	mat.set_shader_parameter("grid_size", Vector2(_floor_preview_cols, _floor_preview_rows))

	var total := float(cells.size())
	var reveal := clampf(reveal_cells, 0.0, total)
	var current := clampi(int(ceil(reveal)) - 1, 0, cells.size() - 1)
	mat.set_shader_parameter("reveal_cells", reveal)
	mat.set_shader_parameter("current_index", float(current))
	_floor_preview.visible = true


func _clear_floor_drag_preview(reset_reveal: bool = true) -> void:
	_floor_drag_cells.clear()
	_floor_preview_cells.clear()
	if _floor_preview != null:
		_floor_preview.visible = false
	if reset_reveal:
		_floor_drag_reveal = 0.0


func _finish_floor_drag() -> void:
	var cells := _floor_drag_rect_cells()
	var placed: Array[Vector2i] = []
	for cell in cells:
		if _place_floor(cell, true):
			placed.append(cell)
	if not placed.is_empty():
		_animate_floors_build(placed)
		pieces_changed.emit()
	_clear_floor_drag_preview()
	_floor_dragging = false


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
			_rebuild_wall_ghost_model()
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
	# El arrastre de pisos mantiene su propia previsualizacion persistente:
	# no hay que ocultarla en cada frame.
	if tool == Tool.FLOOR and _floor_dragging:
		return
	_hide_ghosts()
	if not _hovering:
		return
	if tool == Tool.WALL and _wall_dragging:
		return

	match tool:
		Tool.FLOOR:
			_show_floor_preview(grid.clamp_cell(_hover_cell), false)
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
				_show_floor_preview(grid.clamp_cell(_hover_cell), true)


## Previsualizacion de una sola celda (cursor quieto o herramienta de borrar).
func _show_floor_preview(cell: Vector2i, erasing: bool) -> void:
	if _floor_preview == null:
		return
	var cells: Array[Vector2i] = [cell]
	if not _same_floor_cells(cells, _floor_preview_cells):
		_rebuild_floor_preview(cells, cell, erasing)
	_update_floor_preview(cells, 1.0, erasing)


func _show_wall_ghost(key: Vector3i, valid: bool, erasing: bool) -> void:
	if _wall_ghost == null:
		return
	if _wall_ghost_model == null or _wall_ghost_scene != wall_scene:
		_rebuild_wall_ghost_model()
	if _wall_ghost_model == null or _wall_ghost_material == null:
		return
	_wall_ghost.visible = true
	_wall_ghost.global_transform = _wall_ghost_transform(key, _wall_ghost_base_offset)
	_update_ghost_material(
		_wall_ghost_material, _wall_ghost, _wall_ghost_aabb,
		valid, erasing, GHOST_CURRENT_STRENGTH, 1.0
	)


## Transformacion exacta que usa `_spawn_wall_piece`, para que el fantasma y
## la pared real coincidan (mismo origen y misma rotacion).
func _wall_ghost_transform(key: Vector3i, base_offset: float) -> Transform3D:
	return Transform3D(
		Basis(Vector3.UP, grid.wall_yaw(key)),
		grid.wall_center(key) + Vector3.UP * base_offset
	)


func _update_ghost_material(
	mat: ShaderMaterial,
	ghost: Node3D,
	local_aabb: AABB,
	valid: bool,
	erasing: bool,
	strength: float,
	reveal: float,
	fallback_height: float = 0.0
) -> void:
	if mat == null or ghost == null:
		return
	var color := COLOR_OK
	if erasing:
		color = COLOR_ERASE
	elif not valid:
		color = COLOR_BAD
	mat.set_shader_parameter("ghost_color", Color(color.r, color.g, color.b, 1.0))
	mat.set_shader_parameter("ghost_alpha", 0.42 if valid and not erasing else 0.5)
	mat.set_shader_parameter("strength", strength)
	mat.set_shader_parameter("reveal", reveal)
	var base_y := ghost.global_position.y + local_aabb.position.y
	var top_y := ghost.global_position.y + local_aabb.end.y
	if local_aabb.size.y < 0.001:
		base_y = ghost.global_position.y
		top_y = base_y + (fallback_height if fallback_height > 0.0 else wall_height)
	mat.set_shader_parameter("build_bottom", base_y)
	mat.set_shader_parameter("build_top", top_y)


func _show_object_ghost(cell: Vector2i, valid: bool, erasing: bool) -> void:
	if _object_ghost == null:
		return

	var scene: PackedScene = null
	var footprint := Vector2i(1, 1)
	var steps := _object_rotation
	if erasing:
		# Al borrar se muestra el modelo del objeto que hay bajo el cursor.
		var piece := _object_cells.get(cell) as BuildPiece
		if piece != null:
			var item := _find_item_by_id(piece.item_id)
			if item != null:
				scene = item.scene
				footprint = Vector2i(
					maxi(item.footprint.x, 1), maxi(item.footprint.y, 1)
				)
			# El objeto puede ocupar varias celdas: usar su celda primaria.
			cell = piece.cell
			steps = piece.object_rotation_steps
	elif _selected_object_item != null:
		scene = _selected_object_item.scene
		footprint = Vector2i(
			maxi(_selected_object_item.footprint.x, 1),
			maxi(_selected_object_item.footprint.y, 1)
		)

	if _object_ghost_model == null or _object_ghost_scene != scene \
			or _object_ghost_footprint != footprint:
		_rebuild_object_ghost_model(scene, footprint)
	if _object_ghost_model == null or _object_ghost_material == null:
		return

	_object_ghost.visible = true
	_object_ghost.global_transform = Transform3D(
		Basis(Vector3.UP, float(steps % 4) * PI * 0.5),
		grid.cell_center(cell) + Vector3.UP * object_height_offset
	)
	_update_ghost_material(
		_object_ghost_material, _object_ghost, _object_ghost_aabb,
		valid, erasing, GHOST_CURRENT_STRENGTH, 1.0,
		maxf(_object_ghost_aabb.size.y, 1.0)
	)


func _hide_ghosts() -> void:
	if _floor_preview != null:
		_floor_preview.visible = false
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
	_floor_preview = MeshInstance3D.new()
	_floor_preview.name = "FloorPreview"
	_floor_preview.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_floor_preview_material = ShaderMaterial.new()
	_floor_preview_material.shader = FLOOR_PREVIEW_SHADER
	_floor_preview.material_override = _floor_preview_material
	_floor_preview.visible = false
	add_child(_floor_preview)
	# Mascara inicial (1x1 valida) para que el sampler nunca quede sin textura.
	var empty_mask := Image.create(1, 1, false, Image.FORMAT_L8)
	empty_mask.fill(Color(1, 1, 1))
	_floor_preview_material.set_shader_parameter(
		"valid_mask", ImageTexture.create_from_image(empty_mask)
	)
	_wall_ghost = Node3D.new()
	_wall_ghost.name = "WallGhost"
	_wall_ghost.visible = false
	add_child(_wall_ghost)
	_object_ghost = Node3D.new()
	_object_ghost.name = "ObjectGhost"
	_object_ghost.visible = false
	add_child(_object_ghost)
	_rebuild_wall_ghost_model()


## Reconstruye el fantasma con la malla real de la pared seleccionada. Antes
## era una caja generica, que quedaba desfasada respecto del modelo colocado.
func _rebuild_wall_ghost_model() -> void:
	if _wall_ghost == null:
		return
	if _wall_ghost_model != null:
		if is_instance_valid(_wall_ghost_model):
			_wall_ghost.remove_child(_wall_ghost_model)
			_wall_ghost_model.queue_free()
		_wall_ghost_model = null
	_wall_ghost_material = null
	_wall_ghost_aabb = AABB()
	_wall_ghost_base_offset = 0.0
	_wall_ghost_scene = wall_scene

	var built := _build_wall_ghost_visual()
	if built.is_empty():
		return
	_wall_ghost_model = built["root"]
	_wall_ghost_material = built["mat"]
	_wall_ghost_aabb = built.get("aabb", AABB())
	_wall_ghost_base_offset = float(built.get("base_offset", 0.0))
	_wall_ghost.add_child(_wall_ghost_model)
	_wall_ghost.visible = false


## Instancia el modelo de pared (o una caja de respaldo) y le aplica el shader
## fantasma a todas sus mallas. Devuelve root, material, AABB local y desfase.
func _build_wall_ghost_visual() -> Dictionary:
	var mat := ShaderMaterial.new()
	mat.shader = GHOST_SHADER

	var container := Node3D.new()
	container.name = "WallGhostModel"

	var instance: Node3D
	if _active_map_file == "" and wall_scene != null:
		var packed := wall_scene.instantiate()
		if packed is Node3D:
			instance = packed as Node3D
		else:
			packed.queue_free()
	if instance == null:
		instance = _make_ghost_box_wall()
	container.add_child(instance)

	_strip_ghost_instance(instance)

	# Las cajas procedurales se ajustan al tamano real de la pieza.
	var direct := instance.get_node_or_null("MeshInstance3D") as MeshInstance3D
	if direct != null and direct.mesh is BoxMesh:
		var source := direct.mesh as BoxMesh
		var box := BoxMesh.new()
		box.size = Vector3(grid.cell_size, wall_height, wall_thickness)
		box.material = source.material
		direct.mesh = box

	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(instance, meshes)
	for mi in meshes:
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var base_offset := wall_height * 0.5 if direct != null else 0.0
	return {
		"root": container,
		"mat": mat,
		"aabb": _compute_aabb(instance),
		"base_offset": base_offset,
	}


func _make_ghost_box_wall() -> Node3D:
	var root := Node3D.new()
	root.name = "WallGhostBox"
	var mi := MeshInstance3D.new()
	mi.name = "MeshInstance3D"
	mi.mesh = BoxMesh.new()
	root.add_child(mi)
	return root


## Reconstruye el fantasma del objeto con la malla real de su modelo. Si no hay
## escena (o no es 3D) cae en una caja ajustada a la huella del item.
func _rebuild_object_ghost_model(scene: PackedScene, footprint: Vector2i) -> void:
	if _object_ghost == null:
		return
	if _object_ghost_model != null:
		if is_instance_valid(_object_ghost_model):
			_object_ghost.remove_child(_object_ghost_model)
			_object_ghost_model.queue_free()
		_object_ghost_model = null
	_object_ghost_material = null
	_object_ghost_aabb = AABB()
	_object_ghost_scene = scene
	_object_ghost_footprint = footprint

	var built := _build_object_ghost_visual(scene, footprint)
	if built.is_empty():
		return
	_object_ghost_model = built["root"]
	_object_ghost_material = built["mat"]
	_object_ghost_aabb = built.get("aabb", AABB())
	_object_ghost.add_child(_object_ghost_model)
	_object_ghost.visible = false


## Instancia el modelo del objeto y le aplica el mismo shader que a las paredes.
func _build_object_ghost_visual(scene: PackedScene, footprint: Vector2i) -> Dictionary:
	var mat := ShaderMaterial.new()
	mat.shader = GHOST_SHADER

	var container := Node3D.new()
	container.name = "ObjectGhostModel"

	var instance: Node3D
	if scene != null:
		var packed := scene.instantiate()
		if packed is Node3D:
			instance = packed as Node3D
		else:
			packed.queue_free()
	if instance == null:
		instance = _make_ghost_box_object(footprint)
	container.add_child(instance)

	_strip_ghost_instance(instance)

	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(instance, meshes)
	for mi in meshes:
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	return {
		"root": container,
		"mat": mat,
		"aabb": _compute_aabb(instance),
	}


func _make_ghost_box_object(footprint: Vector2i) -> Node3D:
	var root := Node3D.new()
	root.name = "ObjectGhostBox"
	var mi := MeshInstance3D.new()
	mi.name = "MeshInstance3D"
	var box := BoxMesh.new()
	box.size = Vector3(
		grid.cell_size * 0.8 * maxi(footprint.x, 1),
		0.9,
		grid.cell_size * 0.8 * maxi(footprint.y, 1)
	)
	mi.mesh = box
	# La caja se centra en su origen; subirla para que apoye en el suelo.
	mi.position.y = 0.45
	root.add_child(mi)
	return root


## Deja la instancia como puramente visual: sin scripts, colisiones, camaras,
## luces, audio ni animaciones (un SmartObject fantasma no debe registrarse).
func _strip_ghost_instance(node: Node) -> void:
	if node.get_script() != null:
		node.set_script(null)
	if node is CollisionObject3D:
		var body := node as CollisionObject3D
		body.collision_layer = 0
		body.collision_mask = 0
	for child in node.get_children():
		if child is CollisionShape3D or child is CollisionPolygon3D \
				or child is Light3D or child is Camera3D \
				or child is AnimationPlayer or child is AnimationTree \
				or child is AudioStreamPlayer or child is AudioStreamPlayer3D:
			child.free()
		else:
			_strip_ghost_instance(child)


## Efecto de obra: las paredes recien confirmadas crecen desde el suelo, una
## detras de otra, en el mismo orden en que se dibujaron.
func _animate_walls_build(keys: Array[Vector3i]) -> void:
	if _active_map_file != "":
		return
	var order := 0
	for key in keys:
		var piece := _walls.get(key) as BuildPiece
		if piece != null and is_instance_valid(piece):
			order = _animate_wall_visual(_piece_visual_node(piece), order)
		# La esquina visible de una L se anima entera: no tiene colision.
		var corner := _corner_pieces.get(key) as BuildPiece
		if corner != null and is_instance_valid(corner):
			corner.scale = Vector3(corner.scale.x, 0.001, corner.scale.z)
			var tween := create_tween()
			tween.bind_node(corner)
			tween.tween_interval(float(order) * WALL_BUILD_STAGGER)
			tween.tween_property(corner, "scale:y", 1.0, WALL_BUILD_TIME) \
				.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
			order += 1


func _animate_wall_visual(visual: Node3D, order: int) -> int:
	if visual == null:
		return order
	var is_box := visual is MeshInstance3D \
		and (visual as MeshInstance3D).mesh is BoxMesh
	visual.scale = Vector3(visual.scale.x, 0.001, visual.scale.z)
	if is_box:
		visual.position.y = -wall_height * 0.5

	var tween := create_tween()
	tween.bind_node(visual)
	tween.tween_interval(float(order) * WALL_BUILD_STAGGER)
	tween.tween_property(visual, "scale:y", 1.0, WALL_BUILD_TIME) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	if is_box:
		tween.parallel().tween_property(visual, "position:y", 0.0, WALL_BUILD_TIME) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	return order + 1


func _piece_visual_node(piece: BuildPiece) -> Node3D:
	var direct := piece.get_node_or_null("MeshInstance3D") as MeshInstance3D
	if direct != null:
		return direct
	for child in piece.get_children():
		if child is Node3D and not (child is CollisionShape3D) \
				and not (child is CollisionObject3D):
			return child as Node3D
	return null


## Efecto de obra de los pisos: cada celda aparece con un pequeno "pop"
## (escala en el plano) en el mismo orden en que se pintaron.
func _animate_floors_build(cells: Array[Vector2i]) -> void:
	if _active_map_file != "":
		return
	var order := 0
	for cell in cells:
		var piece := _floors.get(cell) as BuildPiece
		if piece == null or not is_instance_valid(piece):
			continue
		_animate_floor_visual(_piece_visual_node(piece), order)
		order += 1


func _animate_floor_visual(visual: Node3D, order: int) -> void:
	if visual == null:
		return
	var original := visual.scale
	visual.scale = Vector3(original.x * 0.01, original.y, original.z * 0.01)

	var tween := create_tween()
	tween.bind_node(visual)
	tween.tween_interval(float(order) * FLOOR_BUILD_STAGGER)
	tween.tween_property(visual, "scale", original, FLOOR_BUILD_TIME) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


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
