# Gamedev Playground

Playground for exploring ways of making game development a more pleasurable experience.

![Playground screenshot](/screenshot.png)

## Editor
This approach aims to do as much of the editing directly in-game and offload to external editors for more complicated tasks.

Hovering over entities with the mouse will highlight them.

Clicking on them will bring up the inspector which shows all components and their fields and allows editing them.

Double clicking on an entity will open it's sprite in Aseprite. This works particularly well together with hot reloading since you can double click a sprite, edit it, save it, and instantly see the result in-game.

### Keys
* P: Toggle pause.
* F: Toggle fullscreen.
* C: Toggle collider outlines.
* F1: Switch between FPS display modes (none, number, or number and graph).
* F2: Toggle the memory usage graph.
* E: Toggle editor.
* Alt/Option: Clicking on an entity grabs the color and/or type of the clicked element.
* S: Save level.
* L: Load level.


## Hot reloading
Both the code and the assets automatically update in-game when modified. For code this is achieved by having the entire game code inside a shared library with a thin executable that takes care of reloading the shared library when it changes. For assets the executable lets the game know when assets have changed so that it can react to that in whatever way that makes sense, in this case it simply reloads the assets without interrupting the game.


## Build
We build [Dear ImGui](https://github.com/ocornut/imgui) from source and use [Dear Bindings](https://github.com/dearimgui/dear_bindings) to generate C bindings which we then use directly from Zig. It is important to regenerate the bindings whenever updating the Dear ImGui dependency. This can be done by running the following build step:

```
zig build generate_imgui_bindings
```
