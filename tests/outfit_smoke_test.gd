extends SceneTree

## Prueba del sistema modular de atuendo:
## - las piezas GLB estaticas se transforman y se pesan al esqueleto del NPC;
## - se ocultan las partes base del cuerpo;
## - al limpiar el atuendo, las partes base vuelven a mostrarse.

var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	SmartObjectRegistry.clear()
	var outfit_res := load("res://data/outfits/atuendo_servicio.tres") as Resource
	_check(outfit_res != null, "carga el atuendo de servicio")
	_check(outfit_res != null and outfit_res.get("pieces") != null
			and outfit_res.get("pieces").size() == 2,
		"el atuendo tiene dos piezas")

	var npc := _spawn_npc()
	var component := npc.get_node("Outfit")
	_check(component != null and component.has_method("apply_outfit"),
		"el NPC trae el componente de atuendo")
	if component == null:
		_finish()
		return
	component.call("apply_outfit", outfit_res)
	await process_frame
	await process_frame

	var base_torso := npc.find_child("torso", true, false) as MeshInstance3D
	var base_legs := npc.find_child("piernas", true, false) as MeshInstance3D
	_check(base_torso != null and not base_torso.visible,
		"se oculta el torso base")
	_check(base_legs != null and not base_legs.visible,
		"se ocultan las piernas base")

	var tunic := npc.find_child("Outfit_torso", true, false) as MeshInstance3D
	var pants := npc.find_child("Outfit_legs", true, false) as MeshInstance3D
	_check(tunic != null, "se equipa la tunica")
	_check(pants != null, "se equipa el pantalon")
	_check(tunic != null and tunic.get_parent() is Skeleton3D,
		"la tunica cuelga del esqueleto")
	_check(pants != null and pants.get_parent() is Skeleton3D,
		"el pantalon cuelga del esqueleto")
	_check(tunic != null and tunic.skin != null and tunic.skeleton == NodePath(".."),
		"la tunica usa el skin del esqueleto")
	_check(pants != null and pants.skin != null and pants.skeleton == NodePath(".."),
		"el pantalon usa el skin del esqueleto")

	if tunic != null and tunic.mesh != null:
		var arrays := tunic.mesh.surface_get_arrays(0)
		var bones = arrays[Mesh.ARRAY_BONES]
		var weights = arrays[Mesh.ARRAY_WEIGHTS]
		_check(bones != null and bones.size() > 0,
			"la tunica tiene huesos asignados")
		_check(weights != null and weights.size() == bones.size(),
			"la tunica tiene pesos asignados")
		if base_torso != null:
			var aabb := tunic.mesh.get_aabb()
			var base_aabb := base_torso.mesh.get_aabb()
			_check(absf(aabb.get_center().y - base_aabb.get_center().y) < 0.25,
				"la tunica queda alineada en altura con el torso")
			_check(absf(aabb.size.y - base_aabb.size.y) < 0.25,
				"la tunica tiene una escala compatible con el torso")

	if pants != null and pants.mesh != null:
		var arrays := pants.mesh.surface_get_arrays(0)
		_check(arrays[Mesh.ARRAY_BONES] != null
				and arrays[Mesh.ARRAY_BONES].size() > 0,
			"el pantalon tiene huesos asignados")
		if base_legs != null:
			var aabb := pants.mesh.get_aabb()
			var base_aabb := base_legs.mesh.get_aabb()
			_check(absf(aabb.get_center().y - base_aabb.get_center().y) < 0.25,
				"el pantalon queda alineado en altura con las piernas")
			_check(absf(aabb.size.y - base_aabb.size.y) < 0.25,
				"el pantalon tiene una escala compatible con las piernas")

	component.call("clear")
	await process_frame
	await process_frame
	_check(base_torso != null and base_torso.visible,
		"al quitar el atuendo vuelve el torso base")
	_check(base_legs != null and base_legs.visible,
		"al quitar el atuendo vuelven las piernas base")
	_check(npc.find_child("Outfit_torso", true, false) == null,
		"la tunica se retira")
	_check(npc.find_child("Outfit_legs", true, false) == null,
		"el pantalon se retira")

	# Un segundo NPC reutiliza la malla cacheada sin errores.
	var npc2 := _spawn_npc()
	var component2 := npc2.get_node("Outfit")
	component2.call("apply_outfit", outfit_res)
	await process_frame
	_check(npc2.find_child("Outfit_torso", true, false) != null,
		"un segundo NPC tambien recibe el atuendo")
	npc.queue_free()
	npc2.queue_free()
	_finish()


func _spawn_npc() -> Node3D:
	var npc := (load("res://scripts/characters/npc/npc.tscn") as PackedScene) \
		.instantiate() as Node3D
	get_root().add_child(npc)
	return npc


func _check(condition: bool, message: String) -> void:
	if condition:
		print("OK: ", message)
	else:
		_failures += 1
		printerr("FALLO: ", message)


func _finish() -> void:
	if _failures == 0:
		print("OUTFIT_SMOKE_TEST_OK")
		quit(0)
	else:
		printerr("OUTFIT_SMOKE_TEST_FAILED: ", _failures)
		quit(1)
