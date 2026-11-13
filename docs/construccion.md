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
- **Zonas**: pincel y borrador de zonas lógicas.
- **Objetos** *(pestaña independiente de Construir)*: muebles/props colocables
  y sus herramientas (por ejemplo la silla y el borrador de objetos).

Los borradores son ítems del menú (no una herramienta global): cada uno elimina
solo su tipo.

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

## Zonas

Las zonas son áreas lógicas pintadas sobre el piso. Sirven para comunicar a la
IA qué hay en cada parte del hospital (la IA se conectará más adelante).

- **Pincel de zona** (pestaña **Zonas → Pinceles**): clic y arrastrar pinta un
  **rectángulo** de celdas, igual que el pincel de pisos. La zona nace como
  **“Sin asignar”**.
- **Borrador de zona**: clic y arrastrar elimina las celdas de zona del
  rectángulo. No toca suelos, paredes ni objetos.
- Las zonas se ven **solo en modo construcción**, como un **área unida** (sin
  cuadrados separados), con un borde en el perímetro y el **nombre del tipo en
  el centro**.
- Se ocultan automáticamente para no tapar las piezas: al elegir un **objeto**
  (o su borrador) quedan ocultas mientras esa herramienta esté activa. Al
  **pintar un piso** o **arrastrar una pared** se ocultan solo durante el
  trazado y vuelven al soltar. Al entrar al modo construcción se ven siempre.
- Al hacer **clic sobre una zona pintada** se abre el menú de asignación:
  - **Pasillos**
  - **Sala de espera**
  - **Consultorio**
- Cada trazo es una zona independiente: asignar un tipo afecta a todas las
  celdas de ese trazo.
- Las zonas se guardan en el JSON de construcción (`zones`) y se recargan con
  el nivel.

API para la futura IA:

```gdscript
signal zones_changed
func get_zone_count() -> int
func get_zone_type(cell: Vector2i) -> StringName
```

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
   - `show_floor_grid` / `floor_grid_opacity`: segunda grilla que solo cubre las
     celdas con piso colocado, apoyada sobre la cara superior del modelo y más
     transparente que la principal.
   - `subdivisions` / `show_subdivisions`: sub-grilla de precisión para mover
     objetos. Con `subdivisions = 2` (default) cada metro cuadrado se divide en
     4 y los objetos se colocan en pasos de **0,5 m**. Las líneas finas son
     **discontinuas** (guiones de `sub_dash_length` separados por
     `sub_dash_gap`, ambos en celdas) para distinguirlas de la grilla de 1 m.
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
  realizar con el objeto. Si la escena ya tiene raíz `SmartObject` se usa tal
  cual; si es un modelo plano (`.glb`, escena suelta) el controlador la envuelve
  automáticamente y crea un slot de uso en el centro del mueble. Ver
  [docs/smart-objects.md](smart-objects.md).

Los items de tipo `furniture` / `prop` se colocan con la herramienta de objetos
(clic = un objeto, `R` = rotar 90°).

### Objetos especiales

Varios muebles pueden combinarse en un único SmartObject si una receta los
relaciona. El primer caso es el **Escritorio de trabajo**:

- un **Escritorio**;
- una **Silla de escritorio** delante (el operador);
- al menos una **Silla de pacientes** o silla de escritorio suelta del otro
  lado, directamente detrás. Se pueden integrar hasta dos piezas client.

El conjunto ofrece `work` al operador y `sit` a los pacientes.

- Las piezas siguen existiendo y conservan sus colliders, pero la IA deja de
  verlas por separado: solo ve el objeto combinado.
- La silla del operador puede compartir celdas con el escritorio: puede quedar
  medio metro debajo. La base conserva la propiedad de las celdas compartidas.
- Con el conjunto ya formado se pueden agregar más sillas del lado de los
  pacientes; también pueden quedar medio metro metidas y compartir celdas con
  el escritorio, sin correr una celda entera hacia atrás.
- Apuntando al centro de la celda del escritorio, la silla del operador se mete
  un paso más (0,5 m) hasta quedar medio debajo de la mesa. El ancla se guarda
  en una celda libre vecina y el sub-offset compensa la diferencia.
