from pathlib import Path

import ctypes

zig = ctypes.CDLL("./libapplyBPE.0.0.0.dylib")


def e(s):
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


def main():
  root = Path(__file__).parent.parent
  sample = (root / "output/sample.txt.cpp.bpe.txt").resolve()
  bpe = zig.py_bpe(e(sample))

  buff = e("_" * 1000)
  s = e("helllo worlld")
  print(s.value)
  i = zig.py_apply_sentence(bpe, s, len(s.value), buff)
  print(buff.value[:i])


if __name__ == '__main__':
  main()
