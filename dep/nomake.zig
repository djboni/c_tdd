// Copyright (c) 2023 Djones A. Boni - MIT License

// Create a hand-made build-tool to substitute the external tool `make`.
//
// Execute arbitrary commands:
//
// ```zig
// var cmd = try CmdLine.init(allocator);
// try cmd.add(.{"gcc", "-o", "main"});
// try cmd.add(.{"main.c", "mylib.c"});
// try cmd.executeSync();
// ```
//
// Whenever the function accepts `.{"s1", "s2", ...}`, it should also accept
// `[]const[]const u8{"s1", "s2", ...}, and also just `"s1"` (`[]const u8`).
//
// Check rebuild based on mtime:
//
// ```zig
// if (nomake.needsRebuild("main", .{"main.c", "mylib.c", "mylib.h"})) {
//     // Rebuild as shown above.
// }
// ```
//
// Incremental builds below w/ automatic #include detection.
//
// Incremental build of source to object file:
//
// ```zig
// const object_output_path = try buildSource(config, "main.c", .{});
// // free object_output_path
// ```
//
// Incremental build of a static library:
//
// ```zig
// const sources = [_][]const u8{ "mylib.c" };
// const lib_output_path = try buildLibrary(config, "libname", &sources, .{});
// // free lib_output_path
// ```
//
// Incremental build of an executable:
//
// ```zig
// const sources = [_][]const u8{ "main.c" };
// const objects: [sources.len][]const u8 = undefined;
// for (sources) |source, i| objects[i] = try buildSource(config, source, .{});
// const lib_output_path = try buildLibrary(config, "libname", &[_][]const u8{ "mylib.c" }, .{});
// const exec_output_path = try buildExecutable(config, "main", &sources, .{});
// // free exec_output_path, lib_output_path, and objects
// ```
//
// Build configuration example for AVR ATmega2560:
//
// ```zig
// var config = BuildConfig{
//     .initialized = true,
//     .allocator = allocator,
//     .buffer_size = buffer_size,
//     .build_dir = "./out/avr",
//     .arch = "avr",
//     .cc = &[_][]const u8{"avr-gcc"},
//     .ld = &[_][]const u8{"avr-gcc"},
//     .ar = &[_][]const u8{"avr-ar"},
//     .objcopy = &[_][]const u8{"avr-objcopy"},
//     .size = &[_][]const u8{"avr-size"},
//     .cflags = &[_][]const u8{
//         "-mmcu=atmega2560",
//         "-Os",
//         "-g3",
//         "-fdata-sections",
//         "-ffunction-sections",
//     },
//     .ldflags = &[_][]const u8{
//         "-mmcu=atmega2560",
//         "-Wl,--gc-sections",
//     },
//     .include_dirs = &[_][]const u8{
//         "-I./include/",
//         "-I./dep/port/avr/",
//     },
//     .obj_extension = ".o",
//     .lib_extension = ".a",
//     .exec_extension = ".elf",
// };
// ```
//
// Auto rebuild of the current build tool:
//
// ```zig
// var gpa = std.heap.GeneralPurposeAllocator(.{}){};
// const allocator = gpa.allocator();
//
// const argv = try std.process.argsAlloc(allocator);
// defer std.process.argsFree(allocator, argv);
//
// try rebuild(allocator, argv, false, "./build", &[_][]const u8{
//     "./build.zig",
// });
// ```

const std = @import("std");
const builtin = @import("builtin");

// Verbosity
pub const verb_warn = 0;
pub const verb_info = 1;
pub const verb_debug = 2;
pub var verbosity: u8 = verb_warn;

/// Read an entire file. Returns a string with the file contents.
/// The caller must free the returned value.
pub fn readEntireFile(file: []const u8, buffer_size: usize, allocator: std.mem.Allocator) ![]const u8 {
    var fp = try std.fs.cwd().openFile(file, .{});
    defer fp.close();
    return fp.readToEndAlloc(allocator, buffer_size);
}

/// Write an entire file, truncate if it already exists.
pub fn writeEntireFile(file: []const u8, data: []const u8) !void {
    try createParentDirectory(file);
    var fp = try std.fs.cwd().createFile(file, .{ .truncate = true });
    defer fp.close();
    try fp.writeAll(data);
}

