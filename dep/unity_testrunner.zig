// Copyright (c) 2023 Djones A. Boni - MIT License

// Generate test runners for Unity test files (test suites).
//
// Test:    zig test unity_testrunner.zig
// Build:   zig build-exe -OReleaseSafe -static unity_testrunner.zig
// Execute: ./unity_testrunner -o testrunner.c test_suite1.c test_suite2.c
//
// For every test file, a single test runner is produced. For example,
// if the test file is called test/test_suite1.c, the generated test runner
// file will be named test/runner/test_suite1_runner.c.
//
// An additional test runner file is created in test/runner/testrunner.c.
// This file contains the function `run_all_tests()`, which calls each
// of the individual test runners for the test files.
// To change this default output file path, use the option `-o OUTPUT_FILE.c`.
//
// Here's what your main file (ex: testmain.c) should look like:
//
// ```c
// #include "unity_fixture.h"
//
// void run_all_tests(void);
//
// int main(int argc, const char **argv) {
//     return UnityMain(argc, argv, run_all_tests);
// }
// ```
//
// And here's what your test files (ex: test_suite1.c) should look like:
//
// ```c
// #include "unity_fixture.h"
//
// TEST_GROUP(suite1);
//
// TEST_SETUP(suite1) {
// }
//
// TEST_TEAR_DOWN(suite1) {
// }
//
// TEST(suite1, this_test_fails) {
//     FAIL("Fail this test");
// }
// ```

const std = @import("std");
const nomake = @import("./nomake.zig");

/// Main function for standalone executable
pub fn main() !void {
    // Allocator used by the test runner generator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) @panic("memory leak");
    const allocator = gpa.allocator();

    // error: FileTooBig
    // error: NoSpaceLeft
    var buffer_size: usize = 1048576; // 1 MiB

    var test_runner: []const u8 = "./test/runner/testrunner.c";
    var test_files = try allocator.alloc([]const u8, 0);
    defer allocator.free(test_files);

    // Get command line arguments
    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    // Process command line arguments
    const program = argv[0];
    var n: usize = 1;
    while (n < argv.len) : (n += 1) {
        const option = argv[n];
        if (std.mem.eql(u8, "-h", option)) {
            // Help (-h)
            std.debug.print(
                \\Usage: {s} [-h] [-b BUFFER_SIZE] [-o OUTPUT_FILE] INPUT_FILES...
                \\
                \\Generate test runners for Unity test files.
                \\
                \\Options:
                \\-h              show this help message.
                \\-b BUFFER_SIZE  set allocated buffer size (defaults to 1048576 bytes).
                \\-o OUTPUT_FILE  additional output file (defaults to ./test/runner/testrunner.c).
                \\
            , .{program});
            std.os.exit(1);
        } else if (std.mem.eql(u8, "-b", option)) {
            // Allocated buffer size (-b)
            if (n + 1 < argv.len) {
                n += 1;
                const buf = argv[n];
                buffer_size = try std.fmt.parseUnsigned(usize, buf, 10);
            } else {
                std.debug.print("{s}: ERROR: Missing allocated buffer size after \"{s}\"\n", .{ program, option });
                std.os.exit(1);
            }
        } else if (std.mem.eql(u8, "-o", option)) {
            // Output file (-o)
            if (n + 1 < argv.len) {
                n += 1;
                test_runner = argv[n];
            } else {
                std.debug.print("{s}: ERROR: Missing output file after \"{s}\"\n", .{ program, option });
                std.os.exit(1);
            }
        } else if (std.mem.startsWith(u8, option, "-")) {
            // Unknown option
            std.debug.print("{s}: ERROR: Unknown option \"{s}\"\n", .{ program, option });
            std.os.exit(1);
        } else {
            // Input file
            test_files = try allocator.realloc(test_files, test_files.len + 1);
            test_files[test_files.len - 1] = option;
        }
    }

    // Generate test runner (update files only if necessary)
    const test_runners_files = try generate_test_runner(test_files, test_runner, buffer_size, allocator);
    defer {
        for (test_runners_files) |file_name|
            allocator.free(file_name);
        allocator.free(test_runners_files);
    }
}

