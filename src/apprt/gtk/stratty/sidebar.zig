//! Native GTK presentation for Stratty's Quiet List sidebar.

const std = @import("std");
const gobject = @import("gobject");
const gtk = @import("gtk");
const c = @import("gtk_c");

const global = @import("../../../global.zig");
const CoreConfig = @import("../../../config.zig").Config;
const Color = @import("../../../terminal/color.zig").RGB;
const stratty = @import("../../../stratty.zig");

const Status = enum(u8) { idle, running, attention };

const alpha_fraction_scale: u64 = 1 << 16;
const panel_noise_seed: u64 = 0x913A_4F6D_2C85_7B01;
const selection_noise_seed: u64 = 0x6E21_B9C4_A753_08DF;

/// Base16 colors resolved through Ghostty's active ANSI palette. Stylix and
/// normal Ghostty themes both reach the sidebar through this single mapping.
const Theme = struct {
    base03: Color,
    base05: Color,
    base07: Color,
    base0a: Color,
    base0b: Color,

    fn init(config: *const CoreConfig) Theme {
        return .{
            .base03 = config.palette.value[8],
            .base05 = config.palette.value[7],
            .base07 = config.palette.value[15],
            .base0a = config.palette.value[3],
            .base0b = config.palette.value[2],
        };
    }
};

const RasterState = struct {
    pixels: ?[]u32 = null,
    surface: ?*c.cairo_surface_t = null,
    width: c_int = 0,
    height: c_int = 0,
    scale: c_int = 0,

    fn clear(self: *RasterState) void {
        if (self.surface) |surface| c.cairo_surface_destroy(surface);
        if (self.pixels) |pixels| std.heap.c_allocator.free(pixels);
        self.* = .{};
    }
};

const BackdropState = struct {
    color: Color,
    raster: RasterState = .{},
};

const SelectionState = struct {
    row: *gtk.ListBoxRow,
    accent: Color,
    highlight: Color,
    raster: RasterState = .{},
};

pub fn configureBackdrop(area: *gtk.DrawingArea, config: *const CoreConfig) void {
    const state = std.heap.c_allocator.create(BackdropState) catch return;
    state.* = .{ .color = Theme.init(config).base0b };
    c.gtk_drawing_area_set_draw_func(
        @ptrCast(area),
        drawBackdrop,
        state,
        destroyBackdrop,
    );
    area.as(gtk.Widget).queueDraw();
}

fn destroyBackdrop(userdata: ?*anyopaque) callconv(.c) void {
    const state: *BackdropState = @ptrCast(@alignCast(userdata orelse return));
    state.raster.clear();
    std.heap.c_allocator.destroy(state);
}

fn drawBackdrop(
    area: [*c]c.GtkDrawingArea,
    cr: ?*c.cairo_t,
    width: c_int,
    height: c_int,
    userdata: ?*anyopaque,
) callconv(.c) void {
    if (width <= 0 or height <= 0) return;
    const state: *BackdropState = @ptrCast(@alignCast(userdata orelse return));
    const scale = @max(c.gtk_widget_get_scale_factor(@ptrCast(area)), 1);
    if (!ensureRaster(&state.raster, state.color, .panel, width, height, scale)) return;
    _ = c.cairo_set_source_surface(cr, state.raster.surface, 0, 0);
    _ = c.cairo_paint(cr);
}

fn premultipliedPixel(
    color: Color,
    alpha_q16: u64,
    x: usize,
    y: usize,
    seed: u64,
) u32 {
    const alpha = ditheredChannel(alpha_q16, x, y, seed ^ 0xA11F_A11F_A11F_A11F);
    const red = @min(
        ditheredChannel(
            @as(u64, color.r) * alpha_q16 / 255,
            x,
            y,
            seed ^ 0xD31C_D31C_D31C_D31C,
        ),
        alpha,
    );
    const green = @min(
        ditheredChannel(
            @as(u64, color.g) * alpha_q16 / 255,
            x,
            y,
            seed ^ 0x67E2_67E2_67E2_67E2,
        ),
        alpha,
    );
    const blue = @min(
        ditheredChannel(
            @as(u64, color.b) * alpha_q16 / 255,
            x,
            y,
            seed ^ 0xB109_B109_B109_B109,
        ),
        alpha,
    );
    return (@as(u32, alpha) << 24) |
        (@as(u32, red) << 16) |
        (@as(u32, green) << 8) |
        blue;
}