/// Write an entire file if the requested data is different than the current
/// data, truncating the file. The file is read and compared to the requested
/// data. The file is created if it does not exist.
pub fn writeEntireFileIfChanged(file: []const u8, data: []const u8, buffer_size: usize, allocator: std.mem.Allocator) !void {
    // Read the file (the file may not exist: FileNotFound)
    const current_data_or_error = readEntireFile(file, buffer_size, allocator);

    if (current_data_or_error) |current_data| {
        // Compare the new and the current file and overwrite if they differ
        defer allocator.free(current_data);
        if (!std.mem.eql(u8, data, current_data))
            try writeEntireFile(file, data);
    } else |err| {
        if (err == error.FileNotFound) {
            // Create the file since it does not exist yet
            try writeEntireFile(file, data);
        } else {
            // Return any other error
            return err;
        }
    }
}

pub const CmdLine = struct {
    args: [][]const u8,
    used: usize,
    alloc: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !CmdLine {
        const args = try allocator.alloc([]const u8, 0);
        const cmd = CmdLine{ .args = args, .used = 0, .alloc = 0, .allocator = allocator };
        return cmd;
    }

    pub fn deinit(cmd: *CmdLine) void {
        cmd.allocator.free(cmd.args);
    }

    pub fn clean(cmd: *CmdLine) void {
        cmd.used = 0;
    }

    fn privRealloc(cmd: *CmdLine, alloc: usize) !void {
        if (alloc > cmd.alloc) {
            cmd.args = try cmd.allocator.realloc(cmd.args, alloc);
            cmd.alloc = alloc;
        }
    }

    fn privAdd(cmd: *CmdLine, x: []const u8) !void {
        const num = 1;
        const new_len = cmd.used + num;
        try cmd.privRealloc(new_len);
        cmd.args[new_len - 1] = x;
        cmd.used = new_len;
    }

    pub fn add(cmd: *CmdLine, args: anytype) !void {
        //std.debug.print("{}\n", .{@TypeOf(args)});
        if (@TypeOf(args) == []const []const u8 or @TypeOf(args) == [][]const u8) {
            var i: usize = 0;
            while (i < args.len) : (i += 1) {
                try cmd.privAdd(args[i]);
            }
        } else if (@TypeOf(args) == []const u8 or @TypeOf(args) == []u8) {
            try cmd.privAdd(args);
        } else if (@TypeOf(args) == *const [args.len:0]u8) {
            try cmd.privAdd(args);
        } else {
            comptime var i: usize = 0;
            inline while (i < args.len) : (i += 1) {
                try cmd.privAdd(args[i]);
            }
        }
    }

    pub fn print(cmd: *CmdLine, preamble: []const u8) void {
        std.debug.print("{s}", .{preamble});
        const args = cmd.args[0..cmd.used];
        var first: bool = true;
        for (args) |arg| {
            if (first) {
                first = false;
            } else {
                std.debug.print(" ", .{});
            }

            // TODO: Escape the arguments
            if (std.mem.indexOfAny(u8, arg, " ")) |_| {
                std.debug.print("\"{s}\"", .{arg});
            } else {
                std.debug.print("{s}", .{arg});
            }
        }
        std.debug.print("\n", .{});
    }

    pub fn executeSync(cmd: *CmdLine) !void {
        cmd.print("EXEC(): ");
        const args = cmd.args[0..cmd.used];
        var child = std.ChildProcess.init(args, cmd.allocator);
        const term = try child.spawnAndWait();
        // std.debug.print("term={}\n", .{term});
        switch (term) {
            .Exited => |exit_val| {
                if (exit_val != 0) {
                    std.debug.print("ERROR: The command returned an error {}\n", .{exit_val});
                    std.os.exit(exit_val);
                }
                return;
            },
            .Signal => |signal_val| {
                std.debug.print("ERROR: The command received the signal {}\n", .{signal_val});
                std.os.exit(1);
            },
            else => {
                std.debug.print("ERROR: Unexpected value {?}\n", .{term});
                std.os.exit(1);
            },
        }
    }

    pub fn executeSyncGetOutput(cmd: *CmdLine) !child_output {
        var output: child_output = undefined;

        cmd.print("EXEC_OUTPUT(): ");
        const args = cmd.args[0..cmd.used];
        var child = std.ChildProcess.init(args, cmd.allocator);
        child.stdout_behavior = .Pipe;

        var stdout = std.ArrayList(u8).init(cmd.allocator);
        errdefer stdout.deinit();

        try child.spawn();
        errdefer _ = child.kill() catch {};

        while (true) {
            var buff: [4096]u8 = undefined;
            const size = try child.stdout.?.read(&buff);
            if (size == 0)
                break;
            try stdout.appendSlice(buff[0..size]);
        }

        const term = try child.wait();

        output.allocator = cmd.allocator;
        output.stdout = try stdout.toOwnedSlice();
        output.term = term;
        return output;
    }

    pub fn executeSyncGetOutputTimeout(cmd: *CmdLine, timeout: f64) !child_output {
        const timeout_ms: u64 = @intFromFloat(timeout * 1e3);
        var output: child_output = undefined;

        std.debug.print("EXEC_OUTPUT(timeout={}ms): ", .{timeout_ms});
        cmd.print("");
        const args = cmd.args[0..cmd.used];
        var child = std.ChildProcess.init(args, cmd.allocator);
        child.stdout_behavior = .Pipe;

        var stdout = std.ArrayList(u8).init(cmd.allocator);
        errdefer stdout.deinit();

        try child.spawn();
        errdefer _ = child.kill() catch {};

        // Create thread to kill the child process after timeout
        const thread1 = try std.Thread.spawn(.{}, killChildProcess, .{ timeout, &child, &output });
        defer thread1.join();

        while (true) {
            var buff: [4096]u8 = undefined;
            const size = try child.stdout.?.read(&buff);
            if (size == 0)
                break;
            try stdout.appendSlice(buff[0..size]);
        }

        output.allocator = cmd.allocator;
        output.stdout = try stdout.toOwnedSlice();
        return output;
    }

    const child_output = struct {
        allocator: std.mem.Allocator,
        stdout: []const u8,
        //stderr: []const u8,
        term: std.ChildProcess.Term,

        pub fn deinit(child: *const child_output) void {
            child.allocator.free(child.stdout);
        }
    };
};

