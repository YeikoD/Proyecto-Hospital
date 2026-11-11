class_name FPSController
extends CharacterBody3D

## Réplica del player de proyecto-montevideo (solo locomoción).
##
## No sabe nada de como funciona la animacion: solo informa la velocidad al
## AnimationController y deja que elija el estado (idle / caminar / correr).
## Tampoco depende del nombre de los nodos del modelo: todo se busca por clase.
##
## Ratón: mirar | WASD: moverse | Espacio: saltar | Shift: esprintar
## F: linterna | Esc: liberar el ratón (clic para volver a capturar)

@export_group("Movimiento")
@export var speed := 5.0
@export var sprint_speed := 8.0
@export var acceleration := 12.0
@export var deceleration := 14.0
@export var air_control := 0.3
@export var jump_velocity := 5.0

@export_group("Camara")
@export var mouse_sensitivity := 0.002
## Si esta activo, la camara sigue la posicion del hueso indicado.
@export var follow_head := true
## Nombre del hueso de la cabeza. Vacio = la camara queda en altura fija.
@export var head_bone := &"mixamorig_Head"
## Posicion de la camara respecto al hueso de la cabeza
## (espacio del cuerpo: +Y arriba, -Z adelante). Se gira con el cuerpo, asi
## que "adelante" siempre apunta a la direccion a la que miras.
@export var head_offset := Vector3(0.0, 0.10, -0.159)

@onready var camera: Camera3D = _find_node(self, "Camera3D") as Camera3D
@onready var head: Node3D = camera.get_parent()
@onready var anim: AnimationController = _find_named(self, "AnimController") \
	as AnimationController
@onready var _flashlight: SpotLight3D = _find_node(self, "SpotLight3D") as SpotLight3D

var _skeleton: Skeleton3D
var _head_idx := -1
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var _pitch := 0.0


func _ready() -> void:
	_ensure_input_actions()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_skeleton = _find_skeleton(self)
	if _skeleton != null and head_bone != StringName():
		_head_idx = _skeleton.find_bone(head_bone)
	if _head_idx < 0 and follow_head:
		push_warning("FPSController: sin hueso '%s', la camara usa la altura fija del nodo Head." % head_bone)
	if anim != null:
		anim.sync_locomotion_points(speed, sprint_speed)


func _process(_delta: float) -> void:
	if not follow_head or _head_idx < 0 or _skeleton == null:
		return
	var bone_global: Transform3D = _skeleton.global_transform \
		* _skeleton.get_bone_global_pose(_head_idx)
	head.global_transform = Transform3D(
		global_transform.basis,
		bone_global.origin + global_transform.basis * head_offset
	)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		rotate_y(-motion.relative.x * mouse_sensitivity)
		_pitch = clampf(_pitch - motion.relative.y * mouse_sensitivity,
			-PI / 2.0 + 0.01, PI / 2.0 - 0.01)
		camera.rotation.x = _pitch
	elif event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event.is_action_pressed("flashlight") and _flashlight != null:
		_flashlight.visible = not _flashlight.visible


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= _gravity * delta

	var direccion := Input.get_vector(
		"move_left", "move_right", "move_backward", "move_forward"
	)
	var adelante := -global_transform.basis.z
	var derecha := global_transform.basis.x
	var deseo := (adelante * direccion.y + derecha * direccion.x).normalized()

	var objetivo := deseo * (sprint_speed if Input.is_action_pressed("sprint") else speed)
	var tasa := acceleration if deseo != Vector3.ZERO else deceleration
	if not is_on_floor():
		tasa *= air_control

	velocity.x = move_toward(velocity.x, objetivo.x, tasa * delta)
	velocity.z = move_toward(velocity.z, objetivo.z, tasa * delta)

	if is_on_floor() and Input.is_action_just_pressed("jump"):
		velocity.y = jump_velocity

	move_and_slide()

	if anim != null:
		anim.set_speed(Vector2(velocity.x, velocity.z).length())


## Crea las acciones de entrada que falten (por si no estan en Project Settings).
func _ensure_input_actions() -> void:
	_bind_key("move_forward", [KEY_W])
	_bind_key("move_backward", [KEY_S])
	_bind_key("move_left", [KEY_A])
	_bind_key("move_right", [KEY_D])
	_bind_key("jump", [KEY_SPACE])
	_bind_key("sprint", [KEY_SHIFT])
	_bind_key("flashlight", [KEY_F])


func _bind_key(action: String, keys: Array) -> void:
	if InputMap.has_action(action) and not InputMap.action_get_events(action).is_empty():
		return
	if not InputMap.has_action(action):
		InputMap.add_action(action, 0.5)
	for key: Key in keys:
		var event := InputEventKey.new()
		event.physical_keycode = key
		InputMap.action_add_event(action, event)


## Busca un nodo por clase, para no depender de nombres ni de rutas fijas.
func _find_node(desde: Node, clase: String) -> Node:
	if desde.is_class(clase):
		return desde
	for c in desde.get_children():
		var r := _find_node(c, clase)
		if r != null:
			return r
	return null


## Busca por nombre de nodo: sirve para nodos con script propio, donde
## `is_class` no sirve (solo devuelve la clase base, "Node").
func _find_named(desde: Node, nombre: String) -> Node:
	if desde.name == nombre:
		return desde
	for c in desde.get_children():
		var r := _find_named(c, nombre)
		if r != null:
			return r
	return null


func _find_skeleton(desde: Node) -> Skeleton3D:
	return _find_node(desde, "Skeleton3D") as Skeleton3D
