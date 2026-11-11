extends Node
class_name AnimationController

## Controlador de animaciones para personajes humanoides.
##
## API por intencion en lugar de play("nombre"):
##     anim.play_oneshot("Golpe")   # una vez, vuelve solo al locomotion
##     anim.hold("Guardia")         # se mantiene
##     anim.release()               # vuelve al locomotion (o al hold anterior)
##     anim.cancel()                # corte inmediato
##
## Es autocontenido: encuentra su AnimationTree y AnimationPlayer, e inyecta la
## biblioteca de animaciones. El resto del proyecto no necesita saber como
## funciona el esqueleto.
##
## Para agregar una animacion: exportala a anim/<nombre>.anim, ponela en el
## Inspector, y escribi UNA LINEA en `actions` o `holdables`.

signal started(state: StringName)
signal finished(state: StringName)

const LOCOMOTION := &"Locomotion"

## Biblioteca de animaciones a usar. Si esta vacia se toma la que ya tenga el
## AnimationPlayer.
@export var anim_library: AnimationLibrary

## Ruta al AnimationTree. Vacio = se busca automaticamente en el padre.
@export var tree_path: NodePath
## Ruta al AnimationPlayer. Vacio = se busca automaticamente en el padre.
@export var player_path: NodePath

## Puntos del locomotion: animacion -> velocidad (m/s) que la activa.
## Los valores intermedios se interpolan solos.
## Con 3 puntos: idle a 0, walk a `speed`, run a `sprint_speed`.
## Ajustalos desde el Inspector o con sync_locomotion_points().
@export var locomotion_points: Array[Dictionary] = [
	{"anim": &"idle", "speed": 0.0},
	{"anim": &"walk", "speed": 2.0},
	{"anim": &"run", "speed": 5.0},
]

## Animaciones de un disparo: play_oneshot() las reproduce y vuelve al locomotion.
@export var actions: Array[StringName] = []

## Animaciones sostenidas: hold() las mantiene hasta release().
@export var holdables: Array[StringName] = []

## Animaciones del torso superior (mascara).
## No entran en la maquina de estados: van en una capa aparte que solo
## escribe los huesos de arriba, asi el personaje puede seguir caminando
## normal mientras apunta.
@export var upper_body: Array[StringName] = []

## Crossfade por defecto, en segundos.
@export var xfade := 0.2

## Suavizado del valor de blend, en unidades de velocidad por segundo.
## 0 = el cambio es instantaneo.
@export var blend_smoothing := 6.0

var _tree: AnimationTree
var _player: AnimationPlayer
var _sm: AnimationNodeStateMachine
var _playback: AnimationNodeStateMachinePlayback
var _blend: AnimationNodeBlendSpace1D
var _state := LOCOMOTION
var _hold_anterior := StringName()
var _oneshot := StringName()
var _oneshot_left := 0.0
var _speed := 0.0
var _blend_actual := 0.0
var _sync_pendiente: Array = []
var _listo := false
var _capa: AnimationPlayer


func _ready() -> void:
	# El AnimationTree vive dentro de la escena instanciada del modelo: puede
	# todavia no existir cuando corre _ready. Lo armamos en el primer frame util.
	process_priority = 10


func _process(delta: float) -> void:
	if not _listo:
		_intentar_armar()
		if not _listo:
			return

	var objetivo := clampf(_speed, 0.0, _max_speed())
	_blend_actual = move_toward(_blend_actual, objetivo, blend_smoothing * delta)
	_tree.set("parameters/%s/blend_position" % LOCOMOTION, _blend_actual)

	if _oneshot != StringName():
		_oneshot_left -= delta
		if _oneshot_left <= 0.0:
			_terminar_oneshot()


## Reproduce una accion de un disparo y vuelve al locomotion al terminar.
func play_oneshot(estado: StringName) -> void:
	if not _existe(estado):
		return
	_oneshot = estado
	_oneshot_left = _duracion(estado)
	_playback.travel(estado)
	_state = estado
	started.emit(estado)


## Reproduce una animacion y la mantiene hasta release().
func hold(estado: StringName) -> void:
	_oneshot = StringName()
	# las animaciones de torso superior no entran en la maquina de estados:
	# van en una capa aparte que solo escribe sus huesos.
	if estado in upper_body:
		_capa_play(estado)
		return
	if not _existe(estado):
		return
	if _state in holdables:
		_hold_anterior = _state
	_playback.travel(estado)
	_state = estado
	started.emit(estado)


