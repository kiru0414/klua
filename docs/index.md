# klua

A fast, zero-dependency, self-healing package manager built with **C++20** and
**Lua 5.4** (sol2), targeting **Linux and macOS**.

Heavy lifting (HTTP, extraction, filesystem, YAML) lives in native C++20;
resolution logic, providers and lifecycle hooks are extensible in Lua.

## Documentation

- [Getting started](docs/getting-started.md) — installation, XDG paths, CLI, self-healing
- [klua.yaml manifests](docs/klua-yaml.md) — assets, bins, configs, build.steps
- [Lua API reference](docs/lua-api.md) — native primitives, hooks, recipes
- [Taps & registry](docs/taps-and-registry.md) — alias sharding, hosting a tap, contributing aliases

## Status

Milestones 1, 2 and 3 are implemented:

**Milestone 1 — core skeleton**

- CMake build that embeds `builtin/default_init.lua` into a generated
  `embedded_assets.hpp` raw string literal.
- CLI11 subcommands: `install` / `i`, `add`, `sync`, `upgrade`, `repair`,
  `tap`, `list`.
- sol2 engine with self-healing startup: the embedded Lua baseline loads
  first, then `~/.config/klua/init.lua` runs in a protected call. If the user
  file has syntax or runtime errors, klua prints a clear English diagnostic
  and falls back to the embedded defaults.
- `klua repair` forcefully restores `~/.config/klua/init.lua` from the
  embedded baseline (implemented natively, so it works even when Lua is
  broken).

**Milestone 2 — fetcher & installer**

- Native HTTPS client (cpp-httplib + OpenSSL): `klua.http_get`,
  `klua.download` (streaming, redirect-following).
- Archive extraction via system `tar`/`unzip` (`.tar.gz`, `.tar.xz`,
  `.tar.bz2`, `.tar`, `.zip`) with automatic single-top-level-directory
  stripping; POSIX symlinks and `chmod +x` handled natively.
- Alias sharding: bare targets resolve through `v1/<first_char>.yaml`
  fetched from configured registries / taps and parsed in-memory (yaml-cpp).
- `gh:user/repo[@tag]`: GitHub Releases API (nlohmann/json), asset scoring
  by OS/arch, download into the cache, intact extraction into
  `~/.local/share/klua/store/gh/<user>/<repo>/<version>/`, binary discovery
  (ELF/Mach-O magic or exec bits), symlink into `~/.local/bin/`.
- `gl:` (GitLab releases) and `url:` (direct download) providers.
- `klua tap add/remove/list` manages registries in `taps.yaml` (deduplicated).
- `klua list` enumerates installed packages from the store.

Manifests (`klua.yaml`), `sync` and `upgrade` arrive in Milestone 3. See
`AGENTS.md` for the full roadmap.

**Milestone 3 — manifests, sync & release readiness**

- In-repo `klua.yaml` manifests (checked before release heuristics):
  `assets` (glob patterns), `bins` (explicit binaries to link), `configs`
  (files copied to user locations, `~` supported), `build.steps` (source
  build via `git clone` when no suitable release asset exists).
- `klua add <target...>` records targets in `packages.yaml` (deduplicated).
- `klua sync [path_or_url]` installs the declared set; defaults to
  `~/.config/klua/packages.yaml`, follows `includes:` recursively with
  cycle protection, and deduplicates entries.
- `klua upgrade [target...]` reinstalls latest releases and reports version
  changes; without arguments it upgrades every installed gh/gl package.
- `klua remove <target...>` (`rm`, `uninstall`) deletes `~/.local/bin`
  symlinks, the store directory, and matching `packages.yaml` entries.
- `klua init-manifest [--force]` generates a starter `klua.yaml`.
- Official registry default:
  `https://raw.githubusercontent.com/kiru0414/klua-registry/main`
  (githubusercontent.com). Starter shard content lives in
  `registry-template/v1/` — copy its contents (`v1/`) to the **root** of
  the `klua-registry` repository (not the `registry-template/` wrapper).
- `.github/workflows/release.yml` builds static Linux binaries (x86_64 +
  arm64) and macOS binaries (x86_64 + arm64) on `v*` tags and attaches
  them to the GitHub release.

See `AGENTS.md` for the full roadmap.

## Testing

```sh
bash tests/test_milestone1.sh   # offline: CLI, repair, self-healing, XDG
bash tests/test_milestone2.sh   # network: taps, alias sharding, real installs
bash tests/test_milestone3.sh   # add/sync/upgrade + local manifest & build tests
bash tests/test_ux.sh           # remove, CLI/alias typo suggestions
```

## Building (Linux / macOS)

Requirements: CMake >= 3.24, a C++20 compiler (GCC 11+ / Clang 14+), git.
All other dependencies (Lua 5.4, sol2, CLI11) are fetched automatically via
CMake `FetchContent` — no system packages needed.

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
./build/klua --version
```

On Windows, build inside WSL (the project targets POSIX only):

```sh
wsl bash -c "cmake -S . -B build && cmake --build build -j"
```

## Usage

```sh
klua tap add https://example.com/klua-registry  # register an alias registry
klua install fd               # alias sharding -> v1/f.yaml -> gh:sharkdp/fd
klua install gh:jqlang/jq     # direct GitHub Releases install
klua i gh:jqlang/jq@jq-1.7.1  # pinned tag
klua add gh:jqlang/jq fd      # record targets in packages.yaml
klua sync                     # install everything in packages.yaml
klua sync https://host/dotfiles.yaml  # remote source, follows includes:
klua upgrade                  # upgrade all installed packages
klua remove fd                # delete symlinks, store dir, packages.yaml entry
klua list                     # installed packages from the store
klua init-manifest            # starter klua.yaml for a package repo
klua repair                   # restore a clean ~/.config/klua/init.lua
```

## Layout (XDG)

| Purpose | Path                                            |
| ------- | ----------------------------------------------- |
| Config  | `~/.config/klua/` (`init.lua`, `packages.yaml`, `taps.yaml`) |
| Store   | `~/.local/share/klua/store/<provider>/<user>/<repo>/<version>/` |
| Bin     | `~/.local/bin/` (symlinks into the store)       |
| Cache   | `~/.cache/klua/`                                |

`XDG_CONFIG_HOME`, `XDG_DATA_HOME` and `XDG_CACHE_HOME` overrides are honored.

## Customization

Edit `~/.config/klua/init.lua` to register custom providers or override
command handlers:

```lua
klua.register_provider("my", function(rest, target)
    klua.info("custom provider handling " .. target)
    return 0
end)
```

Native primitives available to Lua: `klua.info/warn/error`,
`klua.file_exists/read_file/write_file/mkdir/copy/remove/list_dir`,
`klua.find_executables`, `klua.env`, `klua.exec`, `klua.register_provider`,
`klua.http_get/download`, `klua.extract/is_archive`, `klua.symlink`,
`klua.chmod_exec`, `klua.json_parse/yaml_parse`, `klua.platform`,
`klua.paths`, `klua.version`.
