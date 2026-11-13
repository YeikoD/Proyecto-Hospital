class_name NpcConsult
extends RefCounted

## Busca sillas libres dentro de un consultorio activo.
##
## Un consultorio esta activo cuando:
## 1. hay una zona pintada con tipo `consult`;
## 2. un NPC del grupo `doctor_npcs` esta usando la affordance `work` de un
##    `work_desk` dentro de esa zona;
## 3. queda un slot `sit` libre dentro de la misma zona.
##
## El paciente reserva la silla antes de caminar, igual que el resto de la IA.

const DOCTOR_GROUP := &"doctor_npcs"
const CONSULT_ZONE := &"consult"
const SEAT_AFFORDANCE := &"sit"
const WORK_AFFORDANCE := &"work"
const WORK_DESK_ID := &"work_desk"
## Distancia al escritorio dentro de la cual el medico sigue "presente" aunque
## este en el hueco entre dos turnos (no en USE). Asi la sala de espera no se
## desactiva un instante y los pacientes no pierden el turno.
const DOCTOR_NEAR_DESK := 3.0

## Cuanto tiempo se queda el paciente sentado simulando la consulta.
const CONSULT_DURATION := 20.0
## Cuanto tiempo espera sentado en la sala de espera antes de reevaluar.
const WAITING_DURATION := 30.0
## Cada cuanto se reevalua si ya hay una silla de consultorio libre.
const WAITING_CHECK_INTERVAL := 1.0


## Devuelve el mejor asiento de un consultorio activo, o {} si no hay.
## Con `reserve = true` reserva el slot atomicamente antes de devolverlo.
static func find_active_seat(
	agent: NpcAgent,
	max_distance: float = 0.0,
	reserve: bool = false
) -> Dictionary:
	if agent == null or not is_instance_valid(agent):
		return {}
	if agent.is_in_group(DOCTOR_GROUP):
		return {}

	var controller := BuildController.get_active()
	if controller == null:
		return {}
	var tree := agent.get_tree()
	if tree == null:
		return {}

	var rooms := _active_rooms(controller, tree)
	if rooms.is_empty():
		return {}

	var agent_id := agent.get_instance_id()
	var candidates: Array[Dictionary] = []
	for obj in SmartObjectRegistry.get_objects():
		if obj == null or not is_instance_valid(obj):
			continue
		if not obj.has_affordance(SEAT_AFFORDANCE):
			continue
		if not obj.allows_agent(agent_id, SEAT_AFFORDANCE):
			continue
		var slot: int = obj.find_free_slot(SEAT_AFFORDANCE, agent_id)
		if slot < 0:
			continue
		var seat_pos: Vector3 = obj.get_use_position(slot)
		var zone_id: StringName = controller.get_zone_id_at_world(seat_pos)
		if not rooms.has(zone_id):
			continue
		var distance := agent.global_position.distance_to(seat_pos)
		if max_distance > 0.0 and distance > max_distance:
			continue
		candidates.append({
			"object": obj,
			"affordance": obj.get_affordance(SEAT_AFFORDANCE),
			"slot": slot,
			"distance": distance,
			"zone_id": zone_id,
			"duration": CONSULT_DURATION,
		})

	if candidates.is_empty():
		return {}
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["distance"]) < float(b["distance"])
	)
	if not reserve:
		return candidates[0]
	for candidate in candidates:
		var obj = candidate["object"]
		var slot: int = obj.reserve(SEAT_AFFORDANCE, agent_id)
		if slot >= 0:
			candidate["slot"] = slot
			return candidate
	return {}


## Consultorio activo mas cercano (doctor trabajando), aunque no tenga silla
## libre. Devuelve `{zone_id, desk, distance}` o {}.
static func find_active_room(
	agent: NpcAgent, max_distance: float = 0.0
) -> Dictionary:
	if agent == null or not is_instance_valid(agent):
		return {}
	if agent.is_in_group(DOCTOR_GROUP):
		return {}
	var controller := BuildController.get_active()
	if controller == null:
		return {}
	var tree := agent.get_tree()
	if tree == null:
		return {}

	var rooms := _active_rooms(controller, tree)
	var best: Dictionary = {}
	var best_distance := INF
	for zone_id in rooms.keys():
		var desk := rooms[zone_id] as Node3D
		if desk == null or not is_instance_valid(desk):
			continue
		var distance := agent.global_position.distance_to(desk.global_position)
		if max_distance > 0.0 and distance > max_distance:
			continue
		if distance < best_distance:
			best_distance = distance
			best = {"zone_id": zone_id, "desk": desk, "distance": distance}
	return best


