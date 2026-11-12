class_name NpcAgent
extends CharacterBody3D

## NPC que se mueve por el NavMesh usando un NavigationAgent3D.
##
## Uso basico:
##     npc.move_to(Vector3(10, 0, 4))
##
## Si `wander` esta activo, el NPC elige destinos alcanzables dentro de
## `wander_radius` y camina solo. Tambien acepta un AnimationController para
## animar idle / caminar segun la velocidad.

## Se emite una sola vez cuando el NPC llega al destino de `move_to()`.
signal arrived

## Distancia de llegada por defecto del NavigationAgent3D.
const DEFAULT_ARRIVE_DISTANCE := 0.4

## Distancia maxima aceptada al ajustar un destino al NavMesh. Si el resultado
## queda mas lejos, se conserva el destino pedido (el mapa puede estar
## rehorneandose y devolver (0,0,0)).
const NAV_SNAP_MAX_DISTANCE := 3.0

## Grupo de todos los NPC activos, sin importar si los creó un spawner o están
## colocados a mano. Se usa solo para la evasión entre NPCs.
const AGENT_GROUP := &"npc_agents"
## Distancia hacia adelante en la que se busca a otro NPC.
## Arranca el desvio con ~2 m de margen antes del contacto.
const NPC_LOOK_AHEAD := 3.6
## Tiempo bloqueado antes de intentar el desvio.
const NPC_AVOID_DELAY := 0.15
## Separacion lateral del punto de desvio.
const NPC_AVOID_SIDE := 1.2
## Espera entre desvios para no oscilar.
const NPC_AVOID_COOLDOWN := 0.5

@export_group("Movimiento")
@export var speed := 2.2
@export var acceleration := 8.0
@export var turn_speed := 10.0
@export var gravity := 9.8

@export_group("Deambular")
@export var wander := true
@export var wander_radius := 8.0
@export var wander_min_distance := 2.0
@export var pause_time := 1.5
## Intentos para encontrar un punto alcanzable antes de esperar y reintentar.
@export var target_pick_attempts := 12

@export_group("Evasion")
## Si esta activo, detecta otros NPCs al frente y se aparta para no
## atravesarlos. La colision fisica sigue siendo la ultima barrera.
@export var avoid_other_npcs := true
## Distancia hacia adelante donde empieza a considerar a otro NPC.
@export var npc_look_ahead := NPC_LOOK_AHEAD
## Tiempo bloqueado antes de recalcular un desvio.
@export var npc_avoid_delay := NPC_AVOID_DELAY
## Cuanto se aparta lateralmente al esquivar.
@export var npc_avoid_side := NPC_AVOID_SIDE

@export_group("Nodos")
## Vacio = se busca automaticamente un NavigationAgent3D hijo.
@export var agent_path: NodePath
## Nodo visual que gira hacia la direccion de movimiento. Vacio = "Visual".
@export var visual_path: NodePath
## Opcional: controlador de animacion del personaje.
@export var animation_controller_path: NodePath
## Opcional: manager de secuencias de interaccion (enter/loop/exit + POI).
@export var animation_manager_path: NodePath

var _agent: NavigationAgent3D
var _visual: Node3D
var _anim: AnimationController
var _anim_manager: NpcAnimationManager

var _has_target := false
var _nav_ready := false
var _wait := 0.0
var _target := Vector3.ZERO
## Distancia de llegada pedida por el ultimo `move_to()` (se restaura al
## terminar un desvio de evasion).
var _target_arrive_distance := DEFAULT_ARRIVE_DISTANCE
## Desvio temporal para esquivar a otro NPC. Al alcanzarlo se retoma `_target`.
var _detour_active := false
var _detour_target := Vector3.ZERO
var _blocked_time := 0.0
var _avoid_cooldown := 0.0
## Congelado = el cerebro lo controla (por ejemplo, mientras usa un objeto).
## No se mueve ni se le aplica física, pero conserva su posición.
var frozen := false


