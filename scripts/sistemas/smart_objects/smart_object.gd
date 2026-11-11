class_name SmartObject
extends BuildPiece

## Objeto interactivo colocado en el mundo.
##
## Declara acciones ("affordances") mediante `definition` y expone slots como
## Marker3D hijos llamados `Slot_0`, `Slot_1`, ... La IA reserva un slot, camina
## hasta el punto de uso, interactúa y lo libera.
##
## Regla del sistema: el objeto declara, la IA decide. El objeto nunca mueve al
## NPC; solo presta el slot y lleva el estado de ocupación.

signal slot_reserved(slot: int, agent_id: int)
signal slot_released(slot: int, agent_id: int)
signal used(agent_id: int, affordance_id: StringName)

enum SlotState { FREE, RESERVED, OCCUPIED }

## Definición de interacción. Puede venir del BuildItem al colocar el objeto.
@export var definition: SmartObjectDef

## Distancia usada para calcular el punto de aproximación cuando el prefab no
## trae un Marker3D `Approach_<slot>`.
@export var fallback_approach_distance := 0.8

var _slots: Array[Marker3D] = []
var _states: Array[int] = []
var _owners: Array[int] = []
var _affordance_ids: Array[StringName] = []


func _ready() -> void:
	_collect_slots()
	_ensure_fallback_slot()
	_reset_slots()
	add_to_group("smart_objects")
	SmartObjectRegistry.register(self)


func _exit_tree() -> void:
	SmartObjectRegistry.unregister(self)


# --------------------------------------------------------------------------
# Consulta
# --------------------------------------------------------------------------

func get_slot_count() -> int:
	return _slots.size()


func get_affordance(affordance_id: StringName) -> AffordanceDef:
	if definition == null:
		return null
	return definition.get_affordance(affordance_id)


func has_affordance(affordance_id: StringName) -> bool:
	return get_affordance(affordance_id) != null


## Primer slot libre compatible con la affordance, o -1.
func find_free_slot(affordance_id: StringName, _agent_id: int = -1) -> int:
	var affordance := get_affordance(affordance_id)
	if affordance == null:
		return -1
	for i in _slots.size():
		if _states[i] != SlotState.FREE:
			continue
		if not _slot_accepts(i, affordance):
			continue
		return i
	return -1


func has_free_slot(affordance_id: StringName) -> bool:
	return find_free_slot(affordance_id) >= 0


func get_slot_state(slot: int) -> int:
	if not _valid_slot(slot):
		return SlotState.FREE
	return _states[slot]


func get_slot_owner(slot: int) -> int:
	if not _valid_slot(slot):
		return -1
	return _owners[slot]


func is_slot_free(slot: int) -> bool:
	return get_slot_state(slot) == SlotState.FREE


func is_slot_occupied(slot: int) -> bool:
	return get_slot_state(slot) == SlotState.OCCUPIED


# --------------------------------------------------------------------------
# Reservas
# --------------------------------------------------------------------------

## Reserva un slot para un agente. Devuelve el índice o -1 si no hay lugar.
## Es atómico: si dos agentes piden a la vez, solo uno obtiene el slot.
func reserve(affordance_id: StringName, agent_id: int) -> int:
	var slot := find_free_slot(affordance_id, agent_id)
	if slot < 0:
		return -1
	_states[slot] = SlotState.RESERVED
	_owners[slot] = agent_id
	_affordance_ids[slot] = affordance_id
	slot_reserved.emit(slot, agent_id)
	return slot


## Marca el slot como en uso (el NPC llegó). Solo el dueño puede ocuparlo.
func occupy(slot: int, agent_id: int) -> void:
	if not _valid_slot(slot):
		return
	if _states[slot] != SlotState.RESERVED or _owners[slot] != agent_id:
		return
	_states[slot] = SlotState.OCCUPIED
	used.emit(agent_id, _affordance_ids[slot])


## Libera el slot. Solo el dueño de la reserva puede liberarlo.
func release(slot: int, agent_id: int) -> void:
	if not _valid_slot(slot):
		return
	if _owners[slot] != agent_id:
		return
	_states[slot] = SlotState.FREE
	_owners[slot] = -1
	_affordance_ids[slot] = StringName()
	slot_released.emit(slot, agent_id)


