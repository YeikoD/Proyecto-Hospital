# Objetos especiales (combinaciones de piezas)

Un **objeto especial** es una entidad interactiva formada por dos o más piezas
colocadas por separado en la grilla. Las piezas conservan sus modelos y
colliders, pero mientras el conjunto está activo:

- los `SmartObject` individuales de las piezas se **suspenden** (dejan de estar
  en `SmartObjectRegistry`);
- se registra un **`SpecialObject`** nuevo con su propia `SmartObjectDef`.

El primer caso implementado es el **Escritorio de trabajo**: se forma con un
**Escritorio**, una **Silla de escritorio** delante (el operador) y al menos una
**Silla de pacientes** del otro lado, una grilla más atrás. El conjunto ofrece
`work` para el operador y `sit` para los pacientes.

## Flujo

```
Escritorio          Silla de escritorio        Sillas de pacientes
(base)              (operador, delante)        (client, lado opuesto)
   │                        │                          │
   └──────────── receta SpecialObjectDef ──────────────┘
                 (data/special_objects/work_desk.tres)
                              │
                              ▼
                    SpecialObject "work_desk"
                    ├── Slot_0        operador (tag "work")
                    ├── Slot_1..3     pacientes (tag "seat")
                    ├── POI_* / Approach_* copiados de cada mueble
                    └── definition: SmartObjectDef "work_desk"
                              │
                              ▼
                     SmartObjectRegistry
                     (solo el conjunto, no las piezas)
```

## Archivos

```
scripts/systems/smart_objects/
├── special_object_def.gd       Receta de combinación (recurso)
├── special_object.gd           Nodo combinado en runtime
└── special_object_loader.gd    Carga las recetas del directorio

data/special_objects/
└── work_desk.tres              Escritorio + operador + pacientes

data/smart_objects/
├── work.tres                   Affordance "work" (animación de sentarse)
├── sit.tres                    Affordance "sit" para los pacientes
└── work_desk.tres              SmartObjectDef del conjunto (work + sit)

data/build_items/muebles/
├── furniture_desktop.tres              base de la receta
├── furniture_chair_desktop.tres        operador que se acopla
└── furniture_patient_chairs.tres       pieza client (sillas de pacientes)

tests/special_object_smoke_test.gd
tests/special_object_overlap_smoke_test.gd
tests/patient_desk_smoke_test.gd
tests/chair_extension_smoke_test.gd
tests/desk_dock_smoke_test.gd
```

## Reglas de combinación

Cuando se coloca una pieza, `BuildController` recorre las recetas cargadas y
comprueba si la pieza recién colocada cierra alguna. La combinación funciona en
los dos órdenes: primero el escritorio y después la silla, o al revés.

Para que el conjunto se forme:

1. **Base + operador**: una pieza debe tener el `id` de `base_item_id` y la otra
   el de `part_item_id`.
2. **Adyacencia**: sus huellas deben tocar una celda vecina en la grilla (no
   vale solo la diagonal).
3. **Contacto real**: los rectángulos XZ de las huellas deben tocarse, con una
   tolerancia de `max_gap`. Un objeto desplazado 0,5 m que deja un hueco no se
   acopla.
4. **Lado del operador**: el operador va del lado opuesto a la banca de
   pacientes. Así el conjunto funciona con el escritorio en cualquier rotación
   y da igual en cuál de los dos lados se coloque la silla. Si la receta no usa
   banca (solo sillas de escritorio como clientes), se usa `operator_side` como
   pista: un lado local de la base. El Escritorio de trabajo usa `(0, -1)`.
   La colocación no exige el lado correcto; solo la formación del conjunto lo
   tiene en cuenta, para que el fantasma no se ponga rojo al acomodar la silla.
5. **Acople centrado** (`part_dock_center`): el operador solo puede quedar
   centrado en el lado largo de la base y apoyado contra el borde del lado del
   operador. Mientras se acerca, el snap lo lleva solo a ese punto y lo gira
   para mirar a la base; no se puede colocar centrado dentro de la huella ni
   atravesándola. `part_dock_depth` permite un solape pequeño y controlado
   (0 = apoyado contra el borde). Aunque el cursor esté una o dos celdas más
   lejos, la silla de escritorio igual se gira para mirar al escritorio.