func _ready() -> void:
	add_to_group(AGENT_GROUP)
	_agent = _resolve_agent()
	_visual = _resolve_visual()
	_anim = _resolve_animation()
	_anim_manager = _resolve_animation_manager()

	if _agent != null:
		_agent.path_desired_distance = 0.4
		_agent.target_desired_distance = DEFAULT_ARRIVE_DISTANCE
		_agent.path_max_distance = 2.0
		_agent.radius = 0.35
		_agent.height = 1.8
		_agent.max_speed = speed
		_agent.avoidance_enabled = false

	# Ajustar el blend de animacion a la velocidad real de este NPC.
	if _anim != null:
		_anim.sync_locomotion_points(speed, speed * 1.6)

	# Cuando se rehornea el NavMesh (por ejemplo al colocar una pared), pedir
	# al agente que recalcule el camino actual.
	if not NavigationServer3D.map_changed.is_connected(_on_map_changed):
		NavigationServer3D.map_changed.connect(_on_map_changed)

	call_deferred("_deferred_start")


func _deferred_start() -> void:
	# Esperar a que el NavigationServer sincronice el mapa (sobre todo si el
	# NavMesh se hornea en el mismo frame en que arranca la escena).
	await get_tree().physics_frame
	await get_tree().physics_frame
	_nav_ready = true
	if wander:
		_pick_new_target()


# --------------------------------------------------------------------------
# API
# --------------------------------------------------------------------------

## Envia el NPC a una posicion del mundo (se ajusta al NavMesh mas cercano).
## `arrive_distance` permite exigir una llegada mas fina (por ejemplo, para
## acercarse de verdad al punto de aproximacion de un SmartObject). Un valor
## <= 0 restaura la distancia por defecto.
func move_to(world_position: Vector3, arrive_distance := 0.0) -> void:
	if _agent == null:
		return
	if not _nav_ready:
		await get_tree().physics_frame

	_agent.target_desired_distance = (
		arrive_distance if arrive_distance > 0.0 else DEFAULT_ARRIVE_DISTANCE
	)
	_target_arrive_distance = _agent.target_desired_distance

	var target := _resolve_nav_target(world_position)
	_target = target
	_has_target = true
	_wait = 0.0
	_detour_active = false
	_blocked_time = 0.0
	_avoid_cooldown = 0.0
	_agent.target_position = target


## Ajusta un destino al NavMesh sin aceptar resultados invalidos.
##
## `map_get_closest_point()` devuelve `(0,0,0)` mientras el mapa no tiene
## poligonos (rebake en curso). Usar ese valor mandaria a los NPCs al centro
## del mundo, asi que en ese caso se conserva el destino original.
func _resolve_nav_target(world_position: Vector3) -> Vector3:
	var map := get_world_3d().navigation_map
	if NavigationServer3D.map_get_iteration_id(map) == 0:
		return world_position
	var closest := NavigationServer3D.map_get_closest_point(map, world_position)
	if closest.is_zero_approx() and not world_position.is_zero_approx():
		return world_position
	if closest.distance_to(world_position) > NAV_SNAP_MAX_DISTANCE:
		return world_position
	return closest


## Detiene el NPC en el lugar.
func stop() -> void:
	_has_target = false
	_wait = 0.0
	_detour_active = false
	_blocked_time = 0.0
	_avoid_cooldown = 0.0
	velocity = Vector3.ZERO
	if _agent != null:
		_agent.target_position = global_position


func is_moving() -> bool:
	return _has_target and _agent != null and not _agent.is_navigation_finished()


func get_target() -> Vector3:
	return _target


## Bloquea el movimiento sin sacar al NPC del árbol (mientras usa un objeto).
func set_frozen(value: bool) -> void:
	frozen = value
	if frozen:
		velocity = Vector3.ZERO


## Gira el modelo visual hacia un punto del mundo, sin mover al NPC.
func look_towards(world_position: Vector3) -> void:
	if _visual == null:
		return
	var direction := world_position - global_position
	direction.y = 0.0
	if direction.length_squared() < 0.0001:
		return
	_visual.rotation.y = atan2(-direction.x, -direction.z)


