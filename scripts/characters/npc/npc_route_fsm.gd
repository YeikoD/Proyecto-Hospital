class_name NpcRouteFSM
extends Node

## FSM simple + selector de comportamiento para NPCs de ruta.
##
## La ruta es fija: el NPC aparece en el spawner A y camina hasta el nodo
## destino B. Mientras camina, un selector (el "arbol de comportamiento")
## decide si conviene desviarse a usar un SmartObject:
##
##   1. Si todavia no lo intento, hay un SmartObject con slot libre cerca y la
##      tirada aleatoria acierta -> USE_SMART_OBJECT (delegado a NpcBrain).
##   2. Si ya llego al destino -> WAIT.
##   3. En cualquier otro caso -> seguir caminando.
##
## La ruta puede ser de ida y vuelta: con `loop_route` el NPC alterna entre A y
## B (`A -> B -> A -> B ...`) hasta completar `max_trips` tramos, y recien ahi
## desaparece. No reemplaza a NpcBrain: lo usa como accion para la parte de
## SmartObjects.

enum State { IDLE, TRAVEL, USE_SMART_OBJECT, WAIT, WAIT_CONSULT, DONE }

const Consult := preload("res://scripts/characters/npc/npc_consult.gd")

signal route_finished

## Nodo destino de la ruta (normalmente otro NpcSpawner).
@export var target_node: Node3D
## Spawner que genero al NPC (para avisar cuando desaparece).
@export var source_spawner: NpcSpawner
## Si es true, al llegar a un extremo vuelve al otro (ida y vuelta).
@export var loop_route := false
## Cantidad de tramos antes de desaparecer. A->B cuenta 1, B->A cuenta 2.
## `0` = sin limite (solo tiene efecto con `loop_route = true`).
@export_range(0, 50) var max_trips := 2
@export var wait_at_target := 2.0
## Probabilidad de desviarse a usar un SmartObject al pasar cerca del primero.
@export_range(0.0, 1.0, 0.01) var smart_object_chance := 0.25
## Radio de busqueda de SmartObjects. 0 = sin limite.
@export var smart_object_radius := 12.0
## Tiempo maximo sin empezar una interaccion antes de seguir la ruta.
@export var smart_object_timeout := 15.0
## Cada cuanto se reevalua el selector mientras camina.
@export var think_interval := 1.5
## Radio de busqueda de consultorios activos. 0 = sin limite.
@export var consult_radius := 0.0
## Probabilidad de que ESTE NPC acepte consultar alguna vez. El resto queda
## como caminante A<->B y se dedica a spawnear/despawnear.
@export_range(0.0, 1.0, 0.01) var consult_willingness := 0.6
## Probabilidad de consultar en cada tramo (se tira una sola vez por tramo).
@export_range(0.0, 1.0, 0.01) var consult_chance := 0.6
## Tiempo que el NPC no vuelve a intentar consultar despues de una consulta.
@export var consult_cooldown := 25.0
## Cuanto tiempo se queda el paciente sentado en el consultorio.
@export var consult_duration := 20.0
## Affordances que puede elegir al desviarse. Se queda con la mejor puntuacion.
## `work` queda fuera para NPCs normales por `can_use_affordance`.
@export var affordances: Array[StringName] = [&"sit", &"work"]
## Affordance de respaldo si `affordances` esta vacio.
@export var affordance: StringName = &"sit"
@export var debug := false

var _agent: NpcAgent
var _brain: NpcBrain
var _state: int = State.IDLE
var _to_target := true
var _origin := Vector3.ZERO
var _think_timer := 0.0
var _wait_timer := 0.0
var _smart_timer := 0.0
var _smart_object_attempted := false
var _chosen_affordance: StringName = &""
var _trips := 0
var _wait_check_timer := 0.0
var _wait_seated := false
var _wait_point := Vector3.ZERO
var _consult_cooldown := 0.0
var _consult_willing := true
var _consult_tried_this_leg := false


