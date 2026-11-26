#!/usr/bin/env bash
# v0.7.0 tests: parallel batching, fail-safe 3-tier GitHub resolution,
# TOFU lock enforcement and the optional signature verification hook.
#
# Usage: bash tests/test_v07.sh
#
# Fully offline: a local HTTP server supplies GitHub-style endpoints, registry
# shards, manifests and archives. The server records peak concurrency so the
# bounded worker pool can be observed directly.

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
PORT=8132
SRV="$SANDBOX/srv"
LOG="$SRV/requests.log"
PEAK="$SRV/peak.txt"

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

peak_at_least() { # <name> <minimum>
    local peak
    peak="$(cat "$PEAK" 2>/dev/null || echo 0)"
    if [ "${peak:-0}" -ge "$2" ]; then
        echo "ok:   $1 (peak $peak)"
        pass=$((pass + 1))
    else
        echo "FAIL: $1 (expected peak >= $2, got ${peak:-0})"
        fail=$((fail + 1))
    fi
}

run() { "$KLUA" "$@" >"$OUT" 2>&1; }

# --- local GitHub-like server ------------------------------------------------
mkdir -p "$SRV/v1" "$SRV/files"
: > "$LOG"

cat > "$SRV/server.py" <<'PY'
import http.server
import os
import sys
import threading
import time

port = int(sys.argv[1])
root = sys.argv[2]
log = sys.argv[3]
peak_file = sys.argv[4]

count_lock = threading.Lock()
active = 0
peak = 0

TAGS = {
    "/acme/webtool/releases/latest": "/acme/webtool/releases/tag/v1.0.0",
    "/acme/atomtool/releases/latest": "/acme/atomtool/releases/tag/v2.0.0",
    "/acme/apitool/releases/latest": "/acme/apitool/releases/tag/v3.0.0",
    "/acme/verifyok/releases/latest": "/acme/verifyok/releases/tag/v1.5.0",
    "/acme/verifybad/releases/latest": "/acme/verifybad/releases/tag/v1.6.0",
}

def enter():
    global active, peak
    with count_lock:
        active += 1
        if active > peak:
            peak = active
            with open(peak_file, "w", encoding="utf-8") as stream:
                stream.write(str(peak))

def leave():
    global active
    with count_lock:
        active -= 1

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=root, **kwargs)

    def log_message(self, *args):
        pass

    def record(self):
        path = self.path.split("?", 1)[0]
        with open(log, "a", encoding="utf-8") as stream:
            stream.write("%s %s\n" % (self.command, path))

    def respond_redirect(self, target):
        self.send_response(302)
        self.send_header("Location", "http://127.0.0.1:%d%s" % (port, target))
        self.end_headers()

    def do_HEAD(self):
        enter()
        try:
            self.record()
            path = self.path.split("?", 1)[0]
            if path in TAGS:
                self.respond_redirect(TAGS[path])
                return
            super().do_HEAD()
        finally:
            leave()

    def do_GET(self):
        enter()
        try:
            self.record()
            path = self.path.split("?", 1)[0]
            if path in TAGS:
                self.respond_redirect(TAGS[path])
                return
            if path == "/__reset_peak":
                with count_lock:
                    globals()["peak"] = 0
                    with open(peak_file, "w", encoding="utf-8") as stream:
                        stream.write("0")
                self.send_response(204)
                self.end_headers()
                return
            if path.startswith("/v1/"):
                time.sleep(0.1)
            elif "/releases/download/" in path or path.startswith("/files/"):
                time.sleep(0.25)
            super().do_GET()
        finally:
            leave()

http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY

python3 "$SRV/server.py" "$PORT" "$SRV" "$LOG" "$PEAK" >"$SRV/server.log" 2>&1 &
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
    local sum
    sum="$(sha256sum "$asset" | cut -d' ' -f1)"
    printf '%s  %s\n' "$sum" "$(basename "$asset")" > "$asset.sha256"
}

make_expanded() { # <repo> <tag> <asset>...
    local repo="$1" tag="$2"
    shift 2
    local dir="$SRV/acme/$repo/releases/expanded_assets"
    mkdir -p "$dir"
    : > "$dir/$tag"
    for asset in "$@"; do
        printf '<a href="/acme/%s/releases/download/%s/%s">%s</a>\n' \
            "$repo" "$tag" "$asset" "$asset" >> "$dir/$tag"
    done
}

