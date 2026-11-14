class_name BuildController
extends Node3D

## Modo construccion estilo Sims (version basica).
##
## B toggle  |  1 suelo  |  2 pared  |  3 borrar  |  Esc salir
## Clic izquierdo coloca (y se puede arrastrar para pintar varias celdas).
##
## La grilla y la camara se resuelven automaticamente si no se asignan en el
## inspector, asi que basta con anadir `scripts/systems/build/build_system.tscn` a una escena
## que tenga un FPSPlayer.

enum Tool { FLOOR, WALL, OBJECT, ERASE, ZONE, ZONE_ERASE }
enum EraseKind { ALL, FLOOR, WALL, OBJECT }

## Se emite cuando cambia el conjunto de piezas colocadas (colocar, borrar o
## limpiar). La navegación lo usa para rehornear el NavMesh con debounce.
signal pieces_changed
## Se emite al colocar / borrar un SmartObject (muebles, props interactivos).
signal object_placed(object: Node)
signal object_removed(object: Node)
## Se emite al formarse o separarse un objeto especial (varias piezas).
signal special_object_formed(object: Node)
signal special_object_dissolved(object: Node)
## Se emite al pintar, borrar o reasignar una zona (para la futura IA).
signal zones_changed

const FLOOR_PREFAB := preload("res://prefabs/build/floor_tile.tscn")
const WALL_PREFAB := preload("res://prefabs/build/wall_segment.tscn")
const GHOST_SHADER := preload("res://scripts/systems/build/shaders/ghost.gdshader")
## Variante sin test de profundidad: el rojo del borrador se ve sobre la pieza.
const GHOST_ERASE_SHADER := preload("res://scripts/systems/build/shaders/ghost_erase.gdshader")
## Previsualizacion del pincel de pisos: plana, con borde y cuadricula por celda
## (a diferencia del holograma, que queda mejor para volumenes).
const FLOOR_PREVIEW_SHADER := preload("res://scripts/systems/build/shaders/floor_preview.gdshader")
const COLOR_OK := Color(0.25, 1.0, 0.6, 0.35)
const COLOR_BAD := Color(1.0, 0.3, 0.25, 0.42)
## Rojo de borrado: mismo lenguaje visual que los borradores del menu.
const COLOR_ERASE := Color(1.0, 0.3, 0.26, 0.5)

## Colores de la previsualizacion plana del piso (mas claros que el holograma
## para que se lean sobre el cesped y otros suelos claros).
const FLOOR_PREVIEW_FILL := Color(0.25, 1.0, 0.62)
const FLOOR_PREVIEW_LINE := Color(0.72, 1.0, 0.92)
const FLOOR_ERASE_FILL := Color(1.0, 0.3, 0.26)
const FLOOR_ERASE_LINE := Color(1.0, 0.62, 0.56)
## Altura de la previsualizacion de piso sobre el plano. Al construir queda
## pegada a la grilla; al borrar se sube sobre el suelo real para que el rojo
## de la zona a eliminar se vea entero.
const FLOOR_PREVIEW_LIFT := 0.03
const FLOOR_ERASE_PREVIEW_LIFT := 0.075

## Zonas logicas: se pintan sobre el piso y sirven para que la IA sepa que
## hay en cada area. El tipo es solo un dato; la IA se conectara mas adelante.
const ZONE_DEFAULT_TYPE := &"unassigned"
const ZONE_TYPES := {
	&"unassigned": {
		"name": "Sin asignar",
		"color": Color(0.72, 0.74, 0.82, 0.28),
	},
	&"hallway": {
		"name": "Pasillos",
		"color": Color(1.0, 0.8, 0.22, 0.52),
	},
	&"waiting": {
		"name": "Sala de espera",
		"color": Color(0.3, 0.62, 1.0, 0.52),
	},
	&"consult": {
		"name": "Consultorio",
		"color": Color(0.36, 0.95, 0.55, 0.52),
	},
}
## El overlay de zonas va por encima del piso (0.0625) y el preview un poco
## mas arriba para que se lea siempre.
const ZONE_OVERLAY_LIFT := 0.07
## El borde y las etiquetas se dibujan un poco mas arriba para no pelear con
## el relleno translucido de la zona.
const ZONE_BORDER_LIFT := 0.072
const ZONE_LABEL_LIFT := 0.076
const ZONE_BORDER_WIDTH := 0.06
const ZONE_PREVIEW_LIFT := 0.078
const ZONE_PREVIEW_FILL := Color(0.45, 0.62, 1.0)
const ZONE_PREVIEW_LINE := Color(0.82, 0.9, 1.0)
const ZONE_REVEAL_CELL_TIME := 0.04

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
## Desmontaje al borrar: cada celda/tramo se encoge un poco después del anterior.
const WALL_ERASE_STAGGER := 0.03
const WALL_ERASE_TIME := 0.14
const FLOOR_ERASE_STAGGER := 0.018
const FLOOR_ERASE_TIME := 0.12
const OBJECT_ERASE_STAGGER := 0.02
const OBJECT_ERASE_TIME := 0.12

@export var grid: BuildGrid
@export var build_camera: BuildCamera
@export var player: FPSController
@export var pieces_root: Node3D
@export var floor_scene: PackedScene = FLOOR_PREFAB
@export var wall_scene: PackedScene = WALL_PREFAB
@export var build_menu: BuildMenu
@export var items_dir: String = "res://data/build_items"
## Directorio de recetas de objetos especiales (combinaciones de piezas).
@export var special_objects_dir: String = "res://data/special_objects"

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
var erase_kind: EraseKind = EraseKind.ALL

var _floors: Dictionary = {}
## Celda -> altura de la cara superior de su piso (mundo). Alimenta la grilla
## secundaria que se dibuja solo sobre los pisos colocados.
var _floor_tops: Dictionary = {}
## Evita reconstruir la grilla de pisos varias veces por lote.
var _floor_grid_dirty := false
var _walls: Dictionary = {}
## Celda primaria -> pieza. Para objetos de varias celdas, `_object_cells`
## guarda todas las celdas cubiertas (y sirve para colisiones de huella).
var _objects: Dictionary = {}
## Todas las piezas de objeto, incluidas las que comparten celda ancla con otra
## pieza (por ejemplo la silla acoplada al escritorio). `_objects` es solo un
## indice por celda y puede quedarse con una sola; esta lista es la fuente de
## verdad para guardar y para buscar recetas.
var _object_pieces: Array[BuildPiece] = []
var _object_cells: Dictionary = {}

## Recetas de objetos especiales cargadas de `special_objects_dir`.
var special_object_defs: Array[SpecialObjectDef] = []
## Objetos especiales activos (combinaciones de piezas).
var _special_objects: Array[SpecialObject] = []
## Pieza -> objeto especial al que pertenece mientras la combinacion esta activa.
var _special_by_piece: Dictionary = {}

## Zonas pintadas: celda -> id de zona, e id de zona -> tipo.
var _zone_cells: Dictionary = {}
var _zone_types: Dictionary = {}
var _next_zone_id := 1

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

## Overlay de zonas (visible solo en modo construccion) y su pincel.
var _zones_overlay: MeshInstance3D
var _zones_material: StandardMaterial3D
var _zone_labels_root: Node3D
var _zone_preview: MeshInstance3D
var _zone_preview_material: ShaderMaterial
var _zone_preview_cells: Array[Vector2i] = []
var _zone_preview_cols := 1
var _zone_preview_rows := 1
var _zone_preview_mask: ImageTexture
var _zone_dragging := false
var _zone_drag_erasing := false
var _zone_drag_start := Vector2i.ZERO
var _zone_drag_cells: Array[Vector2i] = []
var _zone_drag_reveal := 0.0
var _zone_drag_started_on: StringName = &""
var _zone_menu_root: Control
var _zone_menu: PanelContainer
var _zone_menu_label: Label
var _zone_menu_buttons: Dictionary = {}
var _zone_menu_zone_id: StringName = &""
var _zone_menu_open := false
## Mientras dura una accion que pinta sobre el piso (piso, pared u objeto) las
## zonas se ocultan; al soltar vuelven a mostrarse.
var _zones_hidden_for_brush := false

var _wall_ghost: Node3D
var _object_ghost: Node3D

## Modelo real usado por el fantasma de paredes (misma escena que la pieza).
var _wall_ghost_model: Node3D
var _wall_ghost_material: ShaderMaterial
var _wall_ghost_aabb := AABB()
var _wall_ghost_scene: PackedScene
## Si el fantasma actual usa la variante de borrado (sin test de profundidad).
var _wall_ghost_erasing := false
## Desfase vertical del origen del modelo (las cajas procedurales se centran).
var _wall_ghost_base_offset := 0.0

## Modelo real usado por el fantasma de objetos (misma escena que la pieza).
var _object_ghost_model: Node3D
var _object_ghost_material: ShaderMaterial
var _object_ghost_aabb := AABB()
var _object_ghost_scene: PackedScene
var _object_ghost_footprint := Vector2i(1, 1)
## Si el fantasma actual usa la variante de borrado (sin test de profundidad).
var _object_ghost_erasing := false

var _hover_cell := Vector2i.ZERO
var _hover_wall := Vector3i.ZERO
## Desplazamiento fino (sub-grilla) del objeto bajo el cursor, relativo al
## centro de su huella. Se calcula al mover el mouse con la herramienta OBJECT.
var _hover_sub_offset := Vector3.ZERO
## Celda ancla resuelta para el fantasma. Puede no coincidir con `_hover_cell`
## cuando la pieza se acopla a una base y el sistema corre su ancla.
var _hover_anchor_cell := Vector2i.ZERO
## Rotacion resuelta para el fantasma (-1 = usar `_object_rotation`). Al acoplar
## una silla el sistema la gira sola para que mire a la base.
var _hover_rotation := -1
var _hovering := false
var _painting := false
var _floor_dragging := false
## true = el arrastre actual borra pisos en vez de construirlos.
var _floor_drag_erasing := false
var _floor_drag_start := Vector2i.ZERO
var _floor_drag_cells: Array[Vector2i] = []
## Progreso del "pintado" del rectangulo, en celdas completas.
var _floor_drag_reveal := 0.0
var _wall_dragging := false
## true = el arrastre actual borra paredes en vez de construirlas.
var _wall_drag_erasing := false
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
	_update_zones_for_tool()
	_rebuild_zones_overlay()
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
	_cancel_drags()
	_close_zone_menu()
	_hide_ghosts()
	if _zones_overlay != null:
		_zones_overlay.visible = false
	if _zone_labels_root != null:
		_zone_labels_root.visible = false
	_zones_hidden_for_brush = false

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
	if new_tool != tool:
		_cancel_drags()
	tool = new_tool
	_update_zones_for_tool()
	_update_ui()


## Cancela los arrastres de pared y piso y limpia sus previsualizaciones.
func _cancel_drags() -> void:
	if _wall_dragging:
		_clear_wall_drag_ghosts()
		_wall_dragging = false
	_wall_drag_erasing = false
	if _floor_dragging:
		_clear_floor_drag_preview()
		_floor_dragging = false
	_floor_drag_erasing = false
	if _zone_dragging:
		_clear_zone_drag_preview()
		_zone_dragging = false
	_zone_drag_erasing = false
	_update_zones_for_tool()


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
	if key_event.ctrl_pressed and not key_event.alt_pressed \
			and (key_event.keycode == KEY_S
				or key_event.physical_keycode == KEY_S):
		return true
	if InputMap.has_action("build_save") \
			and key_event.is_action_pressed("build_save"):
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

	# Con el menu de zonas abierto, Esc solo cierra el menu.
	if _zone_menu_open:
		if event.is_action_pressed("ui_cancel"):
			_close_zone_menu()
			get_viewport().set_input_as_handled()
		return

	if event.is_action_pressed("ui_cancel"):
		exit_build_mode()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("build_rotate") and tool == Tool.OBJECT:
		rotate_object()
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if not build_mode:
		return

	# Mientras el menu de asignacion de zona esta abierto, no se interactua con
	# el mundo (los botones del menu siguen recibiendo input normalmente).
	if _zone_menu_open:
		_hovering = false
		_hide_ghosts()
		_update_ui()
		return

	_hovering = _update_hover()
	var pressed := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	var over_ui := get_viewport().gui_get_hovered_control() != null

	# Permitir terminar un arrastre aunque el cursor salga de la grilla.
	if _wall_dragging:
		if pressed:
			if _hovering:
				_update_wall_drag(_delta)
		else:
			_finish_wall_drag()
			_hide_ghosts()
			_update_ui()
			return

	if _floor_dragging:
		if pressed:
			if _hovering:
				_update_floor_drag(_delta)
		else:
			_finish_floor_drag()
			_hide_ghosts()
			_update_ui()
			return

	if _zone_dragging:
		if pressed:
			if _hovering:
				_update_zone_drag(_delta)
		else:
			_finish_zone_drag()
			_hide_ghosts()
			_update_ui()
			return

	if not _hovering:
		_painting = false
		_hide_ghosts()
		_update_ui()
		return

	if tool == Tool.WALL:
		if pressed:
			if not _wall_dragging:
				_start_wall_drag()
			if _wall_dragging:
				_update_wall_drag(_delta)
	elif tool == Tool.FLOOR:
		# Clic y arrastrar: rectangulo de celdas con vista previa progresiva.
		if pressed:
			if not _floor_dragging and not over_ui:
				_start_floor_drag()
			if _floor_dragging:
				_update_floor_drag(_delta)
	elif tool == Tool.OBJECT:
		# Un clic = un objeto. Arrastrar no debe llenar la sala de muebles.
		# Ignorar clics sobre la UI (menú de items). Las zonas se ocultan solo
		# durante el clic de colocación y vuelven al soltar.
		if pressed and not _painting and not over_ui:
			_set_zones_hidden_for_brush(true)
			_apply_tool()
		elif not pressed and _painting:
			_update_zones_for_tool()
		_painting = pressed
	elif tool == Tool.ERASE and erase_kind == EraseKind.FLOOR:
		# Borrador de piso: igual que construir, pero el rectangulo elimina.
		if pressed:
			if not _floor_dragging and not over_ui:
				_start_floor_drag(true)
			if _floor_dragging:
				_update_floor_drag(_delta)
		_painting = pressed
	elif tool == Tool.ERASE and erase_kind == EraseKind.WALL:
		# Borrador de pared: arrastre en linea recta, como el pincel de paredes.
		if pressed:
			if not _wall_dragging and not over_ui:
				_start_wall_drag(true)
			if _wall_dragging:
				_update_wall_drag(_delta)
		_painting = pressed
	elif tool == Tool.ZONE:
		# Pincel de zonas: rectangulo, igual que el pincel de pisos.
		if pressed:
			if not _zone_dragging and not over_ui:
				_start_zone_drag(false)
			if _zone_dragging:
				_update_zone_drag(_delta)
		_painting = pressed
	elif tool == Tool.ZONE_ERASE:
		if pressed:
			if not _zone_dragging and not over_ui:
				_start_zone_drag(true)
			if _zone_dragging:
				_update_zone_drag(_delta)
		_painting = pressed
	else:
		# Borrado de objetos o generico: pintar mientras se mantiene pulsado.
		# Las zonas se ocultan solo durante el borrado y vuelven al soltar.
		_painting = pressed
		if _painting:
			_set_zones_hidden_for_brush(true)
			_apply_tool()
		else:
			_update_zones_for_tool()

	_update_ghosts()
	_update_zone_label_orientation()
	_update_ui()


# --------------------------------------------------------------------------
# Colocacion
# --------------------------------------------------------------------------

func get_floor_count() -> int:
	return _floors.size()


func get_wall_count() -> int:
	return _walls.size()


func get_object_count() -> int:
	var total := 0
	for piece in _object_pieces:
		if piece != null and is_instance_valid(piece):
			total += 1
	return total


