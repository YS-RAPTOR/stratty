//! Window-local contextual tab policy for Stratty.
//!
//! This module deliberately has no GTK, terminal, process, or Git dependencies.
//! Adapters report resolved facts and apply the effects returned by the controller.

const std = @import("std");

pub const SurfaceId = u64;
pub const CreationSequence = u64;
pub const PendingId = u64;

pub const Role = enum {
    shell,
    editor,
    agent,

    pub fn command(self: Role, commands: Commands) ?[]const u8 {
        return switch (self) {
            .shell => null,
            .editor => commands.editor,
            .agent => commands.agent,
        };
    }
};

pub const Commands = struct {
    editor: []const u8 = "nvim",
    agent: []const u8 = "pi",
};

pub const Status = enum {
    idle,
    running,
};

pub const Activity = struct {
    role: Role,
    command: []const u8,

    pub const shell: Activity = .{ .role = .shell, .command = "shell" };
};

pub const AddSurface = struct {
    id: SurfaceId,
    cwd: []const u8,
    workspace: []const u8,
};

pub const Create = struct {
    pending_id: PendingId,
    role: Role,
    cwd: []const u8,
    workspace: []const u8,
};

pub const Effect = union(enum) {
    none,
    focus: SurfaceId,
    create: Create,
};

pub const QueueInput = struct {
    surface_id: SurfaceId,
    command: []const u8,
};

pub const Presentation = struct {
    workspace: []const u8,
    cwd: []const u8,
    activity: []const u8,
    role: Role,
    status: Status,
    creation_sequence: CreationSequence,
};

const LaunchPhase = enum {
    waiting_for_prompt,
    input_queued,
    command_started,
};

const Owner = struct {
    id: []u8,
    generation: u64,
    active: bool,

    fn deinit(self: *Owner, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
    }
};

const Surface = struct {
    id: SurfaceId,
    creation_sequence: CreationSequence,
    cwd: []u8,
    workspace: []u8,
    activity_command: []u8,
    role: Role = .shell,
    agent_status: ?Status = null,
    pending_id: ?PendingId = null,
    owners: std.ArrayList(Owner) = .empty,

    fn deinit(self: *Surface, allocator: std.mem.Allocator) void {
        allocator.free(self.cwd);
        allocator.free(self.workspace);
        allocator.free(self.activity_command);
        for (self.owners.items) |*owner| owner.deinit(allocator);
        self.owners.deinit(allocator);
    }
};

const Pending = struct {
    id: PendingId,
    role: Role,
    workspace: []u8,
    surface_id: ?SurfaceId = null,
    phase: LaunchPhase = .waiting_for_prompt,

    fn deinit(self: *Pending, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace);
    }
};

