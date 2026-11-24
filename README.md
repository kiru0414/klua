![](docs/asset/logo-1.svg)
# klua

A fast, zero-dependency, self-healing package manager built with **C++20** and
**Lua 5.4** (sol2), targeting **Linux and macOS**.

> **Safer than Homebrew, simpler than Nix, and infinitely hackable in Lua.**

Heavy lifting (HTTP, extraction, filesystem, YAML) lives in native C++20;
resolution logic, providers and lifecycle hooks are extensible in Lua.
Packages stay in an isolated per-package store, shared libraries never pollute
`~/.local/bin`, PATH conflicts are detected before any symlink is created, and
your `init.lua` can evolve every provider or command without recompiling.

## Documentation

- [Getting started](docs/getting-started.md) — installation, XDG paths, CLI, self-healing
- [klua.yaml manifests](docs/klua-yaml.md) — assets, bins, configs, build.steps
- [Lua API reference](docs/lua-api.md) — native primitives, hooks, recipes
- [Taps & registry](docs/taps-and-registry.md) — alias sharding, hosting a tap, contributing aliases

## Design philosophy

- **Isolated store.** Every version is extracted intact under
  `~/.local/share/klua/store/<provider>/<user>/<repo>/<version>/`;
  `~/.local/bin` holds only symlinks to the chosen binaries.
- **No shared library pollution.** `.so`, `.so.*`, `.dylib`, `.a`, `.la` and
  `.dll` files are never linked globally. `klua run` exposes them only to the
  process it launches via `LD_LIBRARY_PATH` / `DYLD_LIBRARY_PATH`.
- **Automatic PATH conflict protection.** Before linking, klua scans `PATH`,
  warns about existing commands, refuses to shadow protected core commands
  unless `--force` is given, and supports `--as NAME` to avoid collisions.
- **Verified downloads.** Matching `.sha256`, `.sha256sum` and `checksums.txt`
  assets are checked before extraction; a mismatch aborts the install unless
  `--skip-checksum` is explicitly given.
- **Self-evolving Lua customization.** The embedded baseline is always the
  fallback; your `init.lua` can override providers, command handlers and
  linking policy at runtime. `klua repair` now backs up custom Lua instead of
  silently destroying it.

## Status

Milestones 1, 2 and 3 plus the v0.4.0 safety release and the v0.5.0
resolution/verification release are implemented:

**Milestone 1 — core skeleton**

- CMake build that embeds `builtin/default_init.lua` into a generated
  `embedded_assets.hpp` raw string literal.
- CLI11 subcommands: `install` / `i`, `add`, `sync`, `upgrade`, `repair`,
  `tap`, `list`.
- sol2 engine with self-healing startup: the embedded Lua baseline loads
  first, then `~/.config/klua/init.lua` runs in a protected call. If the user
  file has syntax or runtime errors, klua prints a clear English diagnostic
  and falls back to the embedded defaults.
- `klua repair` restores `~/.config/klua/init.lua` from the embedded baseline
  (implemented natively, so it works even when Lua is broken). It backs up
  the existing file to `~/.config/klua/init.lua.bak.<timestamp>` first and
  prints the backup path. `klua repair --dry-run` (`--diff`) previews the
  backup path and a unified diff without changing any files.

**Milestone 2 — fetcher & installer**

- Native HTTPS client (cpp-httplib + OpenSSL): `klua.http_get`,
  `klua.http_head_redirect`, `klua.download` (streaming, redirect-following),
  `klua.sha256` (OpenSSL EVP).
- Archive extraction via system `tar`/`unzip` (`.tar.gz`, `.tar.xz`,
  `.tar.bz2`, `.tar`, `.zip`) with automatic single-top-level-directory
  stripping; POSIX symlinks and `chmod +x` handled natively.
- Alias sharding: bare targets resolve through `v1/<first_char>.yaml`
  fetched from configured registries / taps and parsed in-memory (yaml-cpp).
- `gh:user/repo[@tag]`: latest tag discovered from the
  `releases/latest` HTTP redirect, assets parsed from
  `releases/expanded_assets/<tag>`; the REST API is only a fallback. Asset
  scoring by OS/arch, download into the cache, checksum verification, intact
  extraction into `~/.local/share/klua/store/gh/<user>/<repo>/<version>/`,
  binary discovery (ELF/Mach-O magic or exec bits), symlink into
  `~/.local/bin/`.
- `gl:` (GitLab releases) and `url:` (direct download) providers.
- `klua tap add/remove/list` manages registries in `taps.yaml` (deduplicated).
- `klua list` enumerates installed packages from the store.

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
  `registry-template/v1/` — copy the `v1/` contents to the **root** of the
  `klua-registry` repository (not the `registry-template/` wrapper).
- `.github/workflows/release.yml` builds static Linux binaries (x86_64 +
  arm64) and macOS binaries (x86_64 + arm64) on `v*` tags and attaches
  them to the GitHub release.

**v0.4.0 — conflict safety, isolated execution & management**

- Before linking, klua scans `PATH`, refuses to shadow protected core
  commands (`git`, `curl`, `python`, `python3`, `apt`, `sudo`, `klua`, …) and
  warns about existing binaries. The package still installs into the store;
  `klua install --force` explicitly overrides either guard, and
  `klua install --as NAME` chooses the command name for the primary binary.
- Shared/static libraries (`.so`, `.so.*`, `.dylib`, `.a`, `.la`, `.dll`) are
  never linked into `~/.local/bin/` — they remain isolated inside the store.