WEBTOOL="webtool-linux-x86_64.tar.gz"
ATOMTOOL="atomtool-linux-x86_64.tar.gz"
APITOOL="apitool-linux-x86_64.tar.gz"
VERIFYOK="verifyok-linux-x86_64.tar.gz"
VERIFYBAD="verifybad-linux-x86_64.tar.gz"

make_pkg "$SRV/acme/webtool/releases/download/v1.0.0/$WEBTOOL" webtool 'echo webtool-ok'
make_pkg "$SRV/acme/atomtool/releases/download/v2.0.0/$ATOMTOOL" atomtool 'echo atomtool-ok'
make_pkg "$SRV/files/$APITOOL" apitool 'echo apitool-ok'
make_pkg "$SRV/acme/verifyok/releases/download/v1.5.0/$VERIFYOK" verifyok 'echo verifyok-ok'
make_pkg "$SRV/acme/verifybad/releases/download/v1.6.0/$VERIFYBAD" verifybad 'echo verifybad-ok'
cp "$SRV/acme/webtool/releases/download/v1.0.0/$WEBTOOL" "$SANDBOX/webtool.backup"

make_expanded webtool v1.0.0 "$WEBTOOL" "$WEBTOOL.sha256"
make_expanded verifyok v1.5.0 "$VERIFYOK" "$VERIFYOK.sha256"
make_expanded verifybad v1.6.0 "$VERIFYBAD" "$VERIFYBAD.sha256"

# Tier 1 fails: the expanded Assets page parses to zero download links.
mkdir -p "$SRV/acme/atomtool/releases/expanded_assets"
printf '<div>No assets on this page</div>\n' > "$SRV/acme/atomtool/releases/expanded_assets/v2.0.0"

# Tier 2 succeeds: the Atom feed carries both the tag and a download link.
mkdir -p "$SRV/acme/atomtool/releases"
cat > "$SRV/acme/atomtool/releases.atom" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry>
    <title>v2.0.0</title>
    <link rel="alternate" href="http://127.0.0.1:$PORT/acme/atomtool/releases/tag/v2.0.0"/>
    <content type="html">&lt;a href="/acme/atomtool/releases/download/v2.0.0/$ATOMTOOL"&gt;$ATOMTOOL&lt;/a&gt;</content>
  </entry>
</feed>
EOF

# Both Tier 1 and Tier 2 fail for apitool: empty page, Atom entry with no links.
mkdir -p "$SRV/acme/apitool/releases/expanded_assets"
printf '<div>No assets on this page</div>\n' > "$SRV/acme/apitool/releases/expanded_assets/v3.0.0"
cat > "$SRV/acme/apitool/releases.atom" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry>
    <title>v3.0.0</title>
    <link rel="alternate" href="http://127.0.0.1:$PORT/acme/apitool/releases/tag/v3.0.0"/>
  </entry>
</feed>
EOF
mkdir -p "$SRV/api/repos/acme/apitool/releases"
cat > "$SRV/api/repos/acme/apitool/releases/latest" <<EOF
{"tag_name":"v3.0.0","assets":[{"name":"$APITOOL","browser_download_url":"http://127.0.0.1:$PORT/files/$APITOOL"}]}
EOF

# Manifests carrying the optional verification hook.
for ref in HEAD v1.5.0; do
    mkdir -p "$SRV/acme/verifyok/$ref"
    cat > "$SRV/acme/verifyok/$ref/klua.yaml" <<'EOF'
verify: "test -s {payload}"
EOF
done
for ref in HEAD v1.6.0; do
    mkdir -p "$SRV/acme/verifybad/$ref"
    cat > "$SRV/acme/verifybad/$ref/klua.yaml" <<'EOF'
verify: "false"
EOF
done

printf 'webtool: gh:acme/webtool\n' > "$SRV/v1/w.yaml"
printf 'atomtool: gh:acme/atomtool\n' > "$SRV/v1/a.yaml"

