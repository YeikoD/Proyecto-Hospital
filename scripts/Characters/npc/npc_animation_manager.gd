class_name NpcAnimationManager
extends Node

## Reproduce secuencias de animación completas sobre el esqueleto de un NPC.
##
## Un `SmartAnimationSet` declara tres fases (entrada, loop y salida) que pueden
## venir de archivos distintos. El manager:
##
##   1. Extrae los clips del GLB/escena de origen.
##   2. Los retargetea al `Skeleton3D` del NPC (las animaciones de Mixamo usan
##      nodos `Scene/Armature/...` y el NPC usa huesos `Armature/Skeleton3D:...`).
##   3. Los reproduce en un `AnimationPlayer` propio, agregado al final del
##      modelo, para que pise al AnimationTree de locomotion.
##   4. Alinea el modelo al POI recibido moviéndolo suavemente desde la
##      posición donde el NPC llegó (el cuerpo no se teletransporta) y
##      desactiva su colisión mientras la secuencia está activa.
##
## La secuencia avanza sola: enter -> loop -> (request_exit) -> exit -> finished.
## El dueño (por ejemplo `NpcBrain`) sólo decide cuándo pedir la salida.

signal phase_started(phase: StringName)
## El loop ya está corriendo: recién aquí conviene empezar a contar la duración
## de la interacción.
signal loop_started
## La secuencia terminó y el NPC volvió a su punto de salida.
signal finished
## Se canceló desde afuera (objeto borrado, timeout, cerebro desactivado...).
signal canceled

const PHASE_ENTER := &"enter"
const PHASE_LOOP := &"loop"
const PHASE_EXIT := &"exit"

## Ruta al modelo visual del NPC. Vacío = hijo "Visual".
@export var visual_path: NodePath
## Nombre del AnimationPlayer propio que crea el manager.
@export var player_name := &"SmartInteractionPlayer"
## Duración del desplazamiento suave del modelo hasta el POI al empezar.
@export var align_duration := 0.4
## Duración del desplazamiento suave del modelo de vuelta al punto de salida
## tras la animación de exit (evita el "teletransporte" al levantarse).
@export var exit_return_duration := 0.35
## Si el NPC está a más de esta distancia del POI, se teletransporta el cuerpo
## (compatibilidad). Lo normal es llegar caminando y resolver el resto con un
## desplazamiento suave del modelo.
@export var max_soft_align_distance := 1.5

var _npc: NpcAgent
var _visual: Node3D
var _human: Node3D
var _skeleton: Skeleton3D
var _skeleton_path: NodePath
var _player: AnimationPlayer

var _set: SmartAnimationSet
var _phase := StringName()
var _active := false
var _finishing := false
var _has_poi := false
var _soft_align := false
var _poi := Transform3D.IDENTITY
var _exit_transform := Transform3D.IDENTITY
var _align_tween: Tween
var _returning_visual := false
## Posición local original del nodo Visual (el POI se aplica como offset).
var _visual_base_position := Vector3.ZERO
var _visual_base_captured := false

## path del archivo -> { "clips": {nombre: Animation}, "rests": {nodo: Transform3D} }
var _sources: Dictionary = {}
## "archivo|clip|loop" -> nombre dentro del AnimationPlayer.
var _name_by_key: Dictionary = {}
var _key_by_name: Dictionary = {}


func _ready() -> void:
	_resolve_nodes()


func _exit_tree() -> void:
	_active = false
	if _player != null:
		_player.stop()


# --------------------------------------------------------------------------
# API
# --------------------------------------------------------------------------

## Reproduce la secuencia sin mover al NPC. Útil para pruebas o animaciones
## que no necesitan POI.
func play(set: SmartAnimationSet) -> bool:
	return _play(set, false, Transform3D.IDENTITY, Transform3D.IDENTITY)


