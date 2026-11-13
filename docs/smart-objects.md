# SmartObjects (objetos interactivos)

Sistema de objetos con los que la IA interactúa. Un SmartObject es un mueble o
prop que **anuncia acciones** ("affordances") y **presta slots** de uso. La IA
elige, reserva, camina, usa y libera. El objeto nunca mueve al NPC.

Los SmartObjects son también items del sistema Build: se colocan desde el menú
(`M`), respetan la grilla, se borran con la herramienta y su collider entra al
NavMesh como cualquier pieza.

## Flujo

```
BuildItem (.tres)
  └─ smart_object: SmartObjectDef
       └─ affordances: [AffordanceDef]
              id = "sit", slot_tag = "seat", duration, needs_effects

Escena del mueble (raíz SmartObject, extends BuildPiece)
  ├─ Slot_0, Slot_1...      Marker3D: dónde se usa
  ├─ POI_0, POI_1...        Marker3D: pose exacta del NPC (posición + hacia dónde mira)
  └─ Approach_0...          Marker3D opcional: por dónde se llega y a dónde se vuelve

AffordanceDef
  ├─ duration                  segundos de uso (se cuentan desde que empieza el loop)
  └─ animation_set: SmartAnimationSet
       ├─ enter_source/clip    animación de entrada
       ├─ loop_source/clip     loop natural mientras dura la interacción
       └─ exit_source/clip     animación de salida

NpcBrain
  necesidades → SmartObjectRegistry.claim_best()
             → reserva slot (antes de caminar)
             → NpcAgent.move_to(Approach)  (llega caminando de verdad)
             → occupy + NpcAnimationManager.play_at(POI, Approach)
             → enter → loop (arranca la duración) → exit → finished
             → release (o abort con timeout)
```

El cuerpo del NPC **no se teletransporta** al mueble: camina hasta el
`Approach_<slot>` (el punto caminable más cercano) y recién entonces empieza la
secuencia. La diferencia entre esa posición y el `POI` se resuelve moviendo el
modelo visual de forma suave durante la animación de entrada.

## Archivos

```
scripts/systems/smart_objects/
├── smart_object.gd            Nodo colocado: slots, reservas y estados
├── smart_object_def.gd        Acciones que anuncia el objeto
├── affordance_def.gd          Una acción concreta ("sit", "sleep", ...)
├── smart_object_registry.gd   Índice estático global + claim_best()
├── special_object_def.gd      Receta de combinación de piezas
├── special_object.gd          SmartObject formado por varias piezas
└── special_object_loader.gd   Carga de recetas de objetos especiales

prefabs/items/chair.tscn       Silla de ejemplo (Slot + POI + Approach)
scripts/characters/npc/
├── npc_agent.gd               Locomoción + señal `arrived` + frozen
├── npc_brain.gd               Necesidades → utilidad → FSM
├── npc_animation_manager.gd   Secuencias enter/loop/exit + retargeting + POI
└── smart_animation_set.gd     Recurso con las tres fases
data/smart_objects/
├── sit.tres                   Affordance "sit" (usa sit_animations.tres)
├── sit_animations.tres        Secuencia de la silla
├── seat.tres                  Definición "seat" (reutilizable)
├── work.tres                  Affordance "work" del escritorio de trabajo
└── work_desk.tres             Definición del escritorio de trabajo
tests/smart_object_smoke_test.gd
tests/special_object_smoke_test.gd
tests/animation_manager_smoke_test.gd
```

## Cómo agregar un mueble interactivo

1. **Definición**: creá un `SmartObjectDef` en `res://data/smart_objects/`
   (o reutilizá uno existente como `seat.tres`) y asignale las affordances.