fn ditheredChannel(value_q16: u64, x: usize, y: usize, seed: u64) u8 {
    const whole = value_q16 / alpha_fraction_scale;
    const fraction = value_q16 % alpha_fraction_scale;
    const threshold = noise16(x, y, seed);
    return @intCast(whole + @intFromBool(fraction > threshold));
}

fn noise16(x: usize, y: usize, seed: u64) u16 {
    // SplitMix64-style coordinate hashing gives every physical pixel an
    // independent threshold. Unlike a small ordered matrix, this has no tile
    // for a fractional-scale compositor to turn into bands or moire patterns.
    var value = seed ^
        (@as(u64, @intCast(x)) *% 0x9E37_79B9_7F4A_7C15) ^
        (@as(u64, @intCast(y)) *% 0xD1B5_4A32_D192_ED03);
    value = (value ^ (value >> 30)) *% 0xBF58_476D_1CE4_E5B9;
    value = (value ^ (value >> 27)) *% 0x94D0_49BB_1331_11EB;
    value ^= value >> 31;
    return @truncate(value >> 48);
}

fn selectionBackdrop(row: *gtk.ListBoxRow, config: *const CoreConfig) *gtk.Widget {
    const area: *gtk.Widget = @ptrCast(c.gtk_drawing_area_new());
    area.setHexpand(@intFromBool(true));
    area.setVexpand(@intFromBool(true));

    const state = std.heap.c_allocator.create(SelectionState) catch return area;
    const theme = Theme.init(config);
    state.* = .{
        .row = row,
        .accent = theme.base0b,
        .highlight = theme.base07,
    };
    c.gtk_drawing_area_set_draw_func(
        @ptrCast(area),
        drawSelection,
        state,
        destroySelection,
    );
    return area;
}

fn destroySelection(userdata: ?*anyopaque) callconv(.c) void {
    const state: *SelectionState = @ptrCast(@alignCast(userdata orelse return));
    state.raster.clear();
    std.heap.c_allocator.destroy(state);
}

fn drawSelection(
    area: [*c]c.GtkDrawingArea,
    cr: ?*c.cairo_t,
    width: c_int,
    height: c_int,
    userdata: ?*anyopaque,
) callconv(.c) void {
    if (width <= 0 or height <= 0) return;
    const state: *SelectionState = @ptrCast(@alignCast(userdata orelse return));
    if (c.gtk_list_box_row_is_selected(@ptrCast(state.row)) == 0) return;

    const scale = @max(c.gtk_widget_get_scale_factor(@ptrCast(area)), 1);
    if (!ensureRaster(&state.raster, state.accent, .selection, width, height, scale)) return;

    const logical_width: f64 = @floatFromInt(width);
    const logical_height: f64 = @floatFromInt(height);
    c.cairo_save(cr);
    roundedRectangle(cr, 0, 0, logical_width, logical_height, 7);
    c.cairo_clip(cr);
    _ = c.cairo_set_source_surface(cr, state.raster.surface, 0, 0);
    _ = c.cairo_paint(cr);

    // Match the prototype's extremely subtle one-pixel inset highlight.
    c.cairo_set_source_rgba(
        cr,
        @as(f64, @floatFromInt(state.highlight.r)) / 255.0,
        @as(f64, @floatFromInt(state.highlight.g)) / 255.0,
        @as(f64, @floatFromInt(state.highlight.b)) / 255.0,
        0.018,
    );
    c.cairo_rectangle(cr, 1, 0, @max(logical_width - 2, 0), 1);
    c.cairo_fill(cr);
    c.cairo_restore(cr);

    // Draw the 16%-base0B border natively so it remains smooth around the
    // same seven-pixel radius as the dithered fill.
    c.cairo_set_antialias(cr, c.CAIRO_ANTIALIAS_BEST);
    roundedRectangle(cr, 0.5, 0.5, logical_width - 1, logical_height - 1, 6.5);
    c.cairo_set_source_rgba(
        cr,
        @as(f64, @floatFromInt(state.accent.r)) / 255.0,
        @as(f64, @floatFromInt(state.accent.g)) / 255.0,
        @as(f64, @floatFromInt(state.accent.b)) / 255.0,
        0.16,
    );
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);
}

