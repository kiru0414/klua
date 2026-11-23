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
--   klua.file_exists / klua.read_file / klua.write_file / klua.mkdir
--   klua.copy / klua.remove / klua.list_dir / klua.find_executables
--   klua.env / klua.exec / klua.register_provider
--   klua.http_get / klua.download / klua.extract / klua.is_archive
--   klua.symlink / klua.chmod_exec / klua.json_parse / klua.yaml_parse

klua.providers = klua.providers or {}
klua.commands = klua.commands or {}

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
    for _, base in ipairs(registries) do
        local url = strip_trailing_slash(base) .. "/v1/" .. shard .. ".yaml"
        local body, status, err = klua.http_get(url)
        if not err and status == 200 then
            local doc, parse_err = klua.yaml_parse(body)
            if doc and type(doc) == "table" then
                local resolved = doc[target]
                if type(resolved) == "string" and resolved ~= "" then
                    return resolved
                end
            elseif parse_err then
                klua.warn("registry " .. base .. " returned invalid YAML: " .. parse_err)
            end
        end
    end
    return nil, "alias '" .. target .. "' not found in any configured registry"
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
-- In-repo klua.yaml manifests
-- ---------------------------------------------------------------------------

local function fetch_manifest(raw_base, user, name, tag)
    local ref = tag or "HEAD"
    local url = raw_base .. "/" .. user .. "/" .. name .. "/" .. ref .. "/klua.yaml"
    local body, status, err = klua.http_get(url)
    if err or status ~= 200 then
        return nil
    end
    local doc, parse_err = klua.yaml_parse(body)
    if parse_err then
        klua.warn("ignoring invalid klua.yaml: " .. parse_err)
        return nil
    end
    if doc == nil then
        return {} -- comment-only manifest: valid, but no overrides
    end
    if type(doc) ~= "table" then
        klua.warn("ignoring klua.yaml: expected a mapping")
        return nil
    end
    return doc
end

-- Link binaries listed in manifest.bins, or auto-detect one executable.
local function link_binaries(store_dir, manifest, preferred_name)
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
            ok, err = klua.symlink(path, klua.paths.bin .. "/" .. basename(bin))
            if not ok then
                klua.error(tostring(err))
                return 1
            end
            klua.info("linked " .. klua.paths.bin .. "/" .. basename(bin))
        end
        return 0
    end

    local candidates = klua.find_executables(store_dir)
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
    ok, err = klua.symlink(binary, klua.paths.bin .. "/" .. basename(binary))
    if not ok then
        klua.error(tostring(err))
        return 1
    end
    klua.info("linked " .. klua.paths.bin .. "/" .. basename(binary))
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
        if ok then
            ok, err = klua.symlink(store_dir .. "/" .. asset_name,
                                   klua.paths.bin .. "/" .. preferred_name)
        end
        if not ok then
            klua.error(tostring(err))
            return 1
        end
        klua.info("linked " .. klua.paths.bin .. "/" .. preferred_name)
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
        ok, err = klua.symlink(dest, klua.paths.bin .. "/" .. basename(binary))
        if not ok then
            klua.error(tostring(err))
            return 1
        end
        klua.info("linked " .. klua.paths.bin .. "/" .. basename(binary))
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

local function github_install(rest)
    local repo, tag = string.match(rest, "^([^@]+)@(.+)$")
    if not repo then
        repo = rest
    end
    local user, name = string.match(repo, "^([%w_.-]+)/([%w_.-]+)$")
    if not user then
        klua.error("gh: expected 'user/repo' (optionally '@tag'), got '" .. rest .. "'")
        return 1
    end

    -- In-repo manifest takes priority over release heuristics.
    local manifest = fetch_manifest(klua.raw_github, user, name, tag)

    local endpoint = tag and ("tags/" .. tag) or "latest"
    local api = klua.github_api .. "/repos/" .. user .. "/" .. name .. "/releases/" .. endpoint
    local body, status, err = klua.http_get(api)
    if err then
        klua.error("gh: request failed: " .. err)
        return 1
    end

    local release = nil
    if status == 200 then
        local json_err
        release, json_err = klua.json_parse(body)
        if not release then
            klua.error("gh: could not parse release JSON: " .. tostring(json_err))
            return 1
        end
    elseif status ~= 404 then
        klua.error("gh: GitHub API returned HTTP " .. tostring(status))
        return 1
    end

    if release then
        local version = release.tag_name or tag or "unknown"
        local asset = select_asset(release.assets or {}, manifest, klua.platform())
        if asset then
            klua.info("gh: " .. repo .. " " .. version .. " -> " .. asset.name)
            local payload = klua.paths.cache .. "/downloads/" .. asset.name
            local ok, dl_err = klua.download(asset.browser_download_url, payload)
            if not ok then
                klua.error("gh: download failed: " .. tostring(dl_err))
                return 1
            end
            local store_dir = klua.paths.store .. "/gh/" .. user .. "/" .. name .. "/" .. version
            return install_payload(payload, asset.name, store_dir, name, manifest)
        end
    end

    -- No release or no suitable asset: try manifest build.steps.
    if manifest and type(manifest.build) == "table"
        and type(manifest.build.steps) == "table" and #manifest.build.steps > 0 then
        local version = tag or "source"
        local store_dir = klua.paths.store .. "/gh/" .. user .. "/" .. name .. "/" .. version
        return build_from_source(klua.github_clone, user, name, tag, manifest, store_dir)
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

