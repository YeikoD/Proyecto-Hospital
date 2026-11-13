class_name BuildMenu
extends CanvasLayer

## Menú de gameplay para elegir items construibles/colocables.
## Carga automáticamente los recursos `BuildItem` de `items_dir`.
##
## La interfaz se construye por código con un tema propio (panel oscuro, acento
## azul clínico) y resalta en todo momento el item seleccionado, de forma que el
## jugador siempre ve qué herramienta tiene activa.

signal item_selected(item: BuildItem)

const TINT_SHADER := preload("res://scripts/systems/build/shaders/menu_tint.gdshader")

# ---------------------------------------------------------------------------
# Paleta
# ---------------------------------------------------------------------------
const C_PANEL := Color("131d27")           # Fondo del panel
const C_HEADER := Color("1a2734")          # Barra de título
const C_INSET := Color("0e1620")           # Fondo del área de contenido
const C_BORDER := Color("2b4152")          # Borde sutil
const C_ACCENT := Color("2f9dd8")          # Acento principal (azul clínico)
const C_ACCENT_SOFT := Color("1e5470")     # Acento suave (hover)
const C_TEXT := Color("e8eef4")            # Texto principal
const C_TEXT_DIM := Color("93a6b6")        # Texto secundario
const C_DANGER := Color("e0564f")          # Borradores
const C_ZONE := Color("5b8def")            # Zonas
const C_CARD := Color("1b2a38")            # Tarjeta de item (normal)
const C_CARD_HOVER := Color("223646")      # Tarjeta de item (hover)
const C_CARD_SELECTED := Color("1c3344")   # Tarjeta de item (seleccionada)

@export var items_dir: String = "res://data/build_items"
@export var toggle_key: Key = KEY_M

var items: Array[BuildItem] = []

var _panel: PanelContainer
var _categories: TabContainer
var _header_count: Label
var _footer_name: Label
var _footer_notes: Label
var _search_edit: LineEdit
var _no_results: Label

var _item_group: ButtonGroup
## id de item (StringName) -> Button de su tarjeta.
var _item_buttons: Dictionary = {}
## Button -> BuildItem (para resolver el item al filtrar).
var _tile_items: Dictionary = {}
## Button -> Label del distintivo "✓".
var _item_checks: Dictionary = {}
## Todas las tarjetas creadas, en orden.
var _all_tiles: Array = []

var _selected_item: BuildItem
var _search := ""


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


# ---------------------------------------------------------------------------
# Construcción de la interfaz
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.name = "BuildMenuPanel"
	_panel.theme = _create_theme()
	_panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	_panel.offset_left = -392
	_panel.offset_top = 12
	_panel.offset_right = -12
	_panel.offset_bottom = -12
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_bottom", 14)
	_panel.add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)

	root.add_child(_build_header())
	_search_edit = _build_search()
	root.add_child(_search_edit)

	_categories = TabContainer.new()
	_categories.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_categories.get_tab_bar().add_theme_font_size_override("font_size", 15)
	root.add_child(_categories)

	_no_results = Label.new()
	_no_results.text = "Sin resultados"
	_no_results.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_no_results.add_theme_font_size_override("font_size", 13)
	_no_results.add_theme_color_override("font_color", C_TEXT_DIM)
	_no_results.visible = false
	root.add_child(_no_results)

	root.add_child(_build_footer())

	_populate_categories()
	_update_header_count()
	_refresh_selection()
	_update_footer()


