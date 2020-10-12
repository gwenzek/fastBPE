const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Writer = std.fs.File.Writer;
const assert = std.debug.assert;

const clib = @cImport({
    @cInclude("sys/mman.h");
});

const log = std.log.scoped(.fastBPE);
const str = []const u8;

fn debug(comptime fmt: str, any: anytype) void {
    std.debug.print("[DEBUG]");
    std.debug.print(fmt, any);
    std.debug.print("\n");
}

const kMaxPairs: i32 = 1000 * 1000 * 1000;
const kThreads: i32 = max(1, min(10, int(clib.thread.hardware_concurrency())));
pub const kEndWord = comptime "</w>";
pub const kTokenDelim = comptime "@@";

fn strCmp(word1: str, word2: str) bool {
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

pub fn readWords(fp: str, word_count: *Vocab) !void {
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

        log.info("Loading vocabulary from {} ...\n", .{fp});

        const stat = try file.stat();
        const buffer: []u8 = try std.os.mmap(null, stat.size, clib.PROT_READ, clib.MAP_PRIVATE, file.handle, 0);

        n_words = try readWordsFromBuff(word_count, buffer);
    }
    log.info("Read {} words ({} unique) from text file.\n", .{ n_words, word_count.count() });
}

pub const Vocab = std.StringHashMap(i32);
const VocabEntry = Vocab.Entry;
const VocabHeader = packed struct {
    entries: [*]VocabEntry,
    capacity: Vocab.Size,
};

/// Orders word by number of occurences, and alphabetical order in case of ties.
fn hasMoreOccurences(context: void, kv1: Vocab.Entry, kv2: Vocab.Entry) bool {
    if (kv1.value == kv2.value)
        return strCmp(kv1.key, kv2.key);
    return kv1.value > kv2.value;
}

/// Counts words in given **tokenized** files.
/// Output is sorted by decreasing order.
pub fn getVocab(inputFile1: str, inputFile2: str, allocator: *Allocator) !void {
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
    log.info("Word count: {}\n", .{entries.len});
    std.sort.sort(VocabEntry, entries, {}, hasMoreOccurences);

    const stdout_file = std.io.getStdOut();
    // print sorted vocab
    for (entries) |entry| {
        try stdout_file.outStream().print("{} {}\n", .{ entry.key, entry.value });
    }
}

