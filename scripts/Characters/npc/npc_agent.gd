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
## Congelado = el cerebro lo controla (por ejemplo, mientras usa un objeto).
## No se mueve ni se le aplica física, pero conserva su posición.
var frozen := false


func _ready() -> void:
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

	var map := get_world_3d().navigation_map
	var target := NavigationServer3D.map_get_closest_point(map, world_position)
	_target = target
	_has_target = true
	_wait = 0.0
	_agent.target_position = target


## Detiene el NPC en el lugar.
func stop() -> void:
	_has_target = false
	_wait = 0.0
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
	var desired := direction * speed
	velocity.x = move_toward(velocity.x, desired.x, acceleration * delta)
	velocity.z = move_toward(velocity.z, desired.z, acceleration * delta)

	move_and_slide()
	_rotate_visual(direction, delta)
	_update_animation()


func _decelerate(delta: float) -> void:
	velocity.x = move_toward(velocity.x, 0.0, acceleration * delta)
	velocity.z = move_toward(velocity.z, 0.0, acceleration * delta)


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