func _build_header() -> Control:
	var header := PanelContainer.new()
	header.add_theme_stylebox_override("panel", _header_style())

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 10)
	header.add_child(hbox)

	var title_box := VBoxContainer.new()
	title_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_box.add_theme_constant_override("separation", 0)
	hbox.add_child(title_box)

	var title := Label.new()
	title.text = "CONSTRUCCIÓN"
	title.add_theme_font_size_override("font_size", 19)
	title.add_theme_color_override("font_color", C_TEXT)
	title_box.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Catálogo de elementos"
	subtitle.add_theme_font_size_override("font_size", 12)
	subtitle.add_theme_color_override("font_color", C_TEXT_DIM)
	title_box.add_child(subtitle)

	_header_count = Label.new()
	_header_count.add_theme_font_size_override("font_size", 12)
	_header_count.add_theme_color_override("font_color", C_TEXT_DIM)
	_header_count.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hbox.add_child(_header_count)

	var close := Button.new()
	close.text = "✕"
	close.custom_minimum_size = Vector2(30, 30)
	close.focus_mode = Control.FOCUS_NONE
	close.tooltip_text = "Cerrar (M)"
	close.add_theme_font_size_override("font_size", 14)
	close.add_theme_color_override("font_color", C_TEXT_DIM)
	close.add_theme_color_override("font_hover_color", C_TEXT)
	close.add_theme_color_override("font_pressed_color", C_ACCENT.lightened(0.3))
	close.add_theme_stylebox_override("normal", _icon_button_style(C_BORDER))
	close.add_theme_stylebox_override("hover", _icon_button_style(C_ACCENT_SOFT))
	close.add_theme_stylebox_override("pressed", _icon_button_style(C_ACCENT))
	close.pressed.connect(_on_close_pressed)
	hbox.add_child(close)

	return header


func _build_search() -> LineEdit:
	var edit := LineEdit.new()
	edit.placeholder_text = "Buscar elemento…"
	edit.clear_button_enabled = true
	edit.add_theme_font_size_override("font_size", 14)
	edit.add_theme_color_override("font_color", C_TEXT)
	edit.add_theme_color_override("font_placeholder_color", C_TEXT_DIM)
	edit.add_theme_color_override("caret_color", C_ACCENT)
	edit.add_theme_stylebox_override("normal", _search_style(false))
	edit.add_theme_stylebox_override("focus", _search_style(true))
	edit.text_changed.connect(_on_search_changed)
	return edit


func _build_footer() -> Control:
	var footer := PanelContainer.new()
	footer.add_theme_stylebox_override("panel", _footer_style())

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 3)
	footer.add_child(vbox)

	_footer_name = Label.new()
	_footer_name.text = "Selecciona un elemento"
	_footer_name.add_theme_font_size_override("font_size", 14)
	_footer_name.add_theme_color_override("font_color", C_TEXT)
	vbox.add_child(_footer_name)

	_footer_notes = Label.new()
	_footer_notes.add_theme_font_size_override("font_size", 12)
	_footer_notes.add_theme_color_override("font_color", C_TEXT_DIM)
	_footer_notes.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_footer_notes.visible = false
	vbox.add_child(_footer_notes)

	return footer


# ---------------------------------------------------------------------------
# Poblado de categorías e items
# ---------------------------------------------------------------------------

