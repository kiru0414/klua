#include "paths.hpp"

#include <cstdlib>
#include <string>

namespace klua::paths {

namespace fs = std::filesystem;

namespace {

// Read an environment variable; return an empty string when unset/empty.
std::string env_or_empty(const char* name) {
    const char* value = std::getenv(name);
    return value != nullptr ? std::string{value} : std::string{};
}

// Resolve an XDG directory: use the override when it is an absolute path,
// otherwise fall back to the spec default relative to $HOME.
fs::path xdg_dir(const char* env_name, const fs::path& home_relative) {
    const std::string override_value = env_or_empty(env_name);
    if (!override_value.empty()) {
        fs::path override_path{override_value};
        if (override_path.is_absolute()) {
            return override_path;
        }
    }
    return home_dir() / home_relative;
}

} // namespace

fs::path home_dir() {
    const std::string home = env_or_empty("HOME");
    if (!home.empty()) {
        return fs::path{home};
    }
    // Last resort: the current working directory (HOME should always be set
    // on POSIX systems).
    return fs::current_path();
}

fs::path config_dir() {
    return xdg_dir("XDG_CONFIG_HOME", fs::path{".config"}) / "klua";
}

fs::path store_dir() {
    return xdg_dir("XDG_DATA_HOME", fs::path{".local"} / "share") / "klua" / "store";
}

fs::path bin_dir() {
    return home_dir() / ".local" / "bin";
}

fs::path cache_dir() {
    return xdg_dir("XDG_CACHE_HOME", fs::path{".cache"}) / "klua";
}

fs::path user_init() {
    return config_dir() / "init.lua";
}

fs::path packages_file() {
    return config_dir() / "packages.yaml";
}

fs::path taps_file() {
    return config_dir() / "taps.yaml";
}

bool ensure_dir(const fs::path& dir) {
    if (dir.empty()) {
        return false;
    }
    std::error_code ec;
    fs::create_directories(dir, ec);
    return !ec && fs::is_directory(dir, ec);
}

} // namespace klua::paths
