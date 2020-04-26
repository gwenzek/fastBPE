const std = @import("std");
const learn = @import("learnBPE.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const warn = std.debug.warn;
const debug = std.debug.warn;

pub fn applybpe(inputPath: []const u8, codesPath: []const u8, vocabPath: []const u8, allocator: *Allocator) !void {
    var applyer = try BPEApplyer.init(codesPath, vocabPath, allocator);
    const buff: comptime usize = 8192;
    var line_buff: [buff]u8 = undefined;
    var result_buff = try std.ArrayList(u8).initCapacity(allocator, 2 * buff);

    const file = if (eqlString(inputPath, "-"))
        std.io.getStdIn()
    else
        std.fs.openFileAbsolute(inputPath, learn.kReadOnly) catch |e| {
            warn("Error '{}' when opening {}\n", .{ e, inputPath });
            std.process.exit(1);
        };

    const file_stream = std.io.bufferedInStream(file.inStream()).inStream();
    const print = std.io.getStdOut().outStream().print;

    while (file_stream.readUntilDelimiterOrEof(&line_buff, '\n') catch |err| switch (err) {
        error.StreamTooLong => blk: {
            // Line is longer than buf size, skip it.
            // TODO: treat the buffer as a sentence
            try file_stream.skipUntilDelimiterOrEof('\n');
            break :blk &line_buff;
        },
        else => {
            warn("I/O error while reading {}", .{inputPath});
            return err;
        },
    }) |line| {
        applyer.apply_sentence(line, &result_buff);
        try print("{}\n", .{result_buff.span()});
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

threadlocal var _subwords = [_]std.ArrayList([]const u8){
    undefined,
    undefined,
};

const Codes = std.HashMap(WordPair, u32, WordPair.hash, WordPair.eql);
const BPEApplyer = struct {
    // vocab: learn.Vocab,
    codes: Codes,
    // reversed_codes: std.StringHashMap(WordPair),
    buffer: [512]u8,

    fn init(codesPath: []const u8, vocabPath: []const u8, allocator: *Allocator) !BPEApplyer {
        var applier = BPEApplyer{
            // .vocab = learn.Vocab.init(allocator),
            .codes = Codes.init(allocator),
            // .reversed_codes = std.StringHashMap(WordPair).init(allocator),
            .buffer = undefined,
        };
        var buff = &applier.buffer;
        std.mem.copy(u8, buff[buff.len - learn.kEndWord.len ..], learn.kEndWord);
        for (_subwords) |*buffer| {
            buffer.* = try std.ArrayList([]const u8).initCapacity(allocator, 512);
        }
        // TODO load vocab
        try applier.readCodes(codesPath);
        return applier;
    }

    fn readCodes(self: *BPEApplyer, fp: []const u8) !void {
        var realpath_buff: [1024]u8 = undefined;
        const realpath = try std.fs.realpath(fp, &realpath_buff);
        const file = try std.fs.openFileAbsolute(fp, learn.kReadOnly);
        var codes = &self.codes;
        var allocator = self.codes.allocator;

        warn("Loading codes from {} ...\n", .{fp});
        var file_stream = std.io.bufferedInStream(file.inStream()).inStream();
        var line_buf: [4096]u8 = undefined;
        while (file_stream.readUntilDelimiterOrEof(&line_buf, '\n') catch |err| switch (err) {
            error.StreamTooLong => blk: {
                // Line is longer than buf size, skip it.
                try file_stream.skipUntilDelimiterOrEof('\n');
                break :blk &line_buf;
            },
            else => |e| return e,
        }) |line| {
            var it = std.mem.split(line, " ");
            // reset subwords
            const pair = WordPair{ .left = try str_copy(allocator, it.next().?), .right = try str_copy(allocator, it.next().?) };
            const count = try std.fmt.parseInt(i32, it.next().?, 10);
            assert(it.next() == null);
            assert(!self.codes.contains(pair));
            // TODO copy words
            _ = try codes.put(pair, @intCast(u32, codes.count()));
            // string concat = splits[0] + splits[1];
            // assert(reversed_codes.find(concat) == reversed_codes.end());
            // reversed_codes[concat] = pair;
        }
        warn("Read {} codes from the codes file.\n", .{codes.count()});
    }

    fn apply_sentence(self: *BPEApplyer, sentence: []const u8, out: *std.ArrayList(u8)) void {
        // debug("Sentence: {}\n", .{sentence});
        if (sentence.len == 0)
            return;

        var it = std.mem.split(sentence, " ");
        var start = true;
        if (it.next()) |word| {
            self.apply_word(word, out);
        }
        while (it.next()) |word| {
            out.appendAssumeCapacity(' ');
            self.apply_word(word, out);
        }
    }

    /// Compute BPE for given words. Result is copied to "out".
    fn apply_word(self: *BPEApplyer, word: []const u8, out: *std.ArrayList(u8)) void {
        for (_subwords) |*sw| sw.*.items.len = 0;
        var subwords = &_subwords[0];
        var new_subwords = &_subwords[1];

        var word_with_endword = self.buffer[self.buffer.len - learn.kEndWord.len - word.len ..];
        std.mem.copy(u8, word_with_endword, word);

        // split the word into UTF8 chars
        var last_start: usize = 0;
        // TODO: try std.unicode.Utf8Iterator
        for (word_with_endword) |char, pos| {
            if (pos == 0)
                continue;
            if (pos >= word_with_endword.len - learn.kEndWord.len) {
                break;
            }
            if ((char & 0xc0) == 0x80) // continuation byte
                continue;
            var new_token = word_with_endword[last_start..pos];
            subwords.appendAssumeCapacity(new_token);
            last_start = pos;
        }
        var last_word_len = word_with_endword.len - last_start;
        subwords.appendAssumeCapacity(word_with_endword[last_start..]);
        // debug_subwords("Initial state", subwords.*);
        while (subwords.items.len > 1) {
            // find the best pair
            var best_pair_pos: i32 = -1;
            var best_pair: Codes.KV = undefined;
            for (subwords.items[0 .. subwords.items.len - 1]) |sw, i| {
                if (self.codes.get(WordPair{ .left = sw, .right = subwords.items[i + 1] })) |pair| {
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