/// Generate a runner for a test file. Returns the content of the generated
/// file. The caller must free the returned value.
fn generate_test_file_runner(test_file_code: []const u8, all_test_groups: *std.StringArrayHashMap(void), buffer_size: usize, allocator: std.mem.Allocator) ![]const u8 {
    var tokenizer = nomake.Tokenizer{ .data = test_file_code, .position = 0 };

    const State = enum {
        NOTHING,
        // TEST_GROUP(test_grup)
        TESTGROUP_LPAREN,
        TESTGROUP_GRUP,
        TESTGROUP_RPAREN,
        // TEST(test_grup,test_case)
        // IGNORE_TEST(test_grup,test_case)
        TEST_LPAREN,
        TEST_GRUP,
        TEST_COMMA,
        TEST_CASE,
        TEST_RPAREN,
    };

    var state: State = .NOTHING;
    var test_group: []const u8 = undefined;
    var test_case: []const u8 = undefined;

    var size: usize = 0;
    const generated_runner = try allocator.alloc(u8, buffer_size);
    defer allocator.free(generated_runner);
    var test_case_created: bool = false;

    size += (try std.fmt.bufPrint(generated_runner[size..], "/* AUTOGENERATED FILE. DO NOT EDIT. */\n", .{})).len;

    while (tokenizer.next()) |token| {
        // Special treatment for comments and preprocessor
        if (std.mem.startsWith(u8, token, "//")) {
            // C++ style comment (//)
            continue;
        } else if (std.mem.startsWith(u8, token, "/*")) {
            // C style comment (/* */)
            continue;
        } else if (std.mem.startsWith(u8, token, "#") and std.mem.endsWith(u8, token, "include")) {
            // #include
            const include_file = tokenizer.skip_to_eol();
            size += (try std.fmt.bufPrint(generated_runner[size..], "{s}{s}\n", .{ token, include_file })).len;
            continue;
        } else if (std.mem.startsWith(u8, token, "#") and
            (std.mem.endsWith(u8, token, "define") or std.mem.endsWith(u8, token, "undef")))
        {
            // #define #undef
            const expression = tokenizer.skip_to_end_of_pound_expression();
            size += (try std.fmt.bufPrint(generated_runner[size..], "{s}{s}\n", .{ token, expression })).len;
            continue;
        } else if (std.mem.startsWith(u8, token, "#") and
            (std.mem.endsWith(u8, token, "if") or std.mem.endsWith(u8, token, "elif") or
            std.mem.endsWith(u8, token, "ifdef") or std.mem.endsWith(u8, token, "ifndef") or
            std.mem.endsWith(u8, token, "else") or std.mem.endsWith(u8, token, "endif")))
        {
            // #if #elif #ifdef #ifndef #else #endif
            const expression = tokenizer.skip_to_end_of_pound_expression();
            size += (try std.fmt.bufPrint(generated_runner[size..], "{s}{s}\n", .{ token, expression })).len;
            continue;
        }

        switch (state) {
            .NOTHING => {
                if (std.mem.eql(u8, "TEST", token) or std.mem.eql(u8, "IGNORE_TEST", token)) {
                    state = .TEST_LPAREN;
                } else if (std.mem.eql(u8, "TEST_GROUP", token)) {
                    state = .TESTGROUP_LPAREN;
                } else {
                    state = .NOTHING;
                }
            },

            // TEST_GROUP(test_grup)
            .TESTGROUP_LPAREN => {
                if (std.mem.eql(u8, "(", token)) {
                    state = .TESTGROUP_GRUP;
                } else {
                    state = .NOTHING;
                }
            },
            .TESTGROUP_GRUP => {
                test_group = token;
                state = .TESTGROUP_RPAREN;
            },
            .TESTGROUP_RPAREN => {
                if (std.mem.eql(u8, ")", token)) {
                    if (test_case_created) {
                        test_case_created = false;
                        size += (try std.fmt.bufPrint(generated_runner[size..], "}}\n", .{})).len;
                    }
                    if (!test_case_created) {
                        test_case_created = true;
                        size += (try std.fmt.bufPrint(generated_runner[size..], "\n", .{})).len;
                        // TODO: Allow test case order randomization
                        size += (try std.fmt.bufPrint(generated_runner[size..], "TEST_GROUP_RUNNER({s}) {{\n", .{test_group})).len;
                        try add_test_group(all_test_groups, test_group);
                    }
                    state = .NOTHING;
                } else {
                    state = .NOTHING;
                }
            },

            // TEST(test_grup,test_case)
            // IGNORE_TEST(test_grup,test_case)
            .TEST_LPAREN => {
                if (std.mem.eql(u8, "(", token)) {
                    state = .TEST_GRUP;
                } else {
                    state = .NOTHING;
                }
            },
            .TEST_GRUP => {
                test_group = token;
                state = .TEST_COMMA;
            },
            .TEST_COMMA => {
                if (std.mem.eql(u8, ",", token)) {
                    state = .TEST_CASE;
                } else {
                    state = .NOTHING;
                }
            },
            .TEST_CASE => {
                test_case = token;
                state = .TEST_RPAREN;
            },
            .TEST_RPAREN => {
                if (std.mem.eql(u8, ")", token)) {
                    size += (try std.fmt.bufPrint(generated_runner[size..], "    RUN_TEST_CASE({s}, {s}); /* TEST_{s}_{s}_ */\n", .{ test_group, test_case, test_group, test_case })).len;
                    state = .NOTHING;
                } else {
                    state = .NOTHING;
                }
            },
        }
    }

    if (test_case_created) {
        // test_case_created = false;
        size += (try std.fmt.bufPrint(generated_runner[size..], "}}\n", .{})).len;
    }

    // Return a new allocation with only the necessary size
    return allocator.dupe(u8, generated_runner[0..size]);
}

