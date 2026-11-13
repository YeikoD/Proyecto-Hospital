class_name NpcDoctorSpawner
extends NpcSpawner

## Spawner manual del NPC medico.
##
## No genera NPCs por intervalo: espera a que el jugador presione `summon_key`
## (Y por defecto). El medico solo tiene la necesidad `work`, que en el hospital
## ofrece unicamente el SmartObject especial "Escritorio de trabajo"
## (`work_desk`).
##
## A diferencia de los NPCs normales, el medico **no desaparece**: se queda en
## la escena y sigue usando el escritorio mientras tenga la necesidad. Por eso
## este spawner configura a sus NPCs con `despawn_after_use = false`.
##
## Tampoco genera NPCs por intervalo: la unica forma de invocarlo es la accion
## `summon_action` (Y por defecto). Cada intento muestra feedback en pantalla.

## Resultado del ultimo intento de invocacion.
enum SummonOutcome { NONE, SUMMONED, ALREADY_PRESENT, FAILED }

## Se invoco un medico nuevo.
signal doctor_summoned(npc: NpcAgent)
## Ya habia un medico vivo: la tecla no lo duplica.
signal doctor_already_present(npc: NpcAgent)
## No se pudo invocar. `reason` es el texto mostrado al jugador.
signal doctor_summon_failed(reason: String)

## Grupo de los medicos invocados. Se usa para no duplicarlos con la tecla.
const DOCTOR_GROUP := &"doctor_npcs"

@export_group("Invocacion")
## Accion de entrada que invoca al medico. Si no existe, se crea con
## `summon_key`.
@export var summon_action: StringName = &"summon_doctor"
## Tecla que se registra cuando la accion todavia no existe.
@export var summon_key: Key = KEY_Y

@export_group("Feedback")
## Cuanto tiempo queda visible el mensaje de invocacion.
@export var feedback_duration := 2.5
## Si es true, muestra un mensaje en pantalla al pulsar la tecla.
@export var show_feedback := true

@export_group("Estado")
## Muestra un indicador permanente con la disponibilidad del medico.
@export var show_status := true
## Cada cuanto se actualiza el indicador.
@export var status_update_interval := 0.5

var _last_outcome := SummonOutcome.NONE
var _last_feedback := ""
var _feedback_layer: CanvasLayer
var _feedback_label: Label
var _feedback_tween: Tween
var _status_layer: CanvasLayer
var _status_label: Label
var _status_text := ""
var _status_timer: Timer


func _ready() -> void:
	# El medico es permanente: no se agrega NpcSpawnCycle ni vuelve al POI
	# para desaparecer. Se configura antes de `super._ready()` por si la escena
	# guardo otro valor.
	despawn_after_use = false
	super._ready()
	# Este spawner nunca aparece solo: solo por pedido del jugador.
	set_process(false)
	_ensure_input_action()
	set_process_unhandled_input(true)
	_ensure_status_hud()
	_status_timer = Timer.new()
	_status_timer.name = "StatusTimer"
	_status_timer.wait_time = maxf(status_update_interval, 0.2)
	_status_timer.autostart = true
	_status_timer.timeout.connect(_refresh_status)
	add_child(_status_timer)
	_refresh_status()


## El medico no participa del ciclo automatico de aparicion, ni siquiera si
## alguien llama a `start()` sobre todos los spawners.
func _process(_delta: float) -> void:
	pass


func start() -> void:
	enabled = true
	set_process(false)


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(summon_action):
		return
	summon_doctor()
	if is_inside_tree():
		get_viewport().set_input_as_handled()


# --------------------------------------------------------------------------
# API
# --------------------------------------------------------------------------

## Medico vivo, o null si no hay ninguno.
func get_live_doctor() -> NpcAgent:
	if not is_inside_tree():
		return null
	for node in get_tree().get_nodes_in_group(DOCTOR_GROUP):
		var npc := node as NpcAgent
		if npc != null and is_instance_valid(npc) and not npc.is_queued_for_deletion():
			return npc
	return null


