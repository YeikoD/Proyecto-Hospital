class_name NpcSpawner
extends Node3D

## Punto de aparicion de NPCs.
##
## Primera version, deliberadamente simple:
## - Hay un tope global de NPCs vivos (por defecto 5), compartido por todos los
##   spawners de la escena.
## - No aparece gente todo el tiempo: espera un intervalo aleatorio entre
##   apariciones.
## - Solo genera un NPC si hay un SmartObject libre al que pueda ir.
## - El NPC aparece, busca el objeto, lo usa y vuelve a cualquier spawner para
##   desaparecer (ver `NpcSpawnCycle`).
##
## Uso: agregar `npc_spawner.tscn` a la escena (uno por POI). Los spawners se
## encuentran entre si por un registro estatico, sin autoload.

signal npc_spawned(npc: NpcAgent)
signal npc_despawned(npc: NpcAgent)

const NPC_GROUP := &"spawned_npcs"
const SPAWNER_GROUP := &"npc_spawners"
const DEFAULT_NPC_SCENE := preload("res://scripts/characters/npc/npc.tscn")

## Registro estatico: igual que SmartObjectRegistry funciona en tests headless.
static var _spawners: Array = []

@export var npc_scene: PackedScene = DEFAULT_NPC_SCENE
## Vacio = los NPCs se cuelgan del propio spawner.
@export var npc_parent_path: NodePath
@export var enabled := true

@export_group("Poblacion")
## Tope de NPCs vivos en toda la escena. Todos los spawners deberian usar el
## mismo valor para respetar un limite global.
@export var max_alive_total := 5
## Tiempo minimo y maximo entre apariciones (segundos).
@export var spawn_interval_min := 8.0
@export var spawn_interval_max := 16.0
## Espera inicial antes de la primera aparicion.
@export var initial_delay := 2.0

@export_group("Objetivo")
## Si es true, no aparece un NPC hasta que exista un SmartObject libre.
@export var require_objective := true
@export var objective_affordance: StringName = &"sit"
## Radio de busqueda del objetivo. `0` = sin limite: el spawner puede estar
## lejos del hospital y el NPC igual aparece y camina hasta la grilla.
@export var objective_search_radius := 0.0

@export_group("Vida del NPC")
## Necesidad que el NPC llega con ganas de satisfacer.
@export var need: StringName = &"rest"
@export var need_start := 1.0
## Radio en el que el NPC busca el SmartObject. `0` = sin limite: primero
## camina a la grilla y ahi elige el mueble, sin importar la distancia.
@export var brain_search_radius := 0.0
## Si no consigue un objeto en este tiempo, vuelve y desaparece.
@export var search_timeout := 30.0
## Cada cuanto reintenta el camino de vuelta si no llega al spawner. El NPC
## nunca desaparece en el camino: solo al llegar.
@export var return_retry_delay := 3.0

@export_group("Visual")
## El marcador es solo para ubicar el POI en el editor y en el juego.
@export var show_marker := true

var _timer := 0.0


func _ready() -> void:
	add_to_group(SPAWNER_GROUP)
	_register(self)
	if npc_scene == null:
		npc_scene = DEFAULT_NPC_SCENE
	for child in get_children():
		if child is MeshInstance3D and String(child.name).begins_with("Marker"):
			(child as MeshInstance3D).visible = show_marker
	_timer = maxf(initial_delay, 0.0)
	set_process(enabled)


func _exit_tree() -> void:
	_unregister(self)


# --------------------------------------------------------------------------
# API
# --------------------------------------------------------------------------

func start() -> void:
	enabled = true
	_timer = maxf(initial_delay, 0.0)
	set_process(true)


func stop() -> void:
	enabled = false
	set_process(false)


func get_alive_count() -> int:
	return NpcSpawner.count_alive()


func can_spawn() -> bool:
	if not enabled or npc_scene == null:
		return false
	if get_alive_count() >= max_alive_total:
		return false
	if not _nav_ready():
		return false
	if require_objective and not has_objective():
		return false
	return true


## Hay algun SmartObject libre con la affordance objetivo.
func has_objective() -> bool:
	var from := global_position if is_inside_tree() else Vector3.ZERO
	return not SmartObjectRegistry.find_candidates(
		objective_affordance, from, objective_search_radius
	).is_empty()