/// Generate a main runner for the test groups. Returns the content of the
/// generated file. The caller must free the returned value.
fn generate_main_runner(all_test_groups: *std.StringArrayHashMap(void), buffer_size: usize, allocator: std.mem.Allocator) ![]const u8 {
    var size: usize = 0;
    const generated_runner = try allocator.alloc(u8, buffer_size);
    defer allocator.free(generated_runner);

    size += (try std.fmt.bufPrint(generated_runner[size..], "/* AUTOGENERATED FILE. DO NOT EDIT. */\n", .{})).len;
    size += (try std.fmt.bufPrint(generated_runner[size..], "#include \"unity_fixture.h\"\n", .{})).len;
    size += (try std.fmt.bufPrint(generated_runner[size..], "\n", .{})).len;
    size += (try std.fmt.bufPrint(generated_runner[size..], "void run_all_tests(void) {{\n", .{})).len;
    for (all_test_groups.keys()) |test_group| {
        // TODO: Allow test group order randomization
        size += (try std.fmt.bufPrint(generated_runner[size..], "    RUN_TEST_GROUP({s});\n", .{test_group})).len;
    }
    size += (try std.fmt.bufPrint(generated_runner[size..], "}}\n", .{})).len;

    // Return a new allocation with only the necessary size
    return allocator.dupe(u8, generated_runner[0..size]);
}

/// Add a test group to the set all_test_groups.
/// The caller must free the allocated memory added to the set.
fn add_test_group(all_test_groups: *std.StringArrayHashMap(void), group: []const u8) !void {
    const test_group_null = all_test_groups.get(group);
    if (test_group_null == null)
        try all_test_groups.put(try all_test_groups.allocator.dupe(u8, group), {});
}

/// Generate test runners for the test files and a main test runner for
/// the test groups. Returns an allocated list with the allocated names of
/// the files created. The caller must free the returned value and its elements.
pub fn generate_test_runner(file_names: []const []const u8, runner_file_name: []const u8, buffer_size: usize, allocator: std.mem.Allocator) ![]const []const u8 {
    var test_runner_file_count: usize = 0;
    const test_runners_files = try allocator.alloc([]const u8, file_names.len + 1);
    errdefer {
        // On error free the file names of the test runners
        var i: usize = 0;
        while (i < test_runner_file_count) : (i += 1)
            allocator.free(test_runners_files[test_runner_file_count]);
        allocator.free(test_runners_files);
    }

    var all_test_groups = std.StringArrayHashMap(void).init(allocator);
    defer {
        // Free the test groups
        for (all_test_groups.keys()) |test_group|
            all_test_groups.allocator.free(test_group);
        all_test_groups.deinit();
    }

    // Generate the test file runners
    for (file_names) |file_name| {
        const test_file_code = try nomake.readEntireFile(file_name, buffer_size, allocator);
        defer allocator.free(test_file_code);

        const generated_runner = try generate_test_file_runner(test_file_code, &all_test_groups, buffer_size, allocator);
        defer allocator.free(generated_runner);

        const runner_name = try std.mem.concat(allocator, u8, &.{
            std.fs.path.stem(file_name),
            "_runner",
            std.fs.path.extension(file_name),
        });
        defer allocator.free(runner_name);
        const runner_path = try std.fs.path.join(allocator, &.{
            std.fs.path.dirname(file_name) orelse ".",
            "runner",
            runner_name,
        });
        defer allocator.free(runner_path);

        try nomake.writeEntireFileIfChanged(runner_path, generated_runner, buffer_size, allocator);
        test_runners_files[test_runner_file_count] = try allocator.dupe(u8, runner_path);
        test_runner_file_count += 1;
    }

    // Generate the main test runner
    const generated_main_runner = try generate_main_runner(&all_test_groups, buffer_size, allocator);
    defer allocator.free(generated_main_runner);

    try nomake.writeEntireFileIfChanged(runner_file_name, generated_main_runner, buffer_size, allocator);
    test_runners_files[test_runner_file_count] = try allocator.dupe(u8, runner_file_name);
    // test_runner_file_count += 1;

    return test_runners_files;
}

test "tokens hello world" {
    const data =
        \\#include <stdio.h>
        \\int main(int argc, char **argv) {
        \\    printf("Hello World!\n");
        \\    return 0;
        \\}
    ;
    const expected_tokens = [_][]const u8{
        "#include",            "<stdio.h>",
        "int",                 "main",
        "(",                   "int",
        "argc",                ",",
        "char",                "*",
        "*",                   "argv",
        ")",                   "{",
        "printf",              "(",
        "\"Hello World!\\n\"", ")",
        ";",                   "return",
        "0",                   ";",
        "}",
    };
    var tokenizer = nomake.Tokenizer{ .data = data, .position = 0 };
    var i: usize = 0;
    while (tokenizer.next()) |token| {
        //std.debug.print("\"{s}\" == \"{s}\"\n", .{expected_tokens[i], token});
        try std.testing.expectEqualStrings(expected_tokens[i], token);
        i += 1;
    }
}

test "tokens hello world 2" {
    const data =
        \\#include <stdio.h>
        \\int main(int argc,char**argv){printf("Hello World!\n");return 0;}
    ;
    const expected_tokens = [_][]const u8{
        "#include",            "<stdio.h>",
        "int",                 "main",
        "(",                   "int",
        "argc",                ",",
        "char",                "*",
        "*",                   "argv",
        ")",                   "{",
        "printf",              "(",
        "\"Hello World!\\n\"", ")",
        ";",                   "return",
        "0",                   ";",
        "}",
    };
    var tokenizer = nomake.Tokenizer{ .data = data, .position = 0 };
    var i: usize = 0;
    while (tokenizer.next()) |token| {
        //std.debug.print("\"{s}\" == \"{s}\"\n", .{expected_tokens[i], token});
        try std.testing.expectEqualStrings(expected_tokens[i], token);
        i += 1;
    }
}

