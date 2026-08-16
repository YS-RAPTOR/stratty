//! Parsing for Stratty metadata carried as OSC 133 options.

const std = @import("std");
const string_encoding = @import("../os/string_encoding.zig");
const commands_mod = @import("commands.zig");
const controller = @import("controller.zig");

const command_candidate_limit = 64;

pub const Metadata = struct {
    owner: ?[]const u8,
    generation: ?u64,
    tokens_encoded: ?[]const u8,
};

pub fn metadata(raw: []const u8) Metadata {
    return .{
        .owner = option(raw, "stratty_owner"),
        .generation = if (option(raw, "stratty_generation")) |value|
            std.fmt.parseInt(u64, value, 10) catch null
        else
            null,
        .tokens_encoded = option(raw, "stratty_tokens"),
    };
}

/// An owned command classification. Compound commands retain every executable
/// candidate so foreground-process observation can follow the command that is
/// actually running rather than guessing from the first token.
pub const OwnedActivity = struct {
    allocator: std.mem.Allocator,
    role: controller.Role,
    command: []u8,
    compound: bool = false,
    candidates: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *OwnedActivity) void {
        self.allocator.free(self.command);
        for (self.candidates.items) |candidate| self.allocator.free(candidate);
        self.candidates.deinit(self.allocator);
    }

    pub fn value(self: *const OwnedActivity) controller.Activity {
        return .{ .role = self.role, .command = self.command };
    }
};

pub fn activity(
    allocator: std.mem.Allocator,
    raw: []const u8,
    commands: controller.Commands,
) !OwnedActivity {
    const encoded = metadata(raw).tokens_encoded orelse return shellActivity(allocator);
    var tokens: std.ArrayList([]u8) = .empty;
    defer {
        for (tokens.items) |token| allocator.free(token);
        tokens.deinit(allocator);
    }

    var iterator = std.mem.splitScalar(u8, encoded, ',');
    while (iterator.next()) |token| {
        var decoded: std.Io.Writer.Allocating = .init(allocator);
        errdefer decoded.deinit();
        string_encoding.urlPercentDecode(&decoded.writer, token) catch continue;
        try tokens.append(allocator, try decoded.toOwnedSlice());
    }

    var parsed = try parseCommandTokens(allocator, tokens.items);
    errdefer parsed.deinit(allocator);
    const executable = if (parsed.candidates.items.len > 0)
        parsed.candidates.items[0]
    else
        return shellActivity(allocator);

    return .{
        .allocator = allocator,
        .role = commands_mod.classifyExecutable(executable, commands),
        .command = try allocator.dupe(u8, executable),
        .compound = parsed.compound,
        .candidates = parsed.candidates,
    };
}

const ParsedCommand = struct {
    compound: bool = false,
    candidates: std.ArrayList([]u8) = .empty,

    fn deinit(self: *ParsedCommand, allocator: std.mem.Allocator) void {
        for (self.candidates.items) |candidate| allocator.free(candidate);
        self.candidates.deinit(allocator);
    }
};

fn parseCommandTokens(allocator: std.mem.Allocator, tokens: []const []const u8) !ParsedCommand {
    var parsed: ParsedCommand = .{};
    errdefer parsed.deinit(allocator);

    var expect_command = true;
    var decorator = false;
    var skip_redirection_target = false;
    var skip_until_separator = false;

    for (tokens) |token| {
        if (isSeparator(token)) {
            parsed.compound = true;
            expect_command = true;
            decorator = false;
            skip_redirection_target = false;
            skip_until_separator = false;
            continue;
        }
        if (skip_until_separator) continue;
        if (!expect_command) continue;
        if (skip_redirection_target) {
            skip_redirection_target = false;
            continue;
        }
        if (isRedirection(token)) {
            skip_redirection_target = redirectionNeedsTarget(token);
            continue;
        }
        if (isControl(token)) {
            parsed.compound = true;
            skip_until_separator = skipsUntilSeparator(token);
            continue;
        }
        if (isAssignment(token)) continue;
        if (isDecorator(token)) {
            decorator = true;
            continue;
        }
        if (decorator and token.len > 0 and token[0] == '-') continue;

        const candidate = normalizeCandidate(token) orelse {
            expect_command = false;
            continue;
        };
        if (!containsCandidate(parsed.candidates.items, candidate) and
            parsed.candidates.items.len < command_candidate_limit)
        {
            const owned = try allocator.dupe(u8, candidate);
            errdefer allocator.free(owned);
            try parsed.candidates.append(allocator, owned);
        }
        expect_command = false;
    }

    return parsed;
}

fn shellActivity(allocator: std.mem.Allocator) !OwnedActivity {
    return .{
        .allocator = allocator,
        .role = .shell,
        .command = try allocator.dupe(u8, controller.Activity.shell.command),
    };
}

fn containsCandidate(candidates: []const []u8, candidate: []const u8) bool {
    for (candidates) |current| {
        if (std.mem.eql(u8, current, candidate)) return true;
    }
    return false;
}

fn normalizeCandidate(token: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, token, " \t\r\n");
    const command = std.mem.trimStart(u8, trimmed, "-");
    if (command.len == 0 or command.len > 255) return null;
    if (std.mem.indexOfAny(u8, command, "$(){}*?[]") != null) return null;
    return std.fs.path.basename(command);
}

