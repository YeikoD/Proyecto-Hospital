# Documento técnico — Navegación de NPCs sobre la grilla

| Campo | Valor |
| --- | --- |
| Proyecto | Proyecto Hospital (Godot 4.7) |
| Módulos | `res://scripts/sistemas/build/`, `res://scripts/Characters/npc/` |
| Versión del documento | 1.0 |
| Estado | Implementado y verificado |
| Fecha | 2026-11-08 |
| Motor verificado | Godot 4.7.2 stable |

---

## 1. Objetivo

Los NPC deben caminar por el hospital construido con la grilla, respetar las
paredes y reaccionar cuando el jugador coloca o borra piezas en modo
construcción.

La estrategia es:

1. Las piezas colocadas viven dentro de un `NavigationRegion3D`.
2. El NavMesh se hornea desde la geometría de esas piezas: suelos caminables y
   paredes como obstáculos.
3. Cada cambio de piezas dispara un rebake asincrónico con *debounce*.
4. Cada NPC usa un `NavigationAgent3D`; para moverlo basta con asignar
   `agent.target_position` (encapsulado en `NpcAgent.move_to()`).

---

## 2. Arquitectura

### 2.1 Nodos de `build_system.tscn`

```
BuildSystem
├── BuildGrid              (BuildGrid)            Matemática de la grilla
├── BuildCamera            (BuildCamera)          Cámara orbital de obra
├── NavRegion              (NavigationRegion3D)   Región navegable
│   └── PlacedPieces       (Node3D)               Piezas colocadas
├── BuildController        (BuildController)      Colocación / borrado
└── BuildNavigation        (BuildNavigation)      Horneado y sincronización
```

`PlacedPieces` es hijo de `NavRegion` a propósito: el horneado de
`NavigationRegion3D` recorre sus hijos y usa los `StaticBody3D` como geometría
fuente. Si el contenedor queda fuera de la región, el NavMesh no incluye las
piezas.

### 2.2 Archivos

| Archivo | Responsabilidad |
| --- | --- |
| `scripts/sistemas/build/build_navigation.gd` | Configura el NavMesh, escucha cambios, aplica debounce y hornea. |
| `scripts/sistemas/build/build_system.tscn` | Ensambla grilla, cámara, `NavRegion`, controlador y navegación. |
| `scripts/sistemas/build/build_controller.gd` | Emite `pieces_changed` y expone la API de colocación. |
| `scripts/Characters/npc/npc_agent.gd` | `CharacterBody3D` con `NavigationAgent3D`, deambular y animación. |
| `scripts/Characters/npc/npc.tscn` | Prefab de NPC con el modelo y las animaciones del jugador. |
| `scenes/demo/nav_demo.tscn` | Demo con habitaciones, puertas, 4 NPC y HUD. |
| `tests/nav_smoke_test.gd` | Prueba headless del NavMesh y del rebake. |

---

## 3. Horneado del NavMesh

### 3.1 Geometría fuente

`BuildNavigation._apply_settings()` configura el `NavigationMesh`:

```gdscript
mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
mesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN
mesh.geometry_collision_mask = 1
```

- **Suelos:** su cara superior coincide con el plano de construcción, por lo que
  Recast genera superficies caminables a esa altura.
- **Paredes:** sus cajas de colisión se rasterizan y recortan el área. El agente
  no puede atravesarlas.
- Se parsean colliders en vez de mallas porque las piezas son `StaticBody3D` con
  `BoxShape3D`; es más rápido que sincronizar mallas desde el hilo de horneado.

### 3.2 Parámetros por defecto

| Parámetro | Valor | Uso |
| --- | --- | --- |
| `agent_radius` | `0.3 m` | Erosión alrededor de paredes. Permite puertas de 1 celda. |
| `agent_height` | `1.7 m` | Altura libre necesaria. |
| `agent_max_climb` | `0.2 m` | Escalón máximo. |
| `cell_size` / `cell_height` | `0.1 m` | Resolución del NavMesh y del mapa. |
| `bake_delay` | `0.35 s` | Debounce para agrupar cambios. |
| `bounds_padding` | `1.0 m` | Margen del volumen de horneado. |

El tamaño de celda del mapa se sincroniza con el del `NavigationMesh`:

```gdscript
NavigationServer3D.map_set_cell_size(map, cell_size)
NavigationServer3D.map_set_cell_height(map, cell_height)
```

