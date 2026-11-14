# Proyecto Hospital

Juego en primera persona hecho con **Godot 4.7**. Incluye un sistema de
construcción por celdas (paredes, pisos, muebles), NPCs con navegación por
NavMesh, objetos inteligentes con *affordances* y un mapa de isla.

## Requisitos

- [Godot 4.7.2](https://godotengine.org/) o superior (el proyecto usa Jolt
  Physics y D3D12 en Windows).
- Plugins incluidos en `addons/`:
  - **FuncGodot 2025.12** — mapas `.map` de Quake/TrenchBroom.
  - **Terrain3D 1.0.2** — terreno editable. *(Hay una versión 1.1.0 disponible;
    ver “Dependencias” al final).*

## Ejecutar

1. Abrir `project.godot` con Godot.
2. La escena principal es `scenes/demos/build_demo.tscn`.
3. Pulsar **F5** para jugar o **F6** para ejecutar la escena actual.

Desde consola:

```powershell
Godot.exe --path . res://scenes/demos/build_demo.tscn
```

## Estructura del proyecto

```
Proyecto-Hospital/
├── addons/                  Plugins de terceros (FuncGodot, Terrain3D)
├── assets/                  Recursos del juego
│   ├── animations/          Animaciones y AnimationLibrary del jugador
│   ├── characters/          Modelo y texturas del personaje
│   ├── maps/                Mapa de la isla
│   │   └── isla_asercion/   Modelo, materiales, terreno 3D y fuentes .map
│   ├── models/              Modelos de construcción y niveles
│   │   ├── construction/    Paredes, pisos y texturas
│   │   └── levels/          Modelos de niveles
│   └── textures/            Biblioteca de texturas compartidas
├── data/                    Recursos de gameplay (.tres)
│   ├── build_items/         Catálogo del menú de construcción
│   └── smart_objects/       Definiciones de objetos inteligentes
├── docs/                    Documentación técnica y de uso
├── scenes/
│   └── demos/               Escenas de demostración
├── scripts/
│   ├── characters/          Jugador y NPCs
│   └── systems/             Construcción, navegación y Smart Objects
├── tests/                   Pruebas automáticas (headless)
│   └── debug/               Utilidades de depuración de modelos
├── tools/
│   └── actionforge/         Biblioteca fuente de ActionForge (ignorada por Godot)
├── project.godot
└── README.md
```

### Reglas de organización

- Los recursos que Godot importa viven en `assets/`; los scripts y escenas en
  `scripts/` y `scenes/`; los datos de gameplay en `data/`.
- `tools/actionforge/` contiene los archivos originales de ActionForge y tiene
  un `.gdignore`, por lo que Godot no los importa. Los modelos listos para el
  juego están en `assets/`.
- Los backups automáticos de Blender (`*.blend1`) no se versionan.

## Demos

| Escena | Qué muestra |
| --- | --- |
| `scenes/demos/build_demo.tscn` | Construcción, NPCs y mapa de la isla |
| `scenes/demos/nav_demo.tscn` | Dos habitaciones y NPCs con NavMesh |
| `scenes/demos/npc_spawner_demo.tscn` | Spawners de NPC por oleadas |
| `scenes/demos/smart_object_demo.tscn` | Silla con *affordance* de sentarse |

Controles principales: **B** modo construcción, **M** menú, **1/2/3**
herramientas, **WASD** mover, **F** linterna, **Ctrl+S** guardar.

## Pruebas

```powershell
Godot.exe --headless --path . --script res://tests/build_smoke_test.gd
Godot.exe --headless --path . --script res://tests/nav_smoke_test.gd
Godot.exe --headless --path . --script res://tests/nav_map_smoke_test.gd
Godot.exe --headless --path . --script res://tests/npc_spawner_smoke_test.gd
Godot.exe --headless --path . --script res://tests/smart_object_smoke_test.gd
Godot.exe --headless --path . --script res://tests/animation_manager_smoke_test.gd
```

## Documentación

- [Sistema de construcción](docs/construccion.md)
- [Sistema de grilla (detalle técnico)](docs/sistema-grilla.md)
- [Navegación de NPCs](docs/navegacion-npcs.md)
- [Spawners de NPCs](docs/npc-spawners.md)
- [Smart Objects](docs/smart-objects.md)
- [Objetos especiales](docs/objetos-especiales.md)
- [Atuendo modular](docs/atuendos.md)
- [Estado técnico del proyecto](docs/estado-tecnico.md)

## Dependencias

| Dependencia | Versión instalada | Última disponible | Estado |
| --- | --- | --- | --- |
| FuncGodot | 2025.12 | 2025.12 | Al día |
| Terrain3D | 1.0.2 | 1.1.0 | Pendiente de actualizar |

Para actualizar Terrain3D, reemplazar `addons/terrain_3d/` por el contenido de
`Terrain3D_v1.1.0-stable.zip`. La versión 1.1.0 es compatible con Godot 4.5–4.8.
