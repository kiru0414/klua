#!/usr/bin/env bash
# Regression tests for cross-host redirect handling in src/http.cpp.
#
# Usage: bash tests/test_http_redirects.sh
#
# Fully offline: two local HTTP servers simulate a GitHub API host and a
# release CDN. They record request headers so the tests can prove that a
# User-Agent survives every hop while API tokens are dropped as soon as the
# host or path changes.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KLUA="$ROOT/build/klua"

if [ ! -x "$KLUA" ]; then
    echo "error: $KLUA not found; build first (cmake --build build)" >&2
    exit 1
fi

SANDBOX="$(mktemp -d)"
export HOME="$SANDBOX"
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME

OUT="$SANDBOX/out.txt"
SRV="$SANDBOX/srv"
LOG="$SRV/requests.log"
PORT_A=8131
PORT_B=8132

pass=0
fail=0

check() { # <name> <expected-exit> <actual-exit>
    if [ "$2" -eq "$3" ]; then
        echo "ok:   $1"
        pass=$((pass + 1))
    else
        echo "FAIL: $1 (expected exit $2, got $3)"
        fail=$((fail + 1))
    fi
}

expect_output() { # <name> <pattern>
    if grep -q -- "$2" "$OUT"; then
        echo "ok:   $1"
        pass=$((pass + 1))
    else
        echo "FAIL: $1 (missing pattern: $2)"
        fail=$((fail + 1))
    fi
}

log_count() {
    local count
    count="$(grep -c -- "$1" "$LOG" 2>/dev/null || true)"
    echo "${count:-0}"
}

log_expect() { # <name> <pattern> <expected-count>
    local actual
    actual="$(log_count "$2")"
    if [ "$actual" -eq "$3" ]; then
        echo "ok:   $1"
        pass=$((pass + 1))
    else
        echo "FAIL: $1 (expected $3 request(s) matching '$2', got $actual)"
        fail=$((fail + 1))
    fi
}

log_absent() { # <name> <pattern>
    local count
    count="$(log_count "$2")"
    if [ "$count" -eq 0 ]; then
        echo "ok:   $1"
        pass=$((pass + 1))
    else
        echo "FAIL: $1 (unexpected log match: $2)"
        fail=$((fail + 1))
    fi
}

run() { "$KLUA" "$@" >"$OUT" 2>&1; }

# --- fixtures and redirect server --------------------------------------------
mkdir -p "$SRV/new/repo"
printf '#!/bin/sh\necho redirect-ok\n' > "$SRV/final-binary"
cp "$SRV/final-binary" "$SRV/new/repo/tool"
printf 'bz3: url:http://127.0.0.1:%s/api/download/start\n' "$PORT_A" > "$SRV/final-shard"
: > "$LOG"

cat > "$SRV/server.py" <<'PY'
import http.server
import sys
import threading

log = sys.argv[1]
root = sys.argv[2]
port_a = int(sys.argv[3])
port_b = int(sys.argv[4])

redirects = {
    port_a: {
        # Registry shard fetch: API host -> CDN -> API host (non-API path).
        "/api/v1/b.yaml": (302, "http://127.0.0.1:%d/cdn" % port_b),
        # Download: API-looking path -> CDN, then two more redirect types.
        "/api/download/start": (302, "http://127.0.0.1:%d/hop307" % port_b),
        # Repository rename on the same host.
        "/old/repo/tool": (301, "http://127.0.0.1:%d/new/repo/tool" % port_a),
    },
    port_b: {
        "/cdn": (301, "http://127.0.0.1:%d/final-shard" % port_a),
        "/hop307": (307, "http://127.0.0.1:%d/presigned?X-Amz-Signature=sig123" % port_b),
        "/presigned": (308, "http://127.0.0.1:%d/final-binary" % port_a),
    },
}


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=root, **kwargs)

    def log_message(self, *args):
        pass

    def record(self):
        auth = self.headers.get("Authorization", "-")
        private = self.headers.get("PRIVATE-TOKEN", "-")
        ua = self.headers.get("User-Agent", "-")
        with open(log, "a", encoding="utf-8") as stream:
            stream.write("%d %s %s auth=%s private=%s ua=%s\n" % (
                self.server.server_port, self.command, self.path,
                auth, private, ua))

    def redirect(self, status, target):
        self.send_response(status)
        self.send_header("Location", target)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def dispatch_request(self, method):
        self.record()
        path = self.path.split("?", 1)[0]
        target = redirects.get(self.server.server_port, {}).get(path)
        if target:
            self.redirect(*target)
        elif method == "HEAD":
            super().do_HEAD()
        else:
            super().do_GET()

    def do_GET(self):
        self.dispatch_request("GET")

    def do_HEAD(self):
        self.dispatch_request("HEAD")


