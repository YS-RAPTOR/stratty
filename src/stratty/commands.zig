//! Stratty role command configuration.
//!
//! Commands are inherited from the application environment. They are not
//! copied from a live terminal surface.

const std = @import("std");
const controller = @import("controller.zig");

pub const editor_environment_variable = "EDITOR";
pub const agent_environment_variable = "AGENT";

pub fn fromEnvironment(environment: *const std.process.Environ.Map) controller.Commands {
    return .{
        .editor = validCommand(environment.get(editor_environment_variable)) orelse "nvim",
        .agent = validCommand(environment.get(agent_environment_variable)) orelse "pi",
    };
}

/// The first implementation intentionally accepts one executable token rather
/// than evaluating an arbitrary shell fragment. Paths are supported.
pub fn validCommand(value: ?[]const u8) ?[]const u8 {
    const command = value orelse return null;
    if (command.len == 0) return null;
    for (command) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.', '/', '+', ':' => {},
        else => return null,
    };
    return command;
}

pub fn classifyExecutable(executable: []const u8, commands: controller.Commands) controller.Role {
    const actual = std.fs.path.basename(executable);
    if (std.mem.eql(u8, actual, std.fs.path.basename(commands.editor))) return .editor;
    if (std.mem.eql(u8, actual, std.fs.path.basename(commands.agent))) return .agent;
    return .shell;
}

test "environment commands default to nvim and pi" {
    var environment: std.process.Environ.Map = .init(std.testing.allocator);
    defer environment.deinit();

    const commands = fromEnvironment(&environment);
    try std.testing.expectEqualStrings("nvim", commands.editor);
    try std.testing.expectEqualStrings("pi", commands.agent);
}

test "environment commands accept executable names and paths" {
    var environment: std.process.Environ.Map = .init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("EDITOR", "/opt/editors/hx");
    try environment.put("AGENT", "codex");

    const commands = fromEnvironment(&environment);
    try std.testing.expectEqualStrings("/opt/editors/hx", commands.editor);
    try std.testing.expectEqualStrings("codex", commands.agent);
    try std.testing.expectEqual(controller.Role.editor, classifyExecutable("/opt/editors/hx", commands));
    try std.testing.expectEqual(controller.Role.agent, classifyExecutable("/nix/store/hash/bin/codex", commands));
}

test "invalid environment commands use safe defaults" {
    var environment: std.process.Environ.Map = .init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("EDITOR", "nvim --clean");
    try environment.put("AGENT", "pi\nother-command");

    const commands = fromEnvironment(&environment);
    try std.testing.expectEqualStrings("nvim", commands.editor);
    try std.testing.expectEqualStrings("pi", commands.agent);
}