## Objeto colocado cuya huella cubre `cell` (o null).
func get_object_at(cell: Vector2i) -> BuildPiece:
	if not _object_cells.has(cell):
		return null
	var piece = _object_cells[cell]
	return piece as BuildPiece


func get_objects() -> Array[BuildPiece]:
	var out: Array[BuildPiece] = []
	for piece in _object_pieces:
		if piece != null and is_instance_valid(piece):
			out.append(piece)
	return out


func get_special_object_count() -> int:
	return _special_objects.size()


func get_special_objects() -> Array[SpecialObject]:
	var out: Array[SpecialObject] = []
	for special in _special_objects:
		if is_instance_valid(special):
			out.append(special)
	return out


## Objeto especial cuya huella cubre `cell` (o null).
func get_special_object_at(cell: Vector2i) -> SpecialObject:
	var piece: BuildPiece = _object_cells.get(cell)
	if piece == null:
		return null
	return _special_by_piece.get(piece) as SpecialObject


## Objeto especial al que pertenece una pieza (o null).
func get_special_object_for(piece: BuildPiece) -> SpecialObject:
	if piece == null:
		return null
	return _special_by_piece.get(piece) as SpecialObject


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
		or not _object_pieces.is_empty()
	var had_zones := not _zone_cells.is_empty()
	_clear_corner_pieces()
	_wall_corner_path.clear()
	_hidden_walls.clear()
	# Los objetos especiales se liberan antes que sus piezas: no deben intentar
	# restaurar SmartObjects que tambien se estan borrando.
	for special in _special_objects:
		if is_instance_valid(special):
			special.queue_free()
	_special_objects.clear()
	_special_by_piece.clear()
	for piece: Node in _floors.values():
		piece.queue_free()
	for piece: Node in _walls.values():
		piece.queue_free()
	for piece: Node in _object_pieces:
		if is_instance_valid(piece):
			piece.queue_free()
	_floors.clear()
	_floor_tops.clear()
	_walls.clear()
	_objects.clear()
	_object_pieces.clear()
	_object_cells.clear()
	_zone_cells.clear()
	_zone_types.clear()
	_next_zone_id = 1
	_close_zone_menu()
	_rebuild_zones_overlay()
	_request_floor_grid_refresh()
	if had_pieces:
		pieces_changed.emit()
	if had_zones:
		zones_changed.emit()


## Coloca un suelo por API (misma validación que la herramienta).
func place_floor(cell: Vector2i) -> bool:
	return _place_floor(cell)


## Coloca una pared por API (misma validación que la herramienta).
func place_wall(key: Vector3i) -> bool:
	return _place_wall(key)


## Coloca el objeto seleccionado por API. `rotation_steps` = cuartos de vuelta.
func place_object(
	cell: Vector2i, rotation_steps: int = -1, sub_offset: Vector3 = Vector3.ZERO
) -> bool:
	if _selected_object_item == null:
		return false
	var steps := _object_rotation if rotation_steps < 0 else rotation_steps
	return _place_object(cell, _selected_object_item, steps, sub_offset)


## Coloca un BuildItem de tipo objeto concreto (útil para tests y scripts).
func place_object_item(
	item: BuildItem,
	cell: Vector2i,
	rotation_steps: int = 0,
	sub_offset: Vector3 = Vector3.ZERO
) -> bool:
	return _place_object(cell, item, rotation_steps, sub_offset)


## Borra por API respetando la prioridad de la herramienta (pared, luego suelo).
func erase_at(cell: Vector2i, wall: Vector3i, kind: EraseKind = EraseKind.ALL) -> bool:
	return _erase_at(cell, wall, kind)


func _apply_tool() -> void:
	match tool:
		Tool.FLOOR:
			_place_floor(_hover_cell)
		Tool.WALL:
			_place_wall(_hover_wall)
		Tool.OBJECT:
			if _selected_object_item != null:
				_place_object(_hover_cell, _selected_object_item, _object_rotation,
					_hover_sub_offset)
		Tool.ERASE:
			_erase_at(_hover_cell, _hover_wall, erase_kind)
		Tool.ZONE:
			_paint_zone_cells([_hover_cell])
		Tool.ZONE_ERASE:
			_erase_zone_cells([_hover_cell])


func _can_place_floor(cell: Vector2i) -> bool:
	return grid.is_cell_inside(cell) and not _floors.has(cell)


func _can_place_wall(key: Vector3i) -> bool:
	return grid.is_wall_inside(key) and not _walls.has(key)


## Huella efectiva del objeto segun su rotacion (cuartos de vuelta). Un objeto
## de 2x1 pasa a ocupar 1x2 al rotarse 90 grados.
func _object_footprint(item: BuildItem, rotation_steps: int = 0) -> Vector2i:
	var footprint := Vector2i(maxi(item.footprint.x, 1), maxi(item.footprint.y, 1))
	if wrapi(rotation_steps, 0, 4) % 2 == 1:
		return Vector2i(footprint.y, footprint.x)
	return footprint


## Desplazamiento desde el centro de la celda ancla hasta el centro de la
## huella. Para huellas pares el objeto queda centrado en el borde entre dos
## celdas, que es lo esperado para muebles de 2 celdas.
func _object_footprint_offset(footprint: Vector2i) -> Vector3:
	return Vector3(
		(float(footprint.x) - 1.0) * grid.cell_size * 0.5,
		0.0,
		(float(footprint.y) - 1.0) * grid.cell_size * 0.5
	)


## Celdas que ocupa un objeto segun el centro real de su huella. Se incluyen
## las celdas cuyo centro cae dentro del rectangulo, asi un objeto desplazado
## media celda bloquea y se puede borrar desde cualquiera de ellas.
func _object_cells_for(
	item: BuildItem,
	cell: Vector2i,
	rotation_steps: int = 0,
	sub_offset: Vector3 = Vector3.ZERO
) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	if item == null:
		return cells
	var footprint := _object_footprint(item, rotation_steps)
	var center := grid.cell_center(cell) \
		+ _object_footprint_offset(footprint) + sub_offset
	var half := Vector2(footprint.x, footprint.y) * grid.cell_size * 0.5
	var min_cell := grid.cell_from_world(center - Vector3(half.x, 0.0, half.y))
	var max_cell := grid.cell_from_world(center + Vector3(half.x, 0.0, half.y))
	var eps := 0.001
	for x in range(min_cell.x - 1, max_cell.x + 2):
		for z in range(min_cell.y - 1, max_cell.y + 2):
			var c := Vector2i(x, z)
			var cc := grid.cell_center(c)
			if cc.x < center.x - half.x - eps or cc.x > center.x + half.x + eps:
				continue
			if cc.z < center.z - half.y - eps or cc.z > center.z + half.y + eps:
				continue
			cells.append(c)
	return cells


## Resuelve la celda ancla y el sub-offset definitivos de una pieza antes de
## colocarla. Devuelve `[cell, sub_offset, rotation_steps]`.
##
## Si la pieza es el operador de una receta y el cursor esta sobre la base o de
## su lado, se acopla al unico punto valido: el centro del lado largo, apoyado
## contra el borde frontal. Nunca se permite que la silla quede centrada dentro
## de la base. Si no hay acople, se mantiene el snap normal.
func _resolve_part_anchor(
	cell: Vector2i,
	item: BuildItem,
	rotation_steps: int,
	sub_offset: Vector3
) -> Array:
	if item == null:
		return [cell, sub_offset, rotation_steps]

	var dock_base := _dock_base_for(cell, item)
	if dock_base != null:
		var dock_def := _special_def_for_pair(item.id, dock_base.item_id)
		if dock_def != null:
			var dock := _part_dock_target(dock_def, dock_base, item, cell)
			if not dock.is_empty():
				return [dock["cell"], dock["offset"], dock["rotation"]]

	# Aunque no corresponda moverla (por ejemplo, el cursor esta un poco mas
	# lejos del borde), una silla de escritorio cerca de su base se gira igual
	# para mirar al escritorio. Asi el acople se ve aunque el snap de posicion
	# no se active.
	var face_base := _dock_base_for(cell, item, 2, true)
	if face_base != null:
		var face_center := _piece_rect(face_base).get_center()
		var cursor_center := grid.cell_center(cell)
		var to_base := _snap_axis(Vector3(
			face_center.x - cursor_center.x, 0.0,
			face_center.y - cursor_center.z
		))
		if to_base != Vector2.ZERO:
			return [cell, sub_offset, _rotation_facing_direction(to_base)]

	var owner := _object_cells.get(cell) as BuildPiece
	if owner == null:
		return [cell, sub_offset, rotation_steps]
	var def := _special_def_for_piece(item, owner)
	if def == null or item.id == def.base_item_id:
		return [cell, sub_offset, rotation_steps]
	for axis in _anchor_move_axes(owner, item, cell, rotation_steps, sub_offset):
		var moved := cell + axis
		if not grid.is_cell_inside(moved):
			continue
		var moved_offset := sub_offset - Vector3(
			float(axis.x), 0.0, float(axis.y)
		) * grid.cell_size
		if _can_place_object_at(moved, item, rotation_steps, moved_offset):
			return [moved, moved_offset, rotation_steps]
	return [cell, sub_offset, rotation_steps]


## Base cercana a la celda del cursor a la que esta pieza podria acoplarse como
## operador. Solo cuenta si el cursor esta sobre la base o del lado del
## operador; asi una silla de escritorio usada como pieza client del otro lado
## no se corre sola.
##
## `max_distance` y `ignore_side` permiten buscar la base solo para orientar la
## silla hacia el escritorio sin moverla.
func _dock_base_for(
	cell: Vector2i,
	item: BuildItem,
	max_distance: int = 1,
	ignore_side: bool = false
) -> BuildPiece:
	if item == null:
		return null
	var best: BuildPiece = null
	var best_distance := 9999
	for candidate in _unique_object_pieces():
		var base := candidate
		var special := _special_by_piece.get(candidate) as SpecialObject
		if special != null:
			base = _special_base_piece(special)
			if base == null:
				continue
		var def := _special_def_for_pair(item.id, base.item_id)
		if def == null or item.id != def.part_item_id:
			continue
		var base_cells := _piece_cells(base)
		if base_cells.is_empty():
			continue
		var cursor_cells: Array[Vector2i] = [cell]
		var distance := _min_cell_distance(base_cells, cursor_cells)
		if distance > max_distance:
			continue
		var side := _resolved_operator_side(def, base)
		if not ignore_side and side != Vector2.ZERO and not base_cells.has(cell):
			var base_rect := _piece_rect(base)
			var cursor_center := grid.cell_center(cell)
			var to_cursor := Vector2(
				cursor_center.x - (base_rect.position.x + base_rect.size.x * 0.5),
				cursor_center.z - (base_rect.position.y + base_rect.size.y * 0.5)
			)
			if to_cursor.dot(side) < -0.001:
				continue
		if distance < best_distance:
			best = base
			best_distance = distance
	return best


## Posicion de acople de la pieza sobre la base: centrada en el lado largo y
## apoyada contra el borde del lado del operador. Devuelve un diccionario con
## `cell`, `offset` y `rotation`; vacio si no corresponde.
func _part_dock_target(
	def: SpecialObjectDef,
	base: BuildPiece,
	item: BuildItem,
	cursor_cell: Vector2i
) -> Dictionary:
	if def == null or base == null or item == null:
		return {}
	if not def.part_dock_center or item.id != def.part_item_id:
		return {}
	var side := _resolved_operator_side(def, base)
	if side == Vector2.ZERO:
		return {}
	var base_rect := _piece_rect(base)
	if base_rect.size == Vector2.ZERO or grid == null:
		return {}

	var rotation := _rotation_facing_side(side)
	var footprint := _object_footprint(item, rotation)
	var half_x := float(footprint.x) * grid.cell_size * 0.5
	var half_z := float(footprint.y) * grid.cell_size * 0.5
	var depth := maxf(def.part_dock_depth, 0.0)
	var center := base_rect.get_center()
	if not is_zero_approx(side.x):
		var edge := base_rect.end.x if side.x > 0.0 else base_rect.position.x
		center.x = edge + signf(side.x) * (half_x - depth)
	else:
		var edge := base_rect.end.y if side.y > 0.0 else base_rect.position.y
		center.y = edge + signf(side.y) * (half_z - depth)

	return _dock_anchor_for_center(
		center, item, rotation, base, cursor_cell)


## Busca la celda ancla libre que, con un sub-offset de media celda como maximo,
## deja la pieza con su centro en `center`. Prefiere la celda valida mas cercana
## al cursor y conserva un fallback para que el fantasma muestre el acople en
## rojo si esta bloqueado.
func _dock_anchor_for_center(
	center: Vector2,
	item: BuildItem,
	rotation_steps: int,
	base: BuildPiece,
	cursor_cell: Vector2i
) -> Dictionary:
	if grid == null:
		return {}
	var base_cells := _piece_cells(base)
	var half := grid.cell_size * 0.5 + 0.001
	# La grilla puede estar desplazada respecto del origen del mundo (map1 la
	# tiene en z = -25). Descontar su origen antes de pasar a celdas.
	var origin := grid.global_position
	var start := Vector2i(
		floori((center.x - origin.x) / grid.cell_size) - 1,
		floori((center.y - origin.z) / grid.cell_size) - 1
	)
	var best: Dictionary = {}
	var best_score := INF
	var fallback: Dictionary = {}
	var fallback_score := INF
	for x in range(start.x, start.x + 3):
		for z in range(start.y, start.y + 3):
			var candidate := Vector2i(x, z)
			if not grid.is_cell_inside(candidate) or base_cells.has(candidate):
				continue
			var cell_center := grid.cell_center(candidate)
			var offset := Vector3(
				center.x - cell_center.x, 0.0, center.y - cell_center.z)
			if absf(offset.x) > half or absf(offset.z) > half:
				continue
			var score := float(
				absi(candidate.x - cursor_cell.x)
				+ absi(candidate.y - cursor_cell.y))
			var entry := {
				"cell": candidate,
				"offset": offset,
				"rotation": rotation_steps,
			}
			if _can_place_object_at(
					candidate, item, rotation_steps, offset):
				if score < best_score:
					best = entry
					best_score = score
			elif _is_free_anchor_cell(candidate) and score < fallback_score:
				fallback = entry
				fallback_score = score
	if not best.is_empty():
		return best
	return fallback


## Una celda puede ser ancla si ninguna pieza la tiene como ancla todavia.
func _is_free_anchor_cell(cell: Vector2i) -> bool:
	if not _object_cells.has(cell):
		return true
	var owner := _object_cells[cell] as BuildPiece
	return owner == null or owner.cell != cell


## Rotacion de 90 grados que hace mirar el frente de la pieza (-Z local) hacia
## el lado opuesto de `side`, es decir, hacia la base.
func _rotation_facing_side(side: Vector2) -> int:
	return _rotation_facing_direction(-side)


## Rotacion de 90 grados que hace mirar el frente de la pieza (-Z local) hacia
## `direction`.
func _rotation_facing_direction(direction: Vector2) -> int:
	var target := Vector3(direction.x, 0.0, direction.y)
	if target.length() < 0.001:
		return 0
	target = target.normalized()
	var best_step := 0
	var best_dot := -2.0
	for step in 4:
		var forward := Basis(Vector3.UP, float(step) * PI * 0.5) * Vector3.FORWARD
		var dot := forward.dot(target)
		if dot > best_dot:
			best_dot = dot
			best_step = step
	return best_step


