class_name NpcSpawnCycle
extends Node

## Ciclo de vida de un NPC generado por `NpcSpawner`.
##
## Primera version: el NPC aparece, busca un SmartObject, lo usa una vez y
## vuelve a un spawner para desaparecer.
##
## Regla importante: **nunca desaparece en el camino**. Si no encuentra
## objetivo en `search_timeout`, igual vuelve caminando. Y si al volver se
## traba o termina lejos del spawner, reintenta el camino; la desaparicion solo
## ocurre al llegar (`_on_arrived`).
##
## Se agrega automaticamente como hijo del NPC desde `NpcSpawner.spawn_now()`.

enum State { SEEKING, RETURNING, DONE }

## Si no consigue usar un SmartObject en este tiempo, vuelve al spawner.
@export var search_timeout := 30.0
## Cada cuanto reintenta el camino si no llega (no desaparece por vencer).
@export var return_retry_delay := 3.0
## Distancia al spawner con la que se considera que llego.
@export var arrive_distance := 1.5

var _agent: NpcAgent
var _brain: NpcBrain
var _spawner: NpcSpawner
var _state: int = State.SEEKING
var _timer := 0.0


func _ready() -> void:
	_agent = get_parent() as NpcAgent
	_timer = maxf(search_timeout, 1.0)
	if _agent == null:
		push_warning("NpcSpawnCycle: el padre no es un NpcAgent.")
		return
	if not _agent.arrived.is_connected(_on_arrived):
		_agent.arrived.connect(_on_arrived)
	_brain = _agent.get_node_or_null("NpcBrain") as NpcBrain
	if _brain != null and not _brain.interaction_finished.is_connected(_on_interaction_finished):
		_brain.interaction_finished.connect(_on_interaction_finished)


func get_state() -> int:
	return _state


# --------------------------------------------------------------------------
# Bucle
# --------------------------------------------------------------------------

func _process(delta: float) -> void:
	if _state == State.DONE:
		return
	_timer -= delta
	if _timer > 0.0:
		return
	if _state == State.SEEKING:
		# Mientras camina a la grilla o al mueble, o mientras usa el objeto, el
		# tiempo de busqueda no corre: la distancia no debe hacerlo volver.
		if _brain != null:
			var brain_state := _brain.get_state()
			if _brain.is_interacting() \
					or brain_state == NpcBrain.State.SEEK \
					or brain_state == NpcBrain.State.TRAVEL:
				_timer = maxf(search_timeout, 1.0)
				return
		_begin_return()
	else:
		# No llego en el tiempo previsto: recalcula el camino. No desaparece.
		_retarget_spawner()


func _on_interaction_finished(_object: Node, _affordance: AffordanceDef) -> void:
	# Diferido: cuando llega la senal, NpcBrain todavia esta dentro de
	# `_finish()`. Esperamos a que termine de liberar el slot.
	_begin_return.call_deferred()


func _begin_return() -> void:
	if _state != State.SEEKING or not is_instance_valid(_agent):
		return
	_state = State.RETURNING

	if _brain != null:
		_brain.set_enabled(false)

	_spawner = NpcSpawner.pick_return_spawner(_agent.global_position)
	_walk_to_spawner()


## Pide camino al spawner actual y programa el siguiente reintento. Nunca
## elimina al NPC: eso solo pasa en `_on_arrived()`.
func _walk_to_spawner() -> void:
	if not is_instance_valid(_agent):
		return
	_timer = maxf(return_retry_delay, 0.5)
	if _spawner == null or not is_instance_valid(_spawner):
		# Sin spawner disponible (p. ej. los desactivaron): esperar y reintentar.
		_spawner = null
		return
	_agent.wander = false
	_agent.set_frozen(false)
	_agent.move_to(_spawner.get_spawn_point())


func _retarget_spawner() -> void:
	if not is_instance_valid(_agent):
		return
	var next := NpcSpawner.pick_return_spawner(_agent.global_position)
	if next != null:
		_spawner = next
	_walk_to_spawner()


func _on_arrived() -> void:
	if _state != State.RETURNING or not is_instance_valid(_agent):
		return
	if _spawner == null or not is_instance_valid(_spawner):
		_retarget_spawner()
		return

	# El camino puede terminar en otro punto (rebake, atajo): seguir intentando
	# hasta estar realmente en el spawner.
	var spawn_point := _spawner.get_spawn_point()
	if _agent.global_position.distance_to(spawn_point) > arrive_distance:
		_walk_to_spawner()
		return

	_despawn()


func _despawn() -> void:
	if _state == State.DONE:
		return
	_state = State.DONE
	set_process(false)

	if _spawner != null and is_instance_valid(_spawner):
		_spawner.npc_despawned.emit(_agent)
	if is_instance_valid(_agent):
		_agent.queue_free()