## Invoca al medico si hay un Escritorio de trabajo libre. Si ya hay uno,
## devuelve el existente: la tecla nunca duplica medicos. Tambien deja el
## resultado en `get_last_feedback()` y muestra el mensaje en pantalla.
func summon_doctor() -> NpcAgent:
	_last_feedback = ""
	var existing := get_live_doctor()
	if existing != null:
		_last_outcome = SummonOutcome.ALREADY_PRESENT
		_last_feedback = "El médico ya está en el hospital"
		doctor_already_present.emit(existing)
		_present_feedback(_last_feedback, Color(0.95, 0.85, 0.45))
		return existing

	var npc := spawn_now()
	if npc == null:
		_last_outcome = SummonOutcome.FAILED
		_last_feedback = _failure_message()
		doctor_summon_failed.emit(_last_feedback)
		_present_feedback(_last_feedback, Color(1.0, 0.55, 0.45))
		if OS.is_debug_build():
			print("[NpcDoctorSpawner] ", _last_feedback)
		return null

	npc.add_to_group(DOCTOR_GROUP)
	_force_work_only(npc)
	_add_doctor_tag(npc)
	_last_outcome = SummonOutcome.SUMMONED
	_last_feedback = "Médico invocado: va al Escritorio de trabajo"
	doctor_summoned.emit(npc)
	_present_feedback(_last_feedback, Color(0.6, 1.0, 0.7))
	return npc


## Resultado del ultimo intento (enum SummonOutcome).
func get_last_outcome() -> int:
	return _last_outcome


## Texto del ultimo feedback. Vacio si todavia no se intento invocar.
func get_last_feedback() -> String:
	return _last_feedback


## True si el mensaje de feedback esta visible ahora mismo.
func is_feedback_visible() -> bool:
	return _feedback_label != null and is_instance_valid(_feedback_label) \
		and _feedback_label.visible


## Texto actual del indicador de disponibilidad del medico.
func get_status_text() -> String:
	return _status_text


## Actualiza el indicador: sin medico, disponible o atendiendo.
func _refresh_status() -> void:
	if _status_label == null or not is_instance_valid(_status_label):
		return
	if not show_status:
		_status_label.visible = false
		return
	var doctor := get_live_doctor()
	if doctor == null:
		_set_status("● Médico no disponible", Color(0.72, 0.76, 0.82))
		return
	var brain := doctor.get_node_or_null("NpcBrain") as NpcBrain
	var attending := false
	if brain != null and brain.get_state() == NpcBrain.State.USE:
		var affordance := brain.get_current_affordance()
		attending = affordance != null and affordance.id == &"work"
	if attending:
		_set_status("● Médico atendiendo", Color(0.95, 0.85, 0.45))
	else:
		_set_status("● Médico disponible", Color(0.6, 1.0, 0.7))


func _set_status(text: String, color: Color) -> void:
	_status_text = text
	_status_label.text = text
	_status_label.add_theme_color_override("font_color", color)
	_status_label.visible = show_status


func _ensure_status_hud() -> void:
	if _status_label != null and is_instance_valid(_status_label):
		return
	_status_layer = CanvasLayer.new()
	_status_layer.name = "DoctorStatus"
	_status_layer.layer = 11
	add_child(_status_layer)

	_status_label = Label.new()
	_status_label.name = "Status"
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status_label.add_theme_font_size_override("font_size", 16)
	_status_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_status_label.add_theme_constant_override("outline_size", 5)
	_status_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_status_label.offset_left = -380
	_status_label.offset_right = -16
	_status_label.offset_top = 16
	_status_label.offset_bottom = 48
	_status_layer.add_child(_status_label)
	_set_status("● Médico no disponible", Color(0.72, 0.76, 0.82))


## Motivo legible por el jugador cuando `spawn_now()` no puede crear al medico.
func _failure_message() -> String:
	if not enabled:
		return "El spawner del médico está desactivado"
	if not _nav_ready():
		return "El médico no puede aparecer: el NavMesh se está horneando"
	if require_objective and not has_objective():
		return "No hay un Escritorio de trabajo libre para el médico"
	if min_player_distance > 0.0 and _player_near_spawn_point():
		return "No se pudo invocar: el médico no aparece delante de ti"
	return "No se pudo invocar al médico"


