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

enum State { IDLE, SEEK, TRAVEL, USE, WAIT }

## Distancia de llegada al punto de aproximación de un SmartObject. Cubre la
## diferencia vertical entre el NavMesh y el cuerpo del NPC.
const ARRIVE_DISTANCE := 0.25

## La affordance `work` del Escritorio de trabajo pertenece al operador y es
## exclusiva del medico. Los NPCs normales solo usan `sit` (pacientes).
const WORK_AFFORDANCE := &"work"
const DOCTOR_GROUP := &"doctor_npcs"
const Consult := preload("res://scripts/characters/npc/npc_consult.gd")

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

@export_group("Consultorio")
## Los NPCs normales pueden sentarse en una silla libre de un consultorio
## activo (zona `consult` + medico trabajando + silla libre).
@export var consult_enabled := true
## Tiempo que espera antes de volver a buscar consultorio tras una consulta.
@export var consult_cooldown := 15.0

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
## Duracion propia de la interaccion (-1 = la de la affordance). Las consultas
## duran mas que un descanso normal.
var _duration_override := -1.0
var _consult_active := false
var _consult_cooldown_timer := 0.0
var _waiting_for_consult := false
var _wait_check_timer := 0.0
var _wait_point := Vector3.ZERO
var _wait_seated := false


func _ready() -> void:
	_agent = _resolve_agent()
	# El id identifica al NPC, no al cerebro: los objetos exclusivos comprueban
	# el grupo del agente (por ejemplo `doctor_npcs`).
	_agent_id = _agent.get_instance_id() if _agent != null else get_instance_id()
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


## Una affordance puede estar reservada a un tipo de NPC. `work` (silla del
## operador del Escritorio de trabajo) es exclusiva del medico: los NPCs
## normales solo usan `sit`, que en el escritorio son las sillas de pacientes.
func can_use_affordance(affordance_id: StringName) -> bool:
	if affordance_id == WORK_AFFORDANCE:
		return _agent != null and _agent.is_in_group(DOCTOR_GROUP)
	return true


# --------------------------------------------------------------------------
# Bucle principal
# --------------------------------------------------------------------------

func _activate() -> void:
	if _agent == null:
		_agent = _resolve_agent()
	if _agent == null:
		push_warning("NpcBrain: no se encontró un NpcAgent.")
		return
	_agent_id = _agent.get_instance_id()
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
	_consult_cooldown_timer = maxf(_consult_cooldown_timer - delta, 0.0)
	match _state:
		State.IDLE:
			_tick_idle(delta)
		State.SEEK:
			_tick_seek(delta)
		State.TRAVEL:
			_tick_travel(delta)
		State.USE:
			_tick_use(delta)
		State.WAIT:
			_tick_wait(delta)


func _tick_needs(delta: float) -> void:
	for need in needs.keys():
		var growth := float(need_growth.get(need, 0.0))
		needs[need] = clampf(float(needs[need]) + growth * delta, 0.0, 1.0)


func _tick_idle(delta: float) -> void:
	_think_timer -= delta
	if _think_timer > 0.0:
		return
	_think_timer = maxf(think_interval, 0.05)

	# Un paciente prefiere sentarse en un consultorio activo antes que
	# descansar en cualquier silla.
	if _try_consult():
		return

	for need in _needs_by_urgency():
		var affordance_id: StringName = need_affordances.get(need, StringName())
		if affordance_id == StringName():
			continue
		if not can_use_affordance(affordance_id):
			continue

		# Si viene de fuera de la grilla, primero camina a la celda construida
		# mas cercana. Recien al llegar elige el mueble: la distancia no importa.
		if _is_outside_grid() and _has_free_candidate(affordance_id):
			if _walk_to_grid_gateway():
				_begin_seek()
				return

		var candidate := SmartObjectRegistry.claim_best(
			affordance_id, _agent.global_position, search_radius, _agent_id,
			Callable(self, "_skip_for_need")
		)
		if candidate.is_empty():
			# Esa necesidad no tiene un objeto libre: probar la siguiente.
			continue
		_begin(candidate)
		return


## Intenta reservar una silla de un consultorio activo. La reserva se hace acá
## para que dos pacientes no elijan el mismo asiento.
## Intenta reservar una silla de un consultorio activo. La reserva se hace acá
## para que dos pacientes no elijan el mismo asiento. Si el medico esta
## ocupado, busca un lugar en la sala de espera.
func _try_consult() -> bool:
	if not consult_enabled or _agent == null:
		return false
	if _agent.is_in_group(DOCTOR_GROUP):
		return false
	if _consult_cooldown_timer > 0.0:
		return false
	var room := Consult.find_active_room(_agent, search_radius)
	if room.is_empty():
		return false
	var candidate := Consult.find_active_seat(_agent, search_radius, true)
	if not candidate.is_empty():
		_consult_active = true
		_begin(candidate)
		return true
	# El medico esta ocupado: esperar turno en la zona de espera.
	var wait := Consult.find_waiting_spot(_agent, room, true)
	if wait.is_empty():
		return false
	_begin_wait(wait)
	return true


## El NPC espera turno. Si hay silla libre se sienta; si no, va a un punto de
## la zona de espera y espera de pie.
func _begin_wait(spot: Dictionary) -> void:
	_waiting_for_consult = true
	_wait_check_timer = Consult.WAITING_CHECK_INTERVAL
	_wait_seated = bool(spot.get("seated", false))
	_wait_point = spot.get("point", _agent.global_position)
	if _wait_seated:
		_duration_override = Consult.WAITING_DURATION
		_consult_active = false
		_start_target(spot["object"], spot["affordance"], int(spot["slot"]))
	else:
		_state = State.WAIT
		_agent.set_frozen(false)
		_agent.move_to(_wait_point)