2. **Prefab**: creá una escena con raíz `SmartObject` (hereda `BuildPiece`).
   Agregá `Slot_0`, `Slot_1`... como `Marker3D` hijos y, opcionalmente,
   `POI_0`, `POI_1`... y `Approach_0`, `Approach_1`...:
   - Los slots se recogen por nombre; el orden es `Slot_0`, `Slot_1`, ...
   - `POI_<slot>` define la pose del NPC durante la interacción: el origen es
     la posición del CharacterBody y el `-Z` local es hacia dónde mira el
     modelo. Si no existe, se usa el slot bajado al piso.
   - `Approach_<slot>` es el punto exterior de llegada y de salida. Si no
     existe, se calcula separándose del POI sobre su frente.
   - Un slot puede declarar `slot_tag` como metadato para aceptar solo ciertas
     affordances.
   - **No hace falta** que el prefab tenga raíz `SmartObject`: si el `BuildItem`
     define `smart_object`, un modelo plano (`.glb`) se envuelve
     automáticamente. En ese caso se crea `Slot_0` a media altura del AABB y el
     POI se corre hacia el frente para que el NPC quede sentado sobre el
     asiento y no sobre el respaldo.
3. **Item**: creá un `BuildItem` `.tres` en `res://data/build_items/...` con
   `object_type = "furniture"` (o `"prop"`), `scene` apuntando al prefab y
   `smart_object` apuntando a la definición.
4. Aparece solo en el menú (`M`). Para colocarlo: seleccioná el item, clic en el
   suelo, `R` para rotar.

## API de `SmartObject`

```gdscript
var obj: SmartObject = controller.get_object_at(Vector2i(6, 4))

obj.get_affordance(&"sit")          # AffordanceDef o null
obj.has_free_slot(&"sit")           # bool
var slot := obj.reserve(&"sit", agent_id)  # int o -1 (atómico)
obj.occupy(slot, agent_id)          # el NPC llegó
obj.release(slot, agent_id)         # solo el dueño puede liberar
obj.release_agent(agent_id)         # limpieza por si el agente murió
obj.get_use_position(slot)          # Vector3 del Marker3D
obj.get_use_transform(slot)         # Transform3D del slot
obj.get_poi_transform(slot)         # pose de alineación del NPC
obj.get_approach_position(slot)     # punto exterior sugerido
obj.get_approach_transform(slot)    # pose de salida (posición + yaw)
```

Señales: `slot_reserved`, `slot_released`, `used`.

## API del registry

```gdscript
SmartObjectRegistry.find_candidates(&"sit", from, max_distance, agent_id)
SmartObjectRegistry.claim_best(&"sit", from, max_distance, agent_id)  # reserva
SmartObjectRegistry.release_all(agent_id)
SmartObjectRegistry.get_count()
```

Es estático, así que no requiere autoload y funciona igual en tests headless.
Los objetos se registran solos en `_ready` y se dan de baja en `_exit_tree`.

## Cerebro del NPC

`NpcBrain` (hijo del NPC) trae un FSM mínimo:

```
IDLE → SEEK → TRAVEL → USE → IDLE
                   ↘ timeout / objeto borrado → release + IDLE
```

- `needs`: `{"rest": 0.0}` (0..1, más alto = más urgente).
- `need_growth`: cuánto sube por segundo (`rest` 0.01).
- `need_affordances`: `{"rest": "sit"}`.
- `need_threshold`: a partir de qué valor busca objeto.
- `search_radius`, `think_interval`, `travel_timeout`.

Los NPCs normales solo descansan en sillas. La necesidad `work` y su
affordance están reservadas al NPC médico (grupo `doctor_npcs`): el cerebro
ignora `work` para cualquier otro NPC y el selector de ruta tampoco la elige.
Además, un objeto especial puede reservar ciertas affordances a un grupo con
`exclusive_group` + `exclusive_affordances`. El Escritorio de trabajo reserva
`work` al médico, pero deja `sit` disponible: los asientos de pacientes del
conjunto solo se usan a través del selector de **consultorio** (zona `consult`
+ médico trabajando + silla libre). El descanso aleatorio y el desvío de ruta
ignoran el `work_desk`, así que nadie se sienta allí por azar.

Si la necesidad más urgente no tiene un SmartObject libre (por ejemplo, todas
las sillas están ocupadas), el cerebro prueba la siguiente necesidad antes de
quedarse esperando.

La reserva ocurre en `SEEK`, **antes** de caminar: dos NPC no eligen la misma
silla y no pierden el viaje. Cualquier salida anormal (timeout, objeto borrado,
cerebro desactivado) pasa por `_abort()`, que libera el slot.

