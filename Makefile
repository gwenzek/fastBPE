SHELL=zsh
# Only enable this when developping and compilation time is the bottleneck
# RELEASE=""
RELEASE="-Drelease-fast=true"

.DELETE_ON_ERROR:

test: small_vocab_diff small_bpe_diff small_apply_diff
	ls fastBPE/*.zig | xargs -n1 zig test

build: ./zig-cache/bin/fastBPE bin_cpp/fastBPE

./zig-cache/bin/fastBPE: fastBPE/*.zig
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
	# Reuse codes learnt from C++ to limit diffs to the 'p' implementation
	time ./zig-cache/bin/fastBPE applybpe - `realpath $(word 2,$^)` < $< > $@

output/%.zig_ctypes.apply.txt: data/% output/%.cpp.bpe.txt libfastBPE_apply.0.1.0.dylib
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
	# BPE aren't the same because it depends on the hashmap iteration order in the two languages.
	diff -W80 $< output/sample.txt.zig.bpe.txt
	diff -W80 $< output/sample.txt.zig_stdin.bpe.txt

small_apply_diff: output/sample.txt.cpp.apply.txt output/sample.txt.zig.apply.txt
	diff -W80 $< output/sample.txt.zig.apply.txt

big_vocab_diff: output/fr.train.cpp.vocab.txt output/fr.train.zig.vocab.txt output/fr.train.zig_stdin.vocab.txt
	diff -W80 output/fr.train.zig_stdin.vocab.txt output/fr.train.zig_stdin.vocab.txt | head
	diff -W80 $< output/fr.train.zig.vocab.txt | head

big_bpe_diff: output/fr.train.cpp.bpe.txt output/fr.train.zig.bpe.txt output/fr.train.zig_stdin.bpe.txt
	# BPE aren't the same because it depends on the hashmap iteration order in the two languages.
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

libfastBPE_apply.0.1.0.dylib: build
	zig build $(RELEASE)

clean:
	rm bin_cpp/fastBPE libfastBPE_apply.*
	rm -r ./zig-cache
	rm output/*.apply.txt

profile_python_wrapper: output/fr.train.cpp.bpe.txt
	which python; python --version
	py-spy record -r500 --native python --output output/flame/zig_ctypes.svg test/test_zig.py data/fr.train $< > /dev/null
	py-spy record -r500 --native python --output output/flame/cpp_cython.svg test/test_cpp.py data/fr.train $< > /dev/null
