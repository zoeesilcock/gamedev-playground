# Cube

This example uses the SDL3 GPU API to render a cube.

![Playground screenshot](screenshot.png)

## Controls
* P: Toggle pause.
* F: Toggle fullscreen.


## Integrated editor

### Controls
* F1: Cycle between FPS display modes (none, number, or number and graph).
* G: Toggle game state inspector.
* E: Cycle which screen space shader effect to use.


## Hot reloading
To automatically rebuild the shared library and the shaders when the underlying code changes, leave the following command running in a separate terminal:
```
zig build -Dlib_only --watch
```
