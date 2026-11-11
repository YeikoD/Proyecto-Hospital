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

signal interaction_started(object: Node, affordance: AffordanceDef)
signal interaction_finished(object: Node, affordance: AffordanceDef)
signal interaction_aborted(object: Node)

@export var enabled := true
@export var agent_path: NodePath
@export var search_radius := 25.0
@export var think_interval := 0.5

@export_group("Necesidades")
## necesidad -> valor actual (0..1). Cuanto más alto, más urgente.
@export var needs: Dictionary = {"rest": 0.0}
## necesidad -> cuánto crece por segundo.
@export var need_growth: Dictionary = {"rest": 0.01}
## necesidad -> affordance que la satisface.
@export var need_affordances: Dictionary = {"rest": &"sit"}
## Por debajo de este valor la necesidad no dispara una búsqueda.
@export var need_threshold := 0.6
## Tiempo máximo para llegar al objeto antes de abortar y liberar el slot.
@export var travel_timeout := 20.0

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

	var need := _most_urgent_need()
	if need == "":
		return

	var affordance_id: StringName = need_affordances.get(need, StringName())
	if affordance_id == StringName():
		return

	var candidate := SmartObjectRegistry.claim_best(
		affordance_id, _agent.global_position, search_radius, _agent_id
	)
	if candidate.is_empty():
		return
	_begin(candidate)


func _most_urgent_need() -> String:
	var best := ""
	var best_value := need_threshold
	for need in needs.keys():
		var value := float(needs[need])
		if value >= best_value:
			best_value = value
			best = String(need)
	return best


func _begin(candidate: Dictionary) -> void:
	_object = candidate["object"]
	_affordance = candidate["affordance"]
	_slot = int(candidate["slot"])
	_state = State.TRAVEL
	_travel_timer = maxf(travel_timeout, 1.0)

	_agent.set_frozen(false)
	_agent.move_to(_object.get_use_position(_slot))
	if debug:
		print("[NpcBrain] %s -> %s" % [_agent.name, _affordance.id])


func _tick_travel(delta: float) -> void:
	if not _object_alive():
		_abort()
		return
	_travel_timer -= delta
	if _travel_timer <= 0.0:
		_abort()


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
	if _state != State.TRAVEL or not _object_alive():
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
