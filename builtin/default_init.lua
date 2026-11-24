-- klua built-in baseline logic.
--
-- This file is embedded into the klua binary at build time. It is always
-- loaded first on startup, and it is the clean fallback used when the user's
-- ~/.config/klua/init.lua fails to load. `klua repair` restores this exact
-- content into the user's init.lua.
--
-- Native primitives provided by the C++ core (see src/lua_engine.cpp):
--   klua.version, klua.paths, klua.platform(), klua.cwd()
--   klua.info / klua.warn / klua.error
--   klua.file_exists / klua.is_dir / klua.is_executable
--   klua.read_file / klua.write_file / klua.mkdir
--   klua.copy / klua.remove / klua.list_dir / klua.find_executables
--   klua.readlink / klua.env / klua.exec / klua.register_provider
--   klua.http_get / klua.http_head_redirect / klua.download
--   klua.system (optional manager overrides), klua.lockfile
--   klua.sha256 / klua.extract / klua.is_archive
--   klua.symlink / klua.chmod_exec / klua.json_parse / klua.yaml_parse

klua.providers = klua.providers or {}
klua.commands = klua.commands or {}

-- Install-time options, consumed by the safe linking helpers below.
--   force: link even when the name conflicts with a system/protected command
--   link:  false to stage a package in the store without touching ~/.local/bin
--   as:    link the primary binary under this name instead of its own basename
klua.install_opts = klua.install_opts or {}

-- Official registry (hosted on githubusercontent.com via the klua-registry
-- repository). Users can extend this list in their init.lua; `klua tap add
-- <url>` appends to taps.yaml, which takes precedence over the defaults.
klua.registries = klua.registries or {
    "https://raw.githubusercontent.com/kiru0414/klua-registry/main",
}

-- Service endpoints. Overridable in init.lua for mirrors or testing.
klua.github_api = klua.github_api or "https://api.github.com"
klua.gitlab_api = klua.gitlab_api or "https://gitlab.com/api/v4"
klua.raw_github = klua.raw_github or "https://raw.githubusercontent.com"
klua.raw_gitlab = klua.raw_gitlab or "https://gitlab.com"
klua.github_clone = klua.github_clone or "https://github.com"
klua.gitlab_clone = klua.gitlab_clone or "https://gitlab.com"
-- Web endpoints used for API-free release discovery (overridable in tests).
klua.github_web = klua.github_web or "https://github.com"

-- Registry shard cache: one-hour TTL by default. Set klua.shard_ttl in
-- init.lua to change it, or pass --no-cache to force a fresh fetch.
klua.shard_ttl = klua.shard_ttl or 3600
klua.cli_flags = klua.cli_flags or {}

-- System package delegation can be configured in init.lua with:
--   klua.system.manager     -- "apt", "dnf", "yum", "pacman", "apk" or "brew"
--   klua.system.status(pkg) -- true/0 when installed (custom predicate)
--   klua.system.install(pkgs) -- install the whole missing batch (custom hook)
-- Otherwise the manager is detected at runtime and sudo is used when needed.
klua.system = klua.system or {}

-- Reproducible lock state, populated lazily from packages.lock.yaml.
klua.lockfile = klua.lockfile or {}

-- Optional signature/artifact verification hooks. A manifest `verify:` field
-- takes precedence; this table can provide a global command and/or Lua hook.
klua.verify = klua.verify or {}

-- Forward declarations: dependency hooks and the system batch flusher are
-- defined below but called from the release providers.
local install_one
local install_dependencies
local flush_system_packages
local lock_entry_for
local record_lock_entry
local verify_locked_digest

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function basename(path)
    return string.match(path, "([^/]+)$") or path
end

local function dirname(path)
    return string.match(path, "^(.*)/[^/]*$") or "."
end

local function strip_trailing_slash(url)
    return (string.gsub(url, "/+$", ""))
end