6. **Orientación** (`require_facing`): el frente de la pieza acoplada (`-Z`
   local) debe apuntar hacia la base. Con `snap_part_rotation = true`, al
   formarse el conjunto el sistema gira automáticamente la pieza de 1x1 para
   mirar a la base; si no, hay que orientarla antes con `R`. El parámetro
   `facing_dot` define el cono permitido (`0.7` ≈ 45°).
7. **Clientes obligatorios** (`client_item_ids`): si la receta define piezas
   client, debe haber al menos `client_min_count` en el **lado opuesto** al
   operador. Para el escritorio se aceptan las sillas de pacientes y sillas de
   escritorio sueltas:
   - el lado opuesto se deriva de la celda ancla del operador;
   - `client_gap` define las celdas vacías entre la base y el cliente:
     `0` = directamente detrás del escritorio, `1` = una celda vacía en medio;
   - el cliente debe entrar en el ancho lateral de la base, con
     `client_lateral_tolerance` celdas de margen;
   - se integran hasta `client_max_count` piezas client.

La pieza acoplada aporta el slot del operador (`slot_source = "part"`) y las
piezas client aportan sus propios slots. Los tags evitan que se mezclen:

- el slot del operador se etiqueta `part_slot_tag` (por defecto `"work"`);
- los slots de pacientes se etiquetan `client_slot_tag` (por defecto `"seat"`);
- `work.tres` solo acepta slots `"work"` y `sit.tres` solo acepta `"seat"`.

Así el operador trabaja en su silla y los pacientes se sientan en las suyas.

### Celdas compartidas

El operador se apoya contra el borde frontal del escritorio: su centro queda
justo sobre el borde de la huella y el cuerpo de la silla no la invade. Aun así
la celda de la base y la del operador pueden tocarse y compartir una celda de
borde:

- las celdas compartidas **siguen perteneciendo a la base**;
- la pieza acoplada conserva su propia celda ancla, libre;
- la ocupación de la pieza se limita a sus celdas libres;
- la pareja solo se permite si el acople está centrado y la orientación es
  válida.

Las piezas client (por ejemplo las sillas de pacientes) sí pueden quedar medio
metro metidas hacia el escritorio, compartiendo celdas con la base, pero nunca
centradas dentro de su huella. La celda ancla de la pieza nunca queda debajo de
la base: si el snap la deja ahí, el controlador corre el ancla a una celda libre
vecina y compensa el sub-offset. La pieza no se mueve en el mundo y el
borrado/guardado siguen siendo claros.

Si la silla se coloca antes que el escritorio y ya está del lado del operador,
al colocar la base el controlador la corre sola al punto de acople y la gira
hacia la mesa.

## Cómo probarlo

1. Entrá al modo construcción (`B`).
2. Colocá un **Escritorio**.
3. Seleccioná **Silla Escritorio** y acercala al lado largo del escritorio. El
   fantasma se centra solo en el medio del borde frontal y gira la silla para
   mirar a la mesa. No se puede soltar dentro de la huella ni atravesándola.
4. Del lado opuesto a esa silla, directamente detrás, colocá **Sillas de
   pacientes** o sillas de escritorio sueltas. Podés poner hasta dos piezas
   client y orientarlas a lo ancho. Cada silla client puede quedar medio metro
   metida hacia el escritorio aunque el conjunto ya esté formado.
5. Al colocar la última pieza, debería formarse **Escritorio de trabajo**.

El lado del conjunto lo define la banca de pacientes: la silla del operador va
siempre del lado contrario. Por eso funciona igual con el escritorio girado.

Sin la pieza de pacientes el conjunto no se forma: quedan el escritorio y la
silla como SmartObjects individuales.

Si el fantasma aparece en rojo, revisá que la celda tenga piso y que la celda
vecina donde se guarda el ancla de la silla esté libre. La orientación de la
silla no importa: se acomoda sola al formarse el conjunto.

## IA y animaciones

- El escritorio de trabajo usa `sit_animations.tres`, la misma secuencia
  `enter → loop → exit` que la silla normal, tanto para el operador como para
  los pacientes.
- `NpcBrain` mapea la necesidad `work` a la affordance `work`:
  - `needs = {"rest": 0.0, "work": 0.0}`
  - `need_affordances = {"rest": "sit", "work": "work"}`
- La affordance `work` tiene `needs_effects = {"work": 0.7}`: al terminar, el
  NPC descansa de esa necesidad.
