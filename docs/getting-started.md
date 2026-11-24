# Getting Started

klua is a self-healing package manager: a C++20 core does the heavy lifting
(HTTP, extraction, filesystem, YAML/JSON parsing), Lua 5.4 does the thinking
(providers, resolution, lifecycle hooks). Linux and macOS only.

> **Safer than Homebrew, simpler than Nix, and infinitely hackable in Lua.**

That means an isolated store per package version, no shared library pollution
in `~/.local/bin`, automatic PATH conflict protection before every symlink,
and a Lua `init.lua` you can evolve at any time — with `klua repair` backing up
your custom code before restoring the embedded baseline.

## Installation

### From GitHub Releases

Static Linux binaries (x86_64, arm64) and macOS binaries are attached to
every `v*` release:

```sh
curl -LO https://github.com/kiru0414/klua/releases/latest/download/klua-v0.5.0-linux-x86_64.tar.gz
tar -xzf klua-v0.5.0-linux-x86_64.tar.gz
install -m 755 klua ~/.local/bin/klua   # or /usr/local/bin
klua --version
```

Make sure `~/.local/bin` is on your `PATH`:

```sh
export PATH="$HOME/.local/bin:$PATH"    # add to ~/.bashrc / ~/.zshrc
```

### From source

Requirements: CMake >= 3.24, a C++20 compiler (GCC 11+ / Clang 14+), git,
OpenSSL dev headers (`libssl-dev` on Debian/Ubuntu, `brew install openssl@3`
on macOS). Everything else (Lua 5.4, sol2, CLI11, yaml-cpp, nlohmann/json,
cpp-httplib) is fetched by CMake at configure time. `tar` is required at
runtime; `unzip` only for `.zip` assets.

```sh
git clone https://github.com/kiru0414/klua.git
cd klua
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
./build/klua --version
```

Fully static Linux build (what CI ships):

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_EXE_LINKER_FLAGS=-static -DOPENSSL_USE_STATIC_LIBS=ON
cmake --build build -j
```

On Windows, build inside WSL — POSIX is the only supported target.

## XDG paths

| Purpose | Default | Override |
| ------- | ------- | -------- |
| Config  | `~/.config/klua/` (`init.lua`, `packages.yaml`, `taps.yaml`) | `XDG_CONFIG_HOME` |
| Store   | `~/.local/share/klua/store/<provider>/<user>/<repo>/<version>/` | `XDG_DATA_HOME` |
| Bin     | `~/.local/bin/<name>` (symlinks into the store) | none (always `~/.local/bin`) |
| Cache   | `~/.cache/klua/` (`downloads/`, `checksums/`, `build/`, `shards/`) | `XDG_CACHE_HOME` |

Overrides are honored only when absolute. Archives are extracted intact
into the store (single top-level wrapper directories are stripped), so
relative layouts of complex tools survive.

## Design philosophy

- **Isolated store:** binaries and libraries live under
  `~/.local/share/klua/store/...`; `~/.local/bin` contains only symlinks.
- **No shared library pollution:** library-looking files are never linked
  globally; `klua run` exposes store libraries only to the launched process.
- **Automatic PATH conflict protection:** klua scans `PATH`, skips/warns on
  collisions, protects core commands, and offers `--force` / `--as` instead of
  silently overwriting your system.
- **Self-evolving Lua customization:** `init.lua` can replace providers and
  command handlers; the embedded baseline is always the safe fallback.

## CLI

```
klua install [--force] [--as NAME] [--no-cache] [--skip-checksum] <target>...  (alias: klua i)
klua run [--no-cache] [--skip-checksum] <target> [--] [args...]  # store-only
klua search [--no-cache] <query>
klua info [--no-cache] <target>
klua cleanup [--no-cache]
klua doctor [--no-cache]
klua add <target>...
klua remove [--no-cache] <target>...    (aliases: klua rm, klua uninstall)
klua sync [--no-cache] [--skip-checksum] [path_or_url]
klua upgrade [--no-cache] [--skip-checksum] [target...]
klua tap <add|remove|list> [url]
klua list
klua repair [--dry-run|--diff]
klua init-manifest [--force]
klua --version | --help
```

Mistyped subcommands, flags, and aliases get a Levenshtein-based hint. The
suggestion dictionary includes `install`, `run`, `search`, `info`, `cleanup`,
`doctor`, `remove`/`rm`/`uninstall`, and flags such as `--force`, `--as`,
`--no-cache`, `--skip-checksum`, `--dry-run` and `--diff`:

```
$ klua instll
warning: unknown command 'instll'; did you mean 'install'?
$ klua --helo
warning: unknown option '--helo'; did you mean '--help'?
$ klua i bzp3
warning: did you mean 'bzip3'?
$ klua serach jq
warning: unknown command 'serach'; did you mean 'search'?
```

### install / i

Targets are either scheme-qualified or bare aliases:

```sh
klua install gh:jqlang/jq        # GitHub Releases (latest)
klua i gh:jqlang/jq@jq-1.7.1     # pinned tag
klua install gl:user/repo        # GitLab Releases
klua install url:https://example.com/tool.tar.gz
klua install fd                  # alias -> v1/f.yaml -> gh:sharkdp/fd
```

Pipeline: direct scheme dispatch, or alias sharding lookup, then (for
gh/gl) an in-repo [`klua.yaml`](klua-yaml.md) manifest check, then release
discovery (API-free for `gh:`), asset scoring by OS/arch, download, SHA-256
verification, extraction into the store, binary discovery (ELF/Mach-O magic
or exec bits), `chmod +x`, conflict-checked symlink into `~/.local/bin`. See
[taps-and-registry.md](taps-and-registry.md) for alias resolution and the
sections below for release discovery, caching and checksums.

### API-free GitHub resolution

`gh:user/repo` never calls `api.github.com` first. klua sends a HEAD request
to `https://github.com/<user>/<repo>/releases/latest` and reads the
`Location` redirect to learn the tag, then fetches
`releases/expanded_assets/<tag>` and parses `href` links whose paths contain
`/<user>/<repo>/releases/download/<tag>/...`. A pinned target
(`gh:user/repo@v1.2.3`) skips the redirect and reads that tag's asset page
directly. This avoids the unauthenticated REST limit entirely.

