#!/usr/bin/env bash
# v0.5.0 tests: API-free GitHub resolution, shard caching and SHA-256 checks.
#
# Usage: bash tests/test_v05.sh
#
# Fully offline: a local HTTP server supplies GitHub-style redirects,
# expanded_assets pages, registry shards, release payloads and checksum files.

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
PORT=8128
SRV="$SANDBOX/srv"
LOG="$SRV/requests.log"

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

expect_absent() { # <name> <pattern>
    if grep -q -- "$2" "$OUT"; then
        echo "FAIL: $1 (unexpected pattern: $2)"
        fail=$((fail + 1))
    else
        echo "ok:   $1"
        pass=$((pass + 1))
    fi
}

exists() { # <name> <path-test-exit>
    if [ "$2" -eq 0 ]; then
        echo "ok:   $1"
        pass=$((pass + 1))
    else
        echo "FAIL: $1"
        fail=$((fail + 1))
    fi
}

run() { "$KLUA" "$@" >"$OUT" 2>&1; }

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

# --- local GitHub-like server ------------------------------------------------
mkdir -p "$SRV/v1" "$SRV/files" "$SRV/raw"
: > "$LOG"

cat > "$SRV/server.py" <<'PY'
import http.server
import sys

port = int(sys.argv[1])
root = sys.argv[2]
log = sys.argv[3]

redirects = {
    "/acme/widget/releases/latest": "/acme/widget/releases/tag/v1.2.3",
    "/acme/badsum/releases/latest": "/acme/badsum/releases/tag/v1.2.3",
    "/acme/sumfile/releases/latest": "/acme/sumfile/releases/tag/v2.0.0",
    "/acme/checksums/releases/latest": "/acme/checksums/releases/tag/v3.0.0",
}

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=root, **kwargs)

    def log_message(self, *args):
        pass

    def record(self):
        path = self.path.split("?", 1)[0]
        auth = self.headers.get("Authorization", "")
        with open(log, "a", encoding="utf-8") as stream:
            stream.write("%s %s auth=%s\n" % (self.command, path, auth))

    def redirect(self, target):
        self.send_response(302)
        self.send_header("Location", "http://127.0.0.1:%d%s" % (port, target))
        self.end_headers()

    def do_HEAD(self):
        self.record()
        path = self.path.split("?", 1)[0]
        if path in redirects:
            self.redirect(redirects[path])
            return
        super().do_HEAD()

    def do_GET(self):
        self.record()
        path = self.path.split("?", 1)[0]
        if path in redirects:
            self.redirect(redirects[path])
            return
        super().do_GET()

http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY

python3 "$SRV/server.py" "$PORT" "$SRV" "$LOG" >"$SRV/server.log" 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null; rm -rf "$SANDBOX"' EXIT

ready=0
for _ in $(seq 1 50); do
    if curl -fsS "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 0.1
done
if [ "$ready" -ne 1 ]; then
    echo "error: local server did not start" >&2
    cat "$SRV/server.log" >&2
    exit 1
fi

# --- fixtures ----------------------------------------------------------------
make_pkg() { # <asset-path> <binary> <body>
    local asset="$1" binary="$2" body="$3"
    local dir="$SANDBOX/pkg/$binary"
    mkdir -p "$(dirname "$asset")"
    rm -rf "$dir"
    mkdir -p "$dir"
    printf '#!/bin/sh\n%s\n' "$body" > "$dir/$binary"
    chmod +x "$dir/$binary"
    tar -czf "$asset" -C "$SANDBOX/pkg" "$binary"
}

make_expanded() { # <out> <repo> <tag> <asset>...
    local out="$1" repo="$2" tag="$3"
    shift 3
    mkdir -p "$(dirname "$out")"
    : > "$out"
    for asset in "$@"; do
        printf '<a href="/acme/%s/releases/download/%s/%s">%s</a>\n' \
            "$repo" "$tag" "$asset" "$asset" >> "$out"
    done
}

WIDGET="widget-linux-x86_64.tar.gz"
BADSUM="badsum-linux-x86_64.tar.gz"
SUMFILE="sumfile-linux-x86_64.tar.gz"
SUMS="checksums-linux-x86_64.tar.gz"
LEGACY="legacy-linux-x86_64.tar.gz"
GHTOKEN="ghtoken-linux-x86_64.tar.gz"

WIDGET_PATH="$SRV/acme/widget/releases/download/v1.2.3/$WIDGET"
BADSUM_PATH="$SRV/acme/badsum/releases/download/v1.2.3/$BADSUM"
SUMFILE_PATH="$SRV/acme/sumfile/releases/download/v2.0.0/$SUMFILE"
SUMS_PATH="$SRV/acme/checksums/releases/download/v3.0.0/$SUMS"