fn option(raw: []const u8, key: []const u8) ?[]const u8 {
    var remaining = raw;
    while (remaining.len > 0) {
        const length = std.mem.indexOfScalar(u8, remaining, ';') orelse remaining.len;
        const field = remaining[0..length];
        if (std.mem.indexOfScalar(u8, field, '=')) |equals| {
            if (std.mem.eql(u8, field[0..equals], key)) return field[equals + 1 ..];
        }
        if (length == remaining.len) break;
        remaining = remaining[length + 1 ..];
    }
    return null;
}

fn isAssignment(token: []const u8) bool {
    const equals = std.mem.indexOfScalar(u8, token, '=') orelse return false;
    if (equals == 0) return false;
    for (token[0..equals], 0..) |byte, index| {
        const letter = std.ascii.isAlphabetic(byte);
        const digit = std.ascii.isDigit(byte);
        if (!letter and byte != '_' and (index == 0 or !digit)) return false;
    }
    return true;
}

fn isSeparator(token: []const u8) bool {
    return std.mem.eql(u8, token, ";") or
        std.mem.eql(u8, token, "&") or
        std.mem.eql(u8, token, "&&") or
        std.mem.eql(u8, token, "||") or
        std.mem.eql(u8, token, "|") or
        std.mem.eql(u8, token, "|&") or
        std.mem.eql(u8, token, "\n");
}

fn isControl(token: []const u8) bool {
    return std.mem.eql(u8, token, "and") or
        std.mem.eql(u8, token, "or") or
        std.mem.eql(u8, token, "if") or
        std.mem.eql(u8, token, "else") or
        std.mem.eql(u8, token, "while") or
        std.mem.eql(u8, token, "for") or
        std.mem.eql(u8, token, "switch") or
        std.mem.eql(u8, token, "case") or
        std.mem.eql(u8, token, "function") or
        std.mem.eql(u8, token, "begin") or
        std.mem.eql(u8, token, "end");
}

fn skipsUntilSeparator(token: []const u8) bool {
    return std.mem.eql(u8, token, "for") or
        std.mem.eql(u8, token, "switch") or
        std.mem.eql(u8, token, "case") or
        std.mem.eql(u8, token, "function");
}

fn isDecorator(token: []const u8) bool {
    return std.mem.eql(u8, token, "command") or
        std.mem.eql(u8, token, "builtin") or
        std.mem.eql(u8, token, "exec") or
        std.mem.eql(u8, token, "env") or
        std.mem.eql(u8, token, "sudo") or
        std.mem.eql(u8, token, "time") or
        std.mem.eql(u8, token, "nice") or
        std.mem.eql(u8, token, "nohup") or
        std.mem.eql(u8, token, "not");
}

fn isRedirection(token: []const u8) bool {
    return std.mem.indexOfAny(u8, token, "<>") != null or
        std.mem.eql(u8, token, "^") or
        std.mem.eql(u8, token, "^^");
}

fn redirectionNeedsTarget(token: []const u8) bool {
    const left = std.mem.lastIndexOfScalar(u8, token, '<');
    const right = std.mem.lastIndexOfScalar(u8, token, '>');
    const operator = if (left == null) right else if (right == null) left else @max(left.?, right.?);
    const index = operator orelse return std.mem.eql(u8, token, "^") or std.mem.eql(u8, token, "^^");
    const suffix = token[index + 1 ..];
    return suffix.len == 0 or std.mem.eql(u8, suffix, "|");
}

test "metadata reads owner generation and token payload" {
    const value = metadata("stratty_owner=42;stratty_generation=7;stratty_tokens=%2Fbin%2Fnvim");
    try std.testing.expectEqualStrings("42", value.owner.?);
    try std.testing.expectEqual(@as(u64, 7), value.generation.?);
    try std.testing.expectEqualStrings("%2Fbin%2Fnvim", value.tokens_encoded.?);
}

test "activity recognizes configured executable paths" {
    var value = try activity(
        std.testing.allocator,
        "stratty_tokens=env,FOO%3Dbar,%2Fnix%2Fstore%2Fhash%2Fbin%2Fpi",
        .{},
    );
    defer value.deinit();
    try std.testing.expectEqual(controller.Role.agent, value.role);
    try std.testing.expectEqualStrings("pi", value.command);
}

test "compound commands preserve every executable candidate" {
    var value = try activity(
        std.testing.allocator,
        "stratty_tokens=sleep,5,%3B,and,nvim,README.md",
        .{},
    );
    defer value.deinit();
    try std.testing.expect(value.compound);
    try std.testing.expectEqual(@as(usize, 2), value.candidates.items.len);
    try std.testing.expectEqualStrings("sleep", value.candidates.items[0]);
    try std.testing.expectEqualStrings("nvim", value.candidates.items[1]);
}

test "parser handles pipelines controls and redirections" {
    const tokens = [_][]const u8{
        ">",   "/tmp/log", "if",   "test", "-e",   "README.md", ";",
        "env", "A=1",      "nvim", "|",    "less", ";",         "end",
    };
    var parsed = try parseCommandTokens(std.testing.allocator, &tokens);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expect(parsed.compound);
    try std.testing.expectEqual(@as(usize, 3), parsed.candidates.items.len);
    try std.testing.expectEqualStrings("test", parsed.candidates.items[0]);
    try std.testing.expectEqualStrings("nvim", parsed.candidates.items[1]);
    try std.testing.expectEqualStrings("less", parsed.candidates.items[2]);
}
