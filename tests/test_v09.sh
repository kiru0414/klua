#!/usr/bin/env bash
# v0.9.0 tests: clean dry-run previews, @VERSION pinning, release listing,
# interactive selection, offline relinking (`use`) and version-specific `remove`.
#
# Usage: bash tests/test_v09.sh
#
# Fully offline: a local HTTP server supplies a GitHub-style release list,
# expanded asset pages, registry shards and archives. Nothing is installed on
# the host and no real package manager or sudo is invoked.

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
LOCK="$SANDBOX/.config/klua/packages.lock.yaml"
PORT=8135
BASE="http://127.0.0.1:$PORT"
SRV="$SANDBOX/srv"
LOG="$SRV/requests.log"

mkdir -p "$CONFIG" "$BIN" "$SRV/v1" "$SRV/api/repos/acme/tool"

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

symlink_target() { readlink "$BIN/tool" 2>/dev/null || true; }

expect_binary() { # <name> <expected-output>
    local actual
    actual="$("$BIN/tool" 2>&1 || true)"
    if [ "$actual" = "$2" ]; then
        echo "ok:   $1"
        pass=$((pass + 1))
    else
        echo "FAIL: $1 (expected '$2', got '$actual')"
        fail=$((fail + 1))
    fi
}

run() { "$KLUA" "$@" >"$OUT" 2>&1; }

run_input() { # <input> <args...>
    local input="$1"
    shift
    printf '%s\n' "$input" | "$KLUA" "$@" >"$OUT" 2>&1
}

request_count() { wc -l < "$LOG" 2>/dev/null || echo 0; }

# --- local GitHub-like server ------------------------------------------------
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
    mkdir -p "$work" "$(dirname "$asset")" \
        "$SRV/acme/tool/releases/expanded_assets"
    printf '#!/bin/sh\necho tool-%s\n' "$version" > "$work/tool"
    chmod +x "$work/tool"
    tar -czf "$asset" -C "$work" tool
    cat > "$SRV/acme/tool/releases/expanded_assets/$version" <<EOF
<a href="/acme/tool/releases/download/$version/tool-linux-x86_64.tar.gz">tool-linux-x86_64.tar.gz</a>
EOF
}

for version in v1.0.0 v2.0.0 v3.0.0; do
    make_version "$version"
done

cat > "$SRV/api/repos/acme/tool/releases" <<'EOF'
[
  {"tag_name": "v3.0.0", "name": "3.0"},
  {"tag_name": "v2.0.0", "name": "2.0"},
  {"tag_name": "v1.0.0", "name": "1.0"}
]
EOF

cat > "$SRV/v1/t.yaml" <<'EOF'
aliases:
  tool: gh:acme/tool
EOF

cat > "$CONFIG/init.lua" <<EOF
klua.registries = { "$BASE" }
klua.github_web = "$BASE"
klua.github_api = "$BASE/api"
klua.raw_github = "$BASE/raw"
EOF

# --- CLI surface and version -------------------------------------------------
run --version
check "--version exits 0" 0 $?
expect_output "version is 0.9.0" "klua 0.9.0"

run install --help
expect_output "install help lists --dry-run" "--dry-run"
expect_output "install help lists --select" "--select"

run versions --help
check "versions --help exits 0" 0 $?

run use --help
check "use --help exits 0" 0 $?

# --- release listing ---------------------------------------------------------
run versions tool
check "versions exits 0" 0 $?
expect_output "versions lists newest release" "v3.0.0"
expect_output "versions lists middle release" "v2.0.0"
expect_output "versions lists oldest release" "v1.0.0"
expect_output "versions shows resolved target" "gh:acme/tool"

# --- dry run must not write anything ----------------------------------------
run install --dry-run tool@v1.0.0
check "install --dry-run exits 0" 0 $?
expect_output "dry-run announces a preview" "dry-run: install preview"
expect_output "dry-run shows resolved target" "resolved 'tool@v1.0.0' -> gh:acme/tool@v1.0.0"
expect_output "dry-run shows the version" "acme/tool v1.0.0"
expect_output "dry-run shows the planned install" "would install"
expect_output "dry-run confirms no writes" "preview complete; store, links and lockfile were not changed"
expect_exists "dry-run left no store directory" "$STORE/gh/acme/tool" no
expect_exists "dry-run left no symlink" "$BIN/tool" no
expect_exists "dry-run left no lockfile" "$LOCK" no

# --- pinned installs ---------------------------------------------------------
run install tool@v1.0.0
check "alias @version install exits 0" 0 $?
expect_binary "installed binary is v1.0.0" "tool-v1.0.0"
case "$(symlink_target)" in
    */gh/acme/tool/v1.0.0/*) echo "ok:   symlink points at v1.0.0"; pass=$((pass + 1)) ;;
    *) echo "FAIL: symlink does not point at v1.0.0 ($(symlink_target))"; fail=$((fail + 1)) ;;
esac

run versions tool
expect_output "versions marks installed version" "v1.0.0  [installed, active]"

run install tool@v2.0.0
check "second pinned install exits 0" 0 $?
expect_binary "installed binary is v2.0.0" "tool-v2.0.0"
expect_exists "v1.0.0 is still in the store" "$STORE/gh/acme/tool/v1.0.0" yes

# --- interactive selection ---------------------------------------------------
run_input "3" install --select tool
check "install --select exits 0" 0 $?
expect_output "select lists a numbered menu" "1) v3.0.0"
expect_output "select shows the prompt" "select a version number"
expect_binary "select installed the chosen version" "tool-v1.0.0"

run_input "not-a-number" install --select tool
check "invalid selection fails" 1 $?
expect_output "invalid selection is reported" "invalid selection"

# --- offline switching -------------------------------------------------------
before="$(request_count)"
run use gh:acme/tool@v2.0.0
check "use exits 0" 0 $?
expect_output "use reports the switch" "switched gh:acme/tool -> v2.0.0"
expect_binary "use relinked v2.0.0" "tool-v2.0.0"
after="$(request_count)"
if [ "$before" -eq "$after" ]; then
    echo "ok:   use made no HTTP requests (offline)"
    pass=$((pass + 1))
else
    echo "FAIL: use made HTTP requests ($before -> $after)"
    fail=$((fail + 1))
fi

run use gh:acme/tool@v9.9.9
check "use with missing version fails" 1 $?
expect_output "missing version is reported" "is not installed"

# --- version-specific removal with fallback ---------------------------------
run remove gh:acme/tool@v2.0.0
check "remove @version exits 0" 0 $?
expect_output "remove names the version" "removed gh:acme/tool@v2.0.0"
expect_output "remove falls back automatically" "fallback to v1.0.0"
expect_exists "removed version directory is gone" "$STORE/gh/acme/tool/v2.0.0" no
expect_exists "remaining version is intact" "$STORE/gh/acme/tool/v1.0.0" yes
expect_binary "fallback binary runs" "tool-v1.0.0"

# --- removing the last version ----------------------------------------------
run remove gh:acme/tool@v1.0.0
check "remove last version exits 0" 0 $?
expect_output "last removal reports no versions" "no versions remain"
expect_exists "no version directories remain" "$STORE/gh/acme/tool/v1.0.0" no
expect_exists "final symlink is gone" "$BIN/tool" no

run remove gh:acme/tool@v1.0.0
check "removing an absent version fails" 1 $?
expect_output "absent version is reported" "is not installed"

echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