`NpcBrain.enabled` viene en `false` en `npc.tscn` para no cambiar el
comportamiento de las demos existentes. Se activa con `set_enabled(true)` o
desde el inspector.

## Animaciones de interacción (enter → loop → exit)

Un `AffordanceDef` puede apuntar a un `SmartAnimationSet` con tres fases. El
manager vive en `npc.tscn` (`NpcAnimationManager`) y no sabe nada de sillas ni
de SmartObjects: sólo recibe un set, un POI y un punto de salida.

```
NpcAnimationManager
  play_at(set, poi, exit_transform, soft_align = true)
    ├─ congela al NPC y desactiva su colisión
    ├─ desplaza el modelo hasta el POI (suave, sin mover el cuerpo)
    ├─ enter   (una vez)
    ├─ loop    (loop_mode linear)  → emite loop_started
    ├─ exit    (request_exit) → el modelo vuelve al punto de salida
    └─ finished → reactiva la colisión
```

Señales: `phase_started(phase)`, `loop_started`, `finished`, `canceled`.

### El recurso `SmartAnimationSet`

```gdscript
@export_file("*.glb", "*.tscn", "*.res") var enter_source
@export var enter_clip: StringName
@export_file("*.glb", "*.tscn", "*.res") var loop_source
@export var loop_clip: StringName
@export_file("*.glb", "*.tscn", "*.res") var exit_source
@export var exit_clip: StringName
@export var xfade := 0.2
@export var enter_fade := 0.15
```

Si un clip se deja vacío se usa el primero del archivo. Los archivos pueden ser
GLB de Mixamo, escenas o recursos con un `AnimationPlayer`.

### Retargeting

Las animaciones de Mixamo traen tracks de **nodo** (`Scene/Armature/mixamorig_*`)
y el NPC usa tracks de **hueso** (`Armature/Skeleton3D:mixamorig_*`). El manager
convierte en runtime:

- rotaciones de hueso: se copian directo (el rig comparte las mismas rotaciones
  de reposo);
- posición de la cadera: se toma el delta contra la pose de reposo del archivo
  de origen y se reescala a la altura/rest del esqueleto del NPC;
- se ignoran nodos que no sean huesos del NPC.

No hace falta hornear ni duplicar los GLB: el primer uso de cada archivo lo
cachea en memoria.

### POI y alineación

El POI no es el slot: es la pose exacta del personaje. Para una silla con el
respaldar en `+Z` y el frente en `-Z`, `POI_0` se coloca delante del asiento
(`z ≈ -0.3` en la silla de ejemplo) con `basis` identidad. La animación de
Mixamo mueve la cadera hacia atrás al sentarse, así que el origen del POI queda
donde están los pies al empezar a sentarse.

La IA camina hasta `Approach_<slot>` (el punto caminable más cercano al
mueble) y sólo entonces llama a `play_at`. El manager no mueve el cuerpo:

- calcula `offset = POI - posición real del cuerpo` (en espacio local);
- desplaza el nodo `Visual` hasta ese offset con `align_duration` (0.4 s por
  defecto), mientras corre la animación de entrada;
- al salir, devuelve el `Visual` a su posición original con
  `exit_return_duration` (0.35 s), acompañando la animación de levantarse.

Así no hay teletransporte ni deslizamiento del cuerpo: el NPC llega caminando,
se sienta con un pequeño desplazamiento del modelo y al levantarse vuelve a
quedar donde llegó. `max_soft_align_distance` (1.5 m) evita que un llamado
directo a `play_at` desde lejos genere un deslizamiento enorme: en ese caso se
cae al modo clásico de alinear el cuerpo al POI.

Mientras la secuencia está activa el NPC queda congelado y sin collider. Al
terminar (o abortar) el manager reactiva la colisión; el cerebro recién
entonces lo descongela.

### Duración

`AffordanceDef.duration` empieza a contar cuando arranca el loop, no al llegar.
Así una animación de entrada más larga no recorta el tiempo de uso. Un valor
negativo mantiene al NPC en loop hasta que algo lo interrumpa.

