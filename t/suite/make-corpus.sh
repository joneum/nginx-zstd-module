#!/bin/sh
#
# Builds the corpus the test suite serves, t/suite/test and its
# compressed form t/suite/test.zst.
#
# The corpus is generated here and not taken from anywhere, so that the
# repository carries nothing it has not been given the right to pass on.
# Generation is deterministic: the generator seeds a Park-Miller
# sequence with a fixed number and uses only integer arithmetic that
# stays inside what a double represents exactly, so every awk produces
# the same bytes.
#
# The sizes of both files are written into t/01-static.t, which checks
# Content-Length.  After running this, update those numbers.
#
# usage: t/suite/make-corpus.sh

set -eu

cd "$(dirname "$0")"

command -v zstd > /dev/null || { echo "zstd(1) is needed" >&2; exit 2; }

# named, because a bare "> test" reads like a redirection into the
# test(1) command
corpus="test"
compressed="test.zst"

awk 'BEGIN {
	seed = 20261005
	nw = split("the quick brown fox jumps over a lazy dog nginx module " \
		"filter static cache buffer stream frame level ratio header " \
		"request response client server socket worker process config " \
		"location directive variable encoding content length chunk " \
		"window dictionary compress decompress input output source " \
		"target block literal match offset table entry index value " \
		"key pair list array string number boolean upstream proxy " \
		"handler phase rewrite body file path prefix suffix", w, " ")

	# a banner that repeats, which a compressor should fold away
	for (i = 0; i < 40; i++)
		print "# generated corpus for the zstd module test suite, line of a repeating banner"
	print ""

	# prose-like text, moderately compressible
	for (p = 0; p < 320; p++) {
		line = ""
		words = 8 + pick(10)
		for (i = 0; i < words; i++) {
			word = w[1 + pick(nw)]
			line = (line == "") ? word : line " " word
		}
		print line "."
		if (p % 12 == 11)
			print ""
	}

	# structured records, highly regular
	for (r = 0; r < 420; r++)
		printf "record_%05d key=%s value=%d state=%s\n", \
			r, w[1 + pick(nw)], pick(100000), \
			(r % 3 == 0 ? "open" : (r % 3 == 1 ? "half" : "closed"))
	print ""

	# pseudo-random hex, which hardly compresses at all
	for (h = 0; h < 220; h++) {
		line = ""
		for (i = 0; i < 8; i++)
			line = line sprintf("%08x", rnd())
		print line
	}
}

function rnd() {
	seed = (seed * 16807) % 2147483647
	return seed
}

function pick(n) {
	return int(rnd() % n)
}' > "$corpus"

zstd -q -19 -f -o "$compressed" "$corpus"

echo "$corpus      $(wc -c < "$corpus" | tr -d " ") bytes"
echo "$compressed  $(wc -c < "$compressed" | tr -d " ") bytes"
echo
echo "Put those two numbers into t/01-static.t."
