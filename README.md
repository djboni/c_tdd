# Host and Embedded Hardware Tests

Copyright (c) 2023 Djones A. Boni - MIT License

This is a proof of concept (and a starting point) of an Embedded C project with
multi-platform capability and testing. The project can be built on:

1. The host machine (the programmer's computer); and on
2. The embedded hardware (AVR ATmega2560 in this example).

We use [Unity](https://github.com/ThrowTheSwitch/Unity) as the C test framework.

[Zig](https://ziglang.org/) serves as a multi-platform build tool for
the host architecture, C compiler and test runner generator.

For the embedded hardware we use `avr-gcc` for building, `avrdude` to
flash the microcontrollers and `qemu-system-avr` for simulations.
As the embedded build tool we use a custom program called `./build`,
implemented in Zig.

Since the Unity test framework uses only the C language, it is not able to
automatically register the tests cases.
To overcome that, we automatically generate the test runners based on the
test files right before building the tests.
Unity already comes with a Ruby script that does a similar job automating
that process, however in this project we do that with Zig to have one less
dependency.

Instead of using the popular build tools, such as CMake, GNU Make, Ninja, etc,
we opted for creating our own build tool `./build`, which is an executable
that we build using Zig.
This custom build tool is portable, it uses an actual programming language
and makes us need less dependencies.
When using one of the popular build tools it becomes a dependency,
the portability of the build scripts is always a big hassle, and
it is annoying or even impossible to do certain things,
such as append some flags for a newer version of the compiler.

since they are not meant to be programming languages

## Adding Files to the Project

In the `build.zig` file there are three main variables that hold the
paths to the source code:

- `production_lib_files`: Production files that link to the executable and to the tests; and
- `test_lib_files`: Test files, from which the test runners are generated, and only link to the tests.
- `production_exe_files`: Production files that link only to the executable (these are not tested);
- `test_exe_files`: Test files that link only to the executable (these are not tests);

Additionally, you might need to add more include paths in `include_dirs`.

The build tool `./build`, which is compiled from the source `build.zig`,
use the variable above and define a few more related to the
embedded hardware support.

## Build the Bulid Tool `./build`

Build the `./build` program with Zig:

```sh
zig build-exe build.zig
```

Run `./build -h` to execute the build tool and check its help message:

```sh
./build -h
```

## Build and Run the Tests

Test in the host machine using Zig (test runner generation is automatic):

```sh
zig build test
```

Test simulating the embedded hardware using Qemu:

```sh
./build test_run
```

Test in the embedded hardware:

```sh
./build test_flash SERIAL=/dev/ttyACM0
```

## Build and Run the Project Executable

Run in the host machine using Zig:

```sh
zig build run -- 1 2
```

Run simulating the embedded hardware using Qemu
(use `Ctrl+A (release) + X` to quit from Qemu):

```sh
./build prod_run
```

Run in the embedded hardware:

```sh
./build prod_flash SERIAL=/dev/ttyACM0
```

## Zig Version

```console
$ zig version
0.13.0
```