func _populate_categories() -> void:
	_item_buttons.clear()
	_tile_items.clear()
	_item_checks.clear()
	_all_tiles.clear()
	_item_group = ButtonGroup.new()

	for child in _categories.get_children():
		_categories.remove_child(child)
		child.queue_free()

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

	var category_order := ["construir", "zonas", "objetos"]
	var category_titles := {
		"construir": "Construir",
		"zonas": "Zonas",
		"objetos": "Objetos",
	}
	var sub_order := [
		"base", "pinturas", "baldosas", "aberturas",
		"pinceles", "muebles", "general",
	]
	var sub_titles := {
		"base": "Base",
		"pinturas": "Pinturas",
		"baldosas": "Baldosas",
		"aberturas": "Aberturas",
		"pinceles": "Pinceles",
		"muebles": "Muebles",
		"general": "General",
	}

	var added: Dictionary = {}
	for cat in category_order:
		var subs: Dictionary = by_category.get(cat, {})
		_add_category_page(cat, subs, category_titles, sub_order, sub_titles)
		added[cat] = true

	var rest: Array = by_category.keys()
	rest.sort()
	for cat in rest:
		if added.has(cat):
			continue
		_add_category_page(cat, by_category[cat], category_titles, sub_order, sub_titles)

	if _categories.get_child_count() == 0:
		var empty := Label.new()
		empty.text = "No hay items en res://data/build_items"
		empty.add_theme_color_override("font_color", C_TEXT_DIM)
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
	cat_page.add_theme_constant_override("separation", 8)
	_categories.add_child(cat_page)

	var sub_tabs := TabContainer.new()
	sub_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sub_tabs.add_theme_stylebox_override("panel", _empty_style())
	sub_tabs.get_tab_bar().theme_type_variation = &"SubTabs"
	sub_tabs.get_tab_bar().add_theme_font_size_override("font_size", 12)
	cat_page.add_child(sub_tabs)

	if subs.is_empty():
		var placeholder := Label.new()
		placeholder.text = "No hay elementos en esta sección."
		placeholder.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		placeholder.add_theme_font_size_override("font_size", 13)
		placeholder.add_theme_color_override("font_color", C_TEXT_DIM)
		var margin := MarginContainer.new()
		margin.add_theme_constant_override("margin_left", 10)
		margin.add_theme_constant_override("margin_top", 10)
		margin.add_theme_constant_override("margin_right", 10)
		margin.add_theme_constant_override("margin_bottom", 10)
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
			page.add_theme_constant_override("margin_left", 10)
			page.add_theme_constant_override("margin_top", 10)
			page.add_theme_constant_override("margin_right", 10)
			page.add_theme_constant_override("margin_bottom", 10)
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
			placeholder.add_theme_color_override("font_color", C_TEXT_DIM)
			page.add_child(placeholder)
			sub_tabs.add_child(page)
			continue

		var page := ScrollContainer.new()
		page.name = sub_titles.get(sub, _pretty_name(sub))
		page.size_flags_vertical = Control.SIZE_EXPAND_FILL
		page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sub_tabs.add_child(page)

		var list := GridContainer.new()
		list.columns = 2
		list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		list.add_theme_constant_override("h_separation", 8)
		list.add_theme_constant_override("v_separation", 8)
		page.add_child(list)

		visible_items.sort_custom(_sort_build_items)
		for item in visible_items:
			list.add_child(_create_item_tile(item))


func _create_item_tile(item: BuildItem) -> Button:
	var title := item.display_name if item.display_name != "" else String(item.id)
	var accent := _accent_for(item)

	var btn := Button.new()
	btn.toggle_mode = true
	btn.button_group = _item_group
	btn.custom_minimum_size = Vector2(0, 150)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.tooltip_text = title
	btn.add_theme_stylebox_override("normal", _card_style(accent, false, false))
	btn.add_theme_stylebox_override("hover", _card_style(accent, true, false))
	btn.add_theme_stylebox_override("pressed", _card_style(accent, false, true))
	btn.add_theme_stylebox_override("hover_pressed", _card_style(accent, true, true))
	btn.add_theme_stylebox_override("focus", _card_focus_style(accent))
	btn.pressed.connect(_on_item_pressed.bind(item))

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	btn.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	var icon := TextureRect.new()
	icon.texture = item.preview
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = Vector2(0, 96)
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
	label.custom_minimum_size = Vector2(0, 30)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_color_override("font_color", C_TEXT)
	if item.preview_tint != Color.WHITE:
		label.add_theme_color_override(
			"font_color", item.preview_tint.lightened(0.45)
		)
	vbox.add_child(label)

	var check := Label.new()
	check.text = "✓"
	check.mouse_filter = Control.MOUSE_FILTER_IGNORE
	check.visible = false
	check.add_theme_font_size_override("font_size", 14)
	check.add_theme_color_override("font_color", accent.lightened(0.45))
	check.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.8))
	check.add_theme_constant_override("outline_size", 4)
	check.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	check.offset_left = -22
	check.offset_top = 3
	check.offset_right = -6
	check.offset_bottom = 23
	btn.add_child(check)

	_item_buttons[item.id] = btn
	_tile_items[btn] = item
	_item_checks[item.id] = check
	_all_tiles.append(btn)

	return btn


# ---------------------------------------------------------------------------
# Selección
# ---------------------------------------------------------------------------

## Marca visualmente el item activo. Lo llama el controlador al cambiar de
## herramienta (o al seleccionar el item por defecto al iniciar).
func set_selected(item: BuildItem) -> void:
	_selected_item = item
	if _categories != null:
		_refresh_selection()
		_update_footer()