- La silla del operador se puede colocar sin preocuparse por la rotación: al
  formarse el conjunto se auto-orienta hacia el escritorio.
- El operador se busca del lado opuesto a la banca de pacientes, así funciona
  con el escritorio en cualquier rotación. Sillas sueltas como clientes usan
  `operator_side` como pista. Así una silla suelta detrás no se confunde con el
  operador.
- Los slots del operador y de los pacientes tienen tags distintos (`work` y
  `seat`), así cada affordance usa el asiento correcto.
- Sin la pieza de pacientes el conjunto **no** se forma: quedan el escritorio y
  la silla como SmartObjects individuales.
- La combinación funciona en cualquier orden de colocación y se vuelve a
  detectar al cargar el nivel.
- Al borrar una de las piezas, el conjunto se separa y el resto vuelve a
  comportarse como muebles normales (configurable con `remove_together`).
- Las recetas viven en `data/special_objects/` y se cargan automáticamente.

Ver [docs/objetos-especiales.md](objetos-especiales.md).

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
  la misma celda y con el mismo desplazamiento que la pieza real. Los objetos se
  ajustan a una **sub-grilla de 0,5 m** (4 posiciones por metro cuadrado): al
  mover el cursor dentro de la celda el mueble se desplaza en pasos finos, y la
  huella ocupada se recalcula según el objeto desplazado. Al borrar, se muestra
  el modelo del objeto que hay bajo el cursor.
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
└── shaders/menu_tint.gdshader      Tinte rojo de los borradores en el menu

prefabs/
├── build/                   Prefabs base de construcción
│   ├── floor_tile.tscn
│   └── wall_segment.tscn
└── items/                   Prefabs de objetos colocables (SmartObjects)
    ├── chair.tscn
    └── patient_chairs_01.tscn
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

# Sub-grilla de objetos: paso fino y ajuste de un desplazamiento XZ.
var step := grid.sub_cell_size()               # 0.5 con subdivisions = 2
var offset := grid.snap_offset(Vector2(0.3, -0.2))  # -> (0.5, 0.0, 0.0)
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

# Objetos: rotación en cuartos de vuelta y desplazamiento fino (0,5 m).
controller.place_object(Vector2i(4, 5), 0, Vector3(0.5, 0.0, 0.0))
controller.place_object_item(item, Vector2i(4, 5), 1, Vector3(0.0, 0.0, -0.5))

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
Godot.exe --headless --path . --script res://tests/special_object_smoke_test.gd
Godot.exe --headless --path . --script res://tests/special_object_overlap_smoke_test.gd
Godot.exe --headless --path . --script res://tests/patient_desk_smoke_test.gd
Godot.exe --headless --path . --script res://tests/work_desk_ai_smoke_test.gd
Godot.exe --headless --path . --script res://tests/route_work_smoke_test.gd
```

Salen con código 0 e imprimen `BUILD_SMOKE_TEST_OK`, `NAV_SMOKE_TEST_OK`,
`SMART_OBJECT_SMOKE_TEST_OK`, `ANIMATION_MANAGER_SMOKE_TEST_OK`,
`SPECIAL_OBJECT_SMOKE_TEST_OK`, `SPECIAL_OVERLAP_OK`, `PATIENT_DESK_OK`,
`WORK_DESK_AI_OK` y `ROUTE_WORK_OK` respectivamente. La prueba de navegación verifica horneado, caminos entre
habitaciones, puerta de 1 celda, rebake al colocar una pared y destino de NPC.
La de SmartObjects cubre la interacción completa con la silla animada.

## Límites de esta versión

- La grilla es un plano fijo: no se adapta al terreno. Conviene ubicar el
  `BuildSystem` a la altura del suelo y, si hay desniveles, usar una zona plana.
- Suelos y paredes son piezas de 1 celda; todavía no hay muros encadenados,
  pisos múltiples ni puertas.
- Los objetos (muebles/props) ya se colocan y rotan, con precisión de 0,5 m
  sobre una sub-grilla de 2×2 por celda, pero solo hay un SmartObject de
  ejemplo (silla). Ver [docs/smart-objects.md](smart-objects.md).
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
