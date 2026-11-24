#!/usr/bin/env bash
# Milestone 3 end-to-end tests for klua.
#
# Usage: bash tests/test_milestone3.sh
#
# Phase A (network): add, sync (default/includes/cycles/URL), upgrade.
# Phase B (local):   klua.yaml manifests (assets/bins/configs), build.steps
#                    from a local git repo, init-manifest.

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

run() { "$KLUA" "$@" >"$OUT" 2>&1; }

# --- local HTTP server (sync URL source + phase B endpoints) ------------------
PORT=8124
SRV="$SANDBOX/srv"
mkdir -p "$SRV/raw/testuser/testrepo/HEAD" \
         "$SRV/raw/testuser/buildrepo/HEAD" \
         "$SRV/api/repos/testuser/testrepo/releases" \
         "$SRV/files" "$SRV/sync"

# Fake release tarball with a single top-level directory.
mkdir -p "$SANDBOX/pkg/tool-v1.0.0"
printf '#!/bin/sh\necho tool-ok\n' > "$SANDBOX/pkg/tool-v1.0.0/tool"
chmod +x "$SANDBOX/pkg/tool-v1.0.0/tool"
printf 'setting = true\n' > "$SANDBOX/pkg/tool-v1.0.0/config.toml"
tar -czf "$SRV/files/tool-linux-x86_64.tar.gz" -C "$SANDBOX/pkg" tool-v1.0.0

cat > "$SRV/api/repos/testuser/testrepo/releases/latest" <<EOF
{"tag_name":"v1.0.0","assets":[{"name":"tool-linux-x86_64.tar.gz","browser_download_url":"http://127.0.0.1:$PORT/files/tool-linux-x86_64.tar.gz"}]}
EOF

cat > "$SRV/raw/testuser/testrepo/HEAD/klua.yaml" <<'EOF'
assets:
  - "tool-linux-*.tar.gz"
bins:
  - tool
configs:
  - src: config.toml
    dest: ~/.config/tool/config.toml
EOF

# Local bare git repo for the build.steps test.
mkdir -p "$SANDBOX/repos/testuser"
git init --bare -q "$SANDBOX/repos/testuser/buildrepo.git"
git -C "$SANDBOX/repos/testuser/buildrepo.git" symbolic-ref HEAD refs/heads/main
WORK="$SANDBOX/work"
mkdir -p "$WORK"
git -C "$WORK" init -q
git -C "$WORK" config user.email test@example.com
git -C "$WORK" config user.name Test
cat > "$WORK/klua.yaml" <<'EOF'
bins:
  - built-tool
build:
  steps:
    - sh ./build.sh
EOF
cat > "$WORK/build.sh" <<'EOF'
#!/bin/sh
printf '#!/bin/sh\necho built-ok\n' > built-tool
chmod +x built-tool
EOF
git -C "$WORK" add klua.yaml build.sh
git -C "$WORK" commit -q -m "init"
git -C "$WORK" branch -M main
git -C "$WORK" push -q "$SANDBOX/repos/testuser/buildrepo.git" main
cp "$WORK/klua.yaml" "$SRV/raw/testuser/buildrepo/HEAD/klua.yaml"

# Sync sources with includes, duplicates and a cycle.
cat > "$SRV/sync/a.yaml" <<'EOF'
includes:
  - b.yaml
packages:
  - gh:jqlang/jq
  - gh:jqlang/jq
EOF
cat > "$SRV/sync/b.yaml" <<'EOF'
includes:
  - a.yaml
packages:
  - gh:sharkdp/fd
EOF
cp "$SRV/sync/a.yaml" "$SANDBOX/sync-a.yaml"
cp "$SRV/sync/b.yaml" "$SANDBOX/sync-b.yaml"
mkdir -p "$SANDBOX/syncdir"
cp "$SRV/sync/a.yaml" "$SANDBOX/syncdir/a.yaml"
cp "$SRV/sync/b.yaml" "$SANDBOX/syncdir/b.yaml"

python3 -m http.server "$PORT" --directory "$SRV" --bind 127.0.0.1 >/dev/null 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null; rm -rf "$SANDBOX"' EXIT

ready=0
for _ in $(seq 1 50); do
    if curl -fsS "http://127.0.0.1:$PORT/sync/a.yaml" >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 0.1
done
if [ "$ready" -ne 1 ]; then
    echo "error: local server did not start" >&2
    exit 1
