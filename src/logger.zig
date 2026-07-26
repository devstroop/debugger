const std = @import("std");

const stderr_fd = std.fs.File.stderr();

pub const Level = enum(u3) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,

    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }
};

pub const Logger = struct {
    min_level: Level = Level.info,

    pub fn init() Logger {
        return Logger{};
    }

    fn writeToStderr(msg: []const u8) void {
        _ = stderr_fd.write(msg) catch {};
    }

    pub fn log(self: *const Logger, level: Level, msg: []const u8) void {
        if (@intFromEnum(level) < @intFromEnum(self.min_level)) return;
        const ts = std.time.timestamp();
        const line = std.fmt.allocPrint(std.heap.page_allocator, "[{}] [{s}] {s}\n", .{ ts, level.label(), msg }) catch return;
        defer std.heap.page_allocator.free(line);
        writeToStderr(line);
    }

    pub fn debug(self: *const Logger, msg: []const u8) void {
        self.log(.debug, msg);
    }
    pub fn info(self: *const Logger, msg: []const u8) void {
        self.log(.info, msg);
    }
    pub fn warn(self: *const Logger, msg: []const u8) void {
        self.log(.warn, msg);
    }
    pub fn logErr(self: *const Logger, msg: []const u8) void {
        self.log(.err, msg);
    }

    pub fn fmt(self: *const Logger, level: Level, comptime fmt_str: []const u8, args: anytype) void {
        if (@intFromEnum(level) < @intFromEnum(self.min_level)) return;
        const line = std.fmt.allocPrint(std.heap.page_allocator, fmt_str ++ "\n", args) catch return;
        defer std.heap.page_allocator.free(line);
        writeToStderr(line);
    }
};
