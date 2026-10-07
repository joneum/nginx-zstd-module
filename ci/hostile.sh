#!/bin/sh
#
# Put the filter behind an upstream that misbehaves, and in front of a
# client that walks away.
#
# Everything else here hands the filter a finished body from disk or from
# a return directive: one buffer, complete, well formed.  That is the easy
# case.  A body filter earns its keep on the others -- a body that arrives
# in pieces over time, an upstream that announces more than it sends and
# then closes, a client that disconnects while the frame is still open.
# Those are the paths where a compressor either leaks its stream, hands out
# a frame it never finished, or spins.
#
# The three defects this module already carries fixes for were all in that
# area: an empty flush buffer with nothing left to flush, a single input
# buffer larger than the output buffer, an output buffer that was exactly
# full when the frame had to be ended.  None of them needed a hostile peer
# to appear, but all of them live in the same code the cases below walk
# through.
#
# usage: ci/hostile.sh <nginx binary>
#
# A scriptable peer is unavoidable: sh and curl cannot be taught to lie
# about Content-Length or to send a body a byte at a time.  python3 does
# it in a few lines and is already on every runner this repository uses.

set -eu

NGINX=${1:?path to the nginx binary missing}
WORK=${CI_WORK:-$(cd "$(dirname "$0")/.." && pwd)/ci-work}/hostile
PORT=${HOSTILE_PORT:-18300}
BPORT=${HOSTILE_BACKEND_PORT:-18301}

command -v curl > /dev/null || { echo "curl(1) is needed" >&2; exit 2; }
command -v zstd > /dev/null || { echo "zstd(1) is needed" >&2; exit 2; }
command -v python3 > /dev/null || { echo "python3 is needed for the peer" >&2; exit 2; }

rm -rf "$WORK"
mkdir -p "$WORK/conf" "$WORK/logs"

fail=0
note() {
	echo "  $1" >&2
	fail=1
}

# ---------------------------------------------------------------- the peer
#
# One process, one port, and the path decides how it behaves.  It speaks
# HTTP/1.0 so that nginx does not keep the connection and the end of the
# body is simply the close, except where the point of the case is a
# Content-Length that does not match.

cat > "$WORK/peer.py" <<'PEER'
import socket, sys, threading, time

PORT = int(sys.argv[1])
BODY = (b"the quick brown fox jumps over the lazy dog, "
        b"and keeps jumping, because a compressor wants something to chew on. ") * 64


def head(extra=b""):
    return (b"HTTP/1.0 200 OK\r\n"
            b"Content-Type: text/plain\r\n" + extra + b"\r\n")


def serve(c):
    try:
        req = b""
        while b"\r\n\r\n" not in req:
            d = c.recv(4096)
            if not d:
                return
            req += d
        path = req.split(b" ")[1] if b" " in req else b"/"

        if path.startswith(b"/drip"):
            # The body arrives in small pieces with pauses between them, so
            # the filter is handed many buffers instead of one.
            c.sendall(head())
            for i in range(0, len(BODY), 97):
                c.sendall(BODY[i:i + 97])
                time.sleep(0.004)

        elif path.startswith(b"/lie"):
            # Announces far more than it sends and then closes.  nginx has
            # to notice; what matters here is that the filter does not hand
            # the client a frame it never finished as if it were whole.
            c.sendall(head(b"Content-Length: 100000\r\n"))
            c.sendall(BODY[:200])

        elif path.startswith(b"/slow"):
            # Still sending when the client gives up.
            c.sendall(head())
            for _ in range(200):
                c.sendall(BODY[:64])
                time.sleep(0.05)

        elif path.startswith(b"/empty"):
            c.sendall(head(b"Content-Length: 0\r\n"))

        else:
            c.sendall(head())
            c.sendall(BODY)
    except Exception:
        pass
    finally:
        try:
            c.close()
        except Exception:
            pass


srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", PORT))
srv.listen(16)
print("ready", flush=True)
while True:
    conn, _ = srv.accept()
    threading.Thread(target=serve, args=(conn,), daemon=True).start()
PEER

python3 "$WORK/peer.py" "$BPORT" > "$WORK/peer.out" 2>&1 &
PEER_PID=$!

stop() {
	kill "$PEER_PID" 2> /dev/null
	[ -s "$WORK/logs/nginx.pid" ] && kill "$(cat "$WORK/logs/nginx.pid")" 2> /dev/null
	return 0
}
trap stop EXIT

n=0
while [ $n -lt 50 ]; do
	grep -q ready "$WORK/peer.out" 2> /dev/null && break
	n=$((n + 1))
	sleep 0.1 2> /dev/null || sleep 1
done
grep -q ready "$WORK/peer.out" 2> /dev/null || {
	echo "the peer did not come up:" >&2
	cat "$WORK/peer.out" >&2
	exit 1
}

# --------------------------------------------------------------- the server

ngx_user=
if [ "$(id -u)" = 0 ]; then
	ngx_user="user root $(id -gn);"
