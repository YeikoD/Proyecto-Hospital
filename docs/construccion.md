# Sistema de construcción y navegación (grilla base)

Módulo de construcción estilo Sims para Godot 4.7. Implementa una grilla con
*snapping*, previsualización de piezas, colocación / borrado de suelos y paredes,
y un NavMesh que se rehornea solo para que los NPC puedan caminar por lo
construido.

## Probar

### Demo de construcción

1. Abrir `scenes/demos/build_demo.tscn` en Godot.
2. Ejecutar la escena (F6).
3. Pulsar **B** para entrar al modo construcción.

### Demo de navegación

1. Abrir `scenes/demos/nav_demo.tscn` en Godot.
2. Ejecutar la escena (F6).
3. Los NPC deambulan por las habitaciones. Pulsar **B** y colocar o borrar una
   pared: el NavMesh se rehornea y los NPC recalculan su camino.

También se puede correr desde consola:

```powershell
Godot.exe --path . res://scenes/demos/build_demo.tscn
Godot.exe --path . res://scenes/demos/nav_demo.tscn
```

## Controles

| Entrada | Acción |
| --- | --- |
| `B` | Entrar / salir del modo construcción |
| `M` | Abrir / cerrar el menú **Construir** |
| Clic izquierdo | Colocar / borrar (arrastrar pinta varias celdas) |
| Clic izquierdo + arrastrar (pared) | Dibuja una línea recta de paredes entre dos puntos |
| Clic izquierdo + arrastrar (piso) | Dibuja un rectángulo de pisos entre dos esquinas |
| Clic izquierdo + arrastrar (borrador de pared) | Borra una línea de paredes entre dos puntos |
| Clic izquierdo + arrastrar (borrador de piso) | Borra un rectángulo de pisos entre dos esquinas |
| Clic derecho / central + arrastrar | Orbitar la cámara |
| Rueda | Zoom |
| `WASD` | Desplazar la cámara |
| `Q` / `E` | Bajar / subir el foco de la cámara |
| `R` | Rotar objeto (herramienta de objetos) |
| `°` / `Ctrl+S` | Guardar la construcción del nivel |
| `Esc` | Salir del modo construcción |

## Menú

El menú se abre con `M`. Está organizado en pestañas para dejar clara la función
de cada sección:

- **Construir**: obra y acabados de la estructura.
  - **Base**: pared, piso y sus borradores juntos (pared básica, suelo básico,
    borrador de pared y borrador de piso).
  - **Pinturas** *(futuro)*: pinturas/materiales para cambiar el aspecto de las
    paredes ya construidas desde **Base**.
  - **Baldosas** *(futuro)*: pinturas/materiales para cambiar el aspecto de los
    suelos ya construidos desde **Base**.
  - **Aberturas**: reservado (puertas, etc.).
- **Objetos** *(pestaña independiente de Construir)*: muebles/props colocables
  y sus herramientas (por ejemplo la silla y el borrador de objetos).

Los borradores son ítems del menú (no una herramienta global): cada uno elimina
solo su tipo. El atajo `3` sigue disponible como borrado general.

Los borradores de **pared** y **piso** funcionan con el mismo gesto que sus
pinceles de construcción: clic y arrastrar muestra en rojo lo que se va a
eliminar (línea de paredes o rectángulo de pisos) y, al soltar, se borra todo de
golpe. Así no hay que ir pieza por pieza. El borrador de objetos elimina los
objetos que va tocando el cursor mientras se mantiene pulsado.

El borrado tiene una **animación de desmontaje**: cada pared se hunde en el
suelo y cada piso se encoge en el plano, escalonados en el orden del trazado
(como el efecto de obra pero al revés). La colisión de cada pieza se desactiva
al instante para que el NavMesh no la tenga en cuenta mientras termina la
animación.

## Integrarlo en una escena

La forma más simple es arrastrar `scripts/systems/build/build_system.tscn` a la escena.
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

1. Añadir `scripts/systems/build/build_system.tscn` como hijo de la escena.
2. Mover el nodo `BuildSystem` (o su hijo `BuildGrid`) a la altura donde debe
   quedar el plano de construcción.
3. Ajustar en `BuildGrid`:
   - `cells_x` / `cells_z`: tamaño inicial de la grilla en celdas.
   - `cell_size`: tamaño de cada celda en metros.
   - `plane_y`: altura del plano respecto del nodo.
   - La grilla es **fija por defecto**. En el inspector puedes cambiar
     `cells_x` / `cells_z` o usar los botones **Expandir +X**, **Expandir +Z** y
     **Expandir ambos** (añaden `expand_step` celdas).
   - Opcional: activar `auto_expand` para que crezca sola al construir cerca
     del borde (`expand_step` y `expand_margin` controlan el comportamiento).
   - También se puede cambiar por API con `set_grid_size(x, z)` o `expand(dx, dz)`.
   - Si el nivel usa una instancia de `build_system.tscn`, `BuildGrid` está
     **dentro de la instancia**, no como nodo propio del nivel. Para editarlo en
     esa escena: seleccionar `BuildSystem` → clic derecho →
     **Editable Children** → seleccionar `BuildGrid`. Los cambios se guardan
     como override de la instancia.
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