fn killChildProcess(timeout: f64, child: *std.ChildProcess, output: *CmdLine.child_output) void {
    const timeout_ns: u64 = @intFromFloat(timeout * 1e9);
    std.time.sleep(timeout_ns);
    output.term = child.kill() catch std.ChildProcess.Term{ .Unknown = 92 };
}

pub fn createDirectory(dir_path: []const u8) !void {
    if (dir_exists_cache == null) {
        // Cache lazy initialization.
        dir_exists_cache = Cache([]const u8, void).init(cache_gpa.allocator());
    }
    if (dir_exists_cache.?.get(dir_path) == null) {
        try dir_exists_cache.?.put(dir_path, {});
        std.os.mkdir(dir_path, 0o777) catch |err| {
            switch (err) {
                error.PathAlreadyExists => return,
                else => {
                    return err;
                },
            }
        };
        if (verbosity >= verb_info)
            std.debug.print("INFO: Created directory {s}\n", .{dir_path});
    }
}

pub fn createParentDirectory(path: []const u8) !void {
    // Create parent directory.
    if (std.fs.path.dirname(path)) |parent| {
        try createParentDirectory(parent);
        try createDirectory(parent);
    }
}

pub fn deleteDirectory(dir_path: []const u8) !void {
    if (verbosity >= verb_info)
        std.debug.print("INFO: Removing directory {s}\n", .{dir_path});
    try std.fs.cwd().deleteTree(dir_path);
}

pub fn shortenPath(path: []const u8) []const u8 {
    // converts "././A/B//" to "A/B"
    var short = path;
    while (std.mem.endsWith(u8, short, "/"))
        short = short[0 .. short.len - 1];
    while (std.mem.startsWith(u8, short, "./"))
        short = short[2..];
    if (builtin.os.tag == .windows) {
        while (std.mem.endsWith(u8, short, "\\"))
            short = short[0 .. short.len - 1];
        while (std.mem.startsWith(u8, short, ".\\"))
            short = short[2..];
    }
    return short;
}

/// The caller must free the returned value.
pub fn splitBySpaces(allocator: std.mem.Allocator, long_string: []const u8) ![]const []const u8 {
    var slices = try CmdLine.init(allocator);
    defer slices.deinit();

    var iter = std.mem.splitAny(u8, long_string, " ");
    while (iter.next()) |slice|
        try slices.add(slice);

    return allocator.dupe([]const u8, slices.args);
}

