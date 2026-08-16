//! Isolated downstream functionality for Stratty.
//!
//! Upstream Ghostty integration points should import this facade rather than
//! reaching into individual policy modules.

pub const controller = @import("stratty/controller.zig");
pub const commands = @import("stratty/commands.zig");
pub const lifecycle = @import("stratty/lifecycle.zig");
pub const labels = @import("stratty/labels.zig");
pub const linux_process = @import("stratty/linux_process.zig");
pub const workspace = @import("stratty/workspace.zig");

pub const Controller = controller.Controller;
pub const Role = controller.Role;
pub const Commands = controller.Commands;

test {
    _ = controller;
    _ = commands;
    _ = lifecycle;
    _ = labels;
    _ = linux_process;
    _ = workspace;
}
