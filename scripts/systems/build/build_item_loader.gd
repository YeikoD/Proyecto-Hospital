class_name BuildItemLoader
extends RefCounted

const DEFAULT_DIR := "res://data/build_items"


static func load_items(dir_path: String = DEFAULT_DIR) -> Array[BuildItem]:
	var result: Array[BuildItem] = []
	_collect_items(dir_path, result)

	result.sort_custom(func(a: BuildItem, b: BuildItem) -> bool:
		if a.normalized_category() != b.normalized_category():
			return a.normalized_category() < b.normalized_category()
		if a.normalized_subcategory() != b.normalized_subcategory():
			return a.normalized_subcategory() < b.normalized_subcategory()
		return a.display_name.naturalnocasecmp_to(b.display_name) < 0
	)
	return result


static func _collect_items(dir_path: String, result: Array[BuildItem]) -> void:
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
			_collect_items(full_path, result)
		else:
			var lower := file_name.to_lower()
			if lower.ends_with(".tres") or lower.ends_with(".res"):
				var res := ResourceLoader.load(full_path, "", ResourceLoader.CACHE_MODE_REUSE)
				if res is BuildItem:
					# Si el diseñador no rellenó categoría/subcategoría, usar la carpeta.
					var item := res as BuildItem
					if item.normalized_category() == "":
						item.category = _folder_to_category(dir_path)
					if item.normalized_subcategory() == "":
						item.subcategory = _folder_to_subcategory(dir_path)
					result.append(item)
		file_name = dir.get_next()
	dir.list_dir_end()


static func _folder_to_category(dir_path: String) -> String:
	var base := dir_path.get_file().to_lower()
	match base:
		"construccion", "construction":
			return "construction"
		"muebles", "furniture", "objects":
			return "objects"
		_:
			return "construction"


static func _folder_to_subcategory(dir_path: String) -> String:
	var base := dir_path.get_file().to_lower()
	match base:
		"aberturas", "openings":
			return "openings"
		"paredes", "walls":
			return "walls"
		"suelos", "floors":
			return "floors"
		"muebles", "furniture":
			return "furniture"
		_:
			return "general"