pub fn Cache(comptime K: type, comptime V: type) type {
    return struct {
        cache: UnderlyingType,
        stats: Stats,

        const Stats = struct {
            put: usize = 0,
            miss: usize = 0,
            hit: usize = 0,
            clear: usize = 0,
        };

        const Self = @This();

        // `K == []const u8` is a special case where K is a variable length
        // string. We use StringHashMap in this case.
        // We also check if `K/V == []const u8` because of duping
        // the keys/values, which has nothing to do with StringHashMap.
        const UnderlyingType = if (K == []const u8) std.StringArrayHashMap(V) else std.AutoArrayHashMap(K, V);

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .cache = UnderlyingType.init(allocator),
                .stats = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            if (K == []const u8) {
                // Duped key.
                var iter = self.cache.keyIterator();
                while (iter.next()) |key| {
                    self.cache.allocator.free(key.*);
                }
            }
            if (V == []const u8) {
                // Duped value.
                var iter = self.cache.valueIterator();
                while (iter.next()) |value| {
                    self.free(value.*);
                }
            }
            self.cache.deinit();
        }

        pub fn put(self: *Self, key: K, value: V) !void {
            // Duped key, value. Dupe the key and/or value because it may
            // be deallocated.
            self.stats.put += 1;
            const k = if (K == []const u8) try self.cache.allocator.dupe(u8, key) else key;
            errdefer if (K == []const u8) self.cache.allocator.free(key);
            const v = if (V == []const u8) try self.cache.allocator.dupe(u8, value) else value;
            errdefer if (V == []const u8) self.cache.allocator.free(value);
            return self.cache.put(k, v);
        }

        pub fn get(self: *Self, key: K) ?V {
            const result = self.cache.get(key);
            if (result == null) {
                self.stats.miss += 1;
            } else {
                self.stats.hit += 1;
            }
            return result;
        }

        pub fn contains(self: *Self, key: K) bool {
            return self.cache.contains(key);
        }

        pub fn clearEntry(self: *Self, key: K) void {
            if (self.cache.fetchOrderedRemove(key)) |kv| {
                self.stats.clear += 1;
                // Duped key, value.
                if (K == []const u8)
                    self.cache.allocator.free(kv.key);
                if (V == []const u8)
                    self.cache.allocator.free(kv.value);
            }
        }

        pub fn clearAll(self: *Self) void {
            var iter = self.cache.iterator();
            while (iter.next()) |kv| {
                self.stats.clear += 1;
                // Duped key, value.
                if (K == []const u8)
                    self.cache.allocator.free(kv.key_ptr.*);
                if (V == []const u8)
                    self.cache.allocator.free(kv.value_ptr.*);
            }
            self.cache.clearRetainingCapacity();
        }

        pub fn print(self: *Self) void {
            var iter = self.cache.iterator();
            while (iter.next()) |kv| {
                //std.debug.print("{}\n", .{kv});
                if (K == []const u8) {
                    if (V == void) {
                        std.debug.print("{s}\n", .{kv.key_ptr.*});
                    } else if (V == []const []const u8 or V == []const u8) {
                        std.debug.print("{s}: {s}\n", .{ kv.key_ptr.*, kv.value_ptr.* });
                    } else {
                        std.debug.print("{s}: {}\n", .{ kv.key_ptr.*, kv.value_ptr.* });
                    }
                } else {
                    std.debug.print("{}: {}\n", .{ kv.key_ptr.*, kv.value_ptr.* });
                }
            }
        }
    };
}

// This allocator leaks on purpose. We never call
// mtime_cache.?.deinit() and gpa.deinit().
var cache_gpa = std.heap.GeneralPurposeAllocator(.{}){};
pub var dir_exists_cache: ?Cache([]const u8, void) = null;
pub var included_files_cache: ?Cache([]const u8, []const []const u8) = null;
pub var mtime_cache: ?Cache([]const u8, i128) = null;

fn clearMtimeCache(file: []const u8) void {
    mtime_cache.?.clearEntry(file);
}

