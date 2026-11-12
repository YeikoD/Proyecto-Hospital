class_name BuildNavigation
extends Node

## Mantiene horneado el NavMesh a partir de las piezas de la grilla.
##
## Las piezas colocadas viven dentro del NavigationRegion3D, asi que el bake
## las usa como geometria fuente: los suelos son superficie caminable y las
## paredes recortan el area navegable. Cada vez que el BuildController coloca
## o borra algo se pide un rebake con debounce, para no hornear en cada frame
## mientras se pinta con el raton.

signal navigation_bake_started
signal navigation_baked

@export var navigation_region: NavigationRegion3D
@export var build_controller: BuildController

@export_group("Horneado")
## Si esta activo, cualquier cambio de piezas dispara un rebake automatico.
@export var auto_bake := true
## Espera antes de hornear, para agrupar varios cambios seguidos.
@export var bake_delay := 0.35
## Hornea al arrancar si ya hay suelos colocados.
@export var bake_on_ready := true

@export_group("Agente")
## Radio con el que se erosiona el NavMesh alrededor de las paredes.
@export var agent_radius := 0.3
@export var agent_height := 1.7
@export var agent_max_climb := 0.2
@export var agent_max_slope := 45.0
## Tamano de celda del hornado. Debe coincidir con el mapa de navegacion.
@export var cell_size := 0.1
@export var cell_height := 0.1

@export_group("Limites")
## Recorta el volumen de horneado a la grilla y a la altura del agente, para
## que las caras superiores de las paredes no se vuelvan caminables.
@export var limit_bake_bounds := true
@export var bounds_padding := 1.0

@export_group("Mapa")
## Hornea tambien la geometria del mapa (suelo, terreno, rampas) marcada con
## `geometry_group`. Asi el NavMesh cubre todo el mapa y los NPC pueden caminar
## fuera de la grilla construida.
@export var include_scene_geometry := false
## Grupo cuyos nodos (y sus hijos) se usan como geometria caminable extra.
@export var geometry_group: StringName = &"navigation_static"

## Cantidad de horneados completados (util para tests y diagnostico).
var bake_count := 0

## Instancias activas: permite a otros sistemas saber si hay un horneado en
## curso (durante el bake el NavMesh queda vacio por un instante).
static var _instances: Array = []

var _bake_timer: Timer
var _dirty := false
var _baking := false


## True si cualquier `BuildNavigation` de la escena esta horneando.
## Los spawners lo consultan para no aparecer mientras el NavMesh no esta
## sincronizado (evita que `map_get_closest_point` devuelva el origen).
static func is_any_baking() -> bool:
	for instance in _instances:
		if is_instance_valid(instance) and instance.is_baking():
			return true
	return false


func _ready() -> void:
	if not _instances.has(self):
		_instances.append(self)
	_resolve_references()
	if navigation_region == null:
		push_warning("BuildNavigation: falta un NavigationRegion3D.")
		return

	_prepare_navmesh()
	_sync_map_cell_size()
	_validate_pieces_root()

	_bake_timer = Timer.new()
	_bake_timer.name = "BakeTimer"
	_bake_timer.one_shot = true
	_bake_timer.wait_time = maxf(bake_delay, 0.01)
	_bake_timer.timeout.connect(bake_now)
	add_child(_bake_timer)

	if not navigation_region.bake_finished.is_connected(_on_bake_finished):
		navigation_region.bake_finished.connect(_on_bake_finished)

	if build_controller != null \
			and not build_controller.pieces_changed.is_connected(_on_pieces_changed):
		build_controller.pieces_changed.connect(_on_pieces_changed)

	if bake_on_ready and build_controller != null \
			and (build_controller.get_floor_count() > 0 or include_scene_geometry):
		call_deferred("request_bake")


func _exit_tree() -> void:
	_instances.erase(self)


# --------------------------------------------------------------------------
# API
# --------------------------------------------------------------------------

## Pide un rebake agrupado (debounce). Es lo que se llama al colocar/borrar.
func request_bake() -> void:
	_dirty = true
	if not auto_bake or _bake_timer == null:
		return
	_bake_timer.start()


