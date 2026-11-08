class_name BuildMenu
extends CanvasLayer

## Menú de gameplay para elegir items construibles/colocables.
## Carga automáticamente los recursos `BuildItem` de `items_dir`.

signal item_selected(item: BuildItem)

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
	title.text = "Menú de construcción"
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
	# Agrupar por categoría.
	var by_category: Dictionary = {}
	for item in items:
		var cat := item.normalized_category()
		if cat == "":
			cat = "general"
		if not by_category.has(cat):
			by_category[cat] = {}
		var sub := item.normalized_subcategory()
		if sub == "":
			sub = "general"
		if not by_category[cat].has(sub):
			by_category[cat][sub] = []
		by_category[cat][sub].append(item)

	if by_category.is_empty():
		var empty := Label.new()
		empty.text = "No hay items en res://data/build_items"
		_categories.add_child(empty)
		return

	for cat in by_category.keys():
		var cat_page := VBoxContainer.new()
		cat_page.name = _pretty_name(cat)
		_categories.add_child(cat_page)

		var sub_tabs := TabContainer.new()
		sub_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
		cat_page.add_child(sub_tabs)

		var subs: Dictionary = by_category[cat]
		for sub in subs.keys():
			var page := ScrollContainer.new()
			page.name = _pretty_name(sub)
			page.size_flags_vertical = Control.SIZE_EXPAND_FILL
			sub_tabs.add_child(page)

			var list := VBoxContainer.new()
			list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			page.add_child(list)

			for item in subs[sub]:
				var btn := Button.new()
				btn.text = item.display_name if item.display_name != "" else String(item.id)
				btn.icon = item.preview
				btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
				btn.custom_minimum_size = Vector2(0, 40)
				btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				btn.pressed.connect(_on_item_pressed.bind(item))
				list.add_child(btn)


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