Si ambos no coinciden, el servidor puede descartar conexiones entre polígonos.

### 3.3 Límite vertical del horneado

Las paredes miden `2.8 m`. Sin límite, Recast podría generar NavMesh sobre sus
caras superiores. Para evitarlo, `BuildNavigation` calcula un
`filter_baking_aabb` que:

- cubre la grilla completa más `bounds_padding`;
- empieza `0.5 m` debajo del plano;
- termina por debajo de la altura de la pared
  (`min(agent_height + 0.5, wall_height - 0.05)`).

Así las paredes siguen bloqueando dentro del volumen, pero sus techos quedan
fuera y no se hornean como superficie caminable.

### 3.4 Flujo de rebake

```
BuildController coloca/borra una pieza
		│
		└── pieces_changed
				│
				└── BuildNavigation.request_bake()
						│
						└── Timer 0.35 s (se reinicia con cada cambio)
								│
								└── bake_now()
										│
										└── NavigationRegion3D.bake_navigation_mesh(true)
												│
												└── bake_finished
														│
														├── bake_count += 1
														└── navigation_baked
```

Detalles:

- Mientras se pinta con el ratón, el temporizador se reinicia y solo se hornea
  al dejar de construir.
- Si llega un cambio durante un horneado, `_dirty` queda activo y se programa
  otro al terminar.
- Si no hay suelos, se llama a `NavigationMesh.clear()` y se fuerza la
  actualización de la región; no se hornea un NavMesh vacío.
- `navigation_baked` se emite también al limpiar, para que la UI y los tests
  puedan reaccionar.

### 3.5 API de `BuildNavigation`

```gdscript
signal navigation_bake_started
signal navigation_baked

var bake_count: int

func request_bake() -> void          # rebake con debounce
func bake_now() -> void              # horneado inmediato
func is_baking() -> bool
func get_polygon_count() -> int
```

---

## 4. NPC

### 4.1 Prefab

`scripts/Characters/npc/npc.tscn` replica la estructura del jugador, pero sin el controlador FPS,
la cámara, el hueso de cabeza ni la linterna:

```
NPC (CharacterBody3D, NpcAgent)
├── CollisionShape3D         (cápsula 0.35 × 1.8)
├── Visual                   (se rota hacia la dirección de movimiento)
│   └── human                (human.glb + animaciones)
│       └── AnimationTree
├── AnimController           (player_library.tres)
└── NavigationAgent3D
```

El modelo `human.glb` conserva la rotación de 180° que usa el jugador para
quedar mirando hacia `-Z`. `NpcAgent` gira el nodo `Visual`, no el cuerpo físico,
para que la cápsula y el agente de navegación no se vean afectados.

`NpcAgent` detecta automáticamente:

- el `NavigationAgent3D` hijo;
- el nodo llamado `Visual`;
- el `AnimationController`.

También se pueden asignar `agent_path`, `visual_path` y
`animation_controller_path` en el inspector.

### 4.2 Movimiento

```gdscript
func _physics_process(delta):
	if _agent.is_navigation_finished():
		...
		return

	var next := _agent.get_next_path_position()
	var direction := (next - global_position)
	direction.y = 0.0
	...
	velocity.x = move_toward(...)
	velocity.z = move_toward(...)
	move_and_slide()
```

La altura del camino se ignora para el movimiento horizontal; la gravedad y
`move_and_slide()` se encargan de mantener al NPC apoyado en el suelo.

### 4.3 Deambular

Con `wander = true`, el NPC:

1. Elige un ángulo y una distancia aleatoria dentro de `wander_radius`.
2. Busca el punto más cercano del NavMesh.
3. Descarta el candidato si está a más de `1.5 m` del NavMesh o demasiado cerca
   del origen.
4. Comprueba que exista un camino con `NavigationServer3D.map_get_path()`.
5. Asigna `agent.target_position` y camina.
6. Al llegar, espera `pause_time` y repite.

Si todavía no hay NavMesh (por ejemplo, al arrancar la escena), reintenta cada
`0.5 s`.

### 4.4 API pública

```gdscript
func move_to(world_position: Vector3) -> void
func stop() -> void
func is_moving() -> bool
func get_target() -> Vector3
```

Ejemplo:

```gdscript
var npc: NpcAgent = get_node("NPCs/NPC1")
npc.move_to(Vector3(10.0, 0.0, 4.0))
```

