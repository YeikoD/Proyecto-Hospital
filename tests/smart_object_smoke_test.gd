extends SceneTree

## Prueba del sistema SmartObject + colocación de objetos.
## Ejecutar:
##   Godot --headless --path . --script res://tests/smart_object_smoke_test.gd

var _failures := 0
var _interaction_started := false
var _interaction_finished := false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	SmartObjectRegistry.clear()

	var scene: PackedScene = load("res://scenes/demos/nav_demo.tscn")
	if scene == null:
		_fail("no se pudo cargar scenes/demos/nav_demo.tscn")
		quit(1)
		return

	var demo := scene.instantiate() as Node3D
	get_root().add_child(demo)
	await process_frame

	var controller: BuildController = demo.get_node("BuildSystem/BuildController")
	var nav: BuildNavigation = demo.get_node("BuildSystem/BuildNavigation")
	var map := demo.get_world_3d().navigation_map

	# --- Catálogo ---------------------------------------------------------
	var item := load("res://data/build_items/muebles/furniture_chair.tres") as BuildItem
	_check(item != null, "carga el item silla")
	_check(item.smart_object != null, "el item declara un SmartObjectDef")
	_check(item.scene != null, "el item tiene escena 3D")
	_check(item.is_placeable_now(), "la silla es colocable")

	# --- Fase 0: colocación ----------------------------------------------
	var floors_before := controller.get_floor_count()
	_check(controller.place_object_item(item, Vector2i(6, 4), 0),
		"coloca la silla sobre un suelo existente")
	_check(controller.get_object_count() == 1, "cuenta un objeto")
	_check(controller.get_floor_count() == floors_before,
		"colocar un objeto no agrega suelos")
	_check(not controller.place_object_item(item, Vector2i(6, 4), 0),
		"no permite superponer objetos")
	_check(not controller.place_object_item(item, Vector2i(0, 0), 0),
		"no permite colocar fuera de un suelo")

	var obj := controller.get_object_at(Vector2i(6, 4)) as SmartObject
	_check(obj != null, "el objeto colocado es un SmartObject")
	_check(obj.get_slot_count() >= 1, "la silla expone al menos un slot")

	# --- Affordances y reservas ------------------------------------------
	var affordance := obj.get_affordance(&"sit")
	_check(affordance != null, "la silla anuncia la affordance 'sit'")
	_check(obj.has_free_slot(&"sit"), "el slot empieza libre")
	_check(affordance.animation_set != null,
		"la affordance 'sit' trae secuencia de animación")

	# POI: el NPC se alinea delante del asiento, no en el centro del collider.
	var poi := obj.get_poi_transform(0)
	var approach := obj.get_approach_transform(0)
	_check(absf(poi.origin.y - obj.global_position.y) < 0.01,
		"el POI queda a nivel del suelo")
	_check(poi.origin.distance_to(obj.get_use_position(0)) > 0.2,
		"el POI está separado del centro del asiento")
	_check(approach.origin.distance_to(poi.origin) > 0.2,
		"hay un punto de salida distinto del POI")

	var slot_a := obj.reserve(&"sit", 1)
	_check(slot_a >= 0, "el agente 1 reserva el slot")
	_check(obj.reserve(&"sit", 2) == -1, "el agente 2 no puede reservar el mismo slot")
	_check(obj.get_slot_owner(slot_a) == 1, "el slot recuerda a su dueño")

	_check(SmartObjectRegistry.claim_best(
		&"sit", obj.global_position, 10.0, 3
	).is_empty(), "el registry no ofrece un slot ya reservado")

	obj.release(slot_a, 1)
	_check(obj.has_free_slot(&"sit"), "liberar deja el slot libre")
	_check(obj.reserve(&"sit", 2) >= 0, "otro agente puede reservar después")
	obj.release_agent(2)
	_check(obj.has_free_slot(&"sit"), "release_agent libera al dueño")

	var claimed := SmartObjectRegistry.claim_best(
		&"sit", obj.global_position, 10.0, 42
	)
	_check(not claimed.is_empty(), "el registry reclama un slot libre")
	if not claimed.is_empty():
		claimed["object"].release(int(claimed["slot"]), 42)
	_check(obj.has_free_slot(&"sit"), "el claim del registry se puede liberar")

	# --- Rebake: el collider del mueble debe entrar al NavMesh ------------
	var bakes_before := nav.bake_count
	var deadline := Time.get_ticks_msec() + 5000
	while nav.bake_count <= bakes_before and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(nav.bake_count > bakes_before, "colocar el objeto dispara un rebake")

	for i in 8:
		await physics_frame
	NavigationServer3D.map_force_update(map)
	await physics_frame

	# --- Integración: el cerebro reserva, viaja, usa y libera -------------
	var npc := demo.get_node("NPCs/NPC1") as NpcAgent
	var brain := npc.get_node("NpcBrain") as NpcBrain
	_check(brain != null, "el NPC trae un NpcBrain")
	var anim_manager := npc.get_animation_manager()
	_check(anim_manager != null, "el NPC trae un NpcAnimationManager")

	# Interacción corta para no alargar el test.
	affordance.duration = 1.0
	brain.needs = {"rest": 1.0}
	brain.need_growth = {"rest": 0.0}
	brain.interaction_started.connect(_on_interaction_started)
	brain.interaction_finished.connect(_on_interaction_finished)
	brain.set_enabled(true)

	deadline = Time.get_ticks_msec() + 15000
	while not _interaction_started and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(_interaction_started, "el NPC llega y empieza a usar la silla")
	_check(not obj.has_free_slot(&"sit"), "el slot queda ocupado durante el uso")
	var body_at_use := npc.global_position

	# La animación de entrada lleva al loop sentado.
	var loop_deadline := Time.get_ticks_msec() + 8000
	while anim_manager != null and anim_manager.get_phase() != &"loop" \
			and Time.get_ticks_msec() < loop_deadline:
		await process_frame
	_check(anim_manager != null and anim_manager.get_phase() == &"loop",
		"la silla encadena enter -> loop")
	_check(npc.global_position.distance_to(body_at_use) < 0.02,
		"el cuerpo del NPC no se teletransporta al sentarse")

	if anim_manager != null:
		var skeleton := anim_manager.get_skeleton()
		if skeleton != null:
			var hips := skeleton.find_bone("mixamorig_Hips")
			var hip_world := skeleton.global_transform \
				* skeleton.get_bone_global_pose(hips).origin
			var seat := obj.get_use_position(0)
			_check(Vector2(hip_world.x - seat.x, hip_world.z - seat.z).length() < 0.2,
				"la cadera queda sobre el asiento")
			_check(hip_world.y > seat.y and hip_world.y < seat.y + 0.35,
				"la altura sentada cae sobre el asiento")

	deadline = Time.get_ticks_msec() + 15000
	while not _interaction_finished and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(_interaction_finished, "el NPC termina la interacción")
	_check(obj.has_free_slot(&"sit"), "el NPC libera el slot al terminar")
	_check(float(brain.needs["rest"]) < 1.0, "la interacción reduce la necesidad")
	_check(npc.global_position.distance_to(approach.origin) < 0.3,
		"el NPC termina en el punto de salida")

	# --- Borrado ----------------------------------------------------------
	_check(controller.erase_at(Vector2i(6, 4), Vector3i(6, 4, 0)),
		"borra el objeto con la herramienta")
	_check(controller.get_object_count() == 0, "ya no quedan objetos")
	await process_frame
	_check(SmartObjectRegistry.get_count() == 0, "el registry queda vacío al borrar")

	if _failures == 0:
		print("SMART_OBJECT_SMOKE_TEST_OK")
		quit(0)
	else:
		printerr("SMART_OBJECT_SMOKE_TEST_FAILED: %d fallo(s)" % _failures)
		quit(1)


func _on_interaction_started(_object: Node, _affordance: AffordanceDef) -> void:
	_interaction_started = true


func _on_interaction_finished(_object: Node, _affordance: AffordanceDef) -> void:
	_interaction_finished = true


func _check(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	_failures += 1
	printerr("FALLO: " + message)
