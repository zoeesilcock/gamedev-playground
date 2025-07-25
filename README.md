# Gamedev Playground

Playground for exploring ways of making game development a more pleasurable experience.

![Playground screenshot](/screenshot.png)



## Hot reloading
Both the code and the assets automatically update in-game when modified. For code this is achieved by having the entire game code inside a shared library with a thin executable that takes care of reloading the shared library when it changes. For assets the executable lets the game know when assets have changed so that it can react to that in whatever way that makes sense, in this case it simply reloads the assets without interrupting the game.

To automatically rebuild the shared library when you change the code you can leave the following command running in a separate terminal:
```
zig build -Dlib_only --watch
```


## Build
The project is built using the zig build system, use `zig build -h` for a list of options or look at the `build.zig` file for more details.

### Dear ImgGui
We build [Dear ImGui](https://github.com/ocornut/imgui) from source and use [Dear Bindings](https://github.com/dearimgui/dear_bindings) to generate C bindings which we then use directly from Zig. It is important to regenerate the bindings whenever updating the Dear ImGui dependency. This can be done by running the following build step:

```
zig build generate_imgui_bindings
```


## Examples
The project contains a simple game inspired by the classic game [Diamonds](https://en.wikipedia.org/wiki/Diamonds_\(video_game\)). The objective is to clear the screen of colored blocks without hitting spiky blocks. The game isn't the main focus of the project, it's used to explore the process of building a simple game.

### Controls
* Left arrow: Move the ball to the left.
* Right arrow: Move the ball to the right.
* P: Toggle pause.
* F: Toggle fullscreen.


## Editor
This approach aims to do as much of the editing directly in-game and offload to external editors for more complicated tasks.

Hovering over entities with the mouse will highlight them.

Clicking on them will bring up the inspector which shows all components and their fields and allows editing them.

Double clicking on an entity will open it's sprite in Aseprite. This works particularly well together with hot reloading since you can double click a sprite, edit it, save it, and instantly see the result in-game.

### Controls
* C: Toggle collider outlines.
* F1: Cycle between FPS display modes (none, number, or number and graph).
* F2: Toggle the memory usage graph.
* G: Toggle game state inspector.
* E: Toggle level editor.
* S: Save level.
* L: Load level.
* Alt/Option + click: Grabs the color and/or type of the clicked element like an eye dropper tool.