## Comprueba que la pieza este centrada en el lado largo de la base y apoyada
## contra su borde del lado del operador. `depth` permite un pequeño solape
## configurable (`part_dock_depth`), nunca suficiente para atravesar la base.
func _part_dock_geometry_matches(
	def: SpecialObjectDef,
	base_rect: Rect2,
	part_rect: Rect2,
	side: Vector2
) -> bool:
	if side == Vector2.ZERO:
		return true
	var eps := 0.001
	var gap := maxf(def.max_gap, 0.0)
	var depth := maxf(def.part_dock_depth, 0.0)
	var base_center := base_rect.get_center()
	var part_center := part_rect.get_center()
	if not is_zero_approx(side.x):
		if absf(part_center.y - base_center.y) > eps:
			return false
		if side.x > 0.0:
			var inner := part_rect.position.x
			var edge := base_rect.end.x - depth
			return inner >= edge - eps and inner <= edge + gap
		var inner_right := part_rect.end.x
		var edge_left := base_rect.position.x + depth
		return inner_right <= edge_left + eps and inner_right >= edge_left - gap
	if absf(part_center.x - base_center.x) > eps:
		return false
	if side.y > 0.0:
		var inner := part_rect.position.y
		var edge := base_rect.end.y - depth
		return inner >= edge - eps and inner <= edge + gap
	var inner_bottom := part_rect.end.y
	var edge_top := base_rect.position.y + depth
	return inner_bottom <= edge_top + eps and inner_bottom >= edge_top - gap


## Orden en que se prueban las celdas vecinas para sacar el ancla de la base.
## Primero la direccion del sub-offset (si existe) y despues el lado por el que
## la pieza esta mas metida en la base.
func _anchor_move_axes(
	owner: BuildPiece,
	item: BuildItem,
	cell: Vector2i,
	rotation_steps: int,
	sub_offset: Vector3
) -> Array[Vector2i]:
	var axes: Array[Vector2i] = []
	if not is_zero_approx(sub_offset.x):
		axes.append(Vector2i(int(signf(sub_offset.x)), 0))
	if not is_zero_approx(sub_offset.z):
		axes.append(Vector2i(0, int(signf(sub_offset.z))))

	var base_rect := _piece_rect(owner)
	var part_rect := _rect_for_item(item, cell, rotation_steps, sub_offset)
	if base_rect.size == Vector2.ZERO or part_rect.size == Vector2.ZERO:
		return axes
	var center := part_rect.get_center()
	var edges := [
		[Vector2i(-1, 0), center.x - base_rect.position.x],
		[Vector2i(1, 0), base_rect.end.x - center.x],
		[Vector2i(0, -1), center.y - base_rect.position.y],
		[Vector2i(0, 1), base_rect.end.y - center.y],
	]
	edges.sort_custom(func(a: Array, b: Array) -> bool:
		return float(a[1]) < float(b[1]))
	for edge in edges:
		var axis: Vector2i = edge[0]
		if not axes.has(axis):
			axes.append(axis)
	return axes


## Base de un objeto especial ya formado (siempre es la primera pieza).
func _special_base_piece(special: SpecialObject) -> BuildPiece:
	if special == null:
		return null
	var parts := special.get_parts()
	if parts.is_empty():
		return null
	return parts[0]


## Pieza operadora de un objeto especial ya formado (siempre es la segunda).
func _special_part_piece(special: SpecialObject) -> BuildPiece:
	if special == null:
		return null
	var parts := special.get_parts()
	if parts.size() < 2:
		return null
	return parts[1]


## Receta que relaciona `item` con una pieza ya colocada. Si la pieza pertenece
## a un objeto especial, se compara contra la base del conjunto.
func _special_def_for_piece(
	item: BuildItem, other: BuildPiece
) -> SpecialObjectDef:
	if item == null or other == null:
		return null
	var other_id := other.item_id
	var special := _special_by_piece.get(other) as SpecialObject
	if special != null:
		var base := _special_base_piece(special)
		if base != null:
			other_id = base.item_id
	return _special_def_for_pair(item.id, other_id)


## Comprueba que `item` pueda compartir celdas con un objeto especial ya
## formado. Solo las piezas de la misma receta (operador o clientes) pueden
## hacerlo; si ademas encaja como client, el conjunto se rehace al colocarla.
## El lado y la orientacion se validan recien al formar el conjunto: igual que
## con las piezas sueltas, el fantasma no se pone rojo por eso.
func _can_extend_special(
	def: SpecialObjectDef,
	special: SpecialObject,
	base: BuildPiece,
	item: BuildItem,
	_cell: Vector2i,
	_rotation_steps: int,
	_sub_offset: Vector3
) -> bool:
	if def == null or special == null or base == null or item == null:
		return false
	if item.id == def.base_item_id:
		return false
	return item.id == def.part_item_id or def.is_client_item(item.id)


## `_special_client_matches` para una pieza que todavia no esta instanciada.
func _can_place_object(
	cell: Vector2i,
	item: BuildItem,
	rotation_steps: int = 0,
	sub_offset: Vector3 = Vector3.ZERO
) -> bool:
	var resolved := _resolve_part_anchor(cell, item, rotation_steps, sub_offset)
	return _can_place_object_at(
		resolved[0], item, int(resolved[2]), resolved[1])


func _can_place_object_at(
	cell: Vector2i,
	item: BuildItem,
	rotation_steps: int = 0,
	sub_offset: Vector3 = Vector3.ZERO
) -> bool:
	if item == null or item.scene == null:
		return false
	if not grid.is_cell_inside(cell):
		return false
	# Dos piezas no pueden compartir la celda ancla: el guardado y el borrado se
	# indexan por esa celda. Las celdas compartidas de la huella si valen.
	if _object_cells.has(cell):
		var anchor_owner := _object_cells[cell] as BuildPiece
		if anchor_owner != null and anchor_owner.cell == cell:
			return false
	var cells := _object_cells_for(item, cell, rotation_steps, sub_offset)
	if cells.is_empty():
		return false

	# Una pieza de un objeto especial puede compartir celdas con su pareja:
	# por ejemplo, la silla de escritorio puede quedar medio metro debajo del
	# escritorio. Las celdas compartidas siguen perteneciendo a la base.
	var shared_def: SpecialObjectDef = null
	var shared_other: BuildPiece = null
	for c in cells:
		if not grid.is_cell_inside(c):
			return false
		if require_floor_for_objects and not _floors.has(c):
			return false
		if not _object_cells.has(c):
			continue
		var other := _object_cells[c] as BuildPiece
		if other == null:
			return false
		# Si la celda pertenece a un objeto especial ya formado, la pieza nueva
		# solo puede compartirla si amplia ese mismo conjunto (por ejemplo, una
		# segunda silla de pacientes metida medio metro hacia el escritorio).
		var other_special := _special_by_piece.get(other) as SpecialObject
		var def: SpecialObjectDef = null
		var def_other: BuildPiece = other
		if other_special != null:
			def_other = _special_base_piece(other_special)
			if def_other == null:
				return false
			def = _special_def_for_pair(item.id, def_other.item_id)
			if def == null or not _can_extend_special(
					def, other_special, def_other, item, cell,
					rotation_steps, sub_offset):
				return false
			# Solo se comparten celdas con la base. Dos piezas acopladas
			# (operador, clientes) no se pisan entre si.
			if other != def_other:
				return false
		else:
			def = _special_def_for_pair(item.id, other.item_id)
			if def == null:
				return false
		# La pieza acoplada no puede tener su celda ancla debajo de la base.
		if item.id != def.base_item_id and c == cell:
			return false
		if shared_other == null:
			shared_other = def_other
			shared_def = def
		elif shared_other != def_other or shared_def != def:
			return false

	# Una pieza que solo comparte celdas con el conjunto necesita al menos una
	# celda propia para poder borrarse y guardarse. Vale su celda ancla aunque
	# la huella quede entera sobre la base. La base si puede reclamar celdas.
	if shared_def != null and item.id != shared_def.base_item_id:
		var owns_cell := not _object_cells.has(cell)
		if not owns_cell:
			for c in cells:
				if not _object_cells.has(c):
					owns_cell = true
					break
		if not owns_cell:
			return false

	if shared_def != null and not _special_placement_matches(
			shared_def, shared_other, item, cell, rotation_steps, sub_offset, false):
		return false
	return true


## Receta que relaciona dos items, sin importar cual es la base y cual la pieza.
func _special_def_for_pair(
	item_id: StringName, other_id: StringName
) -> SpecialObjectDef:
	for def in special_object_defs:
		if def == null or not def.is_valid():
			continue
		if (item_id == def.base_item_id and other_id == def.part_item_id) \
				or (item_id == def.part_item_id and other_id == def.base_item_id):
			return def
	return null


## Comprueba si la colocacion hipotetica de `item` forma una pareja valida con
## `other` (que ya esta colocado). Se usa antes de permitir celdas compartidas.
func _special_placement_matches(
	def: SpecialObjectDef,
	other: BuildPiece,
	item: BuildItem,
	cell: Vector2i,
	rotation_steps: int,
	sub_offset: Vector3,
	check_facing: bool = true
) -> bool:
	var placing_base := item.id == def.base_item_id
	var base_rect: Rect2
	var part_rect: Rect2
	var part_rotation: int
	var base_cells: Array[Vector2i]
	var part_cells: Array[Vector2i]
	if placing_base:
		base_rect = _rect_for_item(item, cell, rotation_steps, sub_offset)
		part_rect = _piece_rect(other)
		part_rotation = other.object_rotation_steps
		base_cells = _object_cells_for(item, cell, rotation_steps, sub_offset)
		part_cells = _piece_cells(other)
	else:
		base_rect = _piece_rect(other)
		part_rect = _rect_for_item(item, cell, rotation_steps, sub_offset)
		part_rotation = rotation_steps
		base_cells = _piece_cells(other)
		part_cells = _object_cells_for(item, cell, rotation_steps, sub_offset)

	if base_rect.size == Vector2.ZERO or part_rect.size == Vector2.ZERO:
		return false
	# La pieza acoplada nunca puede quedar centrada dentro de la base: se veria
	# atravesandola. Como maximo puede quedar medio metro metida desde un borde,
	# con el centro justo sobre el borde de la huella.
	if base_rect.grow(-0.01).has_point(part_rect.get_center()):
		return false
	if not base_rect.grow(maxf(def.max_gap, 0.0)).intersects(part_rect):
		return false
	if not _cells_adjacent_or_shared(base_cells, part_cells):
		return false
	if not placing_base and def.part_dock_center \
			and item.id == def.part_item_id:
		var side := _resolved_operator_side(def, other)
		if side != Vector2.ZERO:
			var base_center := base_rect.get_center()
			var part_center := part_rect.get_center()
			var to_part := Vector2(
				part_center.x - base_center.x, part_center.y - base_center.y)
			if to_part.dot(side) > 0.0 \
					and not _part_dock_geometry_matches(
						def, base_rect, part_rect, side):
				return false
	if check_facing and def.require_facing:
		var yaw := float(part_rotation) * PI * 0.5
		var forward := Basis(Vector3.UP, yaw) * Vector3.FORWARD
		var base_center := base_rect.get_center()
		var part_center := part_rect.get_center()
		var to_base := Vector3(
			base_center.x - part_center.x, 0.0, base_center.y - part_center.y
		)
		if to_base.length() < 0.001:
			return false
		if forward.normalized().dot(to_base.normalized()) < def.facing_dot:
			return false
	return true


## Rectangulo XZ de una colocacion hipotetica (todavia no instanciada).
func _rect_for_item(
	item: BuildItem,
	cell: Vector2i,
	rotation_steps: int,
	sub_offset: Vector3
) -> Rect2:
	if item == null or grid == null:
		return Rect2()
	var footprint := _object_footprint(item, rotation_steps)
	var half := Vector2(footprint.x, footprint.y) * grid.cell_size * 0.5
	var center := grid.cell_center(cell) \
		+ _object_footprint_offset(footprint) + sub_offset
	return Rect2(Vector2(center.x, center.z) - half, half * 2.0)


func _cells_adjacent_or_shared(
	a: Array[Vector2i], b: Array[Vector2i]
) -> bool:
	for ca in a:
		for cb in b:
			if absi(ca.x - cb.x) + absi(ca.y - cb.y) <= 1:
				return true
	return false


## Instancia un objeto (mueble/prop). La raíz de la escena puede ser un
## SmartObject; si no lo es, `_spawn_piece` la envuelve en un BuildPiece.
## `sub_offset` permite desplazarlo en pasos de sub-grilla (0,5 m).
func _place_object(
	cell: Vector2i,
	item: BuildItem,
	rotation_steps: int,
	sub_offset: Vector3 = Vector3.ZERO
) -> bool:
	var resolved := _resolve_part_anchor(cell, item, rotation_steps, sub_offset)
	cell = resolved[0]
	sub_offset = resolved[1]
	var steps := wrapi(int(resolved[2]), 0, 4)
	if not _can_place_object_at(cell, item, steps, sub_offset):
		return false

	var piece := _spawn_piece(item.scene, true, item.smart_object, true)
	if piece == null:
		return false

	if piece is SmartObject:
		var smart := piece as SmartObject
		if smart.definition == null and item.smart_object != null:
			smart.definition = item.smart_object

	var yaw := float(steps) * PI * 0.5
	var footprint := _object_footprint(item, steps)
	piece.is_wall = false
	piece.cell = cell
	piece.item_id = item.id
	piece.object_rotation_steps = steps
	piece.sub_offset = sub_offset
	piece.name = "Object_%s_%d_%d" % [String(item.id), cell.x, cell.y]
	piece.global_position = grid.cell_center(cell) \
		+ _object_footprint_offset(footprint) + sub_offset \
		+ Vector3.UP * object_height_offset
	piece.global_rotation = Vector3(0.0, yaw, 0.0)

	_claim_object_cells(piece, item, cell, steps, sub_offset)
	_objects[cell] = piece
	if not _object_pieces.has(piece):
		_object_pieces.append(piece)

	# Una pieza recien colocada puede cerrar una receta de objeto especial.
	_try_form_special_object(piece)

	object_placed.emit(piece)
	pieces_changed.emit()
	return true


## Registra las celdas que ocupa una pieza. En una pareja de objeto especial,
## las celdas compartidas se quedan con la base: la silla no le roba la huella
## al escritorio. Al colocar la base, esta reclama las celdas compartidas.
##
## Si la huella quedo entera sobre la base, la pieza igual conserva su celda
## ancla para poder borrarse y guardarse.
func _claim_object_cells(
	piece: BuildPiece,
	item: BuildItem,
	cell: Vector2i,
	rotation_steps: int,
	sub_offset: Vector3
) -> void:
	for c in _object_cells_for(item, cell, rotation_steps, sub_offset):
		if not _object_cells.has(c):
			_object_cells[c] = piece
			continue
		var other := _object_cells[c] as BuildPiece
		var def := _special_def_for_pair(item.id, other.item_id) \
			if other != null else null
		if def != null and item.id == def.base_item_id:
			_object_cells[c] = piece
	# El ancla siempre debe pertenecer a la pieza, aunque su huella quede sobre
	# la base y las celdas de la huella se compartan.
	if not _object_cells.has(cell):
		_object_cells[cell] = piece


# --------------------------------------------------------------------------
# Objetos especiales (combinaciones de piezas)
# --------------------------------------------------------------------------

## Busca una receta que la pieza recien colocada pueda completar y forma el
## objeto especial. Devuelve el nodo combinado o null.
func _try_form_special_object(placed: BuildPiece) -> SpecialObject:
	if placed == null or special_object_defs.is_empty():
		return null
	if _special_by_piece.has(placed):
		return null
	for def in special_object_defs:
		if def == null or not def.is_valid():
			continue

		# Si la pieza nueva es la silla del operador y quedo mas cerca del
		# escritorio que la actual, se intercambian los papeles: la mas cercana
		# pasa a ser el operador y la anterior queda como asiento.
		if def.part_item_id == placed.item_id:
			var swapped := _try_swap_special_part(def, placed)
			if swapped != null:
				return swapped

		# Si ya existe un conjunto y se coloca otra pieza client valida, se
		# rehace el conjunto con todas las piezas client.
		if def.has_clients() and def.is_client_item(placed.item_id):
			var upgraded := _try_upgrade_special_clients(def, placed)
			if upgraded != null:
				return upgraded

		# La misma pieza puede ser operador o client (por ejemplo, una silla de
		# escritorio suelta). Si ya hay un operador valido, se interpreta como
		# client antes de intentar crear otro operador.
		if def.is_client_item(placed.item_id):
			var as_client := _try_form_from_client(def, placed)
			if as_client != null:
				return as_client

		var formed := _try_form_from_base(def, placed)
		if formed != null:
			return formed
		formed = _try_form_from_part(def, placed)
		if formed != null:
			return formed
	return null