func _on_item_pressed(item: BuildItem) -> void:
	_selected_item = item
	item_selected.emit(item)
	_refresh_selection()
	_update_footer()


func _on_close_pressed() -> void:
	visible = false


func _refresh_selection() -> void:
	var sel_id: StringName = _selected_item.id if _selected_item != null else &""
	for id in _item_buttons:
		var btn: Button = _item_buttons[id]
		btn.button_pressed = (id == sel_id)
		var check: Label = _item_checks.get(id)
		if check != null:
			check.visible = (id == sel_id)


func _update_header_count() -> void:
	if _header_count != null:
		_header_count.text = "%d elementos" % items.size()


func _update_footer() -> void:
	if _footer_name == null:
		return
	if _selected_item != null:
		var title := _selected_item.display_name \
			if _selected_item.display_name != "" else String(_selected_item.id)
		_footer_name.text = title
		_footer_name.add_theme_color_override(
			"font_color", _accent_for(_selected_item).lightened(0.35)
		)
		var notes := _selected_item.notes.strip_edges()
		_footer_notes.text = notes
		_footer_notes.visible = notes != ""
	else:
		_footer_name.text = "Selecciona un elemento"
		_footer_name.add_theme_color_override("font_color", C_TEXT)
		_footer_notes.text = ""
		_footer_notes.visible = false


# ---------------------------------------------------------------------------
# Búsqueda
# ---------------------------------------------------------------------------

func _on_search_changed(text: String) -> void:
	_search = text.strip_edges().to_lower()
	var any_visible := false
	for btn in _all_tiles:
		var item: BuildItem = _tile_items[btn]
		var title := item.display_name if item.display_name != "" else String(item.id)
		var matches := _search == "" or title.to_lower().contains(_search)
		btn.visible = matches
		if matches:
			any_visible = true
	if _no_results != null:
		_no_results.visible = _search != "" and not any_visible


# ---------------------------------------------------------------------------
# Orden
# ---------------------------------------------------------------------------

static func _sort_build_items(a: BuildItem, b: BuildItem) -> bool:
	if a == null or b == null:
		return a != null
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
		"zone_paint":
			return 0
		"zone_erase":
			return 1
		_:
			return 5


func _accent_for(item: BuildItem) -> Color:
	match item.object_type:
		"erase_floor", "erase_wall", "erase_object":
			return C_DANGER
		"zone_paint", "zone_erase":
			return C_ZONE
		_:
			return C_ACCENT


func _pretty_name(value: String) -> String:
	if value == "":
		return "General"
	return value.substr(0, 1).to_upper() + value.substr(1)


# ---------------------------------------------------------------------------
# API pública
# ---------------------------------------------------------------------------

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
	_populate_categories()
	_update_header_count()
	_refresh_selection()
	_update_footer()
	if _search_edit != null:
		_search_edit.text = ""
		_search = ""


# ---------------------------------------------------------------------------
# Tema y estilos
# ---------------------------------------------------------------------------

func _create_theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = 14

	t.set_stylebox("panel", "PanelContainer", _panel_style())
	t.set_stylebox("panel", "TabContainer", _inset_style())

	# Pestañas principales (categorías).
	t.set_stylebox("tab_selected", "TabContainer", _tab_style(C_ACCENT, true))
	t.set_stylebox("tab_unselected", "TabContainer", _tab_style(C_BORDER, false))
	t.set_stylebox("tab_hover", "TabContainer", _tab_style(C_ACCENT, false, true))
	t.set_stylebox("tab_hover_pressed", "TabContainer", _tab_style(C_ACCENT, true))
	t.set_color("font_selected_color", "TabContainer", C_TEXT)
	t.set_color("font_unselected_color", "TabContainer", C_TEXT_DIM)
	t.set_color("font_hovered_color", "TabContainer", C_TEXT)

	# Subpestañas (variación "SubTabs" sobre TabBar).
	t.set_type_variation("SubTabs", "TabBar")
	t.set_stylebox("tab_selected", "SubTabs", _sub_tab_style(C_ACCENT, true))
	t.set_stylebox("tab_unselected", "SubTabs", _sub_tab_style(C_BORDER, false))
	t.set_stylebox("tab_hover", "SubTabs", _sub_tab_style(C_ACCENT, false, true))
	t.set_stylebox("tab_hover_pressed", "SubTabs", _sub_tab_style(C_ACCENT, true))
	t.set_color("font_selected_color", "SubTabs", C_ACCENT.lightened(0.3))
	t.set_color("font_unselected_color", "SubTabs", C_TEXT_DIM)
	t.set_color("font_hovered_color", "SubTabs", C_TEXT)

	# Área de scroll sin marco.
	t.set_stylebox("panel", "ScrollContainer", _empty_style())

	return t


