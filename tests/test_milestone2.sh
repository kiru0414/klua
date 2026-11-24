#!/usr/bin/env bash
# Milestone 2 end-to-end tests for klua.
#
# Usage: bash tests/test_milestone2.sh
#
# Covers: tap management, alias sharding against a local registry,
# gh: installs (raw binary + archive), store layout, symlinks, list.
# Requires network access to api.github.com and python3 + curl.

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
    if grep -q "$2" "$OUT"; then
        echo "ok:   $1"
        pass=$((pass + 1))
    else
        echo "FAIL: $1 (missing pattern: $2)"
        fail=$((fail + 1))
    fi
}

run() { "$KLUA" "$@" >"$OUT" 2>&1; }

# --- local registry for alias sharding ---------------------------------------
PORT=8123
REGISTRY="$SANDBOX/registry"
mkdir -p "$REGISTRY/v1"
cat > "$REGISTRY/v1/f.yaml" <<'EOF'
fd: gh:sharkdp/fd
fake: bogus:x
EOF
cat > "$REGISTRY/v1/j.yaml" <<'EOF'
jq: gh:jqlang/jq
EOF

python3 -m http.server "$PORT" --directory "$REGISTRY" --bind 127.0.0.1 >/dev/null 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null; rm -rf "$SANDBOX"' EXIT

ready=0
for _ in $(seq 1 50); do
    if curl -fsS "http://127.0.0.1:$PORT/v1/f.yaml" >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 0.1
done
if [ "$ready" -ne 1 ]; then
    echo "error: local registry did not start" >&2
    exit 1
fi

# --- tap management -----------------------------------------------------------
run tap add "http://127.0.0.1:$PORT"
check "tap add exits 0" 0 $?

run tap add "http://127.0.0.1:$PORT/"
check "tap add (trailing slash) exits 0" 0 $?

run tap list
check "tap list exits 0" 0 $?
expect_output "tap listed" "127.0.0.1:$PORT"
count="$(grep -c "127.0.0.1" "$OUT")"
check "taps deduplicated" 1 "$count"

# --- alias sharding -----------------------------------------------------------
run install fake
check "alias resolves then dispatches" 1 $?
expect_output "alias resolved via v1/f.yaml" "resolved 'fake' -> bogus:x"
expect_output "resolved target dispatched" "no provider registered"

run install nosuchtool
check "unknown alias is an error" 1 $?
expect_output "alias miss reported" "not found in any configured registry"

# --- gh: raw binary install (jq) ----------------------------------------------
run install --force gh:jqlang/jq
check "install --force gh:jqlang/jq exits 0" 0 $?
expect_output "asset selected" "jq-linux"

[ -L "$HOME/.local/bin/jq" ]
check "jq symlink created" 0 $?

"$HOME/.local/bin/jq" --version >"$OUT" 2>&1
check "installed jq runs" 0 $?
expect_output "jq reports version" "jq-"

store_jq="$(ls "$HOME/.local/share/klua/store/gh/jqlang/jq" 2>/dev/null | head -1)"
[ -n "$store_jq" ]
check "jq stored under store/gh/jqlang/jq/<version>" 0 $?

# --- alias install with archive extraction (fd) --------------------------------
run install fd
check "install fd via alias exits 0" 0 $?
expect_output "fd alias resolved" "resolved 'fd' -> gh:sharkdp/fd"
expect_output "fd archive selected" "linux"

[ -L "$HOME/.local/bin/fd" ]
check "fd symlink created" 0 $?

"$HOME/.local/bin/fd" --version >"$OUT" 2>&1
check "installed fd runs" 0 $?
expect_output "fd reports version" "fd "

[ -f "$HOME/.local/share/klua/store/gh/sharkdp/fd"/*/fd ]
check "fd binary extracted intact into store" 0 $?

# --- list ----------------------------------------------------------------------
run list
check "list exits 0" 0 $?
expect_output "list shows jq" "gh:jqlang/jq"
expect_output "list shows fd" "gh:sharkdp/fd"

# --- reinstall idempotency -------------------------------------------------------
run i gh:jqlang/jq
check "reinstall via 'i' exits 0" 0 $?
"$HOME/.local/bin/jq" --version >"$OUT" 2>&1
check "jq still runs after reinstall" 0 $?

# --- pinned tag --------------------------------------------------------------------
run install --force gh:jqlang/jq@jq-1.7.1
check "pinned tag install exits 0" 0 $?
[ -d "$HOME/.local/share/klua/store/gh/jqlang/jq/jq-1.7.1" ]
check "pinned version stored separately" 0 $?

# --- tap remove ----------------------------------------------------------------------
run tap remove "http://127.0.0.1:$PORT"
check "tap remove exits 0" 0 $?
run tap list
expect_output "taps empty after remove" "no taps configured"

# --- summary -------------------------------------------------------------------------
echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
