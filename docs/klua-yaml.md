# klua.yaml — in-repo package manifests

When installing `gh:user/repo` or `gl:user/repo`, klua first fetches
`klua.yaml` from the repository root:

```
https://raw.githubusercontent.com/<user>/<repo>/<ref>/klua.yaml   (gh)
https://gitlab.com/<user>/<repo>/-/raw/<ref>/klua.yaml            (gl)
```

`<ref>` is the pinned tag (`repo@tag`) or `HEAD`. If the file exists and
parses, it overrides the release heuristics. If it is missing, invalid, or
comment-only, klua silently falls back to asset scoring.

> **Safer than Homebrew, simpler than Nix, and infinitely hackable in Lua.**
> A manifest only describes what lives in the isolated store; the core decides
> *how* it is exposed: library files stay in the store, PATH conflicts are
> checked before every symlink, downloads are checksum-verified, and Lua hooks
> can refine the policy.

## v0.4.0+ manifest integration

- `bins` are passed through the same conflict-safe linker as auto-detected
  executables. Library-looking names (`.so`, `.so.*`, `.dylib`, `.a`, `.la`,
  `.dll`) are skipped with a warning and never linked into `~/.local/bin`.
- `klua install --as NAME` links the **primary** manifest binary as `NAME`;
  additional `bins` keep their own basenames. `klua install --force` overrides
  protected-command or PATH-collision guards for the chosen name.
- `klua run <target> [args...]` executes a manifest binary straight from the
  store with store libraries on `LD_LIBRARY_PATH` / `DYLD_LIBRARY_PATH`,
  without creating symlinks.
- Manage installed manifests with `klua search`, `klua info`, `klua cleanup`,
  `klua doctor` and `klua remove` (aliases `rm`, `uninstall`). Typos in these
  names or in flags get Levenshtein suggestions.
- v0.5.0 resolves `gh:` releases without the REST API (HEAD redirect +
  `expanded_assets`) and verifies the selected asset against a matching
  `.sha256`, `.sha256sum` or `checksums.txt` before extraction. Use
  `--skip-checksum` for an explicit bypass; use `--no-cache` to refetch alias
  shards rather than the one-hour cached copy.
- v0.6.0 adds `depends:` for system-package delegation. Missing packages are
  collected from the whole invocation and installed in one manager command;
  already-installed packages are skipped. `--lock` / `--locked` record and
  reproduce resolved versions, URLs and digests in `packages.lock.yaml`.
- Custom Lua in `init.lua` can override the provider or command handlers that
  consume manifests. `klua repair` backs up your `init.lua` to
  `init.lua.bak.<timestamp>` before restoring the baseline; preview with
  `klua repair --dry-run` / `--diff`.

Generate a starter in any repo:

```sh
klua init-manifest            # writes ./klua.yaml, refuses to overwrite
klua init-manifest --force    # overwrite
```

## Schema

All fields are optional. Unknown fields are ignored.

```yaml
depends:                     # system packages (batched) or other targets
  - git
  - sys:curl
  - gh:jqlang/jq

assets:                      # list of glob patterns
  - "mytool-*-linux-*.tar.gz"

bins:                        # list of paths relative to the store root
  - mytool
  - bin/helper

configs:                     # list of {src, dest} mappings
  - src: config.example.toml
    dest: ~/.config/mytool/config.toml

build:
  steps:                     # list of shell commands
    - cargo build --release
```

## assets

Explicit release-asset selection. Patterns support `*` (any run of
characters) and `?` (one character); matching is case-sensitive and
anchored (the whole asset name must match).

- The first asset matching any pattern wins (assets are scanned in web/API
  order, patterns in list order).
- Checksum sidecars are ignored for selection but are kept for verification
  after download.
- When `assets` is present it **replaces** OS/arch scoring entirely —
  include the OS/arch tokens in your patterns yourself.
- If nothing matches, klua falls through to `build.steps` (if present),
  otherwise the install fails.

```yaml
assets:
  - "mytool-*-x86_64-unknown-linux-musl.tar.gz"
  - "mytool-*-linux-amd64.tar.gz"     # fallback pattern
```

Without `assets`, klua scores every release asset: OS token must match
(`linux`, or `darwin`/`macos`/`apple`), wrong-architecture assets are
rejected, checksums/signatures/packages (`.sha256`, `.sig`, `.deb`,
`.rpm`, ...) are ignored, exact-arch matches score highest, archives and
musl builds get small bonuses.