const Gradient = enum { panel, selection };

fn ensureRaster(
    state: *RasterState,
    color: Color,
    comptime gradient: Gradient,
    width: c_int,
    height: c_int,
    scale: c_int,
) bool {
    if (state.surface != null and
        state.width == width and
        state.height == height and
        state.scale == scale) return true;

    const pixel_width = std.math.mul(c_int, width, scale) catch return false;
    const pixel_height = std.math.mul(c_int, height, scale) catch return false;
    const stride = c.cairo_format_stride_for_width(c.CAIRO_FORMAT_ARGB32, pixel_width);
    if (stride <= 0) return false;
    const words_per_row: usize = @intCast(@divExact(stride, @sizeOf(u32)));
    const pixel_count = std.math.mul(usize, words_per_row, @intCast(pixel_height)) catch return false;
    const pixels = std.heap.c_allocator.alloc(u32, pixel_count) catch return false;
    @memset(pixels, 0);

    const seed = switch (gradient) {
        .panel => panel_noise_seed,
        .selection => selection_noise_seed,
    };
    for (0..@intCast(pixel_height)) |y| {
        for (0..@intCast(pixel_width)) |x| {
            const alpha_q16 = gradientAlpha(gradient, x, y, pixel_width) orelse continue;
            pixels[y * words_per_row + x] = premultipliedPixel(
                color,
                alpha_q16,
                x,
                y,
                seed,
            );
        }
    }

    const surface = c.cairo_image_surface_create_for_data(
        @ptrCast(pixels.ptr),
        c.CAIRO_FORMAT_ARGB32,
        pixel_width,
        pixel_height,
        stride,
    );
    if (c.cairo_surface_status(surface) != c.CAIRO_STATUS_SUCCESS) {
        c.cairo_surface_destroy(surface);
        std.heap.c_allocator.free(pixels);
        return false;
    }
    c.cairo_surface_set_device_scale(
        surface,
        @floatFromInt(scale),
        @floatFromInt(scale),
    );
    c.cairo_surface_mark_dirty(surface);

    state.clear();
    state.* = .{
        .pixels = pixels,
        .surface = surface,
        .width = width,
        .height = height,
        .scale = scale,
    };
    return true;
}

inline fn gradientAlpha(
    comptime gradient: Gradient,
    x: usize,
    y: usize,
    pixel_width: c_int,
) ?u64 {
    return switch (gradient) {
        .panel => panel: {
            const cutoff = @as(u64, @intCast(pixel_width)) * 2;
            const distance = @as(u64, x) * 2 + @as(u64, y);
            if (distance >= cutoff) break :panel null;
            const max_alpha = 255 * alpha_fraction_scale / 40; // 2.5%
            break :panel max_alpha * (cutoff - distance) / cutoff;
        },
        .selection => selection: {
            // Prototype selector: base0B at 15% on the left and 6.5% on the
            // right. Q16 alpha preserves the ramp through fractional scaling.
            const left_alpha = 255 * 15 * alpha_fraction_scale / 100;
            const right_alpha = 255 * 13 * alpha_fraction_scale / 200;
            const span: u64 = @intCast(@max(pixel_width - 1, 1));
            break :selection left_alpha -
                (left_alpha - right_alpha) * @as(u64, x) / span;
        },
    };
}

fn roundedRectangle(
    cr: ?*c.cairo_t,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    requested_radius: f64,
) void {
    const radius = @min(requested_radius, @min(width, height) / 2.0);
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, x + width - radius, y + radius, radius, -std.math.pi / 2.0, 0);
    c.cairo_arc(cr, x + width - radius, y + height - radius, radius, 0, std.math.pi / 2.0);
    c.cairo_arc(cr, x + radius, y + height - radius, radius, std.math.pi / 2.0, std.math.pi);
    c.cairo_arc(cr, x + radius, y + radius, radius, std.math.pi, 3.0 * std.math.pi / 2.0);
    c.cairo_close_path(cr);
}

