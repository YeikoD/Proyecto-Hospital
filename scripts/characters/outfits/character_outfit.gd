class_name CharacterOutfit
extends Node

## Sistema modular de atuendo.
##
## Toma un `OutfitDef`, instancia cada pieza, la transforma al espacio del
## esqueleto del personaje y le transfiere los pesos de la parte base que
## reemplaza. Asi las piezas estaticas exportadas desde Blender se deforman con
## las animaciones del NPC.
##
## Uso:
##   var outfit := get_node("Outfit") as CharacterOutfit
##   outfit.apply_outfit(load("res://data/outfits/atuendo_servicio.tres"))
##
## El nodo se coloca como hijo del NPC y apunta a `Visual` (que contiene el
## modelo `human.glb`). Cada pieza oculta el MeshInstance3D base indicado.

@export var visual_path: NodePath = ^"../Visual"
@export var outfit: Resource
## Aplica `outfit` solo al entrar al arbol.
@export var auto_apply := true
@export var debug := false

## Cache de mallas ya transformadas/pesadas. La clave incluye la malla de la
## pieza y la parte base; se comparte entre todos los NPCs.
static var _mesh_cache: Dictionary = {}

var _visual: Node3D
var _skeleton: Skeleton3D
## slot -> {node, base, was_visible}
var _applied: Dictionary = {}


func _ready() -> void:
	if auto_apply and outfit != null:
		apply_outfit(outfit)


## Aplica un conjunto completo. Reemplaza lo que hubiera equipado antes.
func apply_outfit(def: Resource) -> void:
	outfit = def
	clear()
	if def == null:
		return
	_resolve_targets()
	if _skeleton == null:
		push_warning("CharacterOutfit: no encontre Skeleton3D en %s" % get_path())
		return
	var pieces = def.get("pieces")
	if pieces == null:
		return
	for piece in pieces:
		if piece != null:
			equip_piece(piece)


## Equipa una sola pieza.
func equip_piece(piece: Resource) -> bool:
	if piece == null:
		return false
	var scene := piece.get("scene") as PackedScene
	if scene == null:
		return false
	_resolve_targets()
	if _skeleton == null:
		return false
	var slot := StringName(piece.get("slot"))
	var base_name := StringName(piece.get("base_part"))
	if slot == &"" and base_name == &"":
		push_warning("CharacterOutfit: pieza sin slot/base_part.")
		return false
	if slot == &"":
		slot = base_name
	if base_name == &"":
		base_name = slot
	if _applied.has(slot):
		unequip(slot)

	var base := _find_mesh(_skeleton, String(base_name))
	if base == null or base.mesh == null:
		push_warning("CharacterOutfit: no encontre la parte base '%s'." % base_name)
		return false
	var base_skin: Skin = base.skin
	if base_skin == null:
		var reference := base.get_skin_reference()
		if reference != null:
			base_skin = reference.get_skin()
	if base_skin == null:
		push_warning("CharacterOutfit: '%s' no tiene Skin." % base_name)
		return false

	var instance: Node = scene.instantiate()
	var outfit_mesh := _find_first_mesh(instance)
	if outfit_mesh == null or outfit_mesh.mesh == null:
		instance.free()
		push_warning("CharacterOutfit: la pieza '%s' no tiene MeshInstance3D." % slot)
		return false

	# Transformacion de la pieza hasta su raiz, y luego al espacio local de la
	# parte base (que es el que usan sus huesos/pesos).
	var to_root := _relative_transform(outfit_mesh, instance)
	var local_xform := base.transform.affine_inverse() * to_root
	var skinned := _get_skinned_mesh(outfit_mesh.mesh, local_xform, base)
	instance.free()
	if skinned == null:
		return false

	var node := MeshInstance3D.new()
	node.name = "Outfit_%s" % String(slot)
	node.mesh = skinned
	node.skin = base_skin
	node.skeleton = NodePath("..")
	node.transform = base.transform
	node.custom_aabb = base.get_aabb().grow(0.4)
	node.extra_cull_margin = 2.0
	var was_visible := base.visible
	_skeleton.add_child(node)
	base.visible = false
	_applied[slot] = {
		"node": node,
		"base": base,
		"was_visible": was_visible,
	}
	if debug:
		print("[CharacterOutfit] equipado ", slot, " (", scene.resource_path, ")")
	return true


func unequip(slot: StringName) -> void:
	if not _applied.has(slot):
		return
	var entry: Dictionary = _applied[slot]
	var node := entry.get("node") as Node
	if node != null and is_instance_valid(node):
		node.queue_free()
	var base := entry.get("base") as MeshInstance3D
	if base != null and is_instance_valid(base):
		base.visible = bool(entry.get("was_visible", true))
	_applied.erase(slot)


func clear() -> void:
	for slot in _applied.keys():
		unequip(slot)


func get_equipped_slots() -> Array[StringName]:
	var out: Array[StringName] = []
	for slot in _applied.keys():
		out.append(slot)
	return out


func has_slot(slot: StringName) -> bool:
	return _applied.has(slot)


# --------------------------------------------------------------------------
# Malla: transformacion + transferencia de pesos
# --------------------------------------------------------------------------

