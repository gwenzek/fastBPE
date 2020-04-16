test: small_diff
	zig test fastBPE/fastBPE.zig

build: ./zig-cache/bin/fastBPE ./fast

./zig-cache/bin/fastBPE: fastBPE/fastBPE.zig
	zig build

./fast: fastBPE/fastBPE.hpp fastBPE/main.cc
	g++ -std=c++11 -pthread -O3 fastBPE/main.cc -IfastBPE -o $@

output/%.zig.vocab.txt: data/% ./zig-cache/bin/fastBPE
	mkdir -p output
	./zig-cache/bin/fastBPE getvocab `realpath $<` > $@

output/%.zig_stdin.vocab.txt: data/% ./zig-cache/bin/fastBPE
	mkdir -p output
	cat $< | ./zig-cache/bin/fastBPE getvocab - > $@

output/%.cpp.vocab.txt: data/% ./fast
	mkdir -p output
	./fast getvocab `realpath $<` > $@

small_diff: output/readme.cpp.vocab.txt output/readme.zig.vocab.txt output/readme.zig_stdin.vocab.txt
	diff -W80 $< output/readme.zig.vocab.txt
	diff -W80 $< output/readme.zig_stdin.vocab.txt

big_diff: output/fr.train.cpp.vocab.txt output/fr.train.zig.vocab.txt output/fr.train.zig_stdin.vocab.txt
	diff -W80 $< output/fr.train.zig.vocab.txt
	diff -W80 $< output/fr.train.zig_stdin.vocab.txt

build_server:
	fswatch -o fastBPE/fastBPE.zig | xargs -n1 -I{} zsh -c "clear; (zig build && echo BUILD_SUCCEED) || echo BUILD_FAILED"

clean:
	[ -f ./fast ] ; rm ./fast
	[ -d ./zig-cache ] ; rm -r ./zig-cache
