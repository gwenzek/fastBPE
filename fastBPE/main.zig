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
    // var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // defer arena.deinit();
    // var alloc = &arena.allocator;
    comptime var GPA = std.heap.GeneralPurposeAllocator(.{
        // Number of stack frames to capture.
        .stack_trace_frames = 16,

        // If true, the allocator will have two fields:
        //  * `total_requested_bytes` which tracks the total allocated bytes of memory requested.
        //  * `requested_memory_limit` which causes allocations to return `error.OutOfMemory`
        //    when the `total_requested_bytes` exceeds this limit.
        // If false, these fields will be `void`.
        .enable_memory_limit = false,

        // Whether to enable safety checks.
        .safety = true,

        // Whether the allocator may be used simultaneously from multiple threads.
        .thread_safe = true,

        // This is a temporary debugging trick you can use to turn segfaults into more helpful
        // logged error messages with stack trace details. The downside is that every allocation
        // will be leaked!
        .never_unmap = true,
    }){};
    var alloc = &GPA.allocator;
    // GPA.deinit() returns true when we have leaks.
    defer std.debug.assert(!GPA.deinit());

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
