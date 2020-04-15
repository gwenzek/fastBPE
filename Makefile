build: ./zig-cache/bin/fastBPE ./fast

./zig-cache/bin/fastBPE: fastBPE/fastBPE.zig
	zig build

./fast: fastBPE/fastBPE.hpp fastBPE/main.cc
	g++ -std=c++11 -pthread -O3 fastBPE/main.cc -IfastBPE -o $@

output/readme_zig_vocab.txt: ./zig-cache/bin/fastBPE
	mkdir -p output
	$< `realpath README.md` > $@

output/readme_cpp_vocab.txt: ./fast
	mkdir -p output
	./fast getvocab `realpath README.md` > $@

diff: output/readme_cpp_vocab.txt output/readme_zig_vocab.txt
	diff -W 80 $^

test: diff
	zig test fastBPE/fastBPE.zig

clean:
	[ -f ./fast ] ; rm ./fast
	[ -d ./zig-cache ] ; rm -r ./zig-cache