pub fn appendHeader(
    list: *gtk.ListBox,
    allocator: std.mem.Allocator,
    workspace: []const u8,
) void {
    const row = gtk.ListBoxRow.new();
    row.setSelectable(@intFromBool(false));
    row.setActivatable(@intFromBool(false));
    row.as(gtk.Widget).addCssClass("stratty-workspace-row");

    const name = std.fs.path.basename(workspace);
    const text = allocator.dupeZ(u8, name) catch return;
    defer allocator.free(text);
    for (text[0..name.len]) |*character| character.* = std.ascii.toUpper(character.*);
    const label = gtk.Label.new(text.ptr);
    label.setXalign(0);
    label.setSingleLineMode(@intFromBool(true));
    label.as(gtk.Widget).addCssClass("stratty-workspace-name");
    row.setChild(label.as(gtk.Widget));
    list.append(row.as(gtk.Widget));
}

pub fn appendTab(
    list: *gtk.ListBox,
    allocator: std.mem.Allocator,
    config: *const CoreConfig,
    presentation: stratty.controller.Presentation,
    attention: bool,
) void {
    const row = gtk.ListBoxRow.new();
    row.as(gtk.Widget).addCssClass("stratty-tab-row");

    // The selection bar sits beside the card rather than inside it. This
    // mirrors the prototype's active pseudo-element and keeps every child
    // vertically centered instead of letting GTK stretch it to the row.
    const content = gtk.Box.new(.horizontal, 6);
    content.as(gtk.Widget).addCssClass("stratty-row-content");

    const bar = gtk.Box.new(.vertical, 0);
    bar.as(gtk.Widget).setSizeRequest(2, 25);
    bar.as(gtk.Widget).setValign(.center);
    bar.as(gtk.Widget).setVexpand(@intFromBool(false));
    bar.as(gtk.Widget).addCssClass("stratty-selection-bar");
    content.append(bar.as(gtk.Widget));

    const card_frame: *gtk.Widget = @ptrCast(c.gtk_overlay_new());
    card_frame.setHexpand(@intFromBool(true));
    card_frame.addCssClass("stratty-row-card");

    const backdrop = selectionBackdrop(row, config);
    c.gtk_overlay_set_child(@ptrCast(card_frame), @ptrCast(backdrop));

    const card = gtk.Box.new(.horizontal, 9);
    card.as(gtk.Widget).setHexpand(@intFromBool(true));
    card.as(gtk.Widget).setHalign(.fill);
    card.as(gtk.Widget).setValign(.fill);
    card.as(gtk.Widget).addCssClass("stratty-row-card-content");

    const image = roleIcon(allocator, config, presentation.role);
    image.as(gtk.Widget).setSizeRequest(23, 23);
    image.as(gtk.Widget).setValign(.center);
    image.as(gtk.Widget).setVexpand(@intFromBool(false));
    image.as(gtk.Widget).addCssClass("stratty-role-icon");
    card.append(image.as(gtk.Widget));

    const copy = gtk.Box.new(.horizontal, 4);
    copy.setBaselinePosition(.center);
    copy.as(gtk.Widget).setHexpand(@intFromBool(true));
    copy.as(gtk.Widget).setValign(.center);
    copy.as(gtk.Widget).setVexpand(@intFromBool(false));

    const title_text = allocator.dupeZ(u8, presentation.activity) catch return;
    defer allocator.free(title_text);
    const title = gtk.Label.new(title_text.ptr);
    title.setXalign(0);
    title.setSingleLineMode(@intFromBool(true));
    title.as(gtk.Widget).setValign(.baseline);
    title.as(gtk.Widget).addCssClass("stratty-row-title");
    copy.append(title.as(gtk.Widget));

    if (relativePath(allocator, presentation.workspace, presentation.cwd)) |relative| {
        defer allocator.free(relative);
        const subtitle = gtk.Label.new(relative.ptr);
        subtitle.setXalign(0);
        subtitle.setSingleLineMode(@intFromBool(true));
        subtitle.as(gtk.Widget).setValign(.baseline);
        subtitle.as(gtk.Widget).addCssClass("stratty-row-subtitle");
        copy.append(subtitle.as(gtk.Widget));
    }
    card.append(copy.as(gtk.Widget));

    const status: Status = if (attention)
        .attention
    else switch (presentation.status) {
        .idle => .idle,
        .running => .running,
    };
    card.append(statusDot(status));
    c.gtk_overlay_add_overlay(@ptrCast(card_frame), @ptrCast(card));
    c.gtk_overlay_set_measure_overlay(@ptrCast(card_frame), @ptrCast(card), 1);
    c.gtk_overlay_set_clip_overlay(@ptrCast(card_frame), @ptrCast(card), 1);
    content.append(card_frame);

    row.setChild(content.as(gtk.Widget));
    list.append(row.as(gtk.Widget));
}