fi

cat > "$WORK/conf/nginx.conf" <<EOF
$ngx_user
worker_processes 1;
error_log $WORK/logs/error.log info;
pid $WORK/logs/nginx.pid;
events { worker_connections 64; }
http {
    access_log off;

    server {
        listen 127.0.0.1:$PORT;

        location / {
            zstd on;
            zstd_types text/plain;
            zstd_min_length 1;
            proxy_pass http://127.0.0.1:$BPORT;
            proxy_http_version 1.0;
        }
    }
}
EOF

echo "--- the configuration is read ---"
"$NGINX" -p "$WORK" -c conf/nginx.conf -t

"$NGINX" -p "$WORK" -c conf/nginx.conf
sleep 1

# What the peer sends for the cases that are meant to succeed, so the
# comparison below is against the real thing and not against a length.
python3 - "$WORK/expected" <<'MAKE'
import sys
body = (b"the quick brown fox jumps over the lazy dog, "
        b"and keeps jumping, because a compressor wants something to chew on. ") * 64
open(sys.argv[1], "wb").write(body)
MAKE

fetch_zstd() {
	curl -s --max-time 20 -H 'Accept-Encoding: zstd' \
		-o "$WORK/body.zst" -D "$WORK/head" \
		"http://127.0.0.1:$PORT$1"
}

encoding() {
	tr -d '\r' < "$WORK/head" | sed -n 's/^[Cc]ontent-[Ee]ncoding: //p'
}

echo "--- a body that arrives in pieces comes back whole ---"
if fetch_zstd /drip; then
	if [ "$(encoding)" != zstd ]; then
		note "the filter did not engage, Content-Encoding is \"$(encoding)\""
	elif zstd -d -q -c "$WORK/body.zst" > "$WORK/body" 2> /dev/null &&
		cmp -s "$WORK/expected" "$WORK/body"; then
		echo "  identical to what the peer sent"
	else
		note "the body came back changed or the frame does not decompress"
	fi
else
	note "the request failed"
fi

echo "--- an upstream that promises more than it sends ---"
# nginx is expected to treat this as a failed upstream.  The point is not
# which status it picks but that a truncated body is never handed over as a
# complete, decompressible frame.
# Not "curl || echo 000": -w has already printed the status by then, and
# the two would end up concatenated.  curl is expected to fail here, the
# upstream closes in the middle of the transfer.
code=$(curl -s --max-time 20 -H 'Accept-Encoding: zstd' \
	-o "$WORK/lie.zst" -w '%{http_code}' \
	"http://127.0.0.1:$PORT/lie" 2> /dev/null || true)
[ -n "$code" ] || code=000
if zstd -t -q "$WORK/lie.zst" 2> /dev/null; then
	note "HTTP $code, and the truncated answer decompresses as a whole frame"
else
	echo "  HTTP $code, and the answer is not a complete frame"
fi

echo "--- a client that walks away while the frame is open ---"
curl -s --max-time 1 -H 'Accept-Encoding: zstd' \
	-o /dev/null "http://127.0.0.1:$PORT/slow" 2> /dev/null || true
sleep 1
if kill -0 "$(cat "$WORK/logs/nginx.pid")" 2> /dev/null; then
	echo "  nginx is still there"
else
	note "nginx died"
fi

echo "--- an empty body with the filter switched on ---"
if fetch_zstd /empty; then
	if [ -s "$WORK/body.zst" ] && ! zstd -t -q "$WORK/body.zst" 2> /dev/null; then
		note "the answer is neither empty nor a valid frame"
	else
		echo "  answered without a stall"
	fi
else
	note "the request failed or timed out"
fi

echo "--- a HEAD request with the filter switched on ---"
code=$(curl -s --max-time 10 -I -H 'Accept-Encoding: zstd' \
	-o "$WORK/headonly" -w '%{http_code}' \
	"http://127.0.0.1:$PORT/plain" 2> /dev/null || true)
[ -n "$code" ] || code=000
size=$(curl -s --max-time 10 -I -H 'Accept-Encoding: zstd' \
	-w '%{size_download}' -o /dev/null \
	"http://127.0.0.1:$PORT/plain" 2> /dev/null || true)
[ -n "$size" ] || size=-1
if [ "$code" = 200 ] && [ "$size" = 0 ]; then
	echo "  HTTP 200 and no body"
else
	note "HTTP $code with $size bytes of body"
fi

echo "--- the worker survived all of it ---"
if kill -0 "$(cat "$WORK/logs/nginx.pid")" 2> /dev/null; then
	echo "  yes"
else
	note "the master is gone"
fi

if grep -qE '\[alert\]|\[crit\]|\[emerg\]|exited on signal' "$WORK/logs/error.log" 2> /dev/null; then
	echo "--- the error log complains ---" >&2
	grep -E '\[alert\]|\[crit\]|\[emerg\]|exited on signal' "$WORK/logs/error.log" | head -5 >&2
	fail=1
fi

[ "$fail" -eq 0 ]