### Ejemplo completo

`data/smart_objects/sit_animations.tres`:

```
enter_source = "res://assets/animations/sitting_enter_fit_anim_only.glb"
loop_source  = "res://assets/animations/sitting_idle_loop_fit_anim_only.glb"
exit_source  = "res://assets/animations/sitting_exit_fit_anim_only.glb"
```

y `sit.tres` referencia ese set con `animation_set`. Con eso, cualquier mueble
que use la affordance `sit` obtiene automáticamente la secuencia completa.

Para otro mueble (cama, ducha, máquina) alcanza con:

1. exportar los tres GLB;
2. crear un `SmartAnimationSet` con las rutas;
3. asignarlo al `AffordanceDef`;
4. agregar `POI_<slot>` y `Approach_<slot>` al prefab.

Si el mueble sólo necesita una animación sostenida que ya existe en
`assets/animations/player_library.tres`, se puede seguir usando `AffordanceDef.animation`
con `NpcAgent.play_interaction()`.

## Integración con Build y NavMesh

- Colocar un objeto emite `object_placed` y `pieces_changed`; `BuildNavigation`
  rehornea con debounce. El collider del mueble recorta el NavMesh.
- `require_floor_for_objects` (en `BuildController`) exige un suelo debajo.
- La huella multi-celda se reorienta al rotar: un mueble 2x1 pasa a ocupar 1x2
  y su pivote se ubica en el centro de la huella (entre las dos celdas).
- Los modelos GLB con el pivote descentrado (por ejemplo apoyado en una pata)
  se recentran automáticamente en X/Z al colocarlos.
- Los objetos se colocan sobre una sub-grilla de 0,5 m (`BuildGrid.subdivisions`).
  La celda ancla no cambia, pero la huella ocupada se recalcula según el
  desplazamiento fino, de modo que un mueble desplazado puede cubrir una celda
  adicional.
- Algunos muebles pueden **combinarse** en un objeto especial: por ejemplo,
  colocar una silla de escritorio delante de un escritorio forma el SmartObject
  "Escritorio de trabajo". Ver
  [objetos especiales](objetos-especiales.md).
- Al borrar, el orden de prioridad es **objeto → pared → suelo**.
- La IA mueve al NPC a `get_approach_position()`: el `NavigationAgent3D` lo
  ajusta a la superficie caminable, así el NPC nunca intenta entrar al
  collider del mueble. El resto de la distancia hasta el `POI` lo cubre el
  desplazamiento suave del modelo.

## Demo

```powershell
Godot.exe --path . res://scenes/demos/smart_object_demo.tscn
```

Cuatro NPC con la necesidad `rest` alta buscan las sillas repartidas por las
habitaciones.

Para población generada en runtime (aparece, usa un objeto y desaparece), ver
[spawners de NPCs](npc-spawners.md).

## Pruebas

```powershell
Godot.exe --headless --path . --script res://tests/smart_object_smoke_test.gd
Godot.exe --headless --path . --script res://tests/animation_manager_smoke_test.gd
Godot.exe --headless --path . --script res://tests/special_object_smoke_test.gd
```

`smart_object_smoke_test.gd` verifica colocación, huella/ocupación, rebake,
affordances, reserva exclusiva, claim del registry, integración completa con
`NpcBrain`, la secuencia animada de la silla y liberación al borrar.

`animation_manager_smoke_test.gd` verifica el retargeting, las tres fases,
la alineación al POI (incluida la altura de la cadera sobre el asiento), la
colisión desactivada durante el uso y la vuelta al punto de salida.

## Límites actuales

- Una interacción por slot; todavía no hay colas de espera.
- `duration` fija (o infinita con valor negativo); no hay condiciones de corte
  por estado del objeto (roto, sucio, ocupado por otro).
- El retargeting asume un rig Mixamo con los mismos nombres y rotaciones de
  reposo. Para otros esqueletos haría falta un mapa de huesos.
- No hay IK ni extracción de root motion: la altura y el desplazamiento salen
  de la cadera del clip.
- Sin persistencia de objetos ni de reservas.
- La navegación sigue siendo de una sola planta plana.
