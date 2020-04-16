// #pragma once

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
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

var alloc: *Allocator = undefined;
// const c_alloc = std.heap.c_allocator;
// var alloc: *std.mem.Allocator = &std.heap.loggingAllocator(c_alloc, std.io.getStdOut().outStream()).allocator;

// using namespace std;

const kMaxPairs: i32 = 1000; //* 1000 * 1000;
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

pub const Vocab = std.StringHashMap(i32);
pub const WordIndex = struct {
    ids: std.StringHashMap(u32) = undefined,
    tokens: std.ArrayList([]const u8) = undefined,

    pub fn init(allocator: *Allocator, capacity: usize) !WordIndex {
        var idx = WordIndex{
            .ids = std.StringHashMap(u32).init(allocator),
            .tokens = std.ArrayList([]const u8).init(allocator),
        };
        try idx.ids.ensureCapacity(capacity);
        try idx.tokens.ensureCapacity(capacity);
        return idx;
    }

    pub fn getOrAdd(self: *WordIndex, word: []const u8, end_of_word: bool) !u32 {
        var new_token = word;
        var need_free = false;
        if (end_of_word) {
            new_token = try concat(self.ids.allocator, word, kEndWord);
            need_free = true;
        }
        defer {
            if (need_free) {
                // warn("We should free {}", .{new_token});
                self.ids.allocator.free(new_token);
            }
        }

        if (self.ids.getValue(new_token)) |id| {
            return id;
        } else {
            var new_id = @intCast(u32, self.tokens.items.len);
            _ = self.ids.putAssumeCapacity(new_token, new_id);
            self.tokens.appendAssumeCapacity(new_token);
            need_free = false;
            warn("'{}' -> id: {}, ", .{ new_token, new_id });
            return new_id;
        }
    }
};

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

    const stdout_file = std.io.getStdOut();
    // print sorted vocab
    for (word_count_arr) |wc|
        try stdout_file.outStream().print("{} {}\n", .{ wc.key, wc.value });
}

fn u32LessThan(x: u32, y: u32) bool {
    return x < y;
}

fn concat(allocator: *Allocator, a: []const u8, b: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, a.len + b.len);
    std.mem.copy(u8, result, a);
    std.mem.copy(u8, result[a.len..], b);
    return result;
}

const WordPair = struct { w1: u32 = 0, w2: u32 = 0 };
const PairCount = struct {
    w1: u32 = 0,
    w2: u32 = 0,
    count: i32 = 0,

    pub fn init(pair: WordPair, count: i32) PairCount {
        return PairCount{ .w1 = pair.w1, .w2 = pair.w2, .count = count };
    }
};
const PairCounts = std.AutoHashMap(WordPair, PairCount);
const Where = std.AutoHashMap(WordPair, std.AutoHashMap(u32, void));

const LearnBpeState = struct {
    pair_counts: PairCounts,
    where: Where,
    contiguous_counts: std.ArrayList(PairCount),

    pub fn init(allocator: *std.mem.Allocator, capacity: u32) !LearnBpeState {
        var state = LearnBpeState{
            .pair_counts = PairCounts.init(allocator),
            .where = Where.init(allocator),
            .contiguous_counts = std.ArrayList(PairCount).init(allocator),
        };
        try state.contiguous_counts.ensureCapacity(capacity);
        try state.pair_counts.ensureCapacity(capacity);
        try state.where.ensureCapacity(capacity);
        return state;
    }

    pub fn change_count(self: *LearnBpeState, pair: WordPair, v: i32, sentence_id: u32) !void {
        if (v == 0) return;

        if (self.pair_counts.get(pair)) |kv| {
            // assert(kv.value.count + v >= 0);
            kv.value.count += v;
            if (v > 0) {
                var sentences = self.where.getValue(pair).?;
                _ = try sentences.put(sentence_id, {});
            }
        } else {
            if (v > 0) {
                const pc = PairCount.init(pair, v);
                self.contiguous_counts.appendAssumeCapacity(pc);
                _ = self.pair_counts.putAssumeCapacity(pair, pc);
                var sentences = std.AutoHashMap(u32, void).init(self.where.allocator);
                _ = try sentences.put(sentence_id, {});
                _ = self.where.putAssumeCapacity(pair, sentences);
            }
        }
    }
};

