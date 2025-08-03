# Gamedev Playground

Playground for exploring ways of making game development a more pleasurable experience.


## Examples

### [Diamonds](examples/diamonds/README.md)
This example is inspired by the classic game [Diamonds](https://en.wikipedia.org/wiki/Diamonds_\(video_game\)). The objective is to clear the screen of colored blocks without hitting spiky blocks. It uses the SDL3 Renderer API to render 2D sprites based on Aseprite files.
![Playground screenshot](examples/diamonds/screenshot.png)

### [Cube](examples/cube/README.md)
This example uses the SDL3 GPU API to render a cube.
![Playground screenshot](examples/cube/screenshot.png)


## Hot reloading
Both the code and the assets automatically update in-game when modified. For code this is achieved by having the entire game code inside a shared library with a thin executable that takes care of reloading the shared library when it changes. For assets the executable lets the game know when assets have changed so that it can react to that in whatever way that makes sense, in this case it simply reloads the assets without interrupting the game.

To automatically rebuild the shared library when you change the code you can leave the following command running in a separate terminal:
```
zig build -Dlib_only --watch
```


## Development
The project is built using the zig build system, use `zig build -h` for a list of options or look at the `build.zig` file for more details.

### Dear ImgGui
We build [Dear ImGui](https://github.com/ocornut/imgui) from source and use [Dear Bindings](https://github.com/dearimgui/dear_bindings) to generate C bindings which we then use directly from Zig. It is important to regenerate the bindings whenever updating the Dear ImGui dependency. This can be done by running the following build step:

```
zig build generate_imgui_bindings
```


## Usage
This project is morphing into a simple runtime for building games and applications using SDL and Zig. It is still in active development and doesn't expose options that are required to customize the resulting executable yet. See the examples for exact details on how to integrate it into your own projects.

### Build
Building the runtime executable in a different project works by importing the dependency in the `build.zig` file and using the `buildExecutable` function to create the runtime executable which can then be installed using `installArtifact`.

### Modules
* sdl - exposes the SDL C API.
* imgui - exposes the ImGui C API and backend integrations for the SDL3 Renderer and SDL3 GPU APIs.
* internal - exposes tools used to generate editors and tools for internal builds.
