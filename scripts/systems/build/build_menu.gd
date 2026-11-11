class_name BuildMenu
extends CanvasLayer

## Menú de gameplay para elegir items construibles/colocables.
## Carga automáticamente los recursos `BuildItem` de `items_dir`.

signal item_selected(item: BuildItem)

const TINT_SHADER := preload("res://scripts/systems/build/shaders/menu_tint.gdshader")

@export var items_dir: String = "res://data/build_items"
@export var toggle_key: Key = KEY_M

var items: Array[BuildItem] = []

var _panel: PanelContainer
var _categories: TabContainer
var _status: Label


func _ready() -> void:
	items = BuildItemLoader.load_items(items_dir)
	_ensure_input_action()
	_build_ui()
	visible = false


func _ensure_input_action() -> void:
	if not InputMap.has_action("build_menu_toggle"):
		InputMap.add_action("build_menu_toggle", 0.5)
	var events := InputMap.action_get_events("build_menu_toggle")
	if events.is_empty():
		var ev := InputEventKey.new()
		ev.physical_keycode = toggle_key
		InputMap.action_add_event("build_menu_toggle", ev)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("build_menu_toggle"):
		visible = not visible
		get_viewport().set_input_as_handled()


func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.name = "BuildMenuPanel"
	_panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	_panel.offset_left = -360
	_panel.offset_top = 12
	_panel.offset_right = -12
	_panel.offset_bottom = -12
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	_panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "Construir"
	title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title)

	_status = Label.new()
	_status.text = "%d items cargados" % items.size()
	_status.add_theme_font_size_override("font_size", 12)
	vbox.add_child(_status)

	_categories = TabContainer.new()
	_categories.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_categories)

	_populate_categories()


func _populate_categories() -> void:
	# Agrupar por categoría y subcategoría.
	var by_category: Dictionary = {}
	for item in items:
		var cat := item.normalized_category()
		if cat == "":
			cat = "construir"
		if not by_category.has(cat):
			by_category[cat] = {}
		var sub := item.normalized_subcategory()
		if sub == "":
			sub = "general"
		if not by_category[cat].has(sub):
			by_category[cat][sub] = []
		by_category[cat][sub].append(item)

	# Pestañas principales. "Construir" agrupa la obra base y, en el futuro,
	# pinturas/baldosas. "Objetos" es una pestaña independiente.
	var category_order := ["construir", "objetos"]
	var category_titles := {
		"construir": "Construir",
		"objetos": "Objetos",
	}
	var sub_order := ["base", "pinturas", "baldosas", "aberturas", "muebles", "general"]
	var sub_titles := {
		"base": "Base",
		"pinturas": "Pinturas",
		"baldosas": "Baldosas",
		"aberturas": "Aberturas",
		"muebles": "Muebles",
		"general": "General",
	}

	var added: Dictionary = {}
	for cat in category_order:
		var subs: Dictionary = by_category.get(cat, {})
		_add_category_page(cat, subs, category_titles, sub_order, sub_titles)
		added[cat] = true

	# Cualquier otra categoría definida en datos se añade al final.
	var rest: Array = by_category.keys()
	rest.sort()
	for cat in rest:
		if added.has(cat):
			continue
		_add_category_page(cat, by_category[cat], category_titles, sub_order, sub_titles)

	if _categories.get_child_count() == 0:
		var empty := Label.new()
		empty.text = "No hay items en res://data/build_items"
		_categories.add_child(empty)


