# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html),
but until we reach 1.0 we are shifting the numbers so that we stay on 0.x.x.
The format is roughly speaking 0.MAJOR.MINOR.PATCH.

## [Unreleased]

### Added
* Renamed project to Flint to better reflect what the project has turned into.
* Added a CHANGELOG.md file.
* Added a quick start command that allows creating a new Flint project based on the template example using `zig build new -- ../my_new_project`.

### Changed
* Changed the `linkSDL` and `buildExecutable` exposed build functions to take the install step which decides when to install artifacts like the executable and the SDL/Imgui libraries. If you want them to always be istalled you can pass `b.getInstallStep()` to get the default step that is triggered on all `zig build` invocations.
