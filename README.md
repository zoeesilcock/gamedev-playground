# Gamedev Playground

Playground for exploring ways of making game development a more pleasurable experience.

![Playground screenshot](/screenshot.png)

## Editor
This approach aims to do as much of the editing directly in-game and offload to external editors for more complicated tasks.

Hovering over entities with the mouse will highlight them.

Double clicking on an entity will open it's sprite in Aseprite. This works particularly well together with hot reloading since you can double click a sprite, edit it, save it, and instantly see the result in-game.

### Keys
* Tab: Toggle pause.
* F: Toggle fullscreen.
* E: Toggle level editor.
* C: Toggle collider outlines.
* S: Save level.
* L: Load level.


## Hot reloading
Both the code and the assets automatically update in-game when modified. For code this is achieved by having the entire game code inside a shared library with a thin executable that takes care of reloading the shared library when it changes. For assets the executable lets the game know when assets have changed so that it can react to that in whatever way that makes sense, in this case it simply reloads the assets without interrupting the game.
