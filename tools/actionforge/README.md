# Biblioteca de ActionForge

Esta carpeta contiene la biblioteca fuente de [ActionForge](https://actionforge.app):
los JSON de animaciones, personajes y etiquetas, junto con los modelos originales.

- **No se usa en tiempo de ejecución.** Los recursos que el juego carga están en
  `assets/animations/` y `assets/characters/`.
- Tiene un archivo `.gdignore`, así que Godot no importa esta carpeta ni genera
  archivos `.import` para sus modelos.
- Si volvés a exportar desde ActionForge, copiá los `.glb`/`.png` resultantes a
  `assets/animations/` o `assets/characters/` según corresponda.

`ActionForge library.txt` es el marcador que usa el sitio para reconocer esta
carpeta como biblioteca.
