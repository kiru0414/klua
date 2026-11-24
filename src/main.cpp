// klua -- a fast, self-healing package manager (C++20 + Lua 5.4).
//
// Milestone 1: CLI skeleton, embedded Lua baseline with self-healing
// fallback, and `klua repair`. Fetching/installing lands in Milestone 2.

#include "lua_engine.hpp"
#include "paths.hpp"

#include "klua/embedded_assets.hpp"

#include <CLI/CLI.hpp>

#include <algorithm>
#include <cstddef>
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

// --- CLI typo suggestions -------------------------------------------------
// CLI11 rejects unknown subcommands/flags with a generic message; add a
// "did you mean" hint based on Levenshtein distance.

std::size_t levenshtein_distance(const std::string& a, const std::string& b) {
    std::vector<std::size_t> prev(b.size() + 1);
    for (std::size_t j = 0; j <= b.size(); ++j) {
        prev[j] = j;
    }
    for (std::size_t i = 1; i <= a.size(); ++i) {
        std::vector<std::size_t> cur(b.size() + 1);
        cur[0] = i;
        for (std::size_t j = 1; j <= b.size(); ++j) {
            const std::size_t cost = a[i - 1] == b[j - 1] ? 0 : 1;
            cur[j] = std::min({prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost});
        }
        prev = std::move(cur);
    }
    return prev[b.size()];
}

std::string closest_word(const std::string& input, const std::vector<std::string>& words) {
    std::string best;
    std::size_t best_distance = std::string::npos;
    for (const auto& word : words) {
        const std::size_t distance = levenshtein_distance(input, word);
        if (distance < best_distance) {
            best = word;
            best_distance = distance;
        }
    }
    const std::size_t threshold = std::max<std::size_t>(1, input.size() / 3);
    return (!best.empty() && best_distance <= threshold) ? best : std::string{};
}

void suggest_cli_typos(int argc, char** argv) {
    const std::vector<std::string> commands = {
        "install", "i", "add", "sync", "upgrade", "repair", "tap", "list",
        "init-manifest", "remove", "rm", "uninstall"};
    const std::vector<std::string> flags = {"--help", "-h", "--version", "--force"};

    for (int index = 1; index < argc; ++index) {
        const std::string token = argv[index];
        if (token.empty()) {
            continue;
        }
        if (token[0] == '-') {
            if (std::find(flags.begin(), flags.end(), token) != flags.end()) {
                continue; // valid flag, nothing to suggest
            }
            const std::string match = closest_word(token, flags);
            if (!match.empty()) {
                std::cerr << "warning: unknown option '" << token
                          << "'; did you mean '" << match << "'?\n";
            }
        } else {
            if (std::find(commands.begin(), commands.end(), token) != commands.end()) {
                continue; // valid subcommand
            }
            const std::string match = closest_word(token, commands);
            if (!match.empty()) {
                std::cerr << "warning: unknown command '" << token
                          << "'; did you mean '" << match << "'?\n";
                break;
            }
        }
    }
}

// Positional arguments collected per subcommand.
struct CommandArgs {
    std::vector<std::string> install_targets;
    std::vector<std::string> add_targets;
    std::vector<std::string> remove_targets;
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

    auto* remove = app.add_subcommand("remove", "Remove installed packages, store dirs and ~/.local/bin symlinks")
                        ->alias("rm")
                        ->alias("uninstall");
    remove->add_option("targets", args.remove_targets, "Packages to remove")->required();

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
        // Add a typo hint for unknown subcommands/flags, but never for the
        // help/version pseudo-errors (which print and exit 0).
        if (dynamic_cast<const CLI::CallForHelp*>(&e) == nullptr
            && dynamic_cast<const CLI::CallForVersion*>(&e) == nullptr) {
            suggest_cli_typos(argc, argv);
        }
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
    if (remove->parsed()) {
        return engine.run_command("remove", args.remove_targets);
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
