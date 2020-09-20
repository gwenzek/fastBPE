const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Writer = std.fs.File.Writer;
const assert = std.debug.assert;
const warn = std.debug.warn;

const c = @cImport({
    @cInclude("sys/mman.h");
});

fn debug(any: anytype) void {
    std.debug.warn("[DEBUG]");
    std.debug.warn(any);
    std.debug.warn("\n");
}

const kMaxPairs: i32 = 1000 * 1000 * 1000;
const kThreads: i32 = max(1, min(10, int(c.thread.hardware_concurrency())));
pub const kEndWord = comptime "</w>";
pub const kTokenDelim = comptime "@@";

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

fn readWordsFromBuff(word_count: *Vocab, buffer: []u8) !u64 {
    var n_words: u64 = 0;
    var w_start: u32 = 0;
    var w_end: u32 = 0;
    var next_char: u8 = ' ';
    while (w_end < buffer.len) {
        next_char = buffer[w_end];
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
        if (word_count.getEntry(w)) |wc| {
            wc.value += 1;
        } else {
            const w_copy = try word_count.allocator.alloc(u8, w.len);
            std.mem.copy(u8, w_copy, w);
            _ = try word_count.put(w_copy, 1);
        }
    }
    return n_words;
}

pub fn readWords(fp: []const u8, word_count: *Vocab) !void {
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
            n_words += try readWordsFromBuff(word_count, line);
        }
    } else {
        var realpath_buff: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const realpath = try std.fs.realpath(fp, &realpath_buff);
        const file = try std.fs.openFileAbsolute(fp, .{ .read = true });

        warn("Loading vocabulary from {} ...\n", .{fp});

        const stat = try file.stat();
        const buffer: []u8 = try std.os.mmap(null, stat.size, c.PROT_READ, c.MAP_PRIVATE, file.handle, 0);

        n_words = try readWordsFromBuff(word_count, buffer);
    }
    warn("Read {} words ({} unique) from text file.\n", .{ n_words, word_count.count() });
}

pub const Vocab = std.StringHashMap(i32);
const VocabEntry = Vocab.Entry;
pub const VocabHeader = packed struct {
    entries: [*]VocabEntry,
    capacity: Vocab.Size,
};

/// Orders word by number of occurences, and alphabetical order in case of ties.
fn hasMoreOccurences(context: void, kv1: Vocab.Entry, kv2: Vocab.Entry) bool {
    if (kv1.value == kv2.value)
        return strCmp(kv1.key, kv2.key);
    return kv1.value > kv2.value;
}

/// Count words in given **tokenized** files.
/// Output is sorted by decreasing order.
pub fn getVocab(inputFile1: []const u8, inputFile2: []const u8, allocator: *Allocator) !void {
    var word_count = Vocab.init(allocator);
    try readWords(inputFile1, &word_count);
    if (inputFile2.len > 0) {
        try readWords(inputFile2, &word_count);
    }
    // Ideally we could salvage the word_count buffer as we iterate through it.
    // We used to be able to do that, but not anymore.
    // var unmanaged = word_count.unmanaged;
    // @ptrCast(*VocabHeader, @ptrCast([*]VocabHeader, unmanaged.metadata.?) - 1)
    // var entries_ptr: [*]VocabEntry = .entries;
    // var entries = entries_ptr[]
    var entries: []VocabEntry = try allocator.alloc(VocabEntry, word_count.count());
    var i: usize = 0;
    var it = word_count.iterator();
    while (it.next()) |entry| {
        entries[i] = entry.*;
        i += 1;
    }

    // var entries: []VocabEntry = word_count.unmanaged.recycle();
    defer word_count.deinit();
    warn("Word count: {}\n", .{entries.len});
    std.sort.sort(VocabEntry, entries, {}, hasMoreOccurences);

    const stdout_file = std.io.getStdOut();
    // print sorted vocab
    for (entries) |entry| {
        try stdout_file.outStream().print("{} {}\n", .{ entry.key, entry.value });
    }
}