## Instancia un NPC ya configurado. Devuelve null si no se puede.
func spawn_now() -> NpcAgent:
	if not can_spawn():
		return null

	var instance := npc_scene.instantiate()
	var npc := instance as NpcAgent
	if npc == null:
		push_warning("NpcSpawner: %s no tiene raiz NpcAgent." % npc_scene.resource_path)
		instance.queue_free()
		return null

	var parent := _resolve_parent()
	parent.add_child(npc)
	npc.add_to_group(NPC_GROUP)
	npc.global_position = get_spawn_point()

	_configure_npc(npc)
	_timer = _next_interval()

	npc_spawned.emit(npc)
	return npc


## Punto caminable mas cercano al spawner (con dispersion opcional).
func get_spawn_point() -> Vector3:
	var target := global_position
	if is_inside_tree():
		var map := get_world_3d().navigation_map
		if NavigationServer3D.map_get_iteration_id(map) != 0:
			target = NavigationServer3D.map_get_closest_point(map, target)
	return target


# --------------------------------------------------------------------------
# Bucle de aparicion
# --------------------------------------------------------------------------

func _process(delta: float) -> void:
	if not enabled:
		return
	_timer -= delta
	if _timer > 0.0:
		return
	# Se reprograma siempre: si no puede aparecer, lo reintenta mas tarde
	# en vez de quedar insistiendo cada frame.
	_timer = _next_interval()
	if spawn_now() == null and OS.is_debug_build():
		print("[NpcSpawner] %s: sin objetivo libre, reintento en %.1fs" % [name, _timer])


func _next_interval() -> float:
	var lo := maxf(minf(spawn_interval_min, spawn_interval_max), 0.5)
	var hi := maxf(spawn_interval_max, lo)
	return randf_range(lo, hi)


func _nav_ready() -> bool:
	if not is_inside_tree():
		return false
	var map := get_world_3d().navigation_map
	return NavigationServer3D.map_get_iteration_id(map) != 0


func _resolve_parent() -> Node:
	if not npc_parent_path.is_empty():
		var target := get_node_or_null(npc_parent_path)
		if target != null:
			return target
	var scene := get_tree().current_scene if get_tree() != null else null
	if scene != null:
		var npcs := scene.get_node_or_null("NPCs")
		if npcs != null:
			return npcs
	return get_parent() if get_parent() != null else self


func _configure_npc(npc: NpcAgent) -> void:
	npc.wander = false

	var brain := npc.get_node_or_null("NpcBrain") as NpcBrain
	if brain != null:
		var need_key := String(need)
		var start := clampf(need_start, 0.0, 1.0)
		brain.needs = {need_key: start}
		brain.need_growth = {need_key: 0.0}
		brain.need_affordances = {need_key: objective_affordance}
		brain.need_threshold = minf(start, 0.5)
		brain.search_radius = brain_search_radius
		brain.set_enabled(true)

	var cycle := NpcSpawnCycle.new()
	cycle.name = "NpcSpawnCycle"
	cycle.search_timeout = search_timeout
	cycle.return_retry_delay = return_retry_delay
	npc.add_child(cycle)


# --------------------------------------------------------------------------
# Registro estatico
# --------------------------------------------------------------------------

static func _register(spawner) -> void:
	if spawner == null or _spawners.has(spawner):
		return
	_spawners.append(spawner)


static func _unregister(spawner) -> void:
	_spawners.erase(spawner)


static func get_spawners() -> Array:
	return _spawners.duplicate()


## NPCs vivos ahora mismo en toda la escena.
static func count_alive() -> int:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return 0
	var total := 0
	for node in tree.get_nodes_in_group(NPC_GROUP):
		if is_instance_valid(node) and not node.is_queued_for_deletion():
			total += 1
	return total


## Elige el spawner al que vuelve un NPC. `prefer_nearest` evita caminatas
## largas, pero cualquiera de ellos sirve para desaparecer.
static func pick_return_spawner(from: Vector3, prefer_nearest := true) -> NpcSpawner:
	var options: Array = []
	for spawner in _spawners:
		if not is_instance_valid(spawner):
			continue
		if not spawner.enabled:
			continue
		options.append(spawner)
	if options.is_empty():
		return null

	var best := options[0] as NpcSpawner
	if not prefer_nearest:
		return options[randi() % options.size()] as NpcSpawner
	for spawner in options:
		var typed := spawner as NpcSpawner
		if typed.global_position.distance_squared_to(from) \
				< best.global_position.distance_squared_to(from):
			best = typed
	return best
