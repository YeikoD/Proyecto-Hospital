class_name NpcBrain
extends Node

## Cerebro mínimo para SmartObjects.
##
## Bucle: necesidades -> elegir affordance -> reservar slot -> viajar -> usar
## -> liberar. Es deliberadamente simple: la selección por utilidad se puede
## reemplazar por GOAP/HTN más adelante sin tocar SmartObject ni el registry.
##
## La reserva se hace ANTES de caminar. Así varios NPC no eligen el mismo
## mueble y después pierden el viaje.

enum State { IDLE, SEEK, TRAVEL, USE }

## Distancia de llegada al punto de aproximación de un SmartObject. Cubre la
## diferencia vertical entre el NavMesh y el cuerpo del NPC.
const ARRIVE_DISTANCE := 0.25

signal interaction_started(object: Node, affordance: AffordanceDef)
signal interaction_finished(object: Node, affordance: AffordanceDef)
signal interaction_aborted(object: Node)

@export var enabled := true
@export var agent_path: NodePath
@export var search_radius := 25.0
@export var think_interval := 0.5

@export_group("Necesidades")
## necesidad -> valor actual (0..1). Cuanto más alto, más urgente.
@export var needs: Dictionary = {"rest": 0.0, "work": 0.0}
## necesidad -> cuánto crece por segundo.
@export var need_growth: Dictionary = {"rest": 0.01, "work": 0.005}
## necesidad -> affordance que la satisface.
@export var need_affordances: Dictionary = {"rest": &"sit", "work": &"work"}
## Por debajo de este valor la necesidad no dispara una búsqueda.
@export var need_threshold := 0.6
## Tiempo máximo para llegar al objeto antes de abortar y liberar el slot.
## Se cuenta como tiempo **sin avanzar**: caminatas largas no lo agotan.
@export var travel_timeout := 20.0
## Si el NPC se traba caminando hacia la grilla, vuelve a pensar tras este
## tiempo (no desaparece).
@export var seek_stall_timeout := 30.0

@export_group("Depuración")
@export var debug := false

var _agent: NpcAgent
var _state: int = State.IDLE
var _agent_id := 0
var _think_timer := 0.0
var _travel_timer := 0.0
var _use_timer := 0.0

var _object = null
var _affordance: AffordanceDef = null
var _slot := -1
var _anim_manager: NpcAnimationManager
var _anim_active := false
var _anim_looped := false
var _exit_requested := false
## Cuando el NPC viene de fuera de la grilla, primero camina hasta la celda
## construida mas cercana y recien despues va al mueble.
var _via_gateway := false
var _seek_timer := 0.0
var _seek_last := Vector3.ZERO
var _last_travel_pos := Vector3.ZERO


func _ready() -> void:
	_agent = _resolve_agent()
	_agent_id = get_instance_id()
	if enabled:
		_activate()
	else:
		set_process(false)


# --------------------------------------------------------------------------
# API
# --------------------------------------------------------------------------

func set_enabled(value: bool) -> void:
	enabled = value
	if enabled:
		_activate()
	else:
		_abort()
		set_process(false)


func is_interacting() -> bool:
	return _state == State.USE


func get_state() -> int:
	return _state


func get_current_affordance() -> AffordanceDef:
	return _affordance


func get_current_object() -> Node:
	return _object


# --------------------------------------------------------------------------
# Bucle principal
# --------------------------------------------------------------------------

func _activate() -> void:
	if _agent == null:
		_agent = _resolve_agent()
	if _agent == null:
		push_warning("NpcBrain: no se encontró un NpcAgent.")
		return
	_agent.wander = false
	if not _agent.arrived.is_connected(_on_arrived):
		_agent.arrived.connect(_on_arrived)

	_anim_manager = _agent.get_animation_manager()
	if _anim_manager != null:
		if not _anim_manager.loop_started.is_connected(_on_animation_loop_started):
			_anim_manager.loop_started.connect(_on_animation_loop_started)
		if not _anim_manager.finished.is_connected(_on_animation_finished):
			_anim_manager.finished.connect(_on_animation_finished)

	set_process(true)
	_think_timer = 0.0