## Intenta formar la receta cuando la pieza colocada es la base.
func _try_form_from_base(
	def: SpecialObjectDef, placed: BuildPiece
) -> SpecialObject:
	if placed.item_id != def.base_item_id:
		return null
	var part := _find_special_part(placed, def)
	if part == null:
		return null
	return _finish_special_candidate(def, placed, part)


## Intenta formar la receta cuando la pieza colocada es la que se acopla.
func _try_form_from_part(
	def: SpecialObjectDef, placed: BuildPiece
) -> SpecialObject:
	if placed.item_id != def.part_item_id:
		return null
	var base := _find_special_base(placed, def)
	if base == null:
		return null
	return _finish_special_candidate(def, base, placed)


## Intenta formar la receta cuando la pieza colocada es una pieza client.
func _try_form_from_client(
	def: SpecialObjectDef, placed: BuildPiece
) -> SpecialObject:
	if not def.is_client_item(placed.item_id):
		return null
	for candidate in _unique_object_pieces():
		if candidate.item_id != def.base_item_id \
				or _special_by_piece.has(candidate):
			continue
		var candidate_part := _find_special_part(candidate, def, placed)
		if candidate_part == null:
			continue
		var clients := _find_special_clients(def, candidate, candidate_part)
		if not clients.has(placed):
			continue
		if not _prepare_special_pair(def, candidate, candidate_part):
			continue
		return _form_special_object(def, candidate, candidate_part, clients)
	return null


func _finish_special_candidate(
	def: SpecialObjectDef, base: BuildPiece, part: BuildPiece
) -> SpecialObject:
	var clients := _find_special_clients(def, base, part)
	if clients.size() < def.client_min_count:
		return null
	if not _prepare_special_pair(def, base, part):
		return null
	return _form_special_object(def, base, part, clients)


## Piezas client (por ejemplo, sillas de pacientes) del lado opuesto a la
## pieza acoplada, con una separacion de `client_gap` celdas.
func _find_special_clients(
	def: SpecialObjectDef, base: BuildPiece, part: BuildPiece
) -> Array[BuildPiece]:
	var out: Array[BuildPiece] = []
	if def == null or not def.has_clients() or base == null or part == null:
		return out

	var direction := _part_anchor_direction(base, part)
	if direction == Vector2.ZERO:
		return out

	var base_cells := _piece_cells(base)
	var base_rect := _piece_rect(base)
	var base_center := Vector3(
		base.global_position.x, 0.0, base.global_position.z
	)
	for candidate in _unique_object_pieces():
		if candidate == base or candidate == part:
			continue
		if not def.is_client_item(candidate.item_id):
			continue
		if _special_by_piece.has(candidate):
			continue
		if not _special_client_matches(
				def, base, direction, base_cells, base_rect, base_center, candidate):
			continue
		out.append(candidate)

	out.sort_custom(func(a: BuildPiece, b: BuildPiece) -> bool:
		return base.global_position.distance_squared_to(a.global_position) \
			< base.global_position.distance_squared_to(b.global_position)
	)
	if def.client_max_count > 0 and out.size() > def.client_max_count:
		out.resize(def.client_max_count)
	return out


## Si la silla colocada es la del operador y quedo mas cerca del escritorio que
## la actual, rehace el conjunto para que la mas cercana sea el operador. La
## silla anterior pasa a ser un asiento de paciente.
func _try_swap_special_part(
	def: SpecialObjectDef, placed: BuildPiece
) -> SpecialObject:
	if def == null or placed == null or def.part_item_id != placed.item_id:
		return null
	for special in _special_objects:
		if special == null or not is_instance_valid(special):
			continue
		if special.get_special_id() != def.id:
			continue
		var parts := special.get_parts()
		if parts.size() < 2:
			continue
		var base := parts[0]
		var current_part := parts[1]
		if base == placed or current_part == placed:
			continue
		# Si hay una banca de pacientes, ella define el lado del operador.
		if _bench_side_for(def, base) != Vector2.ZERO:
			continue
		# No se reacomoda un conjunto que el medico esta usando ahora mismo.
		if special.has_affordance(&"work") and special.find_free_slot(&"work") < 0:
			continue
		if not _special_pair_geometry_matches(def, base, placed):
			if not _try_dock_existing_part(def, base, placed) \
					or not _special_pair_geometry_matches(def, base, placed):
				continue
		if not _part_on_operator_side(def, base, placed):
			continue
		var new_dir := _anchor_direction_from_cells(_piece_cells(base), placed.cell)
		var part_dir := _part_anchor_direction(base, current_part)
		if new_dir == Vector2.ZERO or new_dir == part_dir:
			continue
		# Si ya hay un asiento de paciente en ese lado, la silla nueva es otro
		# asiento, no el operador.
		var same_client_side := false
		for i in range(2, parts.size()):
			if _part_anchor_direction(base, parts[i]) == new_dir:
				same_client_side = true
				break
		if same_client_side:
			continue
		var new_distance := base.global_position.distance_to(placed.global_position)
		var old_distance := base.global_position.distance_to(
			current_part.global_position)
		# Solo se reacomoda si la silla nueva esta claramente mas cerca. Asi una
		# silla de paciente apenas metida bajo la mesa no le roba el operador.
		if new_distance >= old_distance - 0.35:
			continue

		var clients: Array[BuildPiece] = []
		for i in range(2, parts.size()):
			clients.append(parts[i])
		clients.append(current_part)
		clients.sort_custom(func(a: BuildPiece, b: BuildPiece) -> bool:
			return base.global_position.distance_squared_to(a.global_position) \
				< base.global_position.distance_squared_to(b.global_position)
		)
		if def.client_max_count > 0 and clients.size() > def.client_max_count:
			clients.resize(def.client_max_count)
		if not _prepare_special_pair(def, base, placed):
			continue

		_dissolve_special_object(special, false)
		var formed := _form_special_object(def, base, placed, clients)
		if formed != null and OS.is_debug_build():
			print("[BuildController] Operador reacoplado a la silla mas cercana.")
		return formed
	return null


## Si ya hay un Escritorio de trabajo formado y se coloca otra pieza client
## valida (por ejemplo, una segunda silla de pacientes), rehace el conjunto con
## todas las piezas client para que sus asientos queden integrados.
func _try_upgrade_special_clients(
	def: SpecialObjectDef, placed: BuildPiece
) -> SpecialObject:
	for special in _special_objects:
		if special == null or not is_instance_valid(special):
			continue
		if special.get_special_id() != def.id:
			continue
		var parts := special.get_parts()
		if parts.size() < 2:
			continue
		var base := parts[0]
		var part := parts[1]
		var direction := _part_anchor_direction(base, part)
		if direction == Vector2.ZERO:
			continue
		if not _special_client_matches(
				def, base, direction, _piece_cells(base), _piece_rect(base),
				Vector3(base.global_position.x, 0.0, base.global_position.z), placed):
			continue

		var clients: Array[BuildPiece] = []
		for i in range(2, parts.size()):
			clients.append(parts[i])
		if def.client_max_count > 0 and clients.size() >= def.client_max_count:
			continue
		clients.append(placed)
		if not _prepare_special_pair(def, base, part):
			continue

		_dissolve_special_object(special, false)
		return _form_special_object(def, base, part, clients)
	return null


func _special_client_matches(
	def: SpecialObjectDef,
	base: BuildPiece,
	direction: Vector2,
	base_cells: Array[Vector2i],
	base_rect: Rect2,
	base_center: Vector3,
	candidate: BuildPiece
) -> bool:
	# Debe estar del lado opuesto a la pieza acoplada.
	var to_client := Vector2(
		candidate.global_position.x - base_center.x,
		candidate.global_position.z - base_center.z
	)
	if to_client.dot(direction) >= 0.0:
		return false

	# Distancia exacta entre la base y el cliente: `client_gap` celdas vacias.
	var min_distance := _min_cell_distance(base_cells, _piece_cells(candidate))
	if min_distance != def.client_gap + 1:
		return false

	# Tiene que entrar en el ancho lateral de la base (a los lados).
	return _lateral_overlaps(
		base_rect, _piece_rect(candidate), direction,
		def.client_lateral_tolerance * grid.cell_size
	)


## Direccion de la pieza acoplada respecto de la base, ajustada al eje mas
## cercano. Devuelve un vector unitario en X o Z.
func _snap_axis(value: Vector3) -> Vector2:
	if absf(value.x) >= absf(value.z):
		var sx := signf(value.x)
		return Vector2(sx, 0.0) if sx != 0.0 else Vector2.ZERO
	var sz := signf(value.z)
	return Vector2(0.0, sz) if sz != 0.0 else Vector2.ZERO


## Direccion desde las celdas de la base hacia una celda ancla, usando la celda
## de base mas cercana. No depende de la rotacion.
func _anchor_direction_from_cells(
	base_cells: Array[Vector2i], anchor: Vector2i
) -> Vector2:
	if base_cells.is_empty():
		return Vector2.ZERO
	var best := 9999
	var direction := Vector2.ZERO
	for base_cell in base_cells:
		var distance := absi(anchor.x - base_cell.x) + absi(anchor.y - base_cell.y)
		if distance == 0 or distance >= best:
			continue
		best = distance
		direction = _snap_axis(Vector3(
			anchor.x - base_cell.x, 0.0, anchor.y - base_cell.y
		))
	return direction


## Direccion desde la base hacia la pieza acoplada, usando su celda ancla.
func _part_anchor_direction(base: BuildPiece, part: BuildPiece) -> Vector2:
	if base == null or part == null:
		return Vector2.ZERO
	return _anchor_direction_from_cells(_piece_cells(base), part.cell)


## Lado del operador en el mundo, rotado con la base.
func _operator_side_for_rotation(
	def: SpecialObjectDef, rotation_steps: int
) -> Vector2:
	if def == null or def.operator_side == Vector2i.ZERO:
		return Vector2.ZERO
	var side := Vector3(def.operator_side.x, 0.0, def.operator_side.y)
	var yaw := float(rotation_steps) * PI * 0.5
	return _snap_axis(Basis(Vector3.UP, yaw) * side)


func _operator_side_world(def: SpecialObjectDef, base: BuildPiece) -> Vector2:
	if base == null:
		return Vector2.ZERO
	return _operator_side_for_rotation(def, base.object_rotation_steps)


## Lado donde esta la banca de pacientes (si hay una sola, sin ambiguedad).
## `Vector2.ZERO` si no hay banca o hay bancas en lados distintos.
func _bench_side_for(def: SpecialObjectDef, base: BuildPiece) -> Vector2:
	if def == null or base == null:
		return Vector2.ZERO
	var base_cells := _piece_cells(base)
	if base_cells.is_empty():
		return Vector2.ZERO
	var bench_side := Vector2.ZERO
	var bench_found := false
	var ambiguous := false
	for candidate in _unique_object_pieces():
		if candidate == base or _special_by_piece.has(candidate):
			continue
		if not def.is_client_item(candidate.item_id):
			continue
		# Las sillas de escritorio podrian ser operador: no definen el lado.
		if candidate.item_id == def.part_item_id:
			continue
		var distance := _min_cell_distance(base_cells, _piece_cells(candidate))
		if distance != def.client_gap + 1:
			continue
		var direction := _anchor_direction_from_cells(base_cells, candidate.cell)
		if direction == Vector2.ZERO:
			continue
		if not bench_found:
			bench_side = direction
			bench_found = true
		elif not ambiguous and direction != bench_side:
			ambiguous = true
	if bench_found and not ambiguous:
		return bench_side
	return Vector2.ZERO


## Lado del operador para una base concreta. Si hay una banca de pacientes
## acoplada a la base, el operador va del lado opuesto. Si no hay banca, se usa
## el lado configurado solo como pista de colocacion; cualquier silla adyacente
## puede ser el operador.
func _resolved_operator_side(def: SpecialObjectDef, base: BuildPiece) -> Vector2:
	var bench := _bench_side_for(def, base)
	if bench != Vector2.ZERO:
		return -bench
	return _operator_side_world(def, base)


## La pieza acoplada debe estar del lado del operador resuelto para esa base.
## Sin banca de pacientes, cualquier lado adyacente sirve como operador.
func _part_on_operator_side(
	def: SpecialObjectDef, base: BuildPiece, part: BuildPiece
) -> bool:
	if _bench_side_for(def, base) == Vector2.ZERO:
		return true
	var side := _resolved_operator_side(def, base)
	if side == Vector2.ZERO:
		return true
	return _part_anchor_direction(base, part) == side


func _min_cell_distance(a: Array[Vector2i], b: Array[Vector2i]) -> int:
	var best := 9999
	for ca in a:
		for cb in b:
			var distance := absi(ca.x - cb.x) + absi(ca.y - cb.y)
			if distance < best:
				best = distance
	return best


func _lateral_overlaps(
	base_rect: Rect2, client_rect: Rect2, direction: Vector2, tolerance: float
) -> bool:
	if absf(direction.x) > 0.0:
		# Operador a los lados en X: el ancho lateral es Z.
		var base_min := base_rect.position.y
		var base_max := base_rect.end.y
		var client_min := client_rect.position.y
		var client_max := client_rect.end.y
		return client_min <= base_max + tolerance \
			and client_max >= base_min - tolerance
	var base_min := base_rect.position.x
	var base_max := base_rect.end.x
	var client_min := client_rect.position.x
	var client_max := client_rect.end.x
	return client_min <= base_max + tolerance \
		and client_max >= base_min - tolerance


## Corre una pieza ya colocada al punto de acople de la base cuando la base se
## coloca despues que ella. Solo mueve piezas que ya estan del lado del
## operador: una silla usada como client del otro lado no se toca.
func _try_dock_existing_part(
	def: SpecialObjectDef, base: BuildPiece, part: BuildPiece
) -> bool:
	if def == null or base == null or part == null:
		return false
	if not def.part_dock_center or part.item_id != def.part_item_id:
		return false
	var side := _resolved_operator_side(def, base)
	if side == Vector2.ZERO:
		return false
	var base_rect := _piece_rect(base)
	var part_rect := _piece_rect(part)
	if base_rect.size == Vector2.ZERO or part_rect.size == Vector2.ZERO:
		return false
	var to_part := part_rect.get_center() - base_rect.get_center()
	if to_part.dot(side) < -0.25:
		return false
	var item := _find_item_by_id(part.item_id)
	if item == null:
		return false
	var dock := _part_dock_target(def, base, item, part.cell)
	if dock.is_empty():
		return false
	var new_cell: Vector2i = dock["cell"]
	var new_offset: Vector3 = dock["offset"]
	var new_rotation: int = dock["rotation"]
	if new_cell == part.cell \
			and new_offset.is_equal_approx(part.sub_offset) \
			and new_rotation == part.object_rotation_steps:
		return true

	var old_cell := part.cell
	var old_offset := part.sub_offset
	var old_rotation := part.object_rotation_steps
	_release_object_cells(part)
	if not _can_place_object_at(new_cell, item, new_rotation, new_offset):
		_claim_object_cells(part, item, old_cell, old_rotation, old_offset)
		_objects[old_cell] = part
		return false

	part.cell = new_cell
	part.sub_offset = new_offset
	part.object_rotation_steps = new_rotation
	part.global_position = grid.cell_center(new_cell) \
		+ _object_footprint_offset(_object_footprint(item, new_rotation)) \
		+ new_offset + Vector3.UP * object_height_offset
	part.global_rotation = Vector3(0.0, float(new_rotation) * PI * 0.5, 0.0)
	_claim_object_cells(part, item, new_cell, new_rotation, new_offset)
	_objects[new_cell] = part
	return true