pub const WordIndex = struct {
    ids: std.StringHashMap(u32) = undefined,
    tokens: std.ArrayList(str) = undefined,

    pub fn init(allocator: *Allocator) !WordIndex {
        var idx = WordIndex{
            .ids = std.StringHashMap(u32).init(allocator),
            .tokens = std.ArrayList(str).init(allocator),
        };
        return idx;
    }

    pub fn deinit(self: *WordIndex) void {
        self.ids.deinit();
        self.tokens.deinit();
    }

    pub fn ensureCapacity(self: *WordIndex, capacity: u32) !void {
        try self.ids.ensureCapacity(capacity);
        try self.tokens.ensureCapacity(capacity);
    }

    pub fn getOrPut(self: *WordIndex, word: str, end_of_word: bool) !u32 {
        var new_token = word;
        var need_free = false;
        if (end_of_word) {
            new_token = try strConcat(self.ids.allocator, word, kEndWord);
            need_free = true;
        }

        var new_id = @intCast(u32, self.tokens.items.len);
        try self.ensureCapacity(new_id + 1);
        var res = try self.ids.getOrPut(new_token);
        if (res.found_existing) {
            var id = res.entry.value;
            // debug("get token: {} -> {}\n", .{new_token, id});
            if (need_free) {
                self.ids.allocator.free(new_token);
            }
            return id;
        } else {
            // debug("add new token: {} -> {}\n", .{new_id, new_token});
            res.entry.*.value = new_id;
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
const PairLoc = std.AutoHashMap(WordPair, std.AutoHashMap(u32, void));

const LearnBpeState = struct {
    full_words: std.ArrayList(std.ArrayList(u32)),
    word_counts: std.ArrayList(i32),
    pairs: PairCounts,
    pair_loc: PairLoc,
    contiguous_counts: std.ArrayList(PairCount),
    index: WordIndex,

    pub fn init(allocator: *std.mem.Allocator) LearnBpeState {
        var state = LearnBpeState{
            .full_words = std.ArrayList(std.ArrayList(u32)).init(allocator),
            .word_counts = std.ArrayList(i32).init(allocator),
            .pairs = PairCounts.init(allocator),
            .pair_loc = PairLoc.init(allocator),
            .contiguous_counts = std.ArrayList(PairCount).init(allocator),
            .index = try WordIndex.init(allocator),
        };
        return state;
    }

    pub fn deinit(self: *LearnBpeState) void {
        self.full_words.deinit();
        self.word_counts.deinit();
        self.pairs.deinit();
        self.pair_loc.deinit();
        self.contiguous_counts.deinit();
        self.index.deinit();
    }

    pub fn ensureExtraCapacity(self: *LearnBpeState, capacity: usize) !void {
        var len = self.contiguous_counts.items.len;
        try self.contiguous_counts.ensureCapacity(len + capacity);
        var full_len = @intCast(u32, len + capacity);
        try self.contiguous_counts.ensureCapacity(full_len);
        try self.pair_loc.ensureCapacity(full_len);
        // TODO: do we need to increase the index size here ?
        try self.index.ensureCapacity(full_len);
    }

    /// Replaces a pair by a fixed entry, and update all counters.
    pub fn mergeCounts(self: *LearnBpeState, merge: WordPair) !void {
        var tokens = &self.index.tokens.items;
        // TODO: find this string somewhere else ?
        var new_token = try strConcat(self.index.tokens.allocator, tokens.*[merge.w1], tokens.*[merge.w2]);
        var new_token_id = try self.index.getOrPut(new_token, false);

        var full_words = self.full_words.span();
        var where_it = self.pair_loc.get(merge).?.iterator();
        while (where_it.next()) |wi| {
            var full_word = &full_words[wi.key];
            var cwi = self.word_counts.items[wi.key];
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

    fn getCount(self: *const LearnBpeState, w1: str, w2: str) i32 {
        var w1_id: u32 = self.index.ids.get(w1).?;
        if (w2.len == 0) {
            return self.word_counts.items[w1_id];
        } else {
            var w2_id = self.index.ids.get(w2).?;
            return self.pairs.get(.{ .w1 = w1_id, .w2 = w2_id }).?.count;
        }
    }

    /// Increments the count for the pair (w1, w2), found in word 'wid'.
    fn incCount(self: *LearnBpeState, w1: u32, w2: u32, count: i32, wid: u32) !void {
        if (count == 0) return;
        const pair = WordPair{ .w1 = w1, .w2 = w2 };
        if (self.pairs.get(pair)) |kv| {
            // assert(kv.value.count + count >= 0);
            // const old_count = kv.count;
            kv.count += count;
            if (count > 0) {
                var words = &self.pair_loc.get(pair).?;
                _ = try words.put(wid, {});
            }
            // should we remove from where if kv.value.count falls to 0 ?
        } else {
            // can't decrement from inexisting pair.
            assert(count > 0);
            const pc = PairCount.init(pair, count);
            var pc_ptr: *PairCount = self.contiguous_counts.addOneAssumeCapacity();
            pc_ptr.* = pc;
            _ = self.pairs.putAssumeCapacity(pair, pc_ptr);
            var words = std.AutoHashMap(u32, void).init(self.pair_loc.allocator);
            _ = try words.put(wid, {});
            _ = self.pair_loc.putAssumeCapacity(pair, words);
        }
    }
};

/// Learns BPE from the given files.
pub fn learnbpe(n_pairs: i32, inputFile1: str, inputFile2: str, allocator: *Allocator) !void {
    // get vocab
    var word_count = Vocab.init(allocator);
    try readWords(inputFile1, &word_count);
    if (inputFile2.len > 0) {
        try readWords(inputFile2, &word_count);
    }

    // a token is an int, it represents a string
    const reservation = @intCast(u32, 20 * n_pairs);
    var state = LearnBpeState.init(allocator);
    try state.ensureExtraCapacity(reservation);
    try initSingleChars(&word_count, &state);

    var word_counts = state.word_counts.span();
    for (state.full_words.span()) |word, wi| {
        try countPairOfChars(word, @intCast(u32, wi), word_counts[wi], &state);
    }

    try printSortedBytePairs(&state, n_pairs, std.io.getStdOut());
}

fn printSortedBytePairs(state: *LearnBpeState, n_pairs: i32, file: std.fs.File) !void {
    const print = file.writer().print;
    var idx = state.index;
    var i: usize = 0;
    while (i < n_pairs) : (i += 1) {
        var max_p = findMaxPair(&state.contiguous_counts) orelse break;
        var tokens = &idx.tokens.items;
        _ = try print("{} {} {}\n", .{ tokens.*[max_p.w1], tokens.*[max_p.w2], max_p.count });

        try state.mergeCounts(.{ .w1 = max_p.w1, .w2 = max_p.w2 });
        max_p.count = -1;
    }
}

fn initSingleChars(word_count: *Vocab, state: *LearnBpeState) !void {
    try state.full_words.ensureCapacity(word_count.count());
    var idx = &state.index;
    var word_counts = &state.word_counts;
    try word_counts.ensureCapacity(word_count.count());
    var wc_it = word_count.iterator();
    while (wc_it.next()) |wc| {
        var realLength: i32 = 0;
        var word: str = wc.key;
        var current_word = std.ArrayList(u32).init(state.full_words.allocator);
        try current_word.ensureCapacity(word.len);
        word_counts.appendAssumeCapacity(wc.value);

        var lastStart: usize = 0;
        // TODO: try std.unicode.Utf8Iterator
        for (word) |char, pos| {
            if (pos == 0)
                continue;
            if ((char & 0xc0) == 0x80) // continuation byte
                continue;
            realLength += 1;
            var id = try idx.getOrPut(word[lastStart..pos], false);
            current_word.appendAssumeCapacity(id);
            lastStart = pos;
        }
        var id = try idx.getOrPut(word[lastStart..], true);
        current_word.appendAssumeCapacity(id);
        state.*.full_words.appendAssumeCapacity(current_word);
    }
}

test "init single chars" {
    var allocator = std.testing.allocator;
    var vocab = Vocab.init(allocator);
    try vocab.put("hello", 1);
    try vocab.put("world", 2);
    var state = LearnBpeState.init(allocator);
    defer state.deinit();
    try state.ensureExtraCapacity(16);
    try initSingleChars(&vocab, &state);
    // 8 because there are 7 unique chars, but "o" appears both at the end
    // and in the middle of a word.
    assert(state.index.ids.count() == 8);

    assert(state.index.ids.contains("h"));
    assert(state.index.ids.contains("e"));
    assert(state.index.ids.contains("l"));
    assert(state.index.ids.contains("o</w>"));

    assert(state.index.ids.contains("w"));
    assert(state.index.ids.contains("o"));
    assert(state.index.ids.contains("r"));
    assert(state.index.ids.contains("d</w>"));
}

fn countPairOfChars(word: std.ArrayList(u32), wi: u32, count: i32, state: *LearnBpeState) !void {
    var first_round = true;
    var cur_pair = WordPair{};
    // Use pointers to actually modify the state.
    var pairs = &state.pairs;
    var pair_loc = &state.pair_loc;
    var contiguous_counts = &state.contiguous_counts;
    try contiguous_counts.ensureCapacity(contiguous_counts.items.len + word.items.len);

    for (word.span()) |token, i| {
        cur_pair.w1 = cur_pair.w2;
        cur_pair.w2 = token;
        if (i == 0) // cur_pair.w1 isn't correctly initialized
            continue;

        if (pairs.get(cur_pair)) |pair| {
            pair.count += count;
            var w = pair_loc.get(cur_pair);
            assert(count > 0);
            if (count > 0) {
                _ = try w.?.put(wi, {});
            } else {
                _ = w.?.remove(wi);
            }
        } else {
            const pair = PairCount.init(cur_pair, count);
            var pc_ptr: *PairCount = contiguous_counts.addOneAssumeCapacity();
            pc_ptr.* = pair;

            _ = try pairs.put(cur_pair, pc_ptr);
            var set = std.AutoHashMap(u32, void).init(pair_loc.allocator);
            if (count > 0) _ = try set.put(wi, {});
            _ = try pair_loc.put(cur_pair, set);
        }
    }
}

fn findMaxPair(pairs: *std.ArrayList(PairCount)) ?*PairCount {
    var counts = pairs.items;
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

pub fn strConcat(allocator: *Allocator, a: str, b: str) ![]u8 {
    const result = try allocator.alloc(u8, a.len + b.len);
    std.mem.copy(u8, result, a);
    std.mem.copy(u8, result[a.len..], b);
    return result;
}

pub fn resolve(file_path: str) std.fs.File {
    // var realpath_buff: [1024]u8 = undefined;
    // const realpath = try std.fs.realpath(fp, &realpath_buff);
    if (std.mem.eql(u8, file_path, "-")) {
        return std.io.getStdIn();
    }

    return std.fs.openFileAbsolute(file_path, .{ .read = true }) catch |e| {
        log.err("Error '{}' when opening {}\n", .{ e, file_path });
        std.process.exit(1);
    };
}
