const std = @import("std");

pub const Capture = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: Capture, a: std.mem.Allocator) void {
        a.free(self.stdout);
        a.free(self.stderr);
    }
};

pub fn invoke(
    a: std.mem.Allocator,
    io: std.Io,
    parent_env: *const std.process.Environ.Map,
    executable: []const u8,
    args: []const []const u8,
    library_dirs: []const []const u8,
    stdin_bytes: ?[]const u8,
) !Capture {
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.putAll(parent_env);
    try isolatePath(a, &env, library_dirs);

    var argv = try a.alloc([]const u8, args.len + 1);
    defer a.free(argv);
    argv[0] = executable;
    @memcpy(argv[1..], args);

    if (stdin_bytes == null) {
        const result = try std.process.run(a, io, .{
            .argv = argv,
            .environ_map = &env,
            .stdout_limit = .limited(16 * 1024 * 1024),
            .stderr_limit = .limited(16 * 1024 * 1024),
        });
        return .{ .term = result.term, .stdout = result.stdout, .stderr = result.stderr };
    }

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .environ_map = &env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
    });
    defer child.kill(io);

    const input = stdin_bytes.?;
    try child.stdin.?.writeStreamingAll(io, input);
    child.stdin.?.close(io);
    child.stdin = null;

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(a, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();
    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    while (multi_reader.fill(4096, .none)) |_| {
        if (stdout_reader.buffered().len > 16 * 1024 * 1024 or stderr_reader.buffered().len > 16 * 1024 * 1024) return error.WorkerOutputTooLarge;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |other| return other,
    }
    try multi_reader.checkAnyError();
    const term = try child.wait(io);
    const stdout = try multi_reader.toOwnedSlice(0);
    errdefer a.free(stdout);
    const stderr = try multi_reader.toOwnedSlice(1);
    return .{ .term = term, .stdout = stdout, .stderr = stderr };
}

fn isolatePath(a: std.mem.Allocator, env: *std.process.Environ.Map, dirs: []const []const u8) !void {
    if (dirs.len == 0) return;
    var total: usize = 0;
    for (dirs, 0..) |dir, i| total += dir.len + @intFromBool(i + 1 < dirs.len);
    var value = try a.alloc(u8, total);
    defer a.free(value);
    var cursor: usize = 0;
    for (dirs, 0..) |dir, i| {
        @memcpy(value[cursor..][0..dir.len], dir);
        cursor += dir.len;
        if (i + 1 < dirs.len) {
            value[cursor] = ';';
            cursor += 1;
        }
    }
    try env.put("PATH", value);
}

pub fn successful(term: std.process.Child.Term) bool {
    return term.success();
}

test "exit term success is strict" {
    try std.testing.expect(successful(.{ .exited = 0 }));
    try std.testing.expect(!successful(.{ .exited = 7 }));
}

test "child PATH contains only selected library directories" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PATH", "C:\\runtime\\cuda;C:\\runtime\\cpu;C:\\other");
    try isolatePath(std.testing.allocator, &env, &.{ "C:\\package\\runtime\\cpu", "C:\\explicit" });
    try std.testing.expectEqualStrings("C:\\package\\runtime\\cpu;C:\\explicit", env.get("PATH").?);
}