## Reproduce una animación de interacción sostenida, si existe.
func play_interaction(animation: StringName) -> void:
	if _anim != null and animation != StringName():
		_anim.hold(animation)


## Vuelve al locomotion tras una interacción.
func stop_interaction() -> void:
	if _anim != null:
		_anim.release()


## Manager de secuencias (enter/loop/exit). Puede ser null si el NPC no lo
## tiene configurado.
func get_animation_manager() -> NpcAnimationManager:
	if _anim_manager == null or not is_instance_valid(_anim_manager):
		_anim_manager = _resolve_animation_manager()
	return _anim_manager


## Atajo para sistemas externos: alinea al NPC al POI y reproduce la secuencia.
func play_animation_sequence(
	set: SmartAnimationSet,
	poi: Transform3D,
	exit_transform: Transform3D,
	soft_align := true
) -> bool:
	var manager := get_animation_manager()
	if manager == null:
		return false
	return manager.play_at(set, poi, exit_transform, soft_align)


func cancel_animation_sequence() -> void:
	var manager := get_animation_manager()
	if manager != null:
		manager.cancel()


## Coloca al NPC en un transform del mundo (posición + orientación visual).
## Pensado para POIs: el CharacterBody no rota, gira el modelo igual que al
## caminar. No llama move_and_slide: usar con el NPC congelado.
func teleport_to(transform: Transform3D) -> void:
	global_position = transform.origin
	if _visual == null:
		return
	var forward := -transform.basis.z.normalized()
	if forward.length_squared() < 0.0001:
		return
	_visual.rotation.y = atan2(-forward.x, -forward.z)


## Activa o desactiva los colliders del NPC. Se difiere porque cambiar un
## shape durante un callback de física lanza error.
func set_collision_enabled(enabled: bool) -> void:
	for child in get_children():
		if child is CollisionShape3D:
			child.set_deferred("disabled", not enabled)


# --------------------------------------------------------------------------
# Movimiento
# --------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if frozen:
		velocity = Vector3.ZERO
		_update_animation()
		return

	if not is_on_floor():
		velocity.y -= gravity * delta

	if _agent == null:
		move_and_slide()
		return

	if not _has_target:
		_wait -= delta
		if wander and _nav_ready and _wait <= 0.0:
			_pick_new_target()
		_decelerate(delta)
		move_and_slide()
		_update_animation()
		return

	if _agent.is_navigation_finished():
		# Terminar un desvio no significa haber llegado: se retoma la ruta.
		if _detour_active:
			_end_detour()
			_decelerate(delta)
			move_and_slide()
			_update_animation()
			return
		_has_target = false
		_wait = pause_time
		_decelerate(delta)
		move_and_slide()
		_update_animation()
		arrived.emit()
		return

	var next := _agent.get_next_path_position()
	var direction := next - global_position
	direction.y = 0.0

	if direction.length_squared() < 0.0001:
		_decelerate(delta)
		move_and_slide()
		_update_animation()
		return

	direction = direction.normalized()
	if avoid_other_npcs:
		_update_npc_avoidance(delta, direction)

	var desired := direction * speed
	velocity.x = move_toward(velocity.x, desired.x, acceleration * delta)
	velocity.z = move_toward(velocity.z, desired.z, acceleration * delta)

	move_and_slide()
	_rotate_visual(direction, delta)
	_update_animation()


func _decelerate(delta: float) -> void:
	velocity.x = move_toward(velocity.x, 0.0, acceleration * delta)
	velocity.z = move_toward(velocity.z, 0.0, acceleration * delta)


# --------------------------------------------------------------------------
# Evasion de otros NPCs
# --------------------------------------------------------------------------

