extends "res://scenes/demos/nav_demo.gd"

## Demo del spawner de NPCs.
##
## Dos POI de aparicion repartidos por las habitaciones. Como mucho hay 5 NPCs
## vivos en total y aparecen espaciados en el tiempo: cada uno busca una silla,
## la usa y vuelve a cualquier spawner para desaparecer.

const CHAIR_ITEM := "res://data/build_items/muebles/furniture_chair.tres"

## Celdas donde se coloca una silla de ejemplo (una por NPC como maximo).
const CHAIR_CELLS := [
	Vector2i(5, 4),
	Vector2i(9, 4),
	Vector2i(5, 7),
	Vector2i(9, 7),
	Vector2i(7, 4),
]

var _spawn_label: Label


func _ready() -> void:
	super()
	_create_spawn_hud()


func _process(delta: float) -> void:
	super._process(delta)
	if _spawn_label == null:
		return
	_spawn_label.text = "SPAWNERS: %d POI  ·  NPCs vivos: %d / %d" % [
		NpcSpawner.get_spawners().size(),
		NpcSpawner.count_alive(),
		5,
	]


func _build_example() -> void:
	super()

	var controller := get_node_or_null(controller_path) as BuildController
	if controller == null:
		return
	var chair := load(CHAIR_ITEM) as BuildItem
	if chair == null:
		push_warning("NpcSpawnerDemo: no se pudo cargar la silla.")
		return
	for cell in CHAIR_CELLS:
		controller.place_object_item(chair, cell, 0)


func _create_spawn_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "SpawnDemoUI"
	layer.layer = 10
	add_child(layer)

	_spawn_label = Label.new()
	_spawn_label.name = "SpawnerInfo"
	_spawn_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_spawn_label.offset_left = -380
	_spawn_label.offset_top = 12
	_spawn_label.offset_right = -18
	_spawn_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_spawn_label.add_theme_font_size_override("font_size", 16)
	_spawn_label.add_theme_color_override("font_color", Color(0.55, 0.95, 1.0))
	_spawn_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_spawn_label.add_theme_constant_override("outline_size", 5)
	_spawn_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_spawn_label)
