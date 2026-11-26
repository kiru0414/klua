#!/usr/bin/env bash
# v0.9.1 tests: tracked system packages, API-free release listing, custom link
# preservation and cleanup protection for active/locked versions.
#
# Usage: bash tests/test_v091.sh
#
# Fully offline: a local HTTP server supplies release pages and archives, and
# private PATH stubs observe the exact system manager commands. Nothing is
# installed on the host and no real sudo is invoked.

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
CONFIG="$SANDBOX/.config/klua"
BIN="$SANDBOX/.local/bin"
STORE="$SANDBOX/.local/share/klua/store"
LOCK="$CONFIG/packages.lock.yaml"
PORT=8136
BASE="http://127.0.0.1:$PORT"
SRV="$SANDBOX/srv"
LOG="$SRV/requests.log"
STUBS="$SANDBOX/stubs"
CMD_LOG="$SANDBOX/manager.log"
PKG_MARKER="$SANDBOX/pkg-installed"

mkdir -p "$CONFIG" "$BIN" "$SRV/api/repos/acme" "$STUBS"

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

expect_output() { # <name> <literal-pattern>
    if grep -Fq -- "$2" "$OUT"; then
        echo "ok:   $1"
        pass=$((pass + 1))
    else
        echo "FAIL: $1 (missing pattern: $2)"
        fail=$((fail + 1))
    fi
}

expect_absent() { # <name> <literal-pattern>
    if grep -Fq -- "$2" "$OUT"; then
        echo "FAIL: $1 (unexpected pattern: $2)"
        fail=$((fail + 1))
    else
        echo "ok:   $1"
        pass=$((pass + 1))
    fi
}

expect_line() { # <name> <file> <expected-line>
    local actual
    actual="$(cat "$2" 2>/dev/null || true)"
    if [ "$actual" = "$3" ]; then
        echo "ok:   $1"
        pass=$((pass + 1))
    else
        echo "FAIL: $1 (expected '$3', got '$actual')"
        fail=$((fail + 1))
    fi
}

expect_exists() { # <name> <path> <expected: yes|no>
    if [ "$3" = "yes" ]; then
        if [ -e "$2" ]; then
            echo "ok:   $1"
            pass=$((pass + 1))
        else
            echo "FAIL: $1 ($2 is missing)"
            fail=$((fail + 1))
        fi
    else
        if [ -e "$2" ]; then
            echo "FAIL: $1 ($2 unexpectedly exists)"
            fail=$((fail + 1))
        else
            echo "ok:   $1"
            pass=$((pass + 1))
        fi
    fi
}

expect_binary() { # <name> <binary-name> <expected-output>
    local actual
    actual="$("$BIN/$2" 2>&1 || true)"
    if [ "$actual" = "$3" ]; then
        echo "ok:   $1"
        pass=$((pass + 1))
    else
        echo "FAIL: $1 (expected '$3', got '$actual')"
        fail=$((fail + 1))
    fi
}

run() { "$KLUA" "$@" >"$OUT" 2>&1; }

run_sys() { PATH="$STUBS" "$KLUA" "$@" >"$OUT" 2>&1; }

log_count() {
    local count
    count="$(grep -c -- "$1" "$LOG" 2>/dev/null || true)"
    echo "${count:-0}"
}

# --- local release server ----------------------------------------------------
: > "$LOG"

cat > "$SRV/server.py" <<'PY'
import http.server
import sys

port = int(sys.argv[1])
root = sys.argv[2]
log = sys.argv[3]

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=root, **kwargs)

    def log_message(self, *args):
        pass

    def record(self):
        with open(log, "a", encoding="utf-8") as stream:
            stream.write("%s %s\n" % (self.command, self.path))

    def do_GET(self):
        self.record()
        super().do_GET()

    def do_HEAD(self):
        self.record()
        super().do_HEAD()

http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY

python3 "$SRV/server.py" "$PORT" "$SRV" "$LOG" >"$SRV/server.log" 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null; rm -rf "$SANDBOX"' EXIT