## Devuelve una ArrayMesh con los vertices transformados y los huesos/pesos
## copiados de la parte base mas cercana. Cachea por malla + transformacion.
func _get_skinned_mesh(
	source: Mesh, local_xform: Transform3D, base: MeshInstance3D
) -> ArrayMesh:
	if source == null or base == null or base.mesh == null:
		return null
	if source.get_surface_count() == 0 or base.mesh.get_surface_count() == 0:
		return null
	var key := "%s|%s|%s" % [
		source.resource_path,
		base.mesh.resource_path,
		var_to_str(local_xform),
	]
	if _mesh_cache.has(key):
		return _mesh_cache[key] as ArrayMesh

	var base_arrays := base.mesh.surface_get_arrays(0)
	var out_arrays := source.surface_get_arrays(0)
	var base_verts: PackedVector3Array = base_arrays[Mesh.ARRAY_VERTEX]
	var base_bones: PackedInt32Array = base_arrays[Mesh.ARRAY_BONES]
	var base_weights: PackedFloat32Array = base_arrays[Mesh.ARRAY_WEIGHTS]
	var out_verts: PackedVector3Array = out_arrays[Mesh.ARRAY_VERTEX]
	if base_verts.is_empty() or base_bones.is_empty() \
			or base_weights.is_empty() or out_verts.is_empty():
		push_warning("CharacterOutfit: malla base sin bones/weights.")
		return null
	if base_bones.size() < base_verts.size() * 4 \
			or base_weights.size() < base_verts.size() * 4:
		push_warning("CharacterOutfit: bones/weights con formato inesperado.")
		return null

	# Vertices y normales al espacio local de la parte base.
	var verts := PackedVector3Array()
	verts.resize(out_verts.size())
	for i in out_verts.size():
		verts[i] = local_xform * out_verts[i]
	out_arrays[Mesh.ARRAY_VERTEX] = verts

	var normal_matrix := local_xform.basis.inverse().transposed()
	if out_arrays[Mesh.ARRAY_NORMAL] != null:
		var out_normals: PackedVector3Array = out_arrays[Mesh.ARRAY_NORMAL]
		if out_normals.size() == out_verts.size():
			var normals := PackedVector3Array()
			normals.resize(out_normals.size())
			for i in out_normals.size():
				normals[i] = (normal_matrix * out_normals[i]).normalized()
			out_arrays[Mesh.ARRAY_NORMAL] = normals
	if out_arrays[Mesh.ARRAY_TANGENT] != null:
		var out_tangents: PackedFloat32Array = out_arrays[Mesh.ARRAY_TANGENT]
		if out_tangents.size() == out_verts.size() * 4:
			var tangents := PackedFloat32Array()
			tangents.resize(out_tangents.size())
			for i in out_verts.size():
				var t := Vector3(
					out_tangents[i * 4], out_tangents[i * 4 + 1],
					out_tangents[i * 4 + 2]).normalized()
				t = (local_xform.basis * t).normalized()
				tangents[i * 4] = t.x
				tangents[i * 4 + 1] = t.y
				tangents[i * 4 + 2] = t.z
				tangents[i * 4 + 3] = out_tangents[i * 4 + 3]
			out_arrays[Mesh.ARRAY_TANGENT] = tangents

	# Pesos: para cada vertice de la ropa se copian los del vertice mas cercano
	# de la parte base. Es una transferencia simple y estable para ropa pegada.
	var bones := PackedInt32Array()
	bones.resize(out_verts.size() * 4)
	var weights := PackedFloat32Array()
	weights.resize(out_verts.size() * 4)
	for i in verts.size():
		var best := -1
		var best_distance := INF
		var v := verts[i]
		for j in base_verts.size():
			var distance := v.distance_squared_to(base_verts[j])
			if distance < best_distance:
				best_distance = distance
				best = j
		if best < 0:
			continue
		for k in 4:
			bones[i * 4 + k] = base_bones[best * 4 + k]
			weights[i * 4 + k] = base_weights[best * 4 + k]
	out_arrays[Mesh.ARRAY_BONES] = bones
	out_arrays[Mesh.ARRAY_WEIGHTS] = weights

	var result := ArrayMesh.new()
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out_arrays)
	result.surface_set_material(0, source.surface_get_material(0))
	_mesh_cache[key] = result
	if debug:
		print("[CharacterOutfit] malla pesada: ", source.resource_path,
			" verts=", verts.size())
	return result


# --------------------------------------------------------------------------
# Busquedas
# --------------------------------------------------------------------------

func _resolve_targets() -> void:
	if _visual == null or not is_instance_valid(_visual):
		_visual = get_node_or_null(visual_path) as Node3D
	if _visual == null:
		return
	if _skeleton == null or not is_instance_valid(_skeleton):
		_skeleton = _find_skeleton(_visual)


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found != null:
			return found
	return null


func _find_mesh(root: Node, mesh_name: String) -> MeshInstance3D:
	var node := root.find_child(mesh_name, true, false)
	return node as MeshInstance3D


func _find_first_mesh(root: Node) -> MeshInstance3D:
	if root is MeshInstance3D:
		return root as MeshInstance3D
	for child in root.get_children():
		var found := _find_first_mesh(child)
		if found != null:
			return found
	return null


## Transformacion desde `node` hasta `root` (incluyendo la raiz).
func _relative_transform(node: Node, root: Node) -> Transform3D:
	var xform := Transform3D.IDENTITY
	var current := node
	while current != null:
		if current is Node3D:
			xform = (current as Node3D).transform * xform
		if current == root:
			break
		current = current.get_parent()
	return xform
