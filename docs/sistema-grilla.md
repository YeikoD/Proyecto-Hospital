# Documento técnico — Sistema de grilla y construcción

| Campo | Valor |
| --- | --- |
| Proyecto | Proyecto Hospital (Godot 4.7) |
| Módulo | `res://scripts/systems/build/` |
| Versión del documento | 1.3 |
| Estado | Implementado y verificado (construcción + navegación + sub-grilla de objetos) |
| Fecha | 2026-11-12 |
| Motor verificado | Godot 4.7.2 stable |

---

## 1. Objetivo y alcance

Este documento describe el diseño técnico del sistema de construcción estilo
*Sims* del proyecto: una grilla alineada a los ejes X/Z sobre la que se colocan
suelos y paredes con *snapping*, previsualización y borrado.

La versión actual es deliberadamente **básica pero funcional**. Cubre:

- Grilla plana configurable (celdas, tamaño, altura).
- Conversión mundo ↔ celda y mundo ↔ borde de pared.
- Colocación y borrado de suelos (1 celda) y paredes (1 borde de celda).
- *Ghost* de previsualización con validación visual (verde / rojo / naranja).
- Pintado por arrastre.
- Cámara orbital de obra independiente de la cámara FPS.
- Overlay de grilla renderizado con shader.
- Integración *drop-in* sin editar `project.godot`.

Queda **fuera de alcance** en esta versión: adaptación al terreno, muros de
varias celdas, plantas múltiples, puertas/ventanas, guardado/carga y catálogo UI.

---

## 2. Resumen funcional

1. El jugador pulsa **B** y entra al modo construcción.
2. Se oculta el HUD del jugador, se libera el ratón y se activa la cámara de obra.
3. El ratón se proyecta sobre el plano de construcción y se resuelve la celda
   (o el borde de pared) bajo el cursor.
4. Un *ghost* muestra dónde y cómo quedaría la pieza.
5. Con clic izquierdo (o arrastrando) se coloca o borra.
6. **B** o **Esc** devuelve el control al jugador.

### Controles

| Entrada | Acción |
| --- | --- |
| `B` | Entrar / salir del modo construcción |
| Clic izquierdo | Colocar / borrar (arrastrar pinta varias celdas) |
| Clic derecho o central + arrastrar | Orbitar la cámara |
| Rueda | Zoom |
| `WASD` | Desplazar el foco de la cámara |
| `Q` / `E` | Bajar / subir el foco de la cámara |
| `Esc` | Salir del modo construcción |

---

## 3. Arquitectura

### 3.1 Componentes

```
build_system.tscn
├── BuildGrid        (BuildGrid)          Matemática de celdas/bordes + overlay
├── BuildCamera      (BuildCamera)        Cámara orbital de construcción
├── NavRegion        (NavigationRegion3D) Región navegable
│   └── PlacedPieces (Node3D)             Contenedor de piezas ya colocadas
├── BuildController  (BuildController)    Modo construcción, herramientas,
│                                         ghosts, UI y colocación
└── BuildNavigation  (BuildNavigation)    Horneado del NavMesh
```

| Archivo | Responsabilidad |
| --- | --- |
| `scripts/systems/build/build_grid.gd` | Modelo geométrico puro: celdas, bordes, límites, centros, rotación y overlay. |
| `scripts/systems/build/build_controller.gd` | Orquestador: entrada, herramientas, hover, ghosts, instanciación y borrado. |
| `scripts/systems/build/build_navigation.gd` | Configura el NavMesh, escucha cambios de piezas y hornea con debounce. |
| `scripts/systems/build/build_camera.gd` | Cámara orbital con pan, zoom y encuadre inicial. |
| `scripts/systems/build/build_piece.gd` | Clase base de una pieza colocada; redimensiona malla y colisión. |
| `scripts/systems/build/build_input.gd` | Registro en runtime de las acciones de entrada. |
| `scripts/systems/build/shaders/grid.gdshader` | Dibujo anti-aliased de la grilla sobre un plano. |
| `scripts/systems/build/prefabs/floor_tile.tscn` | Prefab de suelo (caja 1×0.1×1). |
| `scripts/systems/build/prefabs/wall_segment.tscn` | Prefab de pared (caja 1×2.8×0.2). |
| `scripts/systems/build/build_system.tscn` | Escena ensamblada lista para arrastrar a un nivel. |
| `scripts/characters/npc/npc_agent.gd` | `CharacterBody3D` con `NavigationAgent3D`, deambular y animación. |
| `scripts/characters/npc/npc.tscn` | Prefab de NPC con el modelo y las animaciones del jugador. |
| `scenes/demos/build_demo.tscn` | Escena de demostración independiente. |
| `scenes/demos/nav_demo.tscn` | Demo con habitaciones, puertas, NPC y NavMesh. |
| `tests/build_smoke_test.gd` | Prueba automática headless del núcleo. |
| `tests/nav_smoke_test.gd` | Prueba del NavMesh, puertas y rebake. |

### 3.2 Principios de diseño

- **Grilla como modelo, no como visual.** `BuildGrid` calcula posiciones; el
  overlay es solo una representación. La lógica funciona sin render.
- **Autoridad única de la geometría.** El controlador nunca calcula celdas por
  su cuenta: siempre pregunta a `BuildGrid`.
- **Piezas autoradas a 1×1.** Los prefabs se modelan en una celda y el
  controlador los redimensiona según la grilla, de modo que cambiar
  `cell_size`, `wall_height`, etc. no requiere rehacer assets.
