import sys
import fastBPE
import time


def apply(file: str, codes: str) -> None:
    start = time.time()
    f = sys.stdin if file == "-" else open(file, mode="r")
    bpe = fastBPE.fastBPE(codes, "")
    for i, line in enumerate(f):
        s = bpe.apply([line[:-1]])[0]
        print(s)

    delay = time.time() - start
    print(f"Computed BPE on {i} sentences in {delay:.2f}s, using cython wrapper around cpp implementation", file=sys.stderr)


if __name__ == "__main__":
    file, codes = sys.argv[1:]
    apply(file, codes)
