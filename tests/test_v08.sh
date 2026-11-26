#!/usr/bin/env bash
# v0.8.0 tests: command confirmation, lock pruning, run refresh flags,
# hashed URL store paths, outdated reporting and dry-run previews.
#
# Usage: bash tests/test_v08.sh
#
# Fully offline: a local HTTP server supplies GitHub/GitLab-style release
# endpoints, manifests and archives. All stdin is closed so remote-command
# confirmation must fail unless --yes/-y is present.

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
PORT=8133
BASE="http://127.0.0.1:$PORT"
SRV="$SANDBOX/srv"
CONFIG="$SANDBOX/.config/klua"
STORE="$SANDBOX/.local/share/klua/store"
BIN="$SANDBOX/.local/bin"
LOCK="$CONFIG/packages.lock.yaml"

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

run() { "$KLUA" "$@" </dev/null >"$OUT" 2>&1; }

make_pkg() { # <asset> <pkgdir> <binary> <body>
    local asset="$1" pkgdir="$2" binary="$3" body="$4"
    local work="$SANDBOX/pkg/$pkgdir"
    rm -rf "$work"
    mkdir -p "$work"
    printf '#!/bin/sh\n%s\n' "$body" > "$work/$binary"
    chmod +x "$work/$binary"
    mkdir -p "$(dirname "$asset")"
    tar -czf "$asset" -C "$SANDBOX/pkg" "$pkgdir"
}

write_release() { # <path> <tag> <asset> <url>
    mkdir -p "$(dirname "$1")"
    printf '{"tag_name":"%s","assets":[{"name":"%s","browser_download_url":"%s"}]}\n' \
        "$2" "$3" "$4" > "$1"
}

# --- local endpoints and fixtures -------------------------------------------
mkdir -p "$SRV/v1" "$SRV/files/one" "$SRV/files/two" "$SRV/raw/acme" \
         "$SRV/api/repos/acme" "$CONFIG" "$BIN"

cat > "$SRV/server.py" <<'PY'
import http.server
import json
import sys

port = int(sys.argv[1])
root = sys.argv[2]

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=root, **kwargs)

    def log_message(self, *args):
        pass

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path.startswith("/api/projects/") and "gltool" in path:
            if path.endswith("/releases/permalink/latest"):
                tag = "v1.1.0"
            elif path.endswith("/releases/v1.0.0"):
                tag = "v1.0.0"
            else:
                self.send_response(404)
                self.end_headers()
                return
            body = json.dumps({
                "tag_name": tag,
                "assets": {"links": [{
                    "name": "gltool-" + tag + "-linux-x86_64.tar.gz",
                    "url": "http://127.0.0.1:%d/files/gltool-%s-linux-x86_64.tar.gz" % (port, tag),
                }]},
            }).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        super().do_GET()

http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY

python3 "$SRV/server.py" "$PORT" "$SRV" >"$SRV/server.log" 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null; rm -rf "$SANDBOX"' EXIT

ready=0
for _ in $(seq 1 50); do
    if curl -fsS "$BASE/v1/" >/dev/null 2>&1; then
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

make_pkg "$SRV/files/verifytool-v1.0.0-linux-x86_64.tar.gz" verifytool-pkg verifytool 'echo verifytool-ok'
write_release "$SRV/api/repos/acme/verifytool/releases/latest" v1.0.0 \
    verifytool-v1.0.0-linux-x86_64.tar.gz "$BASE/files/verifytool-v1.0.0-linux-x86_64.tar.gz"

make_pkg "$SRV/files/locktool-v1.0.0-linux-x86_64.tar.gz" locktool-pkg locktool 'echo locktool-ok'
write_release "$SRV/api/repos/acme/locktool/releases/latest" v1.0.0 \
    locktool-v1.0.0-linux-x86_64.tar.gz "$BASE/files/locktool-v1.0.0-linux-x86_64.tar.gz"