- **Cero configuración obligatoria.** Si no se asignan referencias en el
  inspector, el controlador busca grilla, cámara y jugador en el árbol.
- **Sin tocar la configuración del proyecto.** Las acciones de entrada se crean
  en runtime y la UI/ghosts se construyen por código.

---

## 4. Modelo de coordenadas y convenciones

### 4.1 Sistema de referencia

- La grilla es un **plano horizontal** paralelo a X/Z.
- El origen de la celda `(0, 0)` coincide con la **posición global del nodo**
  `BuildGrid`.
- El plano de construcción está a la altura global
  `global_position.y + plane_y`.
- **El nodo de grilla no debe rotarse ni escalarse.** Toda la matemática asume
  que sus ejes coinciden con los del mundo.

```
		Z
		^
		|
  (0,2) |  (1,2) |  (2,2)
  ------+-------+-------+--> X
  (0,1) |  (1,1) |  (2,1)
  ------+-------+-------
  (0,0) |  (1,0) |  (2,0)   origen del nodo
```

### 4.2 Celdas — `Vector2i`

`cell.x` indexa columnas en X y `cell.y` indexa filas en Z.

```gdscript
func cell_from_world(world: Vector3) -> Vector2i:
	var base := global_position
	return Vector2i(
		floori((world.x - base.x) / cell_size),
		floori((world.z - base.z) / cell_size)
	)
```

Con `cell_size = 1` y nodo en el origen:

| Punto del mundo | Celda |
| --- | --- |
| `(0.5, _, 0.5)` | `(0, 0)` |
| `(2.5, _, 3.5)` | `(2, 3)` |
| `(-0.1, _, 0.5)` | `(-1, 0)` (fuera) |

### 4.3 Bordes de pared — `Vector3i(x, z, axis)`

Una pared no ocupa una celda: ocupa un **borde** entre celdas. El identificador
es un `Vector3i` donde los dos primeros componentes son índices de borde y el
tercero es el eje de la normal.

| `axis` | Significado | Normal | Rango de `x` | Rango de `z` |
| --- | --- | --- | --- | --- |
| `0` | Borde **vertical** (separa celdas en X) | ±X | `[0, cells_x]` | `[0, cells_z - 1]` |
| `1` | Borde **horizontal** (separa celdas en Z) | ±Z | `[0, cells_x - 1]` | `[0, cells_z]` |

Aunque el campo se llama `z`, en `axis = 1` **contiene el índice del borde en
Z**; no es una coordenada de celda. Ejemplos con la grilla anterior:

| Borde | Significado |
| --- | --- |
| `(2, 3, 0)` | Borde vertical en `x = 2`, flanco de la fila `z = 3` |
| `(3, 3, 0)` | Borde vertical en `x = 3`, misma fila |
| `(2, 3, 1)` | Borde horizontal en `z = 3`, columna `x = 2` |
| `(2, 4, 1)` | Borde horizontal en `z = 4`, misma columna |

### 4.4 Orientación de paredes

Los prefabs se modelan **a lo largo de X** (una caja ancha en X y fina en Z).
El controlador aplica una rotación en Y según el borde:

```gdscript
func wall_yaw(key: Vector3i) -> float:
	return PI * 0.5 if key.z == 0 else 0.0
```

| `axis` | `yaw` | Resultado |
| --- | --- | --- |
| `0` | `90°` | La pared corre a lo largo de Z |
| `1` | `0°` | La pared corre a lo largo de X |

---

## 5. Matemática de la grilla

### 5.1 Funciones de celda

```gdscript
func is_cell_inside(cell: Vector2i) -> bool
func clamp_cell(cell: Vector2i) -> Vector2i
func cell_center(cell: Vector2i) -> Vector3
func plane_global_y() -> float
func center_point() -> Vector3
```

- `is_cell_inside`: `0 <= x < cells_x` y `0 <= y < cells_z`.
- `clamp_cell`: satura ambos índices al rango válido (se usa para el *ghost*
  cuando el cursor sale de la grilla).
- `cell_center`: centro geométrico de la celda sobre el plano:

```gdscript
Vector3(
	base.x + (cell.x + 0.5) * cell_size,
	plane_global_y(),
	base.z + (cell.y + 0.5) * cell_size
)
```

- `center_point`: centro de toda la grilla, usado para encuadrar la cámara.
- `plane_global_y`: `global_position.y + plane_y`.

#### Expansión de la grilla

El origen (celda `0,0`) es fijo, así que la grilla crece hacia `+X` y `+Z`:

```gdscript
signal grid_resized(cells_x: int, cells_z: int)

func set_grid_size(new_cells_x: int, new_cells_z: int) -> void
func expand(add_x: int, add_z: int) -> void
func expand_if_near_edge(cell: Vector2i) -> bool
```

- `set_grid_size` / `expand`: cambian el tamaño y refrescan el overlay al instante.
- `expand_if_near_edge`: si el cursor está en una de las últimas
  `expand_margin` celdas, añade `expand_step` celdas en ese eje.
- La grilla es **fija por defecto** (`auto_expand = false`). Para expandirla
  desde el inspector:
  - editar `cells_x` / `cells_z`, o
  - usar los botones **Expandir +X**, **Expandir +Z** y **Expandir ambos**, que
    añaden `expand_step` celdas.
- El crecimiento automático es opcional: activar `auto_expand` y ajustar
  `expand_step` / `expand_margin`.

### 5.2 Detección del borde más cercano

