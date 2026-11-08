class_name BuildCamera
extends Camera3D

## Camara orbital para el modo construccion.
##
## Clic derecho (o central) y arrastrar: orbitar.
## Rueda: zoom. WASD: desplazar el foco. Q/E: bajar/subir el foco.

@export var focus := Vector3.ZERO
@export var yaw := 0.0
@export var pitch := 0.85
@export var distance := 18.0

@export_group("Controles")
@export var pan_speed := 16.0
@export var height_speed := 8.0
@export var zoom_step := 1.15
@export var min_distance := 2.0
@export var max_distance := 80.0
@export var rotate_sensitivity := 0.006
@export var min_pitch := 0.12
@export var max_pitch := 1.5

var _orbiting := false


func _ready() -> void:
	BuildInput.ensure_actions()
	current = false
	_apply_transform()


func _process(delta: float) -> void:
	if not current:
		return

	var input := Input.get_vector(
		"move_left", "move_right", "move_backward", "move_forward"
	)
	if input != Vector2.ZERO:
		var flat := Basis(Vector3.UP, yaw)
		focus += (flat * Vector3(input.x, 0.0, -input.y)) * pan_speed * delta

	if Input.is_action_pressed("build_raise"):
		focus.y += height_speed * delta
	elif Input.is_action_pressed("build_lower"):
		focus.y -= height_speed * delta

	_apply_transform()


func _unhandled_input(event: InputEvent) -> void:
	if not current:
		return

	if event is InputEventMouseButton:
		var mouse_button := event as InputEventMouseButton
		if mouse_button.button_index == MOUSE_BUTTON_RIGHT \
				or mouse_button.button_index == MOUSE_BUTTON_MIDDLE:
			_orbiting = mouse_button.pressed
			get_viewport().set_input_as_handled()
		elif mouse_button.pressed and mouse_button.button_index == MOUSE_BUTTON_WHEEL_UP:
			distance = clampf(distance / zoom_step, min_distance, max_distance)
			_apply_transform()
			get_viewport().set_input_as_handled()
		elif mouse_button.pressed and mouse_button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			distance = clampf(distance * zoom_step, min_distance, max_distance)
			_apply_transform()
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _orbiting:
		var motion := event as InputEventMouseMotion
		yaw -= motion.relative.x * rotate_sensitivity
		pitch = clampf(pitch + motion.relative.y * rotate_sensitivity,
			min_pitch, max_pitch)
		_apply_transform()
		get_viewport().set_input_as_handled()


## Encuadra la grilla completa.
func frame_grid(center: Vector3, size: float) -> void:
	focus = center
	distance = clampf(maxf(size * 1.05, 6.0), min_distance, max_distance)
	_apply_transform()


func _apply_transform() -> void:
	global_rotation = Vector3(-pitch, yaw, 0.0)
	global_position = focus + global_transform.basis.z * distance