make_pkg "$SRV/files/runtool-v1.0.0-linux-x86_64.tar.gz" runtool-v1 runtool 'echo runtool-v1.0.0'
make_pkg "$SRV/files/runtool-v2.0.0-linux-x86_64.tar.gz" runtool-v2 runtool 'echo runtool-v2.0.0'
write_release "$SRV/api/repos/acme/runtool/releases/latest" v2.0.0 \
    runtool-v2.0.0-linux-x86_64.tar.gz "$BASE/files/runtool-v2.0.0-linux-x86_64.tar.gz"
write_release "$SRV/api/repos/acme/runtool/releases/tags/v1.0.0" v1.0.0 \
    runtool-v1.0.0-linux-x86_64.tar.gz "$BASE/files/runtool-v1.0.0-linux-x86_64.tar.gz"

make_pkg "$SRV/files/oldtool-v1.0.0-linux-x86_64.tar.gz" oldtool-v1 oldtool 'echo oldtool-v1.0.0'
make_pkg "$SRV/files/oldtool-v1.1.0-linux-x86_64.tar.gz" oldtool-v2 oldtool 'echo oldtool-v1.1.0'
write_release "$SRV/api/repos/acme/oldtool/releases/latest" v1.1.0 \
    oldtool-v1.1.0-linux-x86_64.tar.gz "$BASE/files/oldtool-v1.1.0-linux-x86_64.tar.gz"
write_release "$SRV/api/repos/acme/oldtool/releases/tags/v1.0.0" v1.0.0 \
    oldtool-v1.0.0-linux-x86_64.tar.gz "$BASE/files/oldtool-v1.0.0-linux-x86_64.tar.gz"

make_pkg "$SRV/files/synctool-v1.0.0-linux-x86_64.tar.gz" synctool-pkg synctool 'echo synctool-ok'
write_release "$SRV/api/repos/acme/synctool/releases/latest" v1.0.0 \
    synctool-v1.0.0-linux-x86_64.tar.gz "$BASE/files/synctool-v1.0.0-linux-x86_64.tar.gz"

make_pkg "$SRV/files/gltool-v1.0.0-linux-x86_64.tar.gz" gltool-pkg gltool 'echo gltool-v1.0.0'

make_pkg "$SRV/files/one/same.tar.gz" url-one urltool 'echo url-one'
make_pkg "$SRV/files/two/same.tar.gz" url-two urltool 'echo url-two'

# Source-build repository for build.steps confirmation.
mkdir -p "$SANDBOX/repos/acme"
git init --bare -q "$SANDBOX/repos/acme/buildtool.git"
git -C "$SANDBOX/repos/acme/buildtool.git" symbolic-ref HEAD refs/heads/main
BUILD_SRC="$SANDBOX/buildsrc"
mkdir -p "$BUILD_SRC"
git -C "$BUILD_SRC" init -q
git -C "$BUILD_SRC" config user.email test@example.com
git -C "$BUILD_SRC" config user.name Test
cat > "$BUILD_SRC/klua.yaml" <<'EOF'
bins:
  - builttool
build:
  steps:
    - sh ./build.sh
EOF
cat > "$BUILD_SRC/build.sh" <<'EOF'
#!/bin/sh
printf '#!/bin/sh\necho built-ok\n' > builttool
chmod +x builttool
EOF
git -C "$BUILD_SRC" add klua.yaml build.sh
git -C "$BUILD_SRC" commit -q -m init
git -C "$BUILD_SRC" branch -M main
git -C "$BUILD_SRC" push -q "$SANDBOX/repos/acme/buildtool.git" main

mkdir -p "$SRV/raw/acme/buildtool/HEAD" "$SRV/raw/acme/verifytool/HEAD" \
         "$SRV/raw/acme/oldtool/v1.1.0"
cp "$BUILD_SRC/klua.yaml" "$SRV/raw/acme/buildtool/HEAD/klua.yaml"
cat > "$SRV/raw/acme/verifytool/HEAD/klua.yaml" <<'EOF'
verify:
  - test -s {payload}
EOF
cat > "$SRV/raw/acme/oldtool/v1.1.0/klua.yaml" <<'EOF'
depends:
  - sys:drypkg
EOF