func _add_category_page(
	cat: String,
	subs: Dictionary,
	category_titles: Dictionary,
	sub_order: Array,
	sub_titles: Dictionary
) -> void:
	var cat_page := VBoxContainer.new()
	cat_page.name = category_titles.get(cat, _pretty_name(cat))
	_categories.add_child(cat_page)

	var sub_tabs := TabContainer.new()
	sub_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cat_page.add_child(sub_tabs)

	if subs.is_empty():
		var placeholder := Label.new()
		placeholder.text = "No hay elementos en esta sección."
		placeholder.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		placeholder.add_theme_font_size_override("font_size", 13)
		var margin := MarginContainer.new()
		margin.add_theme_constant_override("margin_left", 8)
		margin.add_theme_constant_override("margin_top", 8)
		margin.add_child(placeholder)
		sub_tabs.add_child(margin)
		return

	# Subpestañas futuras de "Construir": siempre visibles como marcadores.
	if cat == "construir":
		if not subs.has("pinturas"):
			subs = subs.duplicate()
			subs["pinturas"] = []
		if not subs.has("baldosas"):
			subs = subs.duplicate() if not subs.has("pinturas") else subs
			subs["baldosas"] = []

	var ordered_subs: Array = []
	for sub in sub_order:
		if subs.has(sub):
			ordered_subs.append(sub)
	var rest_subs: Array = subs.keys()
	rest_subs.sort()
	for sub in rest_subs:
		if sub in ordered_subs:
			continue
		ordered_subs.append(sub)

	for sub in ordered_subs:
		var sub_items: Array = subs[sub]
		var visible_items: Array = []
		for item in sub_items:
			if item != null and item.is_placeable_now():
				visible_items.append(item)

		if visible_items.is_empty():
			var page := MarginContainer.new()
			page.name = sub_titles.get(sub, _pretty_name(sub))
			page.add_theme_constant_override("margin_left", 8)
			page.add_theme_constant_override("margin_top", 8)
			page.add_theme_constant_override("margin_right", 8)
			page.add_theme_constant_override("margin_bottom", 8)
			var placeholder := Label.new()
			match sub:
				"pinturas":
					placeholder.text = "Próximamente: pinturas/materiales para las paredes ya construidas."
				"baldosas":
					placeholder.text = "Próximamente: pinturas/materiales para los suelos ya construidos."
				_:
					placeholder.text = "No hay elementos en esta sección."
			placeholder.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			placeholder.add_theme_font_size_override("font_size", 13)
			page.add_child(placeholder)
			sub_tabs.add_child(page)
			continue

		var page := ScrollContainer.new()
		page.name = sub_titles.get(sub, _pretty_name(sub))
		page.size_flags_vertical = Control.SIZE_EXPAND_FILL
		page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sub_tabs.add_child(page)

		var list := GridContainer.new()
		list.columns = 3
		list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		list.add_theme_constant_override("h_separation", 8)
		list.add_theme_constant_override("v_separation", 8)
		page.add_child(list)

		visible_items.sort_custom(_sort_build_items)
		for item in visible_items:
			var btn := _create_item_tile(item)
			list.add_child(btn)


func _create_item_tile(item: BuildItem) -> Button:
	var title := item.display_name if item.display_name != "" else String(item.id)
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(96, 150)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.tooltip_text = title
	btn.pressed.connect(_on_item_pressed.bind(item))

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 6)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_right", 6)
	margin.add_theme_constant_override("margin_bottom", 6)
	btn.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_theme_constant_override("separation", 4)
	margin.add_child(vbox)

	var icon := TextureRect.new()
	icon.texture = item.preview
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = Vector2(0, 108)
	icon.size_flags_vertical = Control.SIZE_EXPAND_FILL
	icon.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if item.preview_tint != Color.WHITE:
		var tint := ShaderMaterial.new()
		tint.shader = TINT_SHADER
		tint.set_shader_parameter("tint_color", item.preview_tint)
		icon.material = tint
	vbox.add_child(icon)

	var label := Label.new()
	label.text = title
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 12)
	label.custom_minimum_size = Vector2(0, 28)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if item.preview_tint != Color.WHITE:
		label.add_theme_color_override(
			"font_color", item.preview_tint.lightened(0.35)
		)
	vbox.add_child(label)

	return btn


static func _sort_build_items(a: BuildItem, b: BuildItem) -> bool:
	if a == null or b == null:
		return a != null
	# En "Base": pared, suelo y después sus borradores.
	var rank_a := _item_rank(a)
	var rank_b := _item_rank(b)
	if rank_a != rank_b:
		return rank_a < rank_b
	var name_a := a.display_name if a.display_name != "" else String(a.id)
	var name_b := b.display_name if b.display_name != "" else String(b.id)
	return name_a.naturalnocasecmp_to(name_b) < 0


static func _item_rank(item: BuildItem) -> int:
	match item.object_type:
		"wall", "pared":
			return 0
		"floor", "suelo":
			return 1
		"erase_wall":
			return 2
		"erase_floor":
			return 3
		"erase_object":
			return 10
		_:
			return 5


func _on_item_pressed(item: BuildItem) -> void:
	item_selected.emit(item)
	_status.text = "Seleccionado: %s" % (item.display_name if item.display_name != "" else String(item.id))


func _pretty_name(value: String) -> String:
	if value == "":
		return "General"
	# Capitalizar primera letra.
	return value.substr(0, 1).to_upper() + value.substr(1)


func get_items() -> Array[BuildItem]:
	return items


func get_items_by_type(object_type: String) -> Array[BuildItem]:
	var out: Array[BuildItem] = []
	for item in items:
		if item.object_type == object_type:
			out.append(item)
	return out


func reload_items(dir_path: String = "") -> void:
	if dir_path != "":
		items_dir = dir_path
	items = BuildItemLoader.load_items(items_dir)
	if _categories == null:
		# La UI aun no se construye; _ready la generara con items_dir actualizado.
		return
	for child in _categories.get_children():
		child.queue_free()
	_populate_categories()
	_status.text = "%d items cargados" % items.size()
