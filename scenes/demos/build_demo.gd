extends Node3D

## Configuración de SmartObjects para la demo de construcción.
##
## Activa los cerebros de los NPC presentes y les sube la necesidad de descanso
## para que busquen las sillas animadas colocadas en la escena.


func _ready() -> void:
	# El hospital usa NavMesh sobre todo el mapa para que los spawner lejanos
	# (terreno, patio) sean caminables. Se fuerza aqui (y no solo en la escena)
	# para que persista aunque el editor re-serialize la escena.
	var nav := get_node_or_null("BuildSystem/BuildNavigation") as BuildNavigation
	if nav != null:
		nav.include_scene_geometry = true
		nav.call_deferred("bake_now")
	call_deferred("_setup_npcs")


func _setup_npcs() -> void:
	# Dar un par de frames para que los SmartObjects y el NavMesh estén listos.
	await get_tree().physics_frame
	await get_tree().physics_frame

	for node in _collect_npcs(self):
		var brain := node.get_node_or_null("NpcBrain") as NpcBrain
		if brain == null:
			continue
		node.wander = false
		brain.needs = {
			"rest": randf_range(0.7, 1.0),
			"work": randf_range(0.7, 1.0),
		}
		brain.need_growth = {"rest": 0.01, "work": 0.005}
		brain.need_affordances = {"rest": &"sit", "work": &"work"}
		brain.need_threshold = 0.6
		brain.search_radius = 30.0
		brain.set_enabled(true)


func _collect_npcs(node: Node) -> Array[NpcAgent]:
	var result: Array[NpcAgent] = []
	if node is NpcAgent:
		result.append(node as NpcAgent)
	for child in node.get_children():
		result.append_array(_collect_npcs(child))
	return result
