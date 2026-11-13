class_name SpecialObjectLoader
extends RefCounted

## Carga las recetas de objetos especiales de un directorio de recursos.
##
## Es un loader aparte del catalogo de BuildItems para que una receta pueda
## existir aunque el item base se agregue despues, y para mantener los datos de
## combinacion fuera de los items.

const DEFAULT_DIR := "res://data/special_objects"


static func load_defs(dir_path: String = DEFAULT_DIR) -> Array[SpecialObjectDef]:
	var result: Array[SpecialObjectDef] = []
	_collect(dir_path, result)
	result.sort_custom(func(a: SpecialObjectDef, b: SpecialObjectDef) -> bool:
		return String(a.id) < String(b.id)
	)
	return result


static func _collect(dir_path: String, result: Array[SpecialObjectDef]) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name == "." or file_name == "..":
			file_name = dir.get_next()
			continue
		var full_path := dir_path.path_join(file_name)
		if dir.current_is_dir():
			_collect(full_path, result)
		else:
			var lower := file_name.to_lower()
			if lower.ends_with(".tres") or lower.ends_with(".res"):
				var res := ResourceLoader.load(full_path, "", ResourceLoader.CACHE_MODE_REUSE)
				if res is SpecialObjectDef:
					var def := res as SpecialObjectDef
					if def.is_valid():
						result.append(def)
		file_name = dir.get_next()
	dir.list_dir_end()