func _ready() -> void:
	_agent = get_parent() as NpcAgent
	if _agent == null:
		push_warning("NpcRouteFSM: el padre no es un NpcAgent.")
		set_process(false)
		return
	if target_node == null:
		push_warning("NpcRouteFSM: falta target_node.")
		set_process(false)
		return

	_brain = _agent.get_node_or_null("NpcBrain") as NpcBrain
	_origin = _agent.global_position
	# Un porcentaje de NPCs nunca consulta: quedan como caminantes A<->B.
	_consult_willing = randf() < clampf(consult_willingness, 0.0, 1.0)
	_agent.wander = false

	if not _agent.arrived.is_connected(_on_arrived):
		_agent.arrived.connect(_on_arrived)
	if _brain != null:
		_brain.set_enabled(false)
		if not _brain.interaction_finished.is_connected(_on_brain_interaction_finished):
			_brain.interaction_finished.connect(_on_brain_interaction_finished)
		if not _brain.interaction_aborted.is_connected(_on_brain_interaction_aborted):
			_brain.interaction_aborted.connect(_on_brain_interaction_aborted)

	_begin_travel(true)


# --------------------------------------------------------------------------
# API / consulta
# --------------------------------------------------------------------------

func get_state() -> int:
	return _state


func get_current_target() -> Vector3:
	return _target_point()


# --------------------------------------------------------------------------
# Bucle
# --------------------------------------------------------------------------

func _process(delta: float) -> void:
	_consult_cooldown = maxf(_consult_cooldown - delta, 0.0)
	match _state:
		State.TRAVEL:
			_tick_travel(delta)
		State.USE_SMART_OBJECT:
			_tick_smart_object(delta)
		State.WAIT:
			_tick_wait(delta)
		State.WAIT_CONSULT:
			_tick_wait_consult(delta)


func _begin_travel(to_target: bool) -> void:
	if _agent == null:
		return
	_to_target = to_target
	_state = State.TRAVEL
	_think_timer = 0.0
	_agent.set_frozen(false)
	_agent.wander = false
	_agent.move_to(_target_point())
	if debug:
		print("[NpcRouteFSM] %s -> %s" % [
			_agent.name, "B" if to_target else "A"
		])


func _target_point() -> Vector3:
	if _to_target and target_node != null and is_instance_valid(target_node):
		return _point_of(target_node)
	return _origin


func _point_of(node: Node3D) -> Vector3:
	if not is_instance_valid(node):
		return _origin
	if node is NpcSpawner:
		return (node as NpcSpawner).get_spawn_point()
	return node.global_position


# --------------------------------------------------------------------------
# Selector de comportamiento durante el viaje
# --------------------------------------------------------------------------

func _tick_travel(delta: float) -> void:
	_think_timer -= delta
	if _think_timer > 0.0:
		return
	_think_timer = maxf(think_interval, 0.1)

	# Selector: primero intentar el desvio a un SmartObject.
	if _try_start_smart_object():
		return
	# Si no, el viaje sigue y la llegada se maneja con la senal `arrived`.


func _try_start_smart_object() -> bool:
	if _brain == null or _smart_object_attempted:
		return false

	# 1) Decision aleatoria: una sola tirada por tramo. Si falla, este NPC sigue
	# caminando A<->B hasta el proximo tramo.
	if _consult_willing and not _consult_tried_this_leg \
			and _consult_cooldown <= 0.0:
		_consult_tried_this_leg = true
		if randf() < clampf(consult_chance, 0.0, 1.0):
			var room := Consult.find_active_room(_agent, consult_radius)
			if not room.is_empty():
				_smart_object_attempted = true
				var seat := Consult.find_active_seat(_agent, consult_radius, true)
				if not seat.is_empty():
					_chosen_affordance = StringName(seat["affordance"].id)
					_start_consult(seat)
					return true
				var waiting := Consult.find_waiting_spot(_agent, room, true)
				if not waiting.is_empty():
					_start_wait(waiting)
					return true
		# Si falla la tirada o no hay consultorio, el NPC sigue caminando o
		# hace el desvio aleatorio normal.

	if smart_object_chance <= 0.0:
		return false
	var ids: Array[StringName] = []
	for id in affordances:
		ids.append(id)
	if ids.is_empty() and affordance != StringName():
		ids.append(affordance)
	if ids.is_empty():
		return false

	var best: Dictionary = {}
	var best_id: StringName = &""
	for id in ids:
		if id == StringName():
			continue
		# `work` es exclusiva del medico: un NPC de ruta nunca ocupa la silla
		# del operador.
		if not _brain.can_use_affordance(id):
			continue
		var candidates := SmartObjectRegistry.find_candidates(
			id, _agent.global_position, smart_object_radius,
			_agent.get_instance_id(), Callable(self, "_skip_smart_object")
		)
		if candidates.is_empty():
			continue
		var candidate: Dictionary = candidates[0]
		if best.is_empty() or float(candidate["score"]) > float(best["score"]):
			best = candidate
			best_id = id
	if best.is_empty():
		return false

	# Solo se hace una tirada por NPC: al llegar a la primera zona con objetos,
	# algunos deciden usarlo y otros siguen de largo.
	_smart_object_attempted = true
	if randf() >= clampf(smart_object_chance, 0.0, 1.0):
		return false

	_chosen_affordance = best_id
	_start_smart_object()
	return true