def serve(port):
    http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


threading.Thread(target=serve, args=(port_b,), daemon=True).start()
serve(port_a)
PY

python3 "$SRV/server.py" "$LOG" "$SRV" "$PORT_A" "$PORT_B" >"$SRV/server.log" 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null; rm -rf "$SANDBOX"' EXIT

for port in "$PORT_A" "$PORT_B"; do
    ready=0
    for _ in $(seq 1 50); do
        if curl -fsS "http://127.0.0.1:$port/" >/dev/null 2>&1; then
            ready=1
            break
        fi
        sleep 0.1
    done
    if [ "$ready" -ne 1 ]; then
        echo "error: local server on port $port did not start" >&2
        cat "$SRV/server.log" >&2
        exit 1
    fi
done

mkdir -p "$SANDBOX/.config/klua"
cat > "$SANDBOX/.config/klua/init.lua" <<EOF
klua.registries = { "http://127.0.0.1:$PORT_A/api" }
EOF

# KLUA_*_API_HOST opts klua into tokens on this local "API" host. The tests
# below verify those tokens never reach the CDN or non-API paths on any hop.
export GITHUB_TOKEN="gh-regression-token"
export GH_TOKEN="gh-regression-token"
export GITLAB_TOKEN="gl-regression-token"
export KLUA_GITHUB_API_HOST="127.0.0.1"
export KLUA_GITLAB_API_HOST="127.0.0.1"

# --- alias shard GET through 302 -> 301 --------------------------------------
run i --no-cache bz3
check "alias install through cross-host redirects exits 0" 0 $?
expect_output "alias resolved through redirected shard" "resolved 'bz3' -> url:http://127.0.0.1:$PORT_A/api/download/start"
[ -L "$HOME/.local/bin/start" ]
check "redirected download created a symlink" 0 $?

"$HOME/.local/bin/start" >"$OUT" 2>&1
check "installed redirected binary runs" 0 $?
expect_output "installed payload came through redirects" "redirect-ok"

# --- download through 302 -> 307 -> 308 with a signed query ------------------
log_expect "shard GET carried API tokens" \
    "^$PORT_A GET /api/v1/b.yaml auth=Bearer .* private=gl-regression-token ua=klua/" 1
log_expect "302 crossed to CDN without tokens" \
    "^$PORT_B GET /cdn auth=- private=- ua=klua/" 1
log_expect "301 returned to API host without tokens on non-API path" \
    "^$PORT_A GET /final-shard auth=- private=- ua=klua/" 1
log_expect "download GET carried API tokens" \
    "^$PORT_A GET /api/download/start auth=Bearer .* private=gl-regression-token ua=klua/" 1
log_expect "307 crossed to CDN without tokens" \
    "^$PORT_B GET /hop307 auth=- private=- ua=klua/" 1
log_expect "308 kept the presigned query without tokens" \
    "^$PORT_B GET /presigned?X-Amz-Signature=sig123 auth=- private=- ua=klua/" 1
log_expect "final payload request carried no tokens" \
    "^$PORT_A GET /final-binary auth=- private=- ua=klua/" 1
log_absent "CDN host never received a Bearer token" "^$PORT_B .* auth=Bearer"
log_absent "CDN host never received a GitLab token" "^$PORT_B .* private=gl-"

# --- repository rename (301) -------------------------------------------------
run i --force "url:http://127.0.0.1:$PORT_A/old/repo/tool"
check "repo-rename install exits 0" 0 $?
[ -L "$HOME/.local/bin/tool" ]
check "repo-rename symlink created" 0 $?
"$HOME/.local/bin/tool" >"$OUT" 2>&1
check "repo-rename binary runs" 0 $?
expect_output "repo-rename payload served" "redirect-ok"
log_expect "301 followed from old repo path" \
    "^$PORT_A GET /old/repo/tool auth=- private=- ua=klua/" 1
log_expect "301 reached renamed repo path" \
    "^$PORT_A GET /new/repo/tool auth=- private=- ua=klua/" 1

if [ "$fail" -ne 0 ]; then
    echo "--- request log ---" >&2
    sed -n '1,40p' "$LOG" >&2
fi

echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
