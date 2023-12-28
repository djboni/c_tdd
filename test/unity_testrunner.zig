// Copyright (c) 2023 Djones A. Boni - MIT License
const std = @import("std");

const runner_append_name = "_runner.c";

/// Read an entire file. Returns a string with the file contents.
/// The caller must free the returned value.
pub fn read_entire_file(file: []const u8, buffer_size: usize,
        allocator: std.mem.Allocator) ![]const u8 {
    var fp = try std.fs.cwd().openFile(file, .{});
    defer fp.close();
    return fp.readToEndAlloc(allocator, buffer_size);
}

/// Write an entire file, truncate if it already exists.
pub fn write_entire_file(file: []const u8, data: []const u8) !void {
    var fp = try std.fs.cwd().createFile(file, .{ .truncate = true });
    defer fp.close();
    try fp.writeAll(data);
}

/// Write an entire file if the requested data is different than the current
/// data, truncating the file. The file is read and compared to the requested
/// data. The file is created if it does not exist.
pub fn write_entire_file_if_changed(file: []const u8, data: []const u8,
        buffer_size: usize, allocator: std.mem.Allocator) !void {
    // Read the file (the file may not exist: FileNotFound)
    const current_data_or_error = read_entire_file(file, buffer_size, allocator);

    if (current_data_or_error) |current_data| {
        // Compare the new and the current file and overwrite if they differ
        defer allocator.free(current_data);
        if (!std.mem.eql(u8, data, current_data))
            try write_entire_file(file, data);
    } else |err| {
        if (err == error.FileNotFound) {
            // Create the file since it does not exist yet
            try write_entire_file(file, data);
        } else {
            // Return any other error
            return err;
        }
    }
}

/// Simple enough tokenizer for C source files.
const Tokenizer = struct {
    data: []const u8,
    position: usize,

    fn skip_whitespace(tokenizer: *Tokenizer) []const u8 {
        var end: usize = tokenizer.position;
        defer tokenizer.position = end;
        while (tokenizer.peek(end)) |ch| {
            if (!std.ascii.isWhitespace(ch))
                break;
            end += 1;
        }
        return tokenizer.data[tokenizer.position..end];
    }

    fn skip_to_eol(tokenizer: *Tokenizer) []const u8 {
        var end: usize = tokenizer.position;
        defer tokenizer.position = end;
        while (tokenizer.peek(end)) |ch| {
            if (ch == '\n')
                break;
            end += 1;
        }
        return tokenizer.data[tokenizer.position..end];
    }

    fn skip_to_token(tokenizer: *Tokenizer, token: []const u8) []const u8 {
        var start: usize = tokenizer.position;
        while (tokenizer.next()) |next_token| {
            if (std.mem.eql(u8, token, next_token))
                break;
        }
        return tokenizer.data[start..tokenizer.position];
    }

    fn skip_to_end_of_pound_expression(tokenizer: *Tokenizer) []const u8 {
        var end: usize = tokenizer.position;
        defer tokenizer.position = end;
        while (tokenizer.peek(end)) |ch| {
            // Continue on escaped new lines
            if (ch == '\n' and tokenizer.peek(end - 1).? != '\\')
                break;
            end += 1;
        }
        return tokenizer.data[tokenizer.position..end];
    }

    fn peek(tokenizer: *Tokenizer, position: usize) ?u8 {
        if (position < tokenizer.data.len) {
            return tokenizer.data[position];
        } else {
            return null;
        }
    }

    fn next(tokenizer: *Tokenizer) ?[]const u8 {
        _ = tokenizer.skip_whitespace();
        var start: usize = tokenizer.position;
        var end: usize = start;
        while (end < tokenizer.data.len) {
            const ch = tokenizer.data[end];

            if (std.ascii.isWhitespace(ch)) {
                break;
            } else if (ch == '/') {
                if (start == end) {
                    if (tokenizer.peek(end + 1)) |next_ch| {
                        if (next_ch == '/') {
                            // Start of a C++ style comment (//)
                            tokenizer.position += 2;
                            _ = tokenizer.skip_to_eol().len;
                            end = tokenizer.position;
                        } else if (next_ch == '*') {
                            // Start of a C style comment (/* */)
                            tokenizer.position += 2;
                            _ = tokenizer.skip_to_token("*/").len;
                            end = tokenizer.position;
                        } else {
                            end += 1;
                        }
                    }
                }
                break;
            } else if (ch == '*') {
                if (start == end) {
                    if (tokenizer.peek(end + 1)) |next_ch| {
                        if (next_ch == '/') {
                            // End of a C style comment (/* */)
                            end += 2;
                        } else {
                            end += 1;
                        }
                    }
                }
                break;
            } else if (ch == '(' or ch == ')' or ch == '[' or ch == ']'
                    or ch == '{' or ch == '}' or ch == ',' or ch == ';') {
                if (start == end)
                    end += 1;
                break;
            } else if (ch == '"') {
                while (tokenizer.peek(end + 1)) |next_ch| {
                    if (next_ch == '\\') {
                        // Escaped character
                        end += 2;
                    } else if (next_ch == '"') {
                        // End of string
                        end += 2;
                        break;
                    } else {
                        end += 1;
                    }
                }
                break;
            } else {
                end += 1;
            }
        }

        if (end > tokenizer.data.len)
            end = tokenizer.data.len;
        defer tokenizer.position = end;
        if (end < tokenizer.data.len or start != end) {
            return tokenizer.data[start..end];
        } else {
            return null;
        }
    }
};