- La affordance `sit` usa los slots de pacientes (`tag "seat"`), así que otros
  NPCs pueden sentarse a esperar mientras el operador trabaja.
- Si el escritorio está ocupado, el cerebro prueba la siguiente necesidad (por
  ejemplo, descansar en una silla libre).
- Los NPCs de ruta (`NpcSpawner` + `NpcRouteFSM`) también consideran `work`:
  `route_affordances = [&"sit", &"work"]` y eligen la mejor puntuación.
- `build_demo.gd` inicializa ambas necesidades altas para que se vea el uso en
  la demo y en el nivel principal.

## La receta `SpecialObjectDef`

| Propiedad | Default | Función |
| --- | --- | --- |
| `id` | vacío | Identificador de la receta |
| `display_name` | vacío | Nombre del objeto resultante |
| `base_item_id` | vacío | `BuildItem.id` de la base (escritorio) |
| `part_item_id` | vacío | `BuildItem.id` de la pieza acoplada (operador) |
| `client_item_ids` | vacío | IDs de `BuildItem` que pueden actuar como piezas client |
| `smart_object` | — | `SmartObjectDef` del conjunto |
| `slot_source` | `"part"` | Qué pieza aporta el slot del operador (`"part"` o `"base"`) |
| `slot_index` | `0` | Slot que se copia de esa pieza |
| `part_slot_tag` | `"work"` | Tag del slot del operador |
| `client_slot_tag` | `"seat"` | Tag de los slots de las piezas client |
| `require_facing` | `true` | Exige que la pieza mire a la base |
| `snap_part_rotation` | `true` | Gira la pieza de 1x1 para mirar a la base al formarse |
| `part_dock_center` | `false` | Exige que el operador quede centrado en el lado largo y apoyado en el borde frontal |
| `part_dock_depth` | `0.0` | Metros de solape permitido al acoplarse (`0` = apoyado contra el borde) |
| `operator_side` | `(0, -1)` | Pista de lado local cuando no hay banca de pacientes; `(0, 0)` = sin restricción. El Escritorio de trabajo usa `(0, -1)` |
| `remove_together` | `false` | Al borrar una pieza, borra también el resto |
| `max_gap` | `0.08` | Hueco máximo entre huellas, en metros |
| `facing_dot` | `0.7` | Tolerancia angular del frente |
| `client_min_count` | `1` | Mínimo de piezas client para formar el conjunto (`0` = opcionales) |
| `client_max_count` | `1` | Máximo de piezas client que se integran (`0` = sin límite) |
| `client_gap` | `0` | Celdas vacías exactas entre la base y el cliente (`0` = pegado) |
| `client_lateral_tolerance` | `0.5` | Margen lateral permitido, en celdas |
| `exclusive_group` | `""` | Grupo que puede reservar las affordances de `exclusive_affordances`. El Escritorio de trabajo usa `doctor_npcs` |
| `exclusive_affordances` | `[]` | Affordances reservadas a `exclusive_group`. Vacío = todas. El Escritorio de trabajo reserva `work` (el operador) y deja `sit` para los pacientes |

`SpecialObjectDef.is_valid()` comprueba que la receta tenga id, base, pieza
acoplada y una definición SmartObject. `client_min_count` puede ser `0`: en ese
caso el conjunto se forma solo con base + operador y las piezas client se
integran si aparecen después.

El Escritorio de trabajo usa `client_min_count = 0` y `client_max_count = 2`, y
acepta como clientes tanto `furniture_patient_chairs_01` como
`furniture_chair_desktop_01`. **Al anclar la silla al escritorio el objeto
especial se forma inmediatamente**, sin exigir la banca. Las sillas de pacientes
se agregan al conjunto cuando se colocan del otro lado.

Si hay una banca de pacientes, el operador se busca del lado opuesto a esa
banca, sin importar la rotación del escritorio. Si no hay banca, cualquier lado
adyacente sirve como operador: `operator_side = (0, -1)` es solo la pista que
usa el fantasma para acoplar y centrar la silla. Al colocar la silla cerca del
escritorio, el controlador la auto-acopla (la centra y la gira hacia la mesa)
antes de validar la receta.

## Ciclo de vida

### Formación

1. `BuildController._place_object()` registra la pieza y llama a
   `_try_form_special_object()`.
2. Si la receta se cumple, crea un `SpecialObject`, copia los markers del
   operador y de cada pieza client, y lo agrega al árbol.