pub const Controller = struct {
    allocator: std.mem.Allocator,
    commands: Commands,
    surfaces: std.ArrayList(Surface) = .empty,
    pending: std.ArrayList(Pending) = .empty,
    selected: ?SurfaceId = null,
    next_creation_sequence: CreationSequence = 1,
    next_pending_id: PendingId = 1,

    pub fn init(allocator: std.mem.Allocator) Controller {
        return initWithCommands(allocator, .{});
    }

    pub fn initWithCommands(allocator: std.mem.Allocator, commands: Commands) Controller {
        return .{ .allocator = allocator, .commands = commands };
    }

    pub fn deinit(self: *Controller) void {
        for (self.surfaces.items) |*surface| surface.deinit(self.allocator);
        self.surfaces.deinit(self.allocator);
        for (self.pending.items) |*pending| pending.deinit(self.allocator);
        self.pending.deinit(self.allocator);
    }

    pub fn addSurface(self: *Controller, input: AddSurface) !CreationSequence {
        if (self.surfaceIndex(input.id) != null) return error.DuplicateSurface;

        const cwd = try self.allocator.dupe(u8, input.cwd);
        errdefer self.allocator.free(cwd);
        const workspace = try self.allocator.dupe(u8, input.workspace);
        errdefer self.allocator.free(workspace);
        const activity = try self.allocator.dupe(u8, Activity.shell.command);
        errdefer self.allocator.free(activity);

        const sequence = self.next_creation_sequence;
        self.next_creation_sequence += 1;
        try self.surfaces.append(self.allocator, .{
            .id = input.id,
            .creation_sequence = sequence,
            .cwd = cwd,
            .workspace = workspace,
            .activity_command = activity,
        });
        return sequence;
    }

    pub fn attachPendingSurface(
        self: *Controller,
        pending_id: PendingId,
        input: AddSurface,
    ) !CreationSequence {
        const pending_index = self.pendingIndex(pending_id) orelse
            return error.UnknownPendingTarget;
        if (!std.mem.eql(u8, self.pending.items[pending_index].workspace, input.workspace))
            return error.WorkspaceMismatch;

        const sequence = try self.addSurface(input);
        try self.bindPendingSurface(pending_id, input.id);
        return sequence;
    }

    pub fn bindPendingSurface(self: *Controller, pending_id: PendingId, surface_id: SurfaceId) !void {
        const pending_index = self.pendingIndex(pending_id) orelse
            return error.UnknownPendingTarget;
        const surface_index = self.surfaceIndex(surface_id) orelse return error.UnknownSurface;
        if (!std.mem.eql(
            u8,
            self.pending.items[pending_index].workspace,
            self.surfaces.items[surface_index].workspace,
        )) return error.WorkspaceMismatch;

        self.surfaces.items[surface_index].pending_id = pending_id;
        self.pending.items[pending_index].surface_id = surface_id;
        self.selected = surface_id;
    }

    pub fn removeSurface(self: *Controller, id: SurfaceId) void {
        const index = self.surfaceIndex(id) orelse return;
        const pending_id = self.surfaces.items[index].pending_id;
        var removed = self.surfaces.orderedRemove(index);
        removed.deinit(self.allocator);
        if (pending_id) |value| self.clearPending(value);
        if (self.selected == id) self.selected = null;
    }

    pub fn selectSurface(self: *Controller, id: SurfaceId) !void {
        if (self.surfaceIndex(id) == null) return error.UnknownSurface;
        self.selected = id;
    }

    pub fn updateLocation(
        self: *Controller,
        id: SurfaceId,
        cwd: []const u8,
        workspace: []const u8,
    ) !void {
        const surface = self.getSurface(id) orelse return error.UnknownSurface;
        const new_cwd = try self.allocator.dupe(u8, cwd);
        errdefer self.allocator.free(new_cwd);
        const new_workspace = try self.allocator.dupe(u8, workspace);
        errdefer self.allocator.free(new_workspace);

        self.allocator.free(surface.cwd);
        self.allocator.free(surface.workspace);
        surface.cwd = new_cwd;
        surface.workspace = new_workspace;
    }

    /// Focus the oldest eligible target, or atomically reserve a pending
    /// creation before returning a create effect.
    pub fn requestRole(self: *Controller, requested: Role) !Effect {
        const selected_id = self.selected orelse return .none;
        const selected = self.getSurface(selected_id) orelse return .none;
        const workspace = selected.workspace;

        var oldest: ?*const Surface = null;
        for (self.surfaces.items) |*candidate| {
            if (!std.mem.eql(u8, self.effectiveWorkspace(candidate), workspace)) continue;
            if (self.effectiveRole(candidate) != requested) continue;
            if (oldest == null or candidate.creation_sequence < oldest.?.creation_sequence) {
                oldest = candidate;
            }
        }

        if (oldest) |target| {
            if (target.id == selected_id) return .none;
            self.selected = target.id;
            return .{ .focus = target.id };
        }

        // An unattached reservation can exist only during the synchronous gap
        // between returning create and the GTK adapter attaching the new page.
        for (self.pending.items) |pending| {
            if (pending.role == requested and
                std.mem.eql(u8, pending.workspace, workspace)) return .none;
        }

        const pending_workspace = try self.allocator.dupe(u8, workspace);
        errdefer self.allocator.free(pending_workspace);
        const pending_id = self.next_pending_id;
        self.next_pending_id += 1;
        try self.pending.append(self.allocator, .{
            .id = pending_id,
            .role = requested,
            .workspace = pending_workspace,
        });

        return .{ .create = .{
            .pending_id = pending_id,
            .role = requested,
            .cwd = selected.cwd,
            .workspace = pending_workspace,
        } };
    }

    /// Report the first idle prompt for a pending target. Editor and agent
    /// commands are queued only now, after normal Fish and direnv startup.
    pub fn promptReady(self: *Controller, id: SurfaceId) ?QueueInput {
        const surface = self.getSurface(id) orelse return null;
        const pending_id = surface.pending_id orelse {
            self.setActivity(surface, .shell) catch {};
            return null;
        };
        const pending_index = self.pendingIndex(pending_id) orelse return null;
        const pending = &self.pending.items[pending_index];

        if (pending.role == .shell) {
            self.setActivity(surface, .shell) catch {};
            self.clearPending(pending_id);
            return null;
        }
        if (pending.phase != .waiting_for_prompt) return null;

        pending.phase = .input_queued;
        return .{
            .surface_id = id,
            .command = pending.role.command(self.commands).?,
        };
    }

    pub fn commandStarted(self: *Controller, id: SurfaceId, activity: Activity) !void {
        const surface = self.getSurface(id) orelse return error.UnknownSurface;
        try self.setActivity(surface, activity);

        const pending_id = surface.pending_id orelse return;
        const pending_index = self.pendingIndex(pending_id) orelse return;
        self.pending.items[pending_index].phase = .command_started;
        if (activity.role == self.pending.items[pending_index].role) {
            self.clearPending(pending_id);
        }
    }

    pub fn commandEnded(self: *Controller, id: SurfaceId) !void {
        const surface = self.getSurface(id) orelse return error.UnknownSurface;
        const pending_id = surface.pending_id;
        try self.setActivity(surface, .shell);
        if (pending_id) |value| self.clearPending(value);
    }

    /// Agent lifecycle reports override the foreground-process fallback while
    /// an agent owns the surface. Reports from shells and editors are ignored.
    pub fn agentStatus(self: *Controller, id: SurfaceId, status: Status) !bool {
        const surface = self.getSurface(id) orelse return error.UnknownSurface;
        if (self.effectiveRole(surface) != .agent) return false;
        if (surface.agent_status == status) return false;
        surface.agent_status = status;
        return true;
    }

    /// Returns false for stale or duplicate lifecycle reports. Once a new
    /// owner is observed, reports from a retired owner can never become active
    /// again on that surface.
    pub fn acceptLifecycle(
        self: *Controller,
        id: SurfaceId,
        owner_id: []const u8,
        generation: u64,
    ) !bool {
        const surface = self.getSurface(id) orelse return error.UnknownSurface;
        for (surface.owners.items) |*owner| {
            if (!std.mem.eql(u8, owner.id, owner_id)) continue;
            if (!owner.active or generation <= owner.generation) return false;
            owner.generation = generation;
            return true;
        }

        for (surface.owners.items) |*owner| owner.active = false;
        try surface.owners.append(self.allocator, .{
            .id = try self.allocator.dupe(u8, owner_id),
            .generation = generation,
            .active = true,
        });
        return true;
    }

    pub fn creationSequence(self: *const Controller, id: SurfaceId) ?CreationSequence {
        const index = self.surfaceIndex(id) orelse return null;
        return self.surfaces.items[index].creation_sequence;
    }

    pub fn role(self: *const Controller, id: SurfaceId) ?Role {
        const index = self.surfaceIndex(id) orelse return null;
        return self.effectiveRole(&self.surfaces.items[index]);
    }

    pub fn pendingCount(self: *const Controller) usize {
        return self.pending.items.len;
    }

    pub fn surfaceCount(self: *const Controller) usize {
        return self.surfaces.items.len;
    }

    pub fn surfaceIdAt(self: *const Controller, index: usize) ?SurfaceId {
        if (index >= self.surfaces.items.len) return null;
        return self.surfaces.items[index].id;
    }

    pub fn presentation(self: *const Controller, id: SurfaceId) ?Presentation {
        const surface_index = self.surfaceIndex(id) orelse return null;
        const surface = &self.surfaces.items[surface_index];
        const activity = activity: {
            const pending_id = surface.pending_id orelse break :activity surface.activity_command;
            const pending_index = self.pendingIndex(pending_id) orelse break :activity surface.activity_command;
            const pending = self.pending.items[pending_index];
            if (pending.phase == .command_started) break :activity surface.activity_command;
            break :activity std.fs.path.basename(pending.role.command(self.commands) orelse "shell");
        };
        const effective_role = self.effectiveRole(surface);
        return .{
            .workspace = self.effectiveWorkspace(surface),
            .cwd = surface.cwd,
            .activity = activity,
            .role = effective_role,
            .status = if (effective_role == .agent)
                surface.agent_status orelse .running
            else if (std.mem.eql(u8, activity, Activity.shell.command))
                .idle
            else
                .running,
            .creation_sequence = surface.creation_sequence,
        };
    }

    fn setActivity(self: *Controller, surface: *Surface, activity: Activity) !void {
        const changed = surface.role != activity.role or
            !std.mem.eql(u8, surface.activity_command, activity.command);
        const command = try self.allocator.dupe(u8, activity.command);
        self.allocator.free(surface.activity_command);
        surface.activity_command = command;
        surface.role = activity.role;
        if (changed) surface.agent_status = null;
    }

    fn clearPending(self: *Controller, id: PendingId) void {
        const index = self.pendingIndex(id) orelse return;
        if (self.pending.items[index].surface_id) |surface_id| {
            if (self.getSurface(surface_id)) |surface| surface.pending_id = null;
        }
        var removed = self.pending.orderedRemove(index);
        removed.deinit(self.allocator);
    }

    fn effectiveWorkspace(self: *const Controller, surface: *const Surface) []const u8 {
        const pending_id = surface.pending_id orelse return surface.workspace;
        const index = self.pendingIndex(pending_id) orelse return surface.workspace;
        return self.pending.items[index].workspace;
    }

    fn effectiveRole(self: *const Controller, surface: *const Surface) Role {
        const pending_id = surface.pending_id orelse return surface.role;
        const index = self.pendingIndex(pending_id) orelse return surface.role;
        return self.pending.items[index].role;
    }

    fn getSurface(self: *Controller, id: SurfaceId) ?*Surface {
        const index = self.surfaceIndex(id) orelse return null;
        return &self.surfaces.items[index];
    }

    fn surfaceIndex(self: *const Controller, id: SurfaceId) ?usize {
        for (self.surfaces.items, 0..) |surface, index| {
            if (surface.id == id) return index;
        }
        return null;
    }

    fn pendingIndex(self: *const Controller, id: PendingId) ?usize {
        for (self.pending.items, 0..) |pending, index| {
            if (pending.id == id) return index;
        }
        return null;
    }
};

