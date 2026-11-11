# Spawners de NPCs

Sistema mínimo para que aparezcan NPCs en puntos fijos del nivel (POI),
busquen un SmartObject, lo usen y vuelvan a un spawner para desaparecer.

Primera versión, pensada para tener población viva sin llenar la escena:

- **Máximo 5 NPCs vivos** en toda la escena (tope global).
- **No aparecen todo el tiempo**: esperan un intervalo aleatorio entre
  apariciones.
- Solo aparecen si hay un **SmartObject libre** al que puedan ir.
- El NPC **vuelve a cualquier spawner** y desaparece **solo al llegar**: nunca
  se lo elimina a mitad de camino. Si se traba, recalcula la ruta y sigue.

```
Spawner (POI)
  ├─ espera intervalo
  ├─ ¿quedan menos de 5 NPCs?  ── no ──> espera otra vez
  ├─ ¿hay un SmartObject libre? ── no ──> espera otra vez
  └─ instancia npc.tscn
        └─ NpcBrain: reserva slot → camina → usa
              └─ NpcSpawnCycle: vuelve al spawner más cercano
                                  └─ solo al llegar → queue_free()
```

## Cómo usarlo

1. Arrastrá `scripts/Characters/npc/npc_spawner.tscn` a la escena. Cada
   instancia es un **POI de aparición** (se ve como un cilindro celeste).
2. Poné dos (o los que quieras) en zonas caminables del NavMesh. Pueden estar
   fuera de la grilla (terreno, patio) si `BuildNavigation` hornea el mapa
   completo; el NPC entra por la celda de grilla más cercana antes de ir al
   mueble (ver [navegación de NPCs](navegacion-npcs.md)).
3. Ajustá en el inspector:
   - `npc_parent_path`: dónde se cuelgan los NPCs (por defecto busca un nodo
     `NPCs` en la escena; si no hay, usa el padre del spawner).
   - `max_alive_total`: tope global. **Todos los spawners deben usar el mismo
     valor** para respetar el límite de 5.
   - `spawn_interval_min` / `spawn_interval_max`: cada cuánto intenta aparecer.
4. Listo: los spawners se encuentran entre sí por un registro estático, sin
   autoload ni configuración extra.

No hace falta nada más: `NpcSpawnCycle` se agrega solo al NPC generado.

## Parámetros

| Grupo | Propiedad | Default | Qué hace |
|---|---|---|---|
| — | `npc_scene` | `npc.tscn` | Escena a instanciar (raíz `NpcAgent`). |
| — | `npc_parent_path` | vacío | Nodo padre de los NPCs generados. |
| — | `enabled` | `true` | Activa/desactiva el spawner. |
| Población | `max_alive_total` | `5` | Tope de NPCs vivos en toda la escena. |
| Población | `spawn_interval_min` | `8.0` | Segundos mínimos entre apariciones. |
| Población | `spawn_interval_max` | `16.0` | Segundos máximos entre apariciones. |
| Población | `initial_delay` | `2.0` | Espera antes de la primera aparición. |
| Objetivo | `require_objective` | `true` | No aparece si no hay SmartObject libre. |
| Objetivo | `objective_affordance` | `&"sit"` | Affordance que debe ofrecer el objeto. |
| Objetivo | `objective_search_radius` | `0.0` | Radio de búsqueda del objeto. `0` = sin límite: el spawner puede estar lejos del hospital. |
| Vida del NPC | `need` | `&"rest"` | Necesidad con la que aparece (urgente). |
| Vida del NPC | `brain_search_radius` | `0.0` | Radio que usa el `NpcBrain`. `0` = sin límite; primero camina a la grilla y ahí elige. |
| Vida del NPC | `search_timeout` | `30.0` | Si no consigue objeto, vuelve y desaparece. |
| Vida del NPC | `return_retry_delay` | `3.0` | Cada cuánto recalcula el camino de vuelta. No desaparece en el camino: solo al llegar. |
| Visual | `show_marker` | `true` | Muestra el cilindro del POI. |

## API

```gdscript
var spawner: NpcSpawner = get_node("Spawners/SpawnerA")

spawner.spawn_now()        # NpcAgent o null (respeta tope/objetivo/NavMesh)
spawner.can_spawn()        # bool
spawner.has_objective()    # ¿hay un SmartObject libre cerca?
spawner.get_alive_count()  # NPCs generados vivos
spawner.stop()             # deja de aparecer (los vivos siguen su ciclo)
spawner.start()            # reanuda

NpcSpawner.get_spawners()               # Array de spawners registrados
NpcSpawner.count_alive()                # NPCs vivos en toda la escena
NpcSpawner.pick_return_spawner(pos)     # spawner al que volver
```

Señales: `npc_spawned(npc)`, `npc_despawned(npc)`.

## Demo

```powershell
Godot.exe --path . res://scenes/demo/npc_spawner_demo.tscn
```

La demo construye dos habitaciones, coloca 5 sillas y tiene **2 POI de
spawner**. En pantalla se ve `NPCs vivos: N / 5`. Cada NPC aparece, camina a
una silla, se sienta y vuelve al spawner más cercano para desaparecer.

El script `scenes/demo/npc_spawner_demo.gd` extiende `nav_demo.gd`: reutiliza
la construcción de habitaciones y sólo agrega sillas y el HUD del spawner.

## Pruebas

```powershell
Godot.exe --headless --path . --script res://tests/npc_spawner_smoke_test.gd
```

Verifica el registro de los 2 POI, el tope de 5, que el intervalo quede
programado, la configuración del NPC (cerebro + ciclo), que **no desaparezca**
al vencer el reintento de vuelta y que recién desaparezca al llegar al spawner.

## Límites de esta primera versión

- Una sola interacción por NPC: usa un objeto y se va (no se queda a vivir).
- Sin colas: si no hay slot libre, el NPC espera a la próxima aparición.
- El retorno es al spawner **más cercano** (`prefer_nearest`); se puede cambiar
  a aleatorio en `NpcSpawner.pick_return_spawner()`.
- Sin horarios, tipos de NPC ni probabilidades por POI.
- El tope es global pero se configura por spawner: si ponés valores distintos,
  manda el menor de los dos.
- El spawner puede estar lejos del hospital: con `objective_search_radius = 0`
  y `brain_search_radius = 0` no hay límite de distancia. El NPC aparece en el
  spawner, camina a la celda de grilla más cercana y recién ahí elige el
  SmartObject. Los tiempos de búsqueda y viaje se pausan mientras camina, así
  la distancia nunca lo obliga a volver.
- No hay persistencia: al recargar la escena la población arranca de cero.
- Si el spawner de vuelta es inalcanzable, el NPC sigue vivo reintentando la
  ruta (por diseño: nunca desaparece lejos del spawner).