## Reproduce la secuencia alineando el modelo del NPC al `poi` y
## devolviéndolo al `exit_transform` cuando termina.
##
## Con `soft_align` (por defecto) el cuerpo se queda donde llegó y el modelo
## se desplaza suavemente hasta el POI: así el NPC camina hasta el mueble y
## recién ahí empieza a sentarse, sin teletransportes. Si la distancia al POI
## supera `max_soft_align_distance`, o `soft_align` es false, se coloca el
## cuerpo directamente en el POI (comportamiento anterior).
func play_at(
	set: SmartAnimationSet,
	poi: Transform3D,
	exit_transform: Transform3D,
	soft_align := true
) -> bool:
	return _play(set, true, poi, exit_transform, soft_align)


## Pide pasar a la fase de salida. Si no hay clip de salida termina enseguida.
func request_exit() -> void:
	if not _active or _phase == PHASE_EXIT:
		return
	if not _start_phase(PHASE_EXIT):
		_complete()


func cancel() -> void:
	if not _active and not _finishing:
		return
	var was_finishing := _finishing
	_stop_restore(false)
	_active = false
	_phase = StringName()
	_stop_player()
	_reset_skeleton()
	_restore_pose()
	if was_finishing:
		finished.emit()
	else:
		canceled.emit()


## Detiene el tween de alineación/retorno. Si `emit_canceled` es true y había
## una interacción activa (no solo el retorno), se notifica cancelación.
func _stop_restore(emit_canceled: bool) -> void:
	_kill_align_tween()
	_returning_visual = false
	var had_active := _active
	_finishing = false
	_active = false
	if _soft_align and _visual != null and _visual_base_captured:
		_visual.position = _visual_base_position
	if emit_canceled and had_active:
		_stop_player()
		_reset_skeleton()
		_restore_pose()
		canceled.emit()


func is_playing() -> bool:
	return _active or _finishing


func get_phase() -> StringName:
	return _phase


func get_animation_set() -> SmartAnimationSet:
	return _set


func get_animation_player() -> AnimationPlayer:
	return _player


func get_skeleton() -> Skeleton3D:
	return _skeleton


## Cantidad de clips retargeteados ya cargados (para depuración y tests).
func get_loaded_clip_count() -> int:
	if _player == null:
		return 0
	return _player.get_animation_list().size()


# --------------------------------------------------------------------------
# Secuencia
# --------------------------------------------------------------------------

func _play(
	set: SmartAnimationSet,
	use_poi: bool,
	poi: Transform3D,
	exit_transform: Transform3D,
	soft_align := true
) -> bool:
	if set == null or not set.has_any():
		return false

	_resolve_nodes()
	if _npc == null or _skeleton == null or not _ensure_player():
		return false

	if _active or _finishing or _returning_visual:
		_stop_restore(true)

	_set = set
	_has_poi = use_poi
	_soft_align = use_poi and soft_align \
		and poi.origin.distance_to(_npc.global_position) <= max_soft_align_distance
	_poi = poi
	_exit_transform = exit_transform
	_active = true
	_phase = StringName()

	if use_poi:
		if _soft_align:
			_begin_alignment(poi)
		else:
			_align_to_poi(poi)

	if not _start_phase(PHASE_ENTER) and not _start_phase(PHASE_LOOP):
		if not _start_phase(PHASE_EXIT):
			# Ningún clip se pudo cargar: deshacer la alineación sin emitir
			# `finished` (el dueño todavía está dentro de su propio callback).
			_active = false
			_phase = StringName()
			_kill_align_tween()
			_stop_player()
			_reset_skeleton()
			_restore_pose()
			return false
	return true


func _start_phase(phase: StringName) -> bool:
	if _set == null:
		return false

	var source := ""
	var clip := StringName()
	var loop := false
	match phase:
		PHASE_ENTER:
			source = _set.enter_source
			clip = _set.enter_clip
		PHASE_LOOP:
			source = _set.loop_source
			clip = _set.loop_clip
			loop = true
		PHASE_EXIT:
			source = _set.exit_source
			clip = _set.exit_clip
		_:
			return false

	if source == "":
		return false

	var anim_name := _get_clip(source, clip, phase, loop)
	if anim_name == StringName():
		return false

	_phase = phase
	var fade := _set.enter_fade if phase == PHASE_ENTER else _set.xfade
	_player.play(anim_name, fade)
	if phase == PHASE_EXIT:
		# El modelo vuelve al punto de salida mientras la animación de
		# levantarse hace su trabajo: se ve como un paso atrás, sin saltos.
		_begin_visual_return(exit_return_duration)
	phase_started.emit(phase)
	if phase == PHASE_LOOP:
		loop_started.emit()
	return true