fn add(
    controller: *Controller,
    id: SurfaceId,
    cwd: []const u8,
    workspace: []const u8,
) !void {
    _ = try controller.addSurface(.{ .id = id, .cwd = cwd, .workspace = workspace });
}

test "focus is isolated by workspace and chooses immutable creation age" {
    var controller = Controller.init(std.testing.allocator);
    defer controller.deinit();

    try add(&controller, 1, "/repo/src", "/repo");
    try add(&controller, 2, "/repo/docs", "/repo");
    try add(&controller, 3, "/other", "/other");
    try controller.commandStarted(2, .{ .role = .editor, .command = "nvim" });
    try controller.commandStarted(3, .{ .role = .editor, .command = "nvim" });
    try controller.selectSurface(1);

    try std.testing.expectEqual(Effect{ .focus = 2 }, try controller.requestRole(.editor));
    try std.testing.expectEqual(Effect.none, try controller.requestRole(.editor));
}

test "oldest role wins independently of insertion position changes" {
    var controller = Controller.init(std.testing.allocator);
    defer controller.deinit();

    try add(&controller, 10, "/repo", "/repo");
    try add(&controller, 20, "/repo", "/repo");
    try add(&controller, 30, "/repo", "/repo");
    try controller.commandStarted(20, .{ .role = .agent, .command = "pi" });
    try controller.commandStarted(30, .{ .role = .agent, .command = "pi" });
    try controller.selectSurface(10);

    try std.testing.expectEqual(Effect{ .focus = 20 }, try controller.requestRole(.agent));
    try std.testing.expect(controller.creationSequence(20).? < controller.creationSequence(30).?);
}

