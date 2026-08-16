//! Linux foreground process-group observation for compound Fish commands.

const std = @import("std");
const builtin = @import("builtin");

pub const Process = struct {
    pid: u64,
    comm: []u8,
    cmdline: []u8,
    cwd: []u8,

    fn deinit(self: *Process, allocator: std.mem.Allocator) void {
        allocator.free(self.comm);
        allocator.free(self.cmdline);
        allocator.free(self.cwd);
    }
};

pub const Processes = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Process) = .empty,

    pub fn deinit(self: *Processes) void {
        for (self.items.items) |*process| process.deinit(self.allocator);
        self.items.deinit(self.allocator);
    }
};

/// Return every process in the PTY's foreground process group. The PTY API
/// exposes a process-group ID on Linux, not necessarily the PID of every
/// pipeline member, so `/proc` must be inspected to retain pipeline behavior.
pub fn foregroundGroup(
    allocator: std.mem.Allocator,
    io: std.Io,
    process_group: u64,
) !Processes {
    var result: Processes = .{ .allocator = allocator };
    errdefer result.deinit();

    var proc = try std.Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true });
    defer proc.close(io);
    var iterator = proc.iterate();
    while (try iterator.next(io)) |entry| {
        const pid = std.fmt.parseInt(u64, entry.name, 10) catch continue;
        if ((processGroup(io, pid) catch continue) != process_group) continue;

        const comm = name(allocator, io, pid) catch try allocator.dupe(u8, "");
        errdefer allocator.free(comm);
        const cmdline = commandLine(allocator, io, pid) catch try allocator.dupe(u8, "");
        errdefer allocator.free(cmdline);
        const cwd = currentWorkingDirectory(allocator, io, pid) catch try allocator.dupe(u8, "");
        errdefer allocator.free(cwd);
        if (comm.len == 0 and cmdline.len == 0) {
            allocator.free(comm);
            allocator.free(cmdline);
            allocator.free(cwd);
            continue;
        }
        try result.items.append(allocator, .{
            .pid = pid,
            .comm = comm,
            .cmdline = cmdline,
            .cwd = cwd,
        });
    }

    std.mem.sort(Process, result.items.items, {}, struct {
        fn lessThan(_: void, left: Process, right: Process) bool {
            return left.pid < right.pid;
        }
    }.lessThan);
    return result;
}

/// Match in process/PID order and then Fish command order, preserving the old
/// Herdr selection semantics for pipelines and sequential commands.
pub fn matchCandidate(processes: []const Process, candidates: []const []u8) ?[]const u8 {
    for (processes) |process| {
        for (candidates) |candidate| {
            if (processMatchesCandidate(process, candidate)) return candidate;
        }
    }
    return null;
}

pub fn matchesExecutable(processes: []const Process, executable: []const u8) bool {
    for (processes) |process| {
        if (processMatchesCandidate(process, executable)) return true;
    }
    return false;
}

fn processMatchesCandidate(process: Process, candidate: []const u8) bool {
    if (pathMatches(process.comm, candidate)) return true;
    var arguments = std.mem.splitScalar(u8, process.cmdline, 0);
    while (arguments.next()) |argument| {
        if (pathMatches(argument, candidate)) return true;
    }
    return false;
}

fn pathMatches(raw_value: []const u8, raw_candidate: []const u8) bool {
    const value = std.mem.trimStart(u8, std.mem.trim(u8, raw_value, " \t\r\n"), "-");
    const candidate = std.fs.path.basename(std.mem.trim(u8, raw_candidate, " \t\r\n"));
    if (value.len == 0 or candidate.len == 0) return false;

    var parts = std.mem.splitScalar(u8, value, '/');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (std.mem.eql(u8, part, candidate)) return true;
        if (std.mem.lastIndexOfScalar(u8, part, '.')) |extension| {
            if (extension > 0 and std.mem.eql(u8, part[0..extension], candidate)) return true;
        }
    }
    return false;
}

