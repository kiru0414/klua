#!/usr/bin/env bash
# Regression tests for system package manager elevation in builtin/default_init.lua.
#
# Usage: bash tests/test_system_sudo.sh
#
# Fully offline: stub `id`, `sudo` and the package managers on a private PATH,
# so the tests can observe the exact command klua builds for root/non-root
# users without touching the host's package database.

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
STUBS="$SANDBOX/stubs"
SUDO_LOG="$SANDBOX/sudo.log"
CMD_LOG="$SANDBOX/manager.log"
MARKER="$SANDBOX/installed"

mkdir -p "$CONFIG"

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

make_stubs() { # <uid> <with-sudo: yes|no>
    local uid="$1" with_sudo="$2" manager
    rm -rf "$STUBS"
    mkdir -p "$STUBS"

    # `id -u` always exits 0; only its output distinguishes root from a
    # regular user. The stub reproduces both cases faithfully.
    cat > "$STUBS/id" <<EOF
#!/bin/sh
echo $uid
EOF

    for manager in apt-get dnf yum pacman apk brew; do
        cat > "$STUBS/$manager" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$CMD_LOG"
: > "$MARKER"
exit 0
EOF
    done

    if [ "$with_sudo" = "yes" ]; then
        cat > "$STUBS/sudo" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$SUDO_LOG"
exec "\$@"
EOF
    fi
    chmod +x "$STUBS"/*
}

write_init() { # <manager>
    cat > "$CONFIG/init.lua" <<EOF
klua.system = {
    manager = "$1",
    status = function(pkg)
        return klua.file_exists("$MARKER")
    end,
}
EOF
}

run_case() { # <name> <uid> <with-sudo> <manager> <target> <manager-args> [sudo-command]
    local name="$1" uid="$2" with_sudo="$3" manager="$4" target="$5" manager_args="$6"
    local sudo_command="${7:-}"
    : > "$SUDO_LOG"
    : > "$CMD_LOG"
    rm -f "$MARKER"
    make_stubs "$uid" "$with_sudo"
    write_init "$manager"

    # A private PATH keeps the host's real sudo/apt-get out of the test.
    PATH="$STUBS" "$KLUA" install "$target" </dev/null >"$OUT" 2>&1
    check "$name: install exits 0" 0 $?
    expect_line "$name: manager command" "$CMD_LOG" "$manager_args"
    if [ -n "$sudo_command" ]; then
        expect_line "$name: invoked through sudo" "$SUDO_LOG" "$sudo_command"
    else
        expect_line "$name: no sudo invocation" "$SUDO_LOG" ""
    fi
}

trap 'rm -rf "$SANDBOX"' EXIT

# --- non-root Linux managers -------------------------------------------------
run_case "non-root apt" 1000 yes apt sys:busybox \
    "install -y -- busybox" "apt-get install -y -- busybox"
expect_output "non-root apt: command is shown with sudo" "sys: sudo apt-get install -y -- 'busybox'"

run_case "non-root apt-get scheme" 1000 yes apt-get "apt-get:curl" \
    "install -y -- curl" "apt-get install -y -- curl"

run_case "non-root dnf" 1000 yes dnf sys:htop \
    "install -y htop" "dnf install -y htop"

run_case "non-root yum" 1000 yes yum sys:htop \
    "install -y htop" "yum install -y htop"

run_case "non-root pacman" 1000 yes pacman sys:htop \
    "-S --noconfirm -- htop" "pacman -S --noconfirm -- htop"

run_case "non-root apk" 1000 yes apk sys:htop \
    "add htop" "apk add htop"

# --- root, missing sudo, and Homebrew ---------------------------------------
run_case "root apt" 0 yes apt sys:busybox \
    "install -y -- busybox"
expect_absent "root apt: sudo not shown in output" "sys: sudo "

run_case "non-root without sudo" 1000 no apt sys:busybox \
    "install -y -- busybox"
expect_output "non-root without sudo: warning emitted" "sudo is unavailable"
expect_absent "non-root without sudo: command has no sudo" "sys: sudo "

run_case "non-root brew" 1000 yes brew brew:jq \
    "install jq"
expect_absent "non-root brew: command has no sudo" "sys: sudo "

echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
