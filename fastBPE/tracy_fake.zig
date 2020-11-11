pub const std = @import("std");

pub const Ctx = struct {
    pub fn end(self: Ctx) void {}
};

pub inline fn trace(comptime src: std.builtin.SourceLocation) Ctx {
    return .{};
}
