# Sistema de construcción y navegación (grilla base)

Módulo de construcción estilo Sims para Godot 4.7. Implementa una grilla con
*snapping*, previsualización de piezas, colocación / borrado de suelos y paredes,
y un NavMesh que se rehornea solo para que los NPC puedan caminar por lo
construido.

## Probar

### Demo de construcción

1. Abrir `scenes/build_demo.tscn` en Godot.
2. Ejecutar la escena (F6).
3. Pulsar **B** para entrar al modo construcción.

### Demo de navegación

1. Abrir `scenes/demo/nav_demo.tscn` en Godot.
2. Ejecutar la escena (F6).
3. Los NPC deambulan por las habitaciones. Pulsar **B** y colocar o borrar una
   pared: el NavMesh se rehornea y los NPC recalculan su camino.

También se puede correr desde consola:

```powershell
Godot.exe --path . res://scenes/build_demo.tscn
Godot.exe --path . res://scenes/demo/nav_demo.tscn
```

## Controles

| Entrada | Acción |
| --- | --- |
| `B` | Entrar / salir del modo construcción |
| `1` | Herramienta suelo |
| `2` | Herramienta pared |
| `3` | Herramienta borrar |
| Clic izquierdo | Colocar / borrar (arrastrar pinta varias celdas) |
| Clic derecho / central + arrastrar | Orbitar la cámara |
| Rueda | Zoom |
| `WASD` | Desplazar la cámara |
| `Q` / `E` | Bajar / subir el foco de la cámara |
| `Esc` | Salir del modo construcción |

## Integrarlo en una escena

La forma más simple es arrastrar `scripts/sistemas/build/build_system.tscn` a la escena.
La escena ya incluye:

```
BuildSystem
├── BuildGrid
├── BuildCamera
├── NavRegion                 (NavigationRegion3D)
│   └── PlacedPieces          (piezas colocadas, dentro del NavRegion)
├── BuildController
└── BuildNavigation
```

Pasos recomendados:

1. Añadir `scripts/sistemas/build/build_system.tscn` como hijo de la escena.
2. Mover el nodo `BuildSystem` (o su hijo `BuildGrid`) a la altura donde debe
   quedar el plano de construcción.
3. Ajustar en `BuildGrid`:
   - `cells_x` / `cells_z`: tamaño de la grilla en celdas.
   - `cell_size`: tamaño de cada celda en metros.
   - `plane_y`: altura del plano respecto del nodo.
4. Ajustar en `BuildController` (opcional):
   - `wall_height`, `wall_thickness`, `floor_thickness`.
   - `floor_scene` / `wall_scene` para usar otros prefabs.
5. Para NPCs, instanciar `scripts/characters/npc/npc.tscn` o añadir un `NavigationAgent3D` +
   `NpcAgent` a un personaje propio.

El sistema busca solo la grilla, la cámara, el `FPSPlayer`, el `NavRegion` y el
`BuildController` que ya existan. `PlacedPieces` debe estar **dentro** de
`NavRegion`; si se mueve, asignar `pieces_root` en el inspector. Lo mismo vale
para `navigation_region` y `build_controller` en `BuildNavigation`.

## Navegación de NPCs

### Cómo funciona el horneado

- `NavRegion` es un `NavigationRegion3D` cuyos hijos son las piezas colocadas.
- `BuildNavigation` escucha la señal `pieces_changed` de `BuildController`.
- Cada cambio (colocar o borrar un suelo/pared) reinicia un temporizador de
  `0.35 s`; al vencer, hornea el NavMesh en un hilo con
  `bake_navigation_mesh(true)`.
- El horneado parsea los `StaticBody3D` con `BoxShape3D` de las piezas:
  - los **suelos** generan superficie caminable;
  - las **paredes** recortan el área navegable.
- Un `filter_baking_aabb` limita el volumen a la grilla y a la altura del
  agente, para que las caras superiores de las paredes no se vuelvan caminables.
- El tamaño de celda del `NavigationMesh` y del mapa de navegación se sincroniza
  a `0.1 m`, lo que permite puertas de 1 celda.
- Si no queda ningún suelo, el NavMesh se limpia.

Señales útiles de `BuildNavigation`:

```gdscript
signal navigation_bake_started
signal navigation_baked
```

También expone `bake_count`, `is_baking()`, `get_polygon_count()`,
`request_bake()` y `bake_now()`.

### API del NPC

`scripts/characters/npc/npc_agent.gd` (`class_name NpcAgent`) extiende `CharacterBody3D` y usa un
`NavigationAgent3D` hijo:

```gdscript
var npc: NpcAgent = get_node("NPCs/NPC1")

# Caminar hasta una posición del mundo. El destino se ajusta al NavMesh.
npc.move_to(Vector3(10.0, 0.0, 4.0))

# Detenerlo.
npc.stop()

# Consultar estado.
var moving: bool = npc.is_moving()
var target: Vector3 = npc.get_target()
```

Con `wander = true` el NPC elige destinos alcanzables dentro de `wander_radius`,
espera `pause_time` y vuelve a caminar. Si el NavMesh cambia, el agente recalcula
su camino actual.

### Prefab del NPC

`scripts/characters/npc/npc.tscn` reutiliza la estructura del jugador, pero sin el controlador FPS,
la cámara ni la linterna:

```
NPC (CharacterBody3D, NpcAgent)
├── CollisionShape3D
├── Visual
│   └── human (modelo + animaciones del jugador)
│       └── AnimationTree
├── AnimController
└── NavigationAgent3D
```

El `AnimationController` usa `res://anim/player_library.tres`. `NpcAgent` le
informa la velocidad cada frame, así que el personaje pasa de *idle* a caminar
automáticamente. Para usar otro modelo, se puede cambiar el nodo `Visual` o
asignar `visual_path` / `animation_controller_path` en el inspector.

### Demo y prueba

`scenes/demo/nav_demo.tscn` construye dos habitaciones con puertas (incluida una de
1 celda), coloca 4 NPC y muestra el estado del NavMesh en pantalla. Los caminos
de `NavigationAgent3D` se dibujan en rojo.

```powershell
Godot.exe --headless --path . --script res://tests/nav_smoke_test.gd
```

## Menú de items (catálogo)

El menú de gameplay (`BuildMenu`) carga automáticamente todos los recursos
`BuildItem` (`.tres`) de `res://data/build_items/`. Para agregar un nuevo
item, el diseñador solo crea un `.tres` con el script `BuildItem`, asigna
nombre, pestaña, subpestaña, tipo, imagen de preview y escena 3D. Al iniciar,
aparece en el menú organizado por pestañas (construcción / objetos) y
subpestañas (suelos, paredes, aberturas, muebles, etc.).

Tecla por defecto para mostrar/ocultar el menú: `M`.

Un item puede usar:
- `scene`: una escena/PackedScene o modelo importado (`.blend`, etc.).
- `map_file`: un archivo `.map`/`.vmf` de FuncGodot, que se construirá al colocar la pieza.

## Estructura

```
scripts/sistemas/build/
├── build_system.tscn        Escena lista para arrastrar a cualquier nivel
├── build_controller.gd      Modo construcción, herramientas y piezas
├── build_navigation.gd      Horneado del NavMesh ligado a las piezas
├── build_grid.gd            Matemática de la grilla + overlay visual
├── build_camera.gd          Cámara orbital de obra
├── build_piece.gd           Script base de las piezas colocadas
├── build_input.gd           Acciones de entrada creadas en runtime
├── shaders/grid.gdshader    Grilla anti-aliased
└── prefabs/
    ├── floor_tile.tscn
    └── wall_segment.tscn
npc/
├── npc.tscn                 Prefab con modelo/animaciones del jugador
└── npc_agent.gd             Movimiento + deambular por NavMesh
scenes/build_demo.tscn       Demo de construcción
scenes/demo/nav_demo.tscn         Demo de construcción + NPCs
tests/build_smoke_test.gd    Prueba del núcleo de construcción
tests/nav_smoke_test.gd      Prueba de NavMesh, puertas y rebake
```

## API de la grilla

Todas las posiciones son globales y el plano se apoya en `plane_y`.

```gdscript
var cell := grid.cell_from_world(world_point)
var center := grid.cell_center(cell)
var is_valid := grid.is_cell_inside(cell)

var edge := grid.wall_from_world(world_point)  # Vector3i(x, z, axis)
var wall_center := grid.wall_center(edge)
var yaw := grid.wall_yaw(edge)
```

Convención de paredes: `Vector3i(x, z, axis)`, donde `axis = 0` es un borde con
normal en X y `axis = 1` un borde con normal en Z. Las paredes se modelan a lo
largo de X y el controlador las rota según el borde.

## API de construcción

```gdscript
# Colocar / borrar por código, con las mismas validaciones que la herramienta.
controller.place_floor(Vector2i(4, 5))
controller.place_wall(Vector3i(4, 5, 1))
controller.erase_at(Vector2i(4, 5), Vector3i(4, 5, 1))

# Cambios y limpieza.
controller.pieces_changed.connect(_on_pieces_changed)
controller.clear_all()
```

## Pruebas automáticas

```powershell
Godot.exe --headless --path . --script res://tests/build_smoke_test.gd
Godot.exe --headless --path . --script res://tests/nav_smoke_test.gd
```

Salen con código 0 e imprimen `BUILD_SMOKE_TEST_OK` y `NAV_SMOKE_TEST_OK`
respectivamente. La prueba de navegación verifica horneado, caminos entre
habitaciones, puerta de 1 celda, rebake al colocar una pared y destino de NPC.

## Límites de esta versión

- La grilla es un plano fijo: no se adapta al terreno. Conviene ubicar el
  `BuildSystem` a la altura del suelo y, si hay desniveles, usar una zona plana.
- Suelos y paredes son piezas de 1 celda; todavía no hay muros encadenados,
  pisos múltiples, puertas ni guardado/carga.
- Las piezas se instancian una por celda. Para edificios grandes se puede migrar
  a `MultiMesh` más adelante.
- El borrado quita primero la pared más cercana y, si no hay, el suelo de la
  celda.
- La navegación cubre una sola planta plana. No hay escaleras, rampas ni
  ascensores; el NavMesh se hornea desde los colliders de las piezas.
- El horneado en hilo puede tardar unos milisegundos en edificios grandes; el
  debounce evita rehornear durante el pintado.
- `NavigationRegion3D` es experimental en Godot 4.7, aunque el flujo está
  verificado con la versión 4.7.2.
