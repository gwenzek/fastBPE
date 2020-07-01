import ctypes
import sys

from pathlib import Path
import time

root = Path(__file__).parent.parent
if sys.platform == "darwin":
    zig = ctypes.CDLL(str(root / "libfastBPE_apply.dylib"))
else:
    zig = ctypes.CDLL(str(root / "libfastBPE_apply.so"))


def encode(s):
    return ctypes.create_string_buffer((str(s) + "\0").encode("utf8"))


zig.ctypes_bpe.argtypes = [ctypes.c_char_p]
zig.ctypes_bpe.restype = ctypes.c_void_p

zig.ctypes_apply_sentence.argtypes = [
    ctypes.c_void_p,
    ctypes.POINTER(ctypes.c_char),
    ctypes.c_size_t,
    ctypes.POINTER(ctypes.c_char),
]
zig.ctypes_apply_sentence.argtypes


_buff = ctypes.create_string_buffer(b"_" * 4096)


def bpe_sent(bpe, sentence: bytes) -> bytes:
    i = zig.ctypes_apply_sentence(bpe, sentence, len(sentence), _buff)
    return bytes(_buff.value[:i])


def test_zig_bpe():
    root = Path(__file__).parent.parent
    sample = (root / "output/sample.txt.cpp.bpe.txt").resolve()
    bpe = zig.ctypes_bpe(encode(sample))

    assert bpe_sent(bpe, b"helllo worlld") == b"h@@ e@@ ll@@ l@@ o wo@@ r@@ ll@@ d"
    assert bpe_sent(bpe, b"llohe world") == b"llohe world"
    assert bpe_sent(bpe, b"lle") == b"ll@@ e"


def apply(file: str, codes: str):
    start = time.time()
    f = sys.stdin.buffer if file == "-" else open(file, mode="rb")
    bpe = zig.ctypes_bpe(encode(Path(codes).resolve()))
    write = sys.stdout.buffer.write
    for i, line in enumerate(f):
        # TODO: I think ctypes is still copying the line to be sure that
        # external code doesn't modify the immutable bytes object.
        s = bpe_sent(bpe, line[:-1])
        write(s)
        write(b"\n")

    delay = time.time() - start
    print(f"Computed BPE on {i} sentences in {delay:.2f}s, using ctypes wrapper around zig implementation", file=sys.stderr)


if __name__ == "__main__":
    file, codes = sys.argv[1:]
    apply(file, codes)