ready=0
for _ in $(seq 1 50); do
    if curl -fsS "$BASE/" >/dev/null 2>&1; then
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
make_version() { # <version>
    local version="$1"
    local work="$SANDBOX/pkg-$version"
    local asset="$SRV/acme/tool/releases/download/$version/tool-linux-x86_64.tar.gz"
    mkdir -p "$work" "$(dirname "$asset")" "$SRV/acme/tool/releases/expanded_assets"
    printf '#!/bin/sh\necho tool-%s\n' "$version" > "$work/tool"
    chmod +x "$work/tool"
    tar -czf "$asset" -C "$work" tool
    cat > "$SRV/acme/tool/releases/expanded_assets/$version" <<EOF
<a href="/acme/tool/releases/download/$version/tool-linux-x86_64.tar.gz">tool-linux-x86_64.tar.gz</a>
EOF
}

for version in v0.0.0 v1.0.0 v2.0.0 v3.0.0; do
    make_version "$version"
done

mkdir -p "$SRV/acme/atomtool" "$SRV/acme/webtool"
cat > "$SRV/acme/atomtool/releases.atom" <<'EOF'
<?xml version="1.0"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry><title>v3.0.0</title><link rel="alternate" href="http://127.0.0.1:8136/acme/atomtool/releases/tag/v3.0.0"/></entry>
  <entry><title>v2.0.0</title><link rel="alternate" href="http://127.0.0.1:8136/acme/atomtool/releases/tag/v2.0.0"/></entry>
  <entry><title>v1.0.0</title><link rel="alternate" href="http://127.0.0.1:8136/acme/atomtool/releases/tag/v1.0.0"/></entry>
</feed>
EOF

cat > "$SRV/acme/webtool/releases" <<'EOF'
<html><body>
<a href="/acme/webtool/releases/tag/v4.0.0">v4.0.0</a>
<a href="/acme/webtool/releases/tag/v3.0.0">v3.0.0</a>
</body></html>
EOF

cat > "$CONFIG/init.lua" <<EOF
klua.github_web = "$BASE"
klua.github_api = "$BASE/api"
klua.system = {
    manager = "apt",
    status = function(pkg)
        return klua.file_exists("$PKG_MARKER")
    end,
}
EOF

# --- system manager stubs ----------------------------------------------------
cat > "$STUBS/id" <<'EOF'
#!/bin/sh
echo 0
EOF

cat > "$STUBS/apt-get" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$CMD_LOG"
case "\$1" in
    install) : > "$PKG_MARKER" ;;
    remove) rm -f "$PKG_MARKER" ;;
esac
exit 0
EOF

cat > "$STUBS/brew" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$CMD_LOG"
case "\$1" in
    install) : > "$PKG_MARKER" ;;
    uninstall) rm -f "$PKG_MARKER" ;;
esac
exit 0
EOF