func _on_animation_finished(_anim_name: StringName) -> void:
	if not _active:
		return

	match _phase:
		PHASE_ENTER:
			if not _start_phase(PHASE_LOOP):
				if not _start_phase(PHASE_EXIT):
					_complete()
		PHASE_EXIT:
			_complete()
		PHASE_LOOP:
			# El loop tiene loop_mode linear; si termina es porque el clip no
			# pudo configurarse como loop. Volver a arrancarlo es lo más sano.
			_start_phase(PHASE_LOOP)


func _complete() -> void:
	if not _active:
		return
	_active = false
	_phase = StringName()
	_stop_player()
	_reset_skeleton()
	if _soft_align and _visual != null and _visual_base_captured \
			and _visual.position.distance_to(_visual_base_position) > 0.005:
		_finishing = true
		_begin_visual_return(exit_return_duration)
		if not _returning_visual:
			_finishing = false
			_restore_pose()
			finished.emit()
		return
	_restore_pose()
	finished.emit()


## Devuelve el modelo a su posición local original. Si ya está ahí no hace
## nada; si `duration` es 0 lo coloca directamente.
func _begin_visual_return(duration: float) -> void:
	if _visual == null or not _soft_align or not _visual_base_captured:
		return
	if _returning_visual:
		return
	if _visual.position.distance_to(_visual_base_position) < 0.005:
		return
	_kill_align_tween()
	if duration <= 0.0:
		_visual.position = _visual_base_position
		return
	_returning_visual = true
	_align_tween = create_tween()
	_align_tween.set_ease(Tween.EASE_IN_OUT)
	_align_tween.set_trans(Tween.TRANS_CUBIC)
	_align_tween.tween_property(
		_visual, "position", _visual_base_position, duration
	)
	_align_tween.finished.connect(_on_visual_return_finished, CONNECT_ONE_SHOT)


func _on_visual_return_finished() -> void:
	_returning_visual = false
	_align_tween = null
	if not _finishing:
		return
	_finishing = false
	_restore_pose()
	finished.emit()


func _kill_align_tween() -> void:
	if _align_tween != null and _align_tween.is_valid():
		_align_tween.kill()
	_align_tween = null


func _stop_player() -> void:
	if _player != null:
		_player.stop()


## Limpia la pose que dejó el último frame reproducido. Sin esto, al detener
## el AnimationPlayer los huesos quedan "congelados" (y el NPC parece hundido).
func _reset_skeleton() -> void:
	if _skeleton == null or not is_instance_valid(_skeleton):
		return
	_skeleton.reset_bone_poses()


# --------------------------------------------------------------------------
# Alineación / POI
# --------------------------------------------------------------------------

## Alineación directa (cuerpo al POI). Se usa cuando el NPC ya está en el POI
## o cuando la distancia es demasiado grande para un desplazamiento suave.
func _align_to_poi(poi: Transform3D) -> void:
	if _npc == null:
		return
	if _visual != null and _visual_base_captured:
		_visual.position = _visual_base_position
	_npc.set_frozen(true)
	_npc.set_collision_enabled(false)
	_npc.teleport_to(poi)