## Libera la ocupacion de una pieza antes de recalcular su celda.
func _release_object_cells(piece: BuildPiece) -> void:
	if piece == null:
		return
	for key in _object_cells.keys():
		if _object_cells[key] == piece:
			_object_cells.erase(key)
	if _objects.get(piece.cell) == piece:
		_objects.erase(piece.cell)


func _find_special_part(
	base: BuildPiece, def: SpecialObjectDef, exclude: BuildPiece = null
) -> BuildPiece:
	var best: BuildPiece = null
	var best_distance := INF
	for candidate in _unique_object_pieces():
		if candidate == base or candidate == exclude:
			continue
		if candidate.item_id != def.part_item_id:
			continue
		if _special_by_piece.has(candidate):
			continue
		if not _special_pair_geometry_matches(def, base, candidate):
			if not _try_dock_existing_part(def, base, candidate) \
					or not _special_pair_geometry_matches(def, base, candidate):
				continue
		if not _part_on_operator_side(def, base, candidate):
			continue
		var distance := base.global_position.distance_squared_to(candidate.global_position)
		if distance < best_distance:
			best = candidate
			best_distance = distance
	return best


func _find_special_base(part: BuildPiece, def: SpecialObjectDef) -> BuildPiece:
	var best: BuildPiece = null
	var best_distance := INF
	for candidate in _unique_object_pieces():
		if candidate == part or candidate.item_id != def.base_item_id:
			continue
		if _special_by_piece.has(candidate):
			continue
		# Al soltar la silla cerca del escritorio, se auto-acopla: no hace falta
		# que el jugador la deje centrada al milímetro para que forme el objeto.
		if not _special_pair_geometry_matches(def, candidate, part):
			if not _try_dock_existing_part(def, candidate, part) \
					or not _special_pair_geometry_matches(def, candidate, part):
				continue
		if not _part_on_operator_side(def, candidate, part):
			continue
		var distance := part.global_position.distance_squared_to(candidate.global_position)
		if distance < best_distance:
			best = candidate
			best_distance = distance
	return best


## Reglas de acoplamiento: las huellas deben ser adyacentes en la grilla,
## tocarse en el mundo (sin huecos) y, opcionalmente, la pieza debe mirar hacia
## la base.
func _special_pair_matches(
	def: SpecialObjectDef, base: BuildPiece, part: BuildPiece
) -> bool:
	if not _special_pair_geometry_matches(def, base, part):
		return false
	if def.require_facing and not _part_faces_base(part, base, def.facing_dot):
		return false
	return true


## Prepara la pareja antes de formar: si la receta lo permite, gira la pieza
## acoplada para que mire a la base y recien despues valida la orientacion.
func _prepare_special_pair(
	def: SpecialObjectDef, base: BuildPiece, part: BuildPiece
) -> bool:
	if def == null or base == null or part == null:
		return false
	# Si el lado del operador cambio (por ejemplo al agregar la banca), la
	# silla se vuelve a acoplar centrada antes de validar.
	if part.item_id == def.part_item_id \
			and not _special_pair_geometry_matches(def, base, part):
		_try_dock_existing_part(def, base, part)
	if not def.require_facing:
		return _special_pair_geometry_matches(def, base, part)
	if def.snap_part_rotation:
		_snap_part_to_base(def, base, part)
	return _special_pair_matches(def, base, part)


## Solo geometria: adyacencia y contacto. La orientacion se valida despues,
## porque puede resolverse con `snap_part_rotation`.
func _special_pair_geometry_matches(
	def: SpecialObjectDef, base: BuildPiece, part: BuildPiece
) -> bool:
	if not _pieces_adjacent(base, part) \
			or not _pieces_touch(base, part, def.max_gap):
		return false
	var base_rect := _piece_rect(base)
	var part_rect := _piece_rect(part)
	if base_rect.size == Vector2.ZERO or part_rect.size == Vector2.ZERO:
		return false
	if base_rect.grow(-0.01).has_point(part_rect.get_center()):
		return false
	if def.part_dock_center and part.item_id == def.part_item_id:
		var side := _resolved_operator_side(def, base)
		if side != Vector2.ZERO:
			var to_part := part_rect.get_center() - base_rect.get_center()
			if to_part.dot(side) > 0.0 \
					and not _part_dock_geometry_matches(
						def, base_rect, part_rect, side):
				return false
	return true


func _unique_object_pieces() -> Array[BuildPiece]:
	var out: Array[BuildPiece] = []
	var seen := {}
	for piece in _object_pieces:
		if piece == null or not is_instance_valid(piece) or seen.has(piece):
			continue
		seen[piece] = true
		out.append(piece)
	return out


func _piece_cells(piece: BuildPiece) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if piece == null:
		return out
	for key in _object_cells.keys():
		if _object_cells[key] == piece:
			var cell: Vector2i = key
			out.append(cell)
	return out


func _pieces_adjacent(base: BuildPiece, part: BuildPiece) -> bool:
	var base_cells := _piece_cells(base)
	if base_cells.is_empty():
		return false
	var lookup := {}
	for cell in base_cells:
		lookup[cell] = true
	for cell in _piece_cells(part):
		if lookup.has(cell + Vector2i(1, 0)) \
				or lookup.has(cell + Vector2i(-1, 0)) \
				or lookup.has(cell + Vector2i(0, 1)) \
				or lookup.has(cell + Vector2i(0, -1)):
			return true
	return false


func _pieces_touch(base: BuildPiece, part: BuildPiece, max_gap: float) -> bool:
	var a := _piece_rect(base)
	var b := _piece_rect(part)
	if a.size == Vector2.ZERO or b.size == Vector2.ZERO:
		return false
	return a.grow(maxf(max_gap, 0.0)).intersects(b)


## Rectangulo XZ de la huella real de una pieza, ya rotada y desplazada.
func _piece_rect(piece: BuildPiece) -> Rect2:
	if piece == null or grid == null:
		return Rect2()
	var item := _find_item_by_id(piece.item_id)
	if item == null:
		return Rect2()
	var footprint := _object_footprint(item, piece.object_rotation_steps)
	var half := Vector2(footprint.x, footprint.y) * grid.cell_size * 0.5
	var center := Vector2(piece.global_position.x, piece.global_position.z)
	return Rect2(center - half, half * 2.0)


func _part_faces_base(
	part: BuildPiece, base: BuildPiece, facing_dot: float
) -> bool:
	var yaw := float(part.object_rotation_steps) * PI * 0.5
	var forward := Basis(Vector3.UP, yaw) * Vector3.FORWARD
	var to_base := Vector3(
		base.global_position.x - part.global_position.x,
		0.0,
		base.global_position.z - part.global_position.z
	)
	if to_base.length() < 0.001:
		return false
	return forward.normalized().dot(to_base.normalized()) >= facing_dot


## Gira una pieza acoplada de 1x1 al paso de 90 grados que mejor mira a la base.
## No toca piezas multi-celda para no cambiar su huella/ocupacion.
func _snap_part_to_base(
	def: SpecialObjectDef, base: BuildPiece, part: BuildPiece
) -> void:
	if def == null or base == null or part == null:
		return
	var item := _find_item_by_id(part.item_id)
	if item == null:
		return
	var footprint := _object_footprint(item, part.object_rotation_steps)
	if footprint.x * footprint.y != 1:
		return
	var to_base := Vector3(
		base.global_position.x - part.global_position.x,
		0.0,
		base.global_position.z - part.global_position.z
	)
	if to_base.length() < 0.001:
		return
	var best_step := part.object_rotation_steps
	var best_dot := -2.0
	for step in 4:
		var forward := Basis(Vector3.UP, float(step) * PI * 0.5) * Vector3.FORWARD
		var dot := forward.dot(to_base.normalized())
		if dot > best_dot:
			best_dot = dot
			best_step = step
	part.object_rotation_steps = best_step
	part.global_rotation = Vector3(0.0, float(best_step) * PI * 0.5, 0.0)


func _form_special_object(
	def: SpecialObjectDef,
	base: BuildPiece,
	part: BuildPiece,
	clients: Array[BuildPiece] = []
) -> SpecialObject:
	if def == null or base == null or part == null:
		return null
	if _special_by_piece.has(base) or _special_by_piece.has(part):
		return null
	for client in clients:
		if _special_by_piece.has(client):
			return null

	var composite := SpecialObject.new()
	composite.name = "Special_%s" % String(def.id)
	if not composite.configure(def, base, part, clients):
		composite.free()
		return null

	var parent: Node = pieces_root if pieces_root != null else self
	parent.add_child(composite)
	composite.global_transform = Transform3D(
		Basis(), composite.get_marker_origin()
	)

	# La IA deja de ver las piezas por separado mientras el conjunto este activo.
	_suspend_special_part(base)
	_suspend_special_part(part)
	for client in clients:
		_suspend_special_part(client)

	_special_objects.append(composite)
	_special_by_piece[base] = composite
	_special_by_piece[part] = composite
	for client in clients:
		_special_by_piece[client] = composite
	special_object_formed.emit(composite)
	return composite


func _suspend_special_part(piece: BuildPiece) -> void:
	if piece == null or not is_instance_valid(piece):
		return
	if piece is SmartObject:
		var smart := piece as SmartObject
		smart.release_all()
		SmartObjectRegistry.unregister(smart)
		smart.remove_from_group("smart_objects")


func _restore_special_part(piece: BuildPiece) -> void:
	if piece == null or not is_instance_valid(piece) \
			or piece.is_queued_for_deletion():
		return
	if piece is SmartObject:
		var smart := piece as SmartObject
		if not smart.is_in_group("smart_objects"):
			smart.add_to_group("smart_objects")
		SmartObjectRegistry.register(smart)


## Deshace la combinacion. `restore_parts` vuelve a registrar las piezas como
## SmartObjects individuales (se usa al separar, no al borrar todo el conjunto).
func _dissolve_special_object(
	composite: SpecialObject, restore_parts: bool
) -> void:
	if composite == null:
		return
	_special_objects.erase(composite)
	for piece in composite.get_parts():
		_special_by_piece.erase(piece)
		if restore_parts:
			_restore_special_part(piece)
	if is_instance_valid(composite):
		special_object_dissolved.emit(composite)
		composite.queue_free()


func _place_floor(cell: Vector2i, silent: bool = false) -> bool:
	if not _can_place_floor(cell):
		return false

	var piece := _spawn_current_piece()
	if piece == null:
		return false

	# Altura real de la cara superior del modelo: algunos GLB de piso son mas
	# altos que `floor_thickness` y taparian la grilla principal.
	var piece_aabb := _compute_aabb(piece)
	var top_offset := floor_thickness * 0.5
	if piece_aabb.size != Vector3.ZERO:
		top_offset = piece_aabb.end.y

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
	_floor_tops[cell] = piece.global_position.y + top_offset
	_request_floor_grid_refresh()
	if not silent:
		pieces_changed.emit()
	return true


# --------------------------------------------------------------------------
# Grilla secundaria sobre los pisos colocados
# --------------------------------------------------------------------------

## Pide un refresco diferido (un solo rebuild por frame aunque se coloque un
## rectangulo entero de pisos).
func _request_floor_grid_refresh() -> void:
	if _floor_grid_dirty:
		return
	_floor_grid_dirty = true
	call_deferred("_refresh_floor_grid")


func _refresh_floor_grid() -> void:
	_floor_grid_dirty = false
	if grid == null:
		return
	var cells: Array[Vector2i] = []
	var tops := PackedFloat32Array()
	var fallback := grid.plane_global_y()
	for cell in _floors.keys():
		if not is_instance_valid(_floors[cell]):
			continue
		cells.append(cell)
		tops.append(float(_floor_tops.get(cell, fallback)))
	grid.set_floor_cells(cells, tops)


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

func _start_wall_drag(erasing: bool = false) -> void:
	if not _hovering:
		return
	# Al empezar a pintar una pared, ocultar las zonas para ver la linea.
	_set_zones_hidden_for_brush(true)
	_wall_dragging = true
	_wall_drag_erasing = erasing
	_wall_drag_start = _hover_wall
	_wall_drag_start_cell = _hover_cell
	_wall_drag_reveal = 0.0
	_clear_wall_drag_ghosts(false)
	_wall_drag_keys.clear()


