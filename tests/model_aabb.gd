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
		if scene == null:
			print("FAIL load", path)
			continue
		var inst = scene.instantiate()
		get_root().add_child(inst)
		var aabb = _compute_aabb(inst)
		print(path, "-> AABB pos=", aabb.position, " size=", aabb.size)
		inst.queue_free()
	quit(0)

func _compute_aabb(node: Node) -> AABB:
	var aabb := AABB()
	var first := true
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			var local := mi.get_aabb()
			var t := mi.global_transform
			var corners := [
				t * local.position,
				t * (local.position + Vector3(local.size.x, 0, 0)),
				t * (local.position + Vector3(0, local.size.y, 0)),
				t * (local.position + Vector3(0, 0, local.size.z)),
				t * (local.position + Vector3(local.size.x, local.size.y, 0)),
				t * (local.position + Vector3(local.size.x, 0, local.size.z)),
				t * (local.position + Vector3(0, local.size.y, local.size.z)),
				t * (local.position + local.size),
			]
			for c in corners:
				if first:
					aabb.position = c
					aabb.size = Vector3.ZERO
					first = false
				else:
					aabb = aabb.expand(c)
	for child in node.get_children():
		var child_aabb := _compute_aabb(child)
		if child_aabb.size != Vector3.ZERO or child_aabb.position != Vector3.ZERO:
			if first:
				aabb = child_aabb
				first = false
			else:
				aabb = aabb.merge(child_aabb)
	return aabb
