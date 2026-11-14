# Atuendo modular

Sistema para reemplazar partes de la malla de un personaje por piezas de ropa
exportadas por separado. Pensado para los atuendos del hospital: el mismo
cuerpo base puede vestir una túnica y un pantalón, y cambiar de conjunto sin
duplicar el NPC.

## Piezas

Cada pieza es un `OutfitPiece`:

| Propiedad | Ejemplo | Qué hace |
|---|---|---|
| `slot` | `&"torso"` | Ranura lógica; identifica la pieza equipada |
| `base_part` | `&"torso"` | Nombre del `MeshInstance3D` del cuerpo que se oculta |
| `scene` | `tunica_servicio_01.glb` | Escena con la malla de ropa |

Un `OutfitDef` agrupa varias piezas:

```gdscript
var outfit = load("res://data/outfits/atuendo_servicio.tres")
var component = npc.get_node("Outfit") as CharacterOutfit
component.apply_outfit(outfit)
component.unequip(&"torso")
component.clear()
```

## Cómo funciona

`CharacterOutfit` (hijo del NPC, apuntando a `Visual`) hace, por cada pieza:

1. Busca el `Skeleton3D` y el `MeshInstance3D` base (`base_part`).
2. Instancia la pieza y hornea la transformación del nodo de la malla
   (escala/rotación de exportación) en sus vértices y normales.
3. Le asigna a cada vértice de la ropa los huesos/pesos del vértice más
   cercano de la parte base. Así la ropa se deforma con el mismo esqueleto y
   las animaciones de caminar/sentarse.
4. Agrega la malla bajo el `Skeleton3D`, con el `Skin` de la parte base.
5. Oculta la parte base (`visible = false`).

Al quitar la pieza o cambiar de atuendo, la parte base vuelve a mostrarse.

Las mallas transformadas/pesadas se cachean por malla y parte base, así que
varios NPCs con el mismo atuendo solo pagan el cálculo una vez.

## Atuendo del médico

- Piezas: `assets/characters/atuendos/atuendo_servicio/tunica_servicio_01.glb`
  y `pantalon_servicio_01.glb`.
- Definición: `data/outfits/atuendo_servicio.tres`.
- `NpcDoctorSpawner` tiene una propiedad `outfit`; al invocar al médico le
  aplica ese conjunto. El componente ya está en `npc.tscn` como nodo `Outfit`.
- La túnica reemplaza `torso` y el pantalón reemplaza `piernas`.

## Crear otro atuendo

1. Exportá la pieza como `.glb` en la misma pose de descanso del cuerpo base.
   No hace falta que tenga skin: el sistema transfiere los pesos.
2. Creá un `OutfitPiece.tres` por pieza con `slot`, `base_part` y `scene`.
3. Creá un `OutfitDef.tres` con el array `pieces`.
4. Asignalo al `CharacterOutfit` del NPC (dejá `auto_apply` en `true`) o al
   export `outfit` del spawner que corresponda.

Slots/base parts actuales:

| Slot | Parte base | Ejemplo |
|---|---|---|
| `torso` | `torso` | Túnica |
| `legs` | `piernas` | Pantalón |

Se pueden agregar más piezas (`brazos`, `cabeza`, etc.) mientras el modelo base
tenga un `MeshInstance3D` con ese nombre dentro del esqueleto.

## Límites

- La transferencia de pesos es por vértice más cercano. Para ropa pegada al
  cuerpo funciona bien; prendas muy sueltas o con otra pose de descanso pueden
  necesitar ajustes manuales de pesos.
- La pieza debe estar orientada/escalada de forma coherente con el cuerpo. El
  sistema compensa la transformación del nodo de la malla, no una pose distinta.
- Solo se usa la primera superficie de la malla de cada pieza.

## Prueba

```powershell
Godot.exe --headless --path . --script res://tests/outfit_smoke_test.gd
```

Verifica que la túnica y el pantalón se equipan, que las partes base se ocultan,
que la ropa cuelga del esqueleto con `Skin` y huesos/pesos, que la escala queda
alineada con el cuerpo, y que al limpiar el atuendo las partes base vuelven.