## Alineación suave: el cuerpo se queda en el punto de llegada y sólo el modelo
## se desplaza hasta el POI. Así el NPC empieza la animación recién cuando ya
## caminó hasta el mueble, sin teletransportarse.
func _begin_alignment(poi: Transform3D) -> void:
	if _npc == null or _visual == null or not _visual_base_captured:
		return

	_npc.set_frozen(true)
	_npc.set_collision_enabled(false)
	_kill_align_tween()

	# El offset es la diferencia entre el POI y la posición física real
	# (no el marker de aproximación), expresada en el espacio del cuerpo.
	var local_delta := _npc.global_transform.basis.inverse() \
		* (poi.origin - _npc.global_position)
	var target_position := _visual_base_position + local_delta

	var start_yaw := _visual.rotation.y
	var target_yaw := start_yaw
	var forward := -poi.basis.z
	forward.y = 0.0
	if forward.length_squared() > 0.000001:
		forward = forward.normalized()
		target_yaw = atan2(-forward.x, -forward.z)

	if align_duration <= 0.0:
		_visual.position = target_position
		_visual.rotation.y = target_yaw
		return

	var delta_yaw := wrapf(target_yaw - start_yaw, -PI, PI)
	_align_tween = create_tween()
	_align_tween.set_parallel(true)
	_align_tween.set_ease(Tween.EASE_OUT)
	_align_tween.set_trans(Tween.TRANS_SINE)
	_align_tween.tween_property(
		_visual, "position", target_position, align_duration
	)
	_align_tween.tween_method(
		func(value: float) -> void: _visual.rotation.y = value,
		start_yaw,
		start_yaw + delta_yaw,
		align_duration
	)


func _restore_pose() -> void:
	if _npc == null or not _has_poi:
		return
	if _visual != null and _visual_base_captured:
		_visual.position = _visual_base_position
	if not _soft_align:
		_npc.teleport_to(_exit_transform)
	_npc.set_collision_enabled(true)


# --------------------------------------------------------------------------
# Retargeting
# --------------------------------------------------------------------------

func _get_clip(
	source: String,
	clip: StringName,
	phase: StringName,
	loop: bool
) -> StringName:
	var data := _get_source_data(source)
	if data.is_empty():
		push_warning("NpcAnimationManager: no se pudo cargar '%s'" % source)
		return StringName()

	var clips: Dictionary = data["clips"]
	if clips.is_empty():
		return StringName()

	var resolved := String(clip)
	if resolved == "" or not clips.has(resolved):
		resolved = String(clips.keys()[0])

	var key := "%s|%s|%s" % [source, resolved, str(loop)]
	if _name_by_key.has(key):
		return _name_by_key[key]

	var converted := _build_animation(source, resolved, loop)
	if converted == null:
		return StringName()

	var base := "%s_%s" % [resolved, phase]
	var anim_name := base
	if _key_by_name.has(anim_name) and _key_by_name[anim_name] != key:
		anim_name = "%s_%d" % [base, absi(source.hash())]

	var library := _player.get_animation_library("")
	if library == null:
		_player.add_animation_library("", AnimationLibrary.new())
		library = _player.get_animation_library("")
	library.add_animation(anim_name, converted)
	_name_by_key[key] = anim_name
	_key_by_name[anim_name] = key
	return anim_name


func _get_source_data(path: String) -> Dictionary:
	if _sources.has(path):
		return _sources[path]
	if not ResourceLoader.exists(path):
		return {}

	var packed := load(path) as PackedScene
	if packed == null:
		return {}

	var instance := packed.instantiate()
	var player := _find_animation_player(instance)
	if player == null:
		instance.free()
		return {}

	var clips: Dictionary = {}
	for anim_name in player.get_animation_list():
		clips[String(anim_name)] = player.get_animation(anim_name)

	var rests: Dictionary = {}
	_collect_rests(instance, rests)

	instance.free()
	var data := {"clips": clips, "rests": rests}
	_sources[path] = data
	return data