## Detecta un NPC adelante. Si sigue bloqueado el tiempo suficiente, recalcula
## un desvio corto hacia un costado y luego retoma el destino original.
func _update_npc_avoidance(delta: float, forward: Vector3) -> void:
	if _avoid_cooldown > 0.0:
		_avoid_cooldown = maxf(_avoid_cooldown - delta, 0.0)
	if _detour_active or not _has_target:
		return

	var blocker := _find_npc_in_front(forward)
	if blocker == null:
		_blocked_time = 0.0
		return

	var to_blocker := blocker.global_position - global_position
	to_blocker.y = 0.0
	# No desviarse de alguien que camina en la misma direccion (fila india):
	# a menos que este muy cerca, seguir su ritmo es mas natural.
	if _is_same_direction_blocker(blocker, forward, to_blocker.length()):
		_blocked_time = 0.0
		return

	_blocked_time += delta
	if _blocked_time < npc_avoid_delay or _avoid_cooldown > 0.0:
		return
	_blocked_time = 0.0
	_start_detour(blocker, forward)


## True si el otro NPC va hacia el mismo lado que nosotros. Se usa para no
## zigzaguear detras de alguien que camina en fila.
func _is_same_direction_blocker(
	blocker: NpcAgent,
	forward: Vector3,
	distance: float
) -> bool:
	if not blocker._has_target:
		return false
	var other_target := blocker.get_target() - blocker.global_position
	other_target.y = 0.0
	if other_target.length_squared() < 0.01:
		return false
	if forward.dot(other_target.normalized()) <= 0.6:
		return false
	return distance > 1.4


## Primer NPC dentro del cono frontal, o null.
func _find_npc_in_front(forward: Vector3) -> NpcAgent:
	var flat := Vector3(forward.x, 0.0, forward.z)
	if flat.length_squared() < 0.0001:
		return null
	flat = flat.normalized()

	var best: NpcAgent = null
	var best_distance := npc_look_ahead
	for node in get_tree().get_nodes_in_group(AGENT_GROUP):
		var other := node as NpcAgent
		if other == null or other == self or not is_instance_valid(other):
			continue
		if other.frozen or not other.is_inside_tree():
			continue
		var to_other := other.global_position - global_position
		if absf(to_other.y) > 1.2:
			continue
		to_other.y = 0.0
		var distance := to_other.length()
		if distance < 0.001 or distance > best_distance:
			continue
		# Solo lo que esta realmente adelante (cono de ~70 grados).
		if to_other.dot(flat) / distance < 0.35:
			continue
		best_distance = distance
		best = other
	return best


## Recalcula un punto al costado del NPC que bloquea y lo usa como destino
## temporal. La ruta original queda guardada en `_target`.
func _start_detour(blocker: NpcAgent, forward: Vector3) -> void:
	if _agent == null or blocker == null or not is_instance_valid(blocker):
		return

	var flat := Vector3(forward.x, 0.0, forward.z)
	if flat.length_squared() < 0.0001:
		return
	flat = flat.normalized()
	var right := flat.cross(Vector3.UP)
	if right.length_squared() < 0.0001:
		return
	right = right.normalized()

	var to_other := blocker.global_position - global_position
	to_other.y = 0.0
	# Si el otro esta a la izquierda, nos apartamos a la derecha (y viceversa).
	# De frente ambos eligen su propia derecha: al caminar en sentidos opuestos
	# terminan pasando por lados distintos.
	var side := flat.cross(to_other).y
	var lateral := right
	if absf(side) > 0.2 and side < 0.0:
		lateral = -right

	var detour_point := blocker.global_position + lateral * npc_avoid_side + flat * 0.5
	var snapped := _resolve_nav_target(detour_point)
	if snapped.distance_to(detour_point) > NAV_SNAP_MAX_DISTANCE:
		return
	var map := get_world_3d().navigation_map
	if NavigationServer3D.map_get_iteration_id(map) == 0:
		return
	var path := NavigationServer3D.map_get_path(map, global_position, snapped, true)
	if path.size() <= 1:
		return

	_detour_target = snapped
	_detour_active = true
	_agent.target_desired_distance = DEFAULT_ARRIVE_DISTANCE
	_agent.target_position = snapped