fi

# --- init-manifest -------------------------------------------------------------
cd "$SANDBOX"
run init-manifest
check "init-manifest exits 0" 0 $?
[ -f "$SANDBOX/klua.yaml" ]
check "starter klua.yaml created" 0 $?
expect_output "creation reported" "created"

run init-manifest
check "init-manifest refuses overwrite" 1 $?
expect_output "overwrite hint shown" "--force"

run init-manifest --force
check "init-manifest --force exits 0" 0 $?
cd "$ROOT"

# --- add (packages.yaml, deduplication) ------------------------------------------
run add gh:jqlang/jq gh:sharkdp/fd
check "add exits 0" 0 $?
[ -f "$HOME/.config/klua/packages.yaml" ]
check "packages.yaml created" 0 $?
expect_output "packages.yaml written" "packages.yaml updated"

run add gh:sharkdp/fd
check "duplicate add exits 0" 0 $?
count="$(grep -c '"gh:sharkdp/fd"' "$HOME/.config/klua/packages.yaml")"
check "add deduplicates" 1 "$count"

# --- upgrade a pinned install ------------------------------------------------------
run install gh:jqlang/jq@jq-1.7.1
check "pinned jq install exits 0" 0 $?

run upgrade gh:jqlang/jq
check "upgrade target exits 0" 0 $?
expect_output "upgrade reports version change" "upgraded gh:jqlang/jq: jq-1.7.1 -> jq-"

# --- sync: default source -----------------------------------------------------------
run sync
check "sync default exits 0" 0 $?
expect_output "sync deduplicated count" "syncing 2 package(s)"
expect_output "sync complete" "sync complete: 2 package(s)"
[ -L "$HOME/.local/bin/jq" ]
check "sync installed jq" 0 $?
[ -L "$HOME/.local/bin/fd" ]
check "sync installed fd" 0 $?

# --- sync: explicit local path with includes + cycle ----------------------------------
run sync "$SANDBOX/syncdir/a.yaml"
check "sync local includes exits 0" 0 $?
expect_output "includes merged and deduped" "syncing 2 package(s)"

# --- sync: URL source --------------------------------------------------------------------
run sync "http://127.0.0.1:$PORT/sync/a.yaml"
check "sync URL exits 0" 0 $?
expect_output "URL includes resolved" "syncing 2 package(s)"

# --- upgrade all ---------------------------------------------------------------------------
run upgrade
check "upgrade all exits 0" 0 $?
expect_output "upgrade all reports status" "up to date"

# --- phase B: manifest + source build via local endpoints ------------------------------------
cat > "$HOME/.config/klua/init.lua" <<EOF
klua.registries = {}
klua.github_api = "http://127.0.0.1:$PORT/api"
klua.raw_github = "http://127.0.0.1:$PORT/raw"
klua.github_clone = "$SANDBOX/repos"
EOF

run install gh:testuser/testrepo
check "manifest install exits 0" 0 $?
expect_output "manifest asset pattern matched" "tool-linux-x86_64.tar.gz"
[ -L "$HOME/.local/bin/tool" ]
check "manifest bin linked" 0 $?
"$HOME/.local/bin/tool" >"$OUT" 2>&1
check "manifest bin runs" 0 $?
expect_output "manifest bin output" "tool-ok"
[ -f "$HOME/.config/tool/config.toml" ]
check "manifest config installed" 0 $?
[ -f "$HOME/.local/share/klua/store/gh/testuser/testrepo/v1.0.0/tool" ]
check "manifest store layout" 0 $?

run install --yes gh:testuser/buildrepo
check "build.steps install exits 0" 0 $?
expect_output "build step executed" "build: sh ./build.sh"
[ -L "$HOME/.local/bin/built-tool" ]
check "built binary linked" 0 $?
"$HOME/.local/bin/built-tool" >"$OUT" 2>&1
check "built binary runs" 0 $?
expect_output "built binary output" "built-ok"
[ -f "$HOME/.local/share/klua/store/gh/testuser/buildrepo/source/built-tool" ]
check "source build stored under 'source' version" 0 $?

# --- list shows everything -------------------------------------------------------------------
run list
check "list exits 0" 0 $?
expect_output "list shows manifest package" "gh:testuser/testrepo"
expect_output "list shows built package" "gh:testuser/buildrepo"

# --- summary -----------------------------------------------------------------------------------
echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
