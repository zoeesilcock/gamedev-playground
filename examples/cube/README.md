# Cube

This example uses the SDL3 GPU API to render a cube.

![Cube screenshot](screenshot.png)


## Controls
* P: Toggle pause.
* F: Toggle fullscreen.


## Integrated editor

### Controls
* F1: Cycle between FPS display modes (none, number, or number and graph).
* G: Toggle game state inspector.
* E: Cycle which screen space shader effect to use.


## Development
This project is built using the zig build system, use `zig build -h` for a list of options or look at the `build.zig` file for more details.

Examples
```
# Run game.
zig build run

# Build an optimized, release build of the game.
zig build -Doptimize=ReleaseFast -Dinternal=false
```