`wall_from_world` convierte un punto del mundo al borde de celda más próximo.
Algoritmo:

1. Obtener la celda que contiene el punto.
2. Calcular la posición fraccionaria dentro de la celda:
   `local_x`, `local_z` ∈ `[0, 1)`.
3. Distancia al borde vertical más cercano:
   `dist_x = min(local_x, 1 - local_x)`.
4. Distancia al borde horizontal más cercano:
   `dist_z = min(local_z, 1 - local_z)`.
5. Si `dist_x <= dist_z`, devolver borde vertical; si no, horizontal.
6. El índice del borde es el de la celda, más 1 si la fracción supera `0.5`.

```gdscript
func wall_from_world(world: Vector3) -> Vector3i:
	var cell := cell_from_world(world)
	var local_x := (world.x - base.x) / cell_size - float(cell.x)
	var local_z := (world.z - base.z) / cell_size - float(cell.y)
	var dist_x := minf(local_x, 1.0 - local_x)
	var dist_z := minf(local_z, 1.0 - local_z)
	if dist_x <= dist_z:
		return Vector3i(cell.x + (1 if local_x > 0.5 else 0), cell.y, 0)
	return Vector3i(cell.x, cell.y + (1 if local_z > 0.5 else 0), 1)
```

El desempate (`<=`) favorece el borde vertical en el centro exacto de la celda,
lo que hace el comportamiento determinista.

### 5.3 Límites y saturación de bordes

```gdscript
func is_wall_inside(key: Vector3i) -> bool
func clamp_wall(key: Vector3i) -> Vector3i
```

- `axis = 0`: `x ∈ [0, cells_x]`, `z ∈ [0, cells_z - 1]`.
- `axis = 1`: `x ∈ [0, cells_x - 1]`, `z ∈ [0, cells_z]`.

Los bordes del perímetro son válidos: una grilla de `32×32` tiene `33` líneas
verticales y `33` horizontales, es decir, `32*33*2 = 2112` paredes posibles.

### 5.4 Posición y rotación de una pared

```gdscript
func wall_center(key: Vector3i) -> Vector3
```

| `axis` | X | Z |
| --- | --- | --- |
| `0` | `base.x + key.x * cell_size` | `base.z + (key.z + 0.5) * cell_size` |
| `1` | `base.x + (key.x + 0.5) * cell_size` | `base.z + key.z * cell_size` |

La altura devuelta es siempre `plane_global_y()`; el controlador añade media
altura de pared para centrar la caja.

### 5.5 Bordes de una celda

```gdscript
func wall_keys_around_cell(cell: Vector2i) -> Array[Vector3i]:
	return [
		Vector3i(cell.x, cell.y, 0),      # izquierda
		Vector3i(cell.x + 1, cell.y, 0),  # derecha
		Vector3i(cell.x, cell.y, 1),      # abajo (Z-)
		Vector3i(cell.x, cell.y + 1, 1),  # arriba (Z+)
	]
```

Disponible para futuras reglas (por ejemplo, validar que una habitación esté
cerrada o autoconectar muros).

---

## 6. Estado y modelo de datos

El controlador mantiene dos diccionarios que actúan como índice espacial y
fuente de verdad de lo construido:

```gdscript
var _floors: Dictionary = {}   # Vector2i -> BuildPiece
var _walls: Dictionary = {}    # Vector3i -> BuildPiece
```

- La clave es la identidad lógica de la pieza; el valor, el nodo instanciado.
- La existencia de la clave implica que la pieza está colocada.
- `_floors` y `_walls` permiten comprobar duplicados y borrar en O(1).
- Las piezas se instancian bajo `PlacedPieces` (`pieces_root`).

Consultas y limpieza:

```gdscript
func get_floor_count() -> int
func get_wall_count() -> int
func clear_all() -> void   # queue_free de todas las piezas y limpia índices
```

---

## 7. Flujo de colocación

### 7.1 Ciclo por frame

`BuildController._process()` solo se ejecuta en modo construcción:

```
_update_hover()
   ├── si no hay impacto en el plano → cancela pintado, oculta ghosts
   └── si hay impacto → guarda _hover_cell y _hover_wall
_painting = botón izquierdo presionado
   └── si pinta → _apply_tool()
_update_ghosts()
_update_ui()
```

El pintado continuo mientras se mantiene el botón es lo que permite arrastrar
para construir varias celdas seguidas.

### 7.2 Proyección del cursor

```gdscript
var plane := Plane(Vector3.UP, grid.plane_global_y())
var hit: Variant = plane.intersects_ray(from, normal)
```

Se lanza un rayo desde la cámara de obra a través del ratón y se intersecta con
el plano de construcción. No se usan colisiones físicas, por lo que el cursor
funciona aunque no haya geometría debajo.

### 7.3 Validación

```gdscript
func _can_place_floor(cell: Vector2i) -> bool:
	return grid.is_cell_inside(cell) and not _floors.has(cell)

func _can_place_wall(key: Vector3i) -> bool:
	return grid.is_wall_inside(key) and not _walls.has(key)
```

No se permite colocar fuera de los límites ni duplicar una pieza existente.

### 7.4 Suelo

```gdscript
piece.is_wall = false
piece.cell = cell
piece.global_position = grid.cell_center(cell) - Vector3.UP * (floor_thickness * 0.5)
piece.set_dimensions(Vector3(grid.cell_size, floor_thickness, grid.cell_size))
_floors[cell] = piece
```

