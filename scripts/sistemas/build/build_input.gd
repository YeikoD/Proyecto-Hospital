class_name BuildInput
extends RefCounted

## Acciones de entrada del sistema de construccion.
##
## Se crean al vuelo si no existen en Project Settings, igual que hace el
## FPSController, para que el modulo funcione sin tocar la configuracion.


static func ensure_actions() -> void:
	_ensure("build_toggle", [KEY_B])
	_ensure("build_tool_floor", [KEY_1])
	_ensure("build_tool_wall", [KEY_2])
	_ensure("build_tool_erase", [KEY_3])
	_ensure("build_raise", [KEY_E])
	_ensure("build_lower", [KEY_Q])


static func _ensure(action: StringName, keys: Array) -> void:
	if InputMap.has_action(action) and not InputMap.action_get_events(action).is_empty():
		return
	if not InputMap.has_action(action):
		InputMap.add_action(action, 0.5)
	for key: Key in keys:
		var event := InputEventKey.new()
		event.physical_keycode = key
		InputMap.action_add_event(action, event)