fn statusDot(status: Status) *gtk.Widget {
    // GtkOverlay keeps the layout footprint at exactly 7 px while allowing a
    // Cairo glow to extend naturally around running and attention states.
    const overlay: *gtk.Widget = @ptrCast(c.gtk_overlay_new());
    overlay.setSizeRequest(7, 7);
    overlay.setValign(.center);
    overlay.setVexpand(@intFromBool(false));
    overlay.addCssClass("stratty-status");
    overlay.addCssClass(@tagName(status));

    const spacer = gtk.Box.new(.horizontal, 0);
    spacer.as(gtk.Widget).setSizeRequest(7, 7);
    c.gtk_overlay_set_child(@ptrCast(overlay), @ptrCast(spacer));

    const status_data: ?*anyopaque = @ptrFromInt(@intFromEnum(status) + 1);
    if (status != .idle) {
        const glow: *gtk.Widget = @ptrCast(c.gtk_drawing_area_new());
        glow.setSizeRequest(17, 17);
        glow.setHalign(.center);
        glow.setValign(.center);
        c.gtk_drawing_area_set_draw_func(@ptrCast(glow), drawStatusGlow, status_data, null);
        c.gtk_overlay_add_overlay(@ptrCast(overlay), @ptrCast(glow));
    }

    const dot: *gtk.Widget = @ptrCast(c.gtk_drawing_area_new());
    dot.setSizeRequest(7, 7);
    dot.setHalign(.center);
    dot.setValign(.center);
    c.gtk_drawing_area_set_draw_func(@ptrCast(dot), drawStatus, status_data, null);
    c.gtk_overlay_add_overlay(@ptrCast(overlay), @ptrCast(dot));
    return overlay;
}

fn statusFromUserdata(userdata: ?*anyopaque) ?Status {
    const raw = @intFromPtr(userdata orelse return null);
    return @enumFromInt(raw - 1);
}

fn drawStatusGlow(
    area: [*c]c.GtkDrawingArea,
    cr: ?*c.cairo_t,
    width: c_int,
    height: c_int,
    userdata: ?*anyopaque,
) callconv(.c) void {
    const status = statusFromUserdata(userdata) orelse return;
    if (status == .idle) return;

    var color: c.GdkRGBA = undefined;
    c.gtk_widget_get_color(@ptrCast(area), &color);
    const center_x = @as(f64, @floatFromInt(width)) / 2.0;
    const center_y = @as(f64, @floatFromInt(height)) / 2.0;
    const radius: f64 = if (status == .attention) 8.0 else 7.0;
    // CSS blur distributes its nominal shadow alpha over a much larger
    // kernel. These center-stop values reproduce that subtle falloff without
    // GTK's cross-shaped tiny box-shadow rasterization.
    const alpha: f64 = if (status == .attention) 0.14 else 0.10;
    const pattern = c.cairo_pattern_create_radial(
        center_x,
        center_y,
        2.5,
        center_x,
        center_y,
        radius,
    );
    c.cairo_pattern_add_color_stop_rgba(pattern, 0, color.red, color.green, color.blue, alpha);
    c.cairo_pattern_add_color_stop_rgba(pattern, 1, color.red, color.green, color.blue, 0);
    c.cairo_set_antialias(cr, c.CAIRO_ANTIALIAS_BEST);
    c.cairo_set_source(cr, pattern);
    c.cairo_arc(cr, center_x, center_y, radius, 0, std.math.tau);
    c.cairo_fill(cr);
    c.cairo_pattern_destroy(pattern);
}

