#!/bin/sh
#
# Serve files of many sizes through the filter, decompress what comes
# back and compare it with the original byte for byte.  This is what the
# Test::Nginx suite cannot do, because a compressed body is binary.
#
# Three defects were found this way and are guarded here:
#
#   - a response was truncated at 131072 bytes when a single input
#     buffer larger than that carried last_buf,
#   - an output buffer that was exactly full when the frame had to be
#     ended was dropped, which happens whenever the compressed form
#     lands on a multiple of the buffer size,
#   - an empty flush buffer with nothing to flush spun the worker.
#
# usage: ci/roundtrip.sh <nginx binary>

set -eu

NGINX=${1:?path to the nginx binary missing}
WORK=${CI_WORK:-$(cd "$(dirname "$0")/.." && pwd)/ci-work}/roundtrip
PORT=${ROUNDTRIP_PORT:-18099}

command -v zstd > /dev/null || { echo "zstd(1) is needed" >&2; exit 2; }
command -v curl > /dev/null || { echo "curl(1) is needed" >&2; exit 2; }

rm -rf "$WORK"
mkdir -p "$WORK/conf" "$WORK/logs" "$WORK/html"

# sizes around the buffer boundaries, where the two truncation defects
# live, plus a spread over the range a response usually has
{
	echo 1; echo 2; echo 1000
	i=4080; while [ $i -le 4120 ]; do echo $i; i=$((i + 1)); done
	i=8180; while [ $i -le 8220 ]; do echo $i; i=$((i + 1)); done
	i=20000; while [ $i -le 20200 ]; do echo $i; i=$((i + 1)); done
	echo 65536; echo 131071; echo 131072; echo 131073
	echo 262144; echo 307200; echo 1048576
} > "$WORK/sizes"

while read -r n; do
	dd if=/dev/urandom of="$WORK/html/s$n.bin" bs=1 count="$n" \
		status=none 2> /dev/null ||
		dd if=/dev/urandom of="$WORK/html/s$n.bin" bs=1 count="$n" 2> /dev/null
done < "$WORK/sizes"

cat > "$WORK/conf/nginx.conf" <<EOF
worker_processes 1;
error_log $WORK/logs/error.log error;
pid $WORK/logs/nginx.pid;
events { worker_connections 64; }
http {
    access_log off;
    default_type application/octet-stream;
    types { application/octet-stream bin; }
    zstd on;
    zstd_types application/octet-stream;
    zstd_min_length 1;
    zstd_comp_level 6;
    server {
        listen 127.0.0.1:$PORT;
        location /small/ { alias $WORK/html/; }
        location /big/   { alias $WORK/html/; output_buffers 1 512k; }
    }
}
EOF

"$NGINX" -p "$WORK" -c conf/nginx.conf -t > /dev/null 2>&1 || {
	"$NGINX" -p "$WORK" -c conf/nginx.conf -t
	exit 1
}
"$NGINX" -p "$WORK" -c conf/nginx.conf

stop() {
	[ -s "$WORK/logs/nginx.pid" ] && kill "$(cat "$WORK/logs/nginx.pid")" 2> /dev/null
	return 0
}
trap stop EXIT

sleep 1

ok=0
bad=0
undecodable=0

check() {
	loc=$1
	name=$2
	orig="$WORK/html/$name"

	curl -sf -o "$WORK/body.zst" -H 'Accept-Encoding: zstd' \
		"http://127.0.0.1:$PORT$loc$name" || {
		echo "  $loc$name: the request failed"
		bad=$((bad + 1))
		return
	}

	if ! zstd -d -q -f -o "$WORK/body" "$WORK/body.zst" > /dev/null 2>&1; then
		echo "  $loc$name: the response does not decompress"
		undecodable=$((undecodable + 1))
		return
	fi

	if cmp -s "$orig" "$WORK/body"; then
		ok=$((ok + 1))
	else
		echo "  $loc$name: $(wc -c < "$WORK/body") bytes back, $(wc -c < "$orig") expected"
		bad=$((bad + 1))
	fi
}

while read -r n; do
	check /small/ "s$n.bin"
done < "$WORK/sizes"

# the same files once more through a single large output buffer
for n in 131072 262144 307200 1048576; do
	check /big/ "s$n.bin"
done

echo "round trip: $ok identical, $bad different, $undecodable undecodable"
[ $((bad + undecodable)) -eq 0 ]
