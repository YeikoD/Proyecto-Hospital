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
		var mi = _find_mesh(inst)
		print(path)
		print("  mesh transform=", mi.transform)
		print("  mesh aabb=", mi.mesh.get_aabb())
		print("  mesh aabb (global)=", mi.global_transform * mi.mesh.get_aabb())
		inst.queue_free()
	quit(0)

func _find_mesh(node):
	if node is MeshInstance3D:
		return node
	for c in node.get_children():
		var r = _find_mesh(c)
		if r != null:
			return r
	return null