## Hornea ahora, sin esperar el debounce.
func bake_now() -> void:
	if navigation_region == null or not is_inside_tree():
		return

	# Si se llama a mano, cancelar el debounce pendiente.
	if _bake_timer != null:
		_bake_timer.stop()

	if navigation_region.is_baking():
		_dirty = true
		return

	# Sin suelos no hay superficie caminable: limpiamos el NavMesh. Si ademas
	# horneamos la geometria del mapa, el mapa sigue siendo caminable.
	if not include_scene_geometry and build_controller != null \
			and build_controller.get_floor_count() == 0:
		_dirty = false
		_clear_navigation()
		return

	_prepare_navmesh()
	_sync_source_group()
	_apply_settings(navigation_region.navigation_mesh)
	_update_bake_bounds()

	_dirty = false
	_baking = true
	navigation_bake_started.emit()
	navigation_region.bake_navigation_mesh(true)


func is_baking() -> bool:
	if _baking:
		return true
	return navigation_region != null \
		and is_instance_valid(navigation_region) \
		and navigation_region.is_baking()


## Cantidad de poligonos del NavMesh actual (util para tests y debug).
func get_polygon_count() -> int:
	if navigation_region == null or navigation_region.navigation_mesh == null:
		return 0
	return navigation_region.navigation_mesh.get_polygon_count()


# --------------------------------------------------------------------------
# Configuracion
# --------------------------------------------------------------------------

func _prepare_navmesh() -> void:
	if navigation_region == null:
		return
	if navigation_region.navigation_mesh == null:
		navigation_region.navigation_mesh = NavigationMesh.new()


func _apply_settings(mesh: NavigationMesh) -> void:
	mesh.agent_radius = agent_radius
	mesh.agent_height = agent_height
	mesh.agent_max_climb = agent_max_climb
	mesh.agent_max_slope = agent_max_slope
	mesh.cell_size = cell_size
	mesh.cell_height = cell_height

	# Los BuildPiece son StaticBody3D con BoxShape3D: parsear colliders es mas
	# rapido que sincronizar mallas desde el hilo de horneado.
	mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	if include_scene_geometry:
		# Las piezas de la grilla y la geometria del mapa (suelo/terreno) viven
		# en nodos distintos: las unimos por grupo para que el hornado vea todo.
		mesh.geometry_source_geometry_mode = \
			NavigationMesh.SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN
		mesh.geometry_source_group_name = String(geometry_group)
	else:
		mesh.geometry_source_geometry_mode = \
			NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN
	mesh.geometry_collision_mask = 1

	mesh.filter_low_hanging_obstacles = true
	mesh.filter_ledge_spans = true
	mesh.filter_walkable_low_height_spans = true
	mesh.region_min_size = 1.0
	mesh.region_merge_size = 10.0
	mesh.edge_max_error = 1.0
	mesh.vertices_per_polygon = 6.0
	mesh.sample_partition_type = NavigationMesh.SAMPLE_PARTITION_WATERSHED


## Las piezas solo se hornean si viven dentro del NavigationRegion3D.
func _validate_pieces_root() -> void:
	if navigation_region == null or build_controller == null:
		return
	var pieces := build_controller.pieces_root
	if pieces != null and not navigation_region.is_ancestor_of(pieces):
		push_warning(
			"BuildNavigation: PlacedPieces debe estar dentro de NavRegion; " +
			"el NavMesh no incluira las piezas colocadas."
		)


## El mapa y el NavMesh deben usar la misma celda; si no, el servidor puede
## descartar conexiones entre poligonos.
func _sync_map_cell_size() -> void:
	if navigation_region == null:
		return
	var map := navigation_region.get_navigation_map()
	if map.is_valid():
		NavigationServer3D.map_set_cell_size(map, cell_size)
		NavigationServer3D.map_set_cell_height(map, cell_height)


## Con `include_scene_geometry`, el modo de horneado pasa a ser por grupo: hay
## que meter las piezas de la grilla en el mismo grupo que el mapa.
func _sync_source_group() -> void:
	if not include_scene_geometry or build_controller == null:
		return
	var pieces := build_controller.pieces_root
	if pieces == null:
		return
	if not pieces.is_in_group(String(geometry_group)):
		pieces.add_to_group(String(geometry_group))


