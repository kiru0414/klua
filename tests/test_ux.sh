#!/usr/bin/env bash
# UX polish tests: package removal, CLI typo suggestions, alias suggestions.
#
# Usage: bash tests/test_ux.sh
#
# Fully offline: uses a local HTTP server as the alias registry and as the
# `url:` package source.

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

run() { "$KLUA" "$@" >"$OUT" 2>&1; }

# --- local registry + package server ----------------------------------------
PORT=8125
SRV="$SANDBOX/srv"
mkdir -p "$SRV/v1" "$SRV/files"

cat > "$SRV/v1/b.yaml" <<'EOF'
bzip3: gh:kspalaiologos/bzip3
EOF

cat > "$SRV/v1/t.yaml" <<EOF
tool: url:http://127.0.0.1:$PORT/files/tool
EOF

printf '#!/bin/sh\necho tool-ok\n' > "$SRV/files/tool"
chmod +x "$SRV/files/tool"

python3 -m http.server "$PORT" --directory "$SRV" --bind 127.0.0.1 >/dev/null 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null; rm -rf "$SANDBOX"' EXIT

ready=0
for _ in $(seq 1 50); do
    if curl -fsS "http://127.0.0.1:$PORT/v1/t.yaml" >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 0.1
done
if [ "$ready" -ne 1 ]; then
    echo "error: local server did not start" >&2
    exit 1
fi

mkdir -p "$SANDBOX/.config/klua"
printf 'klua.registries = { "http://127.0.0.1:%s" }\n' "$PORT" \
    > "$SANDBOX/.config/klua/init.lua"

TOOL_URL="http://127.0.0.1:$PORT/files/tool"
TOOL_HASH="$(printf '%s' "$TOOL_URL" | sha256sum | cut -c1-12)"
STORE_TOOL="$SANDBOX/.local/share/klua/store/url/127.0.0.1:$PORT/tool-$TOOL_HASH/direct"
PACKAGES="$SANDBOX/.config/klua/packages.yaml"

# --- CLI typo suggestions ---------------------------------------------------
run instll
check "unknown command exits 1" 1 $?
expect_output "suggests install" "did you mean 'install'"

run --helo
check "unknown option exits 1" 1 $?
expect_output "suggests --help" "did you mean '--help'"

run install --forc
check "unknown flag exits 1" 1 $?
expect_output "suggests --force" "did you mean '--force'"

run --version
check "valid --version still exits 0" 0 $?
expect_absent "no typo warning for valid version" "did you mean"

run list
check "valid command still exits 0" 0 $?
expect_absent "no typo warning for valid command" "did you mean"

# --- alias typo suggestions ----------------------------------------------------
run i bzp3
check "bad alias exits 1" 1 $?
expect_output "suggests bzip3" "did you mean 'bzip3'"
expect_output "alias miss still reported" "not found in any configured registry"

run i toolz
check "bad alias 'toolz' exits 1" 1 $?
expect_output "suggests tool" "did you mean 'tool'"

# --- remove: happy path (install -> add -> remove) ------------------------------
run install tool
check "install tool exits 0" 0 $?
[ -L "$SANDBOX/.local/bin/tool" ]
check "tool symlink created" 0 $?
[ -d "$STORE_TOOL" ]
check "tool store directory created" 0 $?

run add tool
check "add tool exits 0" 0 $?
expect_output "add reports update" "packages.yaml updated"
grep -qF '"tool"' "$PACKAGES"
check "packages.yaml records tool" 0 $?

run remove tool
check "remove tool exits 0" 0 $?
expect_output "removal reported" "removed url:"
[ ! -e "$SANDBOX/.local/bin/tool" ] && [ ! -L "$SANDBOX/.local/bin/tool" ]
check "tool symlink removed" 0 $?
[ ! -e "$STORE_TOOL" ]
check "tool store directory removed" 0 $?
grep -qF '"tool"' "$PACKAGES"
if [ $? -eq 0 ]; then
    echo "FAIL: packages.yaml still lists tool"
    fail=$((fail + 1))
else
    echo "ok:   packages.yaml entry pruned"
    pass=$((pass + 1))
fi

# --- remove: rm and uninstall aliases -------------------------------------------
run install tool
run rm tool
check "rm alias removes" 0 $?
[ ! -L "$SANDBOX/.local/bin/tool" ]
check "rm removed symlink" 0 $?

run install tool
run uninstall tool
check "uninstall alias removes" 0 $?
[ ! -L "$SANDBOX/.local/bin/tool" ]
check "uninstall removed symlink" 0 $?

# --- remove: explicit scheme target ---------------------------------------------
run install "url:$TOOL_URL"
check "install explicit url exits 0" 0 $?
run remove "url:$TOOL_URL"
check "remove explicit url exits 0" 0 $?
[ ! -d "$STORE_TOOL" ]
check "explicit url store removed" 0 $?

# --- remove: missing package -------------------------------------------------------
run remove gh:nobody/nope
check "remove missing exits 1" 1 $?
expect_output "missing package reported" "not installed"

# --- summary -------------------------------------------------------------------------
echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