test "tokens of string with escaped characters" {
    const data =
        \\"test1\n""test2\n\\""test3\n"
    ;
    const expected_tokens = [_][]const u8{
        "\"test1\\n\"",
        "\"test2\\n\\\\\"",
        "\"test3\\n\"",
    };
    var tokenizer = nomake.Tokenizer{ .data = data, .position = 0 };
    var i: usize = 0;
    while (tokenizer.next()) |token| {
        //std.debug.print("\"{s}\" == \"{s}\"\n", .{expected_tokens[i], token});
        try std.testing.expectEqualStrings(expected_tokens[i], token);
        i += 1;
    }
}

test "tokens c++ style comment" {
    const data =
        \\int//comment
        \\float
    ;
    const expected_tokens = [_][]const u8{ "int", "//comment", "float" };
    var tokenizer = nomake.Tokenizer{ .data = data, .position = 0 };
    var i: usize = 0;
    while (tokenizer.next()) |token| {
        //std.debug.print("\"{s}\" == \"{s}\"\n", .{expected_tokens[i], token});
        try std.testing.expectEqualStrings(expected_tokens[i], token);
        i += 1;
    }
}

test "tokens c style comment" {
    const data =
        \\int/*comment_start
        \\comment_end*/float
    ;
    const expected_tokens = [_][]const u8{ "int", "/*comment_start\ncomment_end*/", "float" };
    var tokenizer = nomake.Tokenizer{ .data = data, .position = 0 };
    var i: usize = 0;
    while (tokenizer.next()) |token| {
        //std.debug.print("\"{s}\" == \"{s}\"\n", .{expected_tokens[i], token});
        try std.testing.expectEqualStrings(expected_tokens[i], token);
        i += 1;
    }
}

test "tokens #if 0 comment" {
    const data =
        \\int
        \\#if 0
        \\comment
        \\#endif
        \\float
    ;
    const expected_tokens = [_][]const u8{ "int", "#if", "0", "comment", "#endif", "float" };
    var tokenizer = nomake.Tokenizer{ .data = data, .position = 0 };
    var i: usize = 0;
    while (tokenizer.next()) |token| {
        //std.debug.print("\"{s}\" == \"{s}\"\n", .{expected_tokens[i], token});
        try std.testing.expectEqualStrings(expected_tokens[i], token);
        i += 1;
    }
}

test "tokens # include with spaces" {
    const data =
        \\# include <stdio.h>
        \\#  include <lib.h>
    ;
    const expected_tokens = [_][]const u8{ "# include", "<stdio.h>", "#  include", "<lib.h>" };
    var tokenizer = nomake.Tokenizer{ .data = data, .position = 0 };
    var i: usize = 0;
    while (tokenizer.next()) |token| {
        //std.debug.print("\"{s}\" == \"{s}\"\n", .{expected_tokens[i], token});
        try std.testing.expectEqualStrings(expected_tokens[i], token);
        i += 1;
    }
}

test "generate one test case" {
    const test_file_code =
        \\#include "unity_fixture.h"
        \\TEST_GROUP(test_group);
        \\TEST_SETUP(test_group) {}
        \\TEST_TEAR_DOWN(test_group) {}
        \\TEST(test_group, the_test_case) {
        \\}
        \\
    ;
    const expected_test_runner =
        \\/* AUTOGENERATED FILE. DO NOT EDIT. */
        \\#include "unity_fixture.h"
        \\
        \\TEST_GROUP_RUNNER(test_group) {
        \\    RUN_TEST_CASE(test_group, the_test_case); /* TEST_test_group_the_test_case_ */
        \\}
        \\
    ;

    const buffer_size: usize = 1024;
    var allocator = std.testing.allocator;
    var all_test_groups = std.StringArrayHashMap(void).init(allocator);
    defer {
        // Free the test groups
        for (all_test_groups.keys()) |test_group|
            all_test_groups.allocator.free(test_group);
        all_test_groups.deinit();
    }

    const generated_runner = try generate_test_file_runner(test_file_code, &all_test_groups, buffer_size, allocator);
    defer allocator.free(generated_runner);

    try std.testing.expectEqualStrings(expected_test_runner, generated_runner);
}

