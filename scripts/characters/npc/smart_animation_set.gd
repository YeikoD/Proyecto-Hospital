class_name SmartAnimationSet
extends Resource

## Secuencia de animaciones de una interacción completa.
##
## Un SmartObject puede declarar, por ejemplo, "sentarse": una animación de
## entrada, un loop natural mientras dura la interacción y una animación de
## salida. Cada fase puede venir de un archivo distinto (GLB, escena o
## biblioteca) y el `NpcAnimationManager` se encarga de retargetearla al
## esqueleto del NPC.
##
## Si `enter_clip`/`loop_clip`/`exit_clip` están vacíos se usa el primer clip
## del archivo correspondiente.

@export_group("Entrada")
## Archivo con la animación de entrada (por ejemplo, un .glb de Mixamo).
@export_file("*.glb", "*.tscn", "*.res") var enter_source := ""
## Nombre del clip dentro del archivo. Vacío = el primero.
@export var enter_clip: StringName = &""

@export_group("Loop")
## Archivo con la animación de loop mientras el NPC usa el objeto.
@export_file("*.glb", "*.tscn", "*.res") var loop_source := ""
@export var loop_clip: StringName = &""

@export_group("Salida")
## Archivo con la animación de salida (levantarse, soltar, etc.).
@export_file("*.glb", "*.tscn", "*.res") var exit_source := ""
@export var exit_clip: StringName = &""

@export_group("Transiciones")
## Crossfade por defecto entre fases, en segundos.
@export var xfade := 0.2
## Crossfade al entrar desde el locomotion. 0 = corte directo.
@export var enter_fade := 0.15


func has_enter() -> bool:
	return enter_source != ""


func has_loop() -> bool:
	return loop_source != ""


func has_exit() -> bool:
	return exit_source != ""


func has_any() -> bool:
	return has_enter() or has_loop() or has_exit()