La caja se centra media altura por debajo del plano, de modo que su **cara
superior coincide exactamente con el plano de construcción**.

### 7.5 Pared

```gdscript
piece.is_wall = true
piece.wall_key = key
piece.global_transform = Transform3D(
	Basis(Vector3.UP, grid.wall_yaw(key)),
	grid.wall_center(key) + Vector3.UP * (wall_height * 0.5)
)
piece.set_dimensions(Vector3(grid.cell_size, wall_height, wall_thickness))
_walls[key] = piece
```

La base de la pared queda apoyada en el plano; el origen del nodo está en el
centro vertical de la caja.

### 7.6 Borrado

```gdscript
func _erase_at(cell: Vector2i, wall: Vector3i) -> bool:
	if _walls.has(wall):
		_remove(_walls, wall)
		return true
	if _floors.has(cell):
		_remove(_floors, cell)
		return true
	return false
```

Prioridad: **primero la pared** del borde bajo el cursor; si no existe, el
suelo de la celda. Ambas herramientas usan la misma celda/borde de *hover*.

### 7.7 Ghosts

Dos `MeshInstance3D` con `BoxMesh` y un material compartido sin sombreado,
transparente y sin *culling*:

| Ghost | Tamaño | Posición |
| --- | --- | --- |
| Suelo | `cell_size * 0.94` × `0.06` × `cell_size * 0.94` | Centro de celda + `0.05` en Y (`0.09` al borrar) |
| Pared | `cell_size * 0.98` × `wall_height` × `wall_thickness * 0.7` | Centro del borde + `wall_height / 2` |

Colores:

| Estado | Color |
| --- | --- |
| Válido | `Color(0.25, 1.0, 0.6, 0.35)` verde |
| Inválido | `Color(1.0, 0.3, 0.25, 0.42)` rojo |
| Borrar | `Color(1.0, 0.45, 0.2, 0.5)` naranja |

El *ghost* de suelo se dibuja en la celda saturada (`clamp_cell`) para no
desaparecer cuando el cursor sale de la grilla, pero el color y la validez se
calculan con la celda real.

---

## 8. Cámara de construcción

`BuildCamera` es una `Camera3D` orbital con un **foco** y coordenadas esféricas
implícitas (`yaw`, `pitch`, `distance`).

### 8.1 Estado

| Exportada | Valor por defecto | Uso |
| --- | --- | --- |
| `focus` | `Vector3.ZERO` | Punto al que mira la cámara |
| `yaw` | `0.0` | Rotación horizontal |
| `pitch` | `0.85` rad (~49°) | Inclinación |
| `distance` | `18.0` | Distancia al foco |

| Control | Valor |
| --- | --- |
| `pan_speed` | `16.0` m/s |
| `height_speed` | `8.0` m/s |
| `zoom_step` | `1.15` |
| `min_distance` / `max_distance` | `2.0` / `80.0` |
| `rotate_sensitivity` | `0.006` rad/píxel |
| `min_pitch` / `max_pitch` | `0.12` / `1.5` rad |

### 8.2 Transformación

```gdscript
global_rotation = Vector3(-pitch, yaw, 0.0)
global_position = focus + global_transform.basis.z * distance
```

El pan se aplica en el plano horizontal, independiente del `pitch`:

```gdscript
var flat := Basis(Vector3.UP, yaw)
focus += (flat * Vector3(input.x, 0.0, -input.y)) * pan_speed * delta
```

### 8.3 Encuadre inicial

`enter_build_mode()` llama una sola vez a:

```gdscript
var side := maxf(grid.cells_x, grid.cells_z) * grid.cell_size
build_camera.frame_grid(grid.center_point(), side)
```

`frame_grid` centra el foco y ajusta la distancia a
`clampf(maxf(size * 1.05, 6.0), min_distance, max_distance)`.

---

## 9. Entrada y cambio de modo

### 9.1 Acciones creadas en runtime

`BuildInput.ensure_actions()` registra las acciones si no existen o si existen
sin eventos. Usa `physical_keycode`, por lo que respeta distribuciones de
teclado.

| Acción | Tecla |
| --- | --- |
| `build_toggle` | `B` |
| `build_rotate` | `R` |
| `build_raise` | `E` |
| `build_lower` | `Q` |
| `build_save` | `°` / `º` / `ª` |

También se reutilizan las acciones del jugador `move_left`, `move_right`,
`move_forward`, `move_backward` y `ui_cancel`.

### 9.2 Entrar al modo construcción

1. Verifica que exista la grilla.
2. Resuelve el jugador (`FPSController`) si no está asignado.
3. Guarda la cámara activa del jugador.
4. Activa `_process`.
5. Desactiva física e input no manejado del jugador:

   ```gdscript
   player.set_physics_process(false)
   player.set_process_unhandled_input(false)
   ```

6. Muestra el ratón (`MOUSE_MODE_VISIBLE`).
7. Encuadra y activa `BuildCamera`.
8. Muestra el overlay de grilla y la UI.

### 9.3 Salir del modo construcción

Invierte el proceso: desactiva la cámara de obra, oculta grilla y UI, restaura
la cámara del jugador, reactiva su física/input y vuelve a
`MOUSE_MODE_CAPTURED`. Cancela cualquier pintado en curso.

### 9.4 UI

La UI se construye por código en un `CanvasLayer` (capa 10) con tres `Label`:
título, herramienta actual + celda bajo el cursor y ayuda de controles. Se
oculta al salir del modo y se puede desactivar con `show_help = false`.

