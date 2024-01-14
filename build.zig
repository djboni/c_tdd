// Build binaries for the host architecture and for an embedded hardware.
//
// Host: Common zig build
//
//     Build: zig build
//     Help:  zig build --help
//
// Embedded: Hand-made make substitute
//
//     Compile the tool: zig build-exe build.zig
//     Build:            ./build
//     Help:             ./build --help

//******************************************************************************
// Host Bulid Configuration
//******************************************************************************

const production_lib_files = [_][]const u8{
    "./src/add.c",
};
const test_lib_files = [_][]const u8{
    "./test/test_add.c",
};
const production_exe_files = [_][]const u8{
    "./src/prodmain.c",
};
const test_exe_files = [_][]const u8{
    "./test/testmain.c",
};

const host_cflags = [_][]const u8{
    "-Wall",
    "-Wextra",
    "-Wundef",
    "-Werror",
};

const include_dirs = [_][]const u8{
    "-I./include/",
    "-I./dep/unity/src/",
    "-I./dep/unity/extras/fixture/src/",
    "-I./dep/unity/extras/memory/src/",
    "-I./dep/unity/extras/bdd/src/",
};

const port_avr_files = [_][]const u8{
    "./dep/port/avr/port.c",
};
const test_unity_files = [_][]const u8{
    "./dep/unity/src/unity.c",
    "./dep/unity/extras/fixture/src/unity_fixture.c",
    "./dep/unity/extras/memory/src/unity_memory.c",
};

const test_runner = "./test/runner/testrunner.c";

const host_zigcc_cflags = host_cflags ++ [_][]const u8{
    "-std=c99",
    "-pedantic",
};

// Too little buffer_size can cause these errors:
// error.FileTooBig
// error.NoSpaceLeft
const buffer_size = 1048576; // 1 MiB

//******************************************************************************
// Host: zig build
//******************************************************************************

const std = @import("std");
const builtin = @import("builtin");
const unity_testrunner = @import("./dep/unity_testrunner.zig");
const nomake = @import("./dep/nomake.zig");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();
// This allocator leaks on purpose, we never call gpa_leak.deinit().
var gpa_leak = std.heap.GeneralPurposeAllocator(.{}){};
const alleakator = gpa_leak.allocator();

