#!/usr/bin/env bash
# v0.6.0 tests: batched system delegation, CI token headers and lockfiles.
#
# Usage: bash tests/test_v06.sh
#
# Fully offline: a local HTTP server supplies GitHub/GitLab-style endpoints,
# registry shards, manifests, archives and checksum files.

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
PORT=8131
SRV="$SANDBOX/srv"
LOG="$SRV/requests.log"
INSTALLED="$SANDBOX/installed.txt"
INSTALL_LOG="$SANDBOX/install.log"

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

run() { "$KLUA" "$@" >"$OUT" 2>&1; }

# --- local GitHub/GitLab-like server ----------------------------------------
mkdir -p "$SRV/v1" "$SRV/files" "$SRV/acme/widget/releases" "$SRV/raw"
: > "$LOG"

cat > "$SRV/server.py" <<'PY'
import http.server
import json
import os
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
        path = self.path.split("?", 1)[0]
        auth = self.headers.get("Authorization", "")
        token = self.headers.get("PRIVATE-TOKEN", "")
        with open(log, "a", encoding="utf-8") as stream:
            stream.write("%s %s auth=%s token=%s\n" % (self.command, path, auth, token))

    def redirect(self, target):
        self.send_response(302)
        self.send_header("Location", "http://127.0.0.1:%d%s" % (port, target))
        self.end_headers()

    def locked_mode(self):
        return os.path.exists(os.path.join(root, "LOCKED_MODE"))

    def do_HEAD(self):
        self.record()
        path = self.path.split("?", 1)[0]
        if path == "/acme/widget/releases/latest":
            if self.locked_mode():
                self.send_response(500)
                self.end_headers()
            else:
                self.redirect("/acme/widget/releases/tag/v1.2.3")
            return
        super().do_HEAD()

    def do_GET(self):
        self.record()
        path = self.path.split("?", 1)[0]
        if path == "/acme/widget/releases/latest":
            if self.locked_mode():
                self.send_response(500)
                self.end_headers()
            else:
                self.redirect("/acme/widget/releases/tag/v1.2.3")
            return
        if path.startswith("/api/projects/"):
            if self.locked_mode():
                self.send_response(500)
                self.end_headers()
                return
            body = json.dumps({
                "tag_name": "v0.9.0",
                "assets": {"links": [{
                    "name": "gltool-linux-x86_64.tar.gz",
                    "url": "http://127.0.0.1:%d/files/gltool-linux-x86_64.tar.gz" % port,
                }]},
            }).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.locked_mode() and path.startswith("/acme/widget/releases/expanded_assets/"):
            self.send_response(404)
            self.end_headers()
            return
        super().do_GET()

http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY

python3 "$SRV/server.py" "$PORT" "$SRV" "$LOG" >"$SRV/server.log" 2>&1 &
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
}

WIDGET="widget-linux-x86_64.tar.gz"
GLTOOL="gltool-linux-x86_64.tar.gz"
WIDGET_PATH="$SRV/acme/widget/releases/download/v1.2.3/$WIDGET"

make_pkg "$WIDGET_PATH" widget 'echo widget-ok'
make_pkg "$SRV/files/$GLTOOL" gltool 'echo gltool-ok'

WIDGET_HASH="$(sha256sum "$WIDGET_PATH" | cut -d' ' -f1)"
printf '%s  %s\n' "$WIDGET_HASH" "$WIDGET" > "$WIDGET_PATH.sha256"

mkdir -p "$SRV/acme/widget/releases/expanded_assets"
cat > "$SRV/acme/widget/releases/expanded_assets/v1.2.3" <<EOF
<a href="/acme/widget/releases/download/v1.2.3/$WIDGET">$WIDGET</a>
<a href="/acme/widget/releases/download/v1.2.3/$WIDGET.sha256">$WIDGET.sha256</a>
EOF

mkdir -p "$SRV/acme/widget/v1.2.3"
cat > "$SRV/acme/widget/v1.2.3/klua.yaml" <<'EOF'
depends:
  - sys:git
  - curl
  - wget
EOF

