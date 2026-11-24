// klua -- a fast, self-healing package manager (C++20 + Lua 5.4).
//
// CLI11 front end: subcommand parsing, Levenshtein typo hints, native
// `repair` (with backup and --dry-run diff), and dispatch into the Lua
// command handlers that implement install, run, search, info, cleanup, etc.

#include "lua_engine.hpp"
#include "paths.hpp"

#include "klua/embedded_assets.hpp"

#include <CLI/CLI.hpp>

#include <algorithm>
#include <chrono>
#include <cstddef>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace {

// --- `klua repair` helpers ------------------------------------------------
// Repair is implemented natively so it works even when the Lua layer is
// completely broken. Before overwriting init.lua it always backs up the
// user's file, and --dry-run previews the change without touching anything.

bool read_text_file(const fs::path& path, std::string& content) {
    std::ifstream in{path, std::ios::binary};
    if (!in) {
        return false;
    }
    std::ostringstream buffer;
    buffer << in.rdbuf();
    if (in.bad()) {
        return false;
    }
    content = buffer.str();
    return true;
}

std::string timestamp_suffix() {
    const auto now = std::chrono::system_clock::now();
    const std::time_t raw = std::chrono::system_clock::to_time_t(now);
    std::tm local{};
#if defined(_WIN32)
    localtime_s(&local, &raw);
#else
    localtime_r(&raw, &local);
#endif
    char buffer[32]{};
    std::strftime(buffer, sizeof(buffer), "%Y%m%d-%H%M%S", &local);
    return buffer;
}

fs::path backup_path_for(const fs::path& target) {
    const std::string base = target.string() + ".bak." + timestamp_suffix();
    fs::path candidate{base};
    for (int index = 2; fs::exists(candidate); ++index) {
        candidate = base + "-" + std::to_string(index);
    }
    return candidate;
}

std::vector<std::string> split_lines(const std::string& text) {
    std::vector<std::string> lines;
    std::istringstream in{text};
    std::string line;
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }
        lines.push_back(line);
    }
    return lines;
}

struct DiffLine {
    char kind; // ' ', '-' or '+'
    std::string text;
};

// Small unified-style diff (LCS based) used for the --dry-run preview. For
// pathologically large files we show a short notice instead of spending
// quadratic time/memory.
std::vector<DiffLine> make_diff(const std::vector<std::string>& before,
                                const std::vector<std::string>& after) {
    std::vector<DiffLine> result;
    const std::size_t n = before.size();
    const std::size_t m = after.size();
    if (n > 4000 || m > 4000 || n * m > 4'000'000) {
        return {};
    }

    std::vector<std::vector<std::size_t>> lcs(n + 1, std::vector<std::size_t>(m + 1, 0));
    for (std::size_t i = n; i-- > 0;) {
        for (std::size_t j = m; j-- > 0;) {
            lcs[i][j] = before[i] == after[j]
                            ? lcs[i + 1][j + 1] + 1
                            : std::max(lcs[i + 1][j], lcs[i][j + 1]);
        }
    }

    std::size_t i = 0;
    std::size_t j = 0;
    while (i < n && j < m) {
        if (before[i] == after[j]) {
            result.push_back({' ', before[i]});
            ++i;
            ++j;
        } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
            result.push_back({'-', before[i++]});
        } else {
            result.push_back({'+', after[j++]});
        }
    }
    while (i < n) {
        result.push_back({'-', before[i++]});
    }
    while (j < m) {
        result.push_back({'+', after[j++]});
    }
    return result;
}

