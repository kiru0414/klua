# Lua API Reference

Everything customizable in klua lives in `~/.config/klua/init.lua`. The
embedded baseline (`builtin/default_init.lua`, baked into the binary) runs
first and defines the default providers and command handlers; your file
runs on top in a protected call and can override anything. If it errors,
klua falls back to the baseline — see
[getting-started.md](getting-started.md#self-healing-behavior).

Available Lua libraries: `base`, `string`, `table`, `math`, `os`,
`coroutine`, `utf8`. There is no `io` or `package` — use the native file
primitives below.

> **Safer than Homebrew, simpler than Nix, and infinitely hackable in Lua.**
> The C++ core enforces the isolated store, keeps shared libraries out of
> `~/.local/bin` and checks PATH conflicts before linking; Lua is where you
> redefine policy. A bad `init.lua` never bricks klua because the embedded
> baseline reloads automatically, and `repair` backs up your custom code.

## Design philosophy in Lua

- Every package version is unpacked under `klua.paths.store`; only chosen
  executable symlinks belong in `klua.paths.bin`.
- Library names are filtered by the baseline's `safe_link` helper. Use
  `klua.install_opts.link = false` for store-only installs and expose
  libraries only to `klua run`.
- The baseline scans `klua.env("PATH")` before linking and protects core
  commands. `--force` and `--as NAME` are surfaced as `install_opts.force`
  and `install_opts.as` for CLI-driven installs.
- Rebind `klua.commands.run`, `klua.commands.search`, `klua.commands.info`,
  `klua.commands.cleanup`, `klua.commands.doctor` or `klua.commands.remove`
  just like any other handler — no rebuild required.
- `gh:` resolution is API-free by default and verified checksums gate
  extraction; both policies live in the baseline Lua and can be replaced.

## Globals

| Name | Type | Meaning |
| ---- | ---- | ------- |
| `klua.version` | string | klua version, e.g. `"0.6.0"` |
| `klua.paths` | table | `config`, `store`, `bin`, `cache`, `shards`, `init`, `packages`, `lock`, `taps` (absolute path strings) |
| `klua.providers` | table | scheme -> `function(rest, target)` |
| `klua.commands` | table | command name -> `function(args)` returning an exit code |
| `klua.install_opts` | table | install-time flags: `force` (override link guards), `link` (`false` = store-only install), `as` (primary link name from `--as`) |
| `klua.registries` | array | registry base URLs for alias sharding (defaults to the official registry) |
| `klua.shard_ttl` | number | registry shard cache lifetime in seconds (default `3600`); `0` disables reuse |
| `klua.cli_flags` | table | `no_cache`, `skip_checksum`, `locked`, `lock`, published from CLI switches before dispatch |
| `klua.system` | table | system package delegation overrides: `manager`, `status`, `install` |
| `klua.lockfile` | table | parsed `packages.lock.yaml` state (`entries`, `loaded`) and lock helpers |

### Service endpoint overrides

Set these in `init.lua` for mirrors, GitHub Enterprise, or testing:

```lua
klua.github_api   = "https://api.github.com"          -- Releases API base
klua.gitlab_api   = "https://gitlab.com/api/v4"       -- Releases API base
klua.raw_github   = "https://raw.githubusercontent.com"  -- klua.yaml fetch base
klua.raw_gitlab   = "https://gitlab.com"                 -- klua.yaml fetch base
klua.github_web   = "https://github.com"              -- web release redirect/assets
klua.github_clone = "https://github.com"              -- git clone base (build.steps)
klua.gitlab_clone = "https://gitlab.com"              -- git clone base (build.steps)
```

`GITHUB_TOKEN` / `GH_TOKEN` are added as `Authorization: Bearer` headers when
the REST fallback talks to `api.github.com`. Set `KLUA_GITHUB_API_HOST` to a
trusted custom hostname to enable the same header for API paths on that host
(raw files and downloads never receive it).

`GITLAB_TOKEN` is sent as `PRIVATE-TOKEN` and `Authorization: Bearer` on
GitLab API requests. Set `KLUA_GITLAB_API_HOST` for a self-hosted instance.
Custom hosts only receive tokens on API-looking paths (`/api/...` or
`/repos/...`), never on manifest, raw-file or asset-download requests.

## Logging

```lua
klua.info("message")    -- stdout, plain
klua.warn("message")    -- stderr, "warning: " prefix
klua.error("message")   -- stderr, "error: " prefix
```

## Filesystem primitives

| Function | Returns | Notes |
| -------- | ------- | ----- |
| `klua.file_exists(path)` | bool | |
| `klua.is_dir(path)` | bool | true for directories (follows symlinks) |
| `klua.is_executable(path)` | bool | true for regular files with any exec bit (used for PATH scans) |
| `klua.read_file(path)` | string or nil | whole file, binary-safe |
| `klua.write_file(path, content)` | ok, err | creates parent dirs, truncates |
| `klua.mkdir(path)` | bool | recursive |
| `klua.copy(src, dest)` | ok, err | byte-for-byte, creates parent dirs, overwrites |
| `klua.remove(path)` | ok, err | recursive; missing path is a no-op |
| `klua.list_dir(path)` | array | entries `{name=, path=, is_dir=}`, sorted; empty when missing |
| `klua.find_executables(dir)` | array | recursive; ELF/Mach-O magic or any exec bit; skips `.sha256 .sha256sum .sig .asc .md .txt .json .yaml .yml .pem .pub .html`; sorted |
| `klua.symlink(target, link)` | ok, err | POSIX symlink; replaces existing entries incl. dangling links; creates parent dirs |
| `klua.readlink(path)` | string or nil | raw symlink target (no resolution); nil when not a symlink |
| `klua.chmod_exec(path)` | ok, err | adds `u+x,g+x,o+x` |
| `klua.cwd()` | string | process working directory |
| `klua.env(name)` | string or nil | environment variable |

"ok, err" means `true, nil` on success and `false, "message"` on failure.

## Process execution

```lua
local code = klua.exec("git clone --depth 1 https://... /tmp/x")
```

Runs the string through the system shell (`/bin/sh -c`); returns the
normalized exit code (0 = success). Quote untrusted values yourself
(single-quote wrapping with `'\\''` escaping, as the baseline does).

## HTTP

```lua
local body, status, err = klua.http_get("https://api.github.com/...")
-- err ~= nil  -> transport failure (status 0, body "")
-- err == nil  -> status is the HTTP code; body is the response text

local location, status, err = klua.http_head_redirect(
    "https://github.com/user/repo/releases/latest")
-- HEAD without following redirects; Location may be "" on 200/404

local ok, err = klua.download("https://host/tool.tar.gz", "/path/dest")
```

- HTTPS via OpenSSL; `http_get` and `download` follow redirects across hosts.
- `http_head_redirect` does **not** follow redirects and returns the raw
  `Location` header, used by the baseline for API-free tag discovery.
- Sends `User-Agent: klua/<version>`. Requests to `api.github.com` also send
  `Authorization: Bearer <token>` when `GITHUB_TOKEN` or `GH_TOKEN` is set.
  GitLab API requests send `PRIVATE-TOKEN` and Bearer auth when
  `GITLAB_TOKEN` is set.
- `download` streams to disk, creates parent dirs, accepts only HTTP 200,
  and removes partial files on failure.
- Transient failures (`403`, `429`, `5xx`, dropped connections — common with
  GitHub's release-asset CDN) are retried up to 4 times with exponential
  backoff.
- Timeouts: 30 s connect, 300 s read, 120 s write.

## SHA-256

```lua
local digest, err = klua.sha256("/path/to/archive.tar.gz")
-- digest: lowercase 64-character hex on success; "" plus err on failure
```

Implemented with OpenSSL `EVP_Digest`. The baseline calls it on the
downloaded payload before extraction when the release contains
`<asset>.sha256`, `<asset>.sha256sum` or `checksums.txt`. It accepts
`<hash>  <filename>`, `<hash> *<filename>`, BSD-style
`SHA256(<filename>) = <hash>`, and bare digests in asset-specific sidecars.
A mismatch produces `SHA-256 mismatch for <asset>` and an exit code of `1`
before any store files are written. `klua.cli_flags.skip_checksum` (from
`--skip-checksum`) bypasses verification with a warning. A locked install
instead verifies the digest recorded in `packages.lock.yaml` and ignores
release checksum sidecars; see [Lockfile](#lockfile).

## System package delegation

The baseline implements `sys:` and the manager-specific schemes
(`apt:`, `apt-get:`, `dnf:`, `yum:`, `pacman:`, `apk:`, `brew:`) by queueing
packages for a single install batch. Status is checked before queuing, and
duplicate names are removed. The default manager is detected from the tools
available at runtime:

| Manager | Status probe | Install command |
| ------- | ------------ | --------------- |
| `apt` | `dpkg-query -W -f='${Status}' <pkg>` | `apt-get install -y -- <pkgs>` |
| `dnf` / `yum` | `rpm -q <pkg>` | `dnf install -y <pkgs>` / `yum install -y <pkgs>` |
| `pacman` | `pacman -Q <pkg>` | `pacman -S --noconfirm -- <pkgs>` |
| `apk` | `apk info -e <pkg>` | `apk add <pkgs>` |
| `brew` | `brew list <pkg>` | `brew install <pkgs>` |

All commands go through the shell with single-quote escaping, and `sudo` is
prepended once for the whole batch when the process is not root (never for
`brew`). Customize in `init.lua`:

```lua
-- Option 1: choose a known manager (or any name when both hooks are supplied).
klua.system = {
    manager = "apt",
    status_cmd = "dpkg-query -W -f='${Status}' %s 2>/dev/null | grep -qx 'install ok installed'",
    install_cmd = "apt-get install -y -- %s",
}

-- Option 2: full hooks. `install` receives the whole missing batch as an array.
klua.system = {
    manager = "nix",
    status = function(pkg)
        return klua.exec("nix profile list | grep -q " .. pkg) == 0
    end,
    install = function(pkgs)
        return klua.exec("nix profile install nixpkgs#" .. table.concat(pkgs, " nixpkgs#"))
    end,
}
```

`status(pkg)` returns true (or numeric `0`) when installed; `install(pkgs)`
returns `0`/true on success. Both hooks are optional, but a custom
`manager` string without a known implementation needs both. Manifest
`depends:` entries without a scheme, or with a system scheme, use this same
batch; other targets are dispatched through their normal provider.

## Lockfile

`packages.lock.yaml` is read from `klua.paths.lock` (normally
`~/.config/klua/packages.lock.yaml`). Keys are canonical scheme targets:
tags are stripped from `gh:` / `gl:` targets so `gh:user/repo@v1` and
`gh:user/repo` share one entry. Each entry has `provider`, `version`,
`asset`, `url` and a lowercase 64-character `sha256`.

`--lock` records these values after a successful resolution; `--locked`
requires them and skips fresh release discovery. The baseline exposes:

```lua
klua.lockfile.require()                         -- bool; --locked needs a lockfile
local entry = klua.lockfile.get(target, provider) -- nil, true on a locked-target error
klua.lockfile.record(target, provider, version, asset, url, sha256) -- only with --lock
local code = klua.lockfile.verify(payload, asset, entry, "my:provider")
klua.lockfile.save()                            -- writes the file only with --lock
```

Custom providers that want lock support should call `get()` before network
access, use `entry.url` / `entry.version` when present, call `verify()` after
download, and call `record()` with the resolved metadata when `--lock` is set.
The built-in `gh:`, `gl:` and `url:` providers already do this. `--locked` is
mutually exclusive with `--lock` and `--skip-checksum`; `sys:` and custom
non-release schemes are not locked.

## Registry shard cache

`resolve_alias` and `klua.commands.search` share a local cache under
`klua.paths.shards`. Each URL is hashed to a stable filename; a sibling `.ts`
file stores the fetch time. Entries younger than `klua.shard_ttl` (default
3600 seconds) are reused without a network request. `--no-cache` sets
`klua.cli_flags.no_cache = true` and forces a refetch; if the refetch fails,
a stale entry is reused with a warning. Returned bodies are always parsed
with `klua.yaml_parse`.

## Archives

```lua
local ok, err = klua.extract("/cache/tool.tar.gz", "/store/tool/1.0")
klua.is_archive("tool.tar.gz")   -- true
```

Supported: `.tar.gz`/`.tgz`, `.tar.xz`/`.txz`, `.tar.bz2`, `.tar` (system
`tar`), `.zip` (system `unzip`). Extraction is intact; a single top-level
wrapper directory is stripped automatically.

## Parsing

```lua
local value, err = klua.json_parse(text)   -- GitHub/GitLab API responses
local value, err = klua.yaml_parse(text)   -- shards, taps, manifests
```

JSON objects / YAML mappings become tables; arrays / sequences become
1-based tables; scalars map to string/number/boolean/nil. On parse
failure: `nil, "message"`.

## Platform

```lua
local p = klua.platform()   -- { os = "linux"|"macos", arch = "x86_64"|"arm64" }
```

Compile-time identification, used for asset scoring.

## Providers

```lua
klua.register_provider("scheme", function(rest, target)
    -- rest:   everything after "scheme:"
    -- target: the full original target string
    return 0   -- exit code; non-number returns count as 0
end)
```

Scheme must be non-empty and contain no `:`. Registration overwrites any
previous handler for the scheme — that is how you replace the built-in
`gh`/`gl`/`url`/`apt` providers. Errors thrown inside a provider are
caught and reported; the install fails with exit 1.

## Command handlers

The CLI dispatches `klua.commands.<name>(args)` where `args` is an array
of positional strings. Names: `install`, `run`, `search`, `info`, `cleanup`,
`doctor`, `add`, `remove`, `sync`, `upgrade`, `tap`, `list`, `init-manifest`
(note the dash: `klua.commands["init-manifest"]`). `run` receives the target
plus all pass-through arguments. CLI-wide switches (`--no-cache`,
`--skip-checksum`, `--lock`, `--locked`) are consumed by CLI11 and exposed as
`klua.cli_flags`; they are not passed in `args`. Return a process exit code.
Override or wrap freely:

```lua
local default_list = klua.commands.list
klua.commands.list = function(args)
    klua.info("== installed packages ==")
    return default_list(args)
end
```

## Conflict-safe linking & run isolation

The baseline routes every link through a local `safe_link` helper (in
`builtin/default_init.lua`). It checks, in order:

1. `klua.install_opts.link == false` → skip linking entirely (store-only).
2. `klua.install_opts.as` → rename the first linked binary to that command
   name (from the CLI's `--as NAME`); extra binaries keep their own names.
3. Library-looking names (`.so`, `.so.*`, `.dylib`, `.a`, `.la`, `.dll`) →
   warn and leave the file inside the store.
4. Existing non-klua links/files at the destination → warn and skip unless
   `klua.install_opts.force` is set.
5. Protected core command names (shells, coreutils, network tools, language
   runtimes, compilers, system package managers, editors and `klua`) → warn
   and skip unless forced.
6. A same-named executable elsewhere on `PATH` → warn and skip unless forced.

A skipped link still counts as success: the package is staged in the store.
Links that already point into the store are replaced, so upgrades work. The
CLI sets these options per invocation:

```lua
-- klua install --force ...
klua.install_opts = { force = true, link = true }

-- klua install --as jq2 jq ...
klua.install_opts = { force = false, link = true, as = "jq2" }

-- klua run ... (install missing package store-only)
klua.install_opts = { force = false, link = false }
```

The CLI validates `--as` before dispatch: it must be a single non-empty name,
cannot contain `/`, `.`, `..` or control characters, and can only be combined
with one install target. The chosen name then goes through exactly the same
library, occupancy, protected-command and PATH guards described above.

`klua run` executes the chosen binary through the shell with store `bin`
directories prepended to `PATH` and store library directories prepended to
`LD_LIBRARY_PATH` / `DYLD_LIBRARY_PATH`; it uses `klua.is_dir` to discover
library directories up to two levels deep and `shq()`-style single-quote
escaping for every argument. Custom providers that create links themselves
should respect `klua.install_opts.link` and perform equivalent conflict
checks using `klua.readlink`, `klua.is_executable` and `klua.env("PATH")`.

## Self-healing and `klua repair`

The embedded baseline is loaded before your `init.lua`; a syntax/runtime error
in your file is reported and the baseline is reloaded automatically. `repair`
is implemented natively so it works even when Lua is broken:

- `klua repair` copies the current file to
  `~/.config/klua/init.lua.bak.<timestamp>`, prints that path, then writes the
  embedded baseline. If the file already matches, nothing is written.
- `klua repair --dry-run` (alias `--diff`) prints the backup path and a
  unified diff of the pending change and touches no files.

Typo suggestions are Levenshtein-based for the new command names (`run`,
`search`, `info`, `cleanup`, `doctor`, `remove`/`rm`/`uninstall`) and flags
(`--force`, `--as`, `--no-cache`, `--skip-checksum`, `--dry-run`, `--diff`).

## Recipes

### Custom provider for an internal scheme

```lua
klua.register_provider("corp", function(rest)
    local url = "https://artifacts.corp.example/tools/" .. rest .. ".tar.gz"
    local payload = klua.paths.cache .. "/downloads/" .. rest .. ".tar.gz"
    local ok, err = klua.download(url, payload)
    if not ok then klua.error(tostring(err)); return 1 end
    local store = klua.paths.store .. "/corp/tools/" .. rest .. "/latest"
    ok, err = klua.extract(payload, store)
    if not ok then klua.error(tostring(err)); return 1 end
    for _, bin in ipairs(klua.find_executables(store)) do
        klua.chmod_exec(bin)
        -- In production, guard this with the conflict checks described above
        -- and respect klua.install_opts.link / .force.
        klua.symlink(bin, klua.paths.bin .. "/" .. bin:match("([^/]+)$"))
    end
    return 0
end)
-- klua install corp:mytool
```

### GitHub token fallback

The native HTTP client already adds `Authorization: Bearer <token>` for
`api.github.com` when `GITHUB_TOKEN` (preferred) or `GH_TOKEN` is set, so no
monkey-patching is needed for private REST fallbacks. Since normal installs
resolve through GitHub's web endpoints, the token is only used when that
discovery path fails.

For a custom host, set both the endpoint override and
`KLUA_GITHUB_API_HOST` in the environment:

```sh
export GH_TOKEN=ghp_...
export KLUA_GITHUB_API_HOST=github.corp.example
```

If a different auth scheme is required, wrap `klua.http_get` as before — but
remember that web discovery uses `klua.http_head_redirect`, so wrap that too
if the token must be present on the redirect request.

### Custom source build without a manifest

```lua
klua.register_provider("src", function(rest)
    local dir = klua.paths.cache .. "/build/" .. rest:gsub("/", "-")
    klua.remove(dir)
    if klua.exec("git clone --depth 1 https://github.com/" .. rest .. " '" .. dir .. "'") ~= 0 then
        klua.error("clone failed"); return 1
    end
    if klua.exec("cd '" .. dir .. "' && make -j4") ~= 0 then
        klua.error("build failed"); return 1
    end
    local bins = klua.find_executables(dir .. "/bin")
    if #bins == 0 then bins = klua.find_executables(dir) end
    for _, bin in ipairs(bins) do
        klua.chmod_exec(bin)
        klua.symlink(bin, klua.paths.bin .. "/" .. bin:match("([^/]+)$"))
    end
    return 0
end)
-- klua install src:user/repo
```

For repo-owned builds prefer [`klua.yaml` `build.steps`](klua-yaml.md) —
no user config needed.

### GitHub Enterprise / mirrors

```lua
klua.github_api   = "https://github.corp.example/api/v3"
klua.github_web   = "https://github.corp.example"  -- releases/latest + expanded_assets
klua.raw_github   = "https://github.corp.example/raw"
klua.github_clone = "https://github.corp.example"
```

### Extra registries without taps

```lua
klua.registries[#klua.registries + 1] = "https://corp.example/klua-registry"
```

Taps (`klua tap add`) are consulted before `klua.registries`; see
[taps-and-registry.md](taps-and-registry.md).
