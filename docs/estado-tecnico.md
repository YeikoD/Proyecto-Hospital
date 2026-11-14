# Estado técnico del proyecto

| Campo | Valor |
| --- | --- |
| Proyecto | Proyecto Hospital (Godot 4.7) |
| Tipo | Auditoría técnica / valoración de calidad |
| Fecha | 2026-11-13 |
| Alcance | `scripts/`, `tests/`, `docs/`, `data/`, estructura del repo e historial |
| Estado del proyecto | 15 commits (2026-11-08 → 2026-11-13) |

Este documento registra una lectura crítica del nivel técnico del proyecto: qué
está bien resuelto, qué conviene vigilar y en qué orden atacar la deuda. No es
una guía de uso (eso está en los documentos de cada sistema); es una evaluación
de ingeniería para orientar las próximas decisiones.

---

## 1. Veredicto general

Para un proyecto de **5 días y 15 commits**, el nivel técnico es **alto**. No es
un prototipo improvisado: hay arquitectura pensada, contratos claros entre
sistemas, pruebas automáticas reales y documentación de ingeniería. Lo que más
se nota es que las decisiones están **justificadas**, no solo implementadas.

Nota orientativa: **8/10** como proyecto de gameplay en Godot. Lo que baja la
nota no es la calidad del código, sino un archivo que concentró demasiado y algo
de desorden de assets.

---

## 2. Qué está bien hecho

### 2.1 Separación de responsabilidades real

Cada sistema tiene un contrato explícito y una sola razón de cambio:

- `BuildGrid` es **modelo puro**: no sabe de render ni de input; solo convierte
  mundo ↔ celda ↔ borde. El overlay es un consumidor más.
- `SmartObject` aplica una regla de diseño documentada: *"el objeto declara, la
  IA decide; el objeto nunca mueve al NPC"*. Eso evita el acoplamiento típico
  entre mueble e IA.
- La IA está partida en capas: `NpcAgent` (movimiento/física), `NpcBrain`
  (necesidades → affordance → reserva → uso) y `NpcRouteFSM` (ruta/selector).
  El FSM **usa** al brain como acción, no lo reemplaza.
- `NpcBrain` deja escrito que la selección por utilidad se puede cambiar por
  GOAP/HTN sin tocar `SmartObject` ni el registry. Es pensar en el futuro, no en
  el commit del día.

### 2.2 Diseño data-driven

El catálogo (`BuildItem`), las affordances (`AffordanceDef`), los objetos
inteligentes (`SmartObjectDef`) y los atuendos (`OutfitDef`) son `Resource`
`.tres`. Agregar contenido no requiere tocar código. Es la forma correcta de
hacer esto en Godot.

### 2.3 Pruebas automáticas de verdad

20 pruebas headless con `extends SceneTree`, códigos de salida `0/1` y mensajes
de fallo legibles. Lo importante: **prueban comportamiento, no implementación**.
Por ejemplo, `tests/smart_object_smoke_test.gd` verifica que la cadera del NPC
quede sobre el asiento usando el hueso real del esqueleto, que el cuerpo no se
teletransporte y que el slot se libere. Eso es test de integración de calidad.

### 2.4 Programación defensiva y determinismo

Detalles que separan código amateur de código profesional:

- `SmartObject.reserve()` es atómico y valida dueño en `occupy`/`release`: dos
  NPC no pueden tomar el mismo slot.
- Timeouts de estancamiento (`travel_timeout`, `seek_stall_timeout`,
  `NPC_DETOUR_STALL_TIMEOUT`) en vez de esperas infinitas.
- Comentarios que explican el **porqué**, no el qué: "se reserva ANTES de
  caminar para que dos NPC no pierdan el viaje", "esperar un frame evita
  reentrar en el abort".
- Fallbacks sensatos: si no hay marker `Slot_0`, se calcula un slot implícito
  desde el AABB.

### 2.5 GDScript tipado y consistente

534 de 601 funciones tienen tipo de retorno (**89%**), uso de `StringName` para
identificadores, `Array[Vector3i]` tipados y setters con validación (`clampf`,
`maxi`). Nada de `get_node("../../..")` frágil: hay resolución automática con
fallback.

### 2.6 Shader de grilla bien resuelto

`scripts/systems/build/shaders/grid.gdshader` usa anti-aliasing por derivadas
(`fwidth`), guiones con máscara y desvanecido por distancia. No hay geometría por
celda: el overlay es una sola malla. Es la solución eficiente, no la obvia.

### 2.7 Documentación de nivel ingeniería