fn getFileMtimeCache(file: []const u8) !i128 {
    if (mtime_cache == null) {
        // Cache lazy initialization.
        mtime_cache = Cache([]const u8, i128).init(cache_gpa.allocator());
    }
    if (mtime_cache.?.get(file)) |mtime| {
        return mtime;
    } else {
        const mtime = try getFileMtime(file);
        try mtime_cache.?.put(file, mtime);
        return mtime;
    }
}

fn getFileMtime(file: []const u8) !i128 {
    const fd = try std.fs.cwd().openFile(file, .{});
    defer fd.close();
    const stat = try fd.stat();
    return stat.mtime;
}

fn privNeedsRebuildOne(target: []const u8, target_mtime: i128, dep: []const u8) bool {
    const dep_mtime = getFileMtimeCache(dep) catch return {
        if (verbosity >= verb_debug)
            std.debug.print("DEBUG: Rebuilding target {s} because the dependency {s} does not exit\n", .{ target, dep });
        clearMtimeCache(target);
        return true;
    };
    if (dep_mtime > target_mtime) {
        if (verbosity >= verb_debug)
            std.debug.print("DEBUG: Rebuilding target {s} because the dependency {s} was updated\n", .{ target, dep });
        clearMtimeCache(target);
        return true;
    }
    return false;
}

pub fn needsRebuild(target: []const u8, dependencies: anytype) bool {
    const target_mtime = getFileMtimeCache(target) catch {
        if (verbosity >= verb_debug)
            std.debug.print("DEBUG: Rebuilding target {s} because it does not exist\n", .{target});
        clearMtimeCache(target);
        return true;
    };
    if (@TypeOf(dependencies) == []const []const u8 or @TypeOf(dependencies) == [][]const u8) {
        for (dependencies) |dep|
            if (privNeedsRebuildOne(target, target_mtime, dep))
                return true;
    } else if (@TypeOf(dependencies) == []const u8 or @TypeOf(dependencies) == []u8) {
        const dep = dependencies;
        if (privNeedsRebuildOne(target, target_mtime, dep))
            return true;
    } else if (@TypeOf(dependencies) == *const [dependencies.len:0]u8) {
        const dep = dependencies;
        if (privNeedsRebuildOne(target, target_mtime, dep))
            return true;
    } else {
        inline for (dependencies) |dep|
            if (needsRebuild(target, dep))
                return true;
    }
    return false;
}

pub fn rebuild(allocator: std.mem.Allocator, argv: []const []const u8, force_rebuild: bool, program: []const u8, dependencies: []const []const u8) !void {
    const program_exe = try std.mem.concat(allocator, u8, &.{
        program,
        switch (builtin.os.tag) {
            .windows => ".exe",
            else => "",
        },
    });
    defer allocator.free(program_exe);

    if (force_rebuild or needsRebuild(program_exe, dependencies)) {
        // Ignore verbosity
        std.debug.print("INFO: Rebuilding {s}\n", .{program_exe});

        var cmd = try CmdLine.init(allocator);
        defer cmd.deinit();

        // First dependency is the source.
        try cmd.add(.{ "zig", "build-exe", dependencies[0] });

        if (builtin.os.tag == .windows) {
            std.debug.print(
                \\ERROR: Cannot self rebuild {s} on Windows because the executable is already open.
                \\       Rebuild manually by running the command:
                \\
            , .{program_exe});
            cmd.print("       ");

            // Exiting with an error
            std.os.exit(1);
        }

        // On Windows replacing the executable fails with
        // "error: lld-link: failed to write output 'build.exe': Permission denied"
        // because the executable is already open.
        try cmd.executeSync();

        // Remove unecessary build output
        if (builtin.os.tag == .windows) {
            // build.exe.obj build.pdb
            const obj = try std.mem.concat(allocator, u8, &.{ program, ".exe.obj" });
            defer allocator.free(obj);
            try std.fs.cwd().deleteFile(obj);
            const pdb = try std.mem.concat(allocator, u8, &.{ program, ".pdb" });
            defer allocator.free(pdb);
            try std.fs.cwd().deleteFile(pdb);
        } else {
            // build.o
            const obj = try std.mem.concat(allocator, u8, &.{ program, ".o" });
            defer allocator.free(obj);
            try std.fs.cwd().deleteFile(obj);
        }

        // Ignore verbosity
        std.debug.print("INFO: Executing the new {s}\n", .{program_exe});

        cmd.clean();
        try cmd.add(argv);
        if (force_rebuild)
            try cmd.add("--no-rebuild");
        try cmd.executeSync();

        // Rebuild and rerun successful. Exit the current.
        std.os.exit(0);
    }
}