local function gitlab_install(rest)
    local repo, tag = string.match(rest, "^([^@]+)@(.+)$")
    if not repo then
        repo = rest
    end
    local user, name = string.match(repo, "^([%w_.-]+)/([%w_.-]+)$")
    if not user then
        klua.error("gl: expected 'user/repo' (optionally '@tag'), got '" .. rest .. "'")
        return 1
    end

    local manifest = fetch_manifest(klua.raw_gitlab, user, name, tag)

    local project = user .. "%2F" .. name
    local endpoint = tag and ("releases/" .. tag) or "releases/permalink/latest"
    local api = klua.gitlab_api .. "/projects/" .. project .. "/" .. endpoint
    local body, status, err = klua.http_get(api)
    if err then
        klua.error("gl: request failed: " .. err)
        return 1
    end

    local release = nil
    if status == 200 then
        local json_err
        release, json_err = klua.json_parse(body)
        if not release then
            klua.error("gl: could not parse release JSON: " .. tostring(json_err))
            return 1
        end
    elseif status ~= 404 then
        klua.error("gl: GitLab API returned HTTP " .. tostring(status))
        return 1
    end

    if release then
        local version = release.tag_name or tag or "unknown"
        -- Normalize GitLab asset links into the GitHub asset shape.
        local assets = {}
        for _, link in ipairs((release.assets and release.assets.links) or {}) do
            assets[#assets + 1] = { name = link.name or "", browser_download_url = link.url }
        end
        local asset = select_asset(assets, manifest, klua.platform())
        if asset then
            klua.info("gl: " .. repo .. " " .. version .. " -> " .. asset.name)
            local asset_name = basename(asset.browser_download_url or asset.name)
            local payload = klua.paths.cache .. "/downloads/" .. asset_name
            local ok, dl_err = klua.download(asset.browser_download_url, payload)
            if not ok then
                klua.error("gl: download failed: " .. tostring(dl_err))
                return 1
            end
            local store_dir = klua.paths.store .. "/gl/" .. user .. "/" .. name .. "/" .. version
            return install_payload(payload, asset_name, store_dir, name, manifest)
        end
    end

    if manifest and type(manifest.build) == "table"
        and type(manifest.build.steps) == "table" and #manifest.build.steps > 0 then
        local version = tag or "source"
        local store_dir = klua.paths.store .. "/gl/" .. user .. "/" .. name .. "/" .. version
        return build_from_source(klua.gitlab_clone, user, name, tag, manifest, store_dir)
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

local function url_install(rest)
    if not string.match(rest, "^https?://") then
        klua.error("url: expected an http(s) URL, got '" .. rest .. "'")
        return 1
    end

    local path_part = string.match(rest, "^https?://[^/]+(/[^?#]*)") or "/"
    local asset_name = basename(path_part)
    if asset_name == "" or asset_name == "/" then
        klua.error("url: could not derive a file name from '" .. rest .. "'")
        return 1
    end
    local host = string.match(rest, "^https?://([^/]+)") or "unknown-host"
    local stem = string.gsub(asset_name, "%.[^.]+$", "")
    stem = string.gsub(stem, "%.tar$", "")

    klua.info("url: downloading " .. rest)
    local payload = klua.paths.cache .. "/downloads/" .. asset_name
    local ok, dl_err = klua.download(rest, payload)
    if not ok then
        klua.error("url: download failed: " .. tostring(dl_err))
        return 1
    end

    local store_dir = klua.paths.store .. "/url/" .. host .. "/" .. stem .. "/direct"
    return install_payload(payload, asset_name, store_dir, stem, nil)
end

klua.register_provider("url", url_install)

-- ---------------------------------------------------------------------------
-- apt provider: delegated to the system package manager (later milestone).
-- ---------------------------------------------------------------------------

klua.register_provider("apt", function(rest)
    klua.warn("apt: installing '" .. rest .. "' via the system package manager is not implemented yet.")
    return 1
end)

-- ---------------------------------------------------------------------------
-- Install dispatch
-- ---------------------------------------------------------------------------

local function install_one(target)
    local scheme, rest = string.match(target, "^([%w][%w+_-]*):(.+)$")
    if not scheme then
        local resolved, err = resolve_alias(target)
        if not resolved then
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

-- Latest stored version for a scheme target (nil when not installed).
local function current_version(target)
    local scheme, user, repo = string.match(target, "^([%w][%w+_-]*):([^/@]+)/([^/@]+)")
    if not scheme then
        return nil
    end
    local versions = klua.list_dir(klua.paths.store .. "/" .. scheme .. "/" .. user .. "/" .. repo)
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
-- Command handlers
-- ---------------------------------------------------------------------------

function klua.commands.install(args)
    if #args == 0 then
        klua.error("usage: klua install <target> [<target>...]")
        return 1
    end
    local status = 0
    for _, target in ipairs(args) do
        local code = install_one(target)
        if code ~= 0 then
            status = code
        end
    end
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

    klua.info("syncing " .. #packages .. " package(s)")
    local failed = 0
    for _, target in ipairs(packages) do
        if install_one(target) ~= 0 then
            failed = failed + 1
        end
    end
    if failed > 0 then
        klua.error("sync finished with " .. failed .. " failure(s)")
        return 1
    end
    klua.info("sync complete: " .. #packages .. " package(s)")
    return 0
end

function klua.commands.upgrade(args)
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