~3.300 líneas en `docs/`, con arquitectura, convenciones de coordenadas,
matemática, API pública, **límites conocidos** y extensiones previstas.
`sistema-grilla.md` explica hasta por qué el desempate usa `<=` para ser
determinista. Documentar los límites (no solo las virtudes) es señal de madurez.

### 2.8 Higiene de repositorio

`.gitignore` para `.godot/`, `.blend1` y `*.build.json`; `.gitattributes` con
`eol=lf`; `.gdignore` en `tools/actionforge` para que Godot no importe los
originales. Son detalles chicos que muchos proyectos no tienen.

---

## 3. Deuda técnica y riesgos

### 3.1 `build_controller.gd` es un god object

5.406 líneas y 228 funciones en un solo archivo. Tiene secciones bien marcadas
(objetos especiales, pinceles, recorte de paredes, guardado), pero eso ya son
**6 sistemas** que merecen archivos propios:

| Sección | Líneas aprox. | Extracción sugerida |
| --- | --- | --- |
| Objetos especiales | 1500–2300 | `special_object_builder.gd` |
| Arrastre de paredes | 2361–2548 | `wall_brush.gd` |
| Pincel de pisos | 2549–2764 | `floor_brush.gd` |
| Pincel de zonas | 2765–3616 | `zone_painter.gd` |
| Recorte de paredes | 3617–4227 | `wall_trim.gd` |
| Guardado / carga | 5146+ | `build_save.gd` |

Es el mayor riesgo técnico: se vuelve difícil de testear en aislamiento y de
mergear.

### 3.2 Ruido en la raíz del repositorio

Hay `animations/`, `characters/` y `character-tags/` fuera de la estructura
documentada, y duplican contenido de `tools/actionforge/` (mismo `.glb` de
4,6 MB dos veces). También aparecen `*.png.png` con doble extensión y
`humano.blend` suelto. El repositorio pesa **~401 MB**.

### 3.3 Deriva entre documentación y código

`sistema-grilla.md` todavía dice "Sin persistencia" y "Sin evitación entre NPCs",
pero ya existen `save_construction`/`load_construction` y `avoid_other_npcs`. El
README lista 6 tests; hay 20. No es grave, pero la documentación pierde valor si
no se actualiza con el código.

### 3.4 Sin runner ni CI

Las 20 pruebas se corren a mano, una por una, y cada archivo repite su propio
`_check`. Un script `run_tests.ps1` + helper compartido sería barato y de alto
retorno.

---

## 4. Recomendaciones priorizadas

| Prioridad | Acción | Motivo |
| --- | --- | --- |
| Alta | Extraer los 6 módulos de `build_controller.gd` | Reduce el mayor riesgo de mantenimiento |
| Alta | Runner único de tests (`run_tests.ps1`) | Hace visible el estado real de la suite |
| Media | Limpiar raíz y deduplicar assets | Baja el peso del repo y ordena la estructura |
| Media | Actualizar límites en `sistema-grilla.md` | Evita documentación engañosa |
| Baja | Helper `_check` compartido entre tests | Menos duplicación, mismos resultados |
| Baja | Revisar nombres `*.png.png` y `humano.blend` | Higiene de assets |

---

## 5. Cómo se hizo este análisis

Métricas usadas (medidas sobre el árbol de trabajo el 2026-11-13):

| Métrica | Valor |
| --- | --- |
| Archivos GDScript (sin addons) | 62 |
| Funciones en `scripts/` | 601 |
| Funciones con tipo de retorno | 534 (89%) |
| Archivo más grande | `build_controller.gd` (5.406 líneas, 228 funciones) |
| Pruebas headless | 20 |
| Líneas de documentación | ~3.334 |
| Archivos versionados | 888 |
| Peso del repositorio | ~401 MB |
| Commits | 15 (2026-11-08 → 2026-11-13) |

La valoración se apoya en lectura directa de `build_grid.gd`, `build_controller.gd`,
`npc_brain.gd`, `npc_route_fsm.gd`, `npc_agent.gd`, `smart_object.gd`,
`character_outfit.gd`, `grid.gdshader`, la suite de `tests/` y los documentos de
`docs/`.

---

## 6. Conclusión

El proyecto está **muy por encima de la media** para su edad. Lo mejor no es una
feature puntual: es el **criterio de diseño** — contratos claros, datos separados
de lógica, tests de comportamiento y documentación que admite límites. La deuda
principal es estructural (`build_controller.gd`) y de orden de assets, no de
calidad de código.

Si hay que preservar **una sola regla**, que sea esta: *"el objeto declara, la IA
decide"*. Es lo que hace que el sistema de Smart Objects escale sin enredarse.