---

## 10. Overlay visual y shader

### 10.1 Nodo

`BuildGrid` crea en `_ready()` un `MeshInstance3D` llamado `GridOverlay` con un
`PlaneMesh` y `ShaderMaterial`. El plano:

- Mide `cells_x * cell_size` × `cells_z * cell_size`.
- Se posiciona en el centro de la grilla, a `plane_y + 0.015` para evitar
  *z-fighting* con el suelo.
- No proyecta sombras.

Cuando cambian `cell_size`, `cells_x`, `cells_z`, `plane_y` o `show_border`, el
*setter* llama a `_refresh_overlay()`. La clase es `@tool`, así que el overlay
también se ve en el editor.

### 10.2 Shader

`grid.gdshader` (spatial, `unshaded`, `depth_draw_never`, `cull_disabled`,
`shadows_disabled`) dibuja la grilla en espacio local del plano.

| Uniform | Default | Función |
| --- | --- | --- |
| `cell_size` | `1.0` | Tamaño de celda en metros |
| `grid_extent` | `(32, 32)` | Cantidad de celdas |
| `fill_color` | blanco muy tenue | Relleno del plano |
| `minor_color` | blanco tenue | Líneas de 1 m |
| `border_color` | blanco brillante | Borde del área construible |
| `subdivisions` | `2` | Divisiones de la sub-grilla por celda |
| `show_subdivisions` | `true` | Dibuja las líneas finas |
| `sub_color` | blanco tenue | Líneas de la sub-grilla |
| `sub_dash_length` | `0.1` | Largo de cada guion, en celdas |
| `sub_dash_gap` | `0.1` | Separación entre guiones, en celdas |
| `line_width` | `1.2` | Grosor de línea en píxeles |
| `show_border` | `true` | Dibuja el perímetro |
| `fade_start` / `fade_end` | `60` / `120` | Distancia de desvanecido |

Anti-aliasing por derivadas:

```glsl
vec2 grid = abs(fract(coord - 0.5) - 0.5) / max(fwidth(coord), vec2(0.00001));
float mask = 1.0 - clamp(min(grid.x, grid.y) / line_width, 0.0, 1.0);
```

El controlador ajusta `fade_start`/`fade_end` a `2×` y `3.5×` el lado mayor
de la grilla para que las líneas lejanas no generen ruido visual.

### 10.3 Grilla secundaria sobre los pisos

La grilla principal queda a `plane_y + 0.015`, pero algunos modelos de piso son
más altos que ese plano (por ejemplo `floor_exterior_01.glb`, cuya cara
superior sobresale). El slab del piso tapa entonces las líneas.

Para resolverlo, `BuildGrid` crea un segundo `MeshInstance3D` llamado
`FloorGridOverlay`, con un `ShaderMaterial` que usa el mismo `grid.gdshader`:

- La malla se arma con **un quad por cada celda que tiene piso colocado**; las
  celdas vacías no reciben geometría.
- Cada quad se apoya en la **cara superior real del piso** más un pequeño
  margen (`FLOOR_GRID_LIFT = 0.006`) para evitar *z-fighting*.
- La altura real se mide con el AABB del modelo al colocarlo, no se asume
  `floor_thickness` (los GLB pueden ser más altos o más bajos).
- Las alphas del shader se multiplican por `floor_grid_opacity` (por defecto
  `0.6`), así la grilla de pisos es **más transparente** que la principal y no
  compite con el material del suelo.
- Se reconstruye con `set_floor_cells(cells, tops)` y se limpia con
  `clear_floor_cells()`. `BuildController` la refresca de forma diferida
  (un solo rebuild por frame) al colocar, borrar, cargar o limpiar pisos.

Propiedades nuevas de `BuildGrid`:

| Propiedad | Default | Función |
| --- | --- | --- |
| `show_floor_grid` | `true` | Activa la grilla secundaria |
| `floor_grid_opacity` | `0.6` | Multiplicador de opacidad respecto de la principal |

### 10.4 Sub-grilla de precisión (objetos)

Suelos y paredes siguen ocupando celdas completas, pero los **objetos**
(muebles y props) se pueden colocar con precisión de **medio metro**, como el
modo de colocación fina de *Los Sims*.

La sub-grilla divide cada celda en `subdivisions × subdivisions` partes. Con el
valor por defecto `subdivisions = 2` cada metro cuadrado queda dividido en 4,
es decir, el paso fino es `cell_size / 2 = 0.5 m`.

| Propiedad de `BuildGrid` | Default | Función |
| --- | --- | --- |
| `subdivisions` | `2` | Divisiones por eje dentro de cada celda (`1` desactiva la sub-grilla lógica) |
| `show_subdivisions` | `true` | Dibuja las líneas finas en el overlay |
| `sub_dash_length` | `0.1` | Largo de cada guion, en celdas (0,1 m) |
| `sub_dash_gap` | `0.1` | Separación entre guiones, en celdas (0,1 m) |

Las líneas finas se dibujan **discontinuas** (guiones cortos) para que el ojo
las distinga de la grilla principal de 1 m sin confundir ambas. Con
`sub_dash_length = 0.1` y `sub_dash_gap = 0.1` hay 5 guiones por metro, similar
a la grilla de precisión de *Los Sims*.

Las líneas finas las pinta el mismo `grid.gdshader` (uniform `sub_color`), tanto
en la grilla principal como en la grilla secundaria sobre los pisos. Por eso la
precisión se ve incluso cuando el suelo tapa el plano base.