## Libera todos los slots que pertenezcan a un agente.
func release_agent(agent_id: int) -> void:
	for i in _states.size():
		if _owners[i] == agent_id:
			release(i, agent_id)


## Libera todo (al borrar el mueble o reiniciar la simulación).
func release_all() -> void:
	for i in _states.size():
		if _states[i] == SlotState.FREE:
			continue
		var owner_id := _owners[i]
		_states[i] = SlotState.FREE
		_owners[i] = -1
		_affordance_ids[i] = StringName()
		slot_released.emit(i, owner_id)


# --------------------------------------------------------------------------
# Puntos de uso
# --------------------------------------------------------------------------

func get_use_transform(slot: int) -> Transform3D:
	if not _valid_slot(slot):
		return global_transform
	return _slots[slot].global_transform


func get_use_position(slot: int) -> Vector3:
	if not _valid_slot(slot):
		return global_position
	return _slots[slot].global_position


## Punto exterior al que el NPC debe caminar antes de usar el slot.
## El NavMesh lo ajusta igualmente a la superficie caminable más cercana.
func get_approach_position(slot: int) -> Vector3:
	if not _valid_slot(slot):
		return global_position

	var approach := get_node_or_null("Approach_%d" % slot) as Node3D
	if approach != null:
		return approach.global_position

	var marker := _slots[slot]
	# En Godot el frente local es -Z: alejarse del objeto es restar basis.z.
	return marker.global_position - marker.global_transform.basis.z * fallback_approach_distance


## Transform de alineación para el NPC (POI): posición y hacia dónde mira.
##
## El prefab puede declarar un Marker3D `POI_<slot>`. Si no existe se usa el
## slot, bajado al nivel del suelo, con su misma orientación.
func get_poi_transform(slot: int) -> Transform3D:
	if not _valid_slot(slot):
		return global_transform

	var poi := get_node_or_null("POI_%d" % slot) as Node3D
	if poi != null:
		return poi.global_transform

	var result := _slots[slot].global_transform
	result.origin.y = global_position.y
	return result


## Transform al que vuelve el NPC al terminar (o abortar) la interacción.
## Usa `Approach_<slot>` si existe; si no, se separa del POI sobre su frente.
func get_approach_transform(slot: int) -> Transform3D:
	if not _valid_slot(slot):
		return global_transform

	var approach := get_node_or_null("Approach_%d" % slot) as Node3D
	if approach != null:
		return approach.global_transform

	var result := get_poi_transform(slot)
	result.origin -= result.basis.z.normalized() * fallback_approach_distance
	return result


# --------------------------------------------------------------------------
# Interno
# --------------------------------------------------------------------------

func _collect_slots() -> void:
	_slots.clear()
	for child in get_children():
		if child is Marker3D and String(child.name).begins_with("Slot"):
			_slots.append(child as Marker3D)
	_slots.sort_custom(func(a: Marker3D, b: Marker3D) -> bool:
		return String(a.name) < String(b.name)
	)


## Un objeto sin slots igual puede usarse: crea uno implícito en el origen.
func _ensure_fallback_slot() -> void:
	if not _slots.is_empty():
		return
	var fallback := Marker3D.new()
	fallback.name = "Slot_0"
	add_child(fallback)
	_slots.append(fallback)


func _reset_slots() -> void:
	_states.clear()
	_owners.clear()
	_affordance_ids.clear()
	for i in _slots.size():
		_states.append(SlotState.FREE)
		_owners.append(-1)
		_affordance_ids.append(StringName())


func _valid_slot(slot: int) -> bool:
	return slot >= 0 and slot < _slots.size()


func _slot_tag(slot: int) -> StringName:
	return StringName(_slots[slot].get_meta("slot_tag", ""))


func _slot_accepts(slot: int, affordance: AffordanceDef) -> bool:
	if affordance.slot_tag == StringName():
		return true
	var tag := _slot_tag(slot)
	return tag == StringName() or tag == affordance.slot_tag