`move_to()` ajusta el destino al punto más cercano del NavMesh, por lo que se
puede pasar una posición aproximada.

### 4.5 Rebake y caminos activos

`NpcAgent` se conecta a `NavigationServer3D.map_changed`. Cuando
`BuildNavigation` termina de hornear, el agente vuelve a asignar su
`target_position` para que recalcule el camino. Si el destino quedó
inaccesible, `NavigationAgent3D` lo acerca al punto alcanzable y el NPC elige
otro destino al terminar.

### 4.6 Animación

`NpcAgent` llama a `AnimationController.set_speed()` cada frame con la velocidad
horizontal. El controlador decide el punto del *blend* de locomoción
(*idle* / caminar / correr). En `_ready()` se ajustan los puntos del blend a la
velocidad del NPC:

```gdscript
_anim.sync_locomotion_points(speed, speed * 1.6)
```

---

## 5. Demo

`scenes/demo/nav_demo.tscn`:

- Construye por código dos habitaciones de 4×6 celdas.
- Incluye una puerta exterior de 2 celdas, una división central con puerta de
  2 celdas y un muro interior con puerta de **1 celda**.
- Coloca 4 NPC sobre los suelos.
- Muestra en pantalla el estado del NavMesh (polígonos / horneando).
- Los caminos de los agentes se dibujan en rojo (`debug_enabled = true`).

Para probar:

1. Ejecutar `scenes/demo/nav_demo.tscn`.
2. Observar a los NPC deambular y atravesar las puertas.
3. Pulsar **B**, elegir pared (2) y cerrar una puerta.
4. Al terminar el debounce, el NavMesh se rehornea y los NPC rodean el nuevo
   obstáculo.

---

## 6. Pruebas

```powershell
Godot.exe --headless --path . --script res://tests/nav_smoke_test.gd
```

La prueba:

1. Carga `scenes/demo/nav_demo.tscn`.
2. Verifica que se construyeron suelos y paredes.
3. Espera el horneado y comprueba que hay polígonos.
4. Verifica que ningún vértice caminable quede a la altura de las paredes.
5. Comprueba que existe camino entre las dos habitaciones.
6. Comprueba el paso por la puerta de 1 celda.
7. Coloca una pared que cierra esa puerta, espera un nuevo `bake_count` y
   verifica que el camino se alarga (rodea el obstáculo).
8. Envía un NPC a un destino y comprueba que lo ajusta al NavMesh.

Resultado esperado:

```
NAV_SMOKE_TEST_OK
```

---

## 7. Rendimiento y límites

### 7.1 Rendimiento

- El horneado corre en un hilo (`bake_navigation_mesh(true)`), por lo que no
  bloquea el frame principal.
- El debounce evita un horneado por cada celda pintada.
- Parsear colliders es más barato que parsear mallas.
- La resolución de `0.1 m` es adecuada para una grilla de 1 m, pero encarece el
  horneado en áreas muy grandes. Si aparece un problema de rendimiento, subir
  `cell_size` a `0.15` o `0.2` y aumentar `agent_radius` en consecuencia.

### 7.2 Límites conocidos

- **Una sola planta plana.** No hay escaleras, rampas ni ascensores.
- **Sin puertas dinámicas.** Una puerta es un hueco entre paredes; no hay
  prefab de puerta que se abra/cierre.
- **Sin evitación entre NPCs.** `avoidance_enabled` está desactivado; los NPC se
  atraviesan entre sí (colisionan con el escenario).
- **Paredes de altura variable.** El límite vertical asume que las paredes son
  más altas que `agent_height + 0.5`; paredes muy bajas podrían generar
  superficies caminables sobre su parte superior.
- **Sin persistencia.** Al reiniciar la escena se pierde la construcción y el
  NavMesh se reconstruye desde cero.
- **`NavigationRegion3D` es experimental** en Godot 4.7; el flujo está
  verificado con 4.7.2.

---

## 8. Referencias

- `scripts/sistemas/build/build_navigation.gd`
- `scripts/sistemas/build/build_system.tscn`
- `scripts/sistemas/build/build_controller.gd`
- `scripts/Characters/npc/npc_agent.gd`
- `scripts/Characters/npc/npc.tscn`
- `scenes/demo/nav_demo.tscn`
- `tests/nav_smoke_test.gd`
- `scripts/sistemas/build/README.md`
- `docs/sistema-grilla.md`