El patrón de guiones se calcula a partir de la distancia a la línea y de una
máscara a lo largo de ella; cerca de la cámara los guiones quedan nítidos y a
distancia se funden suavemente para evitar parpadeo (`fwidth`). Al alejarse, el
trazo discontinuo se vuelve continuo en lugar de generar ruido.

Todas las líneas de 1 m comparten el mismo grosor (`line_width`): no hay una
línea más gruesa cada 5 m. El único trazo con grosor distinto es el borde del
área construible, que no forma parte de la cuadrícula interior.

#### Cómo se calcula el desplazamiento

Al mover el ratón con la herramienta de objetos, el controlador toma el punto
del plano bajo el cursor, lo compara con el centro de la huella y lo ajusta a la
sub-grilla:

```gdscript
# BuildGrid
func sub_cell_size() -> float:
	return cell_size / float(maxi(subdivisions, 1))

func snap_offset(delta: Vector2, max_steps: int = 1) -> Vector3:
	# redondea delta al paso fino y lo limita a ±max_steps pasos por eje
```

El desplazamiento se **limita a un paso por eje** respecto del centro de la
huella. Al mover el cursor a la celda vecina, el ancla cambia y el desplazamiento
vuelve a empezar, de modo que el recorrido completo ofrece posiciones continuas
cada 0,5 m sin que el objeto “salte” dos celdas.

El offset resultante se guarda en `BuildPiece.sub_offset` y se aplica igual en:

- la pieza real,
- el *ghost* de colocación,
- el *ghost* de borrado (recupera el offset guardado por la pieza).

#### Ocupación con objetos desplazados

La ocupación no se deriva del rectángulo de celdas de la huella, sino de la
**huella real ya desplazada**. `BuildController._object_cells_for()` incluye
toda celda cuyo centro caiga dentro del rectángulo del objeto (con una tolerancia
de `0.001 m`). Consecuencias:

- Una silla de 1×1 desplazada 0,5 m ocupa **2 celdas**.
- Un escritorio de 2×1 desplazado 0,5 m ocupa **3 celdas**.
- Esas celdas bloquean la superposición de otros objetos y permiten borrar el
  objeto desde cualquiera de ellas, no solo desde su celda ancla.

El desplazamiento se persiste en el guardado del nivel como `offset_x` /
`offset_z` dentro de cada entrada de `objects` y se restaura al cargar.

---

## 11. Piezas y prefabs

### 11.1 `BuildPiece`

`BuildPiece` extiende `StaticBody3D` y define la interfaz de una pieza ya
colocada:

| Miembro | Tipo | Uso |
| --- | --- | --- |
| `cell` | `Vector2i` | Celda ocupada (suelos) |
| `wall_key` | `Vector3i` | Borde ocupado (paredes) |
| `is_wall` | `bool` | Discrimina el tipo |
| `set_dimensions(size)` | método | Reemplaza `BoxMesh` y `BoxShape3D` |

`set_dimensions()` conserva el material del `BoxMesh` original y reconstruye
malla y colisión con el tamaño pedido. Esto permite autorar prefabs a 1×1 y
escalarlos según la configuración de la grilla.

### 11.2 Estructura obligatoria de un prefab

Todo prefab de pieza debe cumplir:

```
<Pieza> (StaticBody3D, script BuildPiece)
├── MeshInstance3D     (con un BoxMesh)
└── CollisionShape3D   (con un BoxShape3D)
```

`BuildController._spawn_piece()` valida que la instancia sea `BuildPiece`; si
no, la libera y emite una advertencia.

### 11.3 Prefabs incluidos

| Prefab | Malla | Material | Dimensiones al colocar |
| --- | --- | --- | --- |
| `floor_tile.tscn` | `BoxMesh` | Gris azulado, rugoso | `cell_size × floor_thickness × cell_size` |
| `wall_segment.tscn` | `BoxMesh` | Beige, rugoso | `cell_size × wall_height × wall_thickness` |

Valores por defecto del controlador: `floor_thickness = 0.1`,
`wall_height = 2.8`, `wall_thickness = 0.2`, `cell_size = 1.0`.

---

## 12. Integración

### 12.1 Escena lista para usar

1. Añadir `scripts/systems/build/build_system.tscn` como hijo de la escena del nivel.
2. Ubicar el nodo `BuildSystem` (o `BuildGrid`) a la altura del plano de
   construcción.
3. Ajustar en `BuildGrid`: `cells_x`, `cells_z`, `cell_size`, `plane_y`.
   La grilla es fija por defecto; para agrandarla usa los botones
   **Expandir +X / +Z / ambos** del inspector, edita `cells_x` / `cells_z`, o
   llama a `set_grid_size()` / `expand()`. El modo `auto_expand` es opcional.
4. Opcional en `BuildController`: `wall_height`, `wall_thickness`,
   `floor_thickness`, `floor_scene`, `wall_scene`, `show_help`,
   `start_in_build_mode`.
5. La navegación ya viene incluida: `NavRegion` contiene `PlacedPieces` y
   `BuildNavigation` hornea el NavMesh. Para NPCs, instanciar `scripts/characters/npc/npc.tscn`.

La escena debe contener un `FPSController` (jugador del proyecto).

### 12.2 Resolución automática de referencias

En `_ready()`, si una referencia está vacía, el controlador la busca
recursivamente desde la escena actual:

| Referencia | Búsqueda | Fallback |
| --- | --- | --- |
| `grid` | Primer `BuildGrid` | — (advierte y no entra al modo) |
| `build_camera` | Primer `BuildCamera` | Crea una `BuildCamera` hija |
| `player` | Primer `FPSController` | Se reintenta al entrar al modo |
| `pieces_root` | Nodo llamado `PlacedPieces` | Crea `PlacedPieces` hija |
| `navigation_region` (BuildNavigation) | Primer `NavigationRegion3D` | Advierte y no hornea |
| `build_controller` (BuildNavigation) | Primer `BuildController` | Advierte y no hornea |

Las referencias también se pueden asignar a mano en el inspector; en ese caso
tienen prioridad. Para que el NavMesh incluya las piezas, `PlacedPieces` debe
estar dentro de `NavRegion`.

### 12.3 Demo

`scenes/demos/build_demo.tscn` contiene suelo plano de 80×80, `WorldEnvironment`, sol
direccional, `FPSPlayer` y `BuildSystem` a `y = 0.02`. Es independiente del
mapa de la isla, por lo que sirve para probar sin tocar el nivel principal.

### 12.4 Navegación

`BuildController` emite `pieces_changed` al colocar, borrar o limpiar piezas.
`BuildNavigation` lo escucha y programa un horneado asincrónico con debounce de
`0.35 s`. El `NavigationMesh` se genera desde los `StaticBody3D` de las piezas:
los suelos son caminables y las paredes recortan el área. Un
`filter_baking_aabb` limita la altura para que los techos de las paredes no se
vuelvan caminables.

Los NPC usan `scripts/characters/npc/npc.tscn` (`NpcAgent` + `NavigationAgent3D`) y se mueven con:

```gdscript
npc.move_to(Vector3(10.0, 0.0, 4.0))
```

El prefab reutiliza el modelo y las animaciones del jugador, sin el controlador
FPS, la cámara ni la linterna. La demo `scenes/demos/nav_demo.tscn` muestra el sistema
completo. El detalle técnico está en `docs/navegacion-npcs.md`.

---

## 13. API pública

### `BuildGrid`

```gdscript
# Propiedades exportadas
var cell_size: float
var cells_x: int
var cells_z: int
var plane_y: float
var show_border: bool
var show_floor_grid: bool
var floor_grid_opacity: float
var subdivisions: int
var show_subdivisions: bool
var sub_dash_length: float
var sub_dash_gap: float
var auto_expand: bool
var expand_step: int
var expand_margin: int

# Celdas
func cell_from_world(world: Vector3) -> Vector2i
func is_cell_inside(cell: Vector2i) -> bool
func clamp_cell(cell: Vector2i) -> Vector2i
func cell_center(cell: Vector2i) -> Vector3
func plane_global_y() -> float
func center_point() -> Vector3

# Sub-grilla de precisión (objetos)
func sub_cell_size() -> float
func snap_offset(delta: Vector2, max_steps: int = 1) -> Vector3

# Tamaño / expansión
func set_grid_size(new_cells_x: int, new_cells_z: int) -> void
func expand(add_x: int, add_z: int) -> void
func expand_if_near_edge(cell: Vector2i) -> bool
signal grid_resized(cells_x: int, cells_z: int)

# Bordes de pared
func wall_from_world(world: Vector3) -> Vector3i
func is_wall_inside(key: Vector3i) -> bool
func clamp_wall(key: Vector3i) -> Vector3i
func wall_center(key: Vector3i) -> Vector3
func wall_yaw(key: Vector3i) -> float
func wall_keys_around_cell(cell: Vector2i) -> Array[Vector3i]

# Grilla secundaria sobre pisos
func set_floor_cells(cells: Array[Vector2i], tops: PackedFloat32Array) -> void
func clear_floor_cells() -> void
```

### `BuildController`

```gdscript
enum Tool { FLOOR, WALL, ERASE }

var build_mode: bool
var tool: Tool

func enter_build_mode() -> void
func exit_build_mode() -> void
func set_tool(new_tool: Tool) -> void
func get_floor_count() -> int
func get_wall_count() -> int
func clear_all() -> void

# API programática (mismas validaciones que las herramientas)
func place_floor(cell: Vector2i) -> bool
func place_wall(key: Vector3i) -> bool
func place_object(cell: Vector2i, rotation_steps: int = -1, sub_offset: Vector3 = Vector3.ZERO) -> bool
func place_object_item(item: BuildItem, cell: Vector2i, rotation_steps: int = 0, sub_offset: Vector3 = Vector3.ZERO) -> bool
func erase_at(cell: Vector2i, wall: Vector3i) -> bool

signal pieces_changed
```

### `BuildNavigation`

```gdscript
signal navigation_bake_started
signal navigation_baked

var bake_count: int

func request_bake() -> void
func bake_now() -> void
func is_baking() -> bool
func get_polygon_count() -> int
```

### `NpcAgent`

```gdscript
func move_to(world_position: Vector3) -> void
func stop() -> void
func is_moving() -> bool
func get_target() -> Vector3
```

### `BuildCamera`

```gdscript
var focus: Vector3
var yaw: float
var pitch: float
var distance: float

func frame_grid(center: Vector3, size: float) -> void
```

### `BuildPiece`

```gdscript
var cell: Vector2i
var wall_key: Vector3i
var is_wall: bool
var item_id: StringName
var object_rotation_steps: int
var sub_offset: Vector3

func set_dimensions(size: Vector3) -> void
```

### `BuildInput`