func _build_animation(source: String, clip_name: String, loop: bool) -> Animation:
	var data := _get_source_data(source)
	var clips: Dictionary = data["clips"]
	var rests: Dictionary = data["rests"]
	var source_anim := clips[clip_name] as Animation
	if source_anim == null:
		return null

	var hips_index := _hips_index()
	var root_bone := _skeleton.get_bone_name(hips_index) if hips_index >= 0 else ""
	var source_root_rest: Transform3D = rests.get(root_bone, Transform3D.IDENTITY)
	var target_root_rest := _skeleton.get_bone_rest(hips_index) if hips_index >= 0 else Transform3D.IDENTITY
	var position_scale := 1.0
	if source_root_rest.origin.length_squared() > 0.000001:
		position_scale = target_root_rest.origin.length() / source_root_rest.origin.length()

	var anim := Animation.new()
	anim.length = source_anim.length
	anim.step = source_anim.step
	anim.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE

	for track in source_anim.get_track_count():
		var type := source_anim.track_get_type(track)
		if type not in [
			Animation.TYPE_POSITION_3D,
			Animation.TYPE_ROTATION_3D,
			Animation.TYPE_SCALE_3D,
		]:
			continue

		var bone := _track_bone_name(source_anim.track_get_path(track))
		var bone_index := _skeleton.find_bone(bone)
		if bone_index < 0:
			continue

		var new_track := anim.add_track(type)
		anim.track_set_path(
			new_track,
			NodePath("%s:%s" % [String(_skeleton_path), bone])
		)
		anim.track_set_enabled(new_track, true)
		anim.track_set_interpolation_type(
			new_track, source_anim.track_get_interpolation_type(track)
		)
		anim.track_set_interpolation_loop_wrap(
			new_track, source_anim.track_get_interpolation_loop_wrap(track)
		)

		var bone_rest := _skeleton.get_bone_rest(bone_index)
		var source_rest: Transform3D = rests.get(bone, Transform3D.IDENTITY)
		var key_count := source_anim.track_get_key_count(track)
		for key in key_count:
			var time := source_anim.track_get_key_time(track, key)
			var value: Variant = source_anim.track_get_key_value(track, key)
			if type == Animation.TYPE_POSITION_3D:
				var offset: Vector3 = (value as Vector3) - source_rest.origin
				value = bone_rest.origin + offset * position_scale
			anim.track_insert_key(new_track, time, value)

	return anim


func _track_bone_name(path: NodePath) -> String:
	var text := String(path)
	var colon := text.rfind(":")
	if colon >= 0:
		return text.substr(colon + 1)
	var slash := text.rfind("/")
	if slash >= 0:
		return text.substr(slash + 1)
	return text


func _hips_index() -> int:
	if _skeleton == null or _skeleton.get_bone_count() == 0:
		return -1
	return 0


# --------------------------------------------------------------------------
# Nodos
# --------------------------------------------------------------------------

func _resolve_nodes() -> void:
	_npc = _find_ancestor_npc()
	if _npc == null:
		return

	_visual = _resolve_visual()
	if _visual == null:
		return
	if not _visual_base_captured:
		_visual_base_position = _visual.position
		_visual_base_captured = true

	_skeleton = _find_skeleton(_visual)
	if _skeleton == null:
		return

	_human = _find_human_root(_visual, _skeleton)
	if _human == null:
		var parent := _skeleton.get_parent()
		if parent is Node3D:
			_human = parent as Node3D
	if _human == null:
		return

	_skeleton_path = _human.get_path_to(_skeleton)


func _resolve_visual() -> Node3D:
	if not visual_path.is_empty():
		var node := get_node_or_null(visual_path)
		if node is Node3D:
			return node as Node3D
	if _npc != null:
		var node := _npc.get_node_or_null("Visual")
		if node is Node3D:
			return node as Node3D
	return null


func _find_ancestor_npc() -> NpcAgent:
	var node := get_parent()
	while node != null:
		if node is NpcAgent:
			return node as NpcAgent
		node = node.get_parent()
	return null


func _find_human_root(visual: Node3D, skeleton: Skeleton3D) -> Node3D:
	for child in visual.get_children():
		if child is Node3D and child.is_ancestor_of(skeleton):
			return child as Node3D
	return null


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found != null:
			return found
	return null


func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer
	for child in node.get_children():
		var found := _find_animation_player(child)
		if found != null:
			return found
	return null


func _collect_rests(node: Node, out: Dictionary) -> void:
	if node is Node3D:
		out[String(node.name)] = (node as Node3D).transform
	for child in node.get_children():
		_collect_rests(child, out)


func _ensure_player() -> bool:
	if _player != null and is_instance_valid(_player):
		return true
	if _human == null:
		return false

	_player = AnimationPlayer.new()
	_player.name = String(player_name)
	_human.add_child(_player)
	# Las rutas de track quedan relativas al modelo humano, igual que las del
	# AnimationPlayer original del GLB ("Armature/Skeleton3D:hueso").
	_player.root_node = NodePath("..")
	_player.add_animation_library("", AnimationLibrary.new())
	_player.animation_finished.connect(_on_animation_finished)
	return true