## El desvio aleatorio no usa las sillas del escritorio ni las de la sala de
## espera: esas solo se usan para consultar o esperar turno. El medico si puede
## usar `work`.
func _skip_smart_object(obj) -> bool:
	if _agent != null and _agent.is_in_group(Consult.DOCTOR_GROUP):
		return false
	return Consult.is_work_desk(obj) or Consult.is_in_waiting_zone(obj)


## El paciente ya tiene una silla reservada en un consultorio activo.
func _start_consult(candidate: Dictionary) -> void:
	_state = State.USE_SMART_OBJECT
	_smart_timer = maxf(smart_object_timeout, 1.0)
	_agent.stop()
	_agent.set_frozen(false)
	_brain.set_enabled(true)
	if not _brain.begin_reserved(
			candidate["object"], candidate["affordance"], int(candidate["slot"]),
			consult_duration, true
	):
		if candidate["object"] != null and is_instance_valid(candidate["object"]):
			candidate["object"].release(
				int(candidate["slot"]), _agent.get_instance_id())
		_finish_smart_object(false)
		return
	if debug:
		print("[NpcRouteFSM] %s va al consultorio %s" % [
			_agent.name, candidate.get("zone_id", "?")
		])


func _start_smart_object() -> void:
	_state = State.USE_SMART_OBJECT
	_smart_timer = maxf(smart_object_timeout, 1.0)
	_agent.stop()
	_agent.set_frozen(false)

	var chosen := _chosen_affordance
	if chosen == StringName():
		chosen = affordance
	var need_key := "work" if chosen == &"work" else "rest"
	_brain.needs = {need_key: 1.0}
	_brain.need_growth = {need_key: 0.0}
	_brain.need_affordances = {need_key: chosen}
	_brain.need_threshold = 0.5
	_brain.search_radius = smart_object_radius
	_brain.set_enabled(true)
	if debug:
		print("[NpcRouteFSM] %s decide usar un SmartObject (%s)" % [
			_agent.name, chosen
		])


func _tick_smart_object(delta: float) -> void:
	if _brain == null:
		_finish_smart_object(false)
		return
	# Mientras el cerebro camina o interactua, el tiempo no corre: solo cuenta
	# el estancamiento (por ejemplo, si no encuentra un slot libre).
	if _brain.get_state() != NpcBrain.State.IDLE:
		_smart_timer = maxf(smart_object_timeout, 1.0)
		return
	_smart_timer -= delta
	if _smart_timer <= 0.0:
		_finish_smart_object(false)


# --------------------------------------------------------------------------
# Brain callbacks
# --------------------------------------------------------------------------

func _on_brain_interaction_finished(_object: Node, _affordance: AffordanceDef) -> void:
	if _state != State.USE_SMART_OBJECT:
		return
	# El brain todavia esta dentro de su `_finish`; esperar un frame antes de
	# apagarlo evita reentrar en su abort.
	_finish_smart_object.call_deferred(true)


func _on_brain_interaction_aborted(_object: Node) -> void:
	if _state != State.USE_SMART_OBJECT:
		return
	_finish_smart_object.call_deferred(false)


func _finish_smart_object(used: bool) -> void:
	if _brain != null:
		_brain.set_enabled(false)
	if used:
		_consult_cooldown = maxf(consult_cooldown, 0.0)
	_state = State.TRAVEL
	_chosen_affordance = &""
	_think_timer = maxf(think_interval, 0.1)
	if debug:
		print("[NpcRouteFSM] %s %s SmartObject" % [
			_agent.name, "termino" if used else "cancelo"
		])
	_begin_travel(_to_target)


# --------------------------------------------------------------------------
# Destino / fin de ruta
# --------------------------------------------------------------------------