func _panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_PANEL
	sb.border_color = C_BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(12)
	sb.shadow_color = Color(0.0, 0.0, 0.0, 0.45)
	sb.shadow_size = 18
	sb.shadow_offset = Vector2(0.0, 4.0)
	return sb


func _inset_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_INSET
	sb.border_color = Color(0.0, 0.0, 0.0, 0.0)
	sb.set_border_width_all(0)
	sb.set_corner_radius_all(8)
	return sb


func _header_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_HEADER
	sb.border_color = C_ACCENT_SOFT
	sb.border_width_left = 0
	sb.border_width_top = 0
	sb.border_width_right = 0
	sb.border_width_bottom = 2
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 12
	sb.content_margin_top = 9
	sb.content_margin_right = 12
	sb.content_margin_bottom = 9
	return sb


func _footer_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_HEADER
	sb.border_color = C_BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 12
	sb.content_margin_top = 9
	sb.content_margin_right = 12
	sb.content_margin_bottom = 9
	return sb


func _tab_style(accent: Color, selected: bool, hovered: bool = false) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	if selected:
		sb.bg_color = Color(accent.r, accent.g, accent.b, 0.22)
		sb.border_color = accent
		sb.border_width_bottom = 3
	elif hovered:
		sb.bg_color = Color(1.0, 1.0, 1.0, 0.05)
		sb.border_color = accent
		sb.border_width_bottom = 1
	else:
		sb.bg_color = Color(0.0, 0.0, 0.0, 0.0)
		sb.border_color = Color(0.0, 0.0, 0.0, 0.0)
		sb.border_width_bottom = 0
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 7
	sb.content_margin_bottom = 7
	return sb


func _sub_tab_style(accent: Color, selected: bool, hovered: bool = false) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	if selected:
		sb.bg_color = Color(accent.r, accent.g, accent.b, 0.18)
		sb.border_color = Color(accent.r, accent.g, accent.b, 0.45)
		sb.set_border_width_all(1)
	elif hovered:
		sb.bg_color = Color(1.0, 1.0, 1.0, 0.05)
		sb.border_color = Color(accent.r, accent.g, accent.b, 0.35)
		sb.set_border_width_all(1)
	else:
		sb.bg_color = Color(0.0, 0.0, 0.0, 0.0)
		sb.border_color = Color(0.0, 0.0, 0.0, 0.0)
		sb.set_border_width_all(0)
	sb.set_corner_radius_all(5)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 5
	sb.content_margin_bottom = 5
	return sb


func _card_style(accent: Color, hovered: bool, selected: bool) -> StyleBoxFlat:
	var bg := C_CARD_SELECTED if selected else (C_CARD_HOVER if hovered else C_CARD)
	var border := accent if selected else (accent.darkened(0.45) if hovered else C_BORDER)
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(2 if selected else 1)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 2
	sb.content_margin_top = 2
	sb.content_margin_right = 2
	sb.content_margin_bottom = 2
	return sb


func _card_focus_style(accent: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_CARD
	sb.border_color = accent.lightened(0.2)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 2
	sb.content_margin_top = 2
	sb.content_margin_right = 2
	sb.content_margin_bottom = 2
	return sb


func _search_style(focused: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_INSET
	sb.border_color = C_ACCENT if focused else C_BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 10
	sb.content_margin_top = 7
	sb.content_margin_right = 10
	sb.content_margin_bottom = 7
	return sb


func _icon_button_style(border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	return sb


func _empty_style() -> StyleBoxEmpty:
	return StyleBoxEmpty.new()