make_pkg "$WIDGET_PATH" widget 'echo widget-ok'
make_pkg "$BADSUM_PATH" badsum 'echo badsum-ok'
make_pkg "$SUMFILE_PATH" sumtool 'echo sumfile-ok'
make_pkg "$SUMS_PATH" sumcheck 'echo checksums-ok'
make_pkg "$SRV/files/$LEGACY" legacy 'echo legacy-ok'
make_pkg "$SRV/files/$GHTOKEN" ghtoken 'echo ghtoken-ok'

WIDGET_HASH="$(sha256sum "$WIDGET_PATH" | cut -d' ' -f1)"
SUMFILE_HASH="$(sha256sum "$SUMFILE_PATH" | cut -d' ' -f1)"
SUMS_HASH="$(sha256sum "$SUMS_PATH" | cut -d' ' -f1)"

printf '%s  %s\n' "$WIDGET_HASH" "$WIDGET" > "$WIDGET_PATH.sha256"
printf '%064d  %s\n' 0 "$BADSUM" > "$BADSUM_PATH.sha256"
printf '%s\n' "$SUMFILE_HASH" > "$SUMFILE_PATH.sha256sum"
printf '%s  %s\n' "$SUMS_HASH" "$SUMS" > "$SRV/acme/checksums/releases/download/v3.0.0/checksums.txt"

make_expanded "$SRV/acme/widget/releases/expanded_assets/v1.2.3" widget v1.2.3 \
    "$WIDGET" "$WIDGET.sha256"
make_expanded "$SRV/acme/badsum/releases/expanded_assets/v1.2.3" badsum v1.2.3 \
    "$BADSUM" "$BADSUM.sha256"
make_expanded "$SRV/acme/sumfile/releases/expanded_assets/v2.0.0" sumfile v2.0.0 \
    "$SUMFILE" "$SUMFILE.sha256sum"
make_expanded "$SRV/acme/checksums/releases/expanded_assets/v3.0.0" checksums v3.0.0 \
    "$SUMS" "checksums.txt"

mkdir -p "$SRV/api/repos/acme/legacy/releases" "$SRV/api/repos/acme/ghtoken/releases"
cat > "$SRV/api/repos/acme/legacy/releases/latest" <<EOF
{"tag_name":"v9.0.0","assets":[{"name":"$LEGACY","browser_download_url":"http://127.0.0.1:$PORT/files/$LEGACY"}]}
EOF
cat > "$SRV/api/repos/acme/ghtoken/releases/latest" <<EOF
{"tag_name":"v9.1.0","assets":[{"name":"$GHTOKEN","browser_download_url":"http://127.0.0.1:$PORT/files/$GHTOKEN"}]}
EOF

cat > "$SRV/v1/b.yaml" <<EOF
bz3: gh:acme/widget
EOF
printf 'placeholder: gh:example/placeholder\n' > "$SRV/v1/_.yaml"

mkdir -p "$SANDBOX/.config/klua"
cat > "$SANDBOX/.config/klua/init.lua" <<EOF
klua.registries = { "http://127.0.0.1:$PORT" }
klua.github_web = "http://127.0.0.1:$PORT"
klua.github_api = "http://127.0.0.1:$PORT/api"
klua.raw_github = "http://127.0.0.1:$PORT/raw"
EOF

mkdir -p "$SANDBOX/.local/bin"
export PATH="$HOME/.local/bin:$PATH"

# --- version and CLI flags ---------------------------------------------------
run --version
check "--version exits 0" 0 $?
expect_output "version is 0.7.0" "klua 0.7.0"

run --help
check "--help exits 0" 0 $?

run install --help
expect_output "install help lists --no-cache" "--no-cache"
expect_output "install help lists --skip-checksum" "--skip-checksum"

# --- API-free GitHub resolution ----------------------------------------------
: > "$LOG"
run install gh:acme/widget
check "web-resolved install exits 0" 0 $?
expect_output "web resolution reported" "from web release"
expect_output "tag came from redirect" "v1.2.3"
expect_output "asset selected" "$WIDGET"
log_expect "latest tag used a HEAD redirect" "HEAD /acme/widget/releases/latest" 1
log_expect "expanded_assets fetched" "GET /acme/widget/releases/expanded_assets/v1.2.3" 1
log_expect "no REST API call for web release" "/api/repos/acme/widget" 0
expect_output "sha256 sidecar verified" "sha256 verified for $WIDGET"