func _process(delta: float) -> void:
	if not enabled or _agent == null:
		return

	_tick_needs(delta)
	match _state:
		State.IDLE:
			_tick_idle(delta)
		State.SEEK:
			_tick_seek(delta)
		State.TRAVEL:
			_tick_travel(delta)
		State.USE:
			_tick_use(delta)


func _tick_needs(delta: float) -> void:
	for need in needs.keys():
		var growth := float(need_growth.get(need, 0.0))
		needs[need] = clampf(float(needs[need]) + growth * delta, 0.0, 1.0)


func _tick_idle(delta: float) -> void:
	_think_timer -= delta
	if _think_timer > 0.0:
		return
	_think_timer = maxf(think_interval, 0.05)

	for need in _needs_by_urgency():
		var affordance_id: StringName = need_affordances.get(need, StringName())
		if affordance_id == StringName():
			continue

		# Si viene de fuera de la grilla, primero camina a la celda construida
		# mas cercana. Recien al llegar elige el mueble: la distancia no importa.
		if _is_outside_grid() and _has_free_candidate(affordance_id):
			if _walk_to_grid_gateway():
				_begin_seek()
				return

		var candidate := SmartObjectRegistry.claim_best(
			affordance_id, _agent.global_position, search_radius, _agent_id
		)
		if candidate.is_empty():
			# Esa necesidad no tiene un objeto libre: probar la siguiente.
			continue
		_begin(candidate)
		return


## El NPC esta parado fuera de las celdas construidas.
func _is_outside_grid() -> bool:
	var controller := BuildController.get_active()
	if controller == null or controller.grid == null:
		return false
	return not controller.has_floor_at_world(_agent.global_position)


## Hay algun SmartObject libre con esa affordance (sin reservarlo).
func _has_free_candidate(affordance_id: StringName) -> bool:
	return not SmartObjectRegistry.find_candidates(
		affordance_id, _agent.global_position, search_radius, _agent_id
	).is_empty()


func _begin_seek() -> void:
	_state = State.SEEK
	_seek_last = _agent.global_position
	_seek_timer = maxf(seek_stall_timeout, 1.0)


## Vigila que el NPC avance hacia la grilla. Si se traba, vuelve a pensar.
func _tick_seek(delta: float) -> void:
	if _agent == null:
		_state = State.IDLE
		return
	var pos := _agent.global_position
	if pos.distance_to(_seek_last) > 0.5:
		_seek_last = pos
		_seek_timer = maxf(seek_stall_timeout, 1.0)
		return
	_seek_timer -= delta
	if _seek_timer <= 0.0:
		_state = State.IDLE
		_think_timer = 0.5


func _needs_by_urgency() -> Array[String]:
	var urgent: Array[String] = []
	for need in needs.keys():
		if float(needs[need]) >= need_threshold:
			urgent.append(String(need))
	urgent.sort_custom(func(a: String, b: String) -> bool:
		return float(needs[a]) > float(needs[b])
	)
	return urgent


func _begin(candidate: Dictionary) -> void:
	_object = candidate["object"]
	_affordance = candidate["affordance"]
	_slot = int(candidate["slot"])
	_state = State.TRAVEL
	_travel_timer = maxf(travel_timeout, 1.0)
	_last_travel_pos = _agent.global_position

	_agent.set_frozen(false)
	# Si el NPC viene del terreno (fuera de la grilla), primero entra por la
	# celda construida mas cercana. Recien despues camina al mueble.
	_via_gateway = _needs_grid_gateway()
	if _via_gateway:
		_via_gateway = _walk_to_grid_gateway()
	# Caminar hasta el punto de aproximación (fuera del collider del mueble) y
	# exigir una llegada fina: la secuencia de sentarse no debe empezar hasta
	# que el NPC esté físicamente junto al mueble.
	if not _via_gateway:
		_agent.move_to(_object.get_approach_position(_slot), ARRIVE_DISTANCE)
	if debug:
		print("[NpcBrain] %s -> %s%s" % [
			_agent.name, _affordance.id, " (via grilla)" if _via_gateway else ""
		])