pub const BuildConfig = struct {
    initialized: bool,
    allocator: std.mem.Allocator,
    buffer_size: usize,
    arch: []const u8,
    build_dir: []const u8,
    cc: []const []const u8,
    ld: []const []const u8,
    ar: []const []const u8,
    objcopy: []const []const u8,
    size: []const []const u8,
    cflags: []const []const u8,
    ldflags: []const []const u8,
    include_dirs: []const []const u8,
    obj_extension: []const u8,
    lib_extension: []const u8,
    exec_extension: []const u8,
};

/// The caller must free the returned value.
pub fn getCCVersion(c: *BuildConfig) ![]const u8 {
    // Create command line
    var cmd = try CmdLine.init(c.allocator);
    defer cmd.deinit();

    try cmd.add(c.cc);
    try cmd.add("--version");
    const output = try cmd.executeSyncGetOutput();
    defer output.deinit();

    switch (output.term) {
        .Exited => |exit_val| {
            if (exit_val != 0) {
                std.debug.print("ERROR: Could not get the compiler version. Exit status: {}\n", .{exit_val});
                std.os.exit(exit_val);
            }
        },
        else => {
            std.debug.print("ERROR: Could not get the compiler version. Result: {}\n", .{output.term});
            std.os.exit(1);
        },
    }

    // TODO: Improve this version parser
    // avr-gcc: avr-gcc (GCC) 5.4.0
    // avr-gcc: avr-gcc (GCC) 12.1.0
    // gcc:     gcc (Ubuntu 11.4.0-1ubuntu1~22.04) 11.4.0
    // clang:   Ubuntu clang version 14.0.0-1ubuntu1.1
    // zig cc:  clang version 16.0.6 (https://github.com/ziglang/zig-bootstrap GITHASH)
    const idx_end = std.mem.indexOfAny(u8, output.stdout, "\n\r");
    if (idx_end == null)
        return "";

    const idx_start = std.mem.lastIndexOfAny(u8, output.stdout[0..idx_end.?], " ");
    if (idx_start == null)
        return "";

    const version = output.stdout[idx_start.? + 1 .. idx_end.?];
    return c.allocator.dupe(u8, version);
}

