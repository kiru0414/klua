#pragma once

#include <filesystem>

namespace klua::paths {

// XDG-aware directory layout (Linux & macOS). Environment overrides follow
// the XDG Base Directory Specification; the defaults match AGENTS.md.

std::filesystem::path home_dir();

// $XDG_CONFIG_HOME/klua or ~/.config/klua
std::filesystem::path config_dir();

// $XDG_DATA_HOME/klua/store or ~/.local/share/klua/store
std::filesystem::path store_dir();

// ~/.local/bin (symlink entrypoints; intentionally not XDG-overridable)
std::filesystem::path bin_dir();

// $XDG_CACHE_HOME/klua or ~/.cache/klua
std::filesystem::path cache_dir();

// Individual files inside config_dir().
std::filesystem::path user_init();      // init.lua
std::filesystem::path packages_file();  // packages.yaml
std::filesystem::path taps_file();      // taps.yaml

// Create a directory (and parents) if missing. Returns false on failure.
bool ensure_dir(const std::filesystem::path& dir);

} // namespace klua::paths