local function dedupe(list)
    local seen, result = {}, {}
    for _, value in ipairs(list) do
        if not seen[value] then
            seen[value] = true
            result[#result + 1] = value
        end
    end
    return result
end

-- Classic Levenshtein distance (two-row, O(n*m) time, O(m) space).
local function levenshtein(a, b)
    local la, lb = #a, #b
    local prev = {}
    for j = 0, lb do
        prev[j] = j
    end
    for i = 1, la do
        local cur = { [0] = i }
        local ai = string.byte(a, i)
        for j = 1, lb do
            local cost = (ai == string.byte(b, j)) and 0 or 1
            local deletion = prev[j] + 1
            local insertion = cur[j - 1] + 1
            local substitution = prev[j - 1] + cost
            cur[j] = math.min(deletion, insertion, substitution)
        end
        prev = cur
    end
    return prev[lb]
end

-- Pick the closest candidate within a length-relative threshold.
local function closest_match(target, candidates, threshold_divisor)
    local best, best_distance = nil, math.huge
    for _, candidate in ipairs(candidates) do
        local distance = levenshtein(target, candidate)
        if distance < best_distance then
            best, best_distance = candidate, distance
        end
    end
    local threshold = math.max(1, math.floor(#target / (threshold_divisor or 3)))
    if best and best_distance <= threshold then
        return best
    end
    return nil
end

-- POSIX shell quoting for commands passed to klua.exec.
local function shq(value)
    return "'" .. string.gsub(value, "'", "'\\''") .. "'"
end

local function expand_home(path)
    if string.sub(path, 1, 2) == "~/" then
        local home = klua.env("HOME") or ""
        return home .. string.sub(path, 2)
    end
    return path
end

-- ---------------------------------------------------------------------------
-- Conflict-safe linking
--
-- klua never blindly replaces binaries. Before creating a link it checks:
--   1. whether the destination already holds something klua does not manage,
--   2. whether the command shadows a binary elsewhere on PATH,
--   3. whether the name is a protected core system command.
-- Conflicting links are skipped with a warning; --force overrides. Shared
-- libraries are never linked: they stay inside the store and klua run
-- exposes them through LD_LIBRARY_PATH / DYLD_LIBRARY_PATH only.
-- ---------------------------------------------------------------------------

local CORE_COMMANDS = {
    -- shells and coreutils
    sh = true, bash = true, zsh = true, fish = true, dash = true, ksh = true,
    ls = true, cp = true, mv = true, rm = true, ln = true, mkdir = true,
    rmdir = true, cat = true, echo = true, grep = true, sed = true, awk = true,
    find = true, xargs = true, tar = true, gzip = true, gunzip = true,
    bzip2 = true, xz = true, zstd = true, unzip = true, mount = true,
    umount = true, kill = true, ps = true, chmod = true, chown = true,
    -- network and transport
    git = true, curl = true, wget = true, ssh = true, scp = true,
    rsync = true, openssl = true,
    -- language runtimes and package managers
    python = true, ["python3"] = true, pip = true, ["pip3"] = true,
    node = true, npm = true, npx = true, perl = true, ruby = true,
    php = true, java = true, javac = true,
    -- build toolchains
    make = true, cmake = true, cc = true, gcc = true, ["g++"] = true,
    clang = true, ["clang++"] = true, ld = true, ["pkg-config"] = true,
    -- system / package managers
    sudo = true, su = true, systemctl = true, pacman = true, apt = true,
    ["apt-get"] = true, dnf = true, yum = true, apk = true, brew = true,
    port = true, docker = true, podman = true, kubectl = true,
    -- editors and pagers
    vim = true, vi = true, nano = true, emacs = true, man = true,
    less = true, more = true,
    -- never let a package shadow klua itself
    klua = true,
}

-- Shared/static library names must never be linked into ~/.local/bin.
local function is_library_name(name)
    local lower = string.lower(name)
    if string.sub(lower, -3) == ".so" or string.find(lower, "%.so%.", 1, false) then
        return true
    end
    return string.sub(lower, -6) == ".dylib"
        or string.sub(lower, -2) == ".a"
        or string.sub(lower, -3) == ".la"
        or string.sub(lower, -4) == ".dll"
end

local function normalize_dir(dir)
    if #dir > 1 then
        return (string.gsub(dir, "/+$", ""))
    end
    return dir
end

local function path_dirs()
    local dirs, seen = {}, {}
    for dir in string.gmatch(klua.env("PATH") or "", "[^:]+") do
        dir = normalize_dir(dir)
        if dir ~= "" and not seen[dir] then
            seen[dir] = true
            dirs[#dirs + 1] = dir
        end
    end
    return dirs
end

local function is_under_store(path)
    local store = normalize_dir(klua.paths.store)
    return path == store or string.sub(path, 1, #store + 1) == store .. "/"
end

-- First executable named `name` on PATH, ignoring klua's own bin directory
-- and links that already point into the store.
local function find_on_path(name)
    local own_bin = normalize_dir(klua.paths.bin)
    for _, dir in ipairs(path_dirs()) do
        if dir ~= own_bin then
            local candidate = dir .. "/" .. name
            if klua.is_executable(candidate) then
                local link_target = klua.readlink(candidate)
                if not (link_target and is_under_store(link_target)) then
                    return candidate
                end
            end
        end
    end
    return nil
end

-- Create a link into ~/.local/bin after conflict checks. Returns false only
-- for real filesystem errors; a deliberately skipped conflict is success.
local function safe_link(target_path, link_path, name)
    local opts = klua.install_opts or {}
    name = name or basename(link_path)

    if opts.link == false then
        return true -- run-only staging: keep the store isolated
    end

    -- `klua install --as NAME` renames the first linked binary. Extra binaries
    -- from the same package keep their own names so they never overwrite each
    -- other.
    if opts.as and not opts._as_used then
        opts._as_used = true
        name = opts.as
        link_path = klua.paths.bin .. "/" .. name
    elseif opts.as and opts._as_used and not opts._as_warned then
        opts._as_warned = true
        klua.warn("--as applies to the primary binary only; additional binaries "
            .. "keep their own names")
    end

    if is_library_name(name) then
        klua.warn("skipping shared library '" .. name
            .. "'; libraries stay isolated inside the store")
        return true
    end

    local existing = klua.readlink(link_path)
    local managed = existing ~= nil and is_under_store(existing)
    local occupied = existing ~= nil or klua.file_exists(link_path)
    if occupied and not managed and not opts.force then
        klua.warn(link_path .. " already exists and is not managed by klua; "
            .. "not linking '" .. name .. "' (use --force to replace)")
        return true
    end

    local system_path = not managed and find_on_path(name) or nil

    if CORE_COMMANDS[name] and not managed then
        if not opts.force then
            klua.warn("refusing to link protected command '" .. name .. "'"
                .. (system_path and (" (system binary: " .. system_path .. ")") or "")
                .. "; use --force to override")
            return true
        end
        klua.warn("overriding protected command '" .. name .. "'")
    elseif system_path then
        if not opts.force then
            klua.warn("'" .. name .. "' already exists on PATH at " .. system_path
                .. "; not linking (use --force to shadow)")
            return true
        end
        klua.warn("shadowing existing '" .. name .. "' at " .. system_path)
    end

    local ok, err = klua.symlink(target_path, link_path)
    if not ok then
        klua.error(tostring(err))
        return false
    end
    klua.info("linked " .. link_path)
    return true
end

-- Translate a simple glob (* and ?) into an anchored Lua pattern.
local function glob_to_pattern(glob)
    local pattern = string.gsub(glob, "[%(%)%.%%%+%-%^%$%[%]]", "%%%0")
    pattern = string.gsub(pattern, "%*", ".*")
    pattern = string.gsub(pattern, "%?", ".")
    return "^" .. pattern .. "$"
end

-- ---------------------------------------------------------------------------
-- Taps (taps.yaml): a plain YAML list of registry base URLs.
-- ---------------------------------------------------------------------------

local function load_taps()
    if not klua.file_exists(klua.paths.taps) then
        return {}
    end
    local content = klua.read_file(klua.paths.taps)
    if not content or content == "" then
        return {}
    end
    local doc, err = klua.yaml_parse(content)
    if not doc then
        klua.warn("could not parse taps.yaml: " .. tostring(err))
        return {}
    end
    local taps = {}
    for _, value in ipairs(doc) do
        if type(value) == "string" then
            taps[#taps + 1] = value
        end
    end
    return taps
end

local function save_taps(taps)
    local lines = {}
    for _, url in ipairs(taps) do
        lines[#lines + 1] = "- " .. url
    end
    local content = #lines > 0 and (table.concat(lines, "\n") .. "\n") or "[]\n"
    local ok, err = klua.write_file(klua.paths.taps, content)
    if not ok then
        klua.error("could not write taps.yaml: " .. tostring(err))
        return false
    end
    return true
end

local function all_registries()
    local combined = {}
    for _, url in ipairs(load_taps()) do
        combined[#combined + 1] = url
    end
    for _, url in ipairs(klua.registries) do
        combined[#combined + 1] = url
    end
    return dedupe(combined)
end

-- ---------------------------------------------------------------------------
-- Registry shard cache
--
-- Shards are stored under ~/.cache/klua/shards/ with a content-independent
-- key derived from the URL. A sibling .ts file records the fetch time so
-- repeated installs/search calls stay instant within klua.shard_ttl.
-- ---------------------------------------------------------------------------

local function shard_cache_key(url)
    local hash = 0xcbf29ce484222325
    for index = 1, #url do
        hash = hash ~ string.byte(url, index)
        hash = (hash * 0x100000001b3) & 0xffffffffffffffff
    end
    return string.format("%016x", hash)
end

local function shard_cache_paths(url)
    local key = shard_cache_key(url)
    local path = klua.paths.shards .. "/" .. key .. ".yaml"
    return path, path .. ".ts"
end

-- Fetch many shards through the bounded native worker pool. Fresh cache hits
-- are served locally; all misses are requested together (at most 8 at once),
-- then cached in input order. Returned table: url -> {body=...} or {error=...}.
local function fetch_shards_batch(urls)
    local flags = klua.cli_flags or {}
    local results, stale, pending, pending_urls, seen = {}, {}, {}, {}, {}
    for _, url in ipairs(urls) do
        if not seen[url] then
            seen[url] = true
            local path, stamp_path = shard_cache_paths(url)
            local cached_body = klua.read_file(path)
            local cached_stamp = tonumber(klua.read_file(stamp_path) or "")
            if cached_body and cached_stamp and not flags.no_cache
                and os.time() - cached_stamp < klua.shard_ttl then
                results[url] = { body = cached_body }
            else
                stale[url] = cached_body
                pending_urls[#pending_urls + 1] = url
            end
        end
    end

    if #pending_urls > 0 then
        local responses = klua.http_get_batch(pending_urls)
        for index, url in ipairs(pending_urls) do
            local response = responses[index] or { error = "missing batch response" }
            if not response.error and response.status == 200 then
                local path, stamp_path = shard_cache_paths(url)
                klua.write_file(path, response.body)
                klua.write_file(stamp_path, tostring(os.time()))
                results[url] = { body = response.body }
            elseif stale[url] and not flags.no_cache then
                klua.warn("using stale cached shard for " .. url
                    .. " (" .. tostring(response.error
                        or ("HTTP " .. tostring(response.status))) .. ")")
                results[url] = { body = stale[url], stale = true }
            else
                results[url] = {
                    error = response.error or ("HTTP " .. tostring(response.status)),
                }
            end
        end
    end
    return results
end

local function fetch_shard(url)
    local result = fetch_shards_batch({ url })[url]
    if result and result.body then
        return result.body
    end
    return nil, (result and result.error) or "shard fetch failed"
end

-- ---------------------------------------------------------------------------
-- Alias sharding lookup: fetch v1/<first_char>.yaml from each registry and
-- resolve the alias to a scheme target. Non-alpha first characters map to
-- the "_" shard.
-- ---------------------------------------------------------------------------

local function shard_char(target)
    local first = string.lower(string.sub(target, 1, 1))
    if string.match(first, "%a") then
        return first
    end
    return "_"
end

local function resolve_alias(target)
    local registries = all_registries()
    if #registries == 0 then
        return nil, "no registries configured for alias '" .. target
            .. "'; add one with 'klua tap add <url>' or set klua.registries in init.lua"
    end

    local shard = shard_char(target)
    local candidates, seen = {}, {}
    for _, base in ipairs(registries) do
        local url = strip_trailing_slash(base) .. "/v1/" .. shard .. ".yaml"
        local body, err = fetch_shard(url)
        if body then
            local doc, parse_err = klua.yaml_parse(body)
            if doc and type(doc) == "table" then
                for key in pairs(doc) do
                    if type(key) == "string" and not seen[key] then
                        seen[key] = true
                        candidates[#candidates + 1] = key
                    end
                end
                local resolved = doc[target]
                if type(resolved) == "string" and resolved ~= "" then
                    return resolved
                end
            elseif parse_err then
                klua.warn("registry " .. base .. " returned invalid YAML: " .. parse_err)
            end
        elseif err then
            klua.warn("could not fetch shard " .. url .. ": " .. err)
        end
    end
    return nil, "alias '" .. target .. "' not found in any configured registry", candidates
end

-- ---------------------------------------------------------------------------
-- Asset scoring and binary selection
-- ---------------------------------------------------------------------------

local IGNORED_SUFFIXES = {
    ".sha256", ".sha256sum", ".sig", ".asc", ".deb", ".rpm",
    ".msi", ".apk", ".txt", ".json", ".yaml", ".yml",
}

local ARCH_TOKENS = {
    x86_64 = { "x86_64", "amd64", "x64" },
    arm64 = { "arm64", "aarch64" },
}

local ALL_ARCH_TOKENS = {
    "x86_64", "amd64", "x64", "arm64", "aarch64",
    "i686", "i386", "386", "armv7", "armv6", "riscv64", "ppc64le", "s390x",
}

local function score_asset(name, platform)
    local lower = string.lower(name)

    for _, suffix in ipairs(IGNORED_SUFFIXES) do
        if string.sub(lower, -#suffix) == suffix then
            return -1
        end
    end

    -- Operating system must match.
    local os_ok = false
    if platform.os == "linux" then
        os_ok = string.find(lower, "linux", 1, true) ~= nil
    elseif platform.os == "macos" then
        os_ok = string.find(lower, "darwin", 1, true) ~= nil
            or string.find(lower, "macos", 1, true) ~= nil
            or string.find(lower, "apple", 1, true) ~= nil
    end
    if not os_ok then
        return -1
    end

    -- Architecture: reject assets that advertise a different architecture;
    -- accept assets with no architecture token (often universal builds).
    local wanted = ARCH_TOKENS[platform.arch] or {}
    local has_any_arch, has_matching_arch = false, false
    for _, token in ipairs(ALL_ARCH_TOKENS) do
        if string.find(lower, token, 1, true) then
            has_any_arch = true
            for _, want in ipairs(wanted) do
                if token == want then
                    has_matching_arch = true
                end
            end
        end
    end
    if has_any_arch and not has_matching_arch then
        return -1
    end

    local score = 10
    if has_matching_arch then
        score = score + 10
    end
    if klua.is_archive(name) then
        score = score + 2 -- archives usually carry docs/completions too
    end
    if string.find(lower, "musl", 1, true) then
        score = score + 1 -- static builds are the most portable
    end
    return score
end

local function pick_binary(candidates, preferred_name)
    local function rank(path)
        local name = basename(path)
        if name == preferred_name then
            return 0
        end
        if string.find(path, "/bin/", 1, true) then
            return 1
        end
        return 2
    end
    table.sort(candidates, function(a, b)
        local ra, rb = rank(a), rank(b)
        if ra ~= rb then
            return ra < rb
        end
        if #a ~= #b then
            return #a < #b
        end
        return a < b
    end)
    return candidates[1]
end

-- Select a release asset: explicit manifest patterns win over scoring.
local function select_asset(assets, manifest, platform)
    if manifest and type(manifest.assets) == "table" and #manifest.assets > 0 then
        for _, asset in ipairs(assets) do
            local asset_name = asset.name or ""
            for _, pattern in ipairs(manifest.assets) do
                if type(pattern) == "string" and string.match(asset_name, glob_to_pattern(pattern)) then
                    return asset
                end
            end
        end
        return nil
    end

    local best, best_score = nil, 0
    for _, asset in ipairs(assets) do
        local score = score_asset(asset.name or "", platform)
        if score > best_score then
            best, best_score = asset, score
        end
    end
    return best
end

-- ---------------------------------------------------------------------------
-- API-free GitHub release discovery
--
-- `https://github.com/<user>/<repo>/releases/latest` redirects to the tag
-- page; HEAD exposes that tag without a REST call. GitHub's
-- `releases/expanded_assets/<tag>` fragment then lists every downloadable
-- asset as an ordinary HTML link. The REST API remains a fallback for repos
-- whose web layout changes or when GITHUB_TOKEN is available.
-- ---------------------------------------------------------------------------

local function html_unescape(value)
    value = string.gsub(value, "&amp;", "&")
    value = string.gsub(value, "&quot;", "\"")
    value = string.gsub(value, "&#39;", "'")
    return value
end

local function absolute_url(base, href)
    href = html_unescape(href)
    if string.match(href, "^https?://") then
        return href
    end
    local origin = string.match(base, "^(%w+://[^/]+)")
    if string.sub(href, 1, 1) == "/" then
        return (origin or "") .. href
    end
    local prefix = string.match(base, "^(.*/)[^/]*$") or ((origin or base) .. "/")
    return prefix .. href
end

local function tag_from_location(location)
    local tag = string.match(location or "", "/releases/tag/([^?#]+)")
    if tag then
        tag = string.gsub(tag, "/+$", "")
        if tag ~= "" then
            return tag
        end
    end
    return nil
end

local function github_parse_assets(body, web, tag_filter)
    local assets, seen = {}, {}
    for href in string.gmatch(body, [=[href=["']([^"']+)["']]=]) do
        local path = string.match(html_unescape(href), "^([^?#]+)")
        local asset_tag, asset_name
        if path then
            asset_tag, asset_name = string.match(path, "/releases/download/([^/]+)/([^/]+)$")
        end
        if asset_name and asset_name ~= ""
            and (not tag_filter or asset_tag == tag_filter)
            and not seen[asset_name] then
            seen[asset_name] = true
            assets[#assets + 1] = {
                name = asset_name,
                browser_download_url = absolute_url(web, path),
            }
        end
    end
    return assets
end

local function github_expanded_assets(web, user, name, tag)
    local url = web .. "/" .. user .. "/" .. name .. "/releases/expanded_assets/" .. tag
    local body, status, err = klua.http_get(url)
    if err or status ~= 200 then
        return nil, "could not fetch " .. url .. ": "
            .. tostring(err or ("HTTP " .. tostring(status)))
    end
    local assets = github_parse_assets(body, web, tag)
    if #assets == 0 then
        -- Never treat an empty scrape as success: the caller must continue to
        -- the Atom feed and then the REST API.
        return nil, "0 assets parsed from " .. url
    end
    return assets
end

local function github_web_release(user, name, tag)
    local web = strip_trailing_slash(klua.github_web)

    if not tag then
        local latest = web .. "/" .. user .. "/" .. name .. "/releases/latest"
        local location, status, err = klua.http_head_redirect(latest)
        if err then
            return nil, "HEAD " .. latest .. " failed: " .. err
        end
        tag = tag_from_location(location)
        if not tag then
            return nil, "could not determine latest tag from " .. latest
                .. " (HTTP " .. tostring(status) .. ", Location: " .. tostring(location) .. ")"
        end
    end

    local assets, assets_err = github_expanded_assets(web, user, name, tag)
    if not assets then
        return nil, assets_err
    end
    return { tag_name = tag, assets = assets }
end

-- Atom tier: GitHub exposes recent releases as XML. It usually carries the
-- tag (and sometimes release notes with download links) but not a reliable
-- complete asset list, so when no assets are embedded we re-read the expanded
-- assets page for the tag found in the feed.
local function github_atom_release(user, name, tag)
    local web = strip_trailing_slash(klua.github_web)
    local url = web .. "/" .. user .. "/" .. name .. "/releases.atom"
    local body, status, err = klua.http_get(url)
    if err or status ~= 200 then
        return nil, "could not fetch " .. url .. ": "
            .. tostring(err or ("HTTP " .. tostring(status)))
    end

    local found
    for entry in string.gmatch(body, "<entry[^>]*>(.-)</entry>") do
        local entry_tag
        for href in string.gmatch(entry, [=[href=["']([^"']+)["']]=]) do
            local candidate = string.match(html_unescape(href), "/releases/tag/([^?#\"']+)")
            if candidate then
                candidate = string.gsub(candidate, "/+$", "")
                if candidate ~= "" then
                    entry_tag = candidate
                    break
                end
            end
        end
        if entry_tag and not found then
            found = entry_tag
        end
        if tag and entry_tag == tag then
            found = tag
            break
        end
    end

    if not found then
        return nil, "no release entry for " .. (tag or "latest") .. " in " .. url
    end
    if tag and found ~= tag then
        return nil, "requested tag '" .. tag .. "' is not present in " .. url
    end

    local assets = github_parse_assets(body, web, found)
    if #assets == 0 then
        local expanded, expanded_err = github_expanded_assets(web, user, name, found)
        if not expanded then
            return nil, expanded_err
        end
        assets = expanded
    end
    return { tag_name = found, assets = assets }
end

local function github_api_release(user, name, tag)
    local endpoint = tag and ("tags/" .. tag) or "latest"
    local api = klua.github_api .. "/repos/" .. user .. "/" .. name .. "/releases/" .. endpoint
    local body, status, err = klua.http_get(api)
    if err then
        return nil, "request failed: " .. err
    end
    if status == 200 then
        local release, json_err = klua.json_parse(body)
        if not release then
            return nil, "could not parse release JSON: " .. tostring(json_err)
        end
        return release
    end
    if status == 404 then
        return nil, "no release at " .. api
    end
    return nil, "GitHub API returned HTTP " .. tostring(status)
end

-- Fail-safe resolution order: expanded_assets HTML -> releases.atom -> REST.
-- Successful results are cached so a sync prefetch and the later install do
-- not repeat the same discovery work.
local github_release_cache = {}

local function github_release_for(user, name, tag)
    local web = strip_trailing_slash(klua.github_web)
    local key = web .. "|" .. user .. "/" .. name .. "@" .. (tag or "latest")
    local cached = github_release_cache[key]
    if cached then
        return cached.release, nil, cached.source
    end

    local release, web_err = github_web_release(user, name, tag)
    if release then
        github_release_cache[key] = { release = release, source = "web" }
        return release, nil, "web"
    end

    local atom_release, atom_err = github_atom_release(user, name, tag)
    if atom_release then
        github_release_cache[key] = { release = atom_release, source = "atom" }
        return atom_release, nil, "atom"
    end

    local api_release, api_err = github_api_release(user, name, tag)
    if api_release then
        github_release_cache[key] = { release = api_release, source = "api" }
        return api_release, nil, "api"
    end

    return nil, "web: " .. tostring(web_err)
        .. "; atom: " .. tostring(atom_err)
        .. "; api: " .. tostring(api_err)
end

-- ---------------------------------------------------------------------------
-- SHA-256 verification
--
-- A release may ship <asset>.sha256, <asset>.sha256sum or checksums.txt. The
-- digest is checked before extraction; a mismatch aborts the install unless
-- --skip-checksum was passed.
-- ---------------------------------------------------------------------------

local function checksum_candidates(assets, asset_name)
    local wanted = {
        asset_name .. ".sha256",
        asset_name .. ".sha256sum",
        "checksums.txt",
    }
    local found = {}
    for _, name in ipairs(wanted) do
        for _, asset in ipairs(assets or {}) do
            if (asset.name or "") == name then
                found[#found + 1] = asset
                break
            end
        end
    end
    return found
end

local function parse_checksum_text(text, asset_name, allow_bare)
    local target = string.lower(asset_name)
    for line in string.gmatch(text or "", "[^\r\n]+") do
        local hash, name = string.match(line, "^%s*([%xX]+)%s+[*]?([^%s]+)")
        if hash and #hash == 64 then
            local file_name = string.match(name, "([^/]+)$") or name
            if string.lower(file_name) == target then
                return string.lower(hash)
            end
        end

        local bsd_name, bsd_hash = string.match(
            line, "^%s*SHA%d*%s*%(%s*([^)]+)%s*%)%s*=%s*([%xX]+)")
        if bsd_hash and #bsd_hash == 64 then
            local file_name = string.match(bsd_name, "([^/]+)$") or bsd_name
            if string.lower(file_name) == target then
                return string.lower(bsd_hash)
            end
        end

        if allow_bare then
            local bare = string.match(line, "^%s*([%xX]+)%s*$")
            if bare and #bare == 64 then
                return string.lower(bare)
            end
        end
    end
    return nil
end

local function verify_checksum(payload_path, asset_name, assets, label)
    local candidates = checksum_candidates(assets, asset_name)
    if #candidates == 0 then
        return 0
    end

    local flags = klua.cli_flags or {}
    if flags.skip_checksum then
        klua.warn("checksum verification skipped via --skip-checksum for " .. asset_name)
        return 0
    end

    local actual, digest_err = klua.sha256(payload_path)
    if not actual or digest_err then
        klua.error("could not compute SHA-256 for " .. asset_name .. ": "
            .. tostring(digest_err))
        return 1
    end
    actual = string.lower(actual)

    local checked = false
    for _, checksum_asset in ipairs(candidates) do
        local url = checksum_asset.browser_download_url
        if url then
            local name = basename(url)
            local checksum_path = klua.paths.cache .. "/checksums/" .. name
            local ok, dl_err = klua.download(url, checksum_path)
            if ok then
                local text = klua.read_file(checksum_path) or ""
                local sidecar = checksum_asset.name == asset_name .. ".sha256"
                    or checksum_asset.name == asset_name .. ".sha256sum"
                local expected = parse_checksum_text(text, asset_name, sidecar)
                if expected then
                    checked = true
                    if expected ~= actual then
                        klua.error("SHA-256 mismatch for " .. asset_name .. ": expected "
                            .. expected .. ", got " .. actual .. " (" .. label .. ")")
                        return 1
                    end
                    klua.info("sha256 verified for " .. asset_name)
                    return 0
                end
            else
                klua.warn("could not download checksum asset " .. name .. ": "
                    .. tostring(dl_err))
            end
        end
    end

    if not checked then
        klua.warn("no matching SHA-256 entry found for " .. asset_name
            .. "; install continues unverified")
    end
    return 0
end

-- ---------------------------------------------------------------------------
-- Optional signature/artifact verification
--
-- `verify:` in klua.yaml (or klua.verify.command in init.lua) runs after the
-- SHA-256 check and before extraction. Commands may use {payload}, {file},
-- {asset}, {version}, {target} and {sha256}; the payload is appended when no
-- file placeholder is present. A Lua hook can inspect the same context.
-- Verification fails closed: a missing tool or non-zero exit aborts install.
-- ---------------------------------------------------------------------------

local function verify_command_list(value)
    if type(value) == "string" and value ~= "" then
        return { value }
    end
    if type(value) == "table" then
        if type(value.command) == "string" and value.command ~= "" then
            return { value.command }
        end
        local commands = {}
        for _, item in ipairs(value) do
            if type(item) == "string" and item ~= "" then
                commands[#commands + 1] = item
            end
        end
        return commands
    end
    return {}
end

local function render_verify_command(template, context)
    local rendered = template
    local placeholders = {
        payload = context.payload,
        file = context.payload,
        asset = context.asset,
        version = context.version,
        target = context.target,
        sha256 = context.sha256,
    }
    local used_payload = false
    for name, value in pairs(placeholders) do
        local token = "{" .. name .. "}"
        if string.find(rendered, token, 1, true) then
            if name == "payload" or name == "file" then
                used_payload = true
            end
            rendered = string.gsub(rendered, token,
                function() return shq(tostring(value or "")) end)
        end
    end
    if not used_payload then
        rendered = rendered .. " " .. shq(context.payload)
    end
    return rendered
end

local function verify_payload(manifest, payload, asset_name, version, target, digest)
    local configured = manifest and manifest.verify
    if configured == false then
        return 0
    end
    local global = klua.verify or {}
    local commands = verify_command_list(configured)
    if #commands == 0 then
        commands = verify_command_list(global.command)
    end
    local hook = type(global.hook) == "function" and global.hook or nil
    if #commands == 0 and not hook then
        return 0
    end

    local context = {
        payload = payload,
        asset = asset_name,
        version = tostring(version or ""),
        target = target,
        sha256 = tostring(digest or ""),
        manifest = manifest,
    }

    if hook then
        local ok, result = pcall(hook, context)
        if not ok then
            klua.error("verify hook failed for " .. asset_name .. ": " .. tostring(result))
            return 1
        end
        if result == false or (type(result) == "number" and result ~= 0) then
            klua.error("verify hook rejected " .. asset_name)
            return 1
        end
    end

    for _, template in ipairs(commands) do
        local command = render_verify_command(template, context)
        klua.info("verify: " .. command)
        local code = klua.exec(command)
        if code ~= 0 then
            klua.error("verify command failed (exit " .. tostring(code) .. ") for " .. asset_name)
            return 1
        end
    end
    klua.info("verify: signature accepted for " .. asset_name)
    return 0
end

-- ---------------------------------------------------------------------------
-- In-repo klua.yaml manifests
-- ---------------------------------------------------------------------------

local manifest_cache = {}

local function fetch_manifest(raw_base, user, name, tag, style)
    local ref = tag or "HEAD"
    local url
    if style == "gitlab" then
        url = raw_base .. "/" .. user .. "/" .. name .. "/-/raw/" .. ref .. "/klua.yaml"
    else
        url = raw_base .. "/" .. user .. "/" .. name .. "/" .. ref .. "/klua.yaml"
    end
    local key = (style or "github") .. "|" .. url
    local cached = manifest_cache[key]
    if cached ~= nil then
        return cached or nil
    end

    local body, status, err = klua.http_get(url)
    if err or status ~= 200 then
        manifest_cache[key] = false
        return nil
    end
    local doc, parse_err = klua.yaml_parse(body)
    if parse_err then
        klua.warn("ignoring invalid klua.yaml: " .. parse_err)
        manifest_cache[key] = false
        return nil
    end
    if doc == nil then
        doc = {} -- comment-only manifest: valid, but no overrides
    end
    if type(doc) ~= "table" then
        klua.warn("ignoring klua.yaml: expected a mapping")
        manifest_cache[key] = false
        return nil
    end
    manifest_cache[key] = doc
    return doc
end

-- Link binaries listed in manifest.bins, or auto-detect one executable.
local function link_binaries(store_dir, manifest, preferred_name)
    if (klua.install_opts or {}).link == false then
        return 0 -- run-only staging
    end
    if manifest and type(manifest.bins) == "table" and #manifest.bins > 0 then
        for _, bin in ipairs(manifest.bins) do
            local path = store_dir .. "/" .. bin
            if not klua.file_exists(path) then
                klua.error("manifest bin not found in store: " .. bin)
                return 1
            end
            local ok, err = klua.chmod_exec(path)
            if not ok then
                klua.error(tostring(err))
                return 1
            end
            local link_name = basename(bin)
            if is_library_name(link_name) then
                klua.warn("manifest bin '" .. bin
                    .. "' is a shared library; leaving it inside the store")
            elseif not safe_link(path, klua.paths.bin .. "/" .. link_name, link_name) then
                return 1
            end
        end
        return 0
    end

    local raw = klua.find_executables(store_dir)
    local candidates = {}
    for _, path in ipairs(raw) do
        local name = basename(path)
        if is_library_name(name) then
            klua.warn("ignoring shared library '" .. name .. "' (left in the store)")
        else
            candidates[#candidates + 1] = path
        end
    end
    if #candidates == 0 then
        klua.error("no executable binary found in " .. store_dir)
        return 1
    end
    local binary = pick_binary(candidates, preferred_name)
    local ok, err = klua.chmod_exec(binary)
    if not ok then
        klua.error(tostring(err))
        return 1
    end
    if not safe_link(binary, klua.paths.bin .. "/" .. basename(binary)) then
        return 1
    end
    return 0
end

-- Copy manifest.configs entries out of the store into user locations.
local function apply_configs(store_dir, manifest)
    if not manifest or type(manifest.configs) ~= "table" then
        return 0
    end
    for _, config in ipairs(manifest.configs) do
        if type(config) == "table" and config.src and config.dest then
            local src = store_dir .. "/" .. config.src
            local dest = expand_home(config.dest)
            if string.sub(dest, -1) == "/" then
                dest = dest .. basename(config.src)
            end
            if not klua.file_exists(src) then
                klua.error("manifest config source not found: " .. config.src)
                return 1
            end
            local ok, err = klua.copy(src, dest)
            if not ok then
                klua.error("could not install config: " .. tostring(err))
                return 1
            end
            klua.info("config -> " .. dest)
        end
    end
    return 0
end

-- Install a downloaded file into the store and link its binaries.
-- `asset_name` drives archive detection; `preferred_name` is the naming hint
-- (repo name for gh/gl, file stem for url). Archives are linked under the
-- real binary's basename; raw binaries under the preferred name.
local function install_payload(payload_path, asset_name, store_dir, preferred_name, manifest)
    local ok, err = klua.remove(store_dir)
    if not ok then
        klua.error("could not clean store directory: " .. tostring(err))
        return 1
    end

    if klua.is_archive(asset_name) then
        ok, err = klua.extract(payload_path, store_dir)
        if not ok then
            klua.error("extraction failed: " .. tostring(err))
            return 1
        end
    else
        -- Raw binary asset: store it intact under its own name.
        ok, err = klua.mkdir(store_dir)
        if not ok then
            klua.error("could not create store directory: " .. tostring(err))
            return 1
        end
        ok, err = klua.copy(payload_path, store_dir .. "/" .. asset_name)
        if not ok then
            klua.error("could not store binary: " .. tostring(err))
            return 1
        end
    end

    -- With explicit manifest bins the link names come from the manifest;
    -- otherwise raw binaries use the preferred name (jq-linux-amd64 -> jq).
    local has_manifest_bins = manifest and type(manifest.bins) == "table" and #manifest.bins > 0
    if not has_manifest_bins and not klua.is_archive(asset_name) then
        ok, err = klua.chmod_exec(store_dir .. "/" .. asset_name)
        if not ok then
            klua.error(tostring(err))
            return 1
        end
        if not safe_link(store_dir .. "/" .. asset_name,
                         klua.paths.bin .. "/" .. preferred_name, preferred_name) then
            return 1
        end
    else
        local code = link_binaries(store_dir, manifest, preferred_name)
        if code ~= 0 then
            return code
        end
    end

    local code = apply_configs(store_dir, manifest)
    if code ~= 0 then
        return code
    end

    klua.info("installed -> " .. store_dir)
    return 0
end

-- ---------------------------------------------------------------------------
-- Source builds (manifest build.steps, no suitable release asset)
-- ---------------------------------------------------------------------------

local function build_from_source(clone_base, user, name, tag, manifest, store_dir)
    local clone_dir = klua.paths.cache .. "/build/" .. user .. "-" .. name
    local ok, err = klua.remove(clone_dir)
    if not ok then
        klua.error(tostring(err))
        return 1
    end

    local repo_url = clone_base .. "/" .. user .. "/" .. name .. ".git"
    local clone_cmd = "git clone --depth 1 "
    if tag then
        clone_cmd = clone_cmd .. "--branch " .. shq(tag) .. " "
    end
    clone_cmd = clone_cmd .. shq(repo_url) .. " " .. shq(clone_dir)
    klua.info("cloning " .. repo_url)
    if klua.exec(clone_cmd) ~= 0 then
        klua.error("git clone failed for " .. repo_url)
        return 1
    end

    for _, step in ipairs(manifest.build.steps) do
        klua.info("build: " .. step)
        if klua.exec("cd " .. shq(clone_dir) .. " && " .. step) ~= 0 then
            klua.error("build step failed: " .. step)
            return 1
        end
    end

    ok, err = klua.remove(store_dir)
    if not ok then
        klua.error(tostring(err))
        return 1
    end
    ok, err = klua.mkdir(store_dir)
    if not ok then
        klua.error(tostring(err))
        return 1
    end

    -- Collect produced binaries: manifest.bins wins, then common output
    -- directories, then a full scan of the clone.
    local binaries = {}
    if type(manifest.bins) == "table" and #manifest.bins > 0 then
        for _, bin in ipairs(manifest.bins) do
            binaries[#binaries + 1] = clone_dir .. "/" .. bin
        end
    else
        for _, subdir in ipairs({ "target/release", "build", "bin" }) do
            local found = klua.find_executables(clone_dir .. "/" .. subdir)
            if #found > 0 then
                binaries = found
                break
            end
        end
        if #binaries == 0 then
            binaries = klua.find_executables(clone_dir)
        end
    end
    if #binaries == 0 then
        klua.error("no executable produced by build.steps")
        return 1
    end

    for _, binary in ipairs(binaries) do
        if not klua.file_exists(binary) then
            klua.error("build output not found: " .. binary)
            return 1
        end
        local dest = store_dir .. "/" .. basename(binary)
        ok, err = klua.copy(binary, dest)
        if not ok then
            klua.error(tostring(err))
            return 1
        end
        ok, err = klua.chmod_exec(dest)
        if not ok then
            klua.error(tostring(err))
            return 1
        end
        if not safe_link(dest, klua.paths.bin .. "/" .. basename(binary)) then
            return 1
        end
    end

    local code = apply_configs(store_dir, manifest)
    if code ~= 0 then
        return code
    end
    klua.info("installed -> " .. store_dir)
    return 0
end

-- ---------------------------------------------------------------------------
-- GitHub provider: gh:user/repo[@tag]
-- ---------------------------------------------------------------------------

local function github_install(rest, target_key)
    local repo, tag = string.match(rest, "^([^@]+)@(.+)$")
    if not repo then
        repo = rest
    end
    local user, name = string.match(repo, "^([%w_.-]+)/([%w_.-]+)$")
    if not user then
        klua.error("gh: expected 'user/repo' (optionally '@tag'), got '" .. rest .. "'")
        return 1
    end

    local key = target_key or ("gh:" .. repo)
    local flags = klua.cli_flags or {}
    local lock_entry, lock_failed = lock_entry_for(key, "gh")
    if lock_failed then
        return 1
    end
    if lock_entry and tag and lock_entry.version ~= tag then
        klua.error("--locked: requested tag '" .. tag .. "' for " .. key
            .. " but lockfile records '" .. tostring(lock_entry.version) .. "'")
        return 1
    end
    local resolved_tag = tag or (lock_entry and lock_entry.version) or nil

    local release = nil
    if lock_entry then
        klua.info("gh: using lockfile entry for " .. repo .. " " .. lock_entry.version)
        release = {
            tag_name = lock_entry.version,
            assets = {{ name = lock_entry.asset, browser_download_url = lock_entry.url }},
        }
    else
        -- Fail-safe 3-tier discovery: web HTML, Atom feed, then REST API.
        local release_err, source
        release, release_err, source = github_release_for(user, name, resolved_tag)
        if release and source == "web" then
            klua.info("gh: resolved " .. repo .. " " .. release.tag_name .. " from web release")
        elseif release and source == "atom" then
            klua.info("gh: resolved " .. repo .. " " .. release.tag_name
                .. " from releases.atom")
        elseif release then
            klua.warn("gh: web/Atom discovery failed; falling back to GitHub API")
            klua.info("gh: resolved " .. repo .. " " .. release.tag_name .. " from GitHub API")
        else
            klua.warn("gh: release discovery failed (" .. tostring(release_err) .. ")")
        end
    end

    -- Fetch the in-repo manifest using the resolved tag so `depends:` is
    -- read from the exact version being installed. HEAD is still tried first
    -- for source-only repositories that have no release.
    local manifest = fetch_manifest(klua.raw_github, user, name, resolved_tag)
    if release and release.tag_name and release.tag_name ~= resolved_tag then
        local tagged = fetch_manifest(klua.raw_github, user, name, release.tag_name)
        if tagged then
            manifest = tagged
        end
    end
    if manifest then
        local code = install_dependencies(manifest)
        if code ~= 0 then
            return code
        end
    end

    if release then
        local version = release.tag_name or resolved_tag or "unknown"
        local assets = release.assets or {}
        local asset = lock_entry and assets[1] or select_asset(assets, manifest, klua.platform())
        if asset then
            klua.info("gh: " .. repo .. " " .. version .. " -> " .. asset.name)
            local payload = klua.paths.cache .. "/downloads/" .. asset.name
            local ok, dl_err = klua.download(asset.browser_download_url, payload)
            if not ok then
                klua.error("gh: download failed: " .. tostring(dl_err))
                return 1
            end

            local digest
            if lock_entry then
                local code = verify_locked_digest(payload, asset.name, lock_entry, "gh:" .. repo)
                if code ~= 0 then
                    return code
                end
                digest = lock_entry.sha256
            else
                local code = verify_checksum(payload, asset.name, assets, "gh:" .. repo)
                if code ~= 0 then
                    return code
                end
                if flags.lock then
                    local digest_err
                    digest, digest_err = klua.sha256(payload)
                    if not digest or digest_err then
                        klua.error("could not compute SHA-256 for " .. asset.name .. ": "
                            .. tostring(digest_err))
                        return 1
                    end
                    record_lock_entry(key, "gh", version, asset.name,
                        asset.browser_download_url, digest)
                end
            end

            local code = verify_payload(manifest, payload, asset.name, version, key, digest)
            if code ~= 0 then
                return code
            end

            local store_dir = klua.paths.store .. "/gh/" .. user .. "/" .. name .. "/" .. version
            return install_payload(payload, asset.name, store_dir, name, manifest)
        end
    end

    -- No release or no suitable asset: try manifest build.steps. System
    -- dependencies are flushed before any build command runs.
    if manifest and type(manifest.build) == "table"
        and type(manifest.build.steps) == "table" and #manifest.build.steps > 0 then
        local code = flush_system_packages()
        if code ~= 0 then
            return code
        end
        local version = resolved_tag or "source"
        local store_dir = klua.paths.store .. "/gh/" .. user .. "/" .. name .. "/" .. version
        return build_from_source(klua.github_clone, user, name, resolved_tag, manifest, store_dir)
    end

    if not release then
        klua.error("gh: no release found for " .. repo
            .. " (add build.steps to klua.yaml for source builds)")
    else
        klua.error("gh: no suitable release asset for "
            .. klua.platform().os .. "/" .. klua.platform().arch)
    end
    return 1
end

klua.register_provider("gh", github_install)

-- ---------------------------------------------------------------------------
-- GitLab provider: gl:user/repo[@tag]
-- ---------------------------------------------------------------------------

local gitlab_release_cache = {}

local function gitlab_release_for(user, name, tag)
    local key = strip_trailing_slash(klua.gitlab_api) .. "|" .. user .. "/" .. name
        .. "@" .. (tag or "latest")
    local cached = gitlab_release_cache[key]
    if cached then
        return cached
    end

    local project = user .. "%2F" .. name
    local endpoint = tag and ("releases/" .. tag) or "releases/permalink/latest"
    local api = klua.gitlab_api .. "/projects/" .. project .. "/" .. endpoint
    local body, status, err = klua.http_get(api)
    if err then
        return nil, "request failed: " .. err
    end
    if status == 200 then
        local release, json_err = klua.json_parse(body)
        if not release then
            return nil, "could not parse release JSON: " .. tostring(json_err)
        end
        gitlab_release_cache[key] = release
        return release
    end
    if status == 404 then
        return nil, "no release at " .. api
    end
    return nil, "GitLab API returned HTTP " .. tostring(status)
end

local function gitlab_install(rest, target_key)
    local repo, tag = string.match(rest, "^([^@]+)@(.+)$")
    if not repo then
        repo = rest
    end
    local user, name = string.match(repo, "^([%w_.-]+)/([%w_.-]+)$")
    if not user then
        klua.error("gl: expected 'user/repo' (optionally '@tag'), got '" .. rest .. "'")
        return 1
    end

    local key = target_key or ("gl:" .. repo)
    local flags = klua.cli_flags or {}
    local lock_entry, lock_failed = lock_entry_for(key, "gl")
    if lock_failed then
        return 1
    end
    if lock_entry and tag and lock_entry.version ~= tag then
        klua.error("--locked: requested tag '" .. tag .. "' for " .. key
            .. " but lockfile records '" .. tostring(lock_entry.version) .. "'")
        return 1
    end
    local resolved_tag = tag or (lock_entry and lock_entry.version) or nil

    local release = nil
    if lock_entry then
        klua.info("gl: using lockfile entry for " .. repo .. " " .. lock_entry.version)
        release = {
            tag_name = lock_entry.version,
            assets = {
                links = {{ name = lock_entry.asset, url = lock_entry.url }},
            },
        }
    else
        local release_err
        release, release_err = gitlab_release_for(user, name, resolved_tag)
        if not release then
            klua.warn("gl: release discovery failed (" .. tostring(release_err) .. ")")
        end
    end

    -- Re-read the manifest at the resolved tag so depends/settings match the
    -- release that is actually installed.
    local manifest = fetch_manifest(klua.raw_gitlab, user, name, resolved_tag, "gitlab")
    if release and release.tag_name and release.tag_name ~= resolved_tag then
        local tagged = fetch_manifest(klua.raw_gitlab, user, name, release.tag_name, "gitlab")
        if tagged then
            manifest = tagged
        end
    end
    if manifest then
        local code = install_dependencies(manifest)
        if code ~= 0 then
            return code
        end
    end

    if release then
        local version = release.tag_name or resolved_tag or "unknown"
        -- Normalize GitLab asset links into the GitHub asset shape.
        local assets = {}
        for _, link in ipairs((release.assets and release.assets.links) or {}) do
            assets[#assets + 1] = { name = link.name or "", browser_download_url = link.url }
        end
        local asset = lock_entry and assets[1] or select_asset(assets, manifest, klua.platform())
        if asset then
            klua.info("gl: " .. repo .. " " .. version .. " -> " .. asset.name)
            local asset_name = basename(asset.browser_download_url or asset.name)
            local payload = klua.paths.cache .. "/downloads/" .. asset_name
            local ok, dl_err = klua.download(asset.browser_download_url, payload)
            if not ok then
                klua.error("gl: download failed: " .. tostring(dl_err))
                return 1
            end

            local digest
            if lock_entry then
                local code = verify_locked_digest(payload, asset_name, lock_entry, "gl:" .. repo)
                if code ~= 0 then
                    return code
                end
                digest = lock_entry.sha256
            else
                local code = verify_checksum(payload, asset_name, assets, "gl:" .. repo)
                if code ~= 0 then
                    return code
                end
                if flags.lock then
                    local digest_err
                    digest, digest_err = klua.sha256(payload)
                    if not digest or digest_err then
                        klua.error("could not compute SHA-256 for " .. asset_name .. ": "
                            .. tostring(digest_err))
                        return 1
                    end
                    record_lock_entry(key, "gl", version, asset_name,
                        asset.browser_download_url, digest)
                end
            end

            local code = verify_payload(manifest, payload, asset_name, version, key, digest)
            if code ~= 0 then
                return code
            end

            local store_dir = klua.paths.store .. "/gl/" .. user .. "/" .. name .. "/" .. version
            return install_payload(payload, asset_name, store_dir, name, manifest)
        end
    end

    if manifest and type(manifest.build) == "table"
        and type(manifest.build.steps) == "table" and #manifest.build.steps > 0 then
        local code = flush_system_packages()
        if code ~= 0 then
            return code
        end
        local version = resolved_tag or "source"
        local store_dir = klua.paths.store .. "/gl/" .. user .. "/" .. name .. "/" .. version
        return build_from_source(klua.gitlab_clone, user, name, resolved_tag, manifest, store_dir)
    end

    if not release then
        klua.error("gl: no release found for " .. repo
            .. " (add build.steps to klua.yaml for source builds)")
    else
        klua.error("gl: no suitable release asset for "
            .. klua.platform().os .. "/" .. klua.platform().arch)
    end
    return 1
end

klua.register_provider("gl", gitlab_install)

-- ---------------------------------------------------------------------------
-- Direct URL provider: url:https://host/path/tool.tar.gz
-- ---------------------------------------------------------------------------

local function url_install(rest, target_key)
    if not string.match(rest, "^https?://") then
        klua.error("url: expected an http(s) URL, got '" .. rest .. "'")
        return 1
    end

    local key = target_key or ("url:" .. rest)
    local flags = klua.cli_flags or {}
    local lock_entry, lock_failed = lock_entry_for(key, "url")
    if lock_failed then
        return 1
    end
    local download_url = lock_entry and lock_entry.url or rest
    if not string.match(download_url, "^https?://") then
        klua.error("url: lockfile entry has an invalid URL for " .. key)
        return 1
    end

    local path_part = string.match(download_url, "^https?://[^/]+(/[^?#]*)") or "/"
    local asset_name = lock_entry and lock_entry.asset
        or basename(path_part)
    if asset_name == nil or asset_name == "" or asset_name == "/" then
        klua.error("url: could not derive a file name from '" .. download_url .. "'")
        return 1
    end
    local host = string.match(download_url, "^https?://([^/]+)") or "unknown-host"
    local stem = string.gsub(asset_name, "%.[^.]+$", "")
    stem = string.gsub(stem, "%.tar$", "")

    klua.info("url: downloading " .. download_url)
    local payload = klua.paths.cache .. "/downloads/" .. asset_name
    local ok, dl_err = klua.download(download_url, payload)
    if not ok then
        klua.error("url: download failed: " .. tostring(dl_err))
        return 1
    end

    local digest
    if lock_entry then
        local code = verify_locked_digest(payload, asset_name, lock_entry, "url")
        if code ~= 0 then
            return code
        end
        digest = lock_entry.sha256
    elseif flags.lock then
        local digest_err
        digest, digest_err = klua.sha256(payload)
        if not digest or digest_err then
            klua.error("could not compute SHA-256 for " .. asset_name .. ": "
                .. tostring(digest_err))
            return 1
        end
        record_lock_entry(key, "url", "direct", asset_name, download_url, digest)
    end

    local code = verify_payload(nil, payload, asset_name, "direct", key, digest)
    if code ~= 0 then
        return code
    end

    local store_dir = klua.paths.store .. "/url/" .. host .. "/" .. stem .. "/direct"
    return install_payload(payload, asset_name, store_dir, stem, nil)
end

klua.register_provider("url", url_install)

-- ---------------------------------------------------------------------------
-- Batch download prefetch (used by sync and upgrade)
--
-- Plans are resolved without extracting anything, then every archive URL is
-- downloaded by the native bounded worker pool. The normal providers still
-- run afterwards, but the download wrapper below returns the prefetched result
-- so an asset is fetched exactly once.
-- ---------------------------------------------------------------------------

local native_download = klua.download
local prefetched_downloads = {}

local function prefetch_key(url, dest)
    return url .. "\0" .. dest
end

local function download_cached(url, dest)
    local result = prefetched_downloads[prefetch_key(url, dest)]
    if result then
        return result.ok, result.error
    end
    return native_download(url, dest)
end
klua.download = download_cached

local function github_download_plan(rest, target_key)
    local repo, tag = string.match(rest, "^([^@]+)@(.+)$")
    if not repo then
        repo = rest
    end
    local user, name = string.match(repo, "^([%w_.-]+)/([%w_.-]+)$")
    if not user then
        return nil
    end
    local key = target_key or ("gh:" .. repo)
    local lock_entry, lock_failed = lock_entry_for(key, "gh")
    if lock_failed or (lock_entry and tag and lock_entry.version ~= tag) then
        return nil
    end
    local resolved_tag = tag or (lock_entry and lock_entry.version) or nil

    local release
    if lock_entry then
        release = {
            tag_name = lock_entry.version,
            assets = {{ name = lock_entry.asset, browser_download_url = lock_entry.url }},
        }
    else
        release = github_release_for(user, name, resolved_tag)
    end
    if not release then
        return nil
    end

    local manifest = fetch_manifest(klua.raw_github, user, name, resolved_tag)
    if release.tag_name and release.tag_name ~= resolved_tag then
        manifest = fetch_manifest(klua.raw_github, user, name, release.tag_name) or manifest
    end
    local assets = release.assets or {}
    local asset = lock_entry and assets[1]
        or select_asset(assets, manifest, klua.platform())
    if not asset or not asset.browser_download_url then
        return nil
    end
    return {
        url = asset.browser_download_url,
        path = klua.paths.cache .. "/downloads/" .. asset.name,
        label = "gh:" .. repo,
    }
end

local function gitlab_download_plan(rest, target_key)
    local repo, tag = string.match(rest, "^([^@]+)@(.+)$")
    if not repo then
        repo = rest
    end
    local user, name = string.match(repo, "^([%w_.-]+)/([%w_.-]+)$")
    if not user then
        return nil
    end
    local key = target_key or ("gl:" .. repo)
    local lock_entry, lock_failed = lock_entry_for(key, "gl")
    if lock_failed or (lock_entry and tag and lock_entry.version ~= tag) then
        return nil
    end
    local resolved_tag = tag or (lock_entry and lock_entry.version) or nil

    local release
    if lock_entry then
        release = {
            tag_name = lock_entry.version,
            assets = { links = {{ name = lock_entry.asset, url = lock_entry.url }} },
        }
    else
        release = gitlab_release_for(user, name, resolved_tag)
    end
    if not release then
        return nil
    end

    local manifest = fetch_manifest(klua.raw_gitlab, user, name, resolved_tag, "gitlab")
    if release.tag_name and release.tag_name ~= resolved_tag then
        manifest = fetch_manifest(klua.raw_gitlab, user, name, release.tag_name, "gitlab")
            or manifest
    end
    local assets = {}
    for _, link in ipairs((release.assets and release.assets.links) or {}) do
        assets[#assets + 1] = { name = link.name or "", browser_download_url = link.url }
    end
    local asset = lock_entry and assets[1]
        or select_asset(assets, manifest, klua.platform())
    if not asset or not asset.browser_download_url then
        return nil
    end
    local asset_name = basename(asset.browser_download_url or asset.name)
    return {
        url = asset.browser_download_url,
        path = klua.paths.cache .. "/downloads/" .. asset_name,
        label = "gl:" .. repo,
    }
end

local function url_download_plan(rest, target_key)
    if not string.match(rest, "^https?://") then
        return nil
    end
    local key = target_key or ("url:" .. rest)
    local lock_entry, lock_failed = lock_entry_for(key, "url")
    if lock_failed then
        return nil
    end
    local url = lock_entry and lock_entry.url or rest
    local path_part = string.match(url, "^https?://[^/]+(/[^?#]*)") or "/"
    local asset_name = lock_entry and lock_entry.asset or basename(path_part)
    if not asset_name or asset_name == "" or asset_name == "/" then
        return nil
    end
    return {
        url = url,
        path = klua.paths.cache .. "/downloads/" .. asset_name,
        label = key,
    }
end

local function plan_download(target)
    local scheme, rest = string.match(target, "^([%w][%w+_-]*):(.+)$")
    if not scheme then
        local resolved = resolve_alias(target)
        if not resolved then
            return nil
        end
        return plan_download(resolved)
    end
    if scheme == "gh" then
        return github_download_plan(rest, target)
    elseif scheme == "gl" then
        return gitlab_download_plan(rest, target)
    elseif scheme == "url" then
        return url_download_plan(rest, target)
    end
    return nil
end

local function prefetch_downloads(targets)
    local by_path, order = {}, {}
    for _, target in ipairs(targets) do
        local job = plan_download(target)
        if job then
            local previous = by_path[job.path]
            if previous == nil then
                by_path[job.path] = job
                order[#order + 1] = job.path
            elseif previous and previous.url ~= job.url then
                -- Two different assets share a cache filename; leave both to
                -- the normal sequential provider path instead of racing.
                by_path[job.path] = false
            end
        end
    end

    local jobs = {}
    for _, path in ipairs(order) do
        local job = by_path[path]
        if job then
            jobs[#jobs + 1] = job
        end
    end
    if #jobs == 0 then
        return
    end

    if #jobs == 1 then
        local job = jobs[1]
        local ok = native_download(job.url, job.path)
        if ok then
            prefetched_downloads[prefetch_key(job.url, job.path)] = { ok = true }
        end
        return
    end

    klua.info("batch: downloading " .. #jobs .. " asset(s) in parallel (max 8 workers)")
    local requests = {}
    for index, job in ipairs(jobs) do
        requests[index] = { url = job.url, dest = job.path }
    end
    local results = klua.download_batch(requests)
    for index, result in ipairs(results) do
        local job = jobs[index]
        if result.ok == true then
            prefetched_downloads[prefetch_key(job.url, job.path)] = { ok = true }
            klua.info("batch: " .. job.label .. " -> " .. basename(job.path))
        else
            -- Prefetch is best-effort: leave the cache empty so the normal
            -- provider path retries sequentially and reports its own error.
            klua.warn("batch download failed for " .. job.label .. ": "
                .. tostring(result.error))
        end
    end
end

-- ---------------------------------------------------------------------------
-- System package delegation (sys: and klua.yaml depends:)
--
-- Package names are validated and shell-quoted. Installation is idempotent:
-- status is checked first, and every missing package from one klua invocation
-- is installed with a single manager command instead of one sudo per package.
-- ---------------------------------------------------------------------------

local SYSTEM_SCHEMES = {
    apt = true, ["apt-get"] = true, dnf = true, yum = true,
    pacman = true, apk = true, brew = true, sys = true,
}

local SYSTEM_MANAGERS = {
    apt = {
        probe = "dpkg-query",
        status = function(pkg)
            return "dpkg-query -W -f='${Status}' " .. shq(pkg)
                .. " 2>/dev/null | grep -qx 'install ok installed'"
        end,
        install = "apt-get install -y -- %s",
        install_bin = "apt-get",
    },
    dnf = {
        probe = "dnf",
        status = function(pkg) return "rpm -q " .. shq(pkg) .. " >/dev/null 2>&1" end,
        install = "dnf install -y %s",
        install_bin = "dnf",
    },
    yum = {
        probe = "yum",
        status = function(pkg) return "rpm -q " .. shq(pkg) .. " >/dev/null 2>&1" end,
        install = "yum install -y %s",
        install_bin = "yum",
    },
    pacman = {
        probe = "pacman",
        status = function(pkg) return "pacman -Q " .. shq(pkg) .. " >/dev/null 2>&1" end,
        install = "pacman -S --noconfirm -- %s",
        install_bin = "pacman",
    },
    apk = {
        probe = "apk",
        status = function(pkg) return "apk info -e " .. shq(pkg) .. " >/dev/null 2>&1" end,
        install = "apk add %s",
        install_bin = "apk",
    },
    brew = {
        probe = "brew",
        status = function(pkg) return "brew list " .. shq(pkg) .. " >/dev/null 2>&1" end,
        install = "brew install %s",
        install_bin = "brew",
    },
}

local system_queue = {}
local system_seen = {}

local function detect_system_manager()
    local configured = klua.system.manager
    if configured ~= nil then
        if type(configured) == "string" and configured ~= "" then
            local lower = string.lower(configured)
            local has_custom_hooks = type(klua.system.status) == "function"
                and type(klua.system.install) == "function"
            if not SYSTEM_MANAGERS[lower] and not has_custom_hooks then
                klua.error("unknown system package manager '" .. configured .. "'")
                return nil
            end
            return lower
        end
        klua.error("klua.system.manager must be a non-empty string")
        return nil
    end
    for _, name in ipairs({"apt", "dnf", "yum", "pacman", "apk", "brew"}) do
        local spec = SYSTEM_MANAGERS[name]
        if klua.exec("command -v " .. spec.probe .. " >/dev/null 2>&1") == 0 then
            return name
        end
    end
    klua.error("could not detect a supported system package manager; "
        .. "set klua.system.manager in init.lua")
    return nil
end

local function parse_system_packages(rest)
    local packages, seen = {}, {}
    local normalized = string.gsub(tostring(rest or ""), ",", " ")
    for name in string.gmatch(normalized, "%S+") do
        if not string.match(name, "^[%w][%w.+_:-]*$") then
            klua.error("invalid system package name '" .. name .. "'")
            return nil
        end
        if not seen[name] then
            seen[name] = true
            packages[#packages + 1] = name
        end
    end
    if #packages == 0 then
        klua.error("sys: expected one or more package names")
        return nil
    end
    return packages
end

local function system_package_installed(manager, pkg)
    if type(klua.system.status) == "function" then
        local result = klua.system.status(pkg)
        return result == true or result == 0
    end
    if type(klua.system.status_cmd) == "string" then
        return klua.exec(string.format(klua.system.status_cmd, shq(pkg))) == 0
    end
    return klua.exec(SYSTEM_MANAGERS[manager].status(pkg)) == 0
end

local function sudo_prefix(manager)
    if manager == "brew" then
        return ""
    end
    if klua.exec("id -u") == 0 then
        return ""
    end
    if klua.exec("command -v sudo >/dev/null 2>&1") == 0 then
        return "sudo "
    end
    klua.warn("not root and sudo is unavailable; system install may fail")
    return ""
end

local function install_system_batch(manager, packages)
    if type(klua.system.install) == "function" then
        local result = klua.system.install(packages)
        return result == true and 0 or (type(result) == "number" and result or 1)
    end
    if type(klua.system.install_cmd) == "string" then
        local quoted = {}
        for _, pkg in ipairs(packages) do
            quoted[#quoted + 1] = shq(pkg)
        end
        return klua.exec(string.format(klua.system.install_cmd, table.concat(quoted, " ")))
    end
    local spec = SYSTEM_MANAGERS[manager]
    local quoted = {}
    for _, pkg in ipairs(packages) do
        quoted[#quoted + 1] = shq(pkg)
    end
    local prefix = sudo_prefix(manager)
    if spec.install_bin and klua.exec("command -v " .. spec.install_bin .. " >/dev/null 2>&1") ~= 0 then
        klua.error("system package manager '" .. spec.install_bin .. "' is not available")
        return 1
    end
    local command = prefix .. string.format(spec.install, table.concat(quoted, " "))
    klua.info("sys: " .. command)
    return klua.exec(command)
end

local function queue_system_packages(packages)
    local added = 0
    for _, pkg in ipairs(packages) do
        if not system_seen[pkg] then
            system_seen[pkg] = true
            system_queue[#system_queue + 1] = pkg
            added = added + 1
        end
    end
    return added
end

flush_system_packages = function()
    if #system_queue == 0 then
        return 0
    end
    local queued = system_queue
    system_queue = {}
    local manager = detect_system_manager()
    if not manager then
        return 1
    end

    local missing = {}
    for _, pkg in ipairs(queued) do
        if system_package_installed(manager, pkg) then
            klua.info("sys: '" .. pkg .. "' is already installed")
        else
            missing[#missing + 1] = pkg
        end
    end

    if #missing == 0 then
        klua.info("sys: all " .. #queued .. " requested package(s) are already installed")
        return 0
    end

    klua.info("sys: installing " .. #missing .. " missing package(s) with " .. manager
        .. ": " .. table.concat(missing, ", "))
    if install_system_batch(manager, missing) ~= 0 then
        klua.error("sys: failed to install package(s): " .. table.concat(missing, ", "))
        return 1
    end

    local failed = {}
    for _, pkg in ipairs(missing) do
        if not system_package_installed(manager, pkg) then
            failed[#failed + 1] = pkg
        end
    end
    if #failed > 0 then
        klua.warn("sys: package(s) still not available after install: " .. table.concat(failed, ", "))
        return 1
    end
    klua.info("sys: installed " .. #missing .. " package(s)")
    return 0
end

local function system_install(rest)
    local packages = parse_system_packages(rest)
    if not packages then
        return 1
    end
    queue_system_packages(packages)
    return 0
end

klua.register_provider("sys", system_install)
for _, scheme in ipairs({"apt", "apt-get", "dnf", "yum", "pacman", "apk", "brew"}) do
    klua.register_provider(scheme, system_install)
end

-- Manifest `depends:` entries: plain names and sys:/apt: aliases are batched;
-- other targets are installed through their own provider.
local function manifest_dependency_list(manifest)
    local value = manifest and manifest.depends
    local items = {}
    if type(value) == "string" then
        items[1] = value
    elseif type(value) == "table" then
        if value[1] ~= nil then
            for _, item in ipairs(value) do
                if type(item) == "string" then
                    items[#items + 1] = item
                elseif type(item) == "table" and type(item.target) == "string" then
                    items[#items + 1] = item.target
                end
            end
        else
            for _, key in ipairs({"system", "packages"}) do
                local group = value[key]
                if type(group) == "string" then
                    items[#items + 1] = group
                elseif type(group) == "table" then
                    for _, item in ipairs(group) do
                        if type(item) == "string" then
                            items[#items + 1] = item
                        end
                    end
                end
            end
        end
    end
    return items
end

install_dependencies = function(manifest)
    local opts = klua.install_opts or {}
    opts._dependency_seen = opts._dependency_seen or {}
    for _, item in ipairs(manifest_dependency_list(manifest)) do
        local scheme = string.match(item, "^([%w][%w+_-]*):")
        if not scheme or SYSTEM_SCHEMES[scheme] then
            local packages = parse_system_packages(scheme and string.match(item, "^[%w][%w+_-]*:(.+)$") or item)
            if not packages then
                return 1
            end
            queue_system_packages(packages)
        else
            if not opts._dependency_seen[item] then
                opts._dependency_seen[item] = true
                local code = install_one(item)
                if code ~= 0 then
                    return code
                end
            end
        end
    end
    return 0
end

-- ---------------------------------------------------------------------------
-- Install dispatch
-- ---------------------------------------------------------------------------

local function install_one(target)
    local scheme, rest = string.match(target, "^([%w][%w+_-]*):(.+)$")
    if not scheme then
        local resolved, err, candidates = resolve_alias(target)
        if not resolved then
            local suggestion = closest_match(target, candidates or {})
            if suggestion then
                klua.warn("did you mean '" .. suggestion .. "'?")
            end
            klua.error(err)
            return 1
        end
        klua.info("resolved '" .. target .. "' -> " .. resolved)
        return install_one(resolved)
    end

    local provider = klua.providers[scheme]
    if not provider then
        klua.error("no provider registered for scheme '" .. scheme .. "'")
        return 1
    end
    if (klua.cli_flags or {}).locked and scheme ~= "sys"
        and not SYSTEM_SCHEMES[scheme] then
        local _, failed = lock_entry_for(target)
        if failed then
            return 1
        end
    end
    local ok, result = pcall(provider, rest, target)
    if not ok then
        klua.error("provider '" .. scheme .. "' failed: " .. tostring(result))
        return 1
    end
    if type(result) == "number" then
        return result
    end
    return 0
end

-- ---------------------------------------------------------------------------
-- Store introspection (shared by list and upgrade)
-- ---------------------------------------------------------------------------

local function installed_packages()
    local result = {}
    for _, provider in ipairs(klua.list_dir(klua.paths.store)) do
        if provider.is_dir then
            for _, user in ipairs(klua.list_dir(provider.path)) do
                if user.is_dir then
                    for _, repo in ipairs(klua.list_dir(user.path)) do
                        if repo.is_dir then
                            for _, version in ipairs(klua.list_dir(repo.path)) do
                                if version.is_dir then
                                    result[#result + 1] = {
                                        provider = provider.name,
                                        user = user.name,
                                        repo = repo.name,
                                        version = version.name,
                                        target = provider.name .. ":" .. user.name .. "/" .. repo.name,
                                    }
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return result
end

-- Natural (digit-aware) version comparison: 1.10.0 sorts after 1.9.0.
local function natural_version_less(a, b)
    local i, j = 1, 1
    while i <= #a and j <= #b do
        local da, db = string.match(a, "^%d+", i), string.match(b, "^%d+", j)
        if da and db then
            local va, vb = tonumber(da), tonumber(db)
            if va ~= vb then
                return va < vb
            end
            i, j = i + #da, j + #db
        else
            local ca, cb = string.sub(a, i, i), string.sub(b, j, j)
            if ca ~= cb then
                return ca < cb
            end
            i, j = i + 1, j + 1
        end
    end
    return (#a - i) < (#b - j)
end

local function sorted_versions(entries)
    local copy = {}
    for _, entry in ipairs(entries) do
        if entry.is_dir then
            copy[#copy + 1] = entry
        end
    end
    table.sort(copy, function(a, b)
        return natural_version_less(a.name, b.name)
    end)
    return copy
end

-- Latest stored version for a scheme target (nil when not installed).
local function current_version(target)
    local scheme, user, repo = string.match(target, "^([%w][%w+_-]*):([^/@]+)/([^/@]+)")
    if not scheme then
        return nil
    end
    local versions = sorted_versions(
        klua.list_dir(klua.paths.store .. "/" .. scheme .. "/" .. user .. "/" .. repo))
    if #versions == 0 then
        return nil
    end
    return versions[#versions].name
end

-- ---------------------------------------------------------------------------
-- packages.yaml helpers (add / sync)
-- ---------------------------------------------------------------------------

local function yaml_quote(value)
    local escaped = string.gsub(value, "\\", "\\\\")
    escaped = string.gsub(escaped, '"', '\\"')
    return '"' .. escaped .. '"'
end

local function load_packages_file()
    local includes, packages = {}, {}
    if klua.file_exists(klua.paths.packages) then
        local content = klua.read_file(klua.paths.packages)
        local doc = content and klua.yaml_parse(content)
        if type(doc) == "table" then
            if type(doc.includes) == "table" then
                includes = doc.includes
            end
            if type(doc.packages) == "table" then
                packages = doc.packages
            end
        end
    end
    return includes, packages
end

local function save_packages_file(includes, packages)
    local lines = {}
    if #includes > 0 then
        lines[#lines + 1] = "includes:"
        for _, url in ipairs(includes) do
            lines[#lines + 1] = "  - " .. yaml_quote(url)
        end
    end
    lines[#lines + 1] = "packages:"
    for _, target in ipairs(packages) do
        lines[#lines + 1] = "  - " .. yaml_quote(target)
    end
    local ok, err = klua.write_file(klua.paths.packages, table.concat(lines, "\n") .. "\n")
    if not ok then
        klua.error("could not write packages.yaml: " .. tostring(err))
        return false
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Reproducible lockfile (packages.lock.yaml)
--
-- The lockfile maps a canonical scheme target to the exact resolution used by
-- a successful install: version/tag, selected asset, its URL and SHA-256.
-- `--lock` records those values; `--locked` requires them and never performs
-- fresh release discovery.
-- ---------------------------------------------------------------------------

local function canonical_lock_target(target)
    local scheme, rest = string.match(target, "^([%w][%w+_-]*):(.+)$")
    if scheme == "gh" or scheme == "gl" then
        local repo = string.match(rest, "^([^@]+)") or rest
        return scheme .. ":" .. repo
    end
    return target
end

local function load_lockfile()
    if klua.lockfile.loaded then
        return true
    end
    local entries = {}
    if klua.file_exists(klua.paths.lock) then
        local content = klua.read_file(klua.paths.lock) or ""
        local doc, parse_err = klua.yaml_parse(content)
        if parse_err then
            klua.error("could not parse " .. klua.paths.lock .. ": " .. tostring(parse_err))
            return false
        end
        if type(doc) == "table" and type(doc.entries) == "table" then
            for key, entry in pairs(doc.entries) do
                if type(key) == "string" and type(entry) == "table" then
                    entries[key] = entry
                end
            end
        end
    end
    klua.lockfile.entries = entries
    klua.lockfile.loaded = true
    return true
end

local function require_lockfile()
    if not klua.file_exists(klua.paths.lock) then
        klua.error("no " .. klua.paths.lock .. " found; run with --lock first")
        return false
    end
    return load_lockfile()
end

local function valid_sha256(value)
    return type(value) == "string" and string.match(value, "^%x+$") ~= nil and #value == 64
end

lock_entry_for = function(target, provider)
    local flags = klua.cli_flags or {}
    if not flags.locked then
        return nil
    end
    if not load_lockfile() then
        return nil
    end
    local key = canonical_lock_target(target)
    local entry = klua.lockfile.entries[key]
    if not entry then
        klua.error("--locked: no lock entry for '" .. key .. "' in " .. klua.paths.lock)
        return nil, true
    end
    if provider and entry.provider ~= provider then
        klua.error("--locked: '" .. key .. "' is locked to provider '"
            .. tostring(entry.provider) .. "', not '" .. provider .. "'")
        return nil, true
    end
    if not valid_sha256(entry.sha256) then
        klua.error("--locked: invalid sha256 for '" .. key .. "'")
        return nil, true
    end
    if type(entry.url) ~= "string" or entry.url == "" then
        klua.error("--locked: missing asset URL for '" .. key .. "'")
        return nil, true
    end
    return entry
end

record_lock_entry = function(target, provider, version, asset, url, sha256)
    local flags = klua.cli_flags or {}
    if not flags.lock then
        return
    end
    if not load_lockfile() then
        return
    end
    if not valid_sha256(sha256) then
        klua.warn("not locking '" .. target .. "': invalid SHA-256 digest")
        return
    end
    local key = canonical_lock_target(target)
    klua.lockfile.entries[key] = {
        provider = provider,
        version = tostring(version or ""),
        asset = tostring(asset or ""),
        url = tostring(url or ""),
        sha256 = string.lower(sha256),
    }
end

local function save_lockfile()
    local flags = klua.cli_flags or {}
    if not flags.lock then
        return 0
    end
    if not load_lockfile() then
        return 1
    end
    local keys = {}
    for key in pairs(klua.lockfile.entries) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    local lines = {
        "# Generated by klua sync/install --lock; do not edit by hand.",
        "version: 1",
        "entries:",
    }
    for _, key in ipairs(keys) do
        local entry = klua.lockfile.entries[key]
        lines[#lines + 1] = "  " .. yaml_quote(key) .. ":"
        lines[#lines + 1] = "    provider: " .. yaml_quote(tostring(entry.provider or ""))
        lines[#lines + 1] = "    version: " .. yaml_quote(tostring(entry.version or ""))
        lines[#lines + 1] = "    asset: " .. yaml_quote(tostring(entry.asset or ""))
        lines[#lines + 1] = "    url: " .. yaml_quote(tostring(entry.url or ""))
        lines[#lines + 1] = "    sha256: " .. yaml_quote(tostring(entry.sha256 or ""))
    end
    local ok, err = klua.write_file(klua.paths.lock, table.concat(lines, "\n") .. "\n")
    if not ok then
        klua.error("could not write " .. klua.paths.lock .. ": " .. tostring(err))
        return 1
    end
    klua.info("lockfile updated: " .. klua.paths.lock)
    return 0
end

verify_locked_digest = function(payload, asset_name, entry, label)
    -- Locked digests are always enforced. --locked and --skip-checksum are
    -- rejected by the CLI, and this helper must fail closed even if called
    -- directly from custom Lua.
    local actual, err = klua.sha256(payload)
    if not actual or err then
        klua.error("could not compute SHA-256 for " .. asset_name .. ": " .. tostring(err))
        return 1
    end
    if string.lower(actual) ~= string.lower(entry.sha256) then
        klua.error("SHA-256 mismatch for " .. asset_name .. ": expected "
            .. entry.sha256 .. ", got " .. string.lower(actual) .. " (lockfile " .. label .. ")")
        return 1
    end
    klua.info("sha256 verified for " .. asset_name .. " (lockfile)")
    return 0
end

-- Custom providers can opt into the same lockfile policy by calling these
-- helpers with their resolved version, asset URL and digest.
klua.lockfile.require = require_lockfile
klua.lockfile.get = lock_entry_for
klua.lockfile.record = record_lock_entry
klua.lockfile.verify = verify_locked_digest
klua.lockfile.save = save_lockfile

-- ---------------------------------------------------------------------------
-- Command handlers
-- ---------------------------------------------------------------------------

function klua.commands.install(args)
    local flags = klua.cli_flags or {}
    if flags.locked and not require_lockfile() then
        return 1
    end
    local force = false
    local as_name = nil
    local targets = {}
    local index = 1
    while index <= #args do
        local arg = args[index]
        if arg == "--force" then
            force = true
        elseif arg == "--as" then
            index = index + 1
            as_name = args[index]
            if not as_name then
                klua.error("--as requires a command name")
                return 1
            end
        else
            targets[#targets + 1] = arg
        end
        index = index + 1
    end
    if #targets == 0 then
        klua.error("usage: klua install [--force] [--as NAME] [--lock|--locked] <target> [<target>...]")
        return 1
    end
    if as_name then
        if as_name == "" or as_name == "." or as_name == ".."
            or string.find(as_name, "/") or string.find(as_name, "%c") then
            klua.error("invalid --as name: '" .. as_name .. "'")
            return 1
        end
        if #targets > 1 then
            klua.error("--as can only be used with a single target")
            return 1
        end
    end

    local saved = klua.install_opts
    klua.install_opts = { force = force, link = true, as = as_name, _dependency_seen = {} }
    local status = 0
    for _, target in ipairs(targets) do
        local code = install_one(target)
        if code ~= 0 then
            status = code
        end
    end
    local system_status = flush_system_packages()
    if system_status ~= 0 and status == 0 then
        status = system_status
    end
    if status == 0 then
        local lock_status = save_lockfile()
        if lock_status ~= 0 then
            status = lock_status
        end
    end
    klua.install_opts = saved
    return status
end

function klua.commands.add(args)
    if #args == 0 then
        klua.error("usage: klua add <target> [<target>...]")
        return 1
    end
    local includes, packages = load_packages_file()
    for _, target in ipairs(args) do
        packages[#packages + 1] = target
    end
    packages = dedupe(packages)
    if not save_packages_file(includes, packages) then
        return 1
    end
    klua.info("packages.yaml updated (" .. #packages .. " target(s))")
    return 0
end

-- Resolve a scheme target to its store directory (provider + package path,
-- no version). Mirrors the layouts used by the install providers.
local function store_path_for(scheme, rest)
    if scheme == "gh" or scheme == "gl" then
        local repo = string.match(rest, "^([^@]+)") or rest
        local user, name = string.match(repo, "^([^/]+)/([^/]+)$")
        if not user then
            return nil
        end
        return klua.paths.store .. "/" .. scheme .. "/" .. user .. "/" .. name
    elseif scheme == "url" then
        local path_part = string.match(rest, "^https?://[^/]+(/[^?#]*)") or "/"
        local asset_name = basename(path_part)
        if asset_name == "" or asset_name == "/" then
            return nil
        end
        local host = string.match(rest, "^https?://([^/]+)") or "unknown-host"
        local stem = string.gsub(asset_name, "%.[^.]+$", "")
        stem = string.gsub(stem, "%.tar$", "")
        return klua.paths.store .. "/url/" .. host .. "/" .. stem .. "/direct"
    end
    return nil
end

-- Drop removed targets (and their resolved/untagged forms) from packages.yaml.
local function prune_packages(removed)
    local includes, packages = load_packages_file()
    local kept = {}
    for _, existing in ipairs(packages) do
        if not removed[existing] then
            kept[#kept + 1] = existing
        end
    end
    if #kept ~= #packages then
        return save_packages_file(includes, kept)
    end
    return true
end

function klua.commands.remove(args)
    if #args == 0 then
        klua.error("usage: klua remove <target> [<target>...]")
        return 1
    end

    local removed = {}
    local status = 0
    for _, arg in ipairs(args) do
        local scheme, rest = string.match(arg, "^([%w][%w+_-]*):(.+)$")
        local resolved = arg
        if not scheme then
            local alias_target, err, candidates = resolve_alias(arg)
            if not alias_target then
                local match = closest_match(arg, candidates or {})
                if match then
                    klua.warn("did you mean '" .. match .. "'?")
                end
                klua.error(err)
                status = 1
            else
                resolved = alias_target
                scheme, rest = string.match(resolved, "^([%w][%w+_-]*):(.+)$")
            end
        end

        if scheme then
            local store_dir = store_path_for(scheme, rest)
            if not store_dir or not klua.file_exists(store_dir) then
                klua.error("package not installed: " .. arg)
                status = 1
            else
                local links = {}
                for _, entry in ipairs(klua.list_dir(klua.paths.bin)) do
                    if not entry.is_dir then
                        local target = klua.readlink(entry.path)
                        if target and (target == store_dir
                            or string.sub(target, 1, #store_dir + 1) == store_dir .. "/") then
                            local ok, err = klua.remove(entry.path)
                            if not ok then
                                klua.error(tostring(err))
                                status = 1
                            else
                                links[#links + 1] = entry.name
                            end
                        end
                    end
                end

                local ok, err = klua.remove(store_dir)
                if not ok then
                    klua.error(tostring(err))
                    status = 1
                else
                    local suffix = #links > 0 and (" (" .. table.concat(links, ", ") .. ")") or ""
                    klua.info("removed " .. scheme .. ":" .. rest .. suffix)
                    removed[arg] = true
                    removed[resolved] = true
                    local untagged = string.match(rest, "^([^@]+)")
                    if untagged then
                        removed[scheme .. ":" .. untagged] = true
                    end
                end
            end
        end
    end

    if next(removed) and not prune_packages(removed) then
        return 1
    end
    return status
end

-- ---------------------------------------------------------------------------
-- Shared helpers for run / info / cleanup / doctor
-- ---------------------------------------------------------------------------

-- Symlinks in ~/.local/bin that point into a package's store path.
local function linked_binaries(store_base)
    local base = normalize_dir(store_base)
    local links = {}
    for _, entry in ipairs(klua.list_dir(klua.paths.bin)) do
        if not entry.is_dir then
            local target = klua.readlink(entry.path)
            if target and (target == base or string.sub(target, 1, #base + 1) == base .. "/") then
                links[#links + 1] = entry.name
            end
        end
    end
    return links
end

-- Full store directory of the newest installed version (nil when missing).
-- For `url:` packages the store path already ends in `/direct`.
local function package_dir_for(scheme, rest)
    local base = store_path_for(scheme, rest)
    if not base then
        return nil
    end
    if scheme == "url" then
        return klua.is_dir(base) and base or nil
    end
    local versions = sorted_versions(klua.list_dir(base))
    if #versions == 0 then
        return nil
    end
    return versions[#versions].path
end

-- Resolve an alias or a scheme target into (scheme, rest, resolved_target).
local function resolve_target(arg)
    local scheme, rest = string.match(arg, "^([%w][%w+_-]*):(.+)$")
    if scheme then
        return scheme, rest, arg
    end
    local resolved, err, candidates = resolve_alias(arg)
    if not resolved then
        local suggestion = closest_match(arg, candidates or {})
        if suggestion then
            klua.warn("did you mean '" .. suggestion .. "'?")
        end
        return nil, nil, nil, err
    end
    scheme, rest = string.match(resolved, "^([%w][%w+_-]*):(.+)$")
    return scheme, rest, resolved
end

-- Execute a store binary with the store's libraries isolated to this process
-- (never linked into system paths).
local function execute_from_store(binary, store_dir, extra_args)
    local dirs, seen = {}, {}
    local function add_dir(dir)
        if dir and dir ~= "" and not seen[dir] and klua.is_dir(dir) then
            seen[dir] = true
            dirs[#dirs + 1] = dir
        end
    end

    add_dir(dirname(binary))
    add_dir(store_dir .. "/bin")
    add_dir(store_dir .. "/sbin")

    -- Collect lib/lib64/lib32 directories up to two levels deep.
    local lib_dirs, seen_lib = {}, {}
    local function add_lib(dir)
        if klua.is_dir(dir) and not seen_lib[dir] then
            seen_lib[dir] = true
            lib_dirs[#lib_dirs + 1] = dir
        end
    end
    add_lib(store_dir)
    add_lib(store_dir .. "/lib")
    add_lib(store_dir .. "/lib64")
    add_lib(store_dir .. "/lib32")
    local function scan_libs(root, depth)
        if depth > 2 then
            return
        end
        for _, entry in ipairs(klua.list_dir(root)) do
            if entry.is_dir then
                local name = entry.name
                if name == "lib" or name == "lib64" or name == "lib32" then
                    add_lib(entry.path)
                end
                if name ~= "lib" and name ~= "lib64" and name ~= "lib32" then
                    scan_libs(entry.path, depth + 1)
                end
            end
        end
    end
    scan_libs(store_dir, 0)

    local lib_path = table.concat(lib_dirs, ":")
    local existing_lib = klua.env("LD_LIBRARY_PATH")
    if existing_lib and existing_lib ~= "" then
        lib_path = lib_path .. ":" .. existing_lib
    end

    local path_entries = { dirname(binary), store_dir .. "/bin", store_dir .. "/sbin" }
    local path_value = table.concat(path_entries, ":")
    local existing_path = klua.env("PATH")
    if existing_path and existing_path ~= "" then
        path_value = path_value .. ":" .. existing_path
    end

    local env_parts = {}
    if klua.platform().os == "macos" then
        local existing_dyld = klua.env("DYLD_LIBRARY_PATH")
        if existing_dyld and existing_dyld ~= "" then
            lib_path = lib_path .. ":" .. existing_dyld
        end
        env_parts[#env_parts + 1] = "DYLD_LIBRARY_PATH=" .. shq(lib_path)
    else
        env_parts[#env_parts + 1] = "LD_LIBRARY_PATH=" .. shq(lib_path)
    end
    env_parts[#env_parts + 1] = "PATH=" .. shq(path_value)

    local parts = { "env" }
    for _, assignment in ipairs(env_parts) do
        parts[#parts + 1] = assignment
    end
    parts[#parts + 1] = shq(binary)
    for _, arg in ipairs(extra_args or {}) do
        parts[#parts + 1] = shq(arg)
    end
    return klua.exec(table.concat(parts, " "))
end

-- ---------------------------------------------------------------------------
-- klua run <target> [args...]
-- ---------------------------------------------------------------------------

function klua.commands.run(args)
    if #args == 0 then
        klua.error("usage: klua run <target> [--] [args...]")
        return 1
    end

    local target = args[1]
    local extra = {}
    for index = 2, #args do
        extra[#extra + 1] = args[index]
    end

    local scheme, rest, resolved, err = resolve_target(target)
    if not scheme then
        klua.error(err)
        return 1
    end

    local dir = package_dir_for(scheme, rest)
    if not dir then
        klua.info("installing '" .. target .. "' for this run (store only, no links)")
        local saved = klua.install_opts
        klua.install_opts = { force = false, link = false, _dependency_seen = {} }
        local code = install_one(resolved)
        if code == 0 then
            code = flush_system_packages()
        end
        klua.install_opts = saved
        if code ~= 0 then
            return code
        end
        dir = package_dir_for(scheme, rest)
    end
    if not dir then
        klua.error("could not locate installed package for '" .. target .. "'")
        return 1
    end

    local candidates = {}
    for _, path in ipairs(klua.find_executables(dir)) do
        local name = basename(path)
        if not is_library_name(name) then
            klua.chmod_exec(path)
            candidates[#candidates + 1] = path
        end
    end
    if #candidates == 0 then
        klua.error("no runnable binary found in " .. dir)
        return 1
    end

    local preferred = nil
    if scheme == "gh" or scheme == "gl" then
        preferred = string.match(rest, "^[^@]+/([^@/]+)")
    end
    local binary = pick_binary(candidates, preferred)
    return execute_from_store(binary, dir, extra)
end

-- ---------------------------------------------------------------------------
-- klua search <query>
-- ---------------------------------------------------------------------------

local SEARCH_SHARDS = { "_" }
for character in string.gmatch("abcdefghijklmnopqrstuvwxyz", ".") do
    SEARCH_SHARDS[#SEARCH_SHARDS + 1] = character
end

function klua.commands.search(args)
    local query = args[1]
    if not query or query == "" then
        klua.error("usage: klua search <query>")
        return 1
    end

    local registries = all_registries()
    if #registries == 0 then
        klua.error("no registries configured; add one with 'klua tap add <url>'")
        return 1
    end

    local needle = string.lower(query)
    local aliases, order = {}, {}
    local reachable = 0
    for _, base in ipairs(registries) do
        local base_reachable = false
        local urls = {}
        for _, shard in ipairs(SEARCH_SHARDS) do
            urls[#urls + 1] = strip_trailing_slash(base) .. "/v1/" .. shard .. ".yaml"
        end
        local bodies = fetch_shards_batch(urls)
        for _, shard in ipairs(SEARCH_SHARDS) do
            local url = strip_trailing_slash(base) .. "/v1/" .. shard .. ".yaml"
            local result = bodies[url] or { error = "shard fetch failed" }
            local body = result.body
            if body then
                base_reachable = true
                local doc, parse_err = klua.yaml_parse(body)
                if doc and type(doc) == "table" then
                    for alias, target in pairs(doc) do
                        if type(alias) == "string" and type(target) == "string"
                            and aliases[alias] == nil then
                            aliases[alias] = target
                            order[#order + 1] = alias
                        end
                    end
                elseif parse_err then
                    klua.warn("registry " .. base .. " returned invalid YAML: " .. parse_err)
                end
            end
        end
        if base_reachable then
            reachable = reachable + 1
        end
    end

    if reachable == 0 then
        klua.error("could not fetch any registry shards; check your network or taps")
        return 1
    end

    table.sort(order)
    local matches = 0
    for _, alias in ipairs(order) do
        local target = aliases[alias]
        if string.find(string.lower(alias), needle, 1, true)
            or string.find(string.lower(target), needle, 1, true) then
            matches = matches + 1
            local padding = string.rep(" ", math.max(1, 20 - #alias))
            klua.info(alias .. padding .. target)
        end
    end
    if matches == 0 then
        klua.info("no packages matched '" .. query .. "'")
    end
    return 0
end

-- ---------------------------------------------------------------------------
-- klua info <target>
-- ---------------------------------------------------------------------------

function klua.commands.info(args)
    local target = args[1]
    if not target or target == "" then
        klua.error("usage: klua info <target>")
        return 1
    end

    local scheme, rest, resolved, err = resolve_target(target)
    if not scheme then
        klua.error(err)
        return 1
    end

    klua.info("package:  " .. (resolved ~= target and target or resolved))
    if resolved ~= target then
        klua.info("target:   " .. resolved)
    end
    klua.info("provider: " .. scheme)

    local base = store_path_for(scheme, rest)
    if not base then
        klua.error("unsupported target: " .. resolved)
        return 1
    end

    local versions = {}
    if scheme == "url" then
        if klua.is_dir(base) then
            versions[1] = "direct"
        end
    else
        for _, entry in ipairs(sorted_versions(klua.list_dir(base))) do
            versions[#versions + 1] = entry.name
        end
    end
    klua.info("installed: " .. (#versions > 0 and table.concat(versions, ", ") or "no"))
    klua.info("store:    " .. base .. (scheme == "url" and "" or "/<version>"))

    local links = linked_binaries(base)
    klua.info("linked:   " .. (#links > 0 and table.concat(links, ", ") or "none"))

    if scheme == "gh" or scheme == "gl" then
        local user, name = string.match(rest, "^([^/@]+)/([^@/]+)")
        local tag = string.match(rest, "@(.+)$")
        if user then
            local api
            if scheme == "gh" then
                api = klua.github_api .. "/repos/" .. user .. "/" .. name
                    .. "/releases/" .. (tag and ("tags/" .. tag) or "latest")
            else
                api = klua.gitlab_api .. "/projects/" .. user .. "%2F" .. name .. "/"
                    .. (tag and ("releases/" .. tag) or "releases/permalink/latest")
            end
            local body, status, request_err = klua.http_get(api)
            if request_err then
                klua.warn("could not query release metadata: " .. request_err)
            elseif status == 200 then
                local doc = klua.json_parse(body)
                if type(doc) == "table" then
                    klua.info("release:  " .. tostring(doc.tag_name or doc.name or "unknown"))
                    local assets = 0
                    if scheme == "gh" and type(doc.assets) == "table" then
                        assets = #doc.assets
                    elseif scheme == "gl" and type(doc.assets) == "table"
                        and type(doc.assets.links) == "table" then
                        assets = #doc.assets.links
                    end
                    klua.info("assets:   " .. assets)
                end
            elseif status == 404 then
                klua.info("release:  none")
            else
                klua.warn("release query returned HTTP " .. tostring(status))
            end
        end
    elseif scheme == "url" then
        klua.info("url:      " .. rest)
    end
    return 0
end

-- ---------------------------------------------------------------------------
-- klua cleanup
-- ---------------------------------------------------------------------------

function klua.commands.cleanup(args)
    local removed_versions, broken_links, library_links, cache_removed = 0, 0, 0, 0
    local status = 0

    for _, provider in ipairs(klua.list_dir(klua.paths.store)) do
        if provider.is_dir then
            for _, user in ipairs(klua.list_dir(provider.path)) do
                if user.is_dir then
                    for _, repo in ipairs(klua.list_dir(user.path)) do
                        if repo.is_dir then
                            local versions = sorted_versions(klua.list_dir(repo.path))
                            for index = 1, #versions - 1 do
                                local ok, err = klua.remove(versions[index].path)
                                if ok then
                                    removed_versions = removed_versions + 1
                                    klua.info("removed old version " .. versions[index].path)
                                else
                                    klua.error("could not remove " .. versions[index].path
                                        .. ": " .. tostring(err))
                                    status = 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    for _, entry in ipairs(klua.list_dir(klua.paths.bin)) do
        if not entry.is_dir then
            local target = klua.readlink(entry.path)
            if target then
                if is_library_name(entry.name) then
                    local ok = klua.remove(entry.path)
                    if ok then
                        library_links = library_links + 1
                        klua.info("removed library link " .. entry.path)
                    else
                        status = 1
                    end
                elseif is_under_store(target) and not klua.file_exists(target) then
                    local ok = klua.remove(entry.path)
                    if ok then
                        broken_links = broken_links + 1
                        klua.info("removed broken link " .. entry.path)
                    else
                        status = 1
                    end
                end
            end
        end
    end

    for _, subdir in ipairs({ "downloads", "build" }) do
        local path = klua.paths.cache .. "/" .. subdir
        if klua.is_dir(path) then
            local ok = klua.remove(path)
            if ok then
                cache_removed = cache_removed + 1
            else
                status = 1
            end
        end
    end

    klua.info("cleanup: " .. removed_versions .. " old version(s), "
        .. broken_links .. " broken link(s), " .. library_links
        .. " library link(s), " .. cache_removed .. " cache dir(s) removed")
    return status
end

-- ---------------------------------------------------------------------------
-- klua doctor
-- ---------------------------------------------------------------------------

local function dir_writable(dir)
    local probe = dir .. "/.klua-doctor-probe"
    if not klua.write_file(probe, "ok") then
        return false
    end
    klua.remove(probe)
    return true
end

function klua.commands.doctor(args)
    local problems, warnings = 0, 0
    local function good(message)
        klua.info("[ok]   " .. message)
    end
    local function warning(message)
        warnings = warnings + 1
        klua.info("[warn] " .. message)
    end
    local function bad(message)
        problems = problems + 1
        klua.info("[fail] " .. message)
    end

    local platform = klua.platform()
    good("klua " .. klua.version .. " (" .. platform.os .. "/" .. platform.arch .. ")")

    local dirs = {
        { name = "config", path = klua.paths.config },
        { name = "store", path = klua.paths.store },
        { name = "bin", path = klua.paths.bin },
        { name = "cache", path = klua.paths.cache },
    }
    for _, dir in ipairs(dirs) do
        if not klua.mkdir(dir.path) then
            bad(dir.name .. " directory could not be created: " .. dir.path)
        elseif not dir_writable(dir.path) then
            bad(dir.name .. " directory is not writable: " .. dir.path)
        else
            good(dir.name .. ": " .. dir.path)
        end
    end

    if klua.file_exists(klua.paths.init) then
        good("init.lua: " .. klua.paths.init)
    else
        warning("init.lua not materialized; using built-in defaults (run 'klua repair')")
    end

    local own_bin = normalize_dir(klua.paths.bin)
    local in_path = false
    for _, dir in ipairs(path_dirs()) do
        if dir == own_bin then
            in_path = true
            break
        end
    end
    if in_path then
        good("PATH includes " .. klua.paths.bin)
    else
        warning("PATH does not include " .. klua.paths.bin
            .. "; linked commands will not be discoverable")
    end

    local registries = all_registries()
    if #registries == 0 then
        warning("no registries configured; alias installs and search will fail")
    else
        for _, base in ipairs(registries) do
            local url = strip_trailing_slash(base) .. "/v1/_.yaml"
            local _, status, err = klua.http_get(url)
            if err then
                warning("registry unreachable: " .. base .. " (" .. err .. ")")
            elseif status == 200 then
                good("registry: " .. base)
            else
                warning("registry " .. base .. " returned HTTP " .. tostring(status))
            end
        end
    end

    local total, broken, libraries = 0, 0, 0
    local links = {}
    for _, entry in ipairs(klua.list_dir(klua.paths.bin)) do
        if not entry.is_dir then
            local target = klua.readlink(entry.path)
            if target then
                total = total + 1
                links[#links + 1] = { name = entry.name, target = target }
                if is_library_name(entry.name) then
                    libraries = libraries + 1
                elseif is_under_store(target) and not klua.file_exists(target) then
                    broken = broken + 1
                    warning("broken symlink: " .. entry.path .. " -> " .. target)
                end
            end
        end
    end
    if broken == 0 then
        good("symlinks: " .. total .. " managed link(s), none broken")
    end
    if libraries > 0 then
        warning(libraries .. " shared library link(s) in " .. klua.paths.bin
            .. "; libraries belong in the store (run 'klua cleanup')")
    end

    local shadowed = 0
    for _, link in ipairs(links) do
        local system_path = find_on_path(link.name)
        if system_path then
            shadowed = shadowed + 1
            if CORE_COMMANDS[link.name] then
                warning("'" .. link.name .. "' shadows protected command at " .. system_path)
            else
                warning("'" .. link.name .. "' shadows " .. system_path)
            end
        end
    end
    if shadowed == 0 then
        good("no system commands are shadowed")
    end

    local packages = installed_packages()
    good("store: " .. #packages .. " installed version(s)")

    if problems > 0 then
        klua.info("doctor: " .. problems .. " error(s), " .. warnings .. " warning(s)")
        return 1
    elseif warnings > 0 then
        klua.info("doctor: no errors, " .. warnings .. " warning(s)")
    else
        klua.info("doctor: no problems found")
    end
    return 0
end

-- Read a sync source (local path or URL); returns content, error, resolved
-- location. Relative sources resolve against base_dir, which may itself be
-- a URL (relative includes of a remote source stay remote).
local function read_source(source, base_dir)
    local location = source
    if not string.match(source, "^https?://")
        and not string.match(source, "^/") and base_dir then
        location = base_dir .. "/" .. source
    end

    if string.match(location, "^https?://") then
        local body, status, err = klua.http_get(location)
        if err then
            return nil, "fetch failed: " .. err
        end
        if status ~= 200 then
            return nil, "HTTP " .. tostring(status) .. " for " .. location
        end
        return body, nil, location
    end

    local content = klua.read_file(location)
    if not content then
        return nil, "could not read " .. location
    end
    return content, nil, location
end

-- Recursively collect packages from a source and its includes, guarding
-- against cycles. Entries are appended to `out` (deduplicated by caller).
local function collect_packages(source, base_dir, visited, out)
    local content, err, resolved = read_source(source, base_dir)
    if not content then
        klua.error("sync: " .. tostring(err))
        return false
    end
    local key = resolved or source
    if visited[key] then
        return true
    end
    visited[key] = true

    local doc, parse_err = klua.yaml_parse(content)
    if parse_err then
        klua.error("sync: invalid YAML in " .. key .. ": " .. parse_err)
        return false
    end

    local next_base = dirname(key)
    if type(doc) == "table" and type(doc.includes) == "table" then
        for _, include in ipairs(doc.includes) do
            if type(include) == "string" then
                if not collect_packages(include, next_base, visited, out) then
                    return false
                end
            end
        end
    end

    local list = {}
    if type(doc) == "table" and type(doc.packages) == "table" then
        list = doc.packages
    elseif type(doc) == "table" and doc[1] ~= nil then
        list = doc -- a bare YAML list is also accepted
    end
    for _, entry in ipairs(list) do
        if type(entry) == "string" then
            out[#out + 1] = entry
        elseif type(entry) == "table" and type(entry.target) == "string" then
            out[#out + 1] = entry.target
        end
    end
    return true
end

function klua.commands.sync(args)
    local flags = klua.cli_flags or {}
    if flags.locked and not require_lockfile() then
        return 1
    end
    local source = args[1] or klua.paths.packages
    if not args[1] and not klua.file_exists(source) then
        klua.error("no packages.yaml found; add targets with 'klua add <target>' first")
        return 1
    end

    local collected = {}
    if not collect_packages(source, nil, {}, collected) then
        return 1
    end
    local packages = dedupe(collected)
    if #packages == 0 then
        klua.info("nothing to sync")
        return 0
    end

    local saved = klua.install_opts
    klua.install_opts = { force = false, link = true, _dependency_seen = {} }
    klua.info("syncing " .. #packages .. " package(s)")
    prefetch_downloads(packages)
    local failed = 0
    for _, target in ipairs(packages) do
        if install_one(target) ~= 0 then
            failed = failed + 1
        end
    end
    if flush_system_packages() ~= 0 then
        failed = failed + 1
    end
    if failed == 0 and save_lockfile() ~= 0 then
        failed = failed + 1
    end
    klua.install_opts = saved
    if failed > 0 then
        klua.error("sync finished with " .. failed .. " failure(s)")
        return 1
    end
    klua.info("sync complete: " .. #packages .. " package(s)")
    return 0
end

function klua.commands.upgrade(args)
    local flags = klua.cli_flags or {}
    if flags.locked then
        klua.error("--locked cannot be combined with 'upgrade'; use 'klua sync --locked'")
        return 1
    end
    local targets = {}
    if #args > 0 then
        for _, target in ipairs(args) do
            if string.find(target, ":", 1, true) then
                targets[#targets + 1] = target
            else
                local resolved, err = resolve_alias(target)
                if not resolved then
                    klua.error(err)
                    return 1
                end
                targets[#targets + 1] = resolved
            end
        end
    else
        local seen = {}
        for _, package in ipairs(installed_packages()) do
            if (package.provider == "gh" or package.provider == "gl")
                and not seen[package.target] then
                seen[package.target] = true
                targets[#targets + 1] = package.target
            end
        end
        if #targets == 0 then
            klua.info("nothing to upgrade")
            return 0
        end
    end

    local saved = klua.install_opts
    klua.install_opts = { force = false, link = true, _dependency_seen = {} }
    prefetch_downloads(targets)
    local status = 0
    for _, target in ipairs(targets) do
        local before = current_version(target)
        klua.info("upgrading " .. target .. " ...")
        local code = install_one(target)
        if code ~= 0 then
            status = 1
        else
            local after = current_version(target)
            if before and after and before ~= after then
                klua.info("upgraded " .. target .. ": " .. before .. " -> " .. after)
            else
                klua.info(target .. " is up to date (" .. tostring(after or before or "unknown") .. ")")
            end
        end
    end
    if flush_system_packages() ~= 0 then
        status = 1
    end
    if status == 0 and save_lockfile() ~= 0 then
        status = 1
    end
    klua.install_opts = saved
    return status
end

function klua.commands.tap(args)
    local action = args[1]
    if action == "list" then
        local taps = load_taps()
        if #taps == 0 then
            klua.info("no taps configured")
        else
            for _, url in ipairs(taps) do
                klua.info(url)
            end
        end
        return 0
    elseif action == "add" or action == "remove" then
        local url = args[2]
        if not url or url == "" then
            klua.error("usage: klua tap " .. action .. " <url>")
            return 1
        end
        url = strip_trailing_slash(url)
        local taps = load_taps()
        if action == "add" then
            taps[#taps + 1] = url
            taps = dedupe(taps)
            if not save_taps(taps) then
                return 1
            end
            klua.info("added tap " .. url)
        else
            local kept = {}
            for _, existing in ipairs(taps) do
                if existing ~= url then
                    kept[#kept + 1] = existing
                end
            end
            if not save_taps(kept) then
                return 1
            end
            klua.info("removed tap " .. url)
        end
        return 0
    end

    klua.error("usage: klua tap <add|remove|list> [url]")
    return 1
end

function klua.commands.list(args)
    local packages = installed_packages()
    if #packages == 0 then
        klua.info("no packages installed")
        return 0
    end
    for _, package in ipairs(packages) do
        klua.info(package.provider .. ":" .. package.user .. "/" .. package.repo
            .. "  " .. package.version)
    end
    return 0
end

-- ---------------------------------------------------------------------------
-- init-manifest: generate a starter klua.yaml in the current directory.
-- ---------------------------------------------------------------------------

local STARTER_MANIFEST = [[
# klua.yaml -- package manifest for this repository.
# klua reads this file from the repo root before falling back to heuristics.

# Optional: explicit release asset patterns (first match wins, * and ?).
# assets:
#   - "mytool-*-linux-*.tar.gz"

# Optional: binaries to link into ~/.local/bin (paths relative to the
# extracted archive / store root). Omit for auto-detection.
# bins:
#   - mytool

# Optional: config files to install (src relative to the store root; dest
# may use ~, and a trailing / means "copy into this directory").
# configs:
#   - src: config.example.toml
#     dest: ~/.config/mytool/config.toml

# Optional: build from source when no suitable release asset exists.
# Steps run in the cloned repository root.
# build:
#   steps:
#     - cargo build --release
]]

klua.commands["init-manifest"] = function(args)
    local force = args[1] == "--force"
    local path = klua.cwd() .. "/klua.yaml"
    if klua.file_exists(path) and not force then
        klua.error("klua.yaml already exists here; use --force to overwrite")
        return 1
    end
    local ok, err = klua.write_file(path, STARTER_MANIFEST)
    if not ok then
        klua.error("could not write klua.yaml: " .. tostring(err))
        return 1
    end
    klua.info("created " .. path)
    return 0
end
