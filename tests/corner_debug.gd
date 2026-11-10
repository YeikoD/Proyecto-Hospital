extends SceneTree

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var scene = load("res://scenes/demo/nav_demo.tscn")
	var demo = scene.instantiate()
	get_root().add_child(demo)
	await process_frame
	await process_frame
	var controller = demo.get_node("BuildSystem/BuildController")
	print("wall_count=", controller.get_wall_count())
	for key in controller._walls.keys():
		var piece = controller._walls[key]
		var mi = piece.get_node_or_null("MeshInstance3D")
		print("key=", key, "mesh=", mi.mesh.get_class() if mi and mi.mesh else "NONE", mi.mesh.resource_path if mi and mi.mesh else "")
	quit(0)
