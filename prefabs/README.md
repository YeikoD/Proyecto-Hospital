# Prefabs

Escenas reutilizables del proyecto, separadas de los modelos y las texturas.

- `build/`: piezas base del sistema de construcción (piso y pared). Son los
  prefabs por defecto de `BuildController`.
- `items/`: prefabs de objetos colocables desde el menú de construcción. Pueden
  tener raíz `SmartObject` con markers `Slot_N`, `POI_N` y `Approach_N` para que
  los NPC interactúen con ellos.

Los modelos (`.glb`, `.blend`) y sus texturas viven en `assets/models/...`.
Los datos del catálogo (`.tres`) viven en `data/build_items/...`.
