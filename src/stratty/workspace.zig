//! Canonical Git-worktree identity with normalized-CWD fallback.

const std = @import("std");

pub const Resolver = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct {
        cwd: []u8,
        workspace: []u8,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Resolver {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Resolver) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.cwd);
            self.allocator.free(entry.workspace);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn resolve(self: *Resolver, cwd_raw: []const u8) ![]const u8 {
        const cwd = try canonicalPath(self.allocator, self.io, cwd_raw);
        errdefer self.allocator.free(cwd);

        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.cwd, cwd)) {
                self.allocator.free(cwd);
                return entry.workspace;
            }
        }

        const workspace = discoverGitRoot(self.allocator, self.io, cwd) catch
            try self.allocator.dupe(u8, cwd);
        errdefer self.allocator.free(workspace);
        try self.entries.append(self.allocator, .{ .cwd = cwd, .workspace = workspace });
        return workspace;
    }
};

fn discoverGitRoot(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8) ![]u8 {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "git", "-C", cwd, "rev-parse", "--show-toplevel" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    const stdout = child.stdout orelse return error.NoStdout;
    const output = readToEndAlloc(stdout, allocator, io, 64 * 1024) catch |err| {
        _ = child.wait(io) catch {};
        return err;
    };
    defer allocator.free(output);
    const result = try child.wait(io);
    switch (result) {
        .exited => |code| if (code != 0) return error.NotGitRepository,
        else => return error.GitFailed,
    }

    const root = std.mem.trim(u8, output, " \t\r\n");
    if (root.len == 0) return error.EmptyGitRoot;
    return canonicalPath(allocator, io, root);
}

fn readToEndAlloc(
    file: std.Io.File,
    allocator: std.mem.Allocator,
    io: std.Io,
    max_bytes: usize,
) ![]u8 {
    var read_buffer: [4096]u8 = undefined;
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);
    while (true) {
        const count = file.readStreaming(io, &.{&read_buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |other| return other,
        };
        if (count == 0) continue;
        if (count > max_bytes - result.items.len) return error.FileTooBig;
        try result.appendSlice(allocator, read_buffer[0..count]);
    }
    return result.toOwnedSlice(allocator);
}

fn canonicalPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const resolved = std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator) catch
        return allocator.dupe(u8, path);
    defer allocator.free(resolved);
    return allocator.dupe(u8, resolved);
}

test "workspace resolver groups nested directories by canonical Git root" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const nested = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(nested);
    const root = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    var resolver = Resolver.init(std.testing.allocator, std.testing.io);
    defer resolver.deinit();
    try std.testing.expectEqualStrings(root, try resolver.resolve(nested));
}

test "workspace resolver falls back to canonical non-Git cwd" {
    var resolver = Resolver.init(std.testing.allocator, std.testing.io);
    defer resolver.deinit();
    try std.testing.expectEqualStrings("/tmp", try resolver.resolve("/tmp"));
}
