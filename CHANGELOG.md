# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html),
but until we reach 1.0 we are shifting the numbers so that we stay on 0.x.x.
The format is roughly speaking 0.MAJOR.MINOR.PATCH.


## [Unreleased]
### Added
* Added RPath entries to Linux/Mac builds so the executable can find libraries in the executable directory and in ./lib. This allows for packaging the executable with the libraries. On Windows it will follow the normal DLL search order, so it's easiest to place the libraries in the same directory as the executable.
* Added a module with utilities for dealing with the file system, to begin with it covers Flints own needs.
* [Breaking] Added a simpler way to integrate the Flint build into a project build.zig by providing a single function that returns both the module and executable. See the Template example for the new suggested setup.
### Changed
* [Breaking] Updated minimum Zig version to 0.16.0.
* Updated SDL to version 3.4.8.
* Changed where we look for the game library to make the executable more portable. The order is now: zig-out if internal build, same directory as executable, and finally a directory called "lib" in the same directory as the executable.
* The workaround to deal with building the game library while it is open on Windows is now only applied if the library is found in the dev directory (zig-out/bin), otherwise we skip it. This allows internal builds to be portable.
* Changed where we look for assets to make the executable more portable. Previously the asset paths only worked relative to the current working directory, now we have a fallback which looks relative to the executable directory if not found in the current directory.
* [Breaking] Refactored how Flint is integrated into the build.zig of projects that use it. Instead of importing the flint module and passing it to `linkSDL` we provide a function called `getFlintModule` which returns the module with SDL already linked.
* [Breaking] Adjusted the order of parameters for the `buildExecutable` build function to align with `getFlintModule`.
* Moved C translation of SDL and Imgui from `@cImport`/`@cDefine`/`@cInclude` in zig files to using `b.addTranslateC` in the build.zig file.
* [Breaking] Changed the naming of the init functions in game libraries to match the type of dependency that they will receive. So what was previously always `init` is now either `initMinimal`, `initFull2D` or `initFull3D`. This makes the library code clearer and inline with the GameLib documentation. It also removes the need to specify the dependency set used by the game in the `GameSettings`.
### Fixed
* Fixed installation of the SDL library artifact when using `linkSDL`. That function now needs the client_b so it can install SDL in the right location.
### Removed
* [Breaking] Removed the custom log function exposed at `GameLib.logFn` since it isn't needed anymore, the default log function works from dynamic libraries since zig 0.16.0. Remove any uses of it.


## [0.10.0]

### Added
* Renamed project to Flint to better reflect what the project has turned into.
* Added a CHANGELOG.md file.
* Added a quick start command that allows creating a new Flint project based on the template example using `zig build new -- ../my_new_project`.
* Added a sprite to the Template example.

### Changed
* Updated imgui to version 1.92.7.
* Updated SDL to version 3.4.2.
* Moved the memory usage window from the Diamonds example into the `internal` module.
* Changed the `linkSDL` and `buildExecutable` exposed build functions to take the install step which decides when to install artifacts like the executable and the SDL/Imgui libraries. If you want them to always be istalled you can pass `b.getInstallStep()` to get the default step that is triggered on all `zig build` invocations.
* The executable now checks for changes in the code and runs `zig build -Dlib_only` which allows hot reloading of code to work without running your own instance of `zig build -Dlib_only --watch`.
* Moved the function for opening sprites in Aseprite from the Diamonds example to the `aseprite` module.

### Fixed
* Fixed the Cube example so it works on AMD GPUs.
* Non-internal builds now work entirely without imgui.
* Fixed a memory leak in the Diamonds example.
* Fixed zero FPS in Diamonds example.