fn name(
    allocator: std.mem.Allocator,
    io: std.Io,
    pid: u64,
) ![]u8 {
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/proc/{d}/comm", .{pid});
    const raw = try readProcFile(allocator, io, path, 4096);
    errdefer allocator.free(raw);
    const trimmed = normalized(raw);
    if (trimmed.ptr == raw.ptr and trimmed.len == raw.len) return raw;
    const result = try allocator.dupe(u8, trimmed);
    allocator.free(raw);
    return result;
}

fn commandLine(
    allocator: std.mem.Allocator,
    io: std.Io,
    pid: u64,
) ![]u8 {
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/proc/{d}/cmdline", .{pid});
    return readProcFile(allocator, io, path, 64 * 1024);
}

fn currentWorkingDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    pid: u64,
) ![]u8 {
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/proc/{d}/cwd", .{pid});
    var target_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const count = try std.Io.Dir.readLinkAbsolute(io, path, &target_buffer);
    return allocator.dupe(u8, target_buffer[0..count]);
}

fn normalized(raw: []const u8) []const u8 {
    return std.mem.trim(u8, raw, " \t\r\n");
}

fn readProcFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    max_bytes: usize,
) ![]u8 {
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);
    var buffer: [4096]u8 = undefined;
    while (true) {
        const count = file.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |value| return value,
        };
        if (count == 0) continue;
        if (count > max_bytes - result.items.len) return error.FileTooBig;
        try result.appendSlice(allocator, buffer[0..count]);
    }
    return result.toOwnedSlice(allocator);
}

fn processGroup(io: std.Io, pid: u64) !u64 {
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/proc/{d}/stat", .{pid});
    const raw = try readProcFile(std.heap.page_allocator, io, path, 16 * 1024);
    defer std.heap.page_allocator.free(raw);
    return parseProcessGroup(raw);
}

fn parseProcessGroup(stat: []const u8) !u64 {
    const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return error.InvalidProcStat;
    var fields = std.mem.tokenizeAny(u8, stat[close + 1 ..], " \t\r\n");
    _ = fields.next() orelse return error.InvalidProcStat; // state
    _ = fields.next() orelse return error.InvalidProcStat; // parent PID
    const group = fields.next() orelse return error.InvalidProcStat;
    return std.fmt.parseInt(u64, group, 10);
}

test "process names are trimmed" {
    try std.testing.expectEqualStrings("nvim", normalized("nvim\n"));
}

test "proc stat parser tolerates spaces and closing parentheses in command" {
    try std.testing.expectEqual(@as(u64, 77), try parseProcessGroup("42 (odd ) name) S 1 77 77 0"));
}

test "foreground group scan includes the calling Linux process" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const pid: u64 = @intCast(std.os.linux.getpid());
    const group = try processGroup(std.testing.io, pid);
    var processes = try foregroundGroup(std.testing.allocator, std.testing.io, group);
    defer processes.deinit();

    var found = false;
    for (processes.items.items) |process| {
        if (process.pid != pid) continue;
        found = true;
        try std.testing.expect(process.cwd.len > 0);
    }
    try std.testing.expect(found);
}

test "candidate matching inspects comm and every argv path component" {
    const allocator = std.testing.allocator;
    var processes = [_]Process{.{
        .pid = 20,
        .comm = try allocator.dupe(u8, "node"),
        .cmdline = try allocator.dupe(u8, "node\x00/nix/store/hash/nvim/cli.js\x00"),
        .cwd = try allocator.dupe(u8, "/repo"),
    }};
    defer processes[0].deinit(allocator);
    const candidates = [_][]u8{
        try allocator.dupe(u8, "sleep"),
        try allocator.dupe(u8, "nvim"),
    };
    defer for (candidates) |candidate| allocator.free(candidate);

    try std.testing.expectEqualStrings("nvim", matchCandidate(&processes, &candidates).?);
    try std.testing.expect(matchesExecutable(&processes, "/opt/editors/nvim"));
}
