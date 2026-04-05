# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html),
but until we reach 1.0 we are shifting the numbers so that we stay on 0.x.x.
The format is roughly speaking 0.MAJOR.MINOR.PATCH.

## [Unreleased]
### Added
### Changed
### Fixed
* Fixed installation of the SDL library artifact when using `linkSDL`. That function now needs the client_b so it can install SDL in the right location.

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
