// klua -- a fast, self-healing package manager (C++20 + Lua 5.4).
//
// Milestone 1: CLI skeleton, embedded Lua baseline with self-healing
// fallback, and `klua repair`. Fetching/installing lands in Milestone 2.

#include "lua_engine.hpp"
#include "paths.hpp"

#include "klua/embedded_assets.hpp"

#include <CLI/CLI.hpp>

#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace {

// `klua repair` is implemented natively so it works even when the Lua layer
// is completely broken: it forcefully overwrites the user's init.lua with
// the clean embedded baseline.
int run_repair() {
    const fs::path target = klua::paths::user_init();

    if (!klua::paths::ensure_dir(target.parent_path())) {
        std::cerr << "error: could not create config directory '"
                  << target.parent_path().string() << "'\n";
        return 1;
    }

    std::ofstream out{target, std::ios::binary | std::ios::trunc};
    if (!out) {
        std::cerr << "error: could not open '" << target.string() << "' for writing\n";
        return 1;
    }
    out << klua::assets::default_init_lua;
    out.close();
    if (!out) {
        std::cerr << "error: failed to write '" << target.string() << "'\n";
        return 1;
    }

    std::cout << "Restored " << target.string() << " from the built-in defaults.\n";
    return 0;
}

// Positional arguments collected per subcommand.
struct CommandArgs {
    std::vector<std::string> install_targets;
    std::vector<std::string> add_targets;
    std::string sync_source;
    std::vector<std::string> upgrade_targets;
    std::string tap_action;
    std::string tap_url;
};

} // namespace

int main(int argc, char** argv) {
    CLI::App app{"klua -- a fast, self-healing package manager (C++20 + Lua 5.4)"};
    app.set_version_flag("--version", std::string{"klua "} + KLUA_VERSION);
    app.require_subcommand(1);

    CommandArgs args;

    auto* install = app.add_subcommand("install", "Install packages (scheme targets such as gh:user/repo)")
                          ->alias("i");
    install->add_option("targets", args.install_targets, "Targets to install")->required();

    auto* add = app.add_subcommand("add", "Record targets in packages.yaml without installing");
    add->add_option("targets", args.add_targets, "Targets to record")->required();

    auto* sync = app.add_subcommand("sync", "Install everything declared in a local or remote YAML source");
    sync->add_option("source", args.sync_source, "Local path or URL of the YAML source");

    auto* upgrade = app.add_subcommand("upgrade", "Upgrade installed packages");
    upgrade->add_option("targets", args.upgrade_targets, "Packages to upgrade (default: all)");

    auto* repair = app.add_subcommand("repair", "Restore ~/.config/klua/init.lua from the built-in defaults");

    auto* tap = app.add_subcommand("tap", "Manage package registries (taps.yaml)");
    tap->add_option("action", args.tap_action, "add, remove or list")->required();
    tap->add_option("url", args.tap_url, "Registry URL (for add/remove)");

    auto* list = app.add_subcommand("list", "List installed packages");

    bool init_manifest_force = false;
    auto* init_manifest = app.add_subcommand("init-manifest", "Generate a starter klua.yaml in the current directory");
    init_manifest->add_flag("--force", init_manifest_force, "Overwrite an existing klua.yaml");

    try {
        app.parse(argc, argv);
    } catch (const CLI::ParseError& e) {
        // app.exit() prints the diagnostic (or help/version text) and returns
        // CLI11's own exit code; normalize usage errors to a plain 1.
        const int code = app.exit(e);
        return code == 0 ? 0 : 1;
    }

    // Repair never touches Lua: it must succeed even with a broken engine.
    if (repair->parsed()) {
        return run_repair();
    }

    // Self-healing startup: embedded baseline first, user init.lua second.
    klua::LuaEngine engine;
    try {
        engine.bootstrap();
    } catch (const std::exception& ex) {
        std::cerr << "error: " << ex.what() << '\n';
        return 1;
    }

    std::string init_error;
    if (!engine.apply_user_init(init_error)) {
        std::cerr << "error: failed to load " << klua::paths::user_init().string()
                  << ": " << init_error << '\n';
        std::cerr << "warning: falling back to the built-in default logic. "
                  << "Run 'klua repair' to restore a clean init.lua.\n";
        engine.reset();
        try {
            engine.bootstrap();
        } catch (const std::exception& ex) {
            std::cerr << "error: " << ex.what() << '\n';
            return 1;
        }
    }

    // Dispatch the parsed subcommand into the Lua layer.
    if (install->parsed()) {
        return engine.run_command("install", args.install_targets);
    }
    if (add->parsed()) {
        return engine.run_command("add", args.add_targets);
    }
    if (sync->parsed()) {
        std::vector<std::string> sync_args;
        if (!args.sync_source.empty()) {
            sync_args.push_back(args.sync_source);
        }
        return engine.run_command("sync", sync_args);
    }
    if (upgrade->parsed()) {
        return engine.run_command("upgrade", args.upgrade_targets);
    }
    if (tap->parsed()) {
        std::vector<std::string> tap_args{args.tap_action};
        if (!args.tap_url.empty()) {
            tap_args.push_back(args.tap_url);
        }
        return engine.run_command("tap", tap_args);
    }
    if (list->parsed()) {
        return engine.run_command("list", {});
    }
    if (init_manifest->parsed()) {
        std::vector<std::string> manifest_args;
        if (init_manifest_force) {
            manifest_args.push_back("--force");
        }
        return engine.run_command("init-manifest", manifest_args);
    }

    std::cerr << "error: no subcommand selected\n";
    return 1;
}
