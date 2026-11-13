class_name SmartObjectRegistry
extends RefCounted

## Índice global de SmartObjects.
##
## Es estático a propósito: no necesita autoload ni depender del árbol, así
## funciona igual en tests headless que en escenas cargadas en runtime.
## Cada SmartObject se registra en `_ready` y se da de baja en `_exit_tree`.
##
## La IA consulta aquí, nunca recorre la escena buscando muebles.

static var _objects: Array = []


static func register(obj) -> void:
	if obj == null:
		return
	if _objects.has(obj):
		return
	_objects.append(obj)


static func unregister(obj) -> void:
	_objects.erase(obj)


static func clear() -> void:
	_objects.clear()


static func get_count() -> int:
	return _objects.size()


static func get_objects() -> Array:
	return _objects.duplicate()


## Devuelve los objetos que ofrecen `affordance_id` y tienen un slot libre,
## ordenados por utilidad (peso base / distancia).
## `max_distance <= 0` significa sin limite de distancia.
## `skip` es un Callable opcional: si devuelve true para un objeto, se descarta.
static func find_candidates(
	affordance_id: StringName,
	from: Vector3,
	max_distance: float,
	agent_id: int = -1,
	skip: Callable = Callable()
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []

	for obj in _objects:
		if not is_instance_valid(obj):
			continue
		if skip.is_valid() and bool(skip.call(obj)):
			continue
		var affordance = obj.get_affordance(affordance_id)
		if affordance == null:
			continue
		if obj.find_free_slot(affordance_id, agent_id) < 0:
			continue
		if not obj.allows_agent(agent_id, affordance_id):
			continue
		var distance: float = obj.global_position.distance_to(from)
		if max_distance > 0.0 and distance > max_distance:
			continue
		result.append({
			"object": obj,
			"affordance": affordance,
			"slot": -1,
			"distance": distance,
			"score": float(affordance.base_score) / (1.0 + distance),
		})

	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["score"]) > float(b["score"])
	)
	return result


## Reserva atómicamente el mejor objeto disponible. Devuelve {} si no hay.
## Reservar antes de caminar evita que varios NPC vayan al mismo mueble.
static func claim_best(
	affordance_id: StringName,
	from: Vector3,
	max_distance: float,
	agent_id: int,
	skip: Callable = Callable()
) -> Dictionary:
	for candidate in find_candidates(
			affordance_id, from, max_distance, agent_id, skip):
		var obj = candidate["object"]
		var slot: int = obj.reserve(affordance_id, agent_id)
		if slot >= 0:
			candidate["slot"] = slot
			return candidate
	return {}


## Libera cualquier reserva que pertenezca a `agent_id`.
static func release_all(agent_id: int) -> void:
	for obj in _objects:
		if is_instance_valid(obj):
			obj.release_agent(agent_id)