test "creation reserves pending target before the tab exists" {
    var controller = Controller.init(std.testing.allocator);
    defer controller.deinit();

    try add(&controller, 1, "/repo/src", "/repo");
    try controller.selectSurface(1);

    const first = try controller.requestRole(.editor);
    try std.testing.expectEqualStrings("/repo/src", first.create.cwd);
    try std.testing.expectEqualStrings("/repo", first.create.workspace);
    try std.testing.expectEqual(@as(usize, 1), controller.pendingCount());
    try std.testing.expectEqual(Effect.none, try controller.requestRole(.editor));

    _ = try controller.attachPendingSurface(first.create.pending_id, .{
        .id = 2,
        .cwd = first.create.cwd,
        .workspace = first.create.workspace,
    });
    try controller.selectSurface(1);
    try std.testing.expectEqual(Effect{ .focus = 2 }, try controller.requestRole(.editor));
    try std.testing.expectEqual(@as(usize, 1), controller.pendingCount());
}

test "pending command waits for first prompt and does not duplicate queueing" {
    var controller = Controller.init(std.testing.allocator);
    defer controller.deinit();

    try add(&controller, 1, "/repo", "/repo");
    try controller.selectSurface(1);
    const create = (try controller.requestRole(.agent)).create;
    _ = try controller.attachPendingSurface(create.pending_id, .{
        .id = 2,
        .cwd = create.cwd,
        .workspace = create.workspace,
    });

    const queued = controller.promptReady(2).?;
    try std.testing.expectEqual(@as(SurfaceId, 2), queued.surface_id);
    try std.testing.expectEqualStrings("pi", queued.command);
    try std.testing.expect(controller.promptReady(2) == null);
    try std.testing.expectEqual(Role.agent, controller.role(2).?);

    try controller.commandStarted(2, .{ .role = .agent, .command = "pi" });
    try std.testing.expectEqual(@as(usize, 0), controller.pendingCount());
    try controller.commandEnded(2);
    try std.testing.expectEqual(Role.shell, controller.role(2).?);
}