test "generate two test cases" {
    const test_file_code =
        \\#include "unity_fixture.h"
        \\TEST_GROUP(another_group);
        \\TEST_SETUP(another_group) {}
        \\TEST_TEAR_DOWN(another_group) {}
        \\TEST(another_group, the_test_case1) {
        \\}
        \\TEST(another_group, the_test_case2) {
        \\}
        \\
    ;
    const expected_test_runner =
        \\/* AUTOGENERATED FILE. DO NOT EDIT. */
        \\#include "unity_fixture.h"
        \\
        \\TEST_GROUP_RUNNER(another_group) {
        \\    RUN_TEST_CASE(another_group, the_test_case1); /* TEST_another_group_the_test_case1_ */
        \\    RUN_TEST_CASE(another_group, the_test_case2); /* TEST_another_group_the_test_case2_ */
        \\}
        \\
    ;

    const buffer_size: usize = 1024;
    var allocator = std.testing.allocator;
    var all_test_groups = std.StringArrayHashMap(void).init(allocator);
    defer {
        // Free the test groups
        for (all_test_groups.keys()) |test_group|
            all_test_groups.allocator.free(test_group);
        all_test_groups.deinit();
    }

    const generated_runner = try generate_test_file_runner(test_file_code, &all_test_groups, buffer_size, allocator);
    defer allocator.free(generated_runner);

    try std.testing.expectEqualStrings(expected_test_runner, generated_runner);
}

test "generate no test case" {
    const test_file_code =
        \\#include "unity_fixture.h"
        \\TEST_GROUP(test_group);
        \\TEST_SETUP(test_group) {}
        \\TEST_TEAR_DOWN(test_group) {}
        \\
    ;
    const expected_test_runner =
        \\/* AUTOGENERATED FILE. DO NOT EDIT. */
        \\#include "unity_fixture.h"
        \\
        \\TEST_GROUP_RUNNER(test_group) {
        \\}
        \\
    ;

    const buffer_size: usize = 1024;
    var allocator = std.testing.allocator;
    var all_test_groups = std.StringArrayHashMap(void).init(allocator);
    defer {
        // Free the test groups
        for (all_test_groups.keys()) |test_group|
            all_test_groups.allocator.free(test_group);
        all_test_groups.deinit();
    }

    const generated_runner = try generate_test_file_runner(test_file_code, &all_test_groups, buffer_size, allocator);
    defer allocator.free(generated_runner);

    try std.testing.expectEqualStrings(expected_test_runner, generated_runner);
}

test "generate two test groups" {
    const test_file_code =
        \\#include "unity_fixture.h"
        \\
        \\TEST_GROUP(test_group);
        \\TEST_SETUP(test_group) {}
        \\TEST_TEAR_DOWN(test_group) {}
        \\TEST(test_group, the_test_case) {
        \\}
        \\
        \\TEST_GROUP(another_group);
        \\TEST_SETUP(another_group) {}
        \\TEST_TEAR_DOWN(another_group) {}
        \\TEST(another_group, the_test_case1) {
        \\}
        \\TEST(another_group, the_test_case2) {
        \\}
        \\
    ;
    const expected_test_runner =
        \\/* AUTOGENERATED FILE. DO NOT EDIT. */
        \\#include "unity_fixture.h"
        \\
        \\TEST_GROUP_RUNNER(test_group) {
        \\    RUN_TEST_CASE(test_group, the_test_case); /* TEST_test_group_the_test_case_ */
        \\}
        \\
        \\TEST_GROUP_RUNNER(another_group) {
        \\    RUN_TEST_CASE(another_group, the_test_case1); /* TEST_another_group_the_test_case1_ */
        \\    RUN_TEST_CASE(another_group, the_test_case2); /* TEST_another_group_the_test_case2_ */
        \\}
        \\
    ;

    const buffer_size: usize = 1024;
    var allocator = std.testing.allocator;
    var all_test_groups = std.StringArrayHashMap(void).init(allocator);
    defer {
        // Free the test groups
        for (all_test_groups.keys()) |test_group|
            all_test_groups.allocator.free(test_group);
        all_test_groups.deinit();
    }

    const generated_runner = try generate_test_file_runner(test_file_code, &all_test_groups, buffer_size, allocator);
    defer allocator.free(generated_runner);

    try std.testing.expectEqualStrings(expected_test_runner, generated_runner);
}

test "generate no test group" {
    const test_file_code =
        \\#include "unity_fixture.h"
        \\
    ;
    const expected_test_runner =
        \\/* AUTOGENERATED FILE. DO NOT EDIT. */
        \\#include "unity_fixture.h"
        \\
    ;

    const buffer_size: usize = 1024;
    var allocator = std.testing.allocator;
    var all_test_groups = std.StringArrayHashMap(void).init(allocator);
    defer {
        // Free the test groups
        for (all_test_groups.keys()) |test_group|
            all_test_groups.allocator.free(test_group);
        all_test_groups.deinit();
    }

    const generated_runner = try generate_test_file_runner(test_file_code, &all_test_groups, buffer_size, allocator);
    defer allocator.free(generated_runner);

    try std.testing.expectEqualStrings(expected_test_runner, generated_runner);
}

test "generate empty test file" {
    const test_file_code = "";
    const expected_test_runner =
        \\/* AUTOGENERATED FILE. DO NOT EDIT. */
        \\
    ;

    const buffer_size: usize = 1024;
    var allocator = std.testing.allocator;
    var all_test_groups = std.StringArrayHashMap(void).init(allocator);
    defer {
        // Free the test groups
        for (all_test_groups.keys()) |test_group|
            all_test_groups.allocator.free(test_group);
        all_test_groups.deinit();
    }

    const generated_runner = try generate_test_file_runner(test_file_code, &all_test_groups, buffer_size, allocator);
    defer allocator.free(generated_runner);

    try std.testing.expectEqualStrings(expected_test_runner, generated_runner);
}

