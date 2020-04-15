// #pragma once

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const warn = std.debug.warn;

const c = @cImport({
    //   @cInclude("algorithm");
    //   @cInclude("assert.h");
    //   @cInclude("errno.h");
    //   @cInclude("fcntl.h");
    //   @cInclude("fstream");
    //   @cInclude("functional");
    //   @cInclude("iostream");
    //   @cInclude("list");
    //   @cInclude("set");
    @cInclude("stdio.h");
    // @cInclude("string");
    // @cInclude("cstring");
    @cInclude("sys/mman.h");
    // @cInclude("sys/stat.h");
    // @cInclude("thread");
    // @cInclude("unistd.h"); // ftruncat
    // @cInclude("unordered_map");
    // @cInclude("unordered_set");
    // @cInclude("vector");
});

pub const alloc = std.heap.c_allocator;
// const c_alloc = std.heap.c_allocator;
// var alloc: *std.mem.Allocator = &std.heap.loggingAllocator(c_alloc, std.io.getStdOut().outStream()).allocator;

// using namespace std;

const kMaxPairs: i32 = 1000 * 1000 * 1000;
const kThreads: i32 = max(1, min(10, int(c.thread.hardware_concurrency())));
const kEndWord = "</w>";
const kEndWordLength: i32 = 4;
const kTokenDelim = "@@";
const kTokenDelimLength: i32 = 2;

const kReadOnly = std.fs.File.OpenFlags{ .read = true };

// pub fn safeOpen(const char *file_path, int flags, mode_t mode = 0) !void {
//   int fd = open(file_path, flags, mode);
//   if (fd < 0) {
//     fprintf(stderr, "Cannot open text file %s\n", file_path);
//     exit(EXIT_FAILURE);
//   }
//   return fd;
// }
// extern fn malloc(size: size_t) ?*u8;

fn strCmp(word1: []const u8, word2: []const u8) bool {
    if (word1.len > word2.len) return !(strCmp(word2, word1));

    for (word1) |c1, i| {
        const c2 = word2[i];
        if (c1 == c2) continue;
        return c1 < c2;
    }
    // if lengths match then they are equal and "word1 < word2" is false.
    return word1.len < word2.len;
}

test "compare string to prefix" {
    assert(strCmp("foo", "foobar"));
    assert(!strCmp("foobar", "foo"));
}

test "compare string" {
    assert(!strCmp("foo", "bar"));
    assert(strCmp("bar", "foo"));
}

const Slice = struct {
    start: u32 = 0,
    end: u32 = 0,
};

fn readTextFromBuff(word_count: *Vocab, buffer: []u8) !u64 {
    var n_words: u64 = 0;
    var word = Slice{};
    var next_char: u8 = ' ';
    // warn("Read line '{}'\n", .{ buffer });
    while (word.end < buffer.len) {
        next_char = buffer[word.end];
        // warn("Read char '{}' at ({}/{})\n", .{ next_char, word.end, buffer.len });
        if (next_char != ' ' and next_char != '\n' and word.end + 1 < buffer.len) {
            word.end += 1;
            continue;
        }

        if (word.end + 1 == buffer.len and buffer[word.end] != '\n') {
            // only include last file char if it's not a newline
            word.end += 1;
        }

        // end of word
        const w = buffer[word.start..word.end];
        word.start = word.end + 1;
        word.end = word.start;

        if (w.len == 0) continue;
        n_words += 1;
        if (word_count.get(w)) |wc| {
            wc.value += 1;
        } else {
            const w_copy = try word_count.allocator.alloc(u8, w.len);
            std.mem.copy(u8, w_copy, w);
            _ = try word_count.put(w_copy, 1);
        }
    }
    return n_words;
}

pub fn readText(fp: []const u8, word_count: *Vocab) !void {
    var n_words: u64 = 0;
    // Read from stdin
    if (fp.len == 1 and fp[0] == '-') {
        var line_buf: [4096]u8 = undefined;
        const stdin = std.io.bufferedInStream(std.io.getStdIn().inStream()).inStream();
        while (stdin.readUntilDelimiterOrEof(&line_buf, '\n') catch |err| switch (err) {
            error.StreamTooLong => blk: {
                // Line is longer than buf size, skip it.
                try stdin.skipUntilDelimiterOrEof(' ');
                break :blk &line_buf;
            },
            else => |e| return e,
        }) |line| {
            n_words += try readTextFromBuff(word_count, line);
        }
    } else {
        var realpath_buff: [1024]u8 = undefined;
        const realpath = try std.fs.realpath(fp, &realpath_buff);
        const file = try std.fs.openFileAbsolute(fp, kReadOnly);

        warn("Loading vocabulary from {} ...\n", .{fp});

        const stat = try file.stat();
        const buffer: []u8 = try std.os.mmap(null, stat.size, c.PROT_READ, c.MAP_PRIVATE, file.handle, 0);

        n_words = try readTextFromBuff(word_count, buffer);
    }
    warn("Read {} words ({} unique) from text file.\n", .{ n_words, word_count.size });
}

pub const Vocab = std.StringHashMap(u32);

pub fn hasMoreOccurences(kv1: Vocab.KV, kv2: Vocab.KV) bool {
    if (kv1.value == kv2.value)
        return strCmp(kv1.key, kv2.key);
    return kv1.value > kv2.value;
}

// fn hasMoreOccurencesEntry(entry1: Vocab.Entry, entry2: Vocab.Entry) bool {
//     if (!entry1.used or !entry2.used)
//         return entry1.used <= entry2.used;
//     return entry1.kv.value <= entry2.kv.value;
// }

fn getVocab(inputFile1: []const u8, inputFile2: []const u8) !void {
    // get vocab
    // @compileLog(@sizeOf(usize), @sizeOf(u64));
    var word_count = Vocab.init(alloc);
    try readText(inputFile1, &word_count);
    if (inputFile2.len > 0) {
        try readText(inputFile2, &word_count);
    }
    var word_count_arr = try alloc.alloc(Vocab.KV, word_count.size);
    var i: u32 = 0;
    var it = word_count.iterator();
    while (it.next()) |wc| {
        word_count_arr[i] = wc.*;
        // warn("! {} {}\n", .{ word_count_arr[i].key, word_count_arr[i].value });
        i += 1;
    }

    assert(i == word_count.size);
    warn("Word count: {}\n", .{word_count.size});
    std.sort.sort(Vocab.KV, word_count_arr, hasMoreOccurences);
    // std.sort.sort(Vocab.Entry, word_count, hasMoreOccurencesEntry);

    const stdout_file = std.io.getStdOut();
    // print sorted vocab
    for (word_count_arr) |wc|
        try stdout_file.outStream().print("{} {}\n", .{ wc.key, wc.value });
}

fn u32LessThan(x: u32, y: u32) bool {
    return x < y;
}

pub fn main() anyerror!void {
    var args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    for (args) |arg, i| {
        if (i == 0) continue;
        warn("{}: {}\n", .{ arg, i });
    }
    if (args.len < 2) {
        return;
    }
    try getVocab(args[1], "");
}
