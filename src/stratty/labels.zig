//! Stable workspace qualification and activity label formatting.

const std = @import("std");

pub const Labeler = struct {
    allocator: std.mem.Allocator,
    workspaces: std.ArrayList(Workspace) = .empty,

    const Workspace = struct {
        identity: []u8,
        label: []u8,
    };

    pub fn init(allocator: std.mem.Allocator) Labeler {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Labeler) void {
        for (self.workspaces.items) |workspace| {
            self.allocator.free(workspace.identity);
            self.allocator.free(workspace.label);
        }
        self.workspaces.deinit(self.allocator);
    }

    /// Existing assignments never change. A later basename collision receives
    /// the shortest unused parent-qualified suffix.
    pub fn workspaceLabel(self: *Labeler, identity: []const u8) ![]const u8 {
        for (self.workspaces.items) |workspace| {
            if (std.mem.eql(u8, workspace.identity, identity)) return workspace.label;
        }

        const trimmed = trimPath(identity);
        var depth: usize = 1;
        var label: []u8 = undefined;
        while (true) : (depth += 1) {
            label = try suffixComponents(self.allocator, trimmed, depth);
            if (!self.labelExists(label)) break;
            self.allocator.free(label);
        }
        errdefer self.allocator.free(label);

        try self.workspaces.append(self.allocator, .{
            .identity = try self.allocator.dupe(u8, identity),
            .label = label,
        });
        return label;
    }

    pub fn format(
        self: *Labeler,
        workspace: []const u8,
        activity: []const u8,
        duplicate_index: ?usize,
    ) ![:0]u8 {
        const label = try self.workspaceLabel(workspace);
        return if (duplicate_index) |index|
            std.fmt.allocPrintSentinel(
                self.allocator,
                "{s} · {s} ({d})",
                .{ label, activity, index },
                0,
            )
        else
            std.fmt.allocPrintSentinel(
                self.allocator,
                "{s} · {s}",
                .{ label, activity },
                0,
            );
    }

    fn labelExists(self: *const Labeler, candidate: []const u8) bool {
        for (self.workspaces.items) |workspace| {
            if (std.mem.eql(u8, workspace.label, candidate)) return true;
        }
        return false;
    }
};

fn trimPath(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    return if (trimmed.len == 0) path else trimmed;
}

fn suffixComponents(allocator: std.mem.Allocator, path: []const u8, count: usize) ![]u8 {
    var start = path.len;
    var seen: usize = 0;
    while (start > 0 and seen < count) {
        start -= 1;
        if (path[start] == '/') {
            if (start + 1 < path.len) seen += 1;
            if (seen == count) {
                start += 1;
                break;
            }
        }
    }
    if (seen < count) start = 0;
    const result = std.mem.trimStart(u8, path[start..], "/");
    return allocator.dupe(u8, if (result.len > 0) result else "/");
}

test "later same-named workspaces receive stable shortest qualification" {
    var labeler = Labeler.init(std.testing.allocator);
    defer labeler.deinit();

    try std.testing.expectEqualStrings("stratty", try labeler.workspaceLabel("/work/stratty"));
    try std.testing.expectEqualStrings("clones/stratty", try labeler.workspaceLabel("/home/clones/stratty"));
    try std.testing.expectEqualStrings("other/stratty", try labeler.workspaceLabel("/tmp/other/stratty"));
    try std.testing.expectEqualStrings("stratty", try labeler.workspaceLabel("/work/stratty"));
}

test "duplicate activity labels are numbered by caller supplied rank" {
    var labeler = Labeler.init(std.testing.allocator);
    defer labeler.deinit();

    const first = try labeler.format("/work/stratty", "shell", 1);
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("stratty · shell (1)", first);
}