test "generate test case commented c-style" {
    const test_file_code =
        \\#include "unity_fixture.h"
        \\TEST_GROUP(test_group);
        \\TEST_SETUP(test_group) {}
        \\TEST_TEAR_DOWN(test_group) {}
        \\/*TEST(test_group, the_test_case1) {
        \\}*/
        \\
    ;
    const expected_test_runner =
        \\/* AUTOGENERATED FILE. DO NOT EDIT. */
        \\#include "unity_fixture.h"
        \\
        \\TEST_GROUP_RUNNER(test_group) {
        \\}
        \\
    ;

    const buffer_size: usize = 1024;
    var allocator = std.testing.allocator;
    var all_test_groups = std.StringArrayHashMap(void).init(allocator);
    defer {
        // Free the test groups
        for (all_test_groups.keys()) |test_group|
            all_test_groups.allocator.free(test_group);
        all_test_groups.deinit();
    }

    const generated_runner = try generate_test_file_runner(test_file_code, &all_test_groups, buffer_size, allocator);
    defer allocator.free(generated_runner);

    try std.testing.expectEqualStrings(expected_test_runner, generated_runner);
}

test "generate test case commented cpp-style" {
    const test_file_code =
        \\#include "unity_fixture.h"
        \\TEST_GROUP(test_group);
        \\TEST_SETUP(test_group) {}
        \\TEST_TEAR_DOWN(test_group) {}
        \\//TEST(test_group, the_test_case1) {
        \\//}
        \\
    ;
    const expected_test_runner =
        \\/* AUTOGENERATED FILE. DO NOT EDIT. */
        \\#include "unity_fixture.h"
        \\
        \\TEST_GROUP_RUNNER(test_group) {
        \\}
        \\
    ;

    const buffer_size: usize = 1024;
    var allocator = std.testing.allocator;
    var all_test_groups = std.StringArrayHashMap(void).init(allocator);
    defer {
        // Free the test groups
        for (all_test_groups.keys()) |test_group|
            all_test_groups.allocator.free(test_group);
        all_test_groups.deinit();
    }

    const generated_runner = try generate_test_file_runner(test_file_code, &all_test_groups, buffer_size, allocator);
    defer allocator.free(generated_runner);

    try std.testing.expectEqualStrings(expected_test_runner, generated_runner);
}

test "generate add the file included in the test file" {
    const test_file_code =
        \\#include "unity_fixture.h"
        \\#include "custom_include_file.h"
        \\#include <stdint.h>
        \\#include <stdbool.h>
        \\
    ;
    const expected_test_runner =
        \\/* AUTOGENERATED FILE. DO NOT EDIT. */
        \\#include "unity_fixture.h"
        \\#include "custom_include_file.h"
        \\#include <stdint.h>
        \\#include <stdbool.h>
        \\
    ;

    const buffer_size: usize = 1024;
    var allocator = std.testing.allocator;
    var all_test_groups = std.StringArrayHashMap(void).init(allocator);
    defer {
        // Free the test groups
        for (all_test_groups.keys()) |test_group|
            all_test_groups.allocator.free(test_group);
        all_test_groups.deinit();
    }

    const generated_runner = try generate_test_file_runner(test_file_code, &all_test_groups, buffer_size, allocator);
    defer allocator.free(generated_runner);

    try std.testing.expectEqualStrings(expected_test_runner, generated_runner);
}

test "generate add the macros defined in the test file" {
    const test_file_code =
        \\#define UNDEF_ME_1
        \\#define UNDEF_ME_2 value
        \\#include "unity_fixture.h"
        \\#undef UNDEF_ME_1
        \\#undef UNDEF_ME_2
        \\
        \\#define SUCCESS 0
        \\#define FAILURE 1
        \\#define max(a, b) \
        \\    ((a)>=(b) ? \
        \\    (a) : \
        \\    (b))
        \\
    ;
    const expected_test_runner =
        \\/* AUTOGENERATED FILE. DO NOT EDIT. */
        \\#define UNDEF_ME_1
        \\#define UNDEF_ME_2 value
        \\#include "unity_fixture.h"
        \\#undef UNDEF_ME_1
        \\#undef UNDEF_ME_2
        \\#define SUCCESS 0
        \\#define FAILURE 1
        \\#define max(a, b) \
        \\    ((a)>=(b) ? \
        \\    (a) : \
        \\    (b))
        \\
    ;

    const buffer_size: usize = 1024;
    var allocator = std.testing.allocator;
    var all_test_groups = std.StringArrayHashMap(void).init(allocator);
    defer {
        // Free the test groups
        for (all_test_groups.keys()) |test_group|
            all_test_groups.allocator.free(test_group);
        all_test_groups.deinit();
    }

    const generated_runner = try generate_test_file_runner(test_file_code, &all_test_groups, buffer_size, allocator);
    defer allocator.free(generated_runner);

    try std.testing.expectEqualStrings(expected_test_runner, generated_runner);
}

