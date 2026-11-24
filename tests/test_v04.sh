#!/usr/bin/env bash
# v0.4.0 tests: conflict-safe linking, isolated run, and management commands.
#
# Usage: bash tests/test_v04.sh
#
# Fully offline: a local HTTP server provides the registry shards and the
# `url:` package payloads.

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

exists() { # <name> <path-test-exit>
    if [ "$2" -eq 0 ]; then
        echo "ok:   $1"
        pass=$((pass + 1))
    else
        echo "FAIL: $1"
        fail=$((fail + 1))
    fi
}

# --- local registry + package server ----------------------------------------
PORT=8127
SRV="$SANDBOX/srv"
mkdir -p "$SRV/v1" "$SRV/files" "$SANDBOX/pkgs"

# Build a package archive from a script name and optional extra files.
make_script_pkg() { # <archive> <binary> <body>
    local archive="$1" binary="$2" body="$3"
    local dir="$SANDBOX/pkgs/$binary-pkg"
    rm -rf "$dir"
    mkdir -p "$dir"
    printf '#!/bin/sh\n%s\n' "$body" > "$dir/$binary"
    chmod +x "$dir/$binary"
    tar -czf "$SRV/files/$archive" -C "$SANDBOX/pkgs" "$binary-pkg"
}

make_script_pkg git.tar.gz git 'echo git-pkg-ok'
make_script_pkg tool.tar.gz tool 'echo tool-ok'
make_script_pkg grep.tar.gz grep 'echo grep-pkg-ok'

# runner: executable + an executable shared library that must not be linked.
mkdir -p "$SANDBOX/pkgs/runner-pkg/lib"
cat > "$SANDBOX/pkgs/runner-pkg/runner" <<'EOF'
#!/bin/sh
echo "runner-ok lib=$LD_LIBRARY_PATH args=$*"
EOF
chmod +x "$SANDBOX/pkgs/runner-pkg/runner"
printf 'not-a-real-library\n' > "$SANDBOX/pkgs/runner-pkg/lib/libfoo.so"
chmod +x "$SANDBOX/pkgs/runner-pkg/lib/libfoo.so"
tar -czf "$SRV/files/runner.tar.gz" -C "$SANDBOX/pkgs" runner-pkg

# spacer: executable + executable .so at the top level.
mkdir -p "$SANDBOX/pkgs/spacer-pkg"
printf '#!/bin/sh\necho spacer-ok\n' > "$SANDBOX/pkgs/spacer-pkg/spacer"
chmod +x "$SANDBOX/pkgs/spacer-pkg/spacer"
printf 'not-a-real-library\n' > "$SANDBOX/pkgs/spacer-pkg/libz.so"
chmod +x "$SANDBOX/pkgs/spacer-pkg/libz.so"
tar -czf "$SRV/files/spacer.tar.gz" -C "$SANDBOX/pkgs" spacer-pkg

cat > "$SRV/v1/b.yaml" <<'EOF'
bzip3: gh:kspalaiologos/bzip3
EOF
cat > "$SRV/v1/g.yaml" <<EOF
git: url:http://127.0.0.1:$PORT/files/git.tar.gz
grep: url:http://127.0.0.1:$PORT/files/grep.tar.gz
EOF
cat > "$SRV/v1/t.yaml" <<EOF
tool: url:http://127.0.0.1:$PORT/files/tool.tar.gz
EOF
cat > "$SRV/v1/r.yaml" <<EOF
runner: url:http://127.0.0.1:$PORT/files/runner.tar.gz
EOF
cat > "$SRV/v1/s.yaml" <<EOF
spacer: url:http://127.0.0.1:$PORT/files/spacer.tar.gz
EOF
printf 'placeholder: gh:example/placeholder\n' > "$SRV/v1/_.yaml"

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

# A "system" binary named `tool` earlier on PATH, plus ~/.local/bin first.
FAKEBIN="$SANDBOX/fakebin"
mkdir -p "$FAKEBIN"
printf '#!/bin/sh\necho system-tool\n' > "$FAKEBIN/tool"
chmod +x "$FAKEBIN/tool"
export PATH="$HOME/.local/bin:$FAKEBIN:$PATH"

# --- version -----------------------------------------------------------------
run --version
check "--version exits 0" 0 $?
expect_output "version is 0.4.0" "klua 0.4.0"

# --- CLI typo suggestions include new commands --------------------------------
run serach tool
check "mistyped search exits 1" 1 $?
expect_output "suggests search" "did you mean 'search'"

run remov tool
check "mistyped remove exits 1" 1 $?
expect_output "suggests remove" "did you mean 'remove'"

# --- conflict protection: existing PATH binary --------------------------------
run install tool
check "install with PATH conflict still exits 0" 0 $?
expect_output "warns about existing binary" "already exists on PATH at $FAKEBIN/tool"
expect_output "package still staged in store" "installed ->"
[ ! -L "$HOME/.local/bin/tool" ]
exists "conflicting link skipped" $?

run install --force tool
check "install --force exits 0" 0 $?
expect_output "force warns about shadowing" "shadowing existing 'tool' at $FAKEBIN/tool"
[ -L "$HOME/.local/bin/tool" ]
exists "--force created the link" $?

# --- conflict protection: core system command ----------------------------------
run install git
check "protected command install exits 0" 0 $?
expect_output "refuses protected command" "refusing to link protected command 'git'"
[ ! -L "$HOME/.local/bin/git" ]
exists "protected command not linked" $?

run install --force git
check "protected command with --force exits 0" 0 $?
expect_output "force overrides protected command" "overriding protected command 'git'"
[ -L "$HOME/.local/bin/git" ]
exists "protected command linked with --force" $?