The REST API is still used if the web endpoints fail. When the fallback runs,
`GITHUB_TOKEN` or `GH_TOKEN` (in that order) is sent automatically as
`Authorization: Bearer ...`. For a trusted custom API host, set
`KLUA_GITHUB_API_HOST` to that hostname; the token is then limited to
API-looking paths on that host.

### Registry shard cache

Fetched `v1/<char>.yaml` shards are stored under `~/.cache/klua/shards/` with
a one-hour TTL (`klua.shard_ttl` in `init.lua`). Repeated installs and
`klua search` runs reuse the cached body. `--no-cache` forces a fresh fetch;
if a refresh fails, a stale entry is reused with a warning so you can still
work offline.

```sh
klua install --no-cache fd   # bypass the shard cache for this invocation
klua search --no-cache fd    # same for search (all 27 shards)
```

### SHA-256 verification

When a release ships `<asset>.sha256`, `<asset>.sha256sum` or
`checksums.txt`, klua hashes the downloaded file with OpenSSL EVP and checks
the digest **before** extraction. Supported checksum lines include
`<hash>  <filename>`, `<hash> *<filename>` and `SHA256(<filename>) = <hash>`;
a bare 64-hex digest is accepted in an asset-specific sidecar. A mismatch
aborts the install and leaves the store untouched.

```sh
klua install gh:jqlang/jq               # verifies automatically if a checksum exists
klua install --skip-checksum gh:jqlang/jq  # explicit bypass, warns and continues
```

GitLab releases go through the same verification path. Registries and
checksum files themselves are not signed; this protects against truncated or
corrupted downloads, not maliciously published checksums.

### Conflict safety

Before creating any link, klua scans `PATH` and:

- refuses to shadow protected core commands such as `git`, `curl`, `python`,
  `python3`, `apt`, `sudo` and `klua` itself;
- warns when a binary with the same name already exists on `PATH` or at the
  link destination and is not managed by klua;
- never links shared/static libraries (`.so`, `.so.*`, `.dylib`, `.a`, `.la`,
  `.dll`) — they stay inside the store.

A skipped link is not an install failure: the package remains staged in the
store. Existing links that point into the store are replaced normally, so
upgrades keep working. Pass `--force` to consciously override either guard, or
`--as NAME` to install under a non-conflicting command name:

```sh
klua install git                # warns and leaves ~/.local/bin/git alone
klua install --force git        # creates the link anyway
klua install --as jq2 jq        # links ~/.local/bin/jq2 instead of ~/.local/bin/jq
```