# --------------------------------------------------------------------------
# Feedback en pantalla
# --------------------------------------------------------------------------

func _present_feedback(text: String, color: Color) -> void:
	if not show_feedback or text.is_empty():
		return
	_ensure_feedback_hud()
	if _feedback_label == null:
		return
	if _feedback_tween != null and _feedback_tween.is_valid():
		_feedback_tween.kill()
	_feedback_label.text = text
	_feedback_label.add_theme_color_override("font_color", color)
	_feedback_label.modulate.a = 1.0
	_feedback_label.visible = true
	_feedback_tween = create_tween()
	_feedback_tween.tween_interval(maxf(feedback_duration, 0.1))
	_feedback_tween.tween_property(_feedback_label, "modulate:a", 0.0, 0.4)
	_feedback_tween.tween_callback(_hide_feedback_label)


func _hide_feedback_label() -> void:
	if _feedback_label != null and is_instance_valid(_feedback_label):
		_feedback_label.visible = false


## Crea el HUD del feedback la primera vez que hace falta. Es propio del
## spawner para no depender de que la escena tenga un HUD de construccion.
func _ensure_feedback_hud() -> void:
	if _feedback_label != null and is_instance_valid(_feedback_label):
		return
	_feedback_layer = CanvasLayer.new()
	_feedback_layer.name = "DoctorFeedback"
	_feedback_layer.layer = 12
	add_child(_feedback_layer)

	_feedback_label = Label.new()
	_feedback_label.name = "Message"
	_feedback_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_feedback_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_feedback_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_feedback_label.add_theme_font_size_override("font_size", 20)
	_feedback_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_feedback_label.add_theme_constant_override("outline_size", 6)
	_feedback_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_feedback_label.offset_left = -420
	_feedback_label.offset_right = 420
	_feedback_label.offset_top = -132
	_feedback_label.offset_bottom = -84
	_feedback_label.visible = false
	_feedback_layer.add_child(_feedback_label)


## Etiqueta flotante para distinguir al medico de los NPCs normales. Todos usan
## el mismo modelo, asi que sin esto parece que "respawneara" otra persona.
func _add_doctor_tag(npc: NpcAgent) -> void:
	if npc.has_node("DoctorTag"):
		return
	var tag := Label3D.new()
	tag.name = "DoctorTag"
	tag.text = "MÉDICO"
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.font_size = 48
	tag.pixel_size = 0.004
	tag.outline_size = 14
	tag.modulate = Color(0.75, 1.0, 0.85)
	tag.outline_modulate = Color(0.0, 0.0, 0.0, 0.9)
	tag.position = Vector3(0.0, 2.15, 0.0)
	npc.add_child(tag)


## El medico no se distrae con otras necesidades: solo puede elegir `work`,
## que es la affordance del objeto especial `work_desk`.
func _force_work_only(npc: NpcAgent) -> void:
	npc.wander = false
	var brain := npc.get_node_or_null("NpcBrain") as NpcBrain
	if brain == null:
		return
	brain.needs = {&"work": 1.0}
	brain.need_growth = {&"work": 0.0}
	brain.need_affordances = {&"work": &"work"}
	brain.need_threshold = 0.0
	brain.search_radius = 0.0
	brain.set_enabled(true)


## El medico es unico y manual: no lo frena el tope de poblacion de los
## spawners automaticos.
func can_spawn() -> bool:
	if not enabled or npc_scene == null:
		return false
	if not _nav_ready():
		return false
	if require_objective and not has_objective():
		return false
	if min_player_distance > 0.0 and _player_near_spawn_point():
		return false
	return true


func _ensure_input_action() -> void:
	if not InputMap.has_action(summon_action):
		InputMap.add_action(summon_action, 0.5)
	if not InputMap.action_get_events(summon_action).is_empty():
		return
	var event := InputEventKey.new()
	event.physical_keycode = summon_key
	InputMap.action_add_event(summon_action, event)