cat > "$CONFIG/init.lua" <<EOF
klua.registries = { "$BASE" }
klua.github_web = "$BASE"
klua.github_api = "$BASE/api"
klua.raw_github = "$BASE/raw"
klua.gitlab_api = "$BASE/api"
klua.raw_gitlab = "$BASE/raw"
klua.github_clone = "$SANDBOX/repos"
klua.system = {
    manager = "apt",
    status = function(pkg) return false end,
    install_cmd = "echo SYS-INSTALL %s",
}
EOF
export PATH="$BIN:$PATH"

# --- CLI surface -------------------------------------------------------------
run --version
check "--version exits 0" 0 $?
expect_output "version is 0.9.1" "klua 0.9.1"

run install --help
expect_output "install help lists --yes" "--yes"

run run --help
expect_output "run help lists --upgrade" "--upgrade"
expect_output "run help lists --latest" "--latest"

run sync --help
expect_output "sync help lists --dry-run" "--dry-run"

run upgrade --help
expect_output "upgrade help lists --dry-run" "--dry-run"

run outdated --help
check "outdated help exits 0" 0 $?
expect_output "outdated help describes releases" "newer releases"

# --- remote build.steps confirmation ----------------------------------------
run install gh:acme/buildtool
check "build.steps denied without confirmation" 1 $?
expect_output "build steps are announced" "remote klua.yaml wants to execute build.steps"
expect_output "build refusal explains --yes" "refusing remote build.steps without confirmation"
[ ! -e "$BIN/builttool" ] && [ ! -L "$BIN/builttool" ]
exists "no link after denied build" $?

run install --yes gh:acme/buildtool
check "build.steps allowed with --yes" 0 $?
expect_output "build step executed after approval" "build: sh ./build.sh"
[ -L "$BIN/builttool" ]
exists "built binary linked" $?
"$BIN/builttool" >"$OUT" 2>&1
check "built binary runs" 0 $?
expect_output "built binary output" "built-ok"

# --- remote verification confirmation ---------------------------------------
run install gh:acme/verifytool
check "verify command denied without confirmation" 1 $?
expect_output "verify refusal explains --yes" "refusing remote verify command(s) without confirmation"
[ ! -L "$BIN/verifytool" ]
exists "no link after denied verification" $?

run install -y gh:acme/verifytool
check "verify command allowed with -y" 0 $?
expect_output "verify command executed after approval" "verify: test -s"
expect_output "verification accepted" "verify: signature accepted"
[ -L "$BIN/verifytool" ]
exists "verified binary linked" $?

run remove gh:acme/buildtool gh:acme/verifytool
check "confirmed packages removed" 0 $?

# --- lockfile pruning on remove ---------------------------------------------
run install --lock gh:acme/locktool
check "lock install exits 0" 0 $?
[ -f "$LOCK" ]
exists "lockfile created" $?
grep -q 'gh:acme/locktool' "$LOCK"
exists "lock entry recorded" $?

run remove gh:acme/locktool
check "locked package removed" 0 $?
expect_output "lock pruning reported" "lockfile pruned: 1 entry/entries removed"
[ -f "$LOCK" ]
exists "lockfile kept after pruning" $?
if grep -q 'gh:acme/locktool' "$LOCK"; then
    echo "FAIL: stale lock entry after remove"
    fail=$((fail + 1))
else
    echo "ok:   stale lock entry pruned"
    pass=$((pass + 1))
fi

# --- run --upgrade / --latest ------------------------------------------------
run install gh:acme/runtool@v1.0.0
check "pinned runtool install exits 0" 0 $?
"$BIN/runtool" >"$OUT" 2>&1
expect_output "pinned version installed" "runtool-v1.0.0"

run run --upgrade gh:acme/runtool@v1.0.0
check "run --upgrade exits 0" 0 $?
expect_output "run --upgrade checks latest" "run: checking latest release for 'gh:acme/runtool'"
expect_output "run --upgrade executes latest" "runtool-v2.0.0"
[ -d "$STORE/gh/acme/runtool/v2.0.0" ]
exists "latest version staged in store" $?

run run --latest gh:acme/runtool
check "run --latest exits 0" 0 $?
expect_output "run --latest checks latest" "run: checking latest release for 'gh:acme/runtool'"
expect_output "run --latest executes latest" "runtool-v2.0.0"