## bins

Binaries to make executable and symlink into `~/.local/bin`. Paths are
relative to the store root (i.e. the extracted archive after the
single-top-level-directory strip). Each entry is linked under its
basename:

```yaml
bins:
  - nvim            # -> ~/.local/bin/nvim
  - bin/extra-tool  # -> ~/.local/bin/extra-tool
```

- Missing paths fail the install with a clear error.
- Without `bins`, klua auto-detects executables (ELF/Mach-O magic bytes or
  any exec bit) and links the best candidate: name matching the repo
  first, then files under `bin/`, then the shortest path.
- Raw (non-archive) release assets without `bins` are linked under the
  repo name (`jq-linux-amd64` -> `jq`).
- Every link is checked against `PATH` and the protected-command list before
  it is created. A conflict produces a warning, not a failed install: the
  package stays in the store. Use `--force` to override, or
  `klua install --as NAME <target>` to choose a different command name for
  the primary binary.

## configs

Files copied out of the store into user locations after linking:

```yaml
configs:
  - src: config.example.toml          # relative to the store root
    dest: ~/.config/mytool/config.toml
  - src: completions/
    dest: ~/.local/share/bash-completion/completions/   # trailing / = directory
```

- `~` expands to `$HOME`.
- A trailing `/` on `dest` means "copy into this directory" (the source
  basename is appended).
- Parent directories are created; existing files are overwritten.
- A missing `src` fails the install.

## depends

System packages required by the tool. Entries without a scheme, or with a
system scheme (`sys:`, `apt:`, `apt-get:`, `dnf:`, `yum:`, `pacman:`, `apk:`,
`brew:`), are validated, deduplicated and queued for **one** installer command:

```yaml
depends:
  - git
  - sys:curl,wget
  - brew:jq
  - target: gh:jqlang/jq    # non-system target, installed via its own provider
  - system:                 # grouped form is also supported
      - ca-certificates
      - openssl
```

- Package status is checked with the detected manager before anything is
  queued, so already-installed packages are reported and skipped.
- All missing packages across the manifest and the command line are installed
  together, once per `klua` invocation. For source builds the batch is flushed
  before the first `build.steps` command runs.
- Non-system targets (for example `gh:user/repo` or a bare alias) are installed
  through their normal providers and deduplicated per invocation.
- `klua.system.manager`, `klua.system.status(pkg)` and
  `klua.system.install(pkgs)` can override detection and commands in
  `init.lua`; see [lua-api.md](lua-api.md#system-package-delegation).
- A failed system install fails the overall install; system packages are not
  recorded in `packages.lock.yaml`.

## build.steps

Source build fallback, used when there is **no release** or **no suitable
asset**:

```yaml
build:
  steps:
    - cargo build --release
    - strip target/release/mytool
bins:
  - target/release/mytool
```

Mechanics:

1. `git clone --depth 1` (plus `--branch <tag>` when pinned) into
   `~/.cache/klua/build/<user>-<repo>`.
2. Each step runs as `cd <clone> && <step>` via the system shell; any
   non-zero exit aborts the install.
3. Produced binaries are collected: `bins` entries first; otherwise the
   first non-empty of `target/release/`, `build/`, `bin/`; otherwise a
   full scan of the clone for executables.
4. Binaries are copied into the store under version `source` (or the
   pinned tag), chmod'ed, and symlinked. `configs` apply as usual.

The clone URL base is overridable (`klua.github_clone` / `klua.gitlab_clone`
in `init.lua`) for mirrors and local testing.

## Complete examples

Raw-binary release, no manifest needed — but explicit naming:

```yaml
bins:
  - mytool
```

Archive with docs and a config file:

```yaml
assets:
  - "mytool-*-linux-*.tar.gz"
bins:
  - mytool
configs:
  - src: config.example.toml
    dest: ~/.config/mytool/config.toml
```

No releases at all, pure source build:

```yaml
build:
  steps:
    - make -j4
bins:
  - build/mytool
```

## Precedence summary

1. Manifest `assets` patterns > OS/arch scoring.
2. Manifest `bins` > executable auto-detection.
3. Release install > `build.steps` (build only runs when no release or no
   matching asset).
4. Missing/invalid manifest > nothing — heuristics proceed unchanged.
