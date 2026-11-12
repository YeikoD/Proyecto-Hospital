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

enum State { IDLE, TRAVEL, USE_SMART_OBJECT, WAIT, DONE }

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
var _trips := 0


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
	match _state:
		State.TRAVEL:
			_tick_travel(delta)
		State.USE_SMART_OBJECT:
			_tick_smart_object(delta)
		State.WAIT:
			_tick_wait(delta)


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
	if _brain == null or _smart_object_attempted or smart_object_chance <= 0.0:
		return false
	if affordance == StringName():
		return false

	var candidates := SmartObjectRegistry.find_candidates(
		affordance, _agent.global_position, smart_object_radius
	)
	if candidates.is_empty():
		return false

	# Solo se hace una tirada por NPC: al llegar a la primera zona con objetos,
	# algunos deciden usarlo y otros siguen de largo.
	_smart_object_attempted = true
	if randf() >= clampf(smart_object_chance, 0.0, 1.0):
		return false

	_start_smart_object()
	return true


func _start_smart_object() -> void:
	_state = State.USE_SMART_OBJECT
	_smart_timer = maxf(smart_object_timeout, 1.0)
	_agent.stop()
	_agent.set_frozen(false)

	_brain.needs = {"rest": 1.0}
	_brain.need_growth = {"rest": 0.0}
	_brain.need_affordances = {"rest": affordance}
	_brain.need_threshold = 0.5
	_brain.search_radius = smart_object_radius
	_brain.set_enabled(true)
	if debug:
		print("[NpcRouteFSM] %s decide usar un SmartObject" % _agent.name)


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
	_state = State.TRAVEL
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
		# Cada tramo vuelve a tirar el dado para el desvio a SmartObjects.
		_smart_object_attempted = false
		_begin_travel(not _to_target)
	else:
		_finish_route()


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
