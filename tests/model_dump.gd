extends SceneTree

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	for path in [
		"res://models/build/construccion/wall_basic.blend",
		"res://models/build/construccion/wall_basic_DER.blend",
		"res://models/build/construccion/wall_basic_IZQ.blend",
	]:
		var scene = load(path)
		var inst = scene.instantiate()
		get_root().add_child(inst)
		print("=== ", path)
		_dump(inst, 0)
		inst.queue_free()
	quit(0)

func _dump(node, depth):
	for i in range(depth):
		prints("  ")
	print(node.get_class(), node.name, "transform=", node.transform if node is Node3D else "")
	for c in node.get_children():
		_dump(c, depth+1)