/// Generate a runner for a test file. Returns the content of the generated
/// file. The caller must free the returned value.
fn generate_test_file_runner(test_file_code: []const u8,
        all_test_groups: *std.StringArrayHashMap(void), buffer_size: usize,
        allocator: std.mem.Allocator) ![]const u8 {
    var tokenizer = Tokenizer{ .data=test_file_code, .position=0 };

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
    var generated_runner = try allocator.alloc(u8, buffer_size);
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
        } else if (std.mem.eql(u8, "#include", token)) {
            // #include
            const include_file = tokenizer.skip_to_eol();
            size += (try std.fmt.bufPrint(generated_runner[size..], "{s}{s}\n", .{token, include_file})).len;
            continue;
        } else if (std.mem.eql(u8, "#define", token) or std.mem.eql(u8, "#undef", token)) {
            // #define #undef
            const expression = tokenizer.skip_to_end_of_pound_expression();
            size += (try std.fmt.bufPrint(generated_runner[size..], "{s}{s}\n", .{token, expression})).len;
            continue;
        } else if (std.mem.eql(u8, "#if", token) or std.mem.eql(u8, "#elif", token)
                or std.mem.eql(u8, "#ifdef", token) or std.mem.eql(u8, "#ifndef", token)
                or std.mem.eql(u8, "#else", token) or std.mem.eql(u8, "#endif", token)) {
            // #if #elif #ifdef #ifndef #else #endif
            const expression = tokenizer.skip_to_end_of_pound_expression();
            size += (try std.fmt.bufPrint(generated_runner[size..], "{s}{s}\n", .{token, expression})).len;
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
                    size += (try std.fmt.bufPrint(generated_runner[size..], "    RUN_TEST_CASE({s}, {s}); /* TEST_{s}_{s}_ */\n", .{test_group, test_case, test_group, test_case})).len;
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
fn generate_main_runner(all_test_groups: *std.StringArrayHashMap(void),
        buffer_size: usize, allocator: std.mem.Allocator) ![]const u8 {
    var size: usize = 0;
    var generated_runner = try allocator.alloc(u8, buffer_size);
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
fn add_test_group(all_test_groups: *std.StringArrayHashMap(void),
        group: []const u8) !void {
    const test_group_null = all_test_groups.get(group);
    if (test_group_null == null)
        try all_test_groups.put(try all_test_groups.allocator.dupe(u8, group), {});
}

/// Generate test runners for the test files and a main test runner for
/// the test groups. Returns an allocated list with the allocated names of
/// the files created. The caller must free the returned value and its elements.
pub fn generate_test_runner(file_names: []const[]const u8,
        runner_file_name: []const u8, buffer_size: usize,
        allocator: std.mem.Allocator) ![]const []const u8 {
    var test_runner_file_count: usize = 0;
    var test_runners_files = try allocator.alloc([]const u8, file_names.len + 1);
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
        const test_file_code = try read_entire_file(file_name, buffer_size, allocator);
        defer allocator.free(test_file_code);

        var generated_runner = try generate_test_file_runner(test_file_code, &all_test_groups, buffer_size, allocator);
        defer allocator.free(generated_runner);

        // Creathe the name of the test file runner: file.c -> file_runner.c
        var test_runner_file_name_buffer = try allocator.alloc(u8, file_name.len + runner_append_name.len);
        defer allocator.free(test_runner_file_name_buffer);
        const test_runner_file_name = try std.fmt.bufPrint(
            test_runner_file_name_buffer, "{s}{s}", .{
            file_name[0..file_name.len-2], runner_append_name});

        try write_entire_file_if_changed(test_runner_file_name, generated_runner, buffer_size, allocator);
        test_runners_files[test_runner_file_count] = try allocator.dupe(u8, test_runner_file_name);
        test_runner_file_count += 1;
    }

    // Generate the main test runner
    var generated_main_runner = try generate_main_runner(&all_test_groups, buffer_size, allocator);
    defer allocator.free(generated_main_runner);

    try write_entire_file_if_changed(runner_file_name, generated_main_runner, buffer_size, allocator);
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
        "#include", "<stdio.h>",
        "int", "main", "(", "int", "argc", ",", "char", "*", "*", "argv", ")", "{",
        "printf", "(", "\"Hello World!\\n\"", ")", ";",
        "return", "0", ";",
        "}",
    };
    var tokenizer = Tokenizer{ .data=data, .position=0 };
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
        "#include", "<stdio.h>",
        "int", "main", "(", "int", "argc", ",", "char", "*", "*", "argv", ")", "{",
        "printf", "(", "\"Hello World!\\n\"", ")", ";",
        "return", "0", ";",
        "}",
    };
    var tokenizer = Tokenizer{ .data=data, .position=0 };
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
    var tokenizer = Tokenizer{ .data=data, .position=0 };
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
    const expected_tokens = [_][]const u8{
        "int", "//comment", "float"
    };
    var tokenizer = Tokenizer{ .data=data, .position=0 };
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
    const expected_tokens = [_][]const u8{
        "int", "/*comment_start\ncomment_end*/", "float"
    };
    var tokenizer = Tokenizer{ .data=data, .position=0 };
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
    const expected_tokens = [_][]const u8{
        "int", "#if", "0", "comment", "#endif", "float"
    };
    var tokenizer = Tokenizer{ .data=data, .position=0 };
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

    const generated_runner = try generate_test_file_runner(test_file_code,
        &all_test_groups, buffer_size, allocator);
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

    const generated_runner = try generate_test_file_runner(test_file_code,
        &all_test_groups, buffer_size, allocator);
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

    const generated_runner = try generate_test_file_runner(test_file_code,
        &all_test_groups, buffer_size, allocator);
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

    const generated_runner = try generate_test_file_runner(test_file_code,
        &all_test_groups, buffer_size, allocator);
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

    const generated_runner = try generate_test_file_runner(test_file_code,
        &all_test_groups, buffer_size, allocator);
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

    const generated_runner = try generate_test_file_runner(test_file_code,
        &all_test_groups, buffer_size, allocator);
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

    const generated_runner = try generate_test_file_runner(test_file_code,
        &all_test_groups, buffer_size, allocator);
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

    const generated_runner = try generate_test_file_runner(test_file_code,
        &all_test_groups, buffer_size, allocator);
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

    const generated_runner = try generate_test_file_runner(test_file_code,
        &all_test_groups, buffer_size, allocator);
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

    const generated_runner = try generate_test_file_runner(test_file_code,
        &all_test_groups, buffer_size, allocator);
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

    const generated_runner = try generate_test_file_runner(test_file_code,
        &all_test_groups, buffer_size, allocator);
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

    const generated_runner = try generate_test_file_runner(test_file_code,
        &all_test_groups, buffer_size, allocator);
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

    const generated_runner = try generate_test_file_runner(test_file_code,
        &all_test_groups, buffer_size, allocator);
    defer allocator.free(generated_runner);

    const generated_main_runner = try generate_main_runner(
        &all_test_groups, buffer_size, allocator);
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

    const generated_runner = try generate_test_file_runner(test_file_code,
        &all_test_groups, buffer_size, allocator);
    defer allocator.free(generated_runner);

    const generated_main_runner = try generate_main_runner(
        &all_test_groups, buffer_size, allocator);
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

    const generated_runner_1 = try generate_test_file_runner(test_file_code_1,
        &all_test_groups, buffer_size, allocator);
    defer allocator.free(generated_runner_1);

    const generated_runner_2 = try generate_test_file_runner(test_file_code_2,
        &all_test_groups, buffer_size, allocator);
    defer allocator.free(generated_runner_2);

    const generated_main_runner = try generate_main_runner(
        &all_test_groups, buffer_size, allocator);
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

    const generated_runner = try generate_test_file_runner(test_file_code,
        &all_test_groups, buffer_size, allocator);
    defer allocator.free(generated_runner);

    const generated_main_runner = try generate_main_runner(
        &all_test_groups, buffer_size, allocator);
    defer allocator.free(generated_main_runner);

    try std.testing.expectEqualStrings(expected_main_test_runner, generated_main_runner);
}
