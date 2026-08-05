

# Flint
*Construye tu propio motor*

Bloques de construcción para el motor de juego que tu juego realmente necesita.


## Inicio rápido
Para poner tu propio proyecto en marcha rápidamente, puedes usar el generador de proyectos para crear uno nuevo basado en nuestra plantilla. La plantilla actual es de 2D y utiliza Aseprite para los activos, añadiremos más plantillas en el futuro a medida que estén disponibles.

```
git clone https://github.com/zoeesilcock/flint.git && cd flint

zig build new -- ../my_new_project

cd ../my_new_project && zig build run
```


## Demo
Una breve demo de algunas de las funciones más interesantes: ventanas de inspector generadas con `comptime` y recarga en caliente de código y activos:
![Flint demo](demo.gif)


## Uso
Para usar esto en tus propios proyectos, inclúyelo como una dependencia, intégralo en tu archivo `build.zig` y luego implementa una biblioteca que siga la API esperada por el ejecutable principal. Consulta la [documentación](https://zoeesilcock.github.io/flint/), y los ejemplos para más detalles.

### Añadir dependencia
```
zig fetch --save git+https://github.com/zoeesilcock/flint.git#v0.11.0
```

### Módulos expuestos
* sdl - expone la API C de SDL.
* imgui - expone la API C de ImGui y las integraciones de backend para los APIs de SDL3 Renderer y SDL3 GPU.
* internal - expone las herramientas utilizadas para generar editores y herramientas para compilaciones internas.
* aseprite - expone el importador de aseprite.

### Recarga en caliente
Tanto el código como los activos se actualizan automáticamente en el juego cuando se modifican. Para el código, esto se logra manteniendo todo el código del juego dentro de una biblioteca compartida junto con un ejecutable ligero que se encarga de recargar la biblioteca compartida cuando cambia. Cuando Flint detecta un cambio en el código, ejecuta `zig build -Dlib_only`. Al detectar un cambio en la biblioteca dinámica, carga la nueva, lo que la hace totalmente automatizada. Para los activos, el ejecutable avisa al juego cuando estos han cambiado para que pueda reaccionar de la manera que considere oportuna; los ejemplos recargan los activos, mostrando los cambios instantáneamente sin interrumpir el juego.

### Empaquetado
Compilar y empaquetar para la versión final es un tema amplio y funciona de manera diferente en cada plataforma. Flint aún no proporciona una forma automatizada de hacerlo, por lo que debe realizarse manualmente. El ejecutable busca la biblioteca del juego y los activos en varios lugares para ayudar a hacerlo portable.

#### Rutas de búsqueda de activos
Las rutas de los activos son relativas al directorio de trabajo actual por defecto; si no se encuentran allí, intentará buscarlas en relación con el directorio del ejecutable. Esto permite que los activos estén en el directorio raíz del proyecto durante el desarrollo y en el mismo directorio que el ejecutable para la versión final. Las compilaciones internas admiten la recarga en caliente de activos incluso cuando el ejecutable no está en el entorno de desarrollo, por lo que es posible compartir una compilación interna con un artista para que trabaje en los activos. En el futuro, podríamos considerar incrustar los activos en la biblioteca para las compilaciones de lanzamientolan

#### Rutas de búsqueda de bibliotecas
En modo de desarrollo, por defecto busca la biblioteca en zig-out (zig-out/bin en Windows y zig-out/lib en el resto de sistemas). Si no logra encontrar la biblioteca del juego, buscará en el mismo directorio que el ejecutable, así como en `./lib` en relación con el ejecutable. Esto permite utilizar las rutas de salida por defecto durante el desarrollo y luego tener un par de opciones al empaquetar para la versión final.

Para otras bibliotecas como SDL, el ejecutable busca en el mismo directorio que el ejecutable y en `./lib` en relación con el ejecutable. Windows es una excepción aquí, ya que tiene su propio [orden de búsqueda](https://learn.microsoft.com/en-us/windows/win32/dlls/dynamic-link-library-search-order) para las DLL. La forma más sencilla es colocar la biblioteca de SDL en el mismo directorio que el ejecutable.


## Ejemplos

### [Diamonds](examples/diamonds/README.md)
Este ejemplo está inspirado en el juego clásico [Diamonds](https://en.wikipedia.org/wiki/Diamonds_\(video_game\)). El objetivo es limpiar la pantalla de bloques de colores sin golpear bloques espinosos. Utiliza el API SDL3 Renderer para renderizar sprites 2D basados en archivos de Aseprite.
![Diamonds screenshot](examples/diamonds/screenshot.png)

### [Cube](examples/cube/README.md)
Este ejemplo utiliza el API SDL3 GPU para renderizar un cubo.
![Cube screenshot](examples/cube/screenshot.png)

### [Template](examples/template/README.md)
Este ejemplo tiene como objetivo una implementación mínima de un proyecto. Si quieres poner en marcha tu propio proyecto rápidamente, este es un buen lugar para empezar.


## Justificación
Crear juegos es difícil y consume mucho tiempo, y normalmente no es posible saber de antemano qué resultará divertido. Esto significa que la velocidad de iteración y la flexibilidad para experimentar son los factores más importantes para aumentar las probabilidades de encontrar la diversión.

Los motores de juegos mainstream son muy genéricos y rara vez están bien adaptados a ningún tipo de juego específico. La velocidad de iteración suele ser bastante baja, lo que nos saca del flujo cada vez que hacemos un cambio. La mayoría de las tareas incluyen flujos de trabajo manuales y repetitivos, dolorosos, que requieren navegar por interfaces de usuario complejas con el ratón.

Dado que cada juego es único, el mejor motor, editor y flujos de trabajo para un juego específico también son únicos. Crear un motor de juegos de propósito general es una tarea mayor que crear un juego, pero construir las partes del motor de juego necesarias para un juego específico es más manejable.

Este proyecto tiene como objetivo identificar e implementar las herramientas necesarias para crear motores de juegos a medida. No es un motor de juegos, sino un conjunto de herramientas e ideas que te ayudan a construir el motor adecuado para tu juego.

### Principios rectores
* **Centrado en el programador**\
    Prefierimos los datos en formato de texto o código para que puedan ser manipulados con editores de texto y herramientas de control de versiones estándar.
* **Pipeline de activos integrado**\
    La creación y el despliegue de activos deben estar integrados y optimizados para permitir iteraciones y experimentación rápidas.
* **Pocas dependencias**\
    Preferimos poseer el código que hace  nuestros juegos únicos.
    * Elegimos SDL3 por su amplio soporte de plataformas.
    * Elegimos Dear ImGui ya que es muy  ampliamente utilizado, pero podría reemplazarlo en el futuro por algo como [DVUI](https://github.com/david-vanderson/dvui) en el futuro.
* **Código abierto**\
    Preferimos la libertad de usar nuestras herramientas como queramos, sin reglas arbitrarias, tarifas de licencia, bloqueo de proveedor o estafas.


## Desarrollo
Este proyecto se construye utilizando el sistema de compilación de Zig; usa `zig build -h` para obtener una lista de opciones o consulta el archivo `build.zig` para más detalles.

### Depuración
Las configuraciones del depurador para VS Code están incluidas tanto en el proyecto principal como en los proyectos de ejemplo; te pedirá instalar la extensión requerida si no la tienes. Cuando uses VS Code, también es útil abrir el archivo de espacio de trabajo ubicado en `.vscode/flint.code-workspace` para obtener una visión general del proyecto completo.

### Documentación
La documentación se genera utilizando el sistema autodoc de Zig. Se generarse localmente o [verse en línea](https://zoeesilcock.github.io/flint/).

Para generarla y ejecutarla localmente:
```
zig build docs
python -m http.server -b 127.0.0.1 8000 -d zig-out/docs/
```
