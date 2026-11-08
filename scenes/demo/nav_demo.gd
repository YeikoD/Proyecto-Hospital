extends Node3D

## Demo de navegacion sobre la grilla.
##
## Construye un pequeno hospital de ejemplo usando la API del BuildController,
## deja que BuildNavigation hornee el NavMesh y suelta varios NPC que deambulan
## por las habitaciones. Al entrar en modo construccion (B) se pueden colocar o
## borrar paredes y el NavMesh se rehornea solo.

@export var auto_build := true
@export var controller_path: NodePath = ^"BuildSystem/BuildController"
@export var navigation_path: NodePath = ^"BuildSystem/BuildNavigation"

var _nav: BuildNavigation
var _label: Label


func _ready() -> void:
	_nav = get_node_or_null(navigation_path) as BuildNavigation
	_create_hud()
	if auto_build:
		_build_example()


func _process(_delta: float) -> void:
	if _label == null:
		return

	var status := "NavMesh pendiente"
	if _nav != null:
		var state := "horneando..." if _nav.is_baking() else "listo"
		status = "NavMesh: %d poligonos - %s" % [_nav.get_polygon_count(), state]

	_label.text = "NAVEGACION DE NPCS\n" \
		+ "Los NPC deambulan por los suelos construidos.\n" \
		+ "B: construir / salir   ·   1/2/3: suelo / pared / borrar\n" \
		+ "Los muros se rehornean en el NavMesh al colocarlos.\n" \
		+ status


# --------------------------------------------------------------------------
# Construccion del ejemplo
# --------------------------------------------------------------------------

func _build_example() -> void:
	var controller := get_node_or_null(controller_path) as BuildController
	if controller == null:
		push_warning("NavDemo: falta BuildController en %s" % controller_path)
		return

	var x0 := 3
	var x1 := 10
	var z0 := 3
	var z1 := 8

	# Suelos de las dos habitaciones.
	for x in range(x0, x1 + 1):
		for z in range(z0, z1 + 1):
			controller.place_floor(Vector2i(x, z))

	# Muros exteriores con una puerta de 2 celdas al frente (z = z1 + 1).
	for x in range(x0, x1 + 1):
		controller.place_wall(Vector3i(x, z0, 1))
		if x != 6 and x != 7:
			controller.place_wall(Vector3i(x, z1 + 1, 1))
	for z in range(z0, z1 + 1):
		controller.place_wall(Vector3i(x0, z, 0))
		controller.place_wall(Vector3i(x1 + 1, z, 0))

	# Division central con puerta de 2 celdas (z = 5 y 6).
	for z in range(z0, z1 + 1):
		if z == 5 or z == 6:
			continue
		controller.place_wall(Vector3i(7, z, 0))

	# Muro interior con puerta de 1 celda (x = 5), para probar pasillos angostos.
	for x in range(x0, 7):
		if x == 5:
			continue
		controller.place_wall(Vector3i(x, 6, 1))


# --------------------------------------------------------------------------
# HUD
# --------------------------------------------------------------------------

func _create_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "NavDemoUI"
	layer.layer = 10
	add_child(layer)

	_label = Label.new()
	_label.name = "Info"
	_label.position = Vector2(18, 12)
	_label.add_theme_font_size_override("font_size", 16)
	_label.add_theme_color_override("font_color", Color(0.92, 0.97, 1.0))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_label.add_theme_constant_override("outline_size", 5)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_label)