const NOT_WORD: u32 = -1;

fn learnbpe(kNPairs: i32, inputFile1: []const u8, inputFile2: []const u8) !void {
    // get vocab
    var word_count = Vocab.init(alloc);
    try readText(inputFile1, &word_count);
    if (inputFile2.len > 0) {
        try readText(inputFile2, &word_count);
    }

    // a token is an int, it represents a string
    const reservation = @intCast(u32, 20 * kNPairs);
    var idx = try WordIndex.init(alloc, reservation);
    var words = std.ArrayList(std.ArrayList(u32)).init(alloc);
    var counts = std.ArrayList(i32).init(alloc);

    warn("starting tokenize\n", .{});
    try tokenize(&word_count, &idx, &words, &counts);
    var state = try LearnBpeState.init(alloc, reservation);

    const print = std.io.getStdOut().outStream().print;
    var counts_span = counts.span();
    const all_words = words.span();

    warn("starting count_in_word\n", .{});
    for (all_words) |word, wi| {
        try count_in_word(word, @intCast(u32, wi), counts_span[wi], &state);
    }
    warn("starting max_p\n", .{});
    var i: usize = 0;
    while (i < kNPairs) : (i += 1) {
        var max_p = find_maxp(&state.contiguous_counts) orelse break;
        // create new token for pair. replace
        var tokens = idx.tokens.span();
        var new_token = try concat(idx.tokens.allocator, tokens[max_p.w1], tokens[max_p.w2]);
        _ = try print("{} {} {}\n", .{ tokens[max_p.w1], tokens[max_p.w2], max_p.count });
        var new_token_id = try idx.getOrAdd(new_token, false);

        var where_it = state.where.get(WordPair{ .w1 = max_p.w1, .w2 = max_p.w2 }).?.value.iterator();
        while (where_it.next()) |wi| {
            var sentence = all_words[wi.key];
            var full_sentence = all_words[wi.key].items;
            var cwi = counts.items[wi.key];
            var cur_pair = WordPair{ .w2 = full_sentence[0] };
            var j: usize = 0;
            while (j < sentence.items.len) : (j += 1) {
                const w = full_sentence[j];
                if (j == 0) continue;

                cur_pair.w1 = cur_pair.w2;
                cur_pair.w2 = w;

                if (cur_pair.w1 != max_p.w1 or cur_pair.w2 != max_p.w2)
                    continue;

                // we've found the pair

                // change count for word before us.
                if (j > 1) {
                    const w0 = full_sentence[j - 2];
                    try state.change_count(WordPair{
                        .w1 = w0,
                        .w2 = cur_pair.w1,
                    }, -cwi, wi.key);
                    try state.change_count(WordPair{ .w1 = w0, .w2 = new_token_id }, cwi, wi.key);
                }

                // Remove [w1, w2] from sentence insert w1@@w2 instead.
                // TODO only mark the token and remove later.
                full_sentence[j - 1] = new_token_id;
                _ = sentence.orderedRemove(j);

                // update count for next token
                if (j < sentence.items.len) {
                    const w3 = full_sentence[j];
                    try state.change_count(WordPair{ .w1 = cur_pair.w2, .w2 = w3 }, -cwi, wi.key);
                    try state.change_count(WordPair{ .w1 = new_token_id, .w2 = w3 }, cwi, wi.key);
                }

                cur_pair.w2 = new_token_id;
            }
            max_p.count = -1;
        }
    }
}