3. `SpecialObject._ready()` (heredado de `SmartObject`) lo registra en
   `SmartObjectRegistry`.
4. Las piezas originales (base, operador y clientes) se suspenden: se liberan
   sus reservas, se quitan del registry y del grupo `smart_objects`.

Las piezas siguen existiendo, con su collider, para el NavMesh y el borrado.

Si el conjunto ya está formado y se coloca otra pieza client válida (por
ejemplo, una segunda silla de pacientes), el controlador **rehace** el
`SpecialObject` con todas las piezas client para que sus asientos queden
integrados. Las reservas activas del conjunto anterior se pierden en ese
momento.

Esa pieza nueva puede quedar medio metro metida hacia el escritorio aunque
comparta celdas con piezas del conjunto ya formado: la celda compartida sigue
perteneciendo al conjunto y la silla conserva su propia celda ancla. Así se
pueden poner dos sillas de pacientes pegadas, las dos metidas medio metro, sin
tener que correr una celda entera hacia atrás.

### Separación

Al borrar una de las piezas:

- si `remove_together = false` (default), el conjunto se disuelve y las piezas
  restantes vuelven a registrarse como SmartObjects normales;
- si `remove_together = true`, se borran todas las piezas del conjunto.

El borrado usa la misma animación de desmontaje que cualquier objeto.

### Limpieza

`BuildController.clear_all()` libera primero los objetos especiales y después
las piezas, para que no intenten restaurar SmartObjects que también se están
borrando.

## Persistencia

No se guarda el objeto especial como una entrada aparte: se guardan las piezas
individuales con su `item_id`, rotación y `offset`. Al cargar el nivel, la
combinación se vuelve a detectar automáticamente cuando se coloca la última
pieza de la receta.

## API

### `BuildController`

```gdscript
func get_special_object_count() -> int
func get_special_objects() -> Array[SpecialObject]
func get_special_object_at(cell: Vector2i) -> SpecialObject
func get_special_object_for(piece: BuildPiece) -> SpecialObject

signal special_object_formed(object: Node)
signal special_object_dissolved(object: Node)
```

`get_object_count()` y `get_objects()` siguen contando las **piezas físicas**
(escritorio, silla del operador y sillas de pacientes por separado), no el
conjunto lógico.

### `SpecialObject`

Hereda toda la API de `SmartObject` (`reserve`, `occupy`, `release`,
`get_use_transform`, `get_poi_transform`, ...) y agrega:

```gdscript
var special_def: SpecialObjectDef
func get_parts() -> Array[BuildPiece]
func has_part(piece: BuildPiece) -> bool
func get_special_id() -> StringName
func get_display_name() -> String
```

## Cómo agregar otro objeto especial

1. Crear un `SmartObjectDef` para el resultado (o reutilizar uno).
2. Crear un `SpecialObjectDef` en `res://data/special_objects/` con los `id` de
   la base y la pieza acoplada, el `smart_object` resultante y las reglas de
   acople. Opcionalmente, agregar `client_item_ids` y sus reglas.
3. Asegurarse de que todos los `BuildItem` existan en
   `res://data/build_items/`.
4. Probar la orientación y el lado: la pieza acoplada se acomoda sola y, si la
   receta usa banca de pacientes, el operador va del lado opuesto.

No hace falta tocar código: el loader recoge todas las recetas válidas del
directorio al iniciar.

## Pruebas

```powershell
Godot.exe --headless --path . --script res://tests/special_object_smoke_test.gd
Godot.exe --headless --path . --script res://tests/special_object_overlap_smoke_test.gd
Godot.exe --headless --path . --script res://tests/patient_desk_smoke_test.gd
Godot.exe --headless --path . --script res://tests/work_desk_ai_smoke_test.gd
Godot.exe --headless --path . --script res://tests/route_work_smoke_test.gd
Godot.exe --headless --path . --script res://tests/chair_extension_smoke_test.gd
Godot.exe --headless --path . --script res://tests/desk_dock_smoke_test.gd
```

`special_object_smoke_test.gd` cubre:

- carga de la receta y de la silla de escritorio con su propio `id`;
- que sin sillas de pacientes **no** se forme el conjunto;
- combinación con pacientes en ambos órdenes;
- suspensión de los SmartObjects individuales y registro del conjunto;
- copia del slot del operador y de los slots de pacientes;
- reserva de `work` solo en el slot del operador y de `sit` en pacientes;
- auto-orientación de una silla colocada mirando al lado opuesto;
- disolución al borrar una pieza y restauración del resto.