test "generate add the conditional compilations defined in the test file" {
    const test_file_code =
        \\#include "unity_fixture.h"
        \\
        \\#ifndef HEADER_GUARD_H_
        \\#define HEADER_GUARD_H_
        \\#endif /* HEADER_GUARD_H_ */
        \\
        \\#ifdef MACRO
        \\    #if (MACRO > VALUE_2)
        \\        #undef MACRO
        \\    #endif
        \\#endif
        \\
        \\#ifndef MACRO
        \\    #define MACRO VALUE_0
        \\#endif
        \\
        \\#if (MACRO == VALUE_1)
        \\#elif (MACRO == VALUE_2)
        \\#else /* MACRO */
        \\#endif /* MACRO */
        \\
    ;
    const expected_test_runner =
        \\/* AUTOGENERATED FILE. DO NOT EDIT. */
        \\#include "unity_fixture.h"
        \\#ifndef HEADER_GUARD_H_
        \\#define HEADER_GUARD_H_
        \\#endif /* HEADER_GUARD_H_ */
        \\#ifdef MACRO
        \\#if (MACRO > VALUE_2)
        \\#undef MACRO
        \\#endif
        \\#endif
        \\#ifndef MACRO
        \\#define MACRO VALUE_0
        \\#endif
        \\#if (MACRO == VALUE_1)
        \\#elif (MACRO == VALUE_2)
        \\#else /* MACRO */
        \\#endif /* MACRO */
        \\
    ;

    const buffer_size: usize = 1024;
    var allocator = std.testing.allocator;
    var all_test_groups = std.StringArrayHashMap(void).init(allocator);
    defer {
        // Free the test groups
        for (all_test_groups.keys()) |test_group|
            all_test_groups.allocator.free(test_group);
        all_test_groups.deinit();
    }

    const generated_runner = try generate_test_file_runner(test_file_code, &all_test_groups, buffer_size, allocator);
    defer allocator.free(generated_runner);

    try std.testing.expectEqualStrings(expected_test_runner, generated_runner);
}

test "generate add the conditional compilations defined in the test file 2" {
    const test_file_code =
        \\#include "unity_fixture.h"
        \\#define ENABLE_EXTRA_TESTS 1
        \\
        \\TEST_GROUP(test_group);
        \\TEST_SETUP(test_group) {}
        \\TEST_TEAR_DOWN(test_group) {}
        \\
        \\#if 0
        \\TEST(test_group, test_case_commented_with_pound_if_0) {
        \\}
        \\#endif
        \\
        \\#if (ENABLE_EXTRA_TESTS != 0)
        \\TEST(test_group, test_case_conditionally_compiled) {
        \\}
        \\
        \\TEST(test_group, test_case_conditionally_compiled_2) {
        \\}
        \\#endif /* ENABLE_EXTRA_TESTS */
        \\
    ;
    const expected_test_runner =
        \\/* AUTOGENERATED FILE. DO NOT EDIT. */
        \\#include "unity_fixture.h"
        \\#define ENABLE_EXTRA_TESTS 1
        \\
        \\TEST_GROUP_RUNNER(test_group) {
        \\#if 0
        \\    RUN_TEST_CASE(test_group, test_case_commented_with_pound_if_0); /* TEST_test_group_test_case_commented_with_pound_if_0_ */
        \\#endif
        \\#if (ENABLE_EXTRA_TESTS != 0)
        \\    RUN_TEST_CASE(test_group, test_case_conditionally_compiled); /* TEST_test_group_test_case_conditionally_compiled_ */
        \\    RUN_TEST_CASE(test_group, test_case_conditionally_compiled_2); /* TEST_test_group_test_case_conditionally_compiled_2_ */
        \\#endif /* ENABLE_EXTRA_TESTS */
        \\}
        \\
    ;

    const buffer_size: usize = 1024;
    var allocator = std.testing.allocator;
    var all_test_groups = std.StringArrayHashMap(void).init(allocator);
    defer {
        // Free the test groups
        for (all_test_groups.keys()) |test_group|
            all_test_groups.allocator.free(test_group);
        all_test_groups.deinit();
    }

    const generated_runner = try generate_test_file_runner(test_file_code, &all_test_groups, buffer_size, allocator);
    defer allocator.free(generated_runner);

    try std.testing.expectEqualStrings(expected_test_runner, generated_runner);
}

test "generate main runner for one test group" {
    const test_file_code =
        \\#include "unity_fixture.h"
        \\TEST_GROUP(test_group);
        \\TEST_SETUP(test_group) {}
        \\TEST_TEAR_DOWN(test_group) {}
        \\TEST(test_group, the_test_case) {
        \\}
        \\
    ;
    const expected_main_test_runner =
        \\/* AUTOGENERATED FILE. DO NOT EDIT. */
        \\#include "unity_fixture.h"
        \\
        \\void run_all_tests(void) {
        \\    RUN_TEST_GROUP(test_group);
        \\}
        \\
    ;

    const buffer_size: usize = 1024;
    var allocator = std.testing.allocator;
    var all_test_groups = std.StringArrayHashMap(void).init(allocator);
    defer {
        // Free the test groups
        for (all_test_groups.keys()) |test_group|
            all_test_groups.allocator.free(test_group);
        all_test_groups.deinit();
    }

    const generated_runner = try generate_test_file_runner(test_file_code, &all_test_groups, buffer_size, allocator);
    defer allocator.free(generated_runner);

    const generated_main_runner = try generate_main_runner(&all_test_groups, buffer_size, allocator);
    defer allocator.free(generated_main_runner);

    try std.testing.expectEqualStrings(expected_main_test_runner, generated_main_runner);
}

