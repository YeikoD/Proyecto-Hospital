extends SceneTree

## Prueba de IA del Escritorio de trabajo: un NPC con necesidad "work" debe
## reservar el objeto especial, usar la animacion de la silla y reducir la
## necesidad al terminar.
## Ejecutar:
##   Godot --headless --path . --script res://tests/work_desk_ai_smoke_test.gd

var _started := false
var _finished := false
var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	SmartObjectRegistry.clear()
	var demo := (load("res://scenes/demos/nav_demo.tscn") as PackedScene).instantiate() as Node3D
	get_root().add_child(demo)
	await process_frame

	var controller: BuildController = demo.get_node("BuildSystem/BuildController")
	var desk := load("res://data/build_items/muebles/furniture_desktop.tres") as BuildItem
	var chair := load("res://data/build_items/muebles/furniture_chair_desktop.tres") as BuildItem
	var patients := load("res://data/build_items/muebles/furniture_patient_chairs.tres") as BuildItem
	_check(desk != null and chair != null and patients != null,
		"carga escritorio, silla y sillas de pacientes")
	_check(controller.place_object_item(desk, Vector2i(6, 5), 0),
		"coloca el escritorio")
	_check(controller.place_object_item(chair, Vector2i(6, 6), 0),
		"coloca la silla mirando al escritorio")
	_check(controller.place_object_item(patients, Vector2i(6, 4), 1),
		"coloca las sillas de pacientes al otro lado")
	await process_frame
	_check(controller.get_special_object_count() == 1,
		"se forma el escritorio de trabajo")
	var special := controller.get_special_object_at(Vector2i(6, 6))
	_check(special != null, "el objeto especial existe")
	_check(special != null and special.has_affordance(&"work"),
		"el objeto especial anuncia 'work'")
	var work := special.get_affordance(&"work") if special != null else null
	if work != null:
		work.duration = 1.0

	var npc := demo.get_node("NPCs/NPC1") as NpcAgent
	# `work` es exclusiva del medico; esta prueba simula uno para verificar la
	# animacion y el uso del Escritorio de trabajo.
	npc.add_to_group(&"doctor_npcs")
	var brain := npc.get_node("NpcBrain") as NpcBrain
	var anim_manager := npc.get_animation_manager()
	_check(brain != null, "el NPC trae NpcBrain")
	_check(anim_manager != null, "el NPC trae NpcAnimationManager")
	if brain == null:
		quit(1)
		return

	brain.needs = {"work": 1.0}
	brain.need_growth = {"work": 0.0}
	brain.need_affordances = {"work": &"work"}
	brain.need_threshold = 0.5
	brain.search_radius = 25.0
	brain.interaction_started.connect(_on_started)
	brain.interaction_finished.connect(_on_finished)
	brain.set_enabled(true)

	var deadline := Time.get_ticks_msec() + 30000
	while not _started and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(_started, "el NPC empieza a usar el escritorio de trabajo")
	_check(brain.get_current_object() == special,
		"el NPC eligio el objeto especial")
	var current := brain.get_current_affordance()
	_check(current != null and current.id == &"work",
		"el NPC usa la affordance 'work'")
	if current != null:
		_check(current.animation_set != null,
			"la affordance 'work' trae la secuencia de animacion")
		_check(current.animation_set == work.animation_set,
			"usa las mismas animaciones que la silla")

	var loop_deadline := Time.get_ticks_msec() + 10000
	while anim_manager != null and anim_manager.get_phase() != &"loop" \
			and Time.get_ticks_msec() < loop_deadline:
		await process_frame
	_check(anim_manager != null and anim_manager.get_phase() == &"loop",
		"el escritorio de trabajo encadena enter -> loop")

	deadline = Time.get_ticks_msec() + 15000
	while not _finished and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(_finished, "el NPC termina de usar el escritorio")
	_check(float(brain.needs.get("work", 1.0)) < 1.0,
		"la interaccion reduce la necesidad 'work'")

	if _failures == 0:
		print("WORK_DESK_AI_OK")
		quit(0)
	else:
		printerr("WORK_DESK_AI_FAILED: ", _failures)
		quit(1)


func _on_started(_object: Node, _affordance: AffordanceDef) -> void:
	_started = true


func _on_finished(_object: Node, _affordance: AffordanceDef) -> void:
	_finished = true


func _check(condition: bool, message: String) -> void:
	if condition:
		print("OK: ", message)
	else:
		_failures += 1
		printerr("FALLO: ", message)
