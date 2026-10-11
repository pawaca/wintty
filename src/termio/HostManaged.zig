//! A termio backend with no process: the embedder carries the IO. Bytes the
//! terminal emits go to the embedder's write callback, size changes to its
//! resize callback, and the embedder feeds output through
//! ghostty_surface_write_buffer.
//!
//! Adapted from libghostty-spm's host-managed IO patch
//! (https://github.com/Lakr233/libghostty-spm), MIT License,
//! Copyright (c) 2026 @Lakr233.

const HostManaged = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");

userdata: ?*anyopaque = null,
write: Config.Write,
resize_cb: ?Config.Resize = null,
grid_size: renderer.GridSize = .{
    .columns = 0,
    .rows = 0,
},
screen_size: renderer.ScreenSize = .{
    .width = 0,
    .height = 0,
},

pub const Config = struct {
    pub const Write = *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void;
    pub const Resize = *const fn (?*anyopaque, u16, u16, u32, u32) callconv(.c) void;

    userdata: ?*anyopaque = null,
    write: Write,
    resize: ?Resize = null,
};

pub fn init(cfg: Config) HostManaged {
    return .{
        .userdata = cfg.userdata,
        .write = cfg.write,
        .resize_cb = cfg.resize,
    };
}

pub fn deinit(self: *HostManaged) void {
    _ = self;
}

pub fn initTerminal(self: *HostManaged, term: *terminal.Terminal) void {
    self.grid_size = .{
        .columns = term.cols,
        .rows = term.rows,
    };
    self.screen_size = .{
        .width = term.width_px,
        .height = term.height_px,
    };
}

pub fn threadEnter(
    self: *HostManaged,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = alloc;
    _ = io;

    td.backend = .{ .host_managed = .{} };
    self.notifyResize();
}

pub fn threadExit(self: *HostManaged, td: *termio.Termio.ThreadData) void {
    _ = self;
    _ = td;
}

pub fn focusGained(
    self: *HostManaged,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    _ = td;
    _ = focused;
}

pub fn resize(
    self: *HostManaged,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    self.grid_size = grid_size;
    self.screen_size = screen_size;
    self.notifyResize();
}

pub fn queueWrite(
    self: *HostManaged,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = alloc;
    _ = td;
    _ = linefeed;

    if (data.len == 0) return;
    self.write(self.userdata, data.ptr, data.len);
}

pub fn childExitedAbnormally(
    self: *HostManaged,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = self;
    _ = gpa;
    _ = t;
    _ = exit_code;
    _ = runtime_ms;
}

fn notifyResize(self: *HostManaged) void {
    const resize_cb = self.resize_cb orelse return;
    resize_cb(
        self.userdata,
        self.grid_size.columns,
        self.grid_size.rows,
        self.screen_size.width,
        self.screen_size.height,
    );
}

pub const ThreadData = struct {
    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }
};
