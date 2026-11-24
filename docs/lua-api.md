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

## Globals

| Name | Type | Meaning |
| ---- | ---- | ------- |
| `klua.version` | string | klua version, e.g. `"0.4.0"` |
| `klua.paths` | table | `config`, `store`, `bin`, `cache`, `init`, `packages`, `taps` (absolute path strings) |
| `klua.providers` | table | scheme -> `function(rest, target)` |
| `klua.commands` | table | command name -> `function(args)` returning an exit code |
| `klua.install_opts` | table | install-time flags: `force` (override link guards) and `link` (`false` = store-only install) |
| `klua.registries` | array | registry base URLs for alias sharding (defaults to the official registry) |

### Service endpoint overrides

Set these in `init.lua` for mirrors, GitHub Enterprise, or testing:

```lua
klua.github_api   = "https://api.github.com"          -- Releases API base
klua.gitlab_api   = "https://gitlab.com/api/v4"       -- Releases API base
klua.raw_github   = "https://raw.githubusercontent.com"  -- klua.yaml fetch base
klua.raw_gitlab   = "https://gitlab.com"                 -- klua.yaml fetch base
klua.github_clone = "https://github.com"              -- git clone base (build.steps)
klua.gitlab_clone = "https://gitlab.com"              -- git clone base (build.steps)
```

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

local ok, err = klua.download("https://host/tool.tar.gz", "/path/dest")
```

- HTTPS via OpenSSL; redirects followed across hosts.
- Sends `User-Agent: klua/<version>`. No custom-header parameter — see
  the private-auth recipe below for authenticated requests.
- `download` streams to disk, creates parent dirs, accepts only HTTP 200,
  and removes partial files on failure.
- Transient failures (`403`, `429`, `5xx`, dropped connections — common with
  GitHub's release-asset CDN) are retried up to 4 times with exponential
  backoff.
- Timeouts: 30 s connect, 300 s read, 120 s write.

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
plus all pass-through arguments. Return a process exit code. Override or
wrap freely:

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
2. Library-looking names (`.so`, `.so.*`, `.dylib`, `.a`, `.la`, `.dll`) →
   warn and leave the file inside the store.
3. Existing non-klua links/files at the destination → warn and skip unless
   `klua.install_opts.force` is set.
4. Protected core command names (shells, coreutils, network tools, language
   runtimes, compilers, system package managers, editors and `klua`) → warn
   and skip unless forced.
5. A same-named executable elsewhere on `PATH` → warn and skip unless forced.

A skipped link still counts as success: the package is staged in the store.
Links that already point into the store are replaced, so upgrades work. The
CLI sets these options per invocation:

```lua
-- klua install --force ...
klua.install_opts = { force = true, link = true }

-- klua run ... (install missing package store-only)
klua.install_opts = { force = false, link = false }
```

`klua run` executes the chosen binary through the shell with store `bin`
directories prepended to `PATH` and store library directories prepended to
`LD_LIBRARY_PATH` / `DYLD_LIBRARY_PATH`; it uses `klua.is_dir` to discover
library directories up to two levels deep and `shq()`-style single-quote
escaping for every argument. Custom providers that create links themselves
should respect `klua.install_opts.link` and perform equivalent conflict
checks using `klua.readlink`, `klua.is_executable` and `klua.env("PATH")`.

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

### Private GitHub auth (wrap http_get)

`klua.http_get` sends no auth headers. Monkey-patch it to route GitHub
API calls through `curl` with a token, keeping all default provider logic:

```lua
local native_http_get = klua.http_get
klua.http_get = function(url)
    if not url:match("^https://api%.github%.com/") then
        return native_http_get(url)
    end
    local token = klua.env("GITHUB_TOKEN")
    if not token or token == "" then return native_http_get(url) end
    local body_file = klua.paths.cache .. "/http-body"
    local code_file = klua.paths.cache .. "/http-code"
    local cmd = "curl -sS -H 'Authorization: Bearer " .. token .. "'"
        .. " -o '" .. body_file .. "' -w '%{http_code}' '" .. url .. "'"
        .. " > '" .. code_file .. "'"
    if klua.exec(cmd) ~= 0 then
        return "", 0, "curl failed"
    end
    local status = tonumber(klua.read_file(code_file) or "") or 0
    return klua.read_file(body_file) or "", status, nil
end
```

(Keep the token out of shell history/logs; it is passed via argv here —
for stricter setups write a curl config file with `klua.write_file` and
use `curl --config`.)

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
klua.raw_github   = "https://github.corp.example/raw"
klua.github_clone = "https://github.corp.example"
```

### Extra registries without taps

```lua
klua.registries[#klua.registries + 1] = "https://corp.example/klua-registry"
```

Taps (`klua tap add`) are consulted before `klua.registries`; see
[taps-and-registry.md](taps-and-registry.md).