fn tokenize(word_count: *Vocab, idx: *WordIndex, full_words: *std.ArrayList(std.ArrayList(u32)), counts: *std.ArrayList(i32)) !void {
    var it = word_count.iterator();
    try full_words.ensureCapacity(word_count.count());
    try counts.ensureCapacity(word_count.count());
    while (it.next()) |wc| {
        var realLength: i32 = 0;
        var word: []const u8 = wc.key;
        var current_word = std.ArrayList(u32).init(full_words.allocator);
        try current_word.ensureCapacity(word.len);
        counts.appendAssumeCapacity(wc.value);

        var lastStart: usize = 0;
        // TODO: try std.unicode.Utf8Iterator
        for (word) |char, pos| {
            if (pos == 0)
                continue;
            if ((char & 0xc0) == 0x80) // continuation byte
                continue;
            realLength += 1;
            var id = try idx.getOrAdd(word[lastStart..pos], false);
            current_word.appendAssumeCapacity(id);
            lastStart = pos;
        }
        var id = try idx.getOrAdd(word[lastStart..], true);
        current_word.appendAssumeCapacity(id);
        full_words.appendAssumeCapacity(current_word);
    }
}

fn count_in_word(word: std.ArrayList(u32), wi: u32, count: i32, state: *LearnBpeState) !void {
    var first_round = true;
    var cur_pair = WordPair{};
    // Use pointers to actually modify the state.
    var pair_counts = &state.pair_counts;
    var where = &state.where;
    var contiguous_counts = &state.contiguous_counts;
    try contiguous_counts.ensureCapacity(contiguous_counts.items.len + word.items.len);

    warn("word {}({}) len: {},", .{ wi, &word.items, word.span().len });
    for (word.span()) |token, i| {
        cur_pair.w1 = cur_pair.w2;
        cur_pair.w2 = token;
        if (i == 0) // cur_pair.w1 isn't correctly initialized
            continue;

        if (pair_counts.get(cur_pair)) |pair_count| {
            pair_count.value.count += count;
            warn("({}, {}) += {}, ", .{ cur_pair.w1, cur_pair.w2, count });
            var w = where.get(cur_pair);
            if (count > 0) {
                _ = try w.?.value.put(wi, {});
            } else {
                _ = w.?.value.remove(wi);
            }
        } else {
            warn("({}, {}) := {}, ", .{ cur_pair.w1, cur_pair.w2, count });

            const pair_count = PairCount.init(cur_pair, count);
            contiguous_counts.appendAssumeCapacity(pair_count);
            warn("len(contiguous_counts) == {}", .{contiguous_counts.items.len});

            _ = try pair_counts.put(cur_pair, pair_count);
            var set = std.AutoHashMap(u32, void).init(where.allocator);
            if (count > 0) _ = try set.put(wi, {});
            _ = try where.put(cur_pair, set);
        }
    }
    warn("len(contiguous_counts) == {}", .{contiguous_counts.items.len});
}

fn find_maxp(contiguous_counts: *std.ArrayList(PairCount)) ?*PairCount {
    var max_c: i32 = 0;
    var counts = contiguous_counts.items;
    assert(counts.len > 0);
    var max_p: *PairCount = &counts[0];
    for (counts[1..]) |*x| {
        if (x.count > max_c) {
            max_c = x.count;
            max_p = x;
        } else if (x.count == max_c and x.w1 < max_p.w1) {
            max_p = x;
        } else if (x.count == max_c and x.w1 == max_p.w1 and x.w2 < max_p.w2) {
            max_p = x;
        }
    }
    return max_p;
}

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    alloc = &arena.allocator;

    var args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    for (args) |arg, i| {
        if (i == 0) continue;
        warn("{}: {}\n", .{ i, arg });
    }
    if (args.len < 3) {
        std.process.exit(1);
    }
    if (std.ascii.eqlIgnoreCase(args[1], "getvocab")) {
        try getVocab(args[2], "");
    } else if (std.ascii.eqlIgnoreCase(args[1], "learnbpe")) {
        const n_bpe = try std.fmt.parseInt(i32, args[2], 10);
        try learnbpe(n_bpe, args[3], "");
    } else {
        std.process.exit(1);
    }
}
