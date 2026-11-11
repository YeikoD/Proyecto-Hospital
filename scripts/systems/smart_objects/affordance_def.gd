class_name AffordanceDef
extends Resource

## Acción que un SmartObject ofrece a la IA ("sentarse", "dormir", "usar"...).
##
## La IA nunca conoce el mueble: pide un `id` de affordance y el objeto decide
## si tiene un slot libre que la acepte.

## Identificador de la acción: "sit", "sleep", "use", ...
@export var id: StringName = &""

## Etiqueta de slot que acepta. Vacío = cualquier slot.
@export var slot_tag: StringName = &""

## Duración de la interacción en segundos. Negativo = hasta que la IA la corte.
@export var duration := 8.0

## Animación opcional que el NPC reproduce mientras usa el objeto.
## Vacío = el NPC se queda en idle.
## (Solo para clips que ya existan en la librería de locomotion.)
@export var animation: StringName = &""

## Secuencia completa de interacción: entrada, loop y salida. Si se asigna,
## el NPC se alinea al POI del slot y reproduce las tres fases; `animation`
## queda ignorado.
@export var animation_set: SmartAnimationSet

## Peso base para el selector de utilidad. Más alto = más atractivo.
@export var base_score := 1.0

## Efectos sobre las necesidades del NPC al terminar: {"rest": 0.5, ...}.
@export var needs_effects: Dictionary = {}