func _on_arrived() -> void:
	if _state != State.TRAVEL:
		return
	if _brain != null and _brain.enabled:
		return

	var target := _target_point()
	if _agent.global_position.distance_to(target) > 1.0:
		# El NavMesh pudo terminar en otro punto: reintentar el ultimo tramo.
		_agent.move_to(target)
		return

	_state = State.WAIT
	_trips += 1
	_wait_timer = maxf(wait_at_target, 0.0)
	if debug:
		print("[NpcRouteFSM] %s llego a %s" % [
			_agent.name, "B" if _to_target else "A"
		])


func _tick_wait(delta: float) -> void:
	_wait_timer -= delta
	if _wait_timer > 0.0:
		return
	if _should_continue_route():
		# Cada tramo vuelve a tirar el dado para consulta y desvio.
		_smart_object_attempted = false
		_consult_tried_this_leg = false
		_begin_travel(not _to_target)
	else:
		_finish_route()


## El medico esta ocupado: sentarse en la sala de espera o quedarse de pie si
## todas las sillas estan ocupadas. Mientras espera, reintenta la consulta.
func _start_wait(spot: Dictionary) -> void:
	if spot.is_empty():
		return
	_state = State.WAIT_CONSULT
	_wait_check_timer = 0.0
	_wait_seated = bool(spot.get("seated", false))
	_wait_point = spot.get("point", _agent.global_position)
	if _wait_seated:
		_agent.stop()
		_agent.set_frozen(false)
		_brain.set_enabled(true)
		if not _brain.begin_reserved(
				spot["object"], spot["affordance"], int(spot["slot"]),
				Consult.WAITING_DURATION, false
		):
			if spot["object"] != null and is_instance_valid(spot["object"]):
				spot["object"].release(
					int(spot["slot"]), _agent.get_instance_id())
			_brain.set_enabled(false)
			_wait_seated = false
			_agent.move_to(_wait_point)
	else:
		_agent.move_to(_wait_point)
	if debug:
		print("[NpcRouteFSM] %s espera turno (%s)" % [
			_agent.name, "sentado" if _wait_seated else "de pie"
		])


func _tick_wait_consult(delta: float) -> void:
	_wait_check_timer -= delta
	if _wait_check_timer > 0.0:
		return
	_wait_check_timer = maxf(Consult.WAITING_CHECK_INTERVAL, 0.5)

	var room := Consult.find_active_room(_agent, consult_radius)
	if room.is_empty():
		_finish_wait()
		return

	var seat := Consult.find_active_seat(_agent, consult_radius, true)
	if not seat.is_empty():
		if _wait_seated and _brain != null:
			_brain.set_enabled(false)
		_chosen_affordance = StringName(seat["affordance"].id)
		_start_consult(seat)
		return

	# La silla de espera se libero o termino su turno: volver a sentarse o
	# seguir esperando de pie.
	if _wait_seated and _brain != null \
			and _brain.get_state() == NpcBrain.State.IDLE:
		var wait := Consult.find_waiting_spot(_agent, room, true)
		if wait.is_empty():
			_finish_wait()
		else:
			_start_wait(wait)
	elif not _wait_seated:
		# Esperando de pie: si se libera una silla de espera, sentarse.
		var wait := Consult.find_waiting_spot(_agent, room, true)
		if not wait.is_empty() and bool(wait.get("seated", false)):
			_start_wait(wait)


func _finish_wait() -> void:
	if _brain != null and _brain.enabled:
		_brain.set_enabled(false)
	_state = State.TRAVEL
	_chosen_affordance = &""
	_wait_seated = false
	_begin_travel(_to_target)


func _should_continue_route() -> bool:
	if not loop_route:
		return false
	if max_trips <= 0:
		return true
	return _trips < max_trips


## Distancia al extremo de la ruta con la que se permite desaparecer.
const DESPAWN_DISTANCE := 1.5


func _finish_route() -> void:
	if _state == State.DONE:
		return
	# Solo desaparece en un extremo de la ruta (un POI). Si un rebake o un
	# camino incompleto lo dejo lejos, vuelve a intentar ese tramo en vez de
	# desaparecer en mitad del mapa.
	var end_point := _target_point()
	if is_instance_valid(_agent) \
			and _agent.global_position.distance_to(end_point) > DESPAWN_DISTANCE:
		_trips = maxi(_trips - 1, 0)
		_begin_travel(_to_target)
		return
	_state = State.DONE
	set_process(false)
	route_finished.emit()
	if source_spawner != null and is_instance_valid(source_spawner):
		source_spawner.npc_despawned.emit(_agent)
	if is_instance_valid(_agent):
		_agent.queue_free()