# --- hashed URL store paths --------------------------------------------------
URL_A="$BASE/files/one/same.tar.gz"
URL_B="$BASE/files/two/same.tar.gz"
HASH_A="$(printf '%s' "$URL_A" | sha256sum | cut -c1-12)"
HASH_B="$(printf '%s' "$URL_B" | sha256sum | cut -c1-12)"
STORE_A="$STORE/url/127.0.0.1:$PORT/same-$HASH_A/direct"
STORE_B="$STORE/url/127.0.0.1:$PORT/same-$HASH_B/direct"

run install "url:$URL_A"
check "first same-name URL install exits 0" 0 $?
run install "url:$URL_B"
check "second same-name URL install exits 0" 0 $?
[ -d "$STORE_A" ]
exists "first hashed store path exists" $?
[ -d "$STORE_B" ]
exists "second hashed store path exists" $?
[ "$STORE_A" != "$STORE_B" ]
exists "URL hashes do not collide" $?
[ -f "$STORE_A/urltool" ] && [ -f "$STORE_B/urltool" ]
exists "both payloads stored intact" $?

run info "url:$URL_A"
expect_output "info reports first hashed path" "$STORE_A"
run info "url:$URL_B"
expect_output "info reports second hashed path" "$STORE_B"

run remove "url:$URL_A"
check "first URL package removed" 0 $?
[ ! -d "$STORE_A" ]
exists "first hashed path removed" $?
[ -d "$STORE_B" ]
exists "second hashed path untouched" $?
run remove "url:$URL_B"
check "second URL package removed" 0 $?

# --- outdated ----------------------------------------------------------------
run install gh:acme/oldtool@v1.0.0
check "old gh package installed" 0 $?
run install gl:acme/gltool@v1.0.0
check "old gl package installed" 0 $?

run outdated
check "outdated exits 0" 0 $?
expect_output "outdated reports gh release" "outdated: gh:acme/oldtool v1.0.0 -> v1.1.0"
expect_output "outdated reports gl release" "outdated: gl:acme/gltool v1.0.0 -> v1.1.0"
expect_output "outdated summary" "outdated: 2 package(s) can be upgraded"
expect_absent "current package not listed as outdated" "outdated: gh:acme/runtool "

run outdated gh:acme/runtool
check "explicit outdated exits 0" 0 $?
expect_output "explicit up-to-date message" "outdated: all checked packages are up to date"

# --- dry-run sync ------------------------------------------------------------
rm -f "$LOCK"
cat > "$CONFIG/packages.yaml" <<EOF
packages:
  - sys:syncpkg
  - gh:acme/synctool
EOF

run sync --dry-run --lock
check "dry-run with --lock rejected" 1 $?
expect_output "dry-run lock conflict explained" "--dry-run cannot be combined with --lock"

run sync --dry-run
check "sync --dry-run exits 0" 0 $?
expect_output "sync preview announced" "dry-run: would sync 2 package(s)"
expect_output "sync sys command previewed" "dry-run: would run: echo SYS-INSTALL 'syncpkg'"
expect_output "sync preview summary" "sync preview complete: 2 package(s); no changes made"
expect_absent "sync dry-run did not install" "installed ->"
[ ! -d "$STORE/gh/acme/synctool" ]
exists "sync dry-run left store untouched" $?
[ ! -f "$LOCK" ]
exists "sync dry-run left lockfile untouched" $?

# --- dry-run upgrade ---------------------------------------------------------
run upgrade --dry-run gh:acme/oldtool
check "upgrade --dry-run exits 0" 0 $?
expect_output "upgrade preview shows version" "dry-run: would change gh:acme/oldtool: v1.0.0 -> v1.1.0"
expect_output "upgrade sys command previewed" "dry-run: would run: echo SYS-INSTALL 'drypkg'"
expect_absent "upgrade dry-run did not install" "upgraded gh:acme/oldtool"
[ ! -d "$STORE/gh/acme/oldtool/v1.1.0" ]
exists "upgrade dry-run left store untouched" $?
[ ! -f "$LOCK" ]
exists "upgrade dry-run left lockfile untouched" $?

# --- summary -----------------------------------------------------------------
echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