void print_diff(const fs::path& target,
                const std::vector<std::string>& before,
                const std::vector<std::string>& after) {
    const auto diff = make_diff(before, after);
    std::cout << "--- " << target.string() << " (current)\n"
              << "+++ " << target.string() << " (built-in defaults)\n";
    if (diff.empty()) {
        std::cout << "[diff omitted: file is too large for an in-memory preview]\n";
        return;
    }

    constexpr std::size_t context = 3;
    std::vector<bool> changed(diff.size(), false);
    for (std::size_t k = 0; k < diff.size(); ++k) {
        changed[k] = diff[k].kind != ' ';
    }

    std::size_t k = 0;
    while (k < diff.size()) {
        if (!changed[k]) {
            ++k;
            continue;
        }
        std::size_t start = k > context ? k - context : 0;
        std::size_t end = k;
        while (end + 1 < diff.size()
               && (changed[end + 1] || end + 1 - k <= 2 * context)) {
            ++end;
        }
        end = std::min(diff.size() - 1, end + context);

        std::size_t old_line = 1;
        std::size_t new_line = 1;
        for (std::size_t p = 0; p < start; ++p) {
            if (diff[p].kind != '+') {
                ++old_line;
            }
            if (diff[p].kind != '-') {
                ++new_line;
            }
        }
        std::size_t old_count = 0;
        std::size_t new_count = 0;
        for (std::size_t p = start; p <= end; ++p) {
            if (diff[p].kind != '+') {
                ++old_count;
            }
            if (diff[p].kind != '-') {
                ++new_count;
            }
        }
        std::cout << "@@ -" << old_line << ',' << old_count << " +"
                  << new_line << ',' << new_count << " @@\n";
        for (std::size_t p = start; p <= end; ++p) {
            std::cout << diff[p].kind << diff[p].text << '\n';
        }
        k = end + 1;
    }
}

int run_repair(bool dry_run) {
    const fs::path target = klua::paths::user_init();
    const std::string baseline = klua::assets::default_init_lua;

    std::string current;
    const bool exists = fs::exists(target);
    if (exists && !read_text_file(target, current)) {
        std::cerr << "error: could not read '" << target.string() << "'\n";
        return 1;
    }
    if (exists && current == baseline) {
        std::cout << target.string() << " already matches the built-in defaults.\n";
        return 0;
    }

    const fs::path backup = backup_path_for(target);
    if (dry_run) {
        if (exists) {
            std::cout << "Would back up existing " << target.string()
                      << " to " << backup.string() << ".\n";
            print_diff(target, split_lines(current), split_lines(baseline));
        } else {
            std::cout << "Would create " << target.string()
                      << " from the built-in defaults.\n";
        }
        std::cout << "Would restore " << target.string()
                  << " from the built-in defaults. No files were changed.\n";
        return 0;
    }

    if (!klua::paths::ensure_dir(target.parent_path())) {
        std::cerr << "error: could not create config directory '"
                  << target.parent_path().string() << "'\n";
        return 1;
    }
    if (exists) {
        std::error_code ec;
        fs::copy_file(target, backup, fs::copy_options::overwrite_existing, ec);
        if (ec) {
            std::cerr << "error: could not back up '" << target.string()
                      << "' to '" << backup.string() << "': " << ec.message() << '\n';
            return 1;
        }
        std::cout << "Backed up existing " << target.string()
                  << " to " << backup.string() << ".\n";
    }

    std::ofstream out{target, std::ios::binary | std::ios::trunc};
    if (!out) {
        std::cerr << "error: could not open '" << target.string() << "' for writing\n";
        return 1;
    }
    out << baseline;
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
        "init-manifest", "remove", "rm", "uninstall", "run", "search", "info",
        "cleanup", "doctor"};
    const std::vector<std::string> flags = {"--help", "-h", "--version", "--force",
                                            "--as", "--no-cache", "--skip-checksum",
                                            "--locked", "--lock", "--dry-run", "--diff"};

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
    std::string search_query;
    std::string info_target;
};

} // namespace

