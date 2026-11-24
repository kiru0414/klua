#include "lua_engine.hpp"

#include "archive.hpp"
#include "crypto.hpp"
#include "fsops.hpp"
#include "http.hpp"
#include "klua/embedded_assets.hpp"
#include "paths.hpp"
#include "serialize.hpp"
#include "sys.hpp"

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <tuple>

namespace klua {

namespace fs = std::filesystem;

namespace {

void print_error(const std::string& message) {
    std::cerr << "error: " << message << '\n';
}

// Compile-time platform identification for asset scoring in Lua.
const char* platform_os() {
#if defined(__APPLE__)
    return "macos";
#elif defined(__linux__)
    return "linux";
#else
    return "unknown";
#endif
}

const char* platform_arch() {
#if defined(__x86_64__) || defined(_M_X64)
    return "x86_64";
#elif defined(__aarch64__) || defined(__arm64__)
    return "arm64";
#else
    return "unknown";
#endif
}

} // namespace

void LuaEngine::reset() {
    lua_ = sol::state{};
}

void LuaEngine::bootstrap() {
    lua_.open_libraries(sol::lib::base, sol::lib::string, sol::lib::table,
                        sol::lib::math, sol::lib::os, sol::lib::coroutine,
                        sol::lib::utf8);
    bind_natives();

    // The embedded baseline must always load; failure here is a build bug.
    auto result = lua_.safe_script(assets::default_init_lua, sol::script_pass_on_error);
    if (!result.valid()) {
        sol::error err = result;
        throw std::runtime_error(std::string{"embedded default_init.lua failed: "} + err.what());
    }
}

void LuaEngine::bind_natives() {
    sol::table k = lua_.create_named_table("klua");

    k["version"] = KLUA_VERSION;
    k["providers"] = lua_.create_table();
    k["commands"] = lua_.create_table();

    // XDG-aware directory layout, exposed as plain strings.
    sol::table paths_table = lua_.create_table();
    paths_table["config"] = paths::config_dir().string();
    paths_table["store"] = paths::store_dir().string();
    paths_table["bin"] = paths::bin_dir().string();
    paths_table["cache"] = paths::cache_dir().string();
    paths_table["shards"] = paths::shards_dir().string();
    paths_table["init"] = paths::user_init().string();
    paths_table["packages"] = paths::packages_file().string();
    paths_table["taps"] = paths::taps_file().string();
    k["paths"] = paths_table;

    // Logging primitives (all output is English, per project policy).
    k.set_function("info", [](const std::string& message) {
        std::cout << message << '\n';
    });
    k.set_function("warn", [](const std::string& message) {
        std::cerr << "warning: " << message << '\n';
    });
    k.set_function("error", [](const std::string& message) {
        print_error(message);
    });

    // Filesystem primitives (RAII, std::filesystem only).
    k.set_function("file_exists", [](const std::string& path) {
        std::error_code ec;
        return fs::exists(fs::path{path}, ec);
    });

    k.set_function("is_dir", [](const std::string& path) {
        std::error_code ec;
        return fs::is_directory(fs::path{path}, ec);
    });

    // True for regular files with any execute bit set. Used for PATH scans
    // before linking (conflict protection) and for doctor diagnostics.
    k.set_function("is_executable", [](const std::string& path) {
        std::error_code ec;
        const fs::file_status status = fs::status(fs::path{path}, ec);
        if (ec || !fs::is_regular_file(status)) {
            return false;
        }
        const fs::perms perms = status.permissions();
        return (perms & (fs::perms::owner_exec | fs::perms::group_exec
                         | fs::perms::others_exec))
            != fs::perms::none;
    });

    k.set_function("read_file", [](const std::string& path) -> sol::optional<std::string> {
        std::ifstream in{fs::path{path}, std::ios::binary};
        if (!in) {
            return sol::nullopt;
        }
        std::ostringstream buffer;
        buffer << in.rdbuf();
        return buffer.str();
    });

    k.set_function("write_file", [](const std::string& path, const std::string& content) {
        const fs::path target{path};
        std::error_code ec;
        if (target.has_parent_path()) {
            fs::create_directories(target.parent_path(), ec);
            if (ec) {
                return false;
            }
        }
        std::ofstream out{target, std::ios::binary | std::ios::trunc};
        if (!out) {
            return false;
        }
        out.write(content.data(), static_cast<std::streamsize>(content.size()));
        return out.good();
    });

    k.set_function("mkdir", [](const std::string& path) {
        return paths::ensure_dir(fs::path{path});
    });

    k.set_function("env", [](const std::string& name) -> sol::optional<std::string> {
        const char* value = std::getenv(name.c_str());
        if (value == nullptr) {
            return sol::nullopt;
        }
        return std::string{value};
    });

    k.set_function("cwd", []() {
        return fs::current_path().string();
    });

    // Generic process execution primitive; business logic stays in Lua.
    k.set_function("exec", [](const std::string& command) {
        return sys::run_command(command);
    });

    // --- Milestone 2 primitives: HTTP, archives, filesystem, parsing ------

    // HTTP GET: returns (body, status, err). err is nil on success.
    k.set_function("http_get",
                   [](const std::string& url)
                       -> std::tuple<std::string, long, sol::optional<std::string>> {
                       const http::Response response = http::get(url);
                       if (!response.error.empty()) {
                           return {std::string{}, 0L, response.error};
                       }
                       return {response.body, response.status, sol::nullopt};
                   });

    // HEAD without following redirects: returns (location, status, err).
    // Used for API-free GitHub "latest release" tag discovery.
    k.set_function("http_head_redirect",
                   [](const std::string& url)
                       -> std::tuple<std::string, long, sol::optional<std::string>> {
                       const http::HeadResponse response = http::head_redirect(url);
                       if (!response.error.empty()) {
                           return {std::string{}, 0L, response.error};
                       }
                       return {response.location, response.status, sol::nullopt};
                   });

    // Streaming download: returns (ok, err).
    k.set_function("download",
                   [](const std::string& url, const std::string& dest)
                       -> std::tuple<bool, sol::optional<std::string>> {
                       std::string error;
                       if (http::download(url, dest, error)) {
                           return {true, sol::nullopt};
                       }
                       return {false, error};
                   });

    // SHA-256 of a local file: returns (digest, err). Uses OpenSSL EVP.
    k.set_function("sha256",
                   [](const std::string& path)
                       -> std::tuple<std::string, sol::optional<std::string>> {
                       std::string error;
                       const std::string digest = crypto::sha256_file(path, error);
                       if (!error.empty()) {
                           return {std::string{}, error};
                       }
                       return {digest, sol::nullopt};
                   });

    // Archive extraction with single-top-level-directory stripping.
    k.set_function("extract",
                   [](const std::string& archive_path, const std::string& dest_dir)
                       -> std::tuple<bool, sol::optional<std::string>> {
                       std::string error;
                       if (archive::extract(archive_path, dest_dir, error)) {
                           return {true, sol::nullopt};
                       }
                       return {false, error};
                   });

    k.set_function("is_archive", [](const std::string& name) {
        return archive::is_archive_name(name);
    });

    k.set_function("symlink",
                   [](const std::string& target, const std::string& link)
                       -> std::tuple<bool, sol::optional<std::string>> {
                       std::string error;
                       if (fsops::symlink(target, link, error)) {
                           return {true, sol::nullopt};
                       }
                       return {false, error};
                   });

    // Raw symlink target (no resolution); nil when path is not a symlink.
    k.set_function("readlink", [](const std::string& path) -> sol::optional<std::string> {
        std::error_code ec;
        const auto target = fs::read_symlink(fs::path{path}, ec);
        if (ec) {
            return sol::nullopt;
        }
        return target.string();
    });

    k.set_function("chmod_exec",
                   [](const std::string& path)
                       -> std::tuple<bool, sol::optional<std::string>> {
                       std::string error;
                       if (fsops::chmod_exec(path, error)) {
                           return {true, sol::nullopt};
                       }
                       return {false, error};
                   });

    k.set_function("copy",
                   [](const std::string& src, const std::string& dest)
                       -> std::tuple<bool, sol::optional<std::string>> {
                       std::string error;
                       if (fsops::copy(src, dest, error)) {
                           return {true, sol::nullopt};
                       }
                       return {false, error};
                   });

    k.set_function("remove",
                   [](const std::string& path)
                       -> std::tuple<bool, sol::optional<std::string>> {
                       std::string error;
                       if (fsops::remove(path, error)) {
                           return {true, sol::nullopt};
                       }
                       return {false, error};
                   });

    // Executable candidates inside a directory tree (array of paths).
    k.set_function("find_executables", [this](const std::string& dir) {
        sol::table result = lua_.create_table();
        int index = 1;
        for (const auto& path : fsops::find_executables(dir)) {
            result[index++] = path;
        }
        return result;
    });

    // Directory listing: array of {name=..., path=..., is_dir=...}.
    k.set_function("list_dir", [this](const std::string& dir) {
        sol::table result = lua_.create_table();
        int index = 1;
        for (const auto& entry : fsops::list_dir(dir)) {
            sol::table item = lua_.create_table();
            item["name"] = entry.name;
            item["path"] = entry.path;
            item["is_dir"] = entry.is_dir;
            result[index++] = item;
        }
        return result;
    });

    // JSON/YAML parsing into Lua values: returns (value, err).
    k.set_function("json_parse",
                   [this](const std::string& text)
                       -> std::tuple<sol::object, sol::optional<std::string>> {
                       std::string error;
                       sol::object value = serialize::json_to_lua(lua_, text, error);
                       if (!error.empty()) {
                           return {sol::make_object(lua_, sol::nil), error};
                       }
                       return {value, sol::nullopt};
                   });

    k.set_function("yaml_parse",
                   [this](const std::string& text)
                       -> std::tuple<sol::object, sol::optional<std::string>> {
                       std::string error;
                       sol::object value = serialize::yaml_to_lua(lua_, text, error);
                       if (!error.empty()) {
                           return {sol::make_object(lua_, sol::nil), error};
                       }
                       return {value, sol::nullopt};
                   });

    // Compile-time platform identification: {os="linux"/"macos", arch=...}.
    k.set_function("platform", [this]() {
        sol::table result = lua_.create_table();
        result["os"] = platform_os();
        result["arch"] = platform_arch();
        return result;
    });

    // Provider registration primitive: validates the scheme and stores the
    // handler in klua.providers so the resolution pipeline can dispatch it.
    k.set_function("register_provider",
                   [this](const std::string& scheme, sol::function handler) {
                       if (scheme.empty() || scheme.find(':') != std::string::npos) {
                           throw sol::error{"register_provider: scheme must be non-empty and contain no ':'"};
                       }
                       if (!handler.valid()) {
                           throw sol::error{"register_provider: handler must be a function"};
                       }
                       sol::table providers = lua_["klua"]["providers"];
                       providers[scheme] = handler;
                   });
}

bool LuaEngine::apply_user_init(std::string& error) {
    const fs::path init_path = paths::user_init();
    std::error_code ec;
    if (!fs::exists(init_path, ec) || ec) {
        return true; // No user customization yet; the baseline is enough.
    }

    auto result = lua_.safe_script_file(init_path.string(), sol::script_pass_on_error);
    if (!result.valid()) {
        sol::error err = result;
        error = err.what();
        return false;
    }
    return true;
}

int LuaEngine::run_command(const std::string& name, const std::vector<std::string>& args) {
    sol::object handler = lua_["klua"]["commands"][name];
    if (!handler.is<sol::function>()) {
        print_error("no Lua handler registered for command '" + name + "'");
        return 1;
    }

    sol::table args_table = lua_.create_table();
    for (std::size_t i = 0; i < args.size(); ++i) {
        args_table[static_cast<int>(i + 1)] = args[i];
    }

    sol::protected_function fn = handler.as<sol::protected_function>();
    auto result = fn(args_table);
    if (!result.valid()) {
        sol::error err = result;
        print_error(std::string{"command '"} + name + "' failed: " + err.what());
        return 1;
    }

    sol::object ret = result;
    if (ret.is<int>()) {
        return ret.as<int>();
    }
    return 0;
}

void LuaEngine::set_cli_flags(bool no_cache, bool skip_checksum) {
    sol::table flags = lua_["klua"]["cli_flags"].get_or_create<sol::table>();
    flags["no_cache"] = no_cache;
    flags["skip_checksum"] = skip_checksum;
}

} // namespace klua
