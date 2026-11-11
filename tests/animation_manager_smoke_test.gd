extends SceneTree

## Prueba del manager de animaciones de interacción (enter -> loop -> exit).
## Ejecutar:
##   Godot --headless --path . --script res://tests/animation_manager_smoke_test.gd

const SET_PATH := "res://data/smart_objects/sit_animations.tres"

var _failures := 0
var _phases: Array[StringName] = []
var _loop_started := false
var _finished := false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var scene: PackedScene = load("res://scripts/Characters/npc/npc.tscn")
	if scene == null:
		_fail("no se pudo cargar npc.tscn")
		quit(1)
		return

	var world := Node3D.new()
	world.name = "World"
	get_root().add_child(world)

	var ground := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	(shape.shape as BoxShape3D).size = Vector3(20, 0.5, 20)
	shape.position.y = -0.25
	ground.add_child(shape)
	world.add_child(ground)

	var npc := scene.instantiate() as NpcAgent
	npc.wander = false
	world.add_child(npc)
	await process_frame

	var manager := npc.get_animation_manager()
	_check(manager != null, "el NPC expone un NpcAnimationManager")
	if manager == null:
		quit(1)
		return

	var skeleton := manager.get_skeleton()
	_check(skeleton != null, "el manager encuentra el Skeleton3D")
	if skeleton == null:
		quit(1)
		return

	var set_res := load(SET_PATH) as SmartAnimationSet
	_check(set_res != null, "carga el SmartAnimationSet de la silla")
	_check(set_res.has_enter() and set_res.has_loop() and set_res.has_exit(),
		"el set declara las tres fases")
	if set_res == null:
		quit(1)
		return

	manager.phase_started.connect(_on_phase_started)
	manager.loop_started.connect(_on_loop_started)
	manager.finished.connect(_on_finished)

	var hips := 0
	for i in skeleton.get_bone_count():
		if skeleton.get_bone_name(i) == "mixamorig_Hips":
			hips = i
			break
	var rest_hip := skeleton.get_bone_pose_position(hips)

	var yaw := PI * 0.5
	var poi := Transform3D(Basis(Vector3.UP, yaw), Vector3(2.0, 0.0, 3.0))
	var exit := Transform3D(Basis(Vector3.UP, yaw), Vector3(2.0, 0.0, 2.0))

	# El NPC llega caminando al Approach; la secuencia no debe mover el cuerpo.
	npc.global_position = exit.origin
	await physics_frame

	var body_start := npc.global_position
	var ok := manager.play_at(set_res, poi, exit)
	_check(ok, "el manager arranca la secuencia")
	_check(manager.is_playing(), "el manager queda activo")
	_check(manager.get_loaded_clip_count() >= 1, "retargeteó el primer clip")
	_check(npc.global_position.distance_to(body_start) < 0.02,
		"el cuerpo no se teletransporta al POI")

	# El modelo se desliza suavemente hasta el POI.
	var visual := npc.get_node("Visual") as Node3D
	var align_deadline := Time.get_ticks_msec() + 3000
	while (visual.global_position.distance_to(poi.origin) > 0.02
			or absf(wrapf(visual.rotation.y - yaw, -PI, PI)) > 0.01) \
			and Time.get_ticks_msec() < align_deadline:
		await process_frame
	_check(visual.global_position.distance_to(poi.origin) < 0.02,
		"el modelo se alinea suavemente al POI")
	_check(absf(wrapf(visual.rotation.y - yaw, -PI, PI)) < 0.01,
		"giró el modelo según el POI")

	# Colisión desactivada (set_deferred aplica en el próximo idle).
	await process_frame
	await process_frame
	var collision := npc.get_node("CollisionShape3D") as CollisionShape3D
	_check(collision.disabled, "desactivó la colisión mientras está sentado")

	# La ruta del track tiene que apuntar al esqueleto del NPC.
	var paths_ok := _check_track_paths(manager)
	_check(paths_ok, "los tracks apuntan a Armature/Skeleton3D:<hueso>")

	var deadline := Time.get_ticks_msec() + 8000
	while not _loop_started and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(_loop_started, "llega al loop natural")
	_check(_phases.has(&"enter"), "pasó por la fase enter")
	_check(manager.get_loaded_clip_count() >= 2, "retargeteó entrada y loop")

	# Dejar que el loop escriba un frame y comprobar que la cadera baja.
	for i in 4:
		await process_frame
	var seated_hip := skeleton.get_bone_pose_position(hips)
	_check(absf(seated_hip.z - rest_hip.z) > 20.0,
		"el loop sentado mueve la cadera (%.1f -> %.1f)" % [rest_hip.z, seated_hip.z])
	_check(absi(skeleton.find_bone("mixamorig_Hips")) >= 0,
		"el clip retargeteado encuentra el hueso de la cadera")

	manager.request_exit()
	var exit_deadline := Time.get_ticks_msec() + 8000
	while not _finished and Time.get_ticks_msec() < exit_deadline:
		await process_frame
	_check(_finished, "termina la secuencia completa")
	_check(_phases.has(&"exit"), "pasó por la fase exit")
	_check(manager.get_loaded_clip_count() == 3, "retargeteó los tres clips")
	_check(not manager.is_playing(), "el manager vuelve a reposo")
	_check(npc.global_position.distance_to(exit.origin) < 0.05,
		"el NPC vuelve al punto de salida")
	await process_frame
	await process_frame
	_check(not collision.disabled, "reactivó la colisión al terminar")

	world.queue_free()
	if _failures == 0:
		print("ANIMATION_MANAGER_SMOKE_TEST_OK")
		quit(0)
	else:
		printerr("ANIMATION_MANAGER_SMOKE_TEST_FAILED: %d fallo(s)" % _failures)
		quit(1)


func _check_track_paths(manager: NpcAnimationManager) -> bool:
	var player := manager.get_animation_player()
	if player == null:
		return false
	for anim_name in player.get_animation_list():
		var anim := player.get_animation(anim_name)
		for t in anim.get_track_count():
			var path := String(anim.track_get_path(t))
			if not path.begins_with("Armature/Skeleton3D:"):
				printerr("track inesperado: ", path)
				return false
	return true


func _on_phase_started(phase: StringName) -> void:
	_phases.append(phase)


func _on_loop_started() -> void:
	_loop_started = true


func _on_finished() -> void:
	_finished = true


func _check(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	_failures += 1
	printerr("FALLO: " + message)