fn drawStatus(
    area: [*c]c.GtkDrawingArea,
    cr: ?*c.cairo_t,
    width: c_int,
    height: c_int,
    userdata: ?*anyopaque,
) callconv(.c) void {
    const status = statusFromUserdata(userdata) orelse return;
    var color: c.GdkRGBA = undefined;
    c.gtk_widget_get_color(@ptrCast(area), &color);
    c.cairo_set_antialias(cr, c.CAIRO_ANTIALIAS_BEST);
    c.cairo_set_source_rgba(cr, color.red, color.green, color.blue, color.alpha);

    const center_x = @as(f64, @floatFromInt(width)) / 2.0;
    const center_y = @as(f64, @floatFromInt(height)) / 2.0;
    if (status == .idle) {
        // CSS renders a one-pixel border inside a 7 px circle: an outer
        // radius of 3.5 px and an inner radius of 2.5 px.
        c.cairo_arc(cr, center_x, center_y, 3.0, 0, std.math.tau);
        c.cairo_set_line_width(cr, 1.0);
        c.cairo_stroke(cr);
    } else {
        c.cairo_arc(cr, center_x, center_y, 3.5, 0, std.math.tau);
        c.cairo_fill(cr);
    }
}

const minimum_width: i64 = 210;
const maximum_width: i64 = 320;

pub const CellGrid = struct {
    // Ghostty reports the surface, cell, and padding in buffer pixels.
    surface_width: i64,
    cell_width: i64,
    padding: i64,

    // GTK reports sidebar allocation and requests in logical pixels.
    sidebar_width: i64,
    previous_request: i64,
    scale: i64,
};

/// Preserve the prototype ratio, then choose the nearest width that leaves the
/// terminal viewport on a whole-cell boundary.
pub fn widthFor(window_width: c_int, grid: ?CellGrid) c_int {
    const proportional = std.math.clamp(
        @divTrunc(@as(i64, window_width) * 236 + 690, 1380),
        minimum_width,
        maximum_width,
    );
    var width = proportional;

    if (grid) |metrics| snap: {
        if (metrics.surface_width <= 0 or
            metrics.sidebar_width <= 0 or
            metrics.scale <= 0 or
            metrics.cell_width <= 0) break :snap;

        const available_width = metrics.surface_width +
            metrics.sidebar_width * metrics.scale;
        const allocation_offset = metrics.sidebar_width - metrics.previous_request;
        var best_distance: i64 = std.math.maxInt(i64);
        var candidate: i64 = minimum_width;
        while (candidate <= maximum_width) : (candidate += 1) {
            const candidate_allocation = candidate + allocation_offset;
            if (candidate_allocation <= 0) continue;
            const terminal_width = available_width -
                candidate_allocation * metrics.scale - metrics.padding;
            if (terminal_width <= 0 or @mod(terminal_width, metrics.cell_width) != 0) continue;

            const distance = if (candidate >= proportional)
                candidate - proportional
            else
                proportional - candidate;
            if (distance >= best_distance) continue;
            best_distance = distance;
            width = candidate;
        }
    }

    return @intCast(width);
}

test "Stratty sidebar width keeps the prototype ratio" {
    try std.testing.expectEqual(@as(c_int, 236), widthFor(1380, null));
    try std.testing.expectEqual(@as(c_int, 210), widthFor(1000, null));
    try std.testing.expectEqual(@as(c_int, 320), widthFor(2000, null));
}

test "Stratty sidebar width aligns the fractional-scale cell grid" {
    try std.testing.expectEqual(@as(c_int, 316), widthFor(2000, .{
        .surface_width = 3580,
        .sidebar_width = 209,
        .previous_request = 210,
        .scale = 2,
        .cell_width = 19,
        .padding = 5,
    }));
}

pub fn pageIndexForRow(list: *gtk.ListBox, selected: *gtk.ListBoxRow) ?c_int {
    var row_index: c_int = 0;
    var page_index: c_int = 0;
    while (list.getRowAtIndex(row_index)) |row| : (row_index += 1) {
        if (row.getSelectable() == 0) continue;
        if (row == selected) return page_index;
        page_index += 1;
    }
    return null;
}

