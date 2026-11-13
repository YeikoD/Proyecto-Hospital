class_name SpecialObject
extends SmartObject

## Objeto interactivo formado por varias piezas colocadas.
##
## Conserva las piezas originales (modelos y colliders) pero expone un unico
## SmartObject: mientras el conjunto esta activo, los SmartObject individuales
## de las piezas se suspenden para que la IA no los elija por separado.
##
## El nodo no tiene geometria propia. Sus markers `Slot_*`, `POI_*` y
## `Approach_*` se copian de la pieza que aporta el punto de uso y de las piezas
## client (por ejemplo, las sillas de pacientes), de modo que las animaciones y
## el acercamiento del NPC siguen funcionando igual.

var special_def: SpecialObjectDef
var parts: Array[BuildPiece] = []

var _marker_origin := Vector3.ZERO


## Configura el objeto antes de agregarlo al arbol (los markers tienen que
## existir cuando corre `SmartObject._ready`).
func configure(
	def: SpecialObjectDef,
	base: BuildPiece,
	part: BuildPiece,
	clients: Array[BuildPiece] = []
) -> bool:
	if def == null or not def.is_valid() or base == null or part == null:
		return false
	special_def = def
	definition = def.smart_object
	parts.clear()
	parts.append(base)
	parts.append(part)
	for client in clients:
		if client != null and not parts.has(client):
			parts.append(client)
	_copy_use_markers(def, base, part, clients)
	return true


func get_parts() -> Array[BuildPiece]:
	return parts.duplicate()


func has_part(piece: BuildPiece) -> bool:
	return parts.has(piece)


func get_special_id() -> StringName:
	return special_def.id if special_def != null else &""


func get_display_name() -> String:
	if special_def != null and special_def.display_name != "":
		return special_def.display_name
	return String(name)


## Origen en el que se deben apoyar los markers copiados. El controlador usa
## este valor para ubicar el nodo del objeto especial.
func get_marker_origin() -> Vector3:
	return _marker_origin


func _copy_use_markers(
	def: SpecialObjectDef,
	base: BuildPiece,
	part: BuildPiece,
	clients: Array[BuildPiece]
) -> void:
	var source: BuildPiece = part if def.slot_source == "part" else base
	var origin := source.global_position
	_marker_origin = origin

	var next_slot := 0
	next_slot = _copy_source_slots(
		source, def.slot_index, def.part_slot_tag, origin, next_slot
	)
	for client in clients:
		if client == null:
			continue
		if client is SmartObject:
			var smart := client as SmartObject
			for i in smart.get_slot_count():
				next_slot = _copy_source_slots(
					client, i, def.client_slot_tag, origin, next_slot
				)
		else:
			next_slot = _copy_source_slots(
				client, -1, def.client_slot_tag, origin, next_slot
			)


func _copy_source_slots(
	source: BuildPiece,
	source_slot: int,
	tag: StringName,
	origin: Vector3,
	first_index: int
) -> int:
	var slot_tf := source.global_transform
	var poi_tf := source.global_transform
	var approach_tf := source.global_transform
	if source_slot >= 0 and source is SmartObject:
		var smart := source as SmartObject
		var slot := clampi(source_slot, 0, maxi(smart.get_slot_count() - 1, 0))
		slot_tf = smart.get_use_transform(slot)
		poi_tf = smart.get_poi_transform(slot)
		approach_tf = smart.get_approach_transform(slot)

	var index := first_index
	_add_marker("Slot_%d" % index, slot_tf, origin, tag)
	_add_marker("POI_%d" % index, poi_tf, origin, tag)
	_add_marker("Approach_%d" % index, approach_tf, origin, tag)
	return index + 1


func _add_marker(
	marker_name: String, world_tf: Transform3D, origin: Vector3, tag: StringName
) -> void:
	var marker := Marker3D.new()
	marker.name = marker_name
	marker.transform = Transform3D(world_tf.basis, world_tf.origin - origin)
	if tag != StringName():
		marker.set_meta("slot_tag", tag)
	add_child(marker)


## Un conjunto puede reservar ciertas affordances a un grupo (por ejemplo, la
## silla del operador del Escritorio de trabajo al medico). Si la affordance no
## esta en `exclusive_affordances`, el resto de los NPCs puede usarla.
func allows_agent(agent_id: int, affordance_id: StringName = &"") -> bool:
	if special_def == null or special_def.exclusive_group == StringName():
		return true
	var exclusive := special_def.exclusive_affordances
	if not exclusive.is_empty() and affordance_id != StringName() \
			and not exclusive.has(affordance_id):
		return true
	if agent_id <= 0:
		return true
	var agent := instance_from_id(agent_id)
	if agent == null or not is_instance_valid(agent):
		return true
	if agent.is_in_group(special_def.exclusive_group):
		return true
	var parent: Node = agent.get_parent()
	return parent != null and parent.is_in_group(special_def.exclusive_group)
