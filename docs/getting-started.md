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

[v0.9.0](https://github.com/kiru0414/klua/releases/download/v0.9.0/klua-v0.9.0-linux-x86_64.tar.gz)

```sh
curl -fsSL https://raw.githubusercontent.com/kiru0414/klua/main/install.sh | bash
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
| Config  | `~/.config/klua/` (`init.lua`, `packages.yaml`, `packages.lock.yaml`, `taps.yaml`) | `XDG_CONFIG_HOME` |
| Store   | `~/.local/share/klua/store/<provider>/<user>/<repo>/<version>/` | `XDG_DATA_HOME` |
| URL store | `~/.local/share/klua/store/url/<host>/<stem>-<url-hash>/direct/` | `XDG_DATA_HOME` |
| Bin     | `~/.local/bin/<name>` (symlinks into the store) | none (always `~/.local/bin`) |
| Cache   | `~/.cache/klua/` (`downloads/`, `checksums/`, `build/`, `shards/`) | `XDG_CACHE_HOME` |

Overrides are honored only when absolute. Archives are extracted intact
into the store (single top-level wrapper directories are stripped), so
relative layouts of complex tools survive. `<url-hash>` is the first 12 hex
characters of the SHA-256 of the full canonical URL, which keeps same-named
`url:` downloads from different paths isolated.

## Design philosophy

- **Isolated store:** binaries and libraries live under
  `~/.local/share/klua/store/...`; `~/.local/bin` contains only symlinks.
- **No shared library pollution:** library-looking files are never linked
  globally; `klua run` exposes store libraries only to the launched process.
- **Automatic PATH conflict protection:** klua scans `PATH`, skips/warns on
  collisions, protects core commands, and offers `--force` / `--as` instead of
  silently overwriting your system.
- **Reproducible installs:** `sync --lock` records versions, URLs and digests;
  `sync --locked` reuses them without release discovery and refuses mismatches.
- **Self-evolving Lua customization:** `init.lua` can replace providers and
  command handlers; the embedded baseline is always the safe fallback.

## CLI

```
klua install [--force] [--as NAME] [--no-cache] [--skip-checksum] [--lock|--locked] [--dry-run] [--select] [--yes] <target>...  (alias: klua i)
klua run [--no-cache] [--skip-checksum] [--yes] [--upgrade|--latest] <target> [--] [args...]  # store-only
klua search [--no-cache] <query>
klua info [--no-cache] <target>
klua cleanup [--no-cache]
klua doctor [--no-cache]
klua add <target>...
klua remove [--no-cache] [--yes] <target>...    (aliases: klua rm, klua uninstall)
klua sync [--no-cache] [--skip-checksum] [--lock|--locked] [--dry-run] [--yes] [path_or_url]
klua upgrade [--no-cache] [--skip-checksum] [--lock] [--dry-run] [--yes] [target...]
klua outdated [--no-cache] [target...]
klua versions [--no-cache] <target>
klua use <target>@<version>
klua tap <add|remove|list> [url]
klua list
klua repair [--dry-run|--diff]
klua init-manifest [--force]
klua --version | --help
```

Mistyped subcommands, flags, and aliases get a Levenshtein-based hint. The
suggestion dictionary includes `install`, `run`, `search`, `info`, `cleanup`,
`doctor`, `remove`/`rm`/`uninstall`, and flags such as `--force`, `--as`,
`--no-cache`, `--skip-checksum`, `--lock`, `--locked`, `--dry-run`, `--diff`,
`--yes`, `-y`, `--latest` and `--upgrade`:

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
klua install sys:git,curl        # install missing system packages in one batch
klua install apt:jq              # same delegation with an explicit manager
klua install fd                  # alias -> v1/f.yaml -> gh:sharkdp/fd
```

Pipeline: direct scheme dispatch, or alias sharding lookup, then (for gh/gl)
release discovery (API-free for `gh:`) and an in-repo
[`klua.yaml`](klua-yaml.md) check at the resolved tag, followed by asset
scoring by OS/arch, download, SHA-256 verification, extraction into the store,
binary discovery (ELF/Mach-O magic or exec bits), `chmod +x`, conflict-checked
symlink into `~/.local/bin`. See
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

Release discovery is a fail-safe three-tier chain. If the expanded-assets page
cannot be fetched or parses to **zero** download links, klua immediately reads
`releases.atom` next. If the feed has no usable asset link either, it finally
calls the REST API. An empty scrape is always a failure, never an empty
success, so a changed GitHub layout cannot silently produce a broken install.
Successful resolutions are cached for the rest of the invocation.

When the REST tier runs, `GITHUB_TOKEN` or `GH_TOKEN` (in that order) is sent
automatically as
`Authorization: Bearer ...`. For a trusted custom API host, set
`KLUA_GITHUB_API_HOST` to that hostname; the token is then limited to
API-looking paths on that host.

HTTP requests follow `301/302/307/308` redirects across hosts, sending
`User-Agent: klua/<version>` on every hop and dropping API tokens when the
host or API path changes. This fixes `HTTP 403` on GitHub repo renames and
githubusercontent S3 URLs.

GitLab releases use `klua.gitlab_api` directly. When `GITLAB_TOKEN` is set,
requests to GitLab API endpoints receive both `PRIVATE-TOKEN` and
`Authorization: Bearer ...`. For a self-hosted instance set
`KLUA_GITLAB_API_HOST` to its hostname. In both cases tokens are only attached
to API-looking paths (`/api/...` or `/repos/...`); raw files and asset
downloads never receive them.

### Registry shard cache

Fetched `v1/<char>.yaml` shards are stored under `~/.cache/klua/shards/` with
a one-hour TTL (`klua.shard_ttl` in `init.lua`). Repeated installs and
`klua search` runs reuse the cached body. `klua search` sends every missing
shard through `klua.http_get_batch`, a bounded C++20 worker pool with at most
eight concurrent requests; results are cached in input order. `--no-cache`
forces a fresh fetch;
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

Locked installs are stricter: the SHA-256 recorded in `packages.lock.yaml` is
always enforced (trust on first use). If upstream bytes change after the lock
is written, `sync --locked` aborts on the hash mismatch before extraction —
even if the lockfile itself was never edited. `--locked` and
`--skip-checksum` cannot be combined.

GitLab releases go through the same verification path. Registries and
checksum files themselves are not signed; this protects against truncated or
corrupted downloads, not maliciously published checksums.

### Signature verification hook

For signed artifacts, add `verify:` to `klua.yaml` (or set
`klua.verify.command` in `init.lua`). The command runs after checksum
verification and before extraction; a non-zero exit aborts the install.
Placeholders `{payload}`, `{asset}`, `{version}`, `{target}` and `{sha256}`
are substituted with shell-safe quoting, and the payload path is appended
when the template does not name it:

```yaml
verify: "cosign verify-blob --signature {payload}.sig --certificate {payload}.pem {payload}"
```

```lua
-- Global alternative in ~/.config/klua/init.lua
klua.verify = {
    command = "cosign verify-blob {payload}",
    hook = function(ctx)
        if ctx.sha256 == "" then return false end
        return true
    end,
}
```

A manifest `verify: false` disables hooks for that package. Verification
fails closed: a missing tool or a rejected hook stops the install. See
[lua-api.md](lua-api.md#signature-verification).

### Remote command approval

Commands from a remote `klua.yaml` are not trusted by default. Before running
`build.steps` or a manifest `verify:` command, klua prints every command and
asks for approval. Only `y` or `yes` is accepted; EOF (non-interactive stdin)
and any other answer deny the request and abort the install. Scripts should
pass `--yes` / `-y` to `install`, `remove`, `run`, `sync` or `upgrade`:

```sh
klua install gh:user/source-only-tool   # prompts before build.steps
klua install --yes gh:user/source-only-tool
klua sync -y
```

Local `init.lua` hooks are trusted; approval protects commands embedded in
remote repository manifests. `--dry-run` skips both the prompt and execution.

### System package delegation

`sys:pkg1,pkg2,...` and the explicit manager schemes (`apt:`, `apt-get:`,
`dnf:`, `yum:`, `pacman:`, `apk:`, `brew:`) delegate to the host package
manager. klua checks each package's installed status first, skips anything
already present, and queues the rest. Every missing package from one CLI
invocation is installed with **one** manager command (`sudo apt-get install -y
...` on Debian/Ubuntu, `brew install ...` on macOS, etc.) instead of spawning
`sudo` once per package. A package listed in a manifest's
[`depends:`](klua-yaml.md#depends) uses the same queue. When the process is not
root and `sudo` is available, `apt`/`apt-get`, `dnf`, `yum`, `pacman` and `apk`
commands are prefixed with `sudo` automatically; `brew` is never elevated.

```sh
klua install sys:git,curl,wget   # one batch; already-installed packages skipped
klua install apt:jq              # force a particular manager scheme
```

The manager is detected at runtime from `dpkg-query`, `dnf`, `yum`, `pacman`,
`apk` and `brew`. In `init.lua`, set `klua.system.manager` to override it, or
provide `klua.system.status(pkg)` / `klua.system.install(pkgs)` hooks for
custom environments. See [lua-api.md](lua-api.md#system-package-delegation).

### Locked installs

`packages.lock.yaml` lives beside `packages.yaml` in the config directory and
records the exact provider, version, asset URL and SHA-256 for every resolved
target:

```yaml
version: 1
entries:
  gh:jqlang/jq:
    provider: gh
    version: jq-1.7.1
    asset: jq-linux-amd64
    url: https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64
    sha256: 0123456789abcdef...
```

```sh
klua sync --lock      # resolve normally, then write/update the lockfile
klua sync --locked    # require the lockfile; install exactly what it records
klua install --locked gh:jqlang/jq
```

With `--locked`, klua refuses to run without a lockfile or if a target is
missing from it. It skips latest-tag redirects, release pages and REST API
calls, downloads the recorded URL, and verifies the recorded digest before
extraction. A tag that disagrees with the locked version, a changed URL, or a
hash mismatch fails the install. `--locked` is mutually exclusive with
`--lock` and `--skip-checksum`. `upgrade --lock` refreshes entries;
`upgrade --locked` is rejected because upgrading is the opposite of a locked
reproduction. System packages and custom schemes are not locked.

`klua remove` prunes matching entries from `packages.lock.yaml` even without
`--lock`, so a later `sync --locked` does not reinstall an intentionally
removed package. Custom handlers can call `klua.lockfile.prune(removed)`.

### Dry-run previews

`sync --dry-run` and `upgrade --dry-run` resolve their inputs and print what
would happen — including the exact shell command generated for any missing
`sys:` packages — without downloading archives, changing the store, creating
links or writing the lockfile. `upgrade --dry-run` reports planned version
changes as `v1.0.0 -> v2.0.0`. `--dry-run` is rejected with `--lock`; use it as
a read-only planning step before the real command. `install --dry-run <target>`
uses the same read-only path for a single install: it prints the resolved
package, its version and the planned `sys:` commands, and never modifies the
store, links or lockfile.

```sh
klua install --dry-run jq           # preview one install
klua sync --dry-run                 # preview packages.yaml actions
klua upgrade --dry-run gh:jqlang/jq # preview one upgrade
```

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
klua run --upgrade gh:jqlang/jq@jq-1.7.0   # ignore the pin; run the latest release
klua run --latest jq                       # alias for --upgrade
```

`run` picks a non-library executable from the newest installed store version,
installs the package store-only (no symlinks) if needed, and executes it with
store `bin` directories prepended to `PATH` and store library directories on
`LD_LIBRARY_PATH` (macOS: `DYLD_LIBRARY_PATH`). Arguments after the target —
including flags — are passed through unchanged; use `--` to separate them
explicitly. Klua flags must appear **before** the target. `--upgrade` /
`--latest` strip a pinned `@tag`, stage the newest release in the store, and
run that binary without creating links.

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
klua sync --lock                 # write versions/URLs/digests to the lockfile
klua sync --locked               # reproduce exactly from the lockfile
klua sync --dry-run              # preview actions without touching state
```

`packages.yaml` supports `includes:` (recursive, cycle-safe) and
`packages:`; duplicate targets are installed once. A bare YAML list is
also accepted as a source. When more than one archive must be fetched,
`sync` resolves all targets first and then downloads them through
`klua.download_batch` (the same bounded eight-worker pool used for shards),
printing `batch: downloading N asset(s) in parallel`. Failed prefetches are
retried by the normal provider path.

See [Locked installs](#locked-installs) for lock semantics.

### upgrade

```sh
klua upgrade                     # every installed gh/gl package
klua upgrade gh:jqlang/jq        # one target (aliases resolved too)
klua upgrade --dry-run           # preview version changes and sys commands
klua outdated                    # list packages with newer releases available
klua outdated gh:jqlang/jq       # check one explicit target
```

`upgrade` uses the same parallel prefetch as `sync` when several packages are
upgraded at once.

Reinstalls the latest release and reports `upgraded X: old -> new` or
`X is up to date (version)`. Add `--lock` to refresh locked entries for the
newly resolved versions. `outdated` is read-only: it compares installed
`gh:` / `gl:` versions with the newest release and prints
`outdated: <target> <installed> -> <latest>` for each upgrade, or
`outdated: all checked packages are up to date`.

### Version selection

```sh
klua install rg@14.0.0       # resolve the alias, then pin that release
klua install --select jq     # numbered release menu; requires TTY/stdin
klua versions jq             # list releases; mark installed/active/pinned
klua use jq@jq-1.7.1         # instant OFFLINE relink to an installed version
klua remove jq@jq-1.7.1      # remove one version, relink the newest
```

`@VERSION` pins work for bare aliases as well as scheme targets. `versions`
lists available releases from the GitHub/GitLab API, marking installed, active
and pinned versions; when the API is unavailable it falls back to locally
installed versions. `--select` prints a numbered menu and installs the pinned
version for the index you enter (a missing TTY/stdin answer cancels). `use` is
fully offline — no download, API call or store extraction — and reuses the
exact link set recorded at install time, falling back to executable discovery
only when no snapshot exists. `remove` with `@version` deletes just that
stored version and relinks the newest remaining one; removing the last version
prunes symlinks and package/lock entries as before and drops a stale
`--locked` pin for the removed version.

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
untagged scheme target) are pruned. Matching `packages.lock.yaml` entries
are pruned too, so `--locked` cannot resurrect the removed package. Removing
a package that is not installed reports an error and changes nothing.

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
