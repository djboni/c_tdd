const std = @import("std");
const unity_testrunner = @import("./test/unity_testrunner.zig");

const production_exe_files = [_][]const u8{
    "./src/prodmain.c",
};
const production_lib_files = [_][]const u8{
    "./src/add.c",
};
const test_files = [_][]const u8{
    "./test/test_add.c",
};

const test_runner = "./test/testrunner.c";

// error: FileTooBig
// error: NoSpaceLeft
const buffer_size = 1048576; // 1 MiB

const cflags_production = [_][]const u8{
    "-std=c90",
    "-pedantic",
    "-Wall",
    "-Wextra",
    "-Wundef",
    "-Werror",
};

const cflags_testing = cflags_production ++ [_][]const u8{
    "-DUNITY_FIXTURE_NO_EXTRAS",
    "-Wno-long-long",
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const run_step = b.step("run", "Run the app");
    const test_step = b.step("test", "Run unit test");

    // Allocator used by the test runner generator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) @panic("memory leak");
    const allocator = gpa.allocator();

    // Generate test runner (update files only if necessary)
    const test_runners_files = try unity_testrunner.generate_test_runner(&test_files, test_runner, buffer_size, allocator);
    defer {
        for (test_runners_files) |file_name|
            allocator.free(file_name);
        allocator.free(test_runners_files);
    }

    // Test the test runner generator
    const test_runner_generator_step = b.step("test_tools", "Run test runner generator unit test");
    const test_runner_generatror = b.addTest(.{
        .root_source_file = .{ .path = "./test/unity_testrunner.zig" },
        .target = target,
        .optimize = optimize,
    });
    const run_test_runner_generatror = b.addRunArtifact(test_runner_generatror);
    test_runner_generator_step.dependOn(&run_test_runner_generatror.step);

    // Static library for production
    const lib = b.addStaticLibrary(.{
        .name = "add",
        .root_source_file = null,
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);
    lib.linkLibC();
    lib.addIncludePath(std.build.LazyPath{ .path = "./include/" });
    lib.addCSourceFiles(&production_lib_files, &cflags_production);

    // Executable for production
    const exe = b.addExecutable(.{
        .name = "exec_add",
        .root_source_file = null,
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);
    lib.linkLibC();
    exe.addIncludePath(std.build.LazyPath{ .path = "./include/" });
    exe.linkLibrary(lib);
    exe.addCSourceFiles(&production_exe_files, &cflags_production);

    const run_exe = b.addRunArtifact(exe);
    run_exe.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_exe.addArgs(args);
    }
    run_step.dependOn(&run_exe.step);

    // Unity static library
    const unity = b.addStaticLibrary(.{
        .name = "unity",
        .root_source_file = null,
        .target = target,
        .optimize = optimize,
    });
    unity.linkLibC();
    unity.addIncludePath(std.build.LazyPath{ .path = "./dep/unity/src/" });
    unity.addIncludePath(std.build.LazyPath{ .path = "./dep/unity/extras/fixture/src/" });
    unity.addCSourceFiles(&[_][]const u8{
        "./dep/unity/src/unity.c",
        "./dep/unity/extras/fixture/src/unity_fixture.c",
    }, &cflags_testing);

    // Test executable
    const test_lib = b.addExecutable(.{
        .name = "test_add",
        .root_source_file = null,
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(test_lib);
    test_lib.linkLibC();
    test_lib.addIncludePath(std.build.LazyPath{ .path = "./include/" });
    test_lib.linkLibrary(lib);
    test_lib.addIncludePath(std.build.LazyPath{ .path = "./dep/unity/src/" });
    test_lib.addIncludePath(std.build.LazyPath{ .path = "./dep/unity/extras/fixture/src/" });
    test_lib.linkLibrary(unity);
    test_lib.addCSourceFiles(&test_files, &cflags_testing);
    test_lib.addCSourceFiles(test_runners_files, &cflags_testing);
    test_lib.addCSourceFiles(&[_][]const u8{
        "./test/testmain.c",
    }, &cflags_testing);

    const run_test = b.addRunArtifact(test_lib);
    test_step.dependOn(&run_test.step);
    run_test.addArgs(&[_][]const u8{"-s"});
}
