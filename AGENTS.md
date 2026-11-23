# AGENTS.md - Project Instructions for `klua`

## 1. Project Overview
`klua` is a fast, zero-dependency, self-healing package manager built with **C++20** and **Lua 5.4** (`sol2`), targeting **Unix-like systems (Linux & macOS)**.
- **Core Philosophy:** Heavy lifting (HTTP, archive extraction, filesystem operations, YAML parsing) is handled natively in C++20. Resolution logic, custom downloaders, and lifecycle hooks are extensible via Lua.
- **Language Policy:** All CLI output, error messages, code comments, and documentation must be strictly in **English**. Do not implement multi-language/i18n support.
- **Platform Policy:** Target **Linux and macOS (POSIX)** first. Use standard XDG directories and POSIX symlinks (`std::filesystem::create_symlink`). Windows support is out of scope for MVP.

---

## 2. Directory & XDG Standards
Respect standard Unix user directories at runtime:
- **Config:** `~/.config/klua/` (`init.lua`, `packages.yaml`, `taps.yaml`)
- **Storage (Store):** `~/.local/share/klua/store/<provider>/<user>/<repo>/<version>/` (Extract archives intact here to preserve relative paths for complex tools like Neovim)
- **Entrypoint (Bin):** `~/.local/bin/<binary_name>` (Symlink pointing to the actual executable inside `store/`)
- **Cache:** `~/.cache/klua/`

---

## 3. Architecture & Core Mechanics

### A. Embedded Default Logic (Self-Healing)
- At build time, CMake embeds `builtin/default_init.lua` into a generated C++ header (`embedded_assets.hpp`) using raw string literals `R"KLUA(...)KLUA"`.
- On startup, load the embedded Lua baseline first, then safely execute `~/.config/klua/init.lua` via `sol::protected_function` / `safe_script`.
- If the user's `init.lua` has syntax or runtime errors, print a clear English error message and automatically fall back to the embedded default logic.
- `klua repair` forcefully overwrites `~/.config/klua/init.lua` with the clean embedded Lua.

### B. Package Resolution Pipeline (`klua install <target>`)
1. **Direct Scheme:** If `<target>` contains `:` (e.g., `gh:user/repo`, `gl:user/repo`, `url:https://...`, `apt:pkg`), dispatch directly to the registered Lua provider for that scheme.
2. **Alias Sharding Lookup:** If `<target>` has no `:` (e.g., `rg`, `gzip-search`), extract the lowercase first character (`r`, `g`, or `_` for non-alpha) and fetch `v1/<char>.yaml` from configured registry URLs / Taps. Parse YAML in-memory (RAII) to resolve the alias to a scheme target.
3. **In-Repo Manifest (`klua.yaml`):** When installing from a Git repository (`gh:` / `gl:`), check for `klua.yaml` at the repo root first. If present, follow its `assets`, `bins`, `configs`, or `build.steps`.
4. **Heuristic Fallback (No `klua.yaml`):**
   - Query Releases API and score assets by OS (`linux`, `darwin`/`macos`) and Arch (`x86_64`/`amd64`, `arm64`/`aarch64`), ignoring `.sha256`, `.sig`, `.deb`, `.rpm`.
   - Extract archive intact into `store/`, auto-strip single top-level directory if present, locate executable binary (ELF/Mach-O magic bytes or executable permissions), `chmod +x`, and symlink to `~/.local/bin/`.
   - If no release binaries exist, fallback to `git clone` and auto-detect build system (`CMakeLists.txt`, `Cargo.toml`, `go.mod`, `Makefile`).

---

## 4. Tech Stack & Coding Conventions
- **Standard:** C++20 (`-std=c++20`), clean RAII, avoid raw `new`/`delete`.
- **Dependencies (via CMake `FetchContent`):**
  - `Lua 5.4` (static) + `sol2` (C++/Lua bindings)
  - `CLI11` (CLI subcommand parsing: `install`/`i`, `add`, `sync`, `upgrade`, `repair`, `tap`, `list`)
  - `yaml-cpp` (In-memory YAML parsing and clean list deduplication)
  - `cpp-httplib` (with OpenSSL) or `libcurl` (HTTPS requests & downloads)
  - `nlohmann/json` (GitHub/GitLab Releases API parsing)
  - `libarchive` (or system `tar`/`unzip` fallback for MVP)
- **Code Style:**
  - Namespace: `klua`
  - Keep C++ core primitives generic (`klua.http_get`, `klua.download`, `klua.extract`, `klua.symlink`, `klua.exec`, `klua.register_provider`) so business logic stays customizable in Lua.

---

## 5. Development Roadmap (Implement in Order)
1. **Milestone 1 (Core Skeleton):** CMake setup with `builtin/default_init.lua` embedding, `CLI11` commands, `sol2` engine with self-healing fallback, and `klua repair`.
2. **Milestone 2 (Fetcher & Installer):** HTTPS client, `v1/<char>.yaml` in-memory alias resolver, GitHub Releases JSON parser, archive extraction to `~/.local/share/klua/store/`, and symlink creation in `~/.local/bin/`.
3. **Milestone 3 (Manifest & Sync):** `klua.yaml` support, `klua sync <local_or_url_yaml>` with automatic source deduplication, and `klua upgrade`.