chmod +x "$STUBS"/*

# --- version and system tracking --------------------------------------------
run --version
check "--version exits 0" 0 $?
expect_output "version is 0.9.1" "klua 0.9.1"

: > "$CMD_LOG"
rm -f "$PKG_MARKER"
run_sys install sys:ffmpeg
check "sys:ffmpeg install exits 0" 0 $?
expect_line "apt install command" "$CMD_LOG" "install -y -- ffmpeg"
expect_exists "sys marker recorded" "$STORE/sys/apt/ffmpeg" yes

run_sys list
check "list exits 0" 0 $?
expect_output "list shows tracked system package" "sys:ffmpeg (apt)"

: > "$CMD_LOG"
run_sys remove sys:ffmpeg
check "sys:ffmpeg removal exits 0" 0 $?
expect_line "apt uninstall command" "$CMD_LOG" "remove -y -- ffmpeg"
expect_exists "sys marker removed" "$STORE/sys/apt/ffmpeg" no
run_sys list
expect_absent "list no longer shows removed package" "sys:ffmpeg"

: > "$CMD_LOG"
rm -f "$PKG_MARKER"
run_sys install brew:jq
check "brew:jq install exits 0" 0 $?
expect_line "brew install command" "$CMD_LOG" "install jq"
expect_exists "brew marker recorded" "$STORE/sys/brew/jq" yes
run_sys list
expect_output "list shows brew manager" "sys:jq (brew)"

: > "$CMD_LOG"
run_sys remove sys:jq
check "brew removal via sys exits 0" 0 $?
expect_line "brew uninstall command" "$CMD_LOG" "uninstall jq"
expect_exists "brew marker removed" "$STORE/sys/brew/jq" no

# --- API-free release discovery ---------------------------------------------
: > "$LOG"
run versions gh:acme/atomtool
check "versions via atom exits 0" 0 $?
expect_output "atom listing has v3" "v3.0.0"
expect_output "atom listing has v2" "v2.0.0"
expect_output "atom listing has v1" "v1.0.0"
if [ "$(log_count '/acme/atomtool/releases.atom')" -ge 1 ]; then
    echo "ok:   releases.atom was fetched"
    pass=$((pass + 1))
else
    echo "FAIL: releases.atom was not fetched"
    fail=$((fail + 1))
fi
if [ "$(log_count '/api/repos/')" -eq 0 ]; then
    echo "ok:   atom discovery made no API request"
    pass=$((pass + 1))
else
    echo "FAIL: atom discovery called the REST API"
    fail=$((fail + 1))
fi

: > "$LOG"
run versions gh:acme/webtool
check "versions via web page exits 0" 0 $?
expect_output "web listing has v4" "v4.0.0"
expect_output "web listing has v3" "v3.0.0"
if [ "$(log_count '/acme/webtool/releases')" -ge 1 ]; then
    echo "ok:   releases page was fetched"
    pass=$((pass + 1))
else
    echo "FAIL: releases page was not fetched"
    fail=$((fail + 1))
fi
if [ "$(log_count '/api/repos/')" -eq 0 ]; then
    echo "ok:   web discovery made no API request"
    pass=$((pass + 1))
else
    echo "FAIL: web discovery called the REST API"
    fail=$((fail + 1))
fi

# --- custom --as link names across use --------------------------------------
run install --as jq2 gh:acme/tool@v1.0.0
check "--as install exits 0" 0 $?
expect_exists "custom link name created" "$BIN/jq2" yes
if grep -Fq -- "jq2=tool" "$STORE/gh/acme/tool/v1.0.0/.klua-links"; then
    echo "ok:   snapshot stores link_name=target"
    pass=$((pass + 1))
else
    echo "FAIL: snapshot does not store link_name=target"
    fail=$((fail + 1))
fi

run install gh:acme/tool@v3.0.0
check "normal install exits 0" 0 $?
expect_binary "normal link runs" "tool" "tool-v3.0.0"

run use gh:acme/tool@v1.0.0
check "use restores custom link exits 0" 0 $?
expect_exists "custom link restored" "$BIN/jq2" yes
expect_binary "restored custom binary runs" "jq2" "tool-v1.0.0"
if [ -e "$BIN/tool" ]; then
    echo "FAIL: stale default link survived use"
    fail=$((fail + 1))
else
    echo "ok:   stale default link was cleared"
    pass=$((pass + 1))
fi

# --- cleanup protects active and pinned versions ----------------------------
run install gh:acme/tool@v0.0.0
check "v0 install exits 0" 0 $?
run install gh:acme/tool@v2.0.0
check "v2 install exits 0" 0 $?
run use gh:acme/tool@v1.0.0
check "re-activate v1 exits 0" 0 $?

cat > "$LOCK" <<'EOF'
version: 1
entries:
  "gh:acme/tool":
    provider: github
    version: v2.0.0
    asset: tool-linux-x86_64.tar.gz
    url: ""
    sha256: ""
EOF

run cleanup
check "cleanup exits 0" 0 $?
expect_output "cleanup reports protected versions" "protected version(s) kept"
expect_output "cleanup names protected version" "kept protected version"
expect_exists "active v1 kept" "$STORE/gh/acme/tool/v1.0.0" yes
expect_exists "pinned v2 kept" "$STORE/gh/acme/tool/v2.0.0" yes
expect_exists "newest v3 kept" "$STORE/gh/acme/tool/v3.0.0" yes
expect_exists "unprotected v0 removed" "$STORE/gh/acme/tool/v0.0.0" no

echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
