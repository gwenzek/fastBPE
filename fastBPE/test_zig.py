from pathlib import Path

import ctypes

zig = ctypes.CDLL("./libapplyBPE.0.0.0.dylib")


def encode(s):
    return ctypes.create_string_buffer((str(s) + "\0").encode("utf8"))


zig.py_bpe.argtypes = [ctypes.c_char_p]
zig.py_bpe.restype = ctypes.c_void_p

zig.py_apply_sentence.argtypes = [
    ctypes.c_void_p,
    ctypes.c_char_p,
    ctypes.c_size_t,
    ctypes.c_char_p,
]
zig.py_apply_sentence.argtypes


_buff = ctypes.create_string_buffer(b"_" * 1024)


def bpe_sent(bpe, sentence: bytes):
    i = zig.py_apply_sentence(bpe, sentence, len(sentence), _buff)
    return bytes(_buff.value[:i])


def test_zig_bpe():
    root = Path(__file__).parent.parent
    sample = (root / "output/sample.txt.cpp.bpe.txt").resolve()
    bpe = zig.py_bpe(encode(sample))

    assert bpe_sent(bpe, b"helllo worlld") == b"h@@ e@@ ll@@ l@@ o wo@@ r@@ ll@@ d"
    assert bpe_sent(bpe, b"llohe world") == b"llohe world"
    assert bpe_sent(bpe, b"lle") == b"ll@@ e"


if __name__ == "__main__":
    test_zig_bpe()