El `AnimationController` usa `res://assets/animations/player_library.tres`. `NpcAgent` le
informa la velocidad cada frame, así que el personaje pasa de *idle* a caminar
automáticamente. Para usar otro modelo, se puede cambiar el nodo `Visual` o
asignar `visual_path` / `animation_controller_path` en el inspector.

### Demo y prueba

`scenes/demos/nav_demo.tscn` construye dos habitaciones con puertas (incluida una de
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
- `smart_object`: un `SmartObjectDef` que declara las acciones que la IA puede
  realizar con el objeto. La escena debe tener raíz `SmartObject`. Ver
  [docs/smart-objects.md](smart-objects.md).

Los items de tipo `furniture` / `prop` se colocan con la herramienta de objetos
(clic = un objeto, `R` = rotar 90°).

### Esquinas de pared

Las esquinas no son items: son piezas visuales que el controlador genera sola
donde dos paredes forman una L (la pared horizontal queda como dueña de la
esquina y la vertical se oculta, ambas conservan su colisión).

Un item de tipo `wall` puede declarar sus modelos en el inspector:
- `corner_left` → modelo para las L que giran a la izquierda (`_IZQ`).
- `corner_right` → modelo para las L que giran a la derecha (`_DER`).

Si esos campos quedan vacíos, el sistema busca automáticamente
`<nombre_del_muro>_IZQ.blend` y `<nombre_del_muro>_DER.blend` junto al modelo
de la pared. Si no hay modelos de esquina, las paredes se recortan como cajas y
la L se resuelve con dos muros normales.

El sistema deduce la esquina interior y el borde de celda directamente del
modelo, y recorta **todas** las mallas de la pieza (un `.blend` puede importarse
dividido en varios objetos). Así los brazos terminan justo en el borde de la
celda aunque el modelo se mueva o se divida al editar texturas en Blender.

### Previsualizaciones de colocación

Las previsualizaciones usan **la malla real del modelo** que se va a colocar en
lugar de una caja genérica, así que el fantasma coincide en origen, escala y
rotación con la pieza final. La excepción son los pisos, que usan una
previsualización plana propia (ver abajo).

- `shaders/ghost.gdshader` aplica el aspecto holográfico (borde Fresnel, líneas
  de escaneo y pulso) a todas las mallas del modelo. Se usa en paredes y objetos.
  `shaders/ghost_erase.gdshader` es la variante de los borradores: dibuja el
  mismo holograma en rojo y sin test de profundidad, para que se vea siempre
  encima de la pieza que se va a quitar (si no, se ve a parches por z-fighting).
- **Pisos**: clic y arrastrar dibuja un **rectángulo** de celdas. La
  previsualización es **plana** y propia (`shaders/floor_preview.gdshader`), no
  el holograma: un piso se lee mejor como superficie. Un único quad cubre todo
  el rectángulo y dibuja:
  - el **borde exterior** exacto del área (siempre visible desde el primer clic),
  - la **cuadrícula** por celda,
  - un **relleno tenue** del área objetivo y un relleno más sólido de las celdas
    ya pintadas, en orden de barrido fila por fila,
  - la **celda actual** (borde de avance) con contorno y relleno más fuertes,
  - en **rojo** las celdas que no se pueden colocar (por ejemplo, ya ocupadas).

  Al soltar, las celdas confirmadas aparecen con un pequeño "pop" en el orden en
  que se pintaron.
- **Paredes**: la previsualización usa `wall_scene`. Al arrastrar, los tramos se
  construyen **en orden**, desde el primer clic hasta el cursor; cada tramo crece
  desde el suelo con el parámetro `reveal`. El tramo actual (el último bajo el
  cursor) usa `strength = 1`, por lo que se ve más sólido que el resto. Al
  soltar, las paredes confirmadas repiten el crecimiento desde el suelo, una
  detrás de otra, para cerrar el efecto de obra. La colisión se crea completa
  desde el principio para no afectar al NavMesh.
- **Objetos**: la previsualización usa la escena del `BuildItem` (por ejemplo la
  silla con su asiento, respaldo y patas), gira con la tecla `R` y se coloca en
  la misma celda y con el mismo desplazamiento que la pieza real. Al borrar, se
  muestra el modelo del objeto que hay bajo el cursor.
- Las previsualizaciones son puramente visuales: a los modelos se les quitan
  scripts (para que un `SmartObject` no se registre), colisiones, luces, cámaras
  y animaciones.

## Guardado por nivel

En **cualquier momento** (dentro o fuera del modo construccion), pulsar **`°`**
o **`Ctrl+S`** guarda la construccion actual del nivel (suelos, paredes y
objetos con su rotacion). Al iniciar el mismo nivel, la construccion se carga
automaticamente.

Aparece un aviso en pantalla (`Construccion guardada: N piezas`) con la ruta del
archivo, y el detalle se imprime en la consola de Godot.

- La partida se guarda junto a la escena del nivel como
  `<escena>.build.json` (por ejemplo `scenes/demos/build_demo.build.json`).
- Si esa ruta no es escribible (juego exportado), se usa
  `user://build_saves/<nivel>.build.json`.
- Las piezas se guardan por el `id` de su `BuildItem`, asi que sobreviven a
  cambios de escena siempre que el item siga existiendo en `data/build_items`.

## Estructura

```
scripts/systems/build/
├── build_system.tscn        Escena lista para arrastrar a cualquier nivel
├── build_controller.gd      Modo construcción, herramientas y piezas
├── build_navigation.gd      Horneado del NavMesh ligado a las piezas
├── build_grid.gd            Matemática de la grilla + overlay visual
├── build_camera.gd          Cámara orbital de obra
├── build_piece.gd           Script base de las piezas colocadas
├── build_input.gd           Acciones de entrada creadas en runtime
├── shaders/grid.gdshader    Grilla anti-aliased
├── shaders/ghost.gdshader   Fantasma holografico de paredes y objetos
├── shaders/ghost_erase.gdshader    Variante roja de borrado (sin depth test)
├── shaders/ghost_common.gdshaderinc  Cuerpo compartido de los fantasmas
├── shaders/floor_preview.gdshader  Vista previa plana del pincel de pisos
├── shaders/menu_tint.gdshader      Tinte rojo de los borradores en el menu
└── prefabs/
    ├── floor_tile.tscn
    └── wall_segment.tscn
scripts/characters/npc/
├── npc.tscn                 Prefab con modelo/animaciones del jugador
└── npc_agent.gd             Movimiento + deambular por NavMesh
scenes/demos/build_demo.tscn       Demo de construcción
scenes/demos/nav_demo.tscn         Demo de construcción + NPCs
tests/build_smoke_test.gd          Prueba del núcleo de construcción
tests/nav_smoke_test.gd            Prueba de NavMesh, puertas y rebake
assets/models/
├── construction/            Paredes, pisos y sus texturas
└── levels/level_01/         Modelo del nivel de ejemplo
assets/textures/             Biblioteca de texturas compartidas
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
Godot.exe --headless --path . --script res://tests/smart_object_smoke_test.gd
Godot.exe --headless --path . --script res://tests/animation_manager_smoke_test.gd
```

Salen con código 0 e imprimen `BUILD_SMOKE_TEST_OK`, `NAV_SMOKE_TEST_OK`,
`SMART_OBJECT_SMOKE_TEST_OK` y `ANIMATION_MANAGER_SMOKE_TEST_OK`
respectivamente. La prueba de navegación verifica horneado, caminos entre
habitaciones, puerta de 1 celda, rebake al colocar una pared y destino de NPC.
La de SmartObjects cubre la interacción completa con la silla animada.

## Límites de esta versión

- La grilla es un plano fijo: no se adapta al terreno. Conviene ubicar el
  `BuildSystem` a la altura del suelo y, si hay desniveles, usar una zona plana.
- Suelos y paredes son piezas de 1 celda; todavía no hay muros encadenados,
  pisos múltiples ni puertas.
- Los objetos (muebles/props) ya se colocan y rotan, pero solo hay un SmartObject
  de ejemplo (silla). Ver [docs/smart-objects.md](smart-objects.md).
- Las piezas se instancian una por celda. Para edificios grandes se puede migrar
  a `MultiMesh` más adelante.
- El borrado quita primero el objeto de la celda, después la pared más cercana
  y, si no hay, el suelo.
- La navegación cubre una sola planta plana. No hay escaleras, rampas ni
  ascensores; el NavMesh se hornea desde los colliders de las piezas.
- El horneado en hilo puede tardar unos milisegundos en edificios grandes; el
  debounce evita rehornear durante el pintado.
- `NavigationRegion3D` es experimental en Godot 4.7, aunque el flujo está
  verificado con la versión 4.7.2.