int main(int argc, char** argv) {
    CLI::App app{"klua -- a fast, self-healing package manager (C++20 + Lua 5.4)"};
    app.set_version_flag("--version", std::string{"klua "} + KLUA_VERSION);
    app.require_subcommand(1);

    CommandArgs args;

    bool no_cache = false;
    bool skip_checksum = false;
    bool locked = false;
    bool lock = false;
    auto add_fetch_flags = [&](CLI::App* command) {
        command->add_flag("--no-cache", no_cache,
                          "Bypass registry shard cache and refetch");
        command->add_flag("--skip-checksum", skip_checksum,
                          "Install even when SHA-256 verification fails");
    };
    auto add_lock_flags = [&](CLI::App* command) {
        command->add_flag("--locked", locked,
                          "Require and reproduce packages.lock.yaml exactly");
        command->add_flag("--lock", lock,
                          "Write resolved versions, URLs and SHA-256 hashes to the lockfile");
    };

    bool install_force = false;
    std::string install_as;
    auto* install = app.add_subcommand("install", "Install packages (scheme targets such as gh:user/repo)")
                          ->alias("i");
    install->add_option("targets", args.install_targets, "Targets to install")->required();
    install->add_flag("--force", install_force,
                      "Link even when a command would shadow a system/protected binary");
    install->add_option("--as", install_as,
                        "Link the primary binary under this name instead of its own");
    add_fetch_flags(install);
    add_lock_flags(install);

    auto* add = app.add_subcommand("add", "Record targets in packages.yaml without installing");
    add->add_option("targets", args.add_targets, "Targets to record")->required();

    auto* remove = app.add_subcommand("remove", "Remove installed packages, store dirs and ~/.local/bin symlinks")
                        ->alias("rm")
                        ->alias("uninstall");
    remove->add_option("targets", args.remove_targets, "Packages to remove")->required();
    add_fetch_flags(remove);

    // `run` is a prefix command: everything after the package target is passed
    // through unchanged to the executed binary (flags included).
    auto* run = app.add_subcommand("run", "Run a package binary from the store without linking it");
    run->prefix_command();
    add_fetch_flags(run);

    auto* search = app.add_subcommand("search", "Search aliases across configured registries");
    search->add_option("query", args.search_query, "Substring to match in aliases or targets")->required();
    add_fetch_flags(search);

    auto* info = app.add_subcommand("info", "Show package details (installed state, store path, release)");
    info->add_option("target", args.info_target, "Alias or scheme target")->required();
    add_fetch_flags(info);

    auto* cleanup = app.add_subcommand("cleanup", "Remove old store versions, broken links and caches");

    auto* doctor = app.add_subcommand("doctor", "Diagnose the klua installation and PATH setup");
    add_fetch_flags(doctor);

    auto* sync = app.add_subcommand("sync", "Install everything declared in a local or remote YAML source");
    sync->add_option("source", args.sync_source, "Local path or URL of the YAML source");
    add_fetch_flags(sync);
    add_lock_flags(sync);

    auto* upgrade = app.add_subcommand("upgrade", "Upgrade installed packages");
    upgrade->add_option("targets", args.upgrade_targets, "Packages to upgrade (default: all)");
    add_fetch_flags(upgrade);
    add_lock_flags(upgrade);

    bool repair_dry_run = false;
    auto* repair = app.add_subcommand("repair", "Restore ~/.config/klua/init.lua from the built-in defaults (backs up the old file)");
    repair->add_flag("--dry-run", repair_dry_run, "Preview the change and a diff without writing or backing up anything");
    repair->add_flag("--diff", repair_dry_run, "Alias for --dry-run");

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

    if (locked && lock) {
        std::cerr << "error: --locked and --lock are mutually exclusive\n";
        return 1;
    }
    if (locked && skip_checksum) {
        std::cerr << "error: --skip-checksum cannot be combined with --locked\n";
        return 1;
    }

    // Repair never touches Lua: it must succeed even with a broken engine.
    if (repair->parsed()) {
        return run_repair(repair_dry_run);
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

    // Publish CLI-wide switches after the self-healing startup sequence so a
    // reset engine still sees them.
    engine.set_cli_flags(no_cache, skip_checksum, locked, lock);

    // Dispatch the parsed subcommand into the Lua layer.
    if (run->parsed()) {
        return engine.run_command("run", run->remaining());
    }
    if (install->parsed()) {
        std::vector<std::string> install_args;
        if (install_force) {
            install_args.push_back("--force");
        }
        if (!install_as.empty()) {
            install_args.push_back("--as");
            install_args.push_back(install_as);
        }
        install_args.insert(install_args.end(), args.install_targets.begin(),
                            args.install_targets.end());
        return engine.run_command("install", install_args);
    }
    if (add->parsed()) {
        return engine.run_command("add", args.add_targets);
    }
    if (remove->parsed()) {
        return engine.run_command("remove", args.remove_targets);
    }
    if (search->parsed()) {
        return engine.run_command("search", {args.search_query});
    }
    if (info->parsed()) {
        return engine.run_command("info", {args.info_target});
    }
    if (cleanup->parsed()) {
        return engine.run_command("cleanup", {});
    }
    if (doctor->parsed()) {
        return engine.run_command("doctor", {});
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
