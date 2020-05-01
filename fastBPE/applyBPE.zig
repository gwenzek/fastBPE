const std = @import("std");
const learn = @import("learnBPE.zig");
const Allocator = std.mem.Allocator;
const File = std.fs.File;
const assert = std.debug.assert;
const warn = std.debug.warn;
const debug = std.debug.warn;
const OutOfMemory = std.mem.Allocator.Error;

pub fn applybpe(input: File, codes: File, vocab_path: []const u8, allocator: *Allocator) !void {
    var applyer = try BPEApplyer.fromFile(codes, vocab_path, allocator);
    const buff: comptime usize = 8192;
    var line_buff: [buff]u8 = undefined;
    var result_buff = try std.ArrayList(u8).initCapacity(allocator, 2 * buff);

    const in_stream = std.io.bufferedInStream(input.inStream()).inStream();
    const print = std.io.getStdOut().outStream().print;

    while (in_stream.readUntilDelimiterOrEof(&line_buff, '\n') catch |err| switch (err) {
        error.StreamTooLong => blk: {
            // Line is longer than buf size, skip it.
            // TODO: treat the buffer as a sentence
            try in_stream.skipUntilDelimiterOrEof('\n');
            break :blk &line_buff;
        },
        else => {
            warn("I/O error while reading {}", .{input});
            return err;
        },
    }) |line| {
        try print("{}\n", .{applyer.applySentence(line, &result_buff)});
        // doesn't change underlying memory, but reset the write pointer.
        result_buff.items.len = 0;
    }
}

const eqlString = std.hash_map.eqlString;

const WordPair = struct {
    left: []const u8,
    right: []const u8,

    fn eql(a: WordPair, b: WordPair) bool {
        return eqlString(a.left, b.left) and eqlString(a.right, b.right);
    }
    fn hash(a: WordPair) u32 {
        const hashString = std.hash_map.hashString;
        var h1 = hashString(a.left);
        var h2 = hashString(a.right);
        // boost::hash_combine
        return h2 +% 0x9e3779b9 +% (h1 << 6) +% (h1 >> 2);
    }
};

export fn ctypes_bpe(codes_file: [*:0]const u8) ?*BPEApplyer {
    const allocator = std.heap.c_allocator;
    var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    var realpath = std.os.realpathZ(codes_file, &buf) catch |err| {
        warn("Failed to resolve code file '{}': {}\n", .{ codes_file, err });
        return null;
    };
    const file = std.mem.dupe(allocator, u8, realpath) catch |err| {
        warn("Failed to copy filename '{}': {}\n", .{ realpath, err });
        return null;
    };
    defer allocator.free(file);
    const handle = std.fs.openFileAbsolute(file, .{ .read = true }) catch |e| {
        warn("Error '{}' when opening {}\n", .{ e, file });
        return null;
    };
    const codes = readCodes(handle, allocator) catch |err| {
        warn("Error when reading codes from {}: {}\n", .{ file, err });
        return null;
    };
    var applier = BPEApplyer.init(codes, allocator) catch |err| {
        warn("Not enough memory: {}\n", .{err});
        return null;
    };
    var heap_bpe: *BPEApplyer = allocator.create(BPEApplyer) catch |err| {
        warn("Not enough memory: {}\n", .{err});
        return null;
    };
    heap_bpe.* = applier;
    return heap_bpe;
}

var ctypes_output_buffer = std.ArrayList(u8).init(std.heap.c_allocator);

export fn ctypes_apply_sentence(bpe: *BPEApplyer, sentence: [*]const u8, sentence_len: usize, out: [*]u8) usize {
    ctypes_output_buffer.capacity = 4096;
    ctypes_output_buffer.items.len = 0;
    ctypes_output_buffer.items.ptr = out;
    var res = bpe.applySentence(sentence[0..sentence_len], &ctypes_output_buffer);
    return res.len;
}