/// Simple enough tokenizer for C source files.
pub const Tokenizer = struct {
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

    fn skip_alpha(tokenizer: *Tokenizer) []const u8 {
        var end: usize = tokenizer.position;
        defer tokenizer.position = end;
        while (tokenizer.peek(end)) |ch| {
            if (!std.ascii.isAlphabetic(ch))
                break;
            end += 1;
        }
        return tokenizer.data[tokenizer.position..end];
    }

    pub fn skip_to_eol(tokenizer: *Tokenizer) []const u8 {
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
        const start: usize = tokenizer.position;
        while (tokenizer.next()) |next_token| {
            if (std.mem.eql(u8, token, next_token))
                break;
        }
        return tokenizer.data[start..tokenizer.position];
    }

    pub fn skip_to_end_of_pound_expression(tokenizer: *Tokenizer) []const u8 {
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

    pub fn next(tokenizer: *Tokenizer) ?[]const u8 {
        _ = tokenizer.skip_whitespace();
        const start: usize = tokenizer.position;
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
            } else if (ch == '(' or ch == ')' or ch == '[' or ch == ']' or ch == '{' or ch == '}' or ch == ',' or ch == ';') {
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
            } else if (ch == '#') {
                tokenizer.position += 1;
                _ = tokenizer.skip_whitespace();
                _ = tokenizer.skip_alpha();
                end = tokenizer.position;
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

/// The caller must free the returned value.
fn privGetCIncludedDependencies(allocator: std.mem.Allocator, content: []const u8) ![]const []const u8 {
    var tokenizer = Tokenizer{ .data = content, .position = 0 };

    var incl = try CmdLine.init(allocator);
    defer incl.deinit();

    while (tokenizer.next()) |token| {
        // Special treatment for comments and preprocessor
        if (std.mem.startsWith(u8, token, "//")) {
            // C++ style comment (//)
            continue;
        } else if (std.mem.startsWith(u8, token, "/*")) {
            // C style comment (/* */)
            continue;
        } else if (std.mem.startsWith(u8, token, "#") and std.mem.endsWith(u8, token, "include")) {
            const include_file = std.mem.trim(u8, tokenizer.skip_to_eol(), " \"<>");
            const duped_include_file = try allocator.dupe(u8, include_file);
            try incl.add(duped_include_file);
            continue;
        } else if (std.mem.startsWith(u8, token, "#") and
            (std.mem.endsWith(u8, token, "define") or std.mem.endsWith(u8, token, "undef")))
        {
            // #define #undef
            _ = tokenizer.skip_to_end_of_pound_expression();
            continue;
        } else if (std.mem.startsWith(u8, token, "#") and
            (std.mem.endsWith(u8, token, "if") or std.mem.endsWith(u8, token, "elif") or
            std.mem.endsWith(u8, token, "ifdef") or std.mem.endsWith(u8, token, "ifndef") or
            std.mem.endsWith(u8, token, "else") or std.mem.endsWith(u8, token, "endif")))
        {
            // #if #elif #ifdef #ifndef #else #endif
            _ = tokenizer.skip_to_end_of_pound_expression();
            continue;
        }
    }

    // Return a new allocation with only the necessary size
    return allocator.dupe([]const u8, incl.args);
}

/// The cache owns the retuned value and its content.
pub fn getIncludedDependencies(c: BuildConfig, file: []const u8, cache_name: []const u8) ![]const []const u8 {
    if (included_files_cache == null) {
        // Cache lazy initialization.
        included_files_cache = Cache([]const u8, []const []const u8).init(cache_gpa.allocator());
    }
    if (included_files_cache.?.get(cache_name)) |deps|
        return deps;

    var found = try CmdLine.init(included_files_cache.?.cache.allocator);
    defer found.deinit();
    errdefer for (found.args) |f| included_files_cache.?.cache.allocator.free(f);

    var not_found = try CmdLine.init(included_files_cache.?.cache.allocator);
    defer not_found.deinit();

    const content = try readEntireFile(file, c.buffer_size, c.allocator);
    defer c.allocator.free(content);

    const included_files = try privGetCIncludedDependencies(c.allocator, content);
    defer {
        for (included_files) |inc_file|
            c.allocator.free(inc_file);
        c.allocator.free(included_files);
    }

    // Temporary add to the cache.
    try included_files_cache.?.put(cache_name, included_files);
    errdefer included_files_cache.?.clearEntry(cache_name);

    for (included_files) |inc_file| {
        var inc_found = false;
        for (c.include_dirs) |dir| {
            const path = try std.mem.concat(c.allocator, u8, &[_][]const u8{ dir[2..], inc_file });
            defer c.allocator.free(path);

            // Check if the file `path` exists
            const fp = std.fs.cwd().openFile(path, .{}) catch |err| if (err == error.FileNotFound) {
                continue;
            } else {
                return err;
            };
            defer fp.close();

            const dep_included = try getIncludedDependencies(c, path, inc_file);

            const duped_inc = try included_files_cache.?.cache.allocator.dupe(u8, path);
            errdefer included_files_cache.?.cache.allocator.free(duped_inc);
            try found.add(duped_inc);

            for (dep_included) |dep|
                try found.add(dep);

            // The file `inc_file` was found in `path`
            inc_found = true;
            break;
        }
        if (!inc_found) {
            try not_found.add(inc_file);
            if (!included_files_cache.?.contains(inc_file))
                try included_files_cache.?.put(inc_file, &[0][]const u8{});
        }
    }

    // Final add to the cache.
    const list_cache = try included_files_cache.?.cache.allocator.dupe([]const u8, found.args);
    errdefer included_files_cache.?.cache.allocator.free(list_cache);
    try included_files_cache.?.put(cache_name, list_cache);

    if (verbosity >= verb_debug) {
        std.debug.print("DEBUG: Dependencies of file \"{s}\": \"{s}\"\n", .{ cache_name, list_cache });
        if (not_found.args.len > 0)
            std.debug.print("DEBUG: Could not find \"{s}\": \"{s}\"\n", .{ cache_name, not_found.args });
    }

    return list_cache;
}

/// The caller must free the returned value.
pub fn buildSource(c: BuildConfig, src: []const u8, dependencies: anytype) ![]const u8 {
    if (verbosity >= verb_debug)
        std.debug.print("DEBUG: Building source file {s}\n", .{src});

    const short_src = shortenPath(src);
    const obj_noext = try std.fs.path.join(c.allocator, &.{ c.build_dir, "obj", short_src });
    defer c.allocator.free(obj_noext);
    const obj = try std.mem.concat(c.allocator, u8, &.{ obj_noext, c.obj_extension });
    errdefer c.allocator.free(obj);

    const included_depencies = try getIncludedDependencies(c, src, src);

    if (needsRebuild(obj, .{ src, dependencies, included_depencies })) {
        try createParentDirectory(obj);

        var cmd = try CmdLine.init(c.allocator);
        defer cmd.deinit();

        if (std.mem.eql(u8, std.fs.path.extension(src), ".c")) {
            try cmd.add(c.cc);
            try cmd.add(.{ "-c", "-o", obj, src });
            try cmd.add(c.cflags);
            try cmd.add(c.include_dirs);
            try cmd.executeSync();
        } else {
            std.debug.print("ERROR: Not implemented this file type \"{s}\"\n", .{src});
            std.os.exit(1);
        }
    }

    return obj;
}

/// The caller must free the returned value.
pub fn buildLibrary(c: BuildConfig, lib: []const u8, srcs: []const []const u8, dependencies: anytype) ![]const u8 {
    if (verbosity >= verb_debug)
        std.debug.print("DEBUG: Building library \"{s}\"\n", .{lib});

    const short_lib = shortenPath(lib);
    const lib_final_noext = try std.fs.path.join(c.allocator, &.{ c.build_dir, "lib", short_lib });
    defer c.allocator.free(lib_final_noext);
    const lib_final = try std.mem.concat(c.allocator, u8, &.{ lib_final_noext, c.lib_extension });
    errdefer c.allocator.free(lib_final);

    // Very careful to avoid unedessarily calling needsRebuild(), which can
    // reload the lib_final mtime into the cache before the build and cause
    // another unecessary rebuild.
    var needs_rebuild_dep = false;
    if (needsRebuild(lib_final, .{ srcs, dependencies })) {
        needs_rebuild_dep = true;
    } else {
        for (srcs) |src| {
            const included_depencies = try getIncludedDependencies(c, src, src);
            if (needsRebuild(lib_final, included_depencies)) {
                needs_rebuild_dep = true;
                break;
            }
        }
    }

    if (needs_rebuild_dep) {
        try createParentDirectory(lib_final);

        var objs = try CmdLine.init(c.allocator);
        defer {
            for (objs.args) |obj| c.allocator.free(obj);
            objs.deinit();
        }

        for (srcs) |src|
            try objs.add(try buildSource(c, src, dependencies));

        var cmd = try CmdLine.init(c.allocator);
        defer cmd.deinit();

        try cmd.add(c.ar);
        try cmd.add(.{ "-rcs", lib_final });
        try cmd.add(objs.args);
        try cmd.executeSync();
    }

    return lib_final;
}

/// The caller must free the returned value.
pub fn buildExecutable(c: BuildConfig, exe: []const u8, objs: []const []const u8, dependencies: anytype) ![]const u8 {
    if (verbosity >= verb_debug)
        std.debug.print("DEBUG: Building executable \"{s}\"\n", .{exe});

    const short_exe = shortenPath(exe);
    const exe_final_noext = try std.fs.path.join(c.allocator, &.{ c.build_dir, "bin", short_exe });
    defer c.allocator.free(exe_final_noext);
    const exe_final = try std.mem.concat(c.allocator, u8, &.{ exe_final_noext, c.exec_extension });
    errdefer c.allocator.free(exe_final);

    if (needsRebuild(exe_final, .{ objs, dependencies })) {
        var cmd = try CmdLine.init(c.allocator);
        defer cmd.deinit();
        try createParentDirectory(exe_final);

        try cmd.add(c.ld);
        try cmd.add(.{ "-o", exe_final });
        try cmd.add(c.ldflags);
        try cmd.add(objs);
        try cmd.executeSync();
    }

    return exe_final;
}