func _tick_travel(delta: float) -> void:
	if not _object_alive():
		_abort()
		return
	# Timeout por estancamiento: si el NPC avanza, el reloj se reinicia. Asi
	# una caminata larga (spawner lejos) nunca aborta la interaccion.
	var pos := _agent.global_position
	if pos.distance_to(_last_travel_pos) > 0.5:
		_last_travel_pos = pos
		_travel_timer = maxf(travel_timeout, 1.0)
	_travel_timer -= delta
	if _travel_timer <= 0.0:
		_abort()


## El NPC esta fuera de la grilla y el mueble esta dentro: conviene entrar por
## una celda construida en vez de cortar camino campo a traves.
func _needs_grid_gateway() -> bool:
	if not _object_alive() or _agent == null:
		return false
	var controller := BuildController.get_active()
	if controller == null or controller.grid == null:
		return false
	if controller.has_floor_at_world(_agent.global_position):
		return false
	return controller.has_floor_at_world(_object.global_position)


## Manda al NPC a la celda de grilla alcanzable mas cercana. Devuelve true si
## encontro una entrada valida (y ya arranco el viaje hacia ella).
func _walk_to_grid_gateway() -> bool:
	var controller := BuildController.get_active()
	if controller == null or _agent == null:
		return false
	var map := _agent.get_world_3d().navigation_map
	if NavigationServer3D.map_get_iteration_id(map) == 0:
		return false
	var points: Array = Array(controller.get_floor_points())
	if points.is_empty():
		return false

	var from := _agent.global_position
	points.sort_custom(func(a: Vector3, b: Vector3) -> bool:
		return from.distance_squared_to(a) < from.distance_squared_to(b)
	)

	# Solo probamos las mas cercanas: alcanza para encontrar la entrada y evita
	# cientos de consultas de camino.
	var attempts := mini(points.size(), 24)
	for i in attempts:
		var cell_point: Vector3 = points[i]
		var nav_point := NavigationServer3D.map_get_closest_point(map, cell_point)
		if nav_point.is_zero_approx() and not cell_point.is_zero_approx():
			continue
		if nav_point.distance_to(cell_point) > 1.0:
			continue
		# Ya esta en la entrada: no hace falta otro tramo.
		if from.distance_to(nav_point) <= 1.0:
			return false
		var path := NavigationServer3D.map_get_path(map, from, nav_point, true)
		if path.size() <= 1:
			continue
		_agent.move_to(nav_point, ARRIVE_DISTANCE)
		return true
	return false


func _tick_use(delta: float) -> void:
	if not _object_alive():
		_abort()
		return

	# Secuencia animada: la duración empieza a contar cuando arranca el loop.
	if _anim_active:
		if not _anim_looped or _exit_requested:
			return
		if _affordance != null and _affordance.duration < 0.0:
			return
		_use_timer -= delta
		if _use_timer <= 0.0:
			_exit_requested = true
			if _anim_manager != null:
				_anim_manager.request_exit()
		return

	# Duración negativa: el NPC se queda hasta que algo lo interrumpa.
	if _affordance != null and _affordance.duration < 0.0:
		return
	if _use_timer > 0.0:
		_use_timer -= delta
		if _use_timer > 0.0:
			return
	_finish()


# --------------------------------------------------------------------------
# Llegada / fin
# --------------------------------------------------------------------------

