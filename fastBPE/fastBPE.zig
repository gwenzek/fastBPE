const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const warn = std.debug.warn;
const debug = std.debug.warn;

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

fn readTextFromBuff(word_count: *Vocab, buffer: []u8) !u64 {
    var n_words: u64 = 0;
    var w_start: u32 = 0;
    var w_end: u32 = 0;
    var next_char: u8 = ' ';
    // debug("Read line '{}'\n", .{ buffer });
    while (w_end < buffer.len) {
        next_char = buffer[w_end];
        // debug("Read char '{}' at ({}/{})\n", .{ next_char, w_end, buffer.len });
        if (next_char != ' ' and next_char != '\n' and w_end + 1 < buffer.len) {
            w_end += 1;
            continue;
        }

        if (w_end + 1 == buffer.len and buffer[w_end] != '\n') {
            // only include last file char if it's not a newline
            w_end += 1;
        }

        // end of word
        const w = buffer[w_start..w_end];
        w_start = w_end + 1;
        w_end = w_start;

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
                // debug("We should free {}", .{new_token});
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
            // debug("'{}' -> id: {}, ", .{ new_token, new_id });
            return new_id;
        }
    }
};

pub fn hasMoreOccurences(kv1: Vocab.KV, kv2: Vocab.KV) bool {
    if (kv1.value == kv2.value)
        return strCmp(kv1.key, kv2.key);
    return kv1.value > kv2.value;
}

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
        // debug("! {} {}\n", .{ word_count_arr[i].key, word_count_arr[i].value });
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
const PairCounts = std.AutoHashMap(WordPair, *PairCount);
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
        try state.ensureExtraCapacity(capacity);
        return state;
    }

    pub fn ensureExtraCapacity(self: *LearnBpeState, capacity: usize) !void {
        var len = self.contiguous_counts.items.len;
        try self.contiguous_counts.ensureCapacity(len + capacity);
        try self.pair_counts.ensureCapacity(len + capacity);
        try self.where.ensureCapacity(len + capacity);
    }

    pub fn inc_count(self: *LearnBpeState, w1: u32, w2: u32, v: i32, wid: u32) !void {
        if (v == 0) return;
        const pair = WordPair{ .w1 = w1, .w2 = w2 };
        if (self.pair_counts.get(pair)) |kv| {
            // assert(kv.value.count + v >= 0);
            const old_count = kv.value.count;
            kv.value.count += v;
            // debug("inc_count: update {} {} {}={}+{}, ", .{ kv.value.w1, kv.value.w2, kv.value.count, old_count, v });
            if (v > 0) {
                var words = &self.where.get(pair).?.value;
                _ = try words.put(wid, {});
            }
            // should we remove from where if kv.value.count falls to 0 ?
        } else {
            // can't decrement from inexisting pair.
            assert(v > 0);
            const pc = PairCount.init(pair, v);
            // debug("inc_count: append {} {} {}, ", .{ pc.w1, pc.w2, pc.count });
            var pc_ptr: *PairCount = self.contiguous_counts.addOneAssumeCapacity();
            pc_ptr.* = pc;
            _ = self.pair_counts.putAssumeCapacity(pair, pc_ptr);
            var words = std.AutoHashMap(u32, void).init(self.where.allocator);
            _ = try words.put(wid, {});
            _ = self.where.putAssumeCapacity(pair, words);
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

    // debug("\nstarting tokenize\n", .{});
    try tokenize(&word_count, &idx, &words, &counts);
    var state = try LearnBpeState.init(alloc, reservation);

    const print = std.io.getStdOut().outStream().print;
    var counts_span = counts.span();
    const all_words = words.span();

    // debug("\nstarting count_in_word\n", .{});
    for (all_words) |word, wi| {
        try count_in_word(word, @intCast(u32, wi), counts_span[wi], &state);
    }
    // debug("\nstarting max_p\n", .{});
    var i: usize = 0;
    while (i < kNPairs) : (i += 1) {
        var max_p = find_maxp(&state.contiguous_counts) orelse break;
        // create new token for pair. replace
        var tokens = &idx.tokens.items;
        // debug("\nmax_p {} {} {}, ", .{ max_p.w1, max_p.w2, max_p.count });
        var new_token = try concat(idx.tokens.allocator, tokens.*[max_p.w1], tokens.*[max_p.w2]);
        _ = try print("{} {} {}\n", .{ tokens.*[max_p.w1], tokens.*[max_p.w2], max_p.count });
        var new_token_id = try idx.getOrAdd(new_token, false);
        // debug("new_token_id {}, ", .{new_token_id});

        var where_it = state.where.get(WordPair{ .w1 = max_p.w1, .w2 = max_p.w2 }).?.value.iterator();
        while (where_it.next()) |wi| {
            var full_word = &all_words[wi.key];
            var cwi = counts.items[wi.key];
            try state.ensureExtraCapacity(full_word.items.len);
            var cur_pair = WordPair{ .w2 = full_word.items[0] };
            var j: usize = 0;
            while (j < full_word.items.len) : (j += 1) {
                const w = full_word.items[j];
                if (j == 0) continue;

                cur_pair.w1 = cur_pair.w2;
                cur_pair.w2 = w;

                if (cur_pair.w1 != max_p.w1 or cur_pair.w2 != max_p.w2)
                    continue;

                // we've found the pair

                // change count for word before us.
                if (j > 1) {
                    const w0 = full_word.items[j - 2];
                    try state.inc_count(w0, cur_pair.w1, -cwi, wi.key);
                    try state.inc_count(w0, new_token_id, cwi, wi.key);
                }

                // Remove [w1, w2] from full_word insert w1@@w2 instead.
                // TODO only mark the token and remove later.
                full_word.items[j - 1] = new_token_id;

                // update count for next token
                if (j + 1 < full_word.items.len) {
                    const w3 = full_word.items[j + 1];
                    try state.inc_count(cur_pair.w2, w3, -cwi, wi.key);
                    try state.inc_count(new_token_id, w3, cwi, wi.key);
                }
                _ = full_word.orderedRemove(j);

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

    for (word.span()) |token, i| {
        cur_pair.w1 = cur_pair.w2;
        cur_pair.w2 = token;
        if (i == 0) // cur_pair.w1 isn't correctly initialized
            continue;

        if (pair_counts.get(cur_pair)) |pair_count| {
            const old_cont = pair_count.value.count;
            pair_count.value.count += count;
            var w = where.get(cur_pair);
            if (count > 0) {
                _ = try w.?.value.put(wi, {});
            } else {
                _ = w.?.value.remove(wi);
            }
            // debug("update {} {} {}={}+{}, ", .{ pair_count.value.w1, pair_count.value.w2, pair_count.value.count, old_cont, count });
        } else {
            const pair_count = PairCount.init(cur_pair, count);
            var pc_ptr: *PairCount = contiguous_counts.addOneAssumeCapacity();
            pc_ptr.* = pair_count;
            // debug("append {} {} {}, ", .{ pair_count.w1, pair_count.w2, pair_count.count });
            // debug("len(contiguous_counts) == {}", .{contiguous_counts.items.len});

            _ = try pair_counts.put(cur_pair, pc_ptr);
            var set = std.AutoHashMap(u32, void).init(where.allocator);
            if (count > 0) _ = try set.put(wi, {});
            _ = try where.put(cur_pair, set);
        }
    }
}

fn find_maxp(contiguous_counts: *std.ArrayList(PairCount)) ?*PairCount {
    var counts = contiguous_counts.items;
    assert(counts.len > 0);
    var zero = PairCount{
        .w1 = 0,
        .w2 = 0,
        .count = -1,
    };
    var max_p: *PairCount = &zero;
    for (counts) |*x| {
        if (x.count > max_p.count) {
            max_p = x;
        } else if (x.count == max_p.count) {
            if (x.w1 < max_p.w1) {
                max_p = x;
            } else if (x.w1 == max_p.w1 and x.w2 < max_p.w2) {
                max_p = x;
            }
        }
    }
    if (max_p.count <= 0) return null;
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
        // debug("{}: {}\n", .{ i, arg });
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