## Vuelve al locomotion, o al hold anterior si habia uno encadenado.
func release() -> void:
	_oneshot = StringName()
	_capa_stop()
	# Si el sistema aun no se armo (NPC recien instanciado), no hay nada que
	# soltar: evitamos tocar _sm/_playback nulos.
	if not _listo:
		_state = LOCOMOTION
		_hold_anterior = StringName()
		return
	var destino := _hold_anterior if _hold_anterior != StringName() else LOCOMOTION
	if _sm.has_node(destino):
		_playback.travel(destino)
		_state = destino
	else:
		_playback.travel(LOCOMOTION)
		_state = LOCOMOTION
	_hold_anterior = StringName()


## Corta lo que haya y vuelve al locomotion de inmediato.
func cancel() -> void:
	_oneshot = StringName()
	_hold_anterior = StringName()
	if not _listo:
		_state = LOCOMOTION
		return
	_playback.travel(LOCOMOTION)
	_state = LOCOMOTION


func is_playing() -> bool:
	return _state != LOCOMOTION


## Llamado por el controlador de movimiento cada frame. El controller decide
## en que punto del blend caerse; el movimiento solo informa la velocidad.
func set_speed(v: float) -> void:
	_speed = v


func current_state() -> StringName:
	return _state


## Ajusta los puntos del blend para que caigan en las velocidades reales del
## personaje: idle a 0, walk a `walk_speed`, run a `run_speed`.
## Llamarlo cuando cambien los exports del controlador de movimiento.
func sync_locomotion_points(walk_speed: float, run_speed: float) -> void:
	if locomotion_points.size() < 3:
		return
	var d0 := locomotion_points[0] as Dictionary
	var d1 := locomotion_points[1] as Dictionary
	var d2 := locomotion_points[2] as Dictionary
	d0["speed"] = 0.0
	d1["speed"] = walk_speed
	d2["speed"] = maxf(run_speed, walk_speed + 0.01)
	if not _listo:
		_sync_pendiente = [walk_speed, run_speed]
		return
	_blend.max_space = _max_speed()
	_blend.set_blend_point_position(0, 0.0)
	_blend.set_blend_point_position(1, float(d1["speed"]))
	_blend.set_blend_point_position(2, float(d2["speed"]))


func _intentar_armar() -> void:
	_resolver()
	if _tree == null or _player == null:
		return
	if anim_library != null:
		_inyectar_biblioteca()
	if _player.get_animation_library("") == null:
		return
	_construir()
	_listo = true


func _inyectar_biblioteca() -> void:
	if _player.has_animation_library(""):
		_player.remove_animation_library("")
	_player.add_animation_library("", anim_library)


func _resolver() -> void:
	# El AnimationTree suele ser hermano de este nodo (vive dentro de la escena
	# instanciada del modelo), asi que se busca desde el padre.
	var raiz := get_parent() as Node
	if tree_path != NodePath():
		_tree = get_node_or_null(tree_path) as AnimationTree
	if _tree == null and raiz != null:
		_tree = _buscar(raiz, "AnimationTree") as AnimationTree
	if player_path != NodePath():
		_player = get_node_or_null(player_path) as AnimationPlayer
	if _player == null and raiz != null:
		_player = _buscar(raiz, "AnimationPlayer") as AnimationPlayer


func _buscar(desde: Node, clase: String) -> Node:
	if desde.is_class(clase):
		return desde
	for c in desde.get_children():
		var r := _buscar(c, clase)
		if r != null:
			return r
	return null


func _construir() -> void:
	_sm = AnimationNodeStateMachine.new()
	_blend = AnimationNodeBlendSpace1D.new()
	_blend.min_space = 0.0
	_blend.max_space = _max_speed()

	for punto in locomotion_points:
		var d := punto as Dictionary
		var nodo := AnimationNodeAnimation.new()
		nodo.animation = d.get("anim")
		_blend.add_blend_point(nodo, float(d.get("speed", 0.0)), -1, d.get("anim"))
	_sm.add_node(LOCOMOTION, _blend)

	# Primero TODOS los nodos, despues las transiciones: add_transition exige
	# que el destino ya exista en la maquina.
	var todas := actions.duplicate()
	todas.append_array(holdables)
	for estado in todas:
		if _sm.has_node(estado):
			continue
		if estado in upper_body:
			# las de torso superior viven en su propia capa, no aqui
			continue
		var nodo := AnimationNodeAnimation.new()
		nodo.animation = estado
		_sm.add_node(estado, nodo)

	for estado in todas:
		if not _sm.has_node(estado):
			continue
		_sm.add_transition(LOCOMOTION, estado, _transicion())
		_sm.add_transition(estado, LOCOMOTION, _transicion())

	_tree.tree_root = _sm
	_tree.active = true
	_playback = _tree.get("parameters/playback")
	_playback.start(LOCOMOTION)
	_preparar_capa()
	# puede haberse llamado antes de que existiera el arbol
	if _sync_pendiente:
		sync_locomotion_points(_sync_pendiente[0], _sync_pendiente[1])
		_sync_pendiente = []


