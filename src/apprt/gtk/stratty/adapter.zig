//! Thin GTK host for the pure Stratty contextual controller.

const std = @import("std");
const adw = @import("adw");
const gtk = @import("gtk");
const glib = @import("glib");
const gobject = @import("gobject");
const global = @import("../../../global.zig");
const apprt = @import("../../../apprt.zig");
const CoreConfig = @import("../../../config.zig").Config;
const stratty = @import("../../../stratty.zig");

const ext = @import("../ext.zig");
const Sidebar = @import("sidebar.zig");
const Window = @import("../class/window.zig").Window;
const Surface = @import("../class/surface.zig").Surface;
const Tab = @import("../class/tab.zig").Tab;

const log = std.log.scoped(.gtk_stratty);

pub const Adapter = struct {
    allocator: std.mem.Allocator,
    window: *Window,
    environment: std.process.Environ.Map,
    workspace: stratty.workspace.Resolver,
    labels: stratty.labels.Labeler,
    controller: stratty.Controller,
    foreground_watches: std.ArrayList(ForegroundWatch) = .empty,
    foreground_source: ?c_uint = null,

    pub fn create(allocator: std.mem.Allocator, window: *Window) !*Adapter {
        const self = try allocator.create(Adapter);
        errdefer allocator.destroy(self);
        self.* = try init(allocator, window);
        return self;
    }

    pub fn destroy(self: *Adapter) void {
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }

    fn init(allocator: std.mem.Allocator, window: *Window) !Adapter {
        var environment = try global.environMap();
        errdefer environment.deinit();
        return .{
            .allocator = allocator,
            .window = window,
            .controller = .initWithCommands(
                allocator,
                stratty.commands.fromEnvironment(&environment),
            ),
            .environment = environment,
            .workspace = .init(allocator, global.io()),
            .labels = .init(allocator),
        };
    }

    fn deinit(self: *Adapter) void {
        if (self.foreground_source) |source| {
            _ = glib.Source.remove(source);
            self.foreground_source = null;
        }
        for (self.foreground_watches.items) |*watch| watch.deinit(self.allocator);
        self.foreground_watches.deinit(self.allocator);
        self.controller.deinit();
        self.workspace.deinit();
        self.labels.deinit();
        self.environment.deinit();
    }

    pub fn surfaceAttached(self: *Adapter, surface: *Surface, fallback_cwd: ?[]const u8) void {
        const cwd: []const u8 = if (surface.getPwd()) |pwd| pwd else fallback_cwd orelse return;
        const workspace = self.workspace.resolve(cwd) catch cwd;
        const id = surfaceId(surface);
        if (self.ensureForegroundWatch(id)) |_| {} else |err| {
            log.warn("unable to monitor Stratty foreground process error={}", .{err});
        }
        if (self.controller.containsSurface(id)) {
            if (self.controller.updateLocation(id, cwd, workspace)) |changed| {
                if (changed) self.updateLabels();
            } else |err| {
                log.warn("unable to update Stratty surface location error={}", .{err});
            }
            return;
        }
        self.controller.addSurface(.{
            .id = id,
            .cwd = cwd,
            .workspace = workspace,
        }) catch |err| log.warn("unable to attach Stratty surface error={}", .{err});
        self.updateLabels();
    }

    pub fn surfaceDetached(self: *Adapter, surface: *Surface) void {
        const id = surfaceId(surface);
        self.removeForegroundWatch(id);
        self.controller.removeSurface(id);
        self.updateLabels();
    }

    pub fn surfacePwdChanged(self: *Adapter, surface: *Surface) void {
        const id = surfaceId(surface);
        if (self.foregroundOwnsLocation(id)) return;
        self.surfaceAttached(surface, null);
    }

    pub fn selected(self: *Adapter, surface: *Surface) void {
        const id = surfaceId(surface);
        if (!self.foregroundOwnsLocation(id)) self.surfaceAttached(surface, null);
        self.controller.selectSurface(id) catch return;
    }

    fn foregroundOwnsLocation(self: *const Adapter, id: stratty.controller.SurfaceId) bool {
        for (self.foreground_watches.items) |watch| {
            if (watch.surface_id == id) return watch.observed_foreground;
        }
        return false;
    }

    pub fn requestRole(self: *Adapter, source: *Surface, role: stratty.Role) bool {
        self.surfaceAttached(source, null);
        self.controller.selectSurface(surfaceId(source)) catch return false;
        const effect = self.controller.requestRole(role) catch |err| {
            log.warn("Stratty contextual action failed error={}", .{err});
            return false;
        };

        switch (effect) {
            .none => return true,
            .focus => |id| {
                const target: *Surface = @ptrFromInt(id);
                self.window.focusSurface(target);
                return true;
            },
            .create => |creation| {
                var reserved = true;
                defer if (reserved) self.controller.cancelPending(creation.pending_id);

                const cwd = self.allocator.dupeZ(u8, creation.cwd) catch return false;
                defer self.allocator.free(cwd);
                const target = self.window.newContextualTab(cwd) orelse return false;
                self.surfaceAttached(target, creation.cwd);
                _ = self.controller.updateLocation(surfaceId(target), creation.cwd, creation.workspace) catch return false;
                self.controller.bindPendingSurface(creation.pending_id, surfaceId(target)) catch |err| {
                    log.warn("unable to attach pending Stratty target error={}", .{err});
                    return false;
                };
                reserved = false;
                self.updateLabels();
                return true;
            },
        }
    }

    pub fn shellLifecycle(
        self: *Adapter,
        surface: *Surface,
        value: apprt.action.ShellLifecycle,
    ) bool {
        self.surfaceAttached(surface, null);
        const id = surfaceId(surface);
        if (!self.controller.containsSurface(id)) return false;

        const report = stratty.lifecycle.metadata(value.report);
        if (report.owner != null and report.generation != null) {
            if (!(self.controller.acceptLifecycle(
                id,
                report.owner.?,
                report.generation.?,
            ) catch return false)) return true;
        } else if (value.kind == .command_started or value.kind == .command_ended) {
            // Ghostty emits an initial synthetic command-end before the first
            // prompt. Only Stratty-owned command reports may mutate role state.
            return true;
        }

        switch (value.kind) {
            .prompt_ready => {
                self.clearForegroundWatch(id);
                if (self.controller.promptReady(id) catch return false) |command| {
                    const core = surface.core() orelse return false;
                    _ = core.performBindingAction(.{ .text = command }) catch |err| {
                        log.warn("unable to queue Stratty command error={}", .{err});
                        return false;
                    };
                    _ = core.performBindingAction(.{ .text = "\\r" }) catch |err| {
                        log.warn("unable to submit Stratty command error={}", .{err});
                        return false;
                    };
                }
            },
            .command_started => {
                var activity = stratty.lifecycle.activity(
                    self.allocator,
                    value.report,
                    self.controller.commands,
                ) catch return false;
                defer activity.deinit();
                self.controller.commandStarted(id, activity.value()) catch return false;
                if (activity.compound and activity.candidates.items.len > 0) {
                    self.setForegroundWatch(id, activity.candidates.items) catch |err|
                        log.warn("unable to monitor compound Stratty command error={}", .{err});
                } else {
                    self.clearForegroundWatch(id);
                }
            },
            .command_ended => {
                self.clearForegroundWatch(id);
                self.controller.commandEnded(id) catch return false;
            },
            .agent_idle => _ = self.controller.agentStatus(id, .idle) catch return false,
            .agent_running => _ = self.controller.agentStatus(id, .running) catch return false,
        }
        self.updateLabels();
        return true;
    }

    const ForegroundWatch = struct {
        surface_id: stratty.controller.SurfaceId,
        candidates: std.ArrayList([]u8) = .empty,
        observed_foreground: bool = false,

        fn clearCandidates(self: *ForegroundWatch, allocator: std.mem.Allocator) void {
            for (self.candidates.items) |candidate| allocator.free(candidate);
            self.candidates.clearRetainingCapacity();
        }

        fn deinit(self: *ForegroundWatch, allocator: std.mem.Allocator) void {
            self.clearCandidates(allocator);
            self.candidates.deinit(allocator);
        }
    };

    fn ensureForegroundWatch(
        self: *Adapter,
        id: stratty.controller.SurfaceId,
    ) !*ForegroundWatch {
        for (self.foreground_watches.items) |*watch| {
            if (watch.surface_id == id) return watch;
        }
        try self.foreground_watches.append(self.allocator, .{ .surface_id = id });
        if (self.foreground_source == null) {
            self.foreground_source = glib.timeoutAdd(500, foregroundPoll, self);
        }
        return &self.foreground_watches.items[self.foreground_watches.items.len - 1];
    }

    fn setForegroundWatch(
        self: *Adapter,
        id: stratty.controller.SurfaceId,
        candidates: []const []u8,
    ) !void {
        const watch = try self.ensureForegroundWatch(id);
        watch.clearCandidates(self.allocator);
        errdefer watch.clearCandidates(self.allocator);
        for (candidates) |candidate| {
            const owned = try self.allocator.dupe(u8, candidate);
            errdefer self.allocator.free(owned);
            try watch.candidates.append(self.allocator, owned);
        }
        log.debug("monitoring compound command surface={d} candidates={d}", .{
            id,
            candidates.len,
        });
    }

    fn clearForegroundWatch(self: *Adapter, id: stratty.controller.SurfaceId) void {
        for (self.foreground_watches.items) |*watch| {
            if (watch.surface_id != id) continue;
            watch.clearCandidates(self.allocator);
            return;
        }
    }

    fn removeForegroundWatch(self: *Adapter, id: stratty.controller.SurfaceId) void {
        for (self.foreground_watches.items, 0..) |watch, index| {
            if (watch.surface_id != id) continue;
            var removed = self.foreground_watches.orderedRemove(index);
            removed.deinit(self.allocator);
            break;
        }
        if (self.foreground_watches.items.len == 0) {
            if (self.foreground_source) |source| _ = glib.Source.remove(source);
            self.foreground_source = null;
        }
    }

    fn foregroundPoll(userdata: ?*anyopaque) callconv(.c) c_int {
        const data: *Adapter = @ptrCast(@alignCast(userdata orelse return 0));
        if (data.foreground_watches.items.len == 0) {
            data.foreground_source = null;
            return 0;
        }
        data.pollForeground();
        return 1;
    }

    fn pollForeground(self: *Adapter) void {
        var changed = false;
        for (self.foreground_watches.items) |*watch| {
            if (!self.controller.containsSurface(watch.surface_id)) continue;
            const surface: *Surface = @ptrFromInt(watch.surface_id);
            const core = surface.core() orelse continue;
            const process_group = core.getProcessInfo(.foreground_pid) orelse continue;
            var processes = stratty.linux_process.foregroundGroup(
                self.allocator,
                global.io(),
                process_group,
            ) catch continue;
            defer processes.deinit();
            if (processes.items.items.len == 0) continue;

            const process_cwd = processes.items.items[0].cwd;
            if (process_cwd.len > 0) {
                const current = self.controller.presentation(watch.surface_id) orelse continue;
                if (!std.mem.eql(u8, current.cwd, process_cwd)) {
                    const workspace = self.workspace.resolve(process_cwd) catch process_cwd;
                    _ = self.controller.updateLocation(
                        watch.surface_id,
                        process_cwd,
                        workspace,
                    ) catch continue;
                    changed = true;
                }
            }

            const command = if (stratty.linux_process.matchesExecutable(
                processes.items.items,
                self.controller.commands.agent,
            ))
                std.fs.path.basename(self.controller.commands.agent)
            else if (stratty.linux_process.matchesExecutable(
                processes.items.items,
                self.controller.commands.editor,
            ))
                std.fs.path.basename(self.controller.commands.editor)
            else if (stratty.linux_process.matchCandidate(
                processes.items.items,
                watch.candidates.items,
            )) |candidate|
                candidate
            else if (self.environment.get("SHELL")) |shell|
                if (stratty.linux_process.matchesExecutable(processes.items.items, shell)) {
                    if (!watch.observed_foreground) continue;
                    self.controller.commandEnded(watch.surface_id) catch continue;
                    watch.observed_foreground = false;
                    changed = true;
                    continue;
                } else processes.items.items[0].comm
            else
                processes.items.items[0].comm;

            watch.observed_foreground = true;
            const role = stratty.commands.classifyExecutable(command, self.controller.commands);
            const current = self.controller.presentation(watch.surface_id) orelse continue;
            if (current.role == role and std.mem.eql(u8, current.activity, command)) continue;
            self.controller.commandStarted(watch.surface_id, .{
                .role = role,
                .command = command,
            }) catch continue;
            log.debug("foreground changed surface={d} command={s} role={s}", .{
                watch.surface_id,
                command,
                @tagName(role),
            });
            changed = true;
        }
        if (changed) self.updateLabels();
    }

    pub fn rebuildSidebar(
        self: *const Adapter,
        list: *gtk.ListBox,
        tab_view: *adw.TabView,
        config: *const CoreConfig,
    ) void {
        const widget = list.as(gtk.Widget);
        while (widget.getFirstChild()) |child| list.remove(child);

        var previous_workspace: ?[]const u8 = null;
        var index: c_int = 0;
        while (index < tab_view.getNPages()) : (index += 1) {
            const page = tab_view.getNthPage(index);
            const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
            const surface = tab.getActiveSurface() orelse continue;
            const presentation = self.controller.presentation(surfaceId(surface)) orelse continue;
            if (previous_workspace == null or !std.mem.eql(
                u8,
                previous_workspace.?,
                presentation.workspace,
            )) {
                Sidebar.appendHeader(list, self.allocator, presentation.workspace);
                previous_workspace = presentation.workspace;
            }
            Sidebar.appendTab(
                list,
                self.allocator,
                config,
                presentation,
                page.getNeedsAttention() != 0,
            );
        }
    }

    fn updateLabels(self: *Adapter) void {
        for (0..self.controller.surfaceCount()) |index| {
            const id = self.controller.surfaceIdAt(index) orelse continue;
            const view = self.controller.presentation(id) orelse continue;
            var total: usize = 0;
            var rank: usize = 0;
            for (0..self.controller.surfaceCount()) |other_index| {
                const other_id = self.controller.surfaceIdAt(other_index) orelse continue;
                const other = self.controller.presentation(other_id) orelse continue;
                if (!std.mem.eql(u8, view.workspace, other.workspace) or
                    !std.mem.eql(u8, view.activity, other.activity)) continue;
                total += 1;
                if (other.creation_sequence <= view.creation_sequence) rank += 1;
            }

            const label = self.labels.format(
                view.workspace,
                view.activity,
                if (total > 1) rank else null,
            ) catch continue;
            defer self.allocator.free(label);
            const surface: *Surface = @ptrFromInt(id);
            const tab = ext.getAncestor(Tab, surface.as(gtk.Widget)) orelse continue;
            tab.setTitleOverride(label);
        }
        self.window.rebuildStrattyTabList();
    }

    fn surfaceId(surface: *Surface) stratty.controller.SurfaceId {
        return @intFromPtr(surface);
    }
};