func _on_arrived() -> void:
	# Etapa de entrada: ya llego a la grilla, ahora si puede elegir el mueble.
	if _state == State.SEEK:
		_state = State.IDLE
		_think_timer = 0.0
		return
	if _state != State.TRAVEL or not _object_alive():
		return

	# Primera etapa del viaje: ya entramos a la grilla. Ahora si, al mueble.
	if _via_gateway:
		_via_gateway = false
		_travel_timer = maxf(travel_timeout, 1.0)
		_last_travel_pos = _agent.global_position
		_agent.move_to(_object.get_approach_position(_slot), ARRIVE_DISTANCE)
		return

	_object.occupy(_slot, _agent_id)
	_agent.set_frozen(true)

	_anim_active = false
	_anim_looped = false
	_exit_requested = false
	_use_timer = maxf(_affordance.duration, 0.0)
	_state = State.USE

	var animated := false
	if _affordance.animation_set != null and _anim_manager != null:
		_anim_active = true
		animated = _anim_manager.play_at(
			_affordance.animation_set,
			_object.get_poi_transform(_slot),
			_object.get_approach_transform(_slot)
		)
		if not animated:
			_anim_active = false

	if not animated:
		_agent.look_towards(_object.global_position)
		if _affordance.animation != StringName():
			_agent.play_interaction(_affordance.animation)

	interaction_started.emit(_object, _affordance)
	if debug:
		print("[NpcBrain] usando %s%s" % [
			_affordance.id, " (animado)" if animated else ""
		])


## El loop ya corre: desde ahora se cuenta la duración de la interacción.
func _on_animation_loop_started() -> void:
	if _state != State.USE or not _anim_active:
		return
	_anim_looped = true
	_use_timer = maxf(_affordance.duration, 0.0) if _affordance != null else 0.0


## La secuencia enter -> loop -> exit terminó y el NPC ya está en su punto de
## salida. Se cierra la interacción normalmente.
func _on_animation_finished() -> void:
	if _state != State.USE or not _anim_active:
		return
	_anim_active = false
	_anim_looped = false
	_exit_requested = false
	_finish()


func _finish() -> void:
	var obj = _object
	var aff := _affordance

	if _anim_manager != null and _anim_manager.is_playing():
		_anim_manager.cancel()
	if _object_alive():
		_object.release(_slot, _agent_id)
	if _agent != null:
		_agent.stop_interaction()
		_agent.set_frozen(false)
	if aff != null:
		for need in aff.needs_effects.keys():
			needs[need] = clampf(
				float(needs.get(need, 0.0)) - float(aff.needs_effects[need]),
				0.0, 1.0
			)

	interaction_finished.emit(obj, aff)
	_reset()
	_state = State.IDLE
	_think_timer = 1.5
	if debug:
		print("[NpcBrain] fin de %s" % (aff.id if aff != null else "?"))


## Salida limpia: libera la reserva y detiene al NPC. Se usa ante timeout,
## borrado del objeto, desactivación del cerebro o salida del árbol.
func _abort() -> void:
	var obj = _object
	if _anim_manager != null:
		_anim_manager.cancel()
	if _object_alive() and _slot >= 0:
		_object.release(_slot, _agent_id)
	if _agent != null:
		_agent.stop_interaction()
		_agent.set_frozen(false)
		_agent.stop()
	if obj != null and is_instance_valid(obj):
		interaction_aborted.emit(obj)

	_reset()
	_state = State.IDLE
	_think_timer = 0.5


func _reset() -> void:
	_object = null
	_affordance = null
	_slot = -1
	_travel_timer = 0.0
	_use_timer = 0.0
	_anim_active = false
	_anim_looped = false
	_exit_requested = false
	_via_gateway = false
	_seek_timer = 0.0
	_seek_last = Vector3.ZERO
	_last_travel_pos = Vector3.ZERO


func _object_alive() -> bool:
	return _object != null and is_instance_valid(_object)


func _exit_tree() -> void:
	if _state != State.IDLE:
		_abort()


# --------------------------------------------------------------------------
# Nodos
# --------------------------------------------------------------------------

func _resolve_agent() -> NpcAgent:
	if not agent_path.is_empty():
		var node := get_node_or_null(agent_path)
		if node is NpcAgent:
			return node as NpcAgent
	var parent := get_parent()
	if parent is NpcAgent:
		return parent as NpcAgent
	for child in get_children():
		if child is NpcAgent:
			return child as NpcAgent
	return null