- `klua run <target> [args...]` stages a missing package in the store without
  creating links, then executes its binary with store `bin` directories on
  `PATH` and store libraries on `LD_LIBRARY_PATH` / `DYLD_LIBRARY_PATH`.
- `klua search <query>` searches all registry shards (`a`–`z` plus `_`);
  `klua info <target>` reports resolution, installed versions, store path,
  links and release metadata; `klua cleanup` prunes old versions, broken or
  library links and caches; `klua doctor` checks dirs, PATH, registries and
  links.
- Levenshtein typo hints cover subcommands (`install`, `run`, `search`,
  `info`, `cleanup`, `doctor`, `remove`/`rm`/`uninstall`, …), flags
  (`--force`, `--as`, `--no-cache`, `--skip-checksum`, `--dry-run`, …) and
  registry aliases — a mistyped
  `klua serach jq` suggests `search`.
- `klua repair` is non-destructive by default: it backs up custom Lua to
  `init.lua.bak.<timestamp>` and prints the path; `--dry-run` / `--diff`
  shows the backup path and a unified diff without changing any files.

**v0.5.0 — zero-rate-limit resolution, shard cache & checksums**

- GitHub installs no longer call `api.github.com` first: a HEAD redirect on
  `https://github.com/<user>/<repo>/releases/latest` yields the tag, and
  `releases/expanded_assets/<tag>` supplies download links. Pinned tags skip
  the redirect entirely. The REST API remains a fallback and automatically
  sends `Authorization: Bearer` when `GITHUB_TOKEN` or `GH_TOKEN` is set.
- Registry shards are cached under `~/.cache/klua/shards/` for one hour by
  default (`klua.shard_ttl` in `init.lua`). `--no-cache` forces a refetch;
  stale cache entries are reused with a warning if the network fails.
- The selected release asset is hashed with `klua.sha256` and compared with a
  matching `.sha256`, `.sha256sum` or `checksums.txt` asset before extraction.
  Mismatches abort with a clear error; `--skip-checksum` explicitly bypasses
  verification. GitLab releases use the same verification path.
- `--no-cache` and `--skip-checksum` are accepted by `install`, `run`,
  `search`, `info`, `cleanup`, `doctor`, `sync`, `upgrade` and `remove`, and
  are covered by Levenshtein typo hints.

See `AGENTS.md` for the full roadmap.

## Testing

```sh
bash tests/test_milestone1.sh   # offline: CLI, repair, self-healing, XDG
bash tests/test_milestone2.sh   # network: taps, alias sharding, real installs
bash tests/test_milestone3.sh   # add/sync/upgrade + local manifest & build tests
bash tests/test_ux.sh           # remove, CLI/alias typo suggestions
bash tests/test_v04.sh          # offline: conflict safety, run, management, repair
bash tests/test_v05.sh          # offline: API-free GitHub, shard cache, SHA-256
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
klua install --force git      # override shadowing/protected-command guard
klua install --as jq2 jq      # link the primary binary as ~/.local/bin/jq2
klua install --no-cache fd    # refetch the registry shard instead of using cache
klua install --skip-checksum jq  # bypass SHA-256 verification (explicit)
klua run jq --version         # execute from the store, no global symlink
klua search jq                # search alias shards across all registries
klua info jq                  # resolution, versions, links, release metadata
klua cleanup                  # prune old versions, broken links and caches
klua doctor                   # diagnose dirs, PATH, registries, links
klua add gh:jqlang/jq fd      # record targets in packages.yaml
klua sync                     # install everything in packages.yaml
klua sync https://host/dotfiles.yaml  # remote source, follows includes:
klua upgrade                  # upgrade all installed packages
klua remove fd                # delete symlinks, store dir, packages.yaml entry
klua rm gh:jqlang/jq          # alias of remove
klua uninstall url:https://host/tool.tar.gz  # alias of remove
klua list                     # installed packages from the store
klua init-manifest            # starter klua.yaml for a package repo
klua repair                   # back up and restore a clean init.lua
klua repair --dry-run         # preview backup path and diff, change nothing
```

## Layout (XDG)

| Purpose | Path                                            |
| ------- | ----------------------------------------------- |
| Config  | `~/.config/klua/` (`init.lua`, `packages.yaml`, `taps.yaml`) |
| Store   | `~/.local/share/klua/store/<provider>/<user>/<repo>/<version>/` |
| Bin     | `~/.local/bin/` (symlinks into the store)       |
| Cache   | `~/.cache/klua/` (`downloads/`, `checksums/`, `build/`, `shards/`) |

Libraries are never linked into `~/.local/bin/`; they stay inside the store
and are exposed to `klua run` via `LD_LIBRARY_PATH` / `DYLD_LIBRARY_PATH`.

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
`klua.file_exists/is_dir/is_executable/read_file/write_file/mkdir/copy/remove/list_dir`,
`klua.find_executables`, `klua.readlink`, `klua.env`, `klua.exec`,
`klua.register_provider`, `klua.http_get/http_head_redirect/download`,
`klua.sha256`, `klua.extract/is_archive`, `klua.symlink`, `klua.chmod_exec`,
`klua.json_parse/yaml_parse`, `klua.platform`, `klua.paths`, `klua.version`.
Set `klua.shard_ttl` to change the one-hour cache lifetime and
`klua.cli_flags` to inspect `--no-cache` / `--skip-checksum` from your own
handlers. Set `klua.install_opts =
{ force = ..., link = ..., as = ... }` in a custom handler to control conflict
overrides, rename the primary link, or request a store-only (run-only)
install. This is the "self-evolving" part: rebind `klua.commands.<name>` or
register a provider in `init.lua` and the CLI immediately behaves differently.