const Codes = std.HashMap(WordPair, u32, WordPair.hash, WordPair.eql);
const BPEApplyer = struct {
    /// Class to apply BPE to text.
    /// Pass by pointer: this struct is very wide because it contains buffers for the conversion.
    /// Not thread safe. Several applier can safely share the same codes.
    codes: Codes,
    // TODO: decide if we keep vocab.
    // vocab: learn.Vocab,
    // reversed_codes: std.StringHashMap(WordPair),
    _word_buffer: [512]u8,
    _subwords: [2]std.ArrayList([]const u8),

    fn init(codes: Codes, allocator: *Allocator) OutOfMemory!BPEApplyer {
        var applier = BPEApplyer{
            .codes = codes,
            ._word_buffer = undefined,
            ._subwords = [_]std.ArrayList([]const u8){
                undefined,
            } ** 2,
        };
        var buff = &applier._word_buffer;
        std.mem.copy(u8, buff[buff.len - learn.kEndWord.len ..], learn.kEndWord);
        for (applier._subwords) |*buffer| {
            buffer.* = try std.ArrayList([]const u8).initCapacity(allocator, 512);
        }
        return applier;
    }

    fn fromFile(codes_file: File, vocab_path: []const u8, allocator: *Allocator) !BPEApplyer {
        var codes = try readCodes(codes_file, allocator);
        return try BPEApplyer.init(codes, allocator);
    }

    fn applySentence(self: *BPEApplyer, sentence: []const u8, out: *std.ArrayList(u8)) []const u8 {
        // debug("Sentence: {}\n", .{sentence});
        const start = out.items.len;
        if (sentence.len == 0)
            return out.items[start..];

        var it = std.mem.split(sentence, " ");
        if (it.next()) |word| {
            _ = self.applyWord(word, out);
        }
        while (it.next()) |word| {
            out.appendAssumeCapacity(' ');
            _ = self.applyWord(word, out);
        }
        return out.items[start..];
    }

    inline fn add_endword(self: *BPEApplyer, word: []const u8) []const u8 {
        const off = self._word_buffer.len - learn.kEndWord.len - word.len;
        var word_with_endword = self._word_buffer[off..];
        std.mem.copy(u8, word_with_endword, word);
        return word_with_endword;
    }

    /// Compute BPE for given words. Result is copied to "out".
    fn applyWord(self: *BPEApplyer, _word: []const u8, out: *std.ArrayList(u8)) []const u8 {
        // reset subwords buffer
        for (self._subwords) |*sw| sw.*.items.len = 0;
        var subwords = &self._subwords[0];
        var new_subwords = &self._subwords[1];
        var start = out.items.len;

        const word = self.add_endword(_word);
        // split the word into UTF8 chars
        var last_start: usize = 0;
        // TODO: try std.unicode.Utf8Iterator
        for (word) |char, pos| {
            if (pos == 0)
                continue;
            if (pos >= word.len - learn.kEndWord.len) {
                break;
            }
            if ((char & 0xc0) == 0x80) // continuation byte
                continue;
            var new_token = word[last_start..pos];
            subwords.appendAssumeCapacity(new_token);
            last_start = pos;
        }
        var last_word_len = word.len - last_start;
        subwords.appendAssumeCapacity(word[last_start..]);
        // debug_subwords("Initial state", subwords.*);
        while (subwords.items.len > 1) {
            // find the best pair
            var best_pair_pos: i32 = -1;
            var best_pair: Codes.KV = undefined;
            for (subwords.items[0 .. subwords.items.len - 1]) |sw, i| {
                if (self.codes.get(.{ .left = sw, .right = subwords.items[i + 1] })) |pair| {
                    var pair_rank = pair.value;
                    if (pair_rank >= 0 and (best_pair_pos == -1 or best_pair.value > pair_rank)) {
                        best_pair = pair.*;
                        best_pair_pos = @intCast(i32, i);
                    }
                }
            }
            // if we cannot merge anything, stop
            if (best_pair_pos == -1) {
                break;
            }
            // otherwise, merge subWords
            // do we need to iterate again across subwords ?
            var just_merged = false;
            var n = subwords.items.len;
            for (subwords.items) |left, i| {
                if ((i + 1 < n) and (!just_merged) and
                    eqlString(left, best_pair.key.left) and
                    eqlString(subwords.items[i + 1], best_pair.key.right))
                {
                    var right = subwords.items[i + 1];
                    // check that right is located next to left
                    var concat: []const u8 = left.ptr[0 .. left.len + subwords.items[i + 1].len];
                    // debug("left '{}', right '{}' concat '{}'\n", .{ left, right, concat });
                    // debug("left ({}, {}), right ({}, {})\n", .{ left.ptr, left.len, right.ptr, right.len });
                    assert(eqlString(right, left.ptr[left.len .. left.len + right.len]));
                    new_subwords.appendAssumeCapacity(concat);
                    just_merged = true;
                } else {
                    if (!just_merged) {
                        new_subwords.appendAssumeCapacity(left);
                    }
                    just_merged = false;
                }
            }
            // Swap the two subwords buffer.
            var tmp_subwords = subwords;
            subwords = new_subwords;
            new_subwords = tmp_subwords;
            new_subwords.*.items.len = 0;
            // debug_subwords("iteration", subwords.*);
        }
        // TODO: is this feature used ? can't this be done by editing the codes file ?
        // check that we are only using words in the dictionary
        // if (vocab.size() > 0) {
        //   limitVocab(subwords, new_subwords, reversed_codes, vocab);
        //   subwords = new_subwords;
        //   // TODO: reset new_subwords
        // }

        // concat subWords
        var n = subwords.items.len;
        for (subwords.items) |x, i| {
            if (i == n - 1) {
                // do not output EndWord markers.
                appendSliceAssumeCapacity(out, x[0 .. x.len - learn.kEndWord.len]);
                break;
            }
            appendSliceAssumeCapacity(out, x);
            appendSliceAssumeCapacity(out, learn.kTokenDelim);
            out.appendAssumeCapacity(' ');
        }
        return out.items[start..];
    }

    fn deinit(self: *BPEApplyer) void {
        self.codes.deinit();
        for (self._subwords) |*buffer| {
            buffer.deinit();
        }
    }

    fn addPairOrCrash(self: *BPEApplyer, left: []const u8, right: []const u8) void {
        const pair = WordPair{ .left = left, .right = right };
        assert(!self.codes.contains(pair));
        _ = self.codes.put(pair, @intCast(u32, self.codes.count())) catch unreachable;
    }
};

