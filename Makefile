SHELL=zsh
# Only enable this when developping and compilation time is the bottleneck
# RELEASE=
RELEASE="-Drelease-fast=true"

VALGRIND_OUT="test/valgrind/valgrind_out.txt"

OS := $(shell uname)
ifeq "$(OS)" "Darwin"
	DLL_EXT=dylib
else
	DLL_EXT=so
endif

.DELETE_ON_ERROR:

test: small_vocab_diff small_bpe_diff small_apply_diff
	ls fastBPE/*.zig | xargs -n1 zig test

build: ./zig-cache/bin/fastBPE libfastBPE_apply.$(DLL_EXT) bin_cpp/fastBPE

./zig-cache/bin/fastB%E libfastBPE_apply%$(DLL_EXT): build.zig fastBPE/*.zig
	mkdir -p output
	zig build $(RELEASE)

bin_cpp/fastBPE: fastBPE/fastBPE.hpp fastBPE/main.cc
	mkdir -p bin_cpp
	g++ -std=c++11 -pthread -O3 fastBPE/main.cc -IfastBPE -o $@

output/%.zig.vocab.txt: data/% ./zig-cache/bin/fastBPE
	time ./zig-cache/bin/fastBPE getvocab `realpath $<` > $@

output/%.zig_stdin.vocab.txt: data/% ./zig-cache/bin/fastBPE
	time cat $< | ./zig-cache/bin/fastBPE getvocab - > $@

output/%.cpp.vocab.txt: data/% bin_cpp/fastBPE
	time bin_cpp/fastBPE getvocab `realpath $<` > $@

output/%.zig.bpe.txt: data/% ./zig-cache/bin/fastBPE
	time ./zig-cache/bin/fastBPE learnbpe 40000 `realpath $<` > $@

output/%.zig_stdin.bpe.txt: data/% ./zig-cache/bin/fastBPE
	time cat $< | ./zig-cache/bin/fastBPE learnbpe 40000 - > $@

output/%.cpp.bpe.txt: data/% bin_cpp/fastBPE
	time bin_cpp/fastBPE learnbpe 40000 `realpath $<` > $@

output/%.zig.apply.txt: data/% output/%.cpp.bpe.txt ./zig-cache/bin/fastBPE
	# Reuse codes learnt from C++ to limit diffs to the 'learn' implementation
	time ./zig-cache/bin/fastBPE applybpe - `realpath $(word 2,$^)` < $< > $@

output/%.zig_ctypes.apply.txt: data/% output/%.cpp.bpe.txt libfastBPE_apply.$(DLL_EXT)
	time python test/test_zig.py $< $(word 2,$^) > $@

output/%.cpp.apply.txt: data/% output/%.cpp.bpe.txt bin_cpp/fastBPE
	time bin_cpp/fastBPE applybpe $@ $< $(word 2,$^)
	time bin_cpp/fastBPE applybpe_stream $(word 2,$^) < $< > $@

output/%.cpp_cython.apply.txt: data/% output/%.cpp.bpe.txt bin_cpp/fastBPE
	time python test/test_cpp.py $< $(word 2,$^) > $@

small_vocab_diff: output/readme.cpp.vocab.txt output/readme.zig.vocab.txt output/readme.zig_stdin.vocab.txt
	diff -W80 $< output/readme.zig.vocab.txt
	diff -W80 $< output/readme.zig_stdin.vocab.txt

small_bpe_diff: output/sample.txt.cpp.bpe.txt output/sample.txt.zig.bpe.txt output/sample.txt.zig_stdin.bpe.txt
	diff -W80 $< <(head -10 output/sample.txt.zig.bpe.txt)
	diff -W80 $< <(head -10 output/sample.txt.zig_stdin.bpe.txt)

small_apply_diff: output/sample.txt.cpp.apply.txt output/sample.txt.zig.apply.txt
	diff -W80 $< output/sample.txt.zig.apply.txt

big_vocab_diff: output/fr.train.cpp.vocab.txt output/fr.train.zig.vocab.txt output/fr.train.zig_stdin.vocab.txt
	diff -W80 output/fr.train.zig_stdin.vocab.txt output/fr.train.zig_stdin.vocab.txt | head
	diff -W80 $< output/fr.train.zig.vocab.txt | head

big_bpe_diff: output/fr.train.cpp.bpe.txt output/fr.train.zig.bpe.txt output/fr.train.zig_stdin.bpe.txt
	# Figure out why we don't have the exact same pair count
	diff -W80 output/fr.train.zig_stdin.bpe.txt output/fr.train.zig_stdin.bpe.txt | head
	diff -W80 $< output/fr.train.zig.bpe.txt | head

big_apply_diff: output/fr.train.cpp_cython.apply.txt output/fr.train.cpp.apply.txt output/fr.train.zig.apply.txt output/fr.train.zig_ctypes.apply.txt
	diff -W80 $< output/fr.train.cpp_cython.apply.txt | head
	diff -W80 $< output/fr.train.zig.apply.txt | head
	diff -W80 $< output/fr.train.zig_ctypes.apply.txt | head

build_server:
	fswatch -o fastBPE/*.zig | xargs -n1 -I{} zsh -c "clear; (zig build && echo BUILD_SUCCEED) || echo BUILD_FAILED"

test_server:
	fswatch -o fastBPE/*.zig | xargs -n1 -I{} zsh -c "clear; (make test && echo TEST_SUCCEED) || echo TEST_FAILED"

perf_apply:
	rm output/fr.train.*.apply.txt; which python; python --version
	make big_apply_diff

test_zig_python: output/sample.txt.cpp.bpe.txt libfastBPE_apply.0.1.0.dylib
	pytest test/test_zig.py

clean:
	[[ ! -f bin_cpp/fastBPE ]] || rm bin_cpp/fastBPE
	[[ ! -f ./zig-cache ]] || rm ./zig-cache
	[[ ! -f test/valgrind ]] || rm test/valgrind
	[[ ! -f libfastBPE_apply.$(DLL_EXT) ]] || rm libfastBPE_apply.$(DLL_EXT)
	rm output/*.apply.txt || true

profile_python_wrapper: output/fr.train.cpp.bpe.txt
	which python; python --version
	mkdir -p output/flame
	py-spy record -r500 --native --output output/flame/zig_ctypes.svg python test/test_zig.py data/fr.train $< > /dev/null
	py-spy record -r500 --native --output output/flame/cpp_cython.svg python test/test_cpp.py data/fr.train $< > /dev/null

test/valgrind/%.txt: fastBPE/%.zig
	mkdir -p $(@D)
	zig test $< 2>&1 | perl -ln -e 's:.*/zig-cache/o/(.*)/test:zig-cache/o/$$1/valgrind.txt:g && print' | xargs -n1 make VALGRIND_OUT=$@

zig-cache/o/%/valgrind.txt: zig-cache/o/%/test
	# We are only interested by the first issue found by valgrind.
	f(){sleep 10; pkill -9 valgrind}; f&
	valgrind -s $< 2>&1 | head -1000 > ${VALGRIND_OUT}
	ln -s `realpath ${VALGRIND_OUT}` $@
	echo "Valgrind generated ${VALGRIND_OUT}"

test_valgrind:
	ls fastBPE/*.zig | perl -ln -e 's:fastBPE/(.*)\.zig:test/valgrind/$$1.txt:g && print' | xargs make

valgrind: test/valgrind/sample_learn.txt

test/valgrind/sample_learn.txt: ./zig-cache/bin/fastBPE
	f(){sleep 10; pkill -9 valgrind}; f&
	valgrind ./zig-cache/bin/fastBPE learnbpe 40000 `realpath data/sample.txt` 2>&1 | head -1000 > $@

tracy: output/bpe.zig.trace
	tracy $<

output/bpe.zig.trace: fastBPE/*.zig
	zig build -Denable_tracy=true $(RELEASE)
	tracy_capture -f -o $@ ./zig-cache/bin/fastBPE learnbpe 40000 `realpath data/fr.train` > /dev/null