test "generate main runner for two test groups in one file" {
    const test_file_code =
        \\#include "unity_fixture.h"
        \\
        \\TEST_GROUP(test_group);
        \\TEST_SETUP(test_group) {}
        \\TEST_TEAR_DOWN(test_group) {}
        \\TEST(test_group, the_test_case) {
        \\}
        \\
        \\TEST_GROUP(another_group);
        \\TEST_SETUP(another_group) {}
        \\TEST_TEAR_DOWN(another_group) {}
        \\TEST(another_group, the_test_case1) {
        \\}
        \\TEST(another_group, the_test_case2) {
        \\}
        \\
    ;
    const expected_main_test_runner =
        \\/* AUTOGENERATED FILE. DO NOT EDIT. */
        \\#include "unity_fixture.h"
        \\
        \\void run_all_tests(void) {
        \\    RUN_TEST_GROUP(test_group);
        \\    RUN_TEST_GROUP(another_group);
        \\}
        \\
    ;

    const buffer_size: usize = 1024;
    var allocator = std.testing.allocator;
    var all_test_groups = std.StringArrayHashMap(void).init(allocator);
    defer {
        // Free the test groups
        for (all_test_groups.keys()) |test_group|
            all_test_groups.allocator.free(test_group);
        all_test_groups.deinit();
    }

    const generated_runner = try generate_test_file_runner(test_file_code, &all_test_groups, buffer_size, allocator);
    defer allocator.free(generated_runner);

    const generated_main_runner = try generate_main_runner(&all_test_groups, buffer_size, allocator);
    defer allocator.free(generated_main_runner);

    try std.testing.expectEqualStrings(expected_main_test_runner, generated_main_runner);
}

test "generate main runner for two test groups in two files" {
    const test_file_code_1 =
        \\#include "unity_fixture.h"
        \\TEST_GROUP(test_group);
        \\TEST_SETUP(test_group) {}
        \\TEST_TEAR_DOWN(test_group) {}
        \\TEST(test_group, the_test_case) {
        \\}
        \\
    ;
    const test_file_code_2 =
        \\#include "unity_fixture.h"
        \\TEST_GROUP(another_group);
        \\TEST_SETUP(another_group) {}
        \\TEST_TEAR_DOWN(another_group) {}
        \\TEST(another_group, the_test_case1) {
        \\}
        \\TEST(another_group, the_test_case2) {
        \\}
        \\
    ;
    const expected_main_test_runner =
        \\/* AUTOGENERATED FILE. DO NOT EDIT. */
        \\#include "unity_fixture.h"
        \\
        \\void run_all_tests(void) {
        \\    RUN_TEST_GROUP(test_group);
        \\    RUN_TEST_GROUP(another_group);
        \\}
        \\
    ;

    const buffer_size: usize = 1024;
    var allocator = std.testing.allocator;
    var all_test_groups = std.StringArrayHashMap(void).init(allocator);
    defer {
        // Free the test groups
        for (all_test_groups.keys()) |test_group|
            all_test_groups.allocator.free(test_group);
        all_test_groups.deinit();
    }

    const generated_runner_1 = try generate_test_file_runner(test_file_code_1, &all_test_groups, buffer_size, allocator);
    defer allocator.free(generated_runner_1);

    const generated_runner_2 = try generate_test_file_runner(test_file_code_2, &all_test_groups, buffer_size, allocator);
    defer allocator.free(generated_runner_2);

    const generated_main_runner = try generate_main_runner(&all_test_groups, buffer_size, allocator);
    defer allocator.free(generated_main_runner);

    try std.testing.expectEqualStrings(expected_main_test_runner, generated_main_runner);
}

test "generate main runner for no test group" {
    const test_file_code =
        \\#include "unity_fixture.h"
        \\
    ;
    const expected_main_test_runner =
        \\/* AUTOGENERATED FILE. DO NOT EDIT. */
        \\#include "unity_fixture.h"
        \\
        \\void run_all_tests(void) {
        \\}
        \\
    ;

    const buffer_size: usize = 1024;
    var allocator = std.testing.allocator;
    var all_test_groups = std.StringArrayHashMap(void).init(allocator);
    defer {
        // Free the test groups
        for (all_test_groups.keys()) |test_group|
            all_test_groups.allocator.free(test_group);
        all_test_groups.deinit();
    }

    const generated_runner = try generate_test_file_runner(test_file_code, &all_test_groups, buffer_size, allocator);
    defer allocator.free(generated_runner);

    const generated_main_runner = try generate_main_runner(&all_test_groups, buffer_size, allocator);
    defer allocator.free(generated_main_runner);

    try std.testing.expectEqualStrings(expected_main_test_runner, generated_main_runner);
}
