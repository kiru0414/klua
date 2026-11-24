#!/usr/bin/env bash
# Milestone 1 smoke tests for klua (core skeleton, no network access).
#
# Usage: bash tests/test_milestone1.sh
#
# Runs against ./build/klua inside a sandboxed HOME so the real user
# configuration is never touched.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KLUA="$ROOT/build/klua"

if [ ! -x "$KLUA" ]; then
    echo "error: $KLUA not found; build first (cmake --build build)" >&2
    exit 1
fi

# Sandbox: isolated HOME, no XDG overrides leaking in.
SANDBOX="$(mktemp -d)"
export HOME="$SANDBOX"
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME
trap 'rm -rf "$SANDBOX"' EXIT

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

# --- CLI basics -------------------------------------------------------------
run --version
check "--version exits 0" 0 $?
expect_output "--version prints version" "klua 0.7.0"

run --help
check "--help exits 0" 0 $?
expect_output "--help lists install" "install"
expect_output "--help lists repair" "repair"

run
check "no subcommand is an error" 1 $?

# --- repair -----------------------------------------------------------------
run repair
check "repair exits 0" 0 $?
expect_output "repair reports restore" "Restored"
[ -f "$HOME/.config/klua/init.lua" ]
check "repair created init.lua" 0 $?
cmp -s "$HOME/.config/klua/init.lua" "$ROOT/builtin/default_init.lua"
check "restored init.lua matches builtin" 0 $?

# --- commands with clean baseline (offline) ----------------------------------
run list
check "empty list exits 0" 0 $?
expect_output "empty store reported" "no packages installed"

run install bogus:thing
check "unknown scheme is an error" 1 $?
expect_output "unknown scheme reported" "no provider registered"

run i bogus:thing
check "install alias 'i' dispatches" 1 $?
expect_output "alias dispatch reaches providers" "no provider registered"

# Clear the default official registry so this suite stays fully offline.
printf 'klua.registries = {}\n' > "$HOME/.config/klua/init.lua"
run install rg
check "alias without registries is an error" 1 $?
expect_output "missing registries reported" "no registries configured"

run tap nonsense
check "invalid tap action is an error" 1 $?
expect_output "tap usage shown" "usage: klua tap"

# --- self-healing: syntax error ----------------------------------------------
printf 'this is not valid lua !!!\n' > "$HOME/.config/klua/init.lua"
run list
check "syntax error still runs command" 0 $?
expect_output "syntax error reported" "failed to load"
expect_output "fallback announced" "falling back to the built-in default logic"

# --- self-healing: runtime error ----------------------------------------------
printf 'error("boom from user init")\n' > "$HOME/.config/klua/init.lua"
run list
check "runtime error still runs command" 0 $?
expect_output "runtime error reported" "boom from user init"
expect_output "fallback announced again" "falling back"

# --- repair heals a broken init ------------------------------------------------
run repair
check "repair after breakage exits 0" 0 $?
run list
expect_output "clean baseline after repair" "no packages installed"
if grep -q "falling back" "$OUT"; then
    echo "FAIL: fallback still triggered after repair"
    fail=$((fail + 1))
else
    echo "ok:   no fallback after repair"
    pass=$((pass + 1))
fi

# --- user customization: custom provider --------------------------------------
cat > "$HOME/.config/klua/init.lua" <<'EOF'
klua.register_provider("my", function(rest, target)
    klua.info("custom provider handled " .. target .. " (rest=" .. rest .. ")")
    return 0
end)
EOF
run install my:hello
check "custom provider exits 0" 0 $?
expect_output "custom provider ran" "custom provider handled my:hello (rest=hello)"

# --- XDG overrides --------------------------------------------------------------
XDG_CONFIG_HOME="$SANDBOX/xdg-config" run repair
check "XDG repair exits 0" 0 $?
[ -f "$SANDBOX/xdg-config/klua/init.lua" ]
check "XDG_CONFIG_HOME honored" 0 $?

# --- summary ---------------------------------------------------------------------
echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