mkdir -p "$SANDBOX/.config/klua" "$SANDBOX/.local/bin"
cat > "$SANDBOX/.config/klua/init.lua" <<EOF
klua.registries = { "http://127.0.0.1:$PORT" }
klua.github_web = "http://127.0.0.1:$PORT"
klua.github_api = "http://127.0.0.1:$PORT/api"
klua.raw_github = "http://127.0.0.1:$PORT"
EOF
export PATH="$HOME/.local/bin:$PATH"

# --- version and API surface -------------------------------------------------
run --version
check "--version exits 0" 0 $?
expect_output "version is 0.9.1" "klua 0.9.1"

# --- parallel shard fetching (bounded worker pool) ---------------------------
rm -f "$PEAK"
run search webtool
check "search exits 0" 0 $?
expect_output "search finds registry alias" "webtool"
peak_at_least "search fetched shards concurrently" 4

# --- tier 2: Atom feed fallback ---------------------------------------------
: > "$LOG"
run install gh:acme/atomtool
check "atom fallback install exits 0" 0 $?
expect_output "atom tier reported" "from releases.atom"
[ -L "$HOME/.local/bin/atomtool" ]
exists "atom fallback linked binary" $?
log_expect "atom tier scraped expanded assets once" "GET /acme/atomtool/releases/expanded_assets/v2.0.0" 1
log_expect "atom tier read the Atom feed" "GET /acme/atomtool/releases.atom" 1
log_expect "atom tier avoided the REST API" "GET /api/repos/acme/atomtool" 0

# --- tier 3: REST API fallback after two failures ---------------------------
: > "$LOG"
run install gh:acme/apitool
check "API fallback install exits 0" 0 $?
expect_output "REST fallback reported" "from GitHub API"
[ -L "$HOME/.local/bin/apitool" ]
exists "API fallback linked binary" $?
log_expect "empty web scrape is retried by Atom tier" "GET /acme/apitool/releases/expanded_assets/v3.0.0" 2
log_expect "Atom feed was tried next" "GET /acme/apitool/releases.atom" 1
log_expect "REST API called last" "GET /api/repos/acme/apitool/releases/latest" 1

# --- parallel archive downloads during sync ---------------------------------
run add gh:acme/webtool gh:acme/atomtool
check "add packages exits 0" 0 $?
curl -fsS "http://127.0.0.1:$PORT/__reset_peak" >/dev/null 2>&1 || true
run sync
check "sync exits 0" 0 $?
expect_output "sync downloads in parallel" "batch: downloading 2 asset(s) in parallel"
peak_at_least "two archives downloaded concurrently" 2

# --- verification hook: success ---------------------------------------------
run install --yes gh:acme/verifyok
check "verify success install exits 0" 0 $?
expect_output "verify command executed" "verify: test -s"
expect_output "verify success accepted" "verify: signature accepted"
[ -L "$HOME/.local/bin/verifyok" ]
exists "verified package linked" $?

# --- verification hook: failure closes the install --------------------------
run install --yes gh:acme/verifybad
check "verify failure exits nonzero" 1 $?
expect_output "verify failure reported" "verify command failed (exit 1)"
[ ! -e "$HOME/.local/bin/verifybad" ]
exists "rejected package not linked" $?

# --- TOFU: locked hash rejects changed upstream bytes -----------------------
run sync --lock
check "sync --lock exits 0" 0 $?
[ -f "$HOME/.config/klua/packages.lock.yaml" ]
exists "lockfile created" $?
grep -q 'version: "v1.0.0"' "$HOME/.config/klua/packages.lock.yaml"
exists "lockfile records resolved version" $?

# Replace the upstream archive with different bytes, then clear the download
# cache so the next locked sync downloads the tampered payload.
printf 'tampered payload\n' > "$SRV/acme/webtool/releases/download/v1.0.0/$WEBTOOL"
rm -f "$HOME/.cache/klua/downloads/$WEBTOOL"
run sync --locked
check "changed upstream payload aborts locked sync" 1 $?
expect_output "TOFU mismatch reported" "SHA-256 mismatch for $WEBTOOL"
cp "$SANDBOX/webtool.backup" "$SRV/acme/webtool/releases/download/v1.0.0/$WEBTOOL"

# --- summary -----------------------------------------------------------------
echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