[ -L "$HOME/.local/bin/widget" ]
exists "web-resolved binary linked" $?
[ -d "$HOME/.local/share/klua/store/gh/acme/widget/v1.2.3" ]
exists "web-resolved package stored by tag" $?

# --- pinned tag skips the latest redirect -----------------------------------
: > "$LOG"
run install "gh:acme/widget@v1.2.3"
check "pinned-tag install exits 0" 0 $?
log_expect "pinned tag skips latest HEAD" "HEAD /acme/widget/releases/latest" 0
log_expect "pinned tag reads expanded_assets" "GET /acme/widget/releases/expanded_assets/v1.2.3" 1

# --- REST fallback still works with tokens ----------------------------------
: > "$LOG"
GITHUB_TOKEN=test-token-123 KLUA_GITHUB_API_HOST=127.0.0.1 \
    run install gh:acme/legacy
check "API fallback install exits 0" 0 $?
expect_output "API fallback announced" "falling back to GitHub API"
expect_output "legacy asset installed" "$LEGACY"
log_expect "API fallback called REST" "GET /api/repos/acme/legacy/releases/latest" 1
log_expect "GITHUB_TOKEN sent as Bearer" "auth=Bearer test-token-123" 1

: > "$LOG"
GITHUB_TOKEN= GH_TOKEN=gh-token-456 KLUA_GITHUB_API_HOST=127.0.0.1 \
    run install gh:acme/ghtoken
check "GH_TOKEN fallback install exits 0" 0 $?
log_expect "GH_TOKEN sent as Bearer" "auth=Bearer gh-token-456" 1

# --- SHA-256 mismatch and --skip-checksum -----------------------------------
run install gh:acme/badsum
check "checksum mismatch aborts install" 1 $?
expect_output "mismatch reported" "SHA-256 mismatch for $BADSUM"
[ ! -d "$HOME/.local/share/klua/store/gh/acme/badsum/v1.2.3" ]
exists "mismatched package not extracted" $?
[ ! -L "$HOME/.local/bin/badsum" ]
exists "mismatched package not linked" $?

run install --skip-checksum gh:acme/badsum
check "--skip-checksum allows install" 0 $?
expect_output "skip warning shown" "checksum verification skipped via --skip-checksum"
[ -L "$HOME/.local/bin/badsum" ]
exists "skipped-checksum package linked" $?

# --- other checksum asset layouts -------------------------------------------
run install gh:acme/sumfile
check ".sha256sum install exits 0" 0 $?
expect_output ".sha256sum verified" "sha256 verified for $SUMFILE"

run install gh:acme/checksums
check "checksums.txt install exits 0" 0 $?
expect_output "checksums.txt verified" "sha256 verified for $SUMS"

# --- registry shard caching --------------------------------------------------
: > "$LOG"
run search bz3
check "first search exits 0" 0 $?
expect_output "search finds cached alias" "bz3"
log_expect "first search fetches b shard" "GET /v1/b.yaml" 1

before="$(log_count "GET /v1/b.yaml")"
run search bz3
check "second search exits 0" 0 $?
after="$(log_count "GET /v1/b.yaml")"
check "second search uses cached shard" "$before" "$after"

[ -d "$HOME/.cache/klua/shards" ]
exists "shard cache directory created" $?
ls "$HOME/.cache/klua/shards"/*.yaml >/dev/null 2>&1
exists "shard cache file written" $?

run search --no-cache bz3
check "--no-cache search exits 0" 0 $?
after_no_cache="$(log_count "GET /v1/b.yaml")"
check "--no-cache refetches shard" "$((after + 1))" "$after_no_cache"

: > "$LOG"
run install bz3
check "alias install exits 0" 0 $?
log_expect "alias install uses cached shard" "GET /v1/b.yaml" 0

# --- flags also parse on the prefix `run` command ----------------------------
: > "$LOG"
run run --no-cache bz3 extra-arg
check "run --no-cache exits 0" 0 $?
expect_output "run still passes through arguments" "widget-ok"
log_expect "run --no-cache refetches shard" "GET /v1/b.yaml" 1

run run --skip-checksum gh:acme/badsum
check "run --skip-checksum exits 0" 0 $?

# --- typo hints include the new flags ---------------------------------------
run install --no-cach gh:acme/widget
check "unknown flag exits nonzero" 1 $?
expect_output "typo suggests --no-cache" "did you mean '--no-cache'?"

run install --skip-cheksum gh:acme/widget
check "skip-checksum typo exits nonzero" 1 $?
expect_output "typo suggests --skip-checksum" "did you mean '--skip-checksum'?"

echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
