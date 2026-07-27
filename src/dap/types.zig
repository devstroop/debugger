const std = @import("std");

pub const DapBreakpoint = struct {
    line: u32,
    condition: ?[]const u8 = null,
    log_message: ?[]const u8 = null,
};

pub const StoppedInfo = struct {
    reason: []const u8,
    thread_id: i64,
    description: ?[]const u8 = null,
};

pub const Error = error{
    NotConnected,
    PortDiscoveryFailed,
    SsFailed,
    LsofFailed,
    PortNotFound,
    Timeout,
    DapRequestFailed,
    ProtocolError,
    NeedMoreData,
    ConnectionClosed,
    ReadError,
    MissingParams,
    InvalidSpawn,
};
