const std = @import("std");
const learn = @import("learnBPE.zig");
const apply = @import("applyBPE.zig");

const warn = std.debug.warn;
const resolve = learn.resolve;

fn get_args(args: [][]const u8, n: usize) []const u8 {
    if (n >= args.len) return "";
    return args[n];
}

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var alloc = &arena.allocator;

    var args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    if (args.len < 2) std.process.exit(1);
    const cmd = args[1];
    var cmd_args = args[2..];
    // TODO use https://github.com/MasterQ32/zig-args ?
    if (std.ascii.eqlIgnoreCase(cmd, "getvocab")) {
        try learn.getVocab(cmd_args[0], "", alloc);
    } else if (std.ascii.eqlIgnoreCase(cmd, "learnbpe")) {
        const n_bpe = try std.fmt.parseInt(i32, cmd_args[0], 10);
        try learn.learnbpe(n_bpe, cmd_args[1], "", alloc);
    } else if (std.ascii.eqlIgnoreCase(cmd, "applybpe")) {
        std.debug.assert(cmd_args.len == 2 or cmd_args.len == 3);
        try apply.applybpe(resolve(cmd_args[0]), resolve(cmd_args[1]), get_args(cmd_args, 2), alloc);
    } else {
        std.process.exit(1);
    }
}