## Espera de pie: reintenta la consulta cada segundo.
func _tick_wait(delta: float) -> void:
	_wait_check_timer -= delta
	if _wait_check_timer > 0.0:
		return
	_wait_check_timer = Consult.WAITING_CHECK_INTERVAL
	var room := Consult.find_active_room(_agent, search_radius)
	if room.is_empty():
		_stop_waiting()
		return
	var seat := Consult.find_active_seat(_agent, search_radius, true)
	if not seat.is_empty():
		_stop_waiting()
		_consult_active = true
		_begin(seat)
		return
	# Se libero una silla en la sala de espera: sentarse.
	var waiting := Consult.find_waiting_spot(_agent, room, true)
	if not waiting.is_empty() and bool(waiting.get("seated", false)):
		_stop_waiting()
		_begin_wait(waiting)


## Espera sentado: se llama desde `_tick_use` para poder cortar el turno en
## cuanto se libera una silla de consultorio.
func _try_consult_from_wait() -> bool:
	var room := Consult.find_active_room(_agent, search_radius)
	if room.is_empty():
		_stop_waiting()
		return true
	var seat := Consult.find_active_seat(_agent, search_radius, true)
	if seat.is_empty():
		return false
	_stop_waiting()
	_consult_active = true
	_begin(seat)
	return true


func _stop_waiting() -> void:
	_waiting_for_consult = false
	_wait_seated = false
	_wait_point = Vector3.ZERO
	if _state == State.USE:
		_abort()
	else:
		if _agent != null:
			_agent.stop()
		_state = State.IDLE
		_think_timer = 0.5


## Los NPCs normales no eligen el Escritorio de trabajo ni las sillas de la
## sala de espera al azar. Esas sillas solo se usan para consultar o esperar.
func _skip_for_need(obj) -> bool:
	if _agent != null and _agent.is_in_group(DOCTOR_GROUP):
		return false
	return Consult.is_work_desk(obj) or Consult.is_in_waiting_zone(obj)


## El NPC esta parado fuera de las celdas construidas.
func _is_outside_grid() -> bool:
	var controller := BuildController.get_active()
	if controller == null or controller.grid == null:
		return false
	return not controller.has_floor_at_world(_agent.global_position)


## Hay algun SmartObject libre con esa affordance (sin reservarlo).
func _has_free_candidate(affordance_id: StringName) -> bool:
	if not can_use_affordance(affordance_id):
		return false
	return not SmartObjectRegistry.find_candidates(
		affordance_id, _agent.global_position, search_radius, _agent_id,
		Callable(self, "_skip_for_need")
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
	_duration_override = float(candidate.get("duration", -1.0))
	_start_target(candidate["object"], candidate["affordance"], int(candidate["slot"]))


## Inicia una interaccion cuyo slot ya reservo otro selector (por ejemplo el
## FSM de ruta para una consulta). Devuelve false si los datos no sirven.
func begin_reserved(
	object: Node,
	affordance: AffordanceDef,
	slot: int,
	duration: float = -1.0,
	is_consult: bool = false
) -> bool:
	if object == null or not is_instance_valid(object) \
			or affordance == null or slot < 0:
		return false
	if not enabled:
		set_enabled(true)
	_consult_active = is_consult
	_duration_override = duration
	_start_target(object, affordance, slot)
	return true


func _start_target(object: Node, affordance: AffordanceDef, slot: int) -> void:
	_object = object
	_affordance = affordance
	_slot = slot
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

	# Si esta esperando sentado, revisar si ya se libero una silla de consulta.
	if _waiting_for_consult:
		_wait_check_timer -= delta
		if _wait_check_timer <= 0.0:
			_wait_check_timer = Consult.WAITING_CHECK_INTERVAL
			if _try_consult_from_wait():
				return

	# Secuencia animada: la duración empieza a contar cuando arranca el loop.
	if _anim_active:
		if not _anim_looped or _exit_requested:
			return
		if _interaction_duration() < 0.0:
			return
		_use_timer -= delta
		if _use_timer <= 0.0:
			_exit_requested = true
			if _anim_manager != null:
				_anim_manager.request_exit()
		return

	# Duración negativa: el NPC se queda hasta que algo lo interrumpa.
	if _interaction_duration() < 0.0:
		return
	if _use_timer > 0.0:
		_use_timer -= delta
		if _use_timer > 0.0:
			return
	_finish()


## Duracion efectiva de la interaccion actual. La consulta usa una duracion
## propia mas larga sin modificar el recurso compartido de `sit`.
func _interaction_duration() -> float:
	if _duration_override >= 0.0:
		return _duration_override
	if _affordance == null:
		return 0.0
	return _affordance.duration


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
	_use_timer = _interaction_duration()
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
	_use_timer = _interaction_duration()


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
	var was_consult := _consult_active

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
	if was_consult:
		_consult_cooldown_timer = maxf(consult_cooldown, 0.0)

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
	if _consult_active:
		_consult_cooldown_timer = maxf(consult_cooldown, 0.0)
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
	_duration_override = -1.0
	_consult_active = false
	_waiting_for_consult = false
	_wait_check_timer = 0.0
	_wait_point = Vector3.ZERO
	_wait_seated = false


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