func _update_wall_drag(delta: float = 0.0) -> void:
	if not _hovering:
		return

	var keys := _wall_drag_segment_keys()
	if _wall_drag_erasing:
		# Al borrar se muestra toda la linea de inmediato.
		_wall_drag_reveal = float(keys.size())
	else:
		if delta > 0.0:
			_wall_drag_reveal += delta / WALL_REVEAL_SEGMENT_TIME
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
		var built := _build_wall_ghost_visual(_wall_drag_erasing)
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
		var key := keys[i]
		var exists := _walls.has(key)
		var t := clampf(progress - float(i), 0.0, 1.0)
		# Al borrar solo se resaltan las paredes que existen de verdad.
		ghost.visible = t > 0.0 and (not _wall_drag_erasing or exists)
		if not ghost.visible:
			continue
		ghost.global_transform = _wall_ghost_transform(key, _wall_drag_base_offset)
		_update_ghost_material(
			mat, ghost, _wall_drag_local_aabb,
			exists if _wall_drag_erasing else _can_place_wall(key),
			_wall_drag_erasing,
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

	if _wall_drag_erasing:
		var erased := false
		var order := 0
		for key in keys:
			if _erase_wall_at(key, true, order):
				erased = true
				order += 1
		if erased:
			_refresh_wall_variants()
			_refresh_wall_shapes()
			pieces_changed.emit()
		_clear_wall_drag_ghosts()
		_wall_dragging = false
		_wall_drag_erasing = false
		_update_zones_for_tool()
		return

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
	_wall_drag_erasing = false
	_update_zones_for_tool()


# --------------------------------------------------------------------------
# Pincel de pisos (estilo Sims): clic y arrastrar para rellenar un rectangulo.
# --------------------------------------------------------------------------

func _start_floor_drag(erasing: bool = false) -> void:
	if not _hovering or not grid.is_cell_inside(_hover_cell):
		return
	# Mientras se pinta el piso, ocultar las zonas para ver el trazado.
	_set_zones_hidden_for_brush(true)
	_floor_dragging = true
	_floor_drag_erasing = erasing
	_floor_drag_start = _hover_cell
	_floor_drag_reveal = 0.0
	_clear_floor_drag_preview(false)
	_floor_drag_cells.clear()


func _update_floor_drag(delta: float = 0.0) -> void:
	if not _hovering:
		return

	var cells := _floor_drag_rect_cells()
	if _floor_drag_erasing:
		# Al borrar se resalta todo el rectangulo de inmediato.
		_floor_drag_reveal = float(cells.size())
	else:
		if delta > 0.0:
			_floor_drag_reveal += delta / FLOOR_REVEAL_CELL_TIME
		# Si el rectangulo crece, las celdas nuevas empiezan a pintarse desde cero.
		if not _same_floor_cells(cells, _floor_drag_cells):
			if cells.size() > _floor_drag_cells.size():
				_floor_drag_reveal = minf(_floor_drag_reveal, float(_floor_drag_cells.size()))
			_floor_drag_cells = cells.duplicate()
		_floor_drag_reveal = minf(_floor_drag_reveal, float(cells.size()))

	if not _same_floor_cells(cells, _floor_preview_cells):
		_rebuild_floor_preview(cells, _floor_drag_start, _floor_drag_erasing)
	_update_floor_preview(cells, _floor_drag_reveal, _floor_drag_erasing)


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
	var lift := FLOOR_ERASE_PREVIEW_LIFT if erasing else FLOOR_PREVIEW_LIFT
	_floor_preview.global_transform = Transform3D(
		Basis.IDENTITY,
		Vector3(
			base.x + (float(min_cell.x) + float(cols) * 0.5) * cs,
			grid.plane_global_y() + lift,
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

	if _floor_drag_erasing:
		var erased := false
		var order := 0
		for cell in cells:
			if _erase_floor_at(cell, true, order):
				erased = true
				order += 1
		if erased:
			pieces_changed.emit()
		_clear_floor_drag_preview()
		_floor_dragging = false
		_floor_drag_erasing = false
		_update_zones_for_tool()
		return

	var placed: Array[Vector2i] = []
	for cell in cells:
		if _place_floor(cell, true):
			placed.append(cell)
	if not placed.is_empty():
		_animate_floors_build(placed)
		pieces_changed.emit()
	_clear_floor_drag_preview()
	_floor_dragging = false
	_floor_drag_erasing = false
	_update_zones_for_tool()


# --------------------------------------------------------------------------
# Pincel de zonas: rectangulos de celdas pintadas sobre el piso.
# --------------------------------------------------------------------------

func _start_zone_drag(erasing: bool = false) -> void:
	if not _hovering or not grid.is_cell_inside(_hover_cell):
		return
	_zone_dragging = true
	_zone_drag_erasing = erasing
	_zone_drag_start = _hover_cell
	_zone_drag_reveal = 0.0
	_zone_drag_started_on = _zone_cells.get(_hover_cell, &"")
	_clear_zone_drag_preview(false)
	_zone_drag_cells.clear()


func _update_zone_drag(delta: float = 0.0) -> void:
	if not _hovering:
		return

	var cells := _zone_drag_rect_cells()
	if _zone_drag_erasing:
		_zone_drag_reveal = float(cells.size())
	else:
		if delta > 0.0:
			_zone_drag_reveal += delta / ZONE_REVEAL_CELL_TIME
		if not _same_floor_cells(cells, _zone_drag_cells):
			if cells.size() > _zone_drag_cells.size():
				_zone_drag_reveal = minf(
					_zone_drag_reveal, float(_zone_drag_cells.size())
				)
			_zone_drag_cells = cells.duplicate()
		_zone_drag_reveal = minf(_zone_drag_reveal, float(cells.size()))

	if not _same_floor_cells(cells, _zone_preview_cells):
		_rebuild_zone_preview(cells, _zone_drag_start, _zone_drag_erasing)
	_update_zone_preview(cells, _zone_drag_reveal, _zone_drag_erasing)


func _zone_drag_rect_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	if not _zone_dragging:
		return cells

	var start := grid.clamp_cell(_zone_drag_start)
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


func _rebuild_zone_preview(
	cells: Array[Vector2i], start: Vector2i, erasing: bool
) -> void:
	if _zone_preview == null or cells.is_empty():
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
	_zone_preview_cols = cols
	_zone_preview_rows = rows

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
	var order := [0, 2, 1, 0, 3, 2]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in order:
		var corner: Array = corners[i]
		st.set_normal(Vector3.UP)
		st.set_uv(corner[1])
		st.add_vertex(corner[0])
	_zone_preview.mesh = st.commit()

	var base := grid.global_position
	_zone_preview.global_transform = Transform3D(
		Basis.IDENTITY,
		Vector3(
			base.x + (float(min_cell.x) + float(cols) * 0.5) * cs,
			grid.plane_global_y() + ZONE_PREVIEW_LIFT,
			base.z + (float(min_cell.y) + float(rows) * 0.5) * cs
		)
	)
	_zone_preview_material.set_shader_parameter("valid_mask", _zone_preview_mask)
	_zone_preview_material.set_shader_parameter("grid_size", Vector2(cols, rows))
	_zone_preview_cells = cells.duplicate()


func _update_zone_preview(
	cells: Array[Vector2i], reveal_cells: float, erasing: bool
) -> void:
	if _zone_preview == null or _zone_preview_material == null or cells.is_empty():
		return
	var mat := _zone_preview_material
	var fill := FLOOR_ERASE_FILL if erasing else ZONE_PREVIEW_FILL
	var line := FLOOR_ERASE_LINE if erasing else ZONE_PREVIEW_LINE
	mat.set_shader_parameter("fill_color", Color(fill.r, fill.g, fill.b, 1.0))
	mat.set_shader_parameter("line_color", Color(line.r, line.g, line.b, 1.0))
	mat.set_shader_parameter(
		"invalid_color", Color(COLOR_BAD.r, COLOR_BAD.g, COLOR_BAD.b, 1.0)
	)
	mat.set_shader_parameter(
		"grid_size", Vector2(_zone_preview_cols, _zone_preview_rows)
	)

	var total := float(cells.size())
	var reveal := clampf(reveal_cells, 0.0, total)
	var current := clampi(int(ceil(reveal)) - 1, 0, cells.size() - 1)
	mat.set_shader_parameter("reveal_cells", reveal)
	mat.set_shader_parameter("current_index", float(current))
	_zone_preview.visible = true


func _show_zone_preview(cell: Vector2i, erasing: bool) -> void:
	if _zone_preview == null:
		return
	var cells: Array[Vector2i] = [cell]
	if not _same_floor_cells(cells, _zone_preview_cells):
		_rebuild_zone_preview(cells, cell, erasing)
	_update_zone_preview(cells, 1.0, erasing)


func _clear_zone_drag_preview(reset_reveal: bool = true) -> void:
	_zone_drag_cells.clear()
	_zone_preview_cells.clear()
	if _zone_preview != null:
		_zone_preview.visible = false
	if reset_reveal:
		_zone_drag_reveal = 0.0


func _finish_zone_drag() -> void:
	var cells := _zone_drag_rect_cells()

	if _zone_drag_erasing:
		_erase_zone_cells(cells)
		_clear_zone_drag_preview()
		_zone_dragging = false
		_zone_drag_erasing = false
		return

	# Un clic sobre una zona existente abre el menu para asignarle tipo.
	if cells.size() == 1 and _zone_drag_started_on != &"" \
			and _zone_cells.get(cells[0], &"") == _zone_drag_started_on:
		_clear_zone_drag_preview()
		_zone_dragging = false
		_zone_drag_erasing = false
		_open_zone_menu(_zone_drag_started_on)
		return

	_paint_zone_cells(cells)
	_clear_zone_drag_preview()
	_zone_dragging = false
	_zone_drag_erasing = false


func _paint_zone_cells(cells: Array[Vector2i]) -> void:
	if cells.is_empty():
		return
	paint_zone(cells)


# --------------------------------------------------------------------------
# API de zonas para la IA y las pruebas
# --------------------------------------------------------------------------

## Zona a la que pertenece una celda (o `&""` si no hay zona).
func get_zone_id_at_cell(cell: Vector2i) -> StringName:
	return _zone_cells.get(cell, &"")


## Zona a la que pertenece un punto del mundo (o `&""`).
func get_zone_id_at_world(world: Vector3) -> StringName:
	if grid == null:
		return &""
	return get_zone_id_at_cell(grid.cell_from_world(world))


## Tipo asignado a una zona (`unassigned`, `hallway`, `waiting`, `consult`).
func get_zone_type_of(zone_id: StringName) -> StringName:
	if zone_id == &"" or not _zone_types.has(zone_id):
		return &""
	return _zone_types[zone_id]


func get_zone_type_at_world(world: Vector3) -> StringName:
	return get_zone_type_of(get_zone_id_at_world(world))


## IDs de todas las zonas pintadas de un tipo concreto.
func get_zone_ids_of_type(type_id: StringName) -> Array[StringName]:
	var out: Array[StringName] = []
	for zone_id in _zone_types.keys():
		if _zone_types[zone_id] == type_id:
			out.append(zone_id)
	return out


## Celdas que pertenecen a una zona.
func get_zone_cells(zone_id: StringName) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if zone_id == &"":
		return out
	for cell in _zone_cells.keys():
		if _zone_cells[cell] == zone_id:
			out.append(cell)
	return out


func is_world_in_zone(world: Vector3, zone_id: StringName) -> bool:
	return zone_id != &"" and get_zone_id_at_world(world) == zone_id


## Pinta una zona nueva con un tipo concreto y devuelve su id. Pensado para la
## UI y para las pruebas; el pincel llama a esta funcion.
func paint_zone(
	cells: Array[Vector2i], type_id: StringName = ZONE_DEFAULT_TYPE
) -> StringName:
	if cells.is_empty():
		return &""
	if not ZONE_TYPES.has(type_id):
		type_id = ZONE_DEFAULT_TYPE
	var zone_id := _new_zone_id()
	for cell in cells:
		_zone_cells[cell] = zone_id
	_zone_types[zone_id] = type_id
	_cleanup_zone_types()
	_rebuild_zones_overlay()
	zones_changed.emit()
	return zone_id


## Cambia el tipo de una zona ya pintada.
func set_zone_type(zone_id: StringName, type_id: StringName) -> bool:
	if zone_id == &"" or not _zone_types.has(zone_id):
		return false
	if not ZONE_TYPES.has(type_id):
		return false
	if _zone_types[zone_id] == type_id:
		return true
	_zone_types[zone_id] = type_id
	_rebuild_zones_overlay()
	zones_changed.emit()
	return true


## Nombre legible de un tipo de zona.
func get_zone_type_name(type_id: StringName) -> String:
	return _zone_type_name(type_id)



func _erase_zone_cells(cells: Array[Vector2i]) -> void:
	var erased := false
	for cell in cells:
		if _zone_cells.erase(cell):
			erased = true
	if erased:
		_cleanup_zone_types()
		_rebuild_zones_overlay()
		zones_changed.emit()


func _new_zone_id() -> StringName:
	var id := StringName("zone_%d" % _next_zone_id)
	_next_zone_id += 1
	return id


func _cleanup_zone_types() -> void:
	var used: Dictionary = {}
	for zid in _zone_cells.values():
		used[zid] = true
	for zid in _zone_types.keys():
		if not used.has(zid):
			_zone_types.erase(zid)


## Las zonas se ocultan mientras se colocan o borran objetos. El piso y la
## pared las ocultan solo durante el trazo (ver `_start_floor_drag` y
## `_start_wall_drag`); al cambiar de herramienta vuelven a mostrarse.
func _tool_hides_zones() -> bool:
	return tool == Tool.OBJECT \
		or (tool == Tool.ERASE and erase_kind == EraseKind.OBJECT)


func _update_zones_for_tool() -> void:
	_set_zones_hidden_for_brush(_tool_hides_zones())


func _set_zones_hidden_for_brush(hidden: bool) -> void:
	if _zones_hidden_for_brush == hidden:
		return
	_zones_hidden_for_brush = hidden
	_refresh_zones_visibility()


func _refresh_zones_visibility() -> void:
	var is_visible := build_mode and not _zone_cells.is_empty() \
		and not _zones_hidden_for_brush
	if _zones_overlay != null:
		_zones_overlay.visible = is_visible
	if _zone_labels_root != null:
		_zone_labels_root.visible = is_visible


func _rebuild_zones_overlay() -> void:
	if _zones_overlay == null:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cell_size := grid.cell_size
	var half := cell_size * 0.5
	var plane := grid.plane_global_y() + ZONE_OVERLAY_LIFT
	var border_plane := grid.plane_global_y() + ZONE_BORDER_LIFT
	var border := minf(ZONE_BORDER_WIDTH, cell_size * 0.25)
	var base := grid.global_position

	for cell_key in _zone_cells.keys():
		var cell: Vector2i = cell_key
		var zone_id: StringName = _zone_cells[cell]
		var type_id: StringName = _zone_types.get(zone_id, ZONE_DEFAULT_TYPE)
		var info: Dictionary = ZONE_TYPES.get(type_id, ZONE_TYPES[ZONE_DEFAULT_TYPE])
		var color: Color = info["color"]
		var cx := base.x + (cell.x + 0.5) * cell_size
		var cz := base.z + (cell.y + 0.5) * cell_size

		# Relleno completo: sin separacion entre celdas, la zona se ve unida.
		_add_zone_quad(st, [
			Vector3(cx - half, plane, cz - half),
			Vector3(cx + half, plane, cz - half),
			Vector3(cx + half, plane, cz + half),
			Vector3(cx - half, plane, cz + half),
		], color)

		# Borde solo en los lados que dan a otra zona o al vacio.
		var edge_color := Color(
			color.r * 0.72, color.g * 0.72, color.b * 0.72, 0.95
		)
		if _zone_cells.get(cell + Vector2i(0, -1), &"") != zone_id:
			_add_zone_quad(st, [
				Vector3(cx - half, border_plane, cz - half),
				Vector3(cx + half, border_plane, cz - half),
				Vector3(cx + half, border_plane, cz - half + border),
				Vector3(cx - half, border_plane, cz - half + border),
			], edge_color)
		if _zone_cells.get(cell + Vector2i(0, 1), &"") != zone_id:
			_add_zone_quad(st, [
				Vector3(cx - half, border_plane, cz + half - border),
				Vector3(cx + half, border_plane, cz + half - border),
				Vector3(cx + half, border_plane, cz + half),
				Vector3(cx - half, border_plane, cz + half),
			], edge_color)
		if _zone_cells.get(cell + Vector2i(-1, 0), &"") != zone_id:
			_add_zone_quad(st, [
				Vector3(cx - half, border_plane, cz - half),
				Vector3(cx - half + border, border_plane, cz - half),
				Vector3(cx - half + border, border_plane, cz + half),
				Vector3(cx - half, border_plane, cz + half),
			], edge_color)
		if _zone_cells.get(cell + Vector2i(1, 0), &"") != zone_id:
			_add_zone_quad(st, [
				Vector3(cx + half - border, border_plane, cz - half),
				Vector3(cx + half, border_plane, cz - half),
				Vector3(cx + half, border_plane, cz + half),
				Vector3(cx + half - border, border_plane, cz + half),
			], edge_color)

	_zones_overlay.mesh = st.commit()
	_rebuild_zone_labels()
	_refresh_zones_visibility()


func _add_zone_quad(st: SurfaceTool, corners: Array, color: Color) -> void:
	for i in [0, 2, 1, 0, 3, 2]:
		st.set_color(color)
		st.set_normal(Vector3.UP)
		st.add_vertex(corners[i])


## Etiquetas con el nombre del tipo en el centro de cada zona. Si una zona
## quedo partida en varias islas, se pone una etiqueta en cada una.
func _rebuild_zone_labels() -> void:
	if _zone_labels_root == null:
		return
	for child in _zone_labels_root.get_children():
		child.free()
	if _zone_cells.is_empty():
		return

	var visited: Dictionary = {}
	for cell_key in _zone_cells.keys():
		var cell: Vector2i = cell_key
		if visited.has(cell):
			continue
		var zone_id: StringName = _zone_cells[cell]
		var component: Array[Vector2i] = []
		var stack: Array[Vector2i] = [cell]
		visited[cell] = true
		while not stack.is_empty():
			var current: Vector2i = stack.pop_back()
			component.append(current)
			for dir in [
				Vector2i(1, 0), Vector2i(-1, 0),
				Vector2i(0, 1), Vector2i(0, -1),
			]:
				var neighbor: Vector2i = current + dir
				if visited.has(neighbor):
					continue
				if _zone_cells.get(neighbor, &"") != zone_id:
					continue
				visited[neighbor] = true
				stack.append(neighbor)
		var center_cell := _zone_component_center(component)
		var type_id: StringName = _zone_types.get(zone_id, ZONE_DEFAULT_TYPE)
		_create_zone_label(type_id, center_cell)


func _zone_component_center(cells: Array[Vector2i]) -> Vector2i:
	if cells.is_empty():
		return Vector2i.ZERO
	var sum := Vector2.ZERO
	for cell in cells:
		sum += Vector2(cell.x, cell.y)
	var average := sum / float(cells.size())
	var best := cells[0]
	var best_distance := INF
	for cell in cells:
		var distance := Vector2(cell.x, cell.y).distance_squared_to(average)
		if distance < best_distance:
			best_distance = distance
			best = cell
	return best


func _create_zone_label(type_id: StringName, cell: Vector2i) -> void:
	if _zone_labels_root == null:
		return
	var label := Label3D.new()
	label.text = _zone_type_name(type_id).to_upper()
	label.font_size = 64
	label.pixel_size = 0.007
	label.outline_size = 12
	label.outline_modulate = Color(0, 0, 0, 0.8)
	label.modulate = Color(1, 1, 1, 0.95)
	label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	label.shaded = false
	label.double_sided = true
	label.render_priority = 2
	label.rotation = Vector3(-PI * 0.5, _zone_label_yaw(), 0.0)
	var base := grid.global_position
	label.position = Vector3(
		base.x + (cell.x + 0.5) * grid.cell_size,
		grid.plane_global_y() + ZONE_LABEL_LIFT,
		base.z + (cell.y + 0.5) * grid.cell_size
	)
	_zone_labels_root.add_child(label)


func _zone_label_yaw() -> float:
	return build_camera.yaw if build_camera != null else 0.0


## Mantiene las etiquetas planas y alineadas con la camara de obra para que se
## lean bien al orbitar.
func _update_zone_label_orientation() -> void:
	if _zone_labels_root == null or not _zone_labels_root.visible \
			or build_camera == null:
		return
	var yaw := build_camera.yaw
	for child in _zone_labels_root.get_children():
		if child is Label3D:
			child.rotation = Vector3(-PI * 0.5, yaw, 0.0)


func _zone_type_name(type_id: StringName) -> String:
	var info: Dictionary = ZONE_TYPES.get(type_id, ZONE_TYPES[ZONE_DEFAULT_TYPE])
	return String(info.get("name", "Sin asignar"))


func _open_zone_menu(zone_id: StringName) -> void:
	if _zone_menu_root == null:
		return
	var type_id: StringName = _zone_types.get(zone_id, ZONE_DEFAULT_TYPE)
	var count := 0
	for zid in _zone_cells.values():
		if zid == zone_id:
			count += 1
	_zone_menu_zone_id = zone_id
	_zone_menu_open = true
	_zone_menu_label.text = "Zona · %d celdas\nTipo actual: %s" % [
		count, _zone_type_name(type_id)
	]
	for tid in _zone_menu_buttons.keys():
		var btn: Button = _zone_menu_buttons[tid]
		btn.text = ("✓  " if tid == type_id else "") + _zone_type_name(tid)
	_zone_menu_root.visible = true
	_hide_ghosts()


func _assign_zone_type(type_id: StringName) -> void:
	if _zone_menu_zone_id == &"":
		return
	if not set_zone_type(_zone_menu_zone_id, type_id):
		return
	_show_build_message(
		"Zona asignada: %s" % _zone_type_name(type_id),
		Color(0.75, 0.9, 1.0)
	)
	_close_zone_menu()


func _close_zone_menu() -> void:
	_zone_menu_open = false
	_zone_menu_zone_id = &""
	if _zone_menu_root != null:
		_zone_menu_root.visible = false


func get_zone_count() -> int:
	return _zone_cells.size()


func get_zone_type(cell: Vector2i) -> StringName:
	var zone_id: StringName = _zone_cells.get(cell, &"")
	if zone_id == &"":
		return &""
	return _zone_types.get(zone_id, &"")


func _erase_at(
	cell: Vector2i, wall: Vector3i, kind: EraseKind = EraseKind.ALL
) -> bool:
	match kind:
		EraseKind.OBJECT:
			if _object_cells.has(cell):
				_erase_object_at(cell)
				pieces_changed.emit()
				return true
			return false
		EraseKind.WALL:
			return _erase_wall_at(wall)
		EraseKind.FLOOR:
			return _erase_floor_at(cell)
		_:
			if _object_cells.has(cell):
				_erase_object_at(cell)
				pieces_changed.emit()
				return true
			if _erase_wall_at(wall):
				return true
			return _erase_floor_at(cell)


## Borra un tramo de pared con animación de desmontaje. `silent` evita
## refrescos/señales por cada pieza al borrar en lote (el llamador hace un único
## refresco al final). `order` escalona la animación.
func _erase_wall_at(
	wall: Vector3i, silent: bool = false, order: int = 0
) -> bool:
	if not _walls.has(wall):
		return false
	var piece := _walls.get(wall) as BuildPiece
	_walls.erase(wall)
	if piece != null and is_instance_valid(piece):
		_disable_piece_collision(piece)
		_animate_wall_erase(piece, order)
	if not silent:
		_refresh_wall_variants()
		_refresh_wall_shapes()
		pieces_changed.emit()
	return true


## Borra un piso con animación de desmontaje. `silent` evita señales por cada
## celda al borrar en lote. `order` escalona la animación.
func _erase_floor_at(
	cell: Vector2i, silent: bool = false, order: int = 0
) -> bool:
	if not _floors.has(cell):
		return false
	var piece := _floors.get(cell) as BuildPiece
	_floors.erase(cell)
	_floor_tops.erase(cell)
	_request_floor_grid_refresh()
	if piece != null and is_instance_valid(piece):
		_disable_piece_collision(piece)
		_animate_floor_erase(piece, order)
	if not silent:
		pieces_changed.emit()
	return true


func _erase_object_at(cell: Vector2i, order: int = 0) -> void:
	if not _object_cells.has(cell):
		return
	var piece := _object_cells[cell] as BuildPiece
	if piece == null:
		return

	# Si la pieza forma parte de un objeto especial, primero se separa el
	# conjunto. La politica de borrado la decide la receta.
	var composite := _special_by_piece.get(piece) as SpecialObject
	var reform_base: BuildPiece = null
	if composite != null:
		var def := composite.special_def
		var parts := composite.get_parts()
		if not parts.is_empty():
			reform_base = parts[0]
		if def != null and def.remove_together:
			_dissolve_special_object(composite, false)
			var index := 0
			for part in parts:
				_erase_object_piece(part, order + index)
				index += 1
			return
		_dissolve_special_object(composite, true)

	_erase_object_piece(piece, order)
	# Si todavia quedan las piezas necesarias (por ejemplo al borrar solo la
	# banca de pacientes), el conjunto se vuelve a formar sin la pieza borrada.
	if reform_base != null and reform_base != piece \
			and is_instance_valid(reform_base) and not reform_base.is_queued_for_deletion():
		_try_form_special_object(reform_base)


## Borra una pieza concreta (todas sus celdas) y lanza su animacion.
func _erase_object_piece(piece: BuildPiece, order: int = 0) -> void:
	if piece == null:
		return

	# Quitar todas las celdas cubiertas y la entrada primaria.
	for c in _object_cells.keys():
		if _object_cells[c] == piece:
			_object_cells.erase(c)
	for c in _objects.keys():
		if _objects[c] == piece:
			_objects.erase(c)
	_object_pieces.erase(piece)

	if is_instance_valid(piece):
		if piece is SmartObject:
			var smart := piece as SmartObject
			smart.release_all()
			# La pieza sigue viva mientras dura la animación, pero debe dejar de
			# existir para la IA en el mismo instante en que se borra.
			SmartObjectRegistry.unregister(smart)
			smart.remove_from_group("smart_objects")
		object_removed.emit(piece)
		_disable_piece_collision(piece)
		_animate_object_erase(piece, order)


## Desactiva la colisión de una pieza que está saliendo para que el NavMesh no
## la siga considerando mientras dura la animación.
func _disable_piece_collision(piece: Node) -> void:
	if piece is CollisionObject3D:
		(piece as CollisionObject3D).collision_layer = 0
		(piece as CollisionObject3D).collision_mask = 0
	var pending: Array[Node] = piece.get_children()
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		if node is CollisionShape3D:
			(node as CollisionShape3D).set_deferred("disabled", true)
		pending.append_array(node.get_children())


func _load_build_items() -> void:
	build_items = BuildItemLoader.load_items(items_dir)
	special_object_defs = SpecialObjectLoader.load_defs(special_objects_dir)
	_validate_special_object_defs()
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
	if build_menu != null:
		build_menu.set_selected(selected_item)


func _wire_build_menu() -> void:
	if build_menu == null:
		return
	if not build_menu.item_selected.is_connected(_on_build_item_selected):
		build_menu.item_selected.connect(_on_build_item_selected)


## Avisa en consola si una receta quedo desincronizada de los items, por
## ejemplo al cambiar el `id` de un BuildItem sin actualizar la receta.
func _validate_special_object_defs() -> void:
	for def in special_object_defs:
		if def == null:
			continue
		if def.smart_object == null:
			push_warning(
				"SpecialObject '%s': falta la definicion smart_object del resultado."
				% String(def.id)
			)
		var base_item := _find_item_by_id(def.base_item_id)
		if base_item == null:
			push_warning(
				"SpecialObject '%s': no existe el BuildItem base '%s'. Revisa el id del item o actualiza la receta."
				% [String(def.id), String(def.base_item_id)]
			)
		var part_item := _find_item_by_id(def.part_item_id)
		if part_item == null:
			push_warning(
				"SpecialObject '%s': no existe el BuildItem que se acopla '%s'. Revisa el id del item o actualiza la receta."
				% [String(def.id), String(def.part_item_id)]
			)
		for client_id in def.client_item_ids:
			if _find_item_by_id(client_id) == null:
				push_warning(
					"SpecialObject '%s': no existe el BuildItem client '%s'. Revisa el id del item o actualiza la receta."
					% [String(def.id), String(client_id)]
				)

		var slot_item: BuildItem = null
		if def.slot_source == "part":
			slot_item = part_item
		else:
			slot_item = base_item
		if slot_item != null and slot_item.smart_object == null:
			push_warning(
				"SpecialObject '%s': el item '%s' no tiene smart_object; no se puede copiar el slot/POI."
				% [String(def.id), String(slot_item.id)]
			)


func _on_build_item_selected(item: BuildItem) -> void:
	selected_item = item
	_apply_selected_item()
	if build_menu != null:
		build_menu.set_selected(item)


func _apply_selected_item() -> void:
	if selected_item == null:
		return
	# Elegir otro item (p. ej. otro borrador) no debe dejar a medias el arrastre.
	_cancel_drags()
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
		"erase_floor":
			erase_kind = EraseKind.FLOOR
			tool = Tool.ERASE
		"erase_wall":
			erase_kind = EraseKind.WALL
			tool = Tool.ERASE
		"erase_object":
			erase_kind = EraseKind.OBJECT
			tool = Tool.ERASE
		"zone_paint":
			tool = Tool.ZONE
		"zone_erase":
			tool = Tool.ZONE_ERASE
		_:
			# Tipos aún no colocables (techo, aberturas, ...).
			pass
	_update_zones_for_tool()
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


func _spawn_piece(
	scene: PackedScene,
	with_collision: bool = true,
	smart_def: SmartObjectDef = null,
	center_visual: bool = false
) -> BuildPiece:
	if scene == null:
		push_warning("BuildController: falta un prefab de pieza.")
		return null

	var instance := scene.instantiate()
	var piece: BuildPiece
	if instance is SmartObject:
		var smart := instance as SmartObject
		if smart.definition == null and smart_def != null:
			smart.definition = smart_def
		piece = smart
		if not with_collision:
			var old_collision := piece.get_node_or_null("CollisionShape3D") as CollisionShape3D
			if old_collision != null:
				old_collision.queue_free()
	elif instance is BuildPiece and smart_def == null:
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
		# Un prefab comun (GLB, escena suelta) con definicion SmartObject se
		# envuelve en un SmartObject: la IA ve el mueble aunque el modelo no
		# traiga la raiz con el script.
		piece = _wrap_3d_instance(instance as Node3D, with_collision, smart_def,
			center_visual)

	var parent: Node = pieces_root if pieces_root != null else self
	parent.add_child(piece)
	return piece


## Envuelve una escena 3D comun en un BuildPiece (o SmartObject) con collider.
## `center_visual` recentra el modelo en X/Z: util para GLB cuyo pivote esta en
## una pata o un borde en vez del centro de la huella.
func _wrap_3d_instance(
	instance: Node3D,
	with_collision: bool,
	smart_def: SmartObjectDef,
	center_visual: bool = false
) -> BuildPiece:
	for child in instance.get_children():
		if child is Camera3D or child is Light3D:
			child.queue_free()

	var piece: BuildPiece
	if smart_def != null:
		var smart := SmartObject.new()
		smart.definition = smart_def
		piece = smart
	else:
		piece = BuildPiece.new()
	piece.name = instance.name
	piece.add_child(instance)
	if center_visual:
		_center_visual_xz(instance)
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
	return piece


## Desplaza el modelo para que el centro de su AABB quede sobre el origen,
## manteniendo la altura (la base sigue apoyada en el piso). Los modelos que ya
## estan centrados no se tocan.
static func _center_visual_xz(instance: Node3D) -> void:
	var aabb := _compute_aabb(instance)
	if aabb.size == Vector3.ZERO:
		return
	var center := aabb.get_center()
	if Vector2(center.x, center.z).length() < 0.01:
		return
	instance.position -= Vector3(center.x, 0.0, center.z)


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
	# Al construir cerca del borde, la grilla se agranda sola para no quedar
	# bloqueado por el limite.
	if tool == Tool.FLOOR or tool == Tool.WALL:
		grid.expand_if_near_edge(_hover_cell)
	_hover_wall = grid.wall_from_world(hit)

	# Precision de medio metro para objetos: se ajusta el centro de la huella a
	# la sub-grilla, limitado a un paso por eje. Si ese ajuste superpone el
	# objeto con otra pieza, se usa el desplazamiento valido mas cercano.
	_hover_anchor_cell = _hover_cell
	_hover_rotation = -1
	_hover_sub_offset = Vector3.ZERO
	if tool == Tool.OBJECT and _selected_object_item != null \
			and grid.subdivisions > 1:
		_hover_sub_offset = _valid_hover_offset(hit)
	return true


## Devuelve el desplazamiento fino valido mas cercano al cursor. Evita que el
## borde de una celda se vuelva rojo solo porque el snap de 0,5 m mete la
## huella en la celda vecina ocupada (por ejemplo, debajo de un escritorio).
##
## Tambien resuelve el acople a una base: deja el ancla y la rotacion en
## `_hover_anchor_cell` y `_hover_rotation` para que el fantasma muestre la
## silla ya girada y apoyada en el borde frontal del escritorio.
func _valid_hover_offset(point: Vector3) -> Vector3:
	var footprint := _object_footprint(_selected_object_item, _object_rotation)
	var base := grid.cell_center(_hover_cell) \
		+ _object_footprint_offset(footprint)
	var wanted := grid.snap_offset(
		Vector2(point.x - base.x, point.z - base.z), 1)
	var resolved := _resolve_part_anchor(
		_hover_cell, _selected_object_item, _object_rotation, wanted)
	var resolved_cell: Vector2i = resolved[0]
	var resolved_offset: Vector3 = resolved[1]
	var resolved_rotation: int = resolved[2]
	_hover_anchor_cell = resolved_cell
	_hover_rotation = resolved_rotation
	if resolved_cell != _hover_cell \
			or not resolved_offset.is_equal_approx(wanted) \
			or resolved_rotation != _object_rotation:
		return resolved_offset
	if _can_place_object_at(
			_hover_cell, _selected_object_item, _object_rotation, wanted):
		return wanted

	var step := grid.sub_cell_size()
	var candidates: Array[Vector3] = []
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			candidates.append(Vector3(float(dx) * step, 0.0, float(dz) * step))
	candidates.sort_custom(func(a: Vector3, b: Vector3) -> bool:
		var da := a.distance_squared_to(wanted)
		var db := b.distance_squared_to(wanted)
		if absf(da - db) > 0.0001:
			return da < db
		# En empate, preferir el centro de la celda.
		return a.length_squared() < b.length_squared()
	)
	for candidate in candidates:
		if candidate.is_equal_approx(wanted):
			continue
		if _can_place_object_at(
				_hover_cell, _selected_object_item, _object_rotation, candidate):
			_hover_rotation = _object_rotation
			return candidate
	return wanted


func _update_ghosts() -> void:
	# El arrastre de pisos mantiene su propia previsualizacion persistente:
	# no hay que ocultarla en cada frame.
	if _floor_dragging:
		return
	if _zone_dragging:
		return
	_hide_ghosts()
	if not _hovering:
		return
	# Los fantasmas del arrastre de paredes son nodos aparte; el hover se oculta.
	if _wall_dragging:
		return

	match tool:
		Tool.FLOOR:
			_show_floor_preview(grid.clamp_cell(_hover_cell), false)
		Tool.ZONE:
			_show_zone_preview(grid.clamp_cell(_hover_cell), false)
		Tool.ZONE_ERASE:
			_show_zone_preview(grid.clamp_cell(_hover_cell), true)
		Tool.WALL:
			_show_wall_ghost(grid.clamp_wall(_hover_wall),
				_can_place_wall(_hover_wall), false)
		Tool.OBJECT:
			var place_cell := _hover_anchor_cell
			var place_rotation := _object_rotation
			if _hover_rotation >= 0:
				place_rotation = _hover_rotation
			_show_object_ghost(place_cell,
				_can_place_object_at(place_cell, _selected_object_item,
					place_rotation, _hover_sub_offset), false,
				_hover_sub_offset)
		Tool.ERASE:
			match erase_kind:
				EraseKind.OBJECT:
					_show_object_ghost(grid.clamp_cell(_hover_cell),
						_object_cells.has(_hover_cell), true)
				EraseKind.WALL:
					_show_wall_ghost(_hover_wall, _walls.has(_hover_wall), true)
				EraseKind.FLOOR:
					_show_floor_preview(grid.clamp_cell(_hover_cell), true)
				_:
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
	if _wall_ghost_model == null or _wall_ghost_scene != wall_scene \
			or _wall_ghost_erasing != erasing:
		_rebuild_wall_ghost_model(erasing)
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


func _show_object_ghost(
	cell: Vector2i,
	valid: bool,
	erasing: bool,
	sub_offset: Vector3 = Vector3.ZERO
) -> void:
	if _object_ghost == null:
		return

	var scene: PackedScene = null
	var footprint := Vector2i(1, 1)
	var steps := _object_rotation
	var offset := sub_offset
	if erasing:
		# Al borrar se muestra el modelo del objeto que hay bajo el cursor.
		var piece := _object_cells.get(cell) as BuildPiece
		if piece != null:
			var item := _find_item_by_id(piece.item_id)
			steps = piece.object_rotation_steps
			offset = piece.sub_offset
			if item != null:
				scene = item.scene
				footprint = _object_footprint(item, steps)
			# El objeto puede ocupar varias celdas: usar su celda primaria.
			cell = piece.cell
	elif _selected_object_item != null:
		if _hover_rotation >= 0:
			steps = _hover_rotation
		scene = _selected_object_item.scene
		footprint = _object_footprint(_selected_object_item, steps)

	if _object_ghost_model == null or _object_ghost_scene != scene \
			or _object_ghost_footprint != footprint \
			or _object_ghost_erasing != erasing:
		_rebuild_object_ghost_model(scene, footprint, erasing)
	if _object_ghost_model == null or _object_ghost_material == null:
		return

	_object_ghost.visible = true
	_object_ghost.global_transform = Transform3D(
		Basis(Vector3.UP, float(steps) * PI * 0.5),
		grid.cell_center(cell) + _object_footprint_offset(footprint) \
			+ offset + Vector3.UP * object_height_offset
	)
	_update_ghost_material(
		_object_ghost_material, _object_ghost, _object_ghost_aabb,
		valid, erasing, GHOST_CURRENT_STRENGTH, 1.0,
		maxf(_object_ghost_aabb.size.y, 1.0)
	)


func _hide_ghosts() -> void:
	if _floor_preview != null:
		_floor_preview.visible = false
	if _zone_preview != null:
		_zone_preview.visible = false
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
		if not grid.grid_resized.is_connected(_on_grid_resized):
			grid.grid_resized.connect(_on_grid_resized)
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
	# Overlay de zonas: un quad por celda, coloreado por tipo. Se construye en
	# coordenadas de mundo, por eso el nodo es top-level.
	_zones_overlay = MeshInstance3D.new()
	_zones_overlay.name = "ZonesOverlay"
	_zones_overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_zones_material = StandardMaterial3D.new()
	_zones_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_zones_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_zones_material.vertex_color_use_as_albedo = true
	_zones_material.albedo_color = Color.WHITE
	_zones_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_zones_overlay.material_override = _zones_material
	_zones_overlay.visible = false
	add_child(_zones_overlay)
	_zones_overlay.top_level = true
	_zones_overlay.global_transform = Transform3D.IDENTITY

	# Etiquetas 3D con el nombre del tipo en el centro de cada zona.
	_zone_labels_root = Node3D.new()
	_zone_labels_root.name = "ZoneLabels"
	add_child(_zone_labels_root)
	_zone_labels_root.top_level = true
	_zone_labels_root.global_transform = Transform3D.IDENTITY
	_zone_labels_root.visible = false

	# Pincel de zonas: reutiliza el shader plano del pincel de pisos.
	_zone_preview = MeshInstance3D.new()
	_zone_preview.name = "ZonePreview"
	_zone_preview.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_zone_preview_material = ShaderMaterial.new()
	_zone_preview_material.shader = FLOOR_PREVIEW_SHADER
	_zone_preview.material_override = _zone_preview_material
	_zone_preview.visible = false
	add_child(_zone_preview)
	_zone_preview.top_level = true
	var zone_mask := Image.create(1, 1, false, Image.FORMAT_L8)
	zone_mask.fill(Color(1, 1, 1))
	_zone_preview_mask = ImageTexture.create_from_image(zone_mask)
	_zone_preview_material.set_shader_parameter("valid_mask", _zone_preview_mask)

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
func _rebuild_wall_ghost_model(erasing: bool = false) -> void:
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
	_wall_ghost_erasing = erasing

	var built := _build_wall_ghost_visual(erasing)
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
func _build_wall_ghost_visual(erasing: bool = false) -> Dictionary:
	var mat := ShaderMaterial.new()
	mat.shader = GHOST_ERASE_SHADER if erasing else GHOST_SHADER

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
func _rebuild_object_ghost_model(
	scene: PackedScene, footprint: Vector2i, erasing: bool = false
) -> void:
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
	_object_ghost_erasing = erasing

	var built := _build_object_ghost_visual(scene, footprint, erasing)
	if built.is_empty():
		return
	_object_ghost_model = built["root"]
	_object_ghost_material = built["mat"]
	_object_ghost_aabb = built.get("aabb", AABB())
	_object_ghost.add_child(_object_ghost_model)
	_object_ghost.visible = false


## Instancia el modelo del objeto y le aplica el mismo shader que a las paredes.
func _build_object_ghost_visual(
	scene: PackedScene, footprint: Vector2i, erasing: bool = false
) -> Dictionary:
	var mat := ShaderMaterial.new()
	mat.shader = GHOST_ERASE_SHADER if erasing else GHOST_SHADER

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
	# Mismo recentrado que en la pieza real: el fantasma debe coincidir con la
	# huella aunque el pivote del modelo no este centrado.
	_center_visual_xz(instance)

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


## Desmontaje de una pared: se hunde en el suelo (escala Y a 0) después de un
## pequeño retardo, como el efecto de obra pero al revés.
func _animate_wall_erase(piece: BuildPiece, order: int) -> void:
	var visual := _piece_visual_node(piece)
	var tween := create_tween()
	tween.bind_node(piece)
	tween.tween_interval(float(order) * WALL_ERASE_STAGGER)
	if visual == null:
		tween.tween_interval(WALL_ERASE_TIME)
	else:
		var is_box := visual is MeshInstance3D \
			and (visual as MeshInstance3D).mesh is BoxMesh
		tween.tween_property(visual, "scale:y", 0.001, WALL_ERASE_TIME) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
		if is_box:
			tween.parallel().tween_property(
				visual, "position:y",
				visual.position.y - wall_height * 0.5, WALL_ERASE_TIME
			).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tween.tween_callback(_free_piece.bind(piece))


## Desmontaje de un piso: se encoge en el plano hasta desaparecer.
func _animate_floor_erase(piece: BuildPiece, order: int) -> void:
	var visual := _piece_visual_node(piece)
	var tween := create_tween()
	tween.bind_node(piece)
	tween.tween_interval(float(order) * FLOOR_ERASE_STAGGER)
	if visual == null:
		tween.tween_interval(FLOOR_ERASE_TIME)
	else:
		var original := visual.scale
		var target := Vector3(original.x * 0.01, original.y, original.z * 0.01)
		tween.tween_property(visual, "scale", target, FLOOR_ERASE_TIME) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tween.tween_callback(_free_piece.bind(piece))


## Desmontaje de un objeto: se encoge completo desde su base.
func _animate_object_erase(piece: Node3D, order: int = 0) -> void:
	var tween := create_tween()
	tween.bind_node(piece)
	tween.tween_interval(float(order) * OBJECT_ERASE_STAGGER)
	var original := piece.scale
	var target := Vector3(original.x * 0.01, original.y * 0.01, original.z * 0.01)
	tween.tween_property(piece, "scale", target, OBJECT_ERASE_TIME) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tween.tween_callback(_free_piece.bind(piece))


func _free_piece(piece: Node) -> void:
	if is_instance_valid(piece):
		piece.queue_free()


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
		+ "M: menú (Construir)   ·   R: rotar   ·   ° / Ctrl+S: guardar   ·   B / Esc: salir",
		15, Color(0.85, 0.9, 0.95, 0.9)
	)
	hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	hint.offset_left = 18
	hint.offset_top = -72
	hint.offset_right = 980
	hint.offset_bottom = -14
	_ui_layer.add_child(hint)
	_build_zone_menu()

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


## Menu modal para asignar el tipo de una zona pintada.
func _build_zone_menu() -> void:
	_zone_menu_root = CenterContainer.new()
	_zone_menu_root.name = "ZoneMenuRoot"
	_zone_menu_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_zone_menu_root.visible = false
	_ui_layer.add_child(_zone_menu_root)

	_zone_menu = PanelContainer.new()
	_zone_menu.custom_minimum_size = Vector2(380, 0)
	_zone_menu_root.add_child(_zone_menu)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_bottom", 14)
	_zone_menu.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "Asignar zona"
	title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title)

	_zone_menu_label = Label.new()
	_zone_menu_label.add_theme_font_size_override("font_size", 13)
	_zone_menu_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_zone_menu_label)

	for type_id in [&"hallway", &"waiting", &"consult"]:
		var info: Dictionary = ZONE_TYPES[type_id]
		var btn := Button.new()
		btn.text = String(info["name"])
		btn.custom_minimum_size = Vector2(0, 40)
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var col: Color = info["color"]
		btn.add_theme_color_override(
			"font_color", Color(col.r, col.g, col.b, 1.0).lightened(0.25)
		)
		btn.pressed.connect(_assign_zone_type.bind(type_id))
		vbox.add_child(btn)
		_zone_menu_buttons[type_id] = btn

	var cancel := Button.new()
	cancel.text = "Cancelar"
	cancel.custom_minimum_size = Vector2(0, 36)
	cancel.pressed.connect(_close_zone_menu)
	vbox.add_child(cancel)