pub fn build(b: *std.Build) !void {
    defer if (gpa.deinit() == .leak) @panic("memory leak");

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const run_step = b.step("run", "Run the app");
    const test_step = b.step("test", "Run unit test");

    // Generate test runner (update files only if necessary)
    const test_runners_files = try unity_testrunner.generate_test_runner(&test_lib_files, test_runner, buffer_size, allocator);
    defer {
        for (test_runners_files) |file_name|
            allocator.free(file_name);
        allocator.free(test_runners_files);
    }

    // Static library with production code
    const libprod = b.addStaticLibrary(.{
        .name = "libprod",
        .root_source_file = null,
        .target = target,
        .optimize = optimize,
    });
    libprod.linkLibC();
    for (include_dirs) |dir| libprod.addIncludePath(.{ .path = dir[2..] });
    libprod.addCSourceFiles(&production_lib_files, &host_zigcc_cflags);

    // Static library with test code
    const libtest = b.addStaticLibrary(.{
        .name = "libtest",
        .root_source_file = null,
        .target = target,
        .optimize = optimize,
    });
    libtest.linkLibC();
    for (include_dirs) |dir| libtest.addIncludePath(.{ .path = dir[2..] });
    libtest.addCSourceFiles(&test_lib_files, &host_zigcc_cflags);
    libtest.addCSourceFiles(test_runners_files, &host_zigcc_cflags);

    // Static library with unity code
    const libunity = b.addStaticLibrary(.{
        .name = "libunity",
        .root_source_file = null,
        .target = target,
        .optimize = .ReleaseFast,
    });
    libunity.linkLibC();
    for (include_dirs) |dir| libunity.addIncludePath(.{ .path = dir[2..] });
    libunity.addCSourceFiles(&test_unity_files, &host_zigcc_cflags);

    // Test executable
    const exectest = b.addExecutable(.{
        .name = "test",
        .root_source_file = null,
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exectest);
    exectest.linkLibC();
    exectest.linkLibrary(libprod);
    exectest.linkLibrary(libtest);
    exectest.linkLibrary(libunity);
    for (include_dirs) |dir| exectest.addIncludePath(.{ .path = dir[2..] });
    exectest.addCSourceFiles(&test_exe_files, &host_zigcc_cflags);

    const run_test = b.addRunArtifact(exectest);
    test_step.dependOn(&run_test.step);
    run_test.addArgs(&[_][]const u8{"-s"});

    // Production executable
    const execprod = b.addExecutable(.{
        .name = "prod",
        .root_source_file = null,
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(execprod);
    execprod.linkLibC();
    for (include_dirs) |dir| execprod.addIncludePath(.{ .path = dir[2..] });
    execprod.linkLibrary(libprod);
    execprod.addCSourceFiles(&production_exe_files, &host_zigcc_cflags);

    if (target.os_tag == .windows or
        (target.os_tag == null and builtin.os.tag == .windows))
    {
        execprod.linkSystemLibrary("opengl32");
        execprod.linkSystemLibrary("gdi32");
        execprod.linkSystemLibrary("winmm");
    }

    const run_exe = b.addRunArtifact(execprod);
    run_exe.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_exe.addArgs(args);
    }
    run_step.dependOn(&run_exe.step);

    // Build tool executable
    const execbuildtool = b.addExecutable(.{
        .name = "build",
        .root_source_file = .{ .path = "build.zig" },
        .target = target,
        .optimize = optimize,
    });
    if (std.mem.eql(u8, std.fs.path.basename(b.install_path), "zig-out")) {
        // Install in the project root directory only when the install_path is
        // the default zig-out/ directory.
        // This command is equivalent to `b.installArtifact(execbuildtool)`
        // but installing in the parent of zig-out/ instead of in zig-out/bin/.
        b.getInstallStep().dependOn(&b.addInstallArtifact(execbuildtool, .{
            .dest_dir = .{ .override = .{ .custom = ".." } },
        }).step);
    }
}

//******************************************************************************
// Embedded: zig build-exe build.zig
//******************************************************************************

// Build configuration
var config = nomake.BuildConfig{
    .initialized = false,
    .allocator = allocator,
    .buffer_size = buffer_size,
    .build_dir = undefined,
    .arch = undefined,
    .cc = undefined,
    .cxx = undefined,
    .ld = undefined,
    .ar = undefined,
    .objcopy = undefined,
    .size = undefined,
    .cflags = undefined,
    .cxxflags = undefined,
    .ldflags = undefined,
    .include_dirs = undefined,
    .obj_extension = undefined,
    .lib_extension = undefined,
    .exec_extension = undefined,
};

fn config_avr() !void {
    config.initialized = true;
    // config.allocator
    // config.buffer_size
    config.build_dir = "./out/avr";
    config.arch = "avr";
    config.cc = &[_][]const u8{"avr-gcc"};
    config.cxx = &[_][]const u8{"avr-g++"};
    config.ld = &[_][]const u8{"avr-gcc"};
    config.ar = &[_][]const u8{"avr-ar"};
    config.objcopy = &[_][]const u8{"avr-objcopy"};
    config.size = &[_][]const u8{"avr-size"};
    // config.cflags below
    config.ldflags = &[_][]const u8{
        "-mmcu=atmega2560",
        "-Wl,--gc-sections",
    };
    config.include_dirs = &(include_dirs ++ [_][]const u8{
        "-I./dep/port/avr/",
    });
    config.obj_extension = ".o";
    config.lib_extension = ".a";
    config.exec_extension = ".elf";

    const default_cflags = [_][]const u8{
        "-mmcu=atmega2560",
        "-std=c99",
        "-pedantic",
        "-Os",
        "-g3",
        "-Wall",
        "-Wextra",
        "-Wundef",
        "-Werror",
        "-fdata-sections",
        "-ffunction-sections",
    };
    const default_cxxflags = [_][]const u8{
        "-mmcu=atmega2560",
        "-std=c++11",
        "-pedantic",
        "-Os",
        "-g3",
        "-Wall",
        "-Wextra",
        "-Wundef",
        "-Werror",
        "-fdata-sections",
        "-ffunction-sections",
    };

    // CFLAGS
    const cc_version = try nomake.getCCVersion(&config);
    defer config.allocator.free(cc_version);

    const parse = std.SemanticVersion.parse;
    const order = std.SemanticVersion.order;
    const parsed_version = parse(cc_version);
    std.debug.print("CC Version: {!} - \"{s}\"\n", .{ parse(cc_version), cc_version });

    if (order(try parsed_version, try parse("12.1.0")).compare(.gte)) {
        const extra_flags = [_][]const u8{
            "--param=min-pagesize=0",
            "-Wno-clobbered",
        };
        config.cflags = &(default_cflags ++ extra_flags);
        config.cxxflags = &(default_cxxflags ++ extra_flags);
    } else if (order(try parsed_version, try parse("11.2.0")).compare(.gte)) {
        const extra_flags = [_][]const u8{
            "-Wno-clobbered",
        };
        config.cflags = &(default_cflags ++ extra_flags);
        config.cxxflags = &(default_cxxflags ++ extra_flags);
    } else {
        config.cflags = &default_cflags;
        config.cxxflags = &default_cxxflags;
    }
}

fn config_zigcc() void {
    config.initialized = true;
    // config.allocator
    // config.buffer_size
    config.build_dir = "./out/zigcc";
    config.arch = "host";
    config.cc = &[_][]const u8{ "zig", "cc" };
    config.cxx = &[_][]const u8{ "zig", "c++" };
    config.ld = &[_][]const u8{ "zig", "c++" };
    config.ar = &[_][]const u8{ "zig", "ar" };
    config.objcopy = &[_][]const u8{ "zig", "objcopy" };
    config.size = &[_][]const u8{"size"};
    config.cflags = &[_][]const u8{
        "-std=c99",
        "-pedantic",
        "-Wall",
        "-Wextra",
        "-Wundef",
        "-Werror",
    };
    config.cxxflags = &[_][]const u8{
        "-std=c++11",
        "-pedantic",
        "-Wall",
        "-Wextra",
        "-Wundef",
        "-Werror",
    };
    config.ldflags = &[_][]const u8{};
    config.include_dirs = &include_dirs;
    config.obj_extension = switch (builtin.os.tag) {
        .windows => ".obj",
        else => ".o",
    };
    config.lib_extension = switch (builtin.os.tag) {
        .windows => ".lib",
        else => ".a",
    };
    config.exec_extension = switch (builtin.os.tag) {
        .windows => ".exe",
        else => "",
    };
}

fn config_gcc() void {
    config.initialized = true;
    // config.allocator
    // config.buffer_size
    config.build_dir = "./out/gcc";
    config.arch = "host";
    config.cc = &[_][]const u8{"gcc"};
    config.cxx = &[_][]const u8{"g++"};
    config.ld = &[_][]const u8{"gcc"};
    config.ar = &[_][]const u8{"ar"};
    config.objcopy = &[_][]const u8{"objcopy"};
    config.size = &[_][]const u8{"size"};
    config.cflags = &[_][]const u8{
        "-std=c99",
        "-pedantic",
        "-Wall",
        "-Wextra",
        "-Wundef",
        "-Werror",
    };
    config.cxxflags = &[_][]const u8{
        "-std=c++11",
        "-pedantic",
        "-Wall",
        "-Wextra",
        "-Wundef",
        "-Werror",
    };
    config.ldflags = &[_][]const u8{};
    config.include_dirs = &include_dirs;
    config.obj_extension = switch (builtin.os.tag) {
        .windows => ".obj",
        else => ".o",
    };
    config.lib_extension = switch (builtin.os.tag) {
        .windows => ".lib",
        else => ".a",
    };
    config.exec_extension = switch (builtin.os.tag) {
        .windows => ".exe",
        else => "",
    };
}

fn config_clang() void {
    config.initialized = true;
    // config.allocator
    // config.buffer_size
    config.build_dir = "./out/clang";
    config.arch = "host";
    config.cc = &[_][]const u8{"clang"};
    config.cxx = &[_][]const u8{"clang++"};
    config.ld = &[_][]const u8{"clang"};
    config.ar = &[_][]const u8{"llvm-ar"};
    config.objcopy = &[_][]const u8{"llvm-objcopy"};
    config.size = &[_][]const u8{"llvm-size"};
    config.cflags = &[_][]const u8{
        "-std=c99",
        "-pedantic",
        "-Wall",
        "-Wextra",
        "-Wundef",
        "-Werror",
    };
    config.cxxflags = &[_][]const u8{
        "-std=c++11",
        "-pedantic",
        "-Wall",
        "-Wextra",
        "-Wundef",
        "-Werror",
    };
    config.ldflags = &[_][]const u8{};
    config.include_dirs = &include_dirs;
    config.obj_extension = switch (builtin.os.tag) {
        .windows => ".obj",
        else => ".o",
    };
    config.lib_extension = switch (builtin.os.tag) {
        .windows => ".lib",
        else => ".a",
    };
    config.exec_extension = switch (builtin.os.tag) {
        .windows => ".exe",
        else => "",
    };
}

// CLI Options
// nomake: var verbosity: u8 = 1;
var force_rebuild: bool = false;
var serial_port: []const u8 = switch (builtin.os.tag) {
    .windows => "COM0",
    else => "/dev/ttyACM0",
};

pub fn main() !void {
    const time_begin_ms = std.time.milliTimestamp();
    defer if (gpa.deinit() == .leak) @panic("memory leak");

    // Get command line arguments
    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);
    const program = argv[0];

    // Options
    var n: usize = 1;
    var num_targets: usize = argv.len - 1;
    while (n < argv.len) : (n += 1) {
        const option = argv[n];
        if (std.mem.eql(u8, option, "-h") or std.mem.eql(u8, option, "--help")) {
            show_help_message_and_exit(program, null);
        } else if (std.mem.eql(u8, option, "--rebuild")) {
            force_rebuild = true;
        } else if (std.mem.eql(u8, option, "--no-rebuild")) {
            force_rebuild = false;
        } else if (std.mem.eql(u8, option, "-v") or std.mem.eql(u8, option, "--verbose")) {
            nomake.verbosity +|= 1;
        } else if (std.mem.eql(u8, option, "--no-verbose")) {
            nomake.verbosity = 0;
        } else if (std.mem.eql(u8, option, "--avr")) {
            try config_avr();
        } else if (std.mem.eql(u8, option, "--zigcc")) {
            config_zigcc();
        } else if (std.mem.eql(u8, option, "--gcc")) {
            config_gcc();
        } else if (std.mem.eql(u8, option, "--clang")) {
            config_clang();
        } else if (std.mem.startsWith(u8, option, "BUILD_DIR=")) {
            config.build_dir = option[10..];
        } else if (std.mem.startsWith(u8, option, "CC=")) {
            config.cc = try nomake.splitBySpaces(alleakator, option[3..]);
        } else if (std.mem.startsWith(u8, option, "CXX=")) {
            config.cc = try nomake.splitBySpaces(alleakator, option[4..]);
        } else if (std.mem.startsWith(u8, option, "LD=")) {
            config.ld = try nomake.splitBySpaces(alleakator, option[3..]);
        } else if (std.mem.startsWith(u8, option, "AR=")) {
            config.ar = try nomake.splitBySpaces(alleakator, option[3..]);
        } else if (std.mem.startsWith(u8, option, "CFLAGS=")) {
            config.cflags = try nomake.splitBySpaces(alleakator, option[7..]);
        } else if (std.mem.startsWith(u8, option, "CXXFLAGS=")) {
            config.cflags = try nomake.splitBySpaces(alleakator, option[9..]);
        } else if (std.mem.startsWith(u8, option, "LDFLAGS=")) {
            config.cflags = try nomake.splitBySpaces(alleakator, option[8..]);
        } else if (std.mem.startsWith(u8, option, "INCLUDE_DIRS=")) {
            config.cflags = try nomake.splitBySpaces(alleakator, option[13..]);
        } else if (std.mem.startsWith(u8, option, "EXEC_EXTENSION=")) {
            config.exec_extension = option[15..];
        } else if (std.mem.startsWith(u8, option, "SERIAL=")) {
            serial_port = option[7..];
        } else if (std.mem.startsWith(u8, option, "-")) {
            // Unknown option
            const error_message = try std.fmt.allocPrint(allocator, "{s}: ERROR: Unknown option \"{s}\"", .{ program, option });
            defer allocator.free(error_message);
            show_help_message_and_exit(program, error_message);
        } else {
            continue;
        }
        num_targets -= 1;
    }

    if (nomake.verbosity >= nomake.verb_debug) {
        std.debug.print("DEBUG: force_rebuild={}\n", .{force_rebuild});
        std.debug.print("DEBUG: verbosity={}\n", .{nomake.verbosity});
    }

    // Rebuild
    try nomake.rebuild(allocator, argv, force_rebuild, "./build", &[_][]const u8{
        "./build.zig",
        "./dep/nomake.zig",
        "./dep/unity_testrunner.zig",
    });

    // Default build configuration
    if (!config.initialized) {
        try config_avr();
    }

    // Targets
    n = 1;
    while (n < argv.len) : (n += 1) {
        const option = argv[n];
        if (std.mem.eql(u8, option, "--rebuild") or std.mem.eql(u8, option, "--no-rebuild") or
            std.mem.eql(u8, option, "-v") or std.mem.eql(u8, option, "--verbose") or std.mem.eql(u8, option, "--no-verbose") or
            std.mem.eql(u8, option, "--avr") or
            std.mem.eql(u8, option, "--zigcc") or
            std.mem.eql(u8, option, "--gcc") or
            std.mem.eql(u8, option, "--clang") or
            std.mem.startsWith(u8, option, "BUILD_DIR=") or
            std.mem.startsWith(u8, option, "CC=") or
            std.mem.startsWith(u8, option, "CXX=") or
            std.mem.startsWith(u8, option, "LD=") or
            std.mem.startsWith(u8, option, "AR=") or
            std.mem.startsWith(u8, option, "CFLAGS=") or
            std.mem.startsWith(u8, option, "CXXFLAGS=") or
            std.mem.startsWith(u8, option, "LDFLAGS=") or
            std.mem.startsWith(u8, option, "INCLUDE_DIRS=") or
            std.mem.startsWith(u8, option, "EXEC_EXTENSION=") or
            std.mem.startsWith(u8, option, "SERIAL="))
        {
            // Ignore
        } else if (std.mem.eql(u8, option, "clean")) {
            try target_clean();
        } else if (std.mem.eql(u8, option, "all")) {
            try target_all();
        } else if (std.mem.eql(u8, option, "prod")) {
            const prod_exec = try target_prod();
            defer allocator.free(prod_exec);
        } else if (std.mem.eql(u8, option, "test")) {
            const test_exec = try target_test();
            defer allocator.free(test_exec);
        } else if (std.mem.eql(u8, "prod_run", option)) {
            try run_exec_prod();
        } else if (std.mem.eql(u8, "test_run", option)) {
            try run_exec_test();
        } else if (std.mem.eql(u8, "prod_flash", option)) {
            try flash_prod();
        } else if (std.mem.eql(u8, "test_flash", option)) {
            try flash_test();
        } else {
            // Unknown target
            const error_message = try std.fmt.allocPrint(allocator, "{s}: ERROR: Unknown target \"{s}\"", .{ program, option });
            defer allocator.free(error_message);
            show_help_message_and_exit(program, error_message);
        }
    }

    // No target: default build
    if (num_targets == 0) {
        try target_all();
    }

    if (nomake.verbosity >= nomake.verb_debug) {
        if (nomake.included_files_cache != null) {
            std.debug.print("DEBUG: IncludedFilesCache: {}\n", .{nomake.included_files_cache.?.stats});
            //nomake.included_files_cache.?.print();
        }
        if (nomake.dir_exists_cache != null) {
            std.debug.print("DEBUG: DirExistsCache: {}\n", .{nomake.dir_exists_cache.?.stats});
            //nomake.dir_exists_cache.?.print();
        }
        if (nomake.mtime_cache != null) {
            std.debug.print("DEBUG: MtimeCache: {}\n", .{nomake.mtime_cache.?.stats});
            //nomake.mtime_cache.?.print();
        }
    }
    if (nomake.verbosity >= nomake.verb_info) {
        const time_end_ms = std.time.milliTimestamp();
        const diff_ms = (time_end_ms - time_begin_ms);
        std.debug.print("INFO: Took {} ms\n", .{diff_ms});
    }
}

fn show_help_message_and_exit(program: []const u8, error_message: ?[]const u8) void {
    std.debug.print(
        \\Usage: {s} [-h] [OPTIONS] TARGETS...
        \\
    , .{program});
    if (error_message) |message| {
        std.debug.print("{s}\n", .{message});
        std.os.exit(1);
    }
    std.debug.print(
        \\
        \\TARGETS:
        \\    all         default build (default)
        \\    clean       clean the build directory
        \\    prod        build the production binary
        \\    test        build the test binary
        \\    prod_run    run the production binary
        \\                - avr: simulates with Qemu
        \\                - host: run normally
        \\    test_run    run the test binary
        \\                - avr: simulates with Qemu
        \\                - host: run normally
        \\    prod_flash  flash the production binary
        \\                - avr: uses the serial port
        \\    test_flash  flash the test binary
        \\                - avr: uses the serial port
        \\
        \\OPTIONS:
        \\    BUILD_DIR=dir             change build directory
        \\    CC=cc                     change C compiler
        \\    CXX=c++                   change C++ compiler
        \\    LD=ld                     change linker
        \\    AR=ar                     change archiver
        \\    CFLAGS=cflags             change C compiler flags
        \\    CXXFLAGS=cxxflags         change C++ compiler flags
        \\    LDFLAGS=ldflags           change linker flags
        \\    INCLUDE_DIRS="dir1 dir2"  change include directories
        \\    EXEC_EXTENSION=.ext       change executable extension
        \\    SERIAL=port               change serial port to flash AVR ATmega2560
        \\                              (defaults to /dev/ttyACM0 on Linux and
        \\                              COM0 on Windows)
        \\    --[no-]rebuild            force rebuild of the {s} executable
        \\    -v --[no-]verbose         increase verbosity (can be used multiple times)
        \\    --avr                     use the AVR compiler for ATmega2560
        \\    --zigcc                   use the host Zig C compiler
        \\    --gcc                     use the host GCC compiler
        \\    --clang                   use the host CLANG compiler
        \\
    , .{program});
    std.os.exit(1);
}

fn target_clean() !void {
    const target = "clean";
    if (nomake.verbosity >= nomake.verb_info)
        std.debug.print("INFO: Target {s}\n", .{target});

    try nomake.deleteDirectory(config.build_dir);

    // Clear caches
    if (nomake.included_files_cache != null) nomake.included_files_cache.?.clearAll();
    if (nomake.dir_exists_cache != null) nomake.dir_exists_cache.?.clearAll();
    if (nomake.mtime_cache != null) nomake.mtime_cache.?.clearAll();

    if (nomake.verbosity >= nomake.verb_info)
        std.debug.print("INFO: Finished target {s}\n", .{target});
}

fn target_all() !void {
    const target = "all";
    if (nomake.verbosity >= nomake.verb_info)
        std.debug.print("INFO: Target {s}\n", .{target});

    const prod_exec = try target_prod();
    defer allocator.free(prod_exec);
    const test_exec = try target_test();
    defer allocator.free(test_exec);

    if (nomake.verbosity >= nomake.verb_info)
        std.debug.print("INFO: Finished target {s}\n", .{target});
}

fn target_libprod() ![]const u8 {
    const target = "libprod";
    if (nomake.verbosity >= nomake.verb_info)
        std.debug.print("INFO: Target {s}\n", .{target});

    const sources = production_lib_files;
    const dependencies = .{};

    const result = nomake.buildLibrary(config, target, &sources, dependencies);

    if (nomake.verbosity >= nomake.verb_info)
        std.debug.print("INFO: Finished target {s}\n", .{target});

    return result;
}

fn target_libtest() ![]const u8 {
    const target = "libtest";
    if (nomake.verbosity >= nomake.verb_info)
        std.debug.print("INFO: Target {s}\n", .{target});

    const sources = test_lib_files;
    const dependencies = .{};

    // Generate test runner (update files only if necessary)
    const test_runners_files = try unity_testrunner.generate_test_runner(&sources, test_runner, buffer_size, allocator);
    defer {
        for (test_runners_files) |file_name|
            allocator.free(file_name);
        allocator.free(test_runners_files);
    }

    var all_sources = try nomake.CmdLine.init(allocator);
    defer all_sources.deinit();

    for (sources) |src|
        try all_sources.add(src);
    for (test_runners_files) |src|
        try all_sources.add(src);

    const result = nomake.buildLibrary(config, target, all_sources.args, dependencies);

    if (nomake.verbosity >= nomake.verb_info)
        std.debug.print("INFO: Finished target {s}\n", .{target});

    return result;
}

fn target_libunity() ![]const u8 {
    const target = "libunity";
    if (nomake.verbosity >= nomake.verb_info)
        std.debug.print("INFO: Target {s}\n", .{target});

    const sources = test_unity_files;
    const dependencies = .{};

    const result = nomake.buildLibrary(config, target, &sources, dependencies);

    if (nomake.verbosity >= nomake.verb_info)
        std.debug.print("INFO: Finished target {s}\n", .{target});

    return result;
}

fn target_libport_avr() ![]const u8 {
    const target = "libport_avr";
    if (nomake.verbosity >= nomake.verb_info)
        std.debug.print("INFO: Target {s}\n", .{target});

    const sources = port_avr_files;
    const dependencies = .{};

    const result = nomake.buildLibrary(config, target, &sources, dependencies);

    if (nomake.verbosity >= nomake.verb_info)
        std.debug.print("INFO: Finished target {s}\n", .{target});

    return result;
}

fn target_prod() ![]const u8 {
    const target = "prod";
    if (nomake.verbosity >= nomake.verb_info)
        std.debug.print("INFO: Target {s}\n", .{target});

    var objs = try nomake.CmdLine.init(allocator);
    defer {
        for (objs.args) |obj|
            allocator.free(obj);
        objs.deinit();
    }

    const sources = production_exe_files;
    const dependencies = .{};

    for (sources) |src|
        try objs.add(try nomake.buildSource(config, src, dependencies));
    try objs.add(try target_libprod());
    if (std.mem.eql(u8, config.arch, "avr"))
        try objs.add(try target_libport_avr());

    const exe = try nomake.buildExecutable(config, target, objs.args, .{});
    errdefer allocator.free(exe);

    if (std.mem.eql(u8, config.arch, "avr")) {
        var cmd = try nomake.CmdLine.init(allocator);
        defer cmd.deinit();

        const hex = try std.mem.concat(allocator, u8, &[_][]const u8{ exe, ".hex" });
        defer allocator.free(hex);

        if (nomake.needsRebuild(hex, exe)) {
            cmd.clean();
            try cmd.add(config.objcopy);
            try cmd.add(.{ "-Oihex", exe, hex });
            try cmd.executeSync();

            cmd.clean();
            try cmd.add(config.size);
            try cmd.add(exe);
            try cmd.executeSync();
        }
    }

    if (nomake.verbosity >= nomake.verb_info)
        std.debug.print("INFO: Finished target {s}\n", .{target});

    return exe;
}

fn target_test() ![]const u8 {
    const target = "test";
    if (nomake.verbosity >= nomake.verb_info)
        std.debug.print("INFO: Target {s}\n", .{target});

    var objs = try nomake.CmdLine.init(allocator);
    defer {
        for (objs.args) |obj|
            allocator.free(obj);
        objs.deinit();
    }

    const sources = test_exe_files;
    const dependencies = .{};

    for (sources) |src|
        try objs.add(try nomake.buildSource(config, src, dependencies));
    try objs.add(try target_libtest());
    try objs.add(try target_libprod());
    try objs.add(try target_libunity());
    if (std.mem.eql(u8, config.arch, "avr"))
        try objs.add(try target_libport_avr());

    const exe = try nomake.buildExecutable(config, target, objs.args, .{});
    errdefer allocator.free(exe);

    if (std.mem.eql(u8, config.arch, "avr")) {
        var cmd = try nomake.CmdLine.init(allocator);
        defer cmd.deinit();

        const hex = try std.mem.concat(allocator, u8, &[_][]const u8{ exe, ".hex" });
        defer allocator.free(hex);

        if (nomake.needsRebuild(hex, exe)) {
            cmd.clean();
            try cmd.add(config.objcopy);
            try cmd.add(.{ "-Oihex", exe, hex });
            try cmd.executeSync();

            cmd.clean();
            try cmd.add(config.size);
            try cmd.add(exe);
            try cmd.executeSync();
        }
    }

    if (nomake.verbosity >= nomake.verb_info)
        std.debug.print("INFO: Finished target {s}\n", .{target});

    return exe;
}

fn run_exec_prod() !void {
    const target = "prod_run";
    if (nomake.verbosity >= nomake.verb_info)
        std.debug.print("INFO: Target {s}\n", .{target});

    const exe = try target_prod();
    defer allocator.free(exe);

    var cmd = try nomake.CmdLine.init(allocator);
    defer cmd.deinit();

    if (std.mem.eql(u8, config.arch, "avr")) {
        cmd.clean();
        try cmd.add(.{ "qemu-system-avr", "-machine", "mega2560" });
        try cmd.add(.{ "-nographic", "-serial", "mon:stdio" });
        try cmd.add(.{ "-bios", exe });
    } else if (std.mem.eql(u8, config.arch, "host")) {
        cmd.clean();
        try cmd.add(.{ exe, "1", "2" });
    } else {
        std.debug.print("ERROR: Running \"{s}\" is not implemented for the architecture \"{s}\"\n", .{ exe, config.arch });
        std.os.exit(1);
    }

    // Qemu commands:
    // Ctrl+A (release) + X
    //
    // Qemu options:
    // -serial mon:stdio
    // -serial tcp:127.0.0.1:6000
    // -serial tcp:127.0.0.1:6000,server=on,wait=on
    // -s -S -- avr-gdb build/main_avr.elf -ex 'target remote :1234'

    if (false) {
        try cmd.executeSync();
    } else {
        const output = try cmd.executeSyncGetOutputTimeout(0.1);
        defer output.deinit();
        std.debug.print("{s}\n", .{output.stdout});
    }

    if (nomake.verbosity >= nomake.verb_info)
        std.debug.print("INFO: Finished target {s}\n", .{target});
}

fn run_exec_test() !void {
    const target = "test_run";
    if (nomake.verbosity >= nomake.verb_info)
        std.debug.print("INFO: Target {s}\n", .{target});

    const exe = try target_test();
    defer allocator.free(exe);

    var cmd = try nomake.CmdLine.init(allocator);
    defer cmd.deinit();

    if (std.mem.eql(u8, config.arch, "avr")) {
        cmd.clean();
        try cmd.add(.{ "qemu-system-avr", "-machine", "mega2560" });
        try cmd.add(.{ "-nographic", "-serial", "mon:stdio" });
        try cmd.add(.{ "-bios", exe });
    } else if (std.mem.eql(u8, config.arch, "host")) {
        cmd.clean();
        try cmd.add(.{ exe, "-s" });
    } else {
        std.debug.print("ERROR: Simulation of \"{s}\" is not implemented for the architecture \"{s}\"\n", .{ exe, config.arch });
        std.os.exit(1);
    }

    const output = try cmd.executeSyncGetOutputTimeout(0.1);
    defer output.deinit();
    std.debug.print("{s}\n", .{output.stdout});

    const OK = if (std.mem.eql(u8, config.arch, "host") and builtin.os.tag == .windows) "\r\nOK\r\n" else "\nOK\n";
    const FAIL = if (std.mem.eql(u8, config.arch, "host") and builtin.os.tag == .windows) "\r\nFAIL\r\n" else "\nFAIL\n";
    if (std.mem.indexOf(u8, output.stdout, OK) == null or std.mem.indexOf(u8, output.stdout, FAIL) != null) {
        std.debug.print("ERROR: Test failed!\n", .{});
        std.os.exit(1);
    } else {
        std.debug.print("INFO: Test passed!\n", .{});
    }

    if (nomake.verbosity >= nomake.verb_info)
        std.debug.print("INFO: Finished target {s}\n", .{target});
}

fn flash_prod() !void {
    const target = "prod_flash";
    if (nomake.verbosity >= nomake.verb_info)
        std.debug.print("INFO: Target {s}\n", .{target});

    const exe = try target_prod();
    defer allocator.free(exe);

    const flash_w_hex = try std.mem.concat(allocator, u8, &[_][]const u8{ "flash:w:", exe, ".hex" });
    defer allocator.free(flash_w_hex);

    var cmd = try nomake.CmdLine.init(allocator);
    defer cmd.deinit();

    if (std.mem.eql(u8, config.arch, "avr")) {
        cmd.clean();
        try cmd.add(.{ "avrdude", "-p", "atmega2560", "-c", "stk500v2" });
        try cmd.add(.{ "-P", serial_port, "-b", "115200", "-D", "-V" });
        try cmd.add(.{ "-U", flash_w_hex });
        try cmd.executeSync();
    } else {
        std.debug.print("ERROR: Flashing \"{s}\" is not implemented for the architecture \"{s}\"\n", .{ exe, config.arch });
        std.os.exit(1);
    }

    if (nomake.verbosity >= nomake.verb_info)
        std.debug.print("INFO: Finished target {s}\n", .{target});
}

fn flash_test() !void {
    const target = "test_flash";
    if (nomake.verbosity >= nomake.verb_info)
        std.debug.print("INFO: Target {s}\n", .{target});

    const exe = try target_test();
    defer allocator.free(exe);

    const flash_w_hex = try std.mem.concat(allocator, u8, &[_][]const u8{ "flash:w:", exe, ".hex" });
    defer allocator.free(flash_w_hex);

    var cmd = try nomake.CmdLine.init(allocator);
    defer cmd.deinit();

    if (std.mem.eql(u8, config.arch, "avr")) {
        cmd.clean();
        try cmd.add(.{ "avrdude", "-p", "atmega2560", "-c", "stk500v2" });
        try cmd.add(.{ "-P", serial_port, "-b", "115200", "-D", "-V" });
        try cmd.add(.{ "-U", flash_w_hex });
        try cmd.executeSync();
    } else {
        std.debug.print("ERROR: Flashing \"{s}\" is not implemented for the architecture \"{s}\"\n", .{ exe, config.arch });
        std.os.exit(1);
    }

    if (nomake.verbosity >= nomake.verb_info)
        std.debug.print("INFO: Finished target {s}\n", .{target});
}