## Lugar para esperar cuando el medico esta ocupado. Devuelve:
## - `{seated: true, object, affordance, slot, zone_id}` si hay silla libre;
## - `{seated: false, point, zone_id}` si la sala tiene sillas pero estan todas
##   ocupadas (se espera de pie);
## - `{}` si no hay zona `waiting` activa (sin ninguna silla) o no existe.
static func find_waiting_spot(
	agent: NpcAgent, room: Dictionary, reserve: bool = true
) -> Dictionary:
	if agent == null or not is_instance_valid(agent) or room.is_empty():
		return {}
	var controller := BuildController.get_active()
	if controller == null:
		return {}

	var waiting_zones := controller.get_zone_ids_of_type(&"waiting")
	if waiting_zones.is_empty():
		return {}

	var desk := room.get("desk") as Node3D
	var room_pos := desk.global_position if desk != null else agent.global_position
	var agent_id := agent.get_instance_id()
	var best_zone: StringName = &""
	var best_distance := INF
	var best_seats: Array[Dictionary] = []
	for zone_id in waiting_zones:
		var seats := _seats_in_zone(controller, zone_id, agent_id)
		if seats.is_empty():
			# Sin asientos la zona de espera no esta activa.
			continue
		var distance := _min_seat_distance(seats, room_pos)
		if distance < best_distance:
			best_distance = distance
			best_zone = zone_id
			best_seats = seats
	if best_zone == &"":
		return {}

	# Primero una silla libre; si no queda ninguna, esperar de pie.
	var free: Array[Dictionary] = []
	for seat in best_seats:
		var obj = seat["object"]
		if obj == null or not is_instance_valid(obj):
			continue
		if obj.find_free_slot(SEAT_AFFORDANCE, agent_id) >= 0:
			free.append(seat)
	if not free.is_empty():
		free.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return agent.global_position.distance_squared_to(
				a["object"].get_use_position(int(a["slot"]))) \
				< agent.global_position.distance_squared_to(
					b["object"].get_use_position(int(b["slot"])))
		)
		for seat in free:
			var obj = seat["object"]
			if not reserve:
				return {
					"seated": true, "object": obj,
					"affordance": obj.get_affordance(SEAT_AFFORDANCE),
					"slot": int(seat["slot"]), "zone_id": best_zone,
					"duration": WAITING_DURATION,
				}
			var slot: int = obj.reserve(SEAT_AFFORDANCE, agent_id)
			if slot >= 0:
				return {
					"seated": true, "object": obj,
					"affordance": obj.get_affordance(SEAT_AFFORDANCE),
					"slot": slot, "zone_id": best_zone,
					"duration": WAITING_DURATION,
				}
	return {
		"seated": false,
		"point": _standing_point(controller, best_zone, agent.global_position),
		"zone_id": best_zone,
	}


## True si el objeto esta dentro de una zona `waiting`. Las sillas de espera
## no se usan para descansar al azar: solo cuando un paciente espera consulta.
static func is_in_waiting_zone(obj) -> bool:
	if obj == null or not is_instance_valid(obj):
		return false
	var controller := BuildController.get_active()
	if controller == null:
		return false
	var node := obj as Node3D
	if node == null:
		return false
	var zone_id := controller.get_zone_id_at_world(node.global_position)
	return controller.get_zone_type_of(zone_id) == &"waiting"


