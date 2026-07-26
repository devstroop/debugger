const std = @import("std");
const Logger = @import("../logger.zig").Logger;
const Level = @import("../logger.zig").Level;

test "Logger init defaults to info level" {
    const logger = Logger.init();
    try std.testing.expectEqual(@as(Level, Level.info), logger.min_level);
}

test "Logger level labels are correct" {
    try std.testing.expectEqualStrings("DEBUG", Level.debug.label());
    try std.testing.expectEqualStrings("INFO", Level.info.label());
    try std.testing.expectEqualStrings("WARN", Level.warn.label());
    try std.testing.expectEqualStrings("ERROR", Level.err.label());
}

test "Logger level enum ordering" {
    // Debug < Info < Warn < Error
    try std.testing.expect(@intFromEnum(Level.debug) < @intFromEnum(Level.info));
    try std.testing.expect(@intFromEnum(Level.info) < @intFromEnum(Level.warn));
    try std.testing.expect(@intFromEnum(Level.warn) < @intFromEnum(Level.err));
}

test "Logger filters messages below min_level" {
    var logger = Logger.init();
    logger.min_level = Level.warn;

    // debug and info should be filtered (no panic = pass)
    logger.debug("this debug should be filtered");
    logger.info("this info should be filtered");
    logger.warn("this warn should pass");
    logger.logErr("this error should pass");
}

test "Logger.fmt respects level filter" {
    var logger = Logger.init();
    logger.min_level = Level.err;

    logger.fmt(.debug, "filtered debug {d}", .{1});
    logger.fmt(.info, "filtered info {d}", .{2});
    logger.fmt(.warn, "filtered warn {d}", .{3});
    logger.fmt(.err, "passing error {d}", .{4});
}