test "configured role commands are queued after startup" {
    var controller = Controller.initWithCommands(std.testing.allocator, .{
        .editor = "/opt/bin/helix",
        .agent = "codex --profile local",
    });
    defer controller.deinit();

    try add(&controller, 1, "/repo", "/repo");
    try controller.selectSurface(1);
    const create = (try controller.requestRole(.editor)).create;
    _ = try controller.attachPendingSurface(create.pending_id, .{
        .id = 2,
        .cwd = create.cwd,
        .workspace = create.workspace,
    });
    try std.testing.expectEqualStrings("/opt/bin/helix", controller.promptReady(2).?.command);
}

test "failed pending command returns to shell and clears reservation" {
    var controller = Controller.init(std.testing.allocator);
    defer controller.deinit();

    try add(&controller, 1, "/repo", "/repo");
    try controller.selectSurface(1);
    const create = (try controller.requestRole(.editor)).create;
    _ = try controller.attachPendingSurface(create.pending_id, .{
        .id = 2,
        .cwd = create.cwd,
        .workspace = create.workspace,
    });
    _ = controller.promptReady(2);
    try controller.commandStarted(2, .{ .role = .shell, .command = "fish: Unknown command: nvim" });
    try std.testing.expectEqual(@as(usize, 1), controller.pendingCount());
    try controller.commandEnded(2);
    try std.testing.expectEqual(@as(usize, 0), controller.pendingCount());
    try std.testing.expectEqual(Role.shell, controller.role(2).?);
}

test "workspace changes immediately affect eligibility" {
    var controller = Controller.init(std.testing.allocator);
    defer controller.deinit();

    try add(&controller, 1, "/repo-a", "/repo-a");
    try add(&controller, 2, "/repo-a/src", "/repo-a");
    try controller.commandStarted(2, .{ .role = .editor, .command = "nvim" });
    try controller.selectSurface(1);
    try controller.updateLocation(2, "/repo-b", "/repo-b");

    const effect = try controller.requestRole(.editor);
    try std.testing.expect(effect == .create);
    try std.testing.expectEqualStrings("/repo-a", effect.create.cwd);
}

test "shell role is running while an ordinary foreground command is active" {
    var controller = Controller.init(std.testing.allocator);
    defer controller.deinit();

    try add(&controller, 1, "/repo", "/repo");
    try std.testing.expectEqual(Status.idle, controller.presentation(1).?.status);
    try controller.commandStarted(1, .{ .role = .shell, .command = "sleep" });
    try std.testing.expectEqual(Status.running, controller.presentation(1).?.status);
    try controller.commandEnded(1);
    try std.testing.expectEqual(Status.idle, controller.presentation(1).?.status);
}

test "agent reports override running fallback until activity changes" {
    var controller = Controller.init(std.testing.allocator);
    defer controller.deinit();

    try add(&controller, 1, "/repo/src", "/repo");
    try controller.commandStarted(1, .{ .role = .agent, .command = "pi" });
    try std.testing.expectEqual(Status.running, controller.presentation(1).?.status);
    try std.testing.expect(try controller.agentStatus(1, .idle));
    try std.testing.expectEqual(Status.idle, controller.presentation(1).?.status);
    try std.testing.expect(!(try controller.agentStatus(1, .idle)));

    try controller.commandEnded(1);
    const presentation = controller.presentation(1).?;
    try std.testing.expectEqual(Status.idle, presentation.status);
    try std.testing.expectEqual(Role.shell, presentation.role);
    try std.testing.expectEqualStrings("/repo/src", presentation.cwd);
    try std.testing.expect(!(try controller.agentStatus(1, .running)));
}

test "lifecycle owner and generation reject stale reports" {
    var controller = Controller.init(std.testing.allocator);
    defer controller.deinit();

    try add(&controller, 1, "/repo", "/repo");
    try std.testing.expect(try controller.acceptLifecycle(1, "fish-1", 1));
    try std.testing.expect(!(try controller.acceptLifecycle(1, "fish-1", 1)));
    try std.testing.expect(try controller.acceptLifecycle(1, "fish-1", 2));
    try std.testing.expect(try controller.acceptLifecycle(1, "fish-2", 1));
    try std.testing.expect(!(try controller.acceptLifecycle(1, "fish-1", 3)));
}