func _update_ui() -> void:
	if _ui_layer == null:
		return
	_ui_layer.visible = build_mode and show_help
	if not build_mode:
		return

	var tool_name := _tool_name()
	if _hovering:
		var text := "%s   ·   celda (%d, %d)" % [
			tool_name, _hover_cell.x, _hover_cell.y
		]
		var zone_type := get_zone_type(_hover_cell)
		if zone_type != &"":
			text += "   ·   zona: %s" % _zone_type_name(zone_type)
		_ui_tool.text = text
	else:
		_ui_tool.text = tool_name


func _tool_name() -> String:
	if selected_item != null and selected_item.display_name != "":
		return "Herramienta: %s" % selected_item.display_name
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
			match erase_kind:
				EraseKind.FLOOR:
					return "Herramienta: borrar piso"
				EraseKind.WALL:
					return "Herramienta: borrar pared"
				EraseKind.OBJECT:
					return "Herramienta: borrar objeto"
				_:
					return "Herramienta: borrar"
		Tool.ZONE:
			return "Herramienta: zona"
		Tool.ZONE_ERASE:
			return "Herramienta: borrar zona"
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
		"zones": [],
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
	for piece in _object_pieces:
		if piece == null or not is_instance_valid(piece):
			continue
		data["objects"].append({
			"x": piece.cell.x,
			"y": piece.cell.y,
			"item_id": String(piece.item_id),
			"rotation": piece.object_rotation_steps,
			"offset_x": piece.sub_offset.x,
			"offset_z": piece.sub_offset.z,
		})

	# Zonas: agrupadas por id para conservar cada trazo por separado.
	var zones_by_id: Dictionary = {}
	for cell in _zone_cells.keys():
		var zone_id: StringName = _zone_cells[cell]
		if not zones_by_id.has(zone_id):
			zones_by_id[zone_id] = {
				"type": String(_zone_types.get(zone_id, ZONE_DEFAULT_TYPE)),
				"cells": [],
			}
		zones_by_id[zone_id]["cells"].append([cell.x, cell.y])
	for zone_id in zones_by_id.keys():
		data["zones"].append(zones_by_id[zone_id])

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
	print("BuildController: construcción guardada en %s (%d suelos, %d paredes, %d objetos, %d zonas)" % [
		path, data["floors"].size(), data["walls"].size(),
		data["objects"].size(), data["zones"].size()
	])
	var zones_note := ""
	if int(data["zones"].size()) > 0:
		zones_note = "  ·  %d zonas" % int(data["zones"].size())
	_show_build_message(
		"Construcción guardada: %d piezas%s  ·  %s" % [total, zones_note, path],
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


## Aviso breve cuando la grilla crece automaticamente al construir cerca del
## borde.
func _on_grid_resized(cells_x: int, cells_z: int) -> void:
	_show_build_message(
		"Grilla ampliada: %d x %d" % [cells_x, cells_z],
		Color(0.86, 0.94, 1.0)
	)


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
		var item := _find_item_by_id(StringName(String(entry.get("item_id", ""))))
		if item == null:
			continue
		var rot := int(entry.get("rotation", 0))
		var sub := Vector3(
			float(entry.get("offset_x", 0.0)), 0.0,
			float(entry.get("offset_z", 0.0))
		)
		if _place_object(cell, item, rot, sub):
			changed = true

	# Zonas
	var zones_loaded := false
	_close_zone_menu()
	_zone_cells.clear()
	_zone_types.clear()
	_next_zone_id = 1
	for entry in data.get("zones", []):
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var type_id := StringName(String(entry.get("type", "unassigned")))
		if not ZONE_TYPES.has(type_id):
			type_id = ZONE_DEFAULT_TYPE
		var zone_id := _new_zone_id()
		_zone_types[zone_id] = type_id
		for cell_entry in entry.get("cells", []):
			if typeof(cell_entry) != TYPE_ARRAY or cell_entry.size() < 2:
				continue
			var cell := Vector2i(int(cell_entry[0]), int(cell_entry[1]))
			if grid.is_cell_inside(cell):
				_zone_cells[cell] = zone_id
				zones_loaded = true
	_cleanup_zone_types()
	_rebuild_zones_overlay()
	if zones_loaded:
		zones_changed.emit()

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