## Asientos `sit` (libres u ocupados) dentro de una zona.
static func _seats_in_zone(
	controller: BuildController, zone_id: StringName, agent_id: int
) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if zone_id == &"":
		return out
	for obj in SmartObjectRegistry.get_objects():
		if obj == null or not is_instance_valid(obj):
			continue
		if is_work_desk(obj):
			continue
		if not obj.has_affordance(SEAT_AFFORDANCE):
			continue
		if not obj.allows_agent(agent_id, SEAT_AFFORDANCE):
			continue
		for slot in obj.get_slot_count():
			if not obj.slot_has_affordance(slot, SEAT_AFFORDANCE):
				continue
			var pos: Vector3 = obj.get_use_position(slot)
			if controller.get_zone_id_at_world(pos) == zone_id:
				out.append({"object": obj, "slot": slot})
	return out


static func _min_seat_distance(seats: Array[Dictionary], from: Vector3) -> float:
	var best := INF
	for seat in seats:
		var obj = seat["object"]
		if obj == null or not is_instance_valid(obj):
			continue
		var distance := from.distance_to(obj.get_use_position(int(seat["slot"])))
		if distance < best:
			best = distance
	return best


## Celda caminable de la zona, fuera de la huella de los muebles, para esperar
## de pie cuando todas las sillas estan ocupadas.
static func _standing_point(
	controller: BuildController, zone_id: StringName, from: Vector3
) -> Vector3:
	var cells := controller.get_zone_cells(zone_id)
	if cells.is_empty():
		return from
	cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return from.distance_squared_to(controller.grid.cell_center(a)) \
			< from.distance_squared_to(controller.grid.cell_center(b))
	)
	for cell in cells:
		var point := controller.grid.cell_center(cell)
		if not controller.has_floor_at_world(point):
			continue
		if controller.get_object_at(cell) != null:
			continue
		return point
	return controller.grid.cell_center(cells[0])


## Zonas `consult` con un medico trabajando en un work_desk dentro de ellas.
static func _active_rooms(controller: BuildController, tree: SceneTree) -> Dictionary:
	var consult_zones: Dictionary = {}
	for zone_id in controller.get_zone_ids_of_type(CONSULT_ZONE):
		consult_zones[zone_id] = true
	if consult_zones.is_empty():
		return {}

	var rooms: Dictionary = {}
	for node in tree.get_nodes_in_group(DOCTOR_GROUP):
		var doctor := node as NpcAgent
		if doctor == null or not is_instance_valid(doctor):
			continue
		var brain := doctor.get_node_or_null("NpcBrain") as NpcBrain
		var desk := _desk_for_doctor(controller, doctor, brain)
		if desk == null:
			continue
		var zone_id := controller.get_zone_id_at_world(desk.global_position)
		if consult_zones.has(zone_id):
			rooms[zone_id] = desk
	return rooms


## Escritorio del medico: el que esta usando para `work` o, durante el hueco
## entre turnos, el `work_desk` que tiene al lado.
static func _desk_for_doctor(
	controller: BuildController, doctor: NpcAgent, brain: NpcBrain
) -> Node3D:
	if brain != null:
		if not brain.enabled:
			return null
		var affordance := brain.get_current_affordance()
		if affordance != null and affordance.id == WORK_AFFORDANCE:
			var current := brain.get_current_object() as Node3D
			if current != null and is_instance_valid(current) and is_work_desk(current):
				return current
	var best: Node3D = null
	var best_distance := DOCTOR_NEAR_DESK
	for special in controller.get_special_objects():
		if special == null or not is_instance_valid(special):
			continue
		if not is_work_desk(special):
			continue
		var distance := doctor.global_position.distance_to(special.global_position)
		if distance <= best_distance:
			best = special
			best_distance = distance
	return best


## True si el objeto es el conjunto del Escritorio de trabajo. La IA normal lo
## ignora para `rest`: sus sillas solo se usan como parte de una consulta.
static func is_work_desk(obj) -> bool:
	return obj is SpecialObject \
		and (obj as SpecialObject).get_special_id() == WORK_DESK_ID


## True si hay algun consultorio activo ahora mismo (util para pruebas/UI).
static func has_active_room(controller: BuildController, tree: SceneTree) -> bool:
	if controller == null or tree == null:
		return false
	return not _active_rooms(controller, tree).is_empty()