## Capa de animacion para el torso superior.
##
## En vez de meter el apuntado dentro de la maquina de estados (eso congela
## las piernas, porque el estado deja de evaluar la locomotion), se crea un
## AnimationPlayer extra sobre el MISMO esqueleto. El clip de apuntado no
## tiene tracks de cadera ni de piernas, asi que la capa solo escribe el torso
## y deja las piernas al AnimationTree.
##
## Se cuelga del padre del AnimationTree y se anade al final, para que la
## maquina de estados procese primero y la capa escriba encima.
func _preparar_capa() -> void:
	if _capa != null or upper_body.is_empty():
		return
	var sk := _esqueleto()
	var padre := _tree.get_parent() if _tree != null else null
	if sk == null or padre == null:
		return
	_capa = AnimationPlayer.new()
	_capa.name = "CapaTorsoSuperior"
	padre.add_child(_capa)
	# Mismo root_node que el AnimationTree: las rutas de track de la biblioteca
	# ("Armature/Skeleton3D:hueso") estan relativas a ahi. La capa se cuelga
	# del mismo padre, asi que el NodePath relativo sirve igual.
	_capa.root_node = _tree.root_node
	if anim_library != null:
		_capa.add_animation_library("", anim_library)
	_capa.stop()


func _capa_play(estado: StringName) -> void:
	_preparar_capa()
	if _capa == null:
		return
	if not _capa.has_animation(estado):
		return
	# El clip es una pose constante (frame final aplanado) con loop perfecto.
	# Se deja reproduciendo en loop para que la capa escriba el torso cada
	# frame: si el AnimationPlayer deja de reproducir, deja de escribir huesos
	# y el torso vuelve a la locomotion.
	_capa.play(estado)


func _capa_stop() -> void:
	if _capa != null:
		_capa.stop()


## El Skeleton3D suele quedar a un par de niveles del AnimationTree, asi que
## se busca en toda la rama de la escena, no solo entre los ancestros.
func _esqueleto() -> Skeleton3D:
	# El Skeleton3D suele quedar a un par de niveles del AnimationTree, asi que
	# se busca en toda la rama de la escena, no solo entre los ancestros.
	var n: Node = self
	if _tree != null:
		n = _tree
	var top: Node = n
	while top.get_parent() != null:
		top = top.get_parent()
	return _buscar(top, "Skeleton3D") as Skeleton3D


## BlendSpace1D con los puntos de locomotion. Se puede usar como nodo suelto
## dentro de un BlendTree.
func _crear_blend_locomotion() -> AnimationNodeBlendSpace1D:
	var espacio := AnimationNodeBlendSpace1D.new()
	espacio.min_space = 0.0
	espacio.max_space = _max_speed()
	for punto in locomotion_points:
		var d := punto as Dictionary
		var nodo := AnimationNodeAnimation.new()
		nodo.animation = d.get("anim")
		espacio.add_blend_point(nodo, float(d.get("speed", 0.0)), -1, d.get("anim"))
	return espacio


func _terminar_oneshot() -> void:
	var terminado := _oneshot
	_oneshot = StringName()
	_playback.travel(LOCOMOTION)
	_state = LOCOMOTION
	finished.emit(terminado)


func _existe(estado: StringName) -> bool:
	if not _listo:
		push_warning("AnimationController: el sistema aun no esta armado")
		return false
	if not _sm.has_node(estado):
		push_warning("AnimationController: no existe la animacion '%s'" % estado)
		return false
	return true


func _transicion() -> AnimationNodeStateMachineTransition:
	var t := AnimationNodeStateMachineTransition.new()
	t.xfade_time = xfade
	return t


func _duracion(estado: StringName) -> float:
	var nodo := _sm.get_node(estado)
	if nodo == null:
		return 0.5
	var anim := _player.get_animation((nodo as AnimationNodeAnimation).animation)
	return anim.length if anim != null else 0.5


func _max_speed() -> float:
	var maximo := 0.0
	for punto in locomotion_points:
		var d := punto as Dictionary
		maximo = maxf(maximo, float(d.get("speed", 0.0)))
	return maximo