## Vuelve a apuntar al destino original despues del desvio.
func _end_detour() -> void:
	_detour_active = false
	_avoid_cooldown = NPC_AVOID_COOLDOWN
	if _agent == null:
		return
	_agent.target_desired_distance = _target_arrive_distance
	if _has_target:
		_agent.target_position = _target


## Elige un punto aleatorio que exista de verdad en el NavMesh y sea alcanzable.
func _pick_new_target() -> bool:
	if _agent == null:
		return false

	var map := get_world_3d().navigation_map
	if NavigationServer3D.map_get_iteration_id(map) == 0:
		_wait = 0.5
		return false

	var origin := global_position
	var max_distance := maxf(wander_min_distance + 0.1, wander_radius)

	for attempt in target_pick_attempts:
		var angle := randf() * TAU
		var distance := randf_range(wander_min_distance, max_distance)
		var candidate := origin \
			+ Vector3(cos(angle), 0.0, sin(angle)) * distance
		var closest := NavigationServer3D.map_get_closest_point(map, candidate)

		# Si el punto mas cercano esta muy lejos, el candidato cayo fuera del
		# NavMesh (o todavia no hay NavMesh).
		if closest.distance_to(candidate) > 1.5:
			continue
		if closest.distance_to(origin) < 1.0:
			continue

		var path := NavigationServer3D.map_get_path(map, origin, closest, true)
		if path.size() > 1:
			move_to(closest)
			return true

	_wait = 0.5
	return false


func _rotate_visual(direction: Vector3, delta: float) -> void:
	if _visual == null:
		return
	var target_yaw := atan2(-direction.x, -direction.z)
	_visual.rotation.y = lerp_angle(
		_visual.rotation.y,
		target_yaw,
		clampf(turn_speed * delta, 0.0, 1.0)
	)


func _update_animation() -> void:
	if _anim != null:
		_anim.set_speed(Vector2(velocity.x, velocity.z).length())


func _on_map_changed(map: RID) -> void:
	if _agent == null or not _has_target:
		return
	if map == get_world_3d().navigation_map:
		_agent.target_position = _target


# --------------------------------------------------------------------------
# Resolucion de nodos
# --------------------------------------------------------------------------

func _resolve_agent() -> NavigationAgent3D:
	if not agent_path.is_empty():
		var node := get_node_or_null(agent_path)
		if node is NavigationAgent3D:
			return node as NavigationAgent3D
	return _find_class(self, "NavigationAgent3D") as NavigationAgent3D


func _resolve_visual() -> Node3D:
	if not visual_path.is_empty():
		var node := get_node_or_null(visual_path)
		if node is Node3D:
			return node as Node3D
	return _find_named(self, "Visual") as Node3D


func _resolve_animation() -> AnimationController:
	if not animation_controller_path.is_empty():
		var node := get_node_or_null(animation_controller_path)
		if node is AnimationController:
			return node as AnimationController
	return _find_anim(self)


func _resolve_animation_manager() -> NpcAnimationManager:
	if not animation_manager_path.is_empty():
		var node := get_node_or_null(animation_manager_path)
		if node is NpcAnimationManager:
			return node as NpcAnimationManager
	return _find_anim_manager(self)


func _find_anim_manager(node: Node) -> NpcAnimationManager:
	if node is NpcAnimationManager:
		return node as NpcAnimationManager
	for child in node.get_children():
		var found := _find_anim_manager(child)
		if found != null:
			return found
	return null


func _find_anim(node: Node) -> AnimationController:
	if node is AnimationController:
		return node as AnimationController
	for child in node.get_children():
		var found := _find_anim(child)
		if found != null:
			return found
	return null


func _find_class(node: Node, type_name: String) -> Node:
	if node.is_class(type_name):
		return node
	for child in node.get_children():
		var found := _find_class(child, type_name)
		if found != null:
			return found
	return null


func _find_named(node: Node, node_name: String) -> Node:
	if node.name == node_name:
		return node
	for child in node.get_children():
		var found := _find_named(child, node_name)
		if found != null:
			return found
	return null