pub fn rowForPageIndex(list: *gtk.ListBox, target: c_int) ?*gtk.ListBoxRow {
    var row_index: c_int = 0;
    var page_index: c_int = 0;
    while (list.getRowAtIndex(row_index)) |row| : (row_index += 1) {
        if (row.getSelectable() == 0) continue;
        if (page_index == target) return row;
        page_index += 1;
    }
    return null;
}

pub fn writeCss(config: *const CoreConfig, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const theme = Theme.init(config);

    try writer.print(
        \\.stratty-sidebar {{
        \\  font-family: Inter, sans-serif;
        \\  background-color: rgba(0, 0, 0, 0.50);
        \\  border-left: 1px solid rgba({[b03r]d}, {[b03g]d}, {[b03b]d}, 0.15);
        \\  box-shadow: -1px 0 0 rgba(0, 0, 0, 0.15), -13px 0 34px rgba(0, 0, 0, 0.16), inset 1px 0 rgba({[b07r]d}, {[b07g]d}, {[b07b]d}, 0.018);
        \\}}
        \\.stratty-sidebar-scroll,
        \\.stratty-sidebar viewport,
        \\.stratty-sidebar list {{
        \\  background-color: transparent;
        \\}}
        \\.stratty-sidebar list {{
        \\  padding: 15px 0 16px;
        \\}}
        \\.stratty-sidebar row {{
        \\  color: rgba({[b07r]d}, {[b07g]d}, {[b07b]d}, 0.94);
        \\  background-color: transparent;
        \\  outline: none;
        \\}}
        \\.stratty-sidebar row.stratty-tab-row {{
        \\  margin: 1px 8px 1px 0;
        \\  padding: 0;
        \\  border: 0;
        \\  box-shadow: none;
        \\}}
        \\.stratty-sidebar row.stratty-tab-row:selected {{
        \\  color: rgb({[b07r]d}, {[b07g]d}, {[b07b]d});
        \\  background-color: transparent;
        \\}}
        \\.stratty-row-card {{
        \\  border-radius: 7px;
        \\  background-color: transparent;
        \\}}
        \\.stratty-row-card-content {{
        \\  padding: 9px 9px 8px 10px;
        \\}}
        \\.stratty-tab-row:hover .stratty-row-card {{
        \\  background-color: rgba({[b03r]d}, {[b03g]d}, {[b03b]d}, 0.065);
        \\}}
        \\.stratty-tab-row:selected .stratty-row-card {{
        \\  background-color: transparent;
        \\  box-shadow: 0 8px 22px rgba(0, 0, 0, 0.08);
        \\}}
        \\.stratty-tab-row:selected .stratty-row-card-content {{
        \\  padding: 9px 10px;
        \\}}
        \\.stratty-selection-bar {{
        \\  border-radius: 2px;
        \\  background-color: transparent;
        \\}}
        \\.stratty-tab-row:selected .stratty-selection-bar {{
        \\  background-color: rgb({[b0br]d}, {[b0bg]d}, {[b0bb]d});
        \\  box-shadow: 0 0 10px rgba({[b0br]d}, {[b0bg]d}, {[b0bb]d}, 0.62);
        \\}}
        \\.stratty-role-icon {{
        \\  min-width: 23px;
        \\  min-height: 23px;
        \\}}
        \\.stratty-row-title {{
        \\  font-size: 12px;
        \\  font-weight: 630;
        \\  text-shadow: 0 1px 8px rgba(0, 0, 0, 0.55);
        \\}}
        \\.stratty-row-subtitle {{
        \\  color: rgba({[b05r]d}, {[b05g]d}, {[b05b]d}, 0.65);
        \\  font-family: monospace;
        \\  font-size: 10px;
        \\}}
        \\.stratty-workspace-row {{
        \\  margin: 9px 8px 0;
        \\  padding-left: 0;
        \\  padding-right: 0;
        \\  background-color: transparent;
        \\}}
        \\.stratty-workspace-name {{
        \\  padding: 5px 9px;
        \\  color: rgba({[b05r]d}, {[b05g]d}, {[b05b]d}, 0.52);
        \\  font-size: 10px;
        \\  font-weight: 750;
        \\  letter-spacing: 1.1px;
        \\  text-shadow: 0 1px 8px rgba(0, 0, 0, 0.45);
        \\}}
        \\.stratty-status {{
        \\  min-width: 7px;
        \\  min-height: 7px;
        \\}}
        \\.stratty-status.idle {{
        \\  color: rgba({[b05r]d}, {[b05g]d}, {[b05b]d}, 0.42);
        \\}}
        \\.stratty-status.running {{
        \\  color: rgb({[b0br]d}, {[b0bg]d}, {[b0bb]d});
        \\}}
        \\.stratty-status.attention {{
        \\  color: rgb({[b0ar]d}, {[b0ag]d}, {[b0ab]d});
        \\}}
        \\
    , .{
        .b03r = theme.base03.r,
        .b03g = theme.base03.g,
        .b03b = theme.base03.b,
        .b05r = theme.base05.r,
        .b05g = theme.base05.g,
        .b05b = theme.base05.b,
        .b07r = theme.base07.r,
        .b07g = theme.base07.g,
        .b07b = theme.base07.b,
        .b0ar = theme.base0a.r,
        .b0ag = theme.base0a.g,
        .b0ab = theme.base0a.b,
        .b0br = theme.base0b.r,
        .b0bg = theme.base0b.g,
        .b0bb = theme.base0b.b,
    });
}