fn appendSliceAssumeCapacity(self: *std.ArrayList(u8), items: []const u8) void {
    const oldlen = self.items.len;
    const newlen = self.items.len + items.len;
    assert(self.capacity > newlen);
    self.items.len = newlen;
    std.mem.copy(u8, self.items[oldlen..], items);
}

fn str_copy(allocator: *Allocator, a: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, a.len);
    std.mem.copy(u8, result, a);
    return result;
}

fn debug_subwords(label: []const u8, subwords: std.ArrayList([]const u8)) void {
    debug("{}: ", .{label});
    for (subwords.items) |sw| {
        debug("{},", .{sw});
    }
    debug("\n", .{});
}

// warn("Loading codes from {} ...\n", .{fp});

fn readCodes(file: File, allocator: *Allocator) !Codes {
    var stream = std.io.bufferedInStream(file.inStream()).inStream();
    var codes = Codes.init(allocator);
    var line_buf: [4096]u8 = undefined;

    var l: u32 = 1;
    while (stream.readUntilDelimiterOrEof(&line_buf, '\n') catch |err| switch (err) {
        error.StreamTooLong => blk: {
            // This looks like a crazy line
            warn("Skipping line {} which is too long: {}\n", .{ l, line_buf[0..80] });
            try stream.skipUntilDelimiterOrEof('\n');
            break :blk &line_buf;
        },
        else => |e| return e,
    }) |line| {
        var it = std.mem.split(line, " ");
        // reset subwords
        const pair = WordPair{ .left = try str_copy(allocator, it.next().?), .right = try str_copy(allocator, it.next().?) };
        const count = try std.fmt.parseInt(i32, it.next().?, 10);
        assert(it.next() == null);
        assert(!codes.contains(pair));
        _ = try codes.put(pair, @intCast(u32, codes.count()));
        // string concat = splits[0] + splits[1];
        // assert(reversed_codes.find(concat) == reversed_codes.end());
        // reversed_codes[concat] = pair;
        l +%= 1;
    }
    warn("Read {} codes from the codes file.\n", .{codes.count()});
    return codes;
}

fn assertEqlString(message: []const u8, actual: []const u8, expected: []const u8) void {
    const eq = eqlString(actual, expected);
    if (eq) return;
    warn("\n - {}: received '{}', expected: '{}'\n", .{ message, actual, expected });
    if (actual.len != expected.len) {
        warn("    received len {}, expected len {}\n", .{ actual.len, expected.len });
        assert(false);
    }
    for (expected) |char, i| {
        const actual_char = actual[i];
        if (actual_char != char) {
            warn("    char mismatch at index {}: received '{}', expected '{}", .{ i, actual[i .. i + 1], expected[i .. i + 1] });
        }
    }
    assert(eq);
}

test "apply word" {
    var bpe = try BPEApplyer.init(std.testing.allocator);
    defer bpe.deinit();
    var out = try std.ArrayList(u8).initCapacity(std.testing.allocator, 512);
    defer out.deinit();

    assertEqlString(
        "codes=[]",
        bpe.applyWord("hello", &out),
        "h@@ e@@ l@@ l@@ o",
    );
    bpe.addPairOrCrash("h", "e");
    assertEqlString(
        "codes=[he]",
        bpe.applyWord("hello", &out),
        "he@@ l@@ l@@ o",
    );
    bpe.addPairOrCrash("l", "l");
    assertEqlString(
        "codes=[he, ll]",
        bpe.applyWord("hello", &out),
        "he@@ ll@@ o",
    );
    bpe.addPairOrCrash("ll", "o</w>");
    assertEqlString(
        "codes=[he, ll, llo]",
        bpe.applyWord("hello", &out),
        "he@@ llo",
    );
}