# --- shared libraries stay in the store -----------------------------------------
run install spacer
check "library-bearing package install exits 0" 0 $?
expect_output "library filtered from auto-link" "ignoring shared library 'libz.so'"
[ -L "$HOME/.local/bin/spacer" ]
exists "real binary linked" $?
[ ! -e "$HOME/.local/bin/libz.so" ] && [ ! -L "$HOME/.local/bin/libz.so" ]
exists "shared library not linked globally" $?

# --- klua run (store only, no links, isolated libraries) -------------------------
run run runner hello world
check "run installs and executes" 0 $?
expect_output "run installs without linking" "store only, no links"
expect_output "run executes the binary" "runner-ok"
expect_output "run exposes store libraries" "runner/direct/lib"
expect_output "run forwards arguments" "args=hello world"
[ ! -L "$HOME/.local/bin/runner" ]
exists "run leaves ~/.local/bin untouched" $?

run run runner --version
check "run forwards flags after target" 0 $?
expect_output "flag passed through" "args=--version"
expect_absent "flag not swallowed by klua" "klua 0.4.0"

run run runner again
check "run on installed package exits 0" 0 $?
expect_absent "no reinstall on second run" "installing 'runner'"

# --- search ---------------------------------------------------------------------
run search zip
check "search exits 0" 0 $?
expect_output "search finds bzip3" "bzip3"
expect_output "search shows target" "gh:kspalaiologos/bzip3"

run search spacer
check "search by alias exits 0" 0 $?
expect_output "search by alias" "spacer"

run search zzzznomatch
check "search with no match exits 0" 0 $?
expect_output "no-match message" "no packages matched"

# --- info -----------------------------------------------------------------------
run info tool
check "info exits 0" 0 $?
expect_output "info shows alias target" "target:   url:http://127.0.0.1:$PORT/files/tool.tar.gz"
expect_output "info shows provider" "provider: url"
expect_output "info shows installed state" "installed: direct"
expect_output "info shows linked binary" "linked:   tool"

# --- cleanup --------------------------------------------------------------------
mkdir -p "$HOME/.local/share/klua/store/gh/example/pkg/1.0.0"
mkdir -p "$HOME/.local/share/klua/store/gh/example/pkg/2.0.0"
printf 'old\n' > "$HOME/.local/share/klua/store/gh/example/pkg/1.0.0/file"
printf 'new\n' > "$HOME/.local/share/klua/store/gh/example/pkg/2.0.0/file"
ln -s "$HOME/.local/share/klua/store/gh/example/pkg/1.0.0/gone" "$HOME/.local/bin/stale-link"
ln -s "$HOME/.local/share/klua/store/url/localhost/lib/libbad.so" "$HOME/.local/bin/libbad.so"
mkdir -p "$HOME/.cache/klua/downloads"
printf 'cached\n' > "$HOME/.cache/klua/downloads/blob"

run cleanup
check "cleanup exits 0" 0 $?
expect_output "cleanup reports summary" "cleanup:"
expect_output "cleanup removed old version" "removed old version"
[ ! -d "$HOME/.local/share/klua/store/gh/example/pkg/1.0.0" ]
exists "old version removed" $?
[ -d "$HOME/.local/share/klua/store/gh/example/pkg/2.0.0" ]
exists "latest version kept" $?
[ ! -L "$HOME/.local/bin/stale-link" ]
exists "broken link removed" $?
[ ! -L "$HOME/.local/bin/libbad.so" ]
exists "library link removed" $?
[ ! -d "$HOME/.cache/klua/downloads" ]
exists "download cache cleared" $?

# --- doctor ---------------------------------------------------------------------
run doctor
check "doctor exits 0 with only warnings" 0 $?
expect_output "doctor reports version" "klua 0.4.0"
expect_output "doctor checks store" "\[ok\]   store:"
expect_output "doctor checks registry" "registry: http://127.0.0.1:$PORT"
expect_output "doctor summary" "doctor:"

# --- repair safety: backup + dry-run preview -------------------------------------
INIT="$HOME/.config/klua/init.lua"
printf 'klua.registries = {}\n-- custom rule: keep me\n' > "$INIT"

run repair --dry-run
check "repair --dry-run exits 0" 0 $?
expect_output "dry-run previews backup path" "Would back up existing $INIT to $INIT.bak."
expect_output "dry-run shows a diff" "+++ $INIT (built-in defaults)"
expect_output "dry-run shows custom Lua" "custom rule: keep me"
expect_output "dry-run reports no changes" "No files were changed"
cmp -s "$INIT" "$ROOT/builtin/default_init.lua"
if [ $? -ne 0 ]; then
    echo "ok:   dry-run left init.lua untouched"
    pass=$((pass + 1))
else
    echo "FAIL: dry-run modified init.lua"
    fail=$((fail + 1))
fi
BACKUP_COUNT=$(find "$HOME/.config/klua" -maxdepth 1 -name 'init.lua.bak.*' | wc -l)
[ "$BACKUP_COUNT" -eq 0 ]
exists "dry-run created no backup" $?

run repair --diff
check "repair --diff alias exits 0" 0 $?
expect_output "--diff also previews" "Would back up existing"

run repair
check "repair exits 0" 0 $?
expect_output "repair reports backup path" "Backed up existing $INIT to $INIT.bak."
expect_output "repair reports restore" "Restored $INIT"
cmp -s "$INIT" "$ROOT/builtin/default_init.lua"
exists "repair restored built-in baseline" $?
BACKUP=$(find "$HOME/.config/klua" -maxdepth 1 -name 'init.lua.bak.*' | head -1)
grep -q -- "custom rule: keep me" "$BACKUP"
exists "backup preserves custom Lua" $?

# --- summary --------------------------------------------------------------------
echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