printf 'widget: gh:acme/widget\n' > "$SRV/v1/w.yaml"
printf 'other: gh:acme/other\n' > "$SRV/v1/o.yaml"

mkdir -p "$SANDBOX/.config/klua" "$SANDBOX/.local/bin"
cat > "$SANDBOX/.config/klua/init.lua" <<EOF
klua.registries = { "http://127.0.0.1:$PORT" }
klua.github_web = "http://127.0.0.1:$PORT"
klua.github_api = "http://127.0.0.1:$PORT/api"
klua.raw_github = "http://127.0.0.1:$PORT"
klua.gitlab_api = "http://127.0.0.1:$PORT/api"
klua.raw_gitlab = "http://127.0.0.1:$PORT/raw"

local installed_file = "$INSTALLED"
local install_log = "$INSTALL_LOG"
klua.system = {
    manager = "test-manager",
    status = function(pkg)
        local text = klua.read_file(installed_file) or ""
        for line in string.gmatch(text, "[^\\r\\n]+") do
            if line == pkg then return true end
        end
        return false
    end,
    install = function(pkgs)
        local previous = klua.read_file(install_log) or ""
        klua.write_file(install_log, previous .. table.concat(pkgs, " ") .. "\\n")
        local current = klua.read_file(installed_file) or ""
        for _, pkg in ipairs(pkgs) do
            current = current .. pkg .. "\\n"
        end
        klua.write_file(installed_file, current)
        return 0
    end,
}
EOF
printf 'git\n' > "$INSTALLED"
: > "$INSTALL_LOG"
export PATH="$HOME/.local/bin:$PATH"

# --- version and CLI surface -------------------------------------------------
run --version
check "--version exits 0" 0 $?
expect_output "version is 0.7.0" "klua 0.7.0"

run install --help
expect_output "install help lists --locked" "--locked"
expect_output "install help lists --lock" "--lock"

run sync --help
expect_output "sync help lists --lock" "--lock"

run install --locked --lock gh:acme/widget
check "--locked and --lock conflict" 1 $?
expect_output "mutual exclusion reported" "mutually exclusive"

run install --locked --skip-checksum gh:acme/widget
check "--locked and --skip-checksum conflict" 1 $?
expect_output "checksum bypass rejected with --locked" "cannot be combined"

run install --lockd gh:acme/widget
check "--lockd typo exits nonzero" 1 $?
expect_output "typo suggests --locked" "did you mean '--locked'?"

# --- lockfile is required by --locked ----------------------------------------
run sync --locked
check "sync --locked without lockfile fails" 1 $?
expect_output "missing lockfile reported" "no .*packages.lock.yaml found"

# --- sys: idempotence and batching -------------------------------------------
run install sys:git,curl,wget,vim
check "sys batch install exits 0" 0 $?
expect_output "batch count reported" "installing 3 missing package(s)"
expect_output "installed package reported" "sys: installed 3 package(s)"
expect_absent "already-installed git not reinstalled" "installing 1 missing package"
[ "$(wc -l < "$INSTALL_LOG")" -eq 1 ]
exists "exactly one system install command" $?
[ "$(cat "$INSTALL_LOG")" = "curl wget vim" ]
exists "single command contains all missing packages" $?

printf 'curl\nwget\nvim\n' >> "$INSTALLED"
: > "$INSTALL_LOG"
run install sys:git,curl
check "second sys install exits 0" 0 $?
expect_output "already-installed package reported" "already installed"
[ ! -s "$INSTALL_LOG" ]
exists "no system install command on idempotent run" $?

# --- manifest depends: uses the same batch ----------------------------------
printf 'git\n' > "$INSTALLED"
: > "$INSTALL_LOG"
: > "$LOG"
run install gh:acme/widget
check "gh install with depends exits 0" 0 $?
expect_output "web release still resolved" "from web release"
expect_output "widget installed" "installed ->"
[ "$(cat "$INSTALL_LOG")" = "curl wget" ]
exists "depends batched into one command" $?
[ "$(wc -l < "$INSTALL_LOG")" -eq 1 ]
exists "depends produced exactly one install command" $?
log_expect "depends install still uses web resolution" "GET /acme/widget/releases/expanded_assets/v1.2.3" 1