```gdscript
static func ensure_actions() -> void
```

---

## 14. Pruebas

Prueba automática headless:

```powershell
Godot.exe --headless --path . --script res://tests/build_smoke_test.gd
```

Cubre:

- Carga de la escena demo y resolución de nodos.
- `cell_from_world`, `cell_center` e `is_cell_inside` (incluidos negativos y
  límites).
- Detección de los cuatro bordes alrededor de una celda.
- Colocación de suelo y pared.
- Prevención de duplicados.
- Rechazo de piezas fuera de la grilla.
- Orden de borrado (pared antes que suelo).
- Entrada y salida del modo construcción (visibilidad de la grilla).

Resultado esperado:

```
BUILD_SMOKE_TEST_OK
```

con código de salida `0`. Verificado el 2026-11-08 con Godot 4.7.2.

Prueba de navegación:

```powershell
Godot.exe --headless --path . --script res://tests/nav_smoke_test.gd
```

Cubre:

- Carga de `scenes/demos/nav_demo.tscn` y construcción del ejemplo.
- Horneado del NavMesh desde las piezas (polígonos > 0).
- Ausencia de superficies caminables sobre las paredes.
- Camino entre habitaciones y por una puerta de 1 celda.
- Rebake al colocar una pared y alargamiento del camino.
- `NpcAgent.move_to()` ajustando el destino al NavMesh.

Resultado esperado:

```
NAV_SMOKE_TEST_OK
```

---

## 15. Rendimiento y límites actuales

### 15.1 Rendimiento

- Cada pieza es un nodo `StaticBody3D` independiente con su propia malla y
  colisión. Es adecuado para decenas o pocos cientos de piezas.
- Los índices `Dictionary` evitan búsquedas lineales al colocar, validar y
  borrar.
- El overlay es una sola malla con shader; no genera geometría por celda.

### 15.2 Límites conocidos

- **Grilla plana:** no se adapta al terreno. Debe ubicarse en una zona plana o
  a la altura del suelo.
- **Expansión solo hacia +X/+Z:** el origen (celda `0,0`) no se mueve, así que
  `set_grid_size` / `expand` no agrandan hacia coordenadas negativas.
- **Sin rotación del nodo:** la matemática asume ejes alineados al mundo.
- **Suelos y paredes de una celda:** los muebles pueden ocupar varias celdas
  (huella) y desplazarse en pasos de sub-grilla de 0,5 m; no hay muros
  compuestos.
- **Sin persistencia:** las construcciones viven solo en memoria de la escena.
- **Sin deshacer/rehacer.**
- **Sin validación estructural:** se puede colocar una pared sin suelo y un
  suelo flotando en el aire.
- **Una sola planta:** `plane_y` es fijo; no hay losas ni escaleras.
- **El borrado prioriza la pared** sobre el suelo en el mismo punto.
- **Navegación de una sola planta plana:** no hay rampas, escaleras ni
  ascensores. El NavMesh se hornea desde los colliders de las piezas.
- **Sin puertas dinámicas:** una puerta es un hueco entre paredes; no hay
  prefab que se abra o cierre.
- **Sin evitación entre NPCs:** `avoidance_enabled` está desactivado.
- **`NavigationRegion3D` es experimental** en Godot 4.7; verificado con 4.7.2.

---

## 16. Extensiones previstas

| Mejora | Enfoque sugerido |
| --- | --- |
| Grilla adaptada al terreno | Muestrear altura por celda y usar `plane_y` variable o malla de overlay deformada. |
| Muros encadenados / multi-celda | Clave de borde + longitud; autoconectar esquinas. |
| Plantas múltiples | Añadir `level` a la identidad de celda/borde y apilar planos. |
| Guardado / carga | Serializar `_floors` y `_walls` (claves + tipo + nivel) a JSON o Resource. |
| Catálogo UI de piezas | Reemplazar los prefabs fijos por un recurso de catálogo con iconos y coste. |
| Deshacer / rehacer | Pila de comandos de colocación/borrado. |
| Validación estructural | Reglas de soporte (pared requiere suelo, suelo requiere apoyo). |
| Optimización | `MultiMeshInstance3D` o *chunking* para edificios grandes. |
| Puertas y ventanas | Variantes del prefab de pared con huecos y snapping al borde. |

---

## 17. Referencias

- `scripts/systems/build/build_grid.gd` — geometría y overlay.
- `scripts/systems/build/build_controller.gd` — lógica de construcción.
- `scripts/systems/build/build_camera.gd` — cámara orbital.
- `scripts/systems/build/build_piece.gd` — pieza base.
- `scripts/systems/build/build_input.gd` — acciones de entrada.
- `scripts/systems/build/shaders/grid.gdshader` — shader de grilla.
- `scripts/systems/build/build_system.tscn` — escena ensamblada.
- `scripts/systems/build/build_navigation.gd` — horneado del NavMesh.
- `docs/construccion.md` — guía rápida de uso.
- `scripts/characters/npc/npc_agent.gd` — movimiento y deambular de NPC.
- `scripts/characters/npc/npc.tscn` — prefab de NPC con modelo/animaciones del jugador.
- `scenes/demos/build_demo.tscn` — demo ejecutable.
- `scenes/demos/nav_demo.tscn` — demo de navegación.
- `tests/build_smoke_test.gd` — prueba automática de construcción.
- `tests/nav_smoke_test.gd` — prueba automática de navegación.
- `docs/navegacion-npcs.md` — documento técnico de navegación.