fn relativePath(
    allocator: std.mem.Allocator,
    workspace: []const u8,
    cwd: []const u8,
) ?[:0]u8 {
    if (std.mem.eql(u8, workspace, cwd)) return null;
    if (!std.mem.startsWith(u8, cwd, workspace)) return null;
    if (workspace.len >= cwd.len or cwd[workspace.len] != std.fs.path.sep) return null;
    const suffix = cwd[workspace.len + 1 ..];
    if (suffix.len == 0) return null;
    return std.fmt.allocPrintSentinel(allocator, "./{s}", .{suffix}, 0) catch null;
}

fn roleIcon(
    allocator: std.mem.Allocator,
    config: *const CoreConfig,
    role: stratty.Role,
) *gtk.Image {
    var owned: ?[:0]u8 = null;
    defer if (owned) |path| allocator.free(path);

    const custom = switch (role) {
        .editor => pathValue(config.@"stratty-editor-icon"),
        .agent => pathValue(config.@"stratty-agent-icon"),
        .shell => null,
    };
    const path = if (validPath(custom)) |value|
        value
    else default: {
        const filename = switch (role) {
            .shell => "cannoli-shell.svg",
            .editor => "neovim.svg",
            .agent => "pi-coding-agent.svg",
        };
        owned = bundledIconPath(allocator, filename);
        break :default owned;
    };

    const image = if (path) |value|
        gtk.Image.newFromFile(value.ptr)
    else
        gtk.Image.newFromIconName("utilities-terminal-symbolic");
    image.setPixelSize(20);
    return image;
}

fn bundledIconPath(
    allocator: std.mem.Allocator,
    filename: []const u8,
) ?[:0]u8 {
    if (global.resourcesDir().app()) |resources| {
        const candidate = std.fmt.allocPrintSentinel(
            allocator,
            "{s}/stratty/icons/{s}",
            .{ resources, filename },
            0,
        ) catch return null;
        if (validPath(candidate) != null) return candidate;
        allocator.free(candidate);
    }

    // Development launches can inherit GHOSTTY_RESOURCES_DIR from an
    // installed upstream Ghostty. The executable-relative install layout is
    // authoritative for this fork and keeps all three bundled icons working.
    const executable = std.process.executablePathAlloc(global.io(), allocator) catch return null;
    defer allocator.free(executable);
    const directory = std.fs.path.dirname(executable) orelse return null;
    const candidate = std.fmt.allocPrintSentinel(
        allocator,
        "{s}/../share/ghostty/stratty/icons/{s}",
        .{ directory, filename },
        0,
    ) catch return null;
    if (validPath(candidate) != null) return candidate;
    allocator.free(candidate);
    return null;
}

fn pathValue(path: ?CoreConfig.Path) ?[:0]const u8 {
    const value = path orelse return null;
    return switch (value) {
        inline else => |resolved| resolved,
    };
}

fn validPath(path: ?[:0]const u8) ?[:0]const u8 {
    const value = path orelse return null;
    std.Io.Dir.accessAbsolute(global.io(), value, .{}) catch return null;
    return value;
}