func _update_bake_bounds() -> void:
	var mesh := navigation_region.navigation_mesh
	if mesh == null:
		return
	if not limit_bake_bounds or build_controller == null \
			or build_controller.grid == null:
		mesh.filter_baking_aabb = AABB()
		return

	var grid := build_controller.grid
	# El AABB se expresa en espacio local del NavigationRegion3D.
	var base := navigation_region.to_local(grid.global_position)
	var plane_y := base.y + grid.plane_y
	var min_x := base.x - bounds_padding
	var max_x := base.x + grid.cells_x * grid.cell_size + bounds_padding
	var min_z := base.z - bounds_padding
	var max_z := base.z + grid.cells_z * grid.cell_size + bounds_padding

	# Mapa: agrandar el volumen (solo en horizontal) hasta cubrir el suelo y el
	# terreno. La altura se mantiene, asi las paredes no generan techo caminable.
	if include_scene_geometry and is_inside_tree():
		var pieces_root: Node = build_controller.pieces_root
		for node in get_tree().get_nodes_in_group(String(geometry_group)):
			if node == pieces_root:
				continue
			var box := _geometry_aabb(node)
			if box.size == Vector3.ZERO:
				continue
			var local_a := navigation_region.to_local(box.position)
			var local_b := navigation_region.to_local(box.end)
			min_x = minf(min_x, minf(local_a.x, local_b.x))
			max_x = maxf(max_x, maxf(local_a.x, local_b.x))
			min_z = minf(min_z, minf(local_a.z, local_b.z))
			max_z = maxf(max_z, maxf(local_a.z, local_b.z))

	# Techo por debajo de la altura de las paredes: asi sus caras superiores
	# quedan fuera del volumen y no se generan poligonos caminables arriba.
	var top_margin := agent_height + 0.5
	var wall_height := build_controller.wall_height
	if wall_height > 0.0:
		top_margin = minf(top_margin, maxf(wall_height - 0.05, 0.5))
	var height := 0.5 + top_margin

	mesh.filter_baking_aabb = AABB(
		Vector3(min_x, plane_y - 0.5, min_z),
		Vector3(max_x - min_x, height, max_z - min_z)
	)
	mesh.filter_baking_aabb_offset = Vector3.ZERO


## AABB en espacio global de la geometria visual de un nodo y sus hijos.
func _geometry_aabb(node: Node) -> AABB:
	var box := AABB()
	var found := false
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var current: Node = stack.pop_back()
		if current is VisualInstance3D:
			var visual := current as VisualInstance3D
			var b := visual.global_transform * visual.get_aabb()
			box = b if not found else box.merge(b)
			found = true
		for child in current.get_children():
			stack.append(child)
	return box if found else AABB()


# --------------------------------------------------------------------------
# Callbacks
# --------------------------------------------------------------------------

func _on_pieces_changed() -> void:
	if auto_bake:
		request_bake()


func _on_bake_finished() -> void:
	_baking = false
	# Asegurar que el servidor de navegacion reciba el NavMesh recien horneado
	# de forma inmediata, reasignando el mesh y sincronizando el mapa.
	if navigation_region != null:
		var _mesh := navigation_region.navigation_mesh
		navigation_region.navigation_mesh = null
		navigation_region.navigation_mesh = _mesh
		var _map := navigation_region.get_navigation_map()
		if _map.is_valid():
			NavigationServer3D.map_force_update(_map)
	bake_count += 1
	navigation_baked.emit()
	if _dirty:
		# Hubo cambios mientras se horneaba: agrupar y hornear de nuevo.
		if _bake_timer != null:
			_bake_timer.start()


func _clear_navigation() -> void:
	if navigation_region == null:
		return
	var mesh := navigation_region.navigation_mesh
	if mesh == null:
		navigation_baked.emit()
		return
	mesh.clear()
	# Reasignar fuerza al servidor a actualizar el area caminable.
	navigation_region.navigation_mesh = null
	navigation_region.navigation_mesh = mesh
	navigation_baked.emit()


# --------------------------------------------------------------------------
# Busquedas
# --------------------------------------------------------------------------

func _resolve_references() -> void:
	# Buscar primero dentro del BuildSystem local y despues en la escena.
	var local_root := get_parent()
	if navigation_region == null:
		navigation_region = _find_region(local_root)
	if build_controller == null:
		build_controller = _find_controller(local_root)

	var scene_root := get_tree().current_scene
	if scene_root == null:
		scene_root = local_root
	if navigation_region == null:
		navigation_region = _find_region(scene_root)
	if build_controller == null:
		build_controller = _find_controller(scene_root)


func _find_region(node: Node) -> NavigationRegion3D:
	if node == null:
		return null
	if node is NavigationRegion3D:
		return node as NavigationRegion3D
	for child in node.get_children():
		var found := _find_region(child)
		if found != null:
			return found
	return null


func _find_controller(node: Node) -> BuildController:
	if node == null:
		return null
	if node is BuildController:
		return node as BuildController
	for child in node.get_children():
		var found := _find_controller(child)
		if found != null:
			return found
	return null