`--as` renames only the primary binary; additional binaries from the same
package keep their own names. It requires a single target, rejects path
separators and `.`/`..`, and still goes through all conflict checks using the
chosen name.

### run

```sh
klua run jq --version
klua run gh:jqlang/jq -r '.version'
```

`run` picks a non-library executable from the newest installed store version,
installs the package store-only (no symlinks) if needed, and executes it with
store `bin` directories prepended to `PATH` and store library directories on
`LD_LIBRARY_PATH` (macOS: `DYLD_LIBRARY_PATH`). Arguments after the target —
including flags — are passed through unchanged; use `--` to separate them
explicitly.

### search / info

```sh
klua search bzip3   # substring match in aliases and targets, all shards a-z + _
klua info fd        # alias resolution, installed versions, links, release info
```

`search` walks every shard of every configured registry (taps first) and
prints `alias<TAB>target` matches sorted by alias; the first registry that
defines an alias wins. `info` works offline for local state and only emits a
warning if release metadata cannot be fetched.

### cleanup / doctor

```sh
klua cleanup        # keep newest version per package; remove stale links/caches
klua doctor         # report dirs, PATH, registries, broken/shadowed links
```

Version ordering is digit-aware (`1.10.0` is newer than `1.9.0`). `cleanup`
removes old store versions, symlinks pointing to missing store files, library
links, and the `downloads/` and `build/` caches. `doctor` exits `1` only for
real errors (e.g. unwritable directories); warnings are informational.

### add / sync

```sh
klua add gh:jqlang/jq fd         # record targets in packages.yaml (deduped)
klua sync                        # install everything in packages.yaml
klua sync ./dotfiles.yaml        # explicit local source
klua sync https://host/set.yaml  # remote source; follows includes:
```

`packages.yaml` supports `includes:` (recursive, cycle-safe) and
`packages:`; duplicate targets are installed once. A bare YAML list is
also accepted as a source.

### upgrade

```sh
klua upgrade                     # every installed gh/gl package
klua upgrade gh:jqlang/jq        # one target (aliases resolved too)
```

Reinstalls the latest release and reports `upgraded X: old -> new` or
`X is up to date (version)`.

### tap / list

```sh
klua tap add https://example.com/my-registry
klua tap list
klua tap remove https://example.com/my-registry
klua list                        # provider:user/repo  version, from the store
```

### remove / rm / uninstall

```sh
klua remove fd                   # alias target
klua rm gh:jqlang/jq             # scheme target
klua uninstall url:https://example.com/tool.tar.gz
```

Removal is complete: symlinks in `~/.local/bin` that point into the
package's store directory are deleted, the store tree
(`~/.local/share/klua/store/<provider>/<user>/<repo>/`) is removed, and
matching entries in `packages.yaml` (bare alias, resolved target, or
untagged scheme target) are pruned. Removing a package that is not
installed reports an error and changes nothing.

### repair

```sh
klua repair
klua repair --dry-run    # or: klua repair --diff
```

Restores `~/.config/klua/init.lua` from the clean embedded baseline.
Implemented natively in C++, so it works even when Lua is broken. Before
overwriting, the current file is copied to
`~/.config/klua/init.lua.bak.<timestamp>` and the backup path is printed —
custom Lua is never silently destroyed. If the file already matches the
baseline, nothing is written. `--dry-run` / `--diff` prints the backup path
and a unified diff of the pending change and leaves all files untouched.

## Self-healing behavior

Startup sequence on every command except `repair`:

1. The embedded Lua baseline (baked into the binary at build time) loads
   first and always succeeds.
2. Your `~/.config/klua/init.lua` runs in a protected call on top of it.
3. If your file has a syntax or runtime error, klua prints the Lua
   diagnostic, discards all Lua state, reloads the embedded baseline, and
   continues with default logic:

```
error: failed to load /home/you/.config/klua/init.lua: [string "..."]:1: ...
warning: falling back to the built-in default logic. Run 'klua repair' to restore a clean init.lua.
```

A broken config never bricks the tool. Fix the file, or run `klua repair`.

## Exit codes

`0` success, `1` any failure (usage errors, provider errors, Lua errors).
Lua command handlers may return other codes; the CLI passes them through.

## Next steps

- Customize providers and hooks: [lua-api.md](lua-api.md)
- Package your own repo: [klua-yaml.md](klua-yaml.md)
- Run or contribute to a registry: [taps-and-registry.md](taps-and-registry.md)