`special_object_overlap_smoke_test.gd` cubre el acople y las celdas
compartidas:

- el snap centra al operador en el borde frontal del escritorio;
- el fantasma lo gira para mirar a la mesa;
- la celda compartida sigue perteneciendo al escritorio;
- la silla se puede colocar aunque todavía no mire al escritorio y luego se
  auto-orienta;
- si el cursor cae sobre la celda del escritorio, el ancla se resuelve en la
  celda libre del lado de la silla;
- la receta se forma con pacientes en los dos órdenes de colocación;
- borrar la silla separa el conjunto y deja el escritorio y los pacientes.

`patient_desk_smoke_test.gd` cubre el requisito de la pieza client:

- sin sillas de pacientes no se forma el objeto especial;
- con una banca de pacientes al otro lado se forma;
- el conjunto tiene 1 slot de operador y 3 de pacientes;
- `work` y `sit` usan slots distintos;
- se pueden agregar dos sillas sueltas como clientes y el conjunto se rehace
  con los dos asientos;
- se puede colocar primero las dos sillas de atrás y el operador al final;
- con el escritorio girado, la banca define el lado y el operador va del lado
  opuesto;
- al borrar la banca de pacientes el conjunto se disuelve.

`chair_extension_smoke_test.gd` cubre la ampliación con el conjunto ya formado:

- se agrega una segunda silla de pacientes al lado de la primera, las dos
  metidas medio metro hacia el escritorio;
- la silla nueva puede compartir celdas con el conjunto existente;
- el conjunto se rehace con los dos asientos y el operador conserva el suyo;
- las dos sillas dan asientos distintos;
- la silla nueva conserva su celda ancla y se puede borrar.

`desk_dock_smoke_test.gd` cubre el acople estricto con el layout guardado:

- el cursor apunta al centro de la celda del escritorio;
- el snap apoya la silla en el borde frontal, centrada en el lado largo;
- el ancla se guarda en la celda libre del frente y el sub-offset la centra;
- la silla se gira sola para mirar al escritorio;
- no puede colocarse centrada ni atravesando la huella;
- aunque el cursor quede una celda más lejos, igual se gira hacia el escritorio;
- con la banca del lado opuesto el conjunto se forma y reconoce al operador;
- el conjunto también se forma si la silla acoplada se coloca primero.

`work_desk_ai_smoke_test.gd` cubre la integración con la IA:

- un NPC con necesidad `work` elige el Escritorio de trabajo;
- usa la affordance `work` y la misma secuencia de animación que la silla;
- encadena `enter → loop` y termina la interacción;
- la necesidad `work` baja al terminar.

`route_work_smoke_test.gd` cubre el selector de los NPCs de ruta:

- con un Escritorio de trabajo cerca, `NpcRouteFSM` elige `work`;
- configura el cerebro con la necesidad `work`;
- la ruta entra en `USE_SMART_OBJECT`.

Resultados esperados: `SPECIAL_OBJECT_SMOKE_TEST_OK`, `SPECIAL_OVERLAP_OK`,
`PATIENT_DESK_OK`, `CHAIR_EXTENSION_OK`, `DESK_DOCK_OK`, `WORK_DESK_AI_OK` y
`ROUTE_WORK_OK`.

## Límites actuales

- Una receta combina una base, una pieza acoplada y, opcionalmente, piezas
  client. El Escritorio de trabajo integra hasta **2** piezas client
  (`client_max_count = 2`); si se coloca otra válida, el conjunto se rehace para
  incluirla.
- La base solo puede tener un objeto especial activo a la vez.
- No se pueden mover piezas ya colocadas salvo el acople automático del
  operador: si la silla ya está del lado del operador cuando se coloca la base,
  el sistema la corre y la gira al punto de acople. Para el resto hay que
  borrar y volver a colocar.
- La orientación usa pasos de 90° y huellas alineadas a los ejes; no hay
  acoples diagonales ni rotaciones libres.
- `remove_together` está desactivado por defecto para que borrar una pieza no
  elimine la otra por sorpresa.
- El `work` usa la misma secuencia de sentarse que la silla (`sit_animations.tres`)
  hasta que exista un clip de trabajo propio.
