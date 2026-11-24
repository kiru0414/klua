#pragma once

#include <sol/sol.hpp>

#include <string>
#include <vector>

namespace klua {

// Owns the Lua 5.4 state and implements the self-healing startup sequence:
//
//   1. bootstrap()       -- bind native primitives, run the embedded baseline.
//   2. apply_user_init() -- safely run ~/.config/klua/init.lua on top.
//   3. on failure the caller resets the engine and bootstraps again, which
//      guarantees a clean fallback to the embedded default logic.
class LuaEngine {
public:
    LuaEngine() = default;

    // Bind native primitives and execute the embedded Lua baseline.
    // Throws std::runtime_error if the embedded baseline itself fails
    // (that would be a build-time bug, not user error).
    void bootstrap();

    // Discard all Lua state so bootstrap() can start from scratch.
    void reset();

    // Execute the user's init.lua if it exists. Returns true when the file
    // is absent or loaded cleanly; on failure returns false and fills
    // `error` with the Lua diagnostic.
    bool apply_user_init(std::string& error);

    // Invoke klua.commands.<name>(args) inside Lua. Returns the handler's
    // exit code (0 on success, 1 on Lua errors or missing handlers).
    int run_command(const std::string& name, const std::vector<std::string>& args);

    // Publish CLI-wide switches to the Lua layer after bootstrap, so command
    // handlers can honour --no-cache and --skip-checksum.
    void set_cli_flags(bool no_cache, bool skip_checksum);

private:
    void bind_natives();

    sol::state lua_;
};

} // namespace klua