printf 'curl\nwget\n' >> "$INSTALLED"
: > "$INSTALL_LOG"
[ -L "$HOME/.local/bin/widget" ]
exists "widget binary linked by dependency-aware install" $?

# --- GitLab token headers ----------------------------------------------------
: > "$LOG"
GITLAB_TOKEN=gl-token-456 KLUA_GITLAB_API_HOST=127.0.0.1 \
    run install gl:acme/gltool
check "GitLab install exits 0" 0 $?
expect_output "GitLab asset installed" "$GLTOOL"
log_expect "GitLab API called once" "GET /api/projects/acme%2Fgltool/releases/permalink/latest" 1
log_expect "GITLAB_TOKEN sent as PRIVATE-TOKEN" "token=gl-token-456" 1
log_expect "GITLAB_TOKEN also sent as Bearer" "auth=Bearer gl-token-456" 1
log_expect "asset download has no token" "GET /files/$GLTOOL auth= token=" 1

# --- lockfile generation via sync --lock -------------------------------------
run add widget
check "add widget exits 0" 0 $?
[ -f "$HOME/.config/klua/packages.yaml" ]
exists "packages.yaml created" $?

: > "$INSTALL_LOG"
run sync --lock
check "sync --lock exits 0" 0 $?
expect_output "lockfile write reported" "lockfile updated"
expect_output "lock still resolves through web" "from web release"
[ -f "$HOME/.config/klua/packages.lock.yaml" ]
exists "packages.lock.yaml created" $?
grep -q 'version: "v1.2.3"' "$HOME/.config/klua/packages.lock.yaml"
exists "lockfile records resolved version" $?
grep -q "url: \"http://127.0.0.1:$PORT/acme/widget/releases/download/v1.2.3/$WIDGET\"" \
    "$HOME/.config/klua/packages.lock.yaml"
exists "lockfile records asset URL" $?
grep -q "sha256: \"$WIDGET_HASH\"" "$HOME/.config/klua/packages.lock.yaml"
exists "lockfile records SHA-256" $?
[ ! -s "$INSTALL_LOG" ]
exists "no repeated system install during sync --lock" $?

cp "$HOME/.config/klua/packages.lock.yaml" "$SANDBOX/lock.backup"

# --- strict reproduction: no discovery, direct download ---------------------
: > "$LOG"
touch "$SRV/LOCKED_MODE"
run sync --locked
check "sync --locked exits 0" 0 $?
expect_output "lock entry announced" "using lockfile entry"
expect_output "lock hash verified" "sha256 verified for $WIDGET (lockfile)"
log_expect "no latest-tag HEAD in locked mode" "HEAD /acme/widget/releases/latest" 0
log_expect "no expanded_assets in locked mode" "GET /acme/widget/releases/expanded_assets/" 0
log_expect "no REST API in locked mode" "GET /api/" 0
log_expect "locked install downloads recorded URL" "GET /acme/widget/releases/download/v1.2.3/$WIDGET" 1

# --- lock hash is enforced ---------------------------------------------------
sed -i 's/sha256: "[0-9a-f]\{64\}"/sha256: "0000000000000000000000000000000000000000000000000000000000000000"/' \
    "$HOME/.config/klua/packages.lock.yaml"
run sync --locked
check "tampered lock hash fails" 1 $?
expect_output "lock mismatch reported" "SHA-256 mismatch for $WIDGET"
cp "$SANDBOX/lock.backup" "$HOME/.config/klua/packages.lock.yaml"

# --- missing lock entry is rejected -----------------------------------------
run add other
check "add other exits 0" 0 $?
run sync --locked
check "missing lock entry fails" 1 $?
expect_output "missing entry reported" "no lock entry for 'gh:acme/other'"

# --- install --locked works for direct scheme targets -----------------------
: > "$LOG"
run install --locked gh:acme/widget
check "install --locked exits 0" 0 $?
expect_output "direct target uses lock" "using lockfile entry"
log_expect "direct locked install skips discovery" "HEAD /acme/widget/releases/latest" 0

echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