pub const WordIndex = struct {
    ids: std.StringHashMap(u32) = undefined,
    tokens: std.ArrayList([]const u8) = undefined,

    pub fn init(allocator: *Allocator, capacity: u32) !WordIndex {
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
            new_token = try strConcat(self.ids.allocator, word, kEndWord);
            need_free = true;
        }
        defer {
            if (need_free) {
                self.ids.allocator.free(new_token);
            }
        }

        if (self.ids.get(new_token)) |id| {
            return id;
        } else {
            var new_id = @intCast(u32, self.tokens.items.len);
            _ = self.ids.putAssumeCapacity(new_token, new_id);
            self.tokens.appendAssumeCapacity(new_token);
            need_free = false;
            return new_id;
        }
    }
};

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
    full_words: std.ArrayList(std.ArrayList(u32)),
    counts: std.ArrayList(i32),
    pair_counts: PairCounts,
    where: Where,
    contiguous_counts: std.ArrayList(PairCount),
    index: WordIndex,

    pub fn init(allocator: *std.mem.Allocator, capacity: u32) !LearnBpeState {
        var state = LearnBpeState{
            .index = try WordIndex.init(allocator, capacity),
            .full_words = std.ArrayList(std.ArrayList(u32)).init(allocator),
            .counts = std.ArrayList(i32).init(allocator),
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
        var full_len = @intCast(u32, len + capacity);
        try self.pair_counts.ensureCapacity(full_len);
        try self.where.ensureCapacity(full_len);
    }

    pub fn mergeCounts(self: *LearnBpeState, merge: WordPair) !void {
        var tokens = &self.index.tokens.items;
        // TODO: find this string somewhere else ?
        var new_token = try strConcat(self.index.tokens.allocator, tokens.*[merge.w1], tokens.*[merge.w2]);
        var new_token_id = try self.index.getOrAdd(new_token, false);

        var where_it = self.where.get(merge).?.iterator();
        var full_words = self.full_words.span();
        while (where_it.next()) |wi| {
            var full_word = &full_words[wi.key];
            var cwi = self.counts.items[wi.key];
            try self.ensureExtraCapacity(full_word.items.len);
            var cur_pair = WordPair{ .w2 = full_word.items[0] };
            var j: usize = 0;
            while (j < full_word.items.len) : (j += 1) {
                const w = full_word.items[j];
                if (j == 0) continue;

                cur_pair.w1 = cur_pair.w2;
                cur_pair.w2 = w;

                if (cur_pair.w1 != merge.w1 or cur_pair.w2 != merge.w2)
                    continue;

                // we've found the pair, get the string


                // change count for word before us.
                if (j > 1) {
                    const w0 = full_word.items[j - 2];
                    try self.incCount(w0, cur_pair.w1, -cwi, wi.key);
                    try self.incCount(w0, new_token_id, cwi, wi.key);
                }

                // Remove [w1, w2] from full_word insert w1@@w2 instead.
                // TODO only mark the token and remove later.
                full_word.items[j - 1] = new_token_id;

                // update count for next token
                if (j + 1 < full_word.items.len) {
                    const w3 = full_word.items[j + 1];
                    try self.incCount(cur_pair.w2, w3, -cwi, wi.key);
                    try self.incCount(new_token_id, w3, cwi, wi.key);
                }
                _ = full_word.orderedRemove(j);

                cur_pair.w2 = new_token_id;
            }
        }
    }

    fn incCount(self: *LearnBpeState, w1: u32, w2: u32, count: i32, wid: u32) !void {
        if (count == 0) return;
        const pair = WordPair{ .w1 = w1, .w2 = w2 };
        if (self.pair_counts.get(pair)) |kv| {
            // assert(kv.value.count + count >= 0);
            // const old_count = kv.count;
            kv.count += count;
            if (count > 0) {
                var words = &self.where.get(pair).?;
                _ = try words.put(wid, {});
            }
            // should we remove from where if kv.value.count falls to 0 ?
        } else {
            // can't decrement from inexisting pair.
            assert(count > 0);
            const pc = PairCount.init(pair, count);
            var pc_ptr: *PairCount = self.contiguous_counts.addOneAssumeCapacity();
            pc_ptr.* = pc;
            _ = self.pair_counts.putAssumeCapacity(pair, pc_ptr);
            var words = std.AutoHashMap(u32, void).init(self.where.allocator);
            _ = try words.put(wid, {});
            _ = self.where.putAssumeCapacity(pair, words);
        }
    }
};

