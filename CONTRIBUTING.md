# Contributing

Keep in mind that while the project is in its infancy, it can be hard to know what types of contributions may be accepted. The [README](README.md) contains some information about the rationale and guiding principles which helps give an idea of what direction we are aiming for. If you want to contribute it is best to create an issue to discuss it first to avoid wasted work.

## Structure
The project provides an executable that can be built from other projects and some examples of how this executable can be used. The executable provides a basis for the code and asset hot reloading which relies on the game code being in a shared library. Apart from the executable the main project also provides a set of tools that are meant to help users piece together their own game engine. The main project can be built but not run by itself, the examples provide a way to test changes.

## Examples
Examples are partly there to show how the project can be used, but also meant to be used as real world examples to help guide what should be implemented in the main executable and set of tools provided.

## Rules
* Follow the [style guide](STYLEGUIDE.md).
* Any AI usage must be disclosed in the PR. AI usage is not disallowed, but for review purposes we need to know the type of AI tools used and to what extent they where used.
* We aim to have as few dependencies as possible, adding new ones should come with clear justification.
* When using C libraries they should be included directly rather than using a separate project that provides Zig bindings since that introduces an extra dependency.