/// Learn BPE from the given files.
pub fn learnbpe(n_pairs: i32, inputFile1: []const u8, inputFile2: []const u8, allocator: *Allocator) !void {
    // get vocab
    var word_count = Vocab.init(allocator);
    try readWords(inputFile1, &word_count);
    if (inputFile2.len > 0) {
        try readWords(inputFile2, &word_count);
    }

    // a token is an int, it represents a string
    const reservation = @intCast(u32, 20 * n_pairs);
    var state = try LearnBpeState.init(allocator, reservation);
    try countSingleChars(&word_count, &state);

    var counts = state.counts.span();
    for (state.full_words.span()) |word, wi| {
        try countPairOfChars(word, @intCast(u32, wi), counts[wi], &state);
    }

    try printSortedBytePairs(&state, n_pairs, std.io.getStdOut());
}

fn printSortedBytePairs(state: *LearnBpeState, n_pairs: i32, file: std.fs.File) !void {
    const print = file.writer().print;
    var idx = state.index;
    var i: usize = 0;
    while (i < n_pairs) : (i += 1) {
        var max_p = findMaxP(&state.contiguous_counts) orelse break;
        var tokens = &idx.tokens.items;
        _ = try print("{} {} {}\n", .{ tokens.*[max_p.w1], tokens.*[max_p.w2], max_p.count });

        try state.mergeCounts(.{ .w1 = max_p.w1, .w2 = max_p.w2 });
        max_p.count = -1;
    }
}

fn countSingleChars(word_count: *Vocab, state: *LearnBpeState) !void {
    var it = word_count.iterator();
    try state.full_words.ensureCapacity(word_count.count());
    var counts = &state.counts;
    var idx = &state.index;
    try counts.ensureCapacity(word_count.count());
    while (it.next()) |wc| {
        var realLength: i32 = 0;
        var word: []const u8 = wc.key;
        var current_word = std.ArrayList(u32).init(state.full_words.allocator);
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
        state.*.full_words.appendAssumeCapacity(current_word);
    }
}

fn countPairOfChars(word: std.ArrayList(u32), wi: u32, count: i32, state: *LearnBpeState) !void {
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
            pair_count.count += count;
            var w = where.get(cur_pair);
            assert(count > 0);
            if (count > 0) {
                _ = try w.?.put(wi, {});
            } else {
                _ = w.?.remove(wi);
            }
        } else {
            const pair_count = PairCount.init(cur_pair, count);
            var pc_ptr: *PairCount = contiguous_counts.addOneAssumeCapacity();
            pc_ptr.* = pair_count;

            _ = try pair_counts.put(cur_pair, pc_ptr);
            var set = std.AutoHashMap(u32, void).init(where.allocator);
            if (count > 0) _ = try set.put(wi, {});
            _ = try where.put(cur_pair, set);
        }
    }
}

fn findMaxP(contiguous_counts: *std.ArrayList(PairCount)) ?*PairCount {
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

pub fn strConcat(allocator: *Allocator, a: []const u8, b: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, a.len + b.len);
    std.mem.copy(u8, result, a);
    std.mem.copy(u8, result[a.len..], b);
    return result;
}

pub fn resolve(file_path: []const u8) std.fs.File {
    // var realpath_buff: [1024]u8 = undefined;
    // const realpath = try std.fs.realpath(fp, &realpath_buff);
    if (std.mem.eql(u8, file_path, "-")) {
        return std.io.getStdIn();
    }

    return std.fs.openFileAbsolute(file_path, .{ .read = true }) catch |e| {
        warn("Error '{}' when opening {}\n", .{ e, file_path });
        std.process.exit(1);
    };
}
