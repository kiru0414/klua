#include "archive.hpp"

#include "sys.hpp"

#include <algorithm>
#include <cctype>
#include <filesystem>
#include <string>
#include <vector>

namespace klua::archive {

namespace fs = std::filesystem;

namespace {

std::string to_lower(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return value;
}

bool ends_with(const std::string& value, const std::string& suffix) {
    return value.size() >= suffix.size()
        && value.compare(value.size() - suffix.size(), suffix.size(), suffix) == 0;
}

// Move the contents of a single wrapper directory up into dest_dir.
void strip_single_top_level(const fs::path& dest_dir) {
    std::error_code ec;
    std::vector<fs::directory_entry> entries;
    for (const auto& entry : fs::directory_iterator(dest_dir, ec)) {
        entries.push_back(entry);
    }
    if (ec || entries.size() != 1 || !entries.front().is_directory()) {
        return;
    }

    const fs::path wrapper = entries.front().path();
    for (const auto& child : fs::directory_iterator(wrapper, ec)) {
        fs::rename(child.path(), dest_dir / child.path().filename(), ec);
        if (ec) {
            return; // Leave the layout intact if anything cannot be moved.
        }
    }
    fs::remove(wrapper, ec);
}

} // namespace

bool is_archive_name(const std::string& name) {
    const std::string lower = to_lower(name);
    return ends_with(lower, ".tar.gz") || ends_with(lower, ".tgz")
        || ends_with(lower, ".tar.xz") || ends_with(lower, ".txz")
        || ends_with(lower, ".tar.bz2") || ends_with(lower, ".tar")
        || ends_with(lower, ".zip");
}

bool extract(const std::string& archive_path, const std::string& dest_dir, std::string& error) {
    const fs::path archive{archive_path};
    const fs::path dest{dest_dir};

    std::error_code ec;
    if (!fs::exists(archive, ec)) {
        error = "archive not found: " + archive_path;
        return false;
    }
    fs::create_directories(dest, ec);
    if (ec) {
        error = "could not create destination: " + dest_dir;
        return false;
    }

    const std::string lower = to_lower(archive.filename().string());
    const std::string quoted_archive = sys::shell_quote(archive_path);
    const std::string quoted_dest = sys::shell_quote(dest_dir);

    std::string command;
    if (ends_with(lower, ".tar.gz") || ends_with(lower, ".tgz")) {
        command = "tar -xzf " + quoted_archive + " -C " + quoted_dest;
    } else if (ends_with(lower, ".tar.xz") || ends_with(lower, ".txz")) {
        command = "tar -xJf " + quoted_archive + " -C " + quoted_dest;
    } else if (ends_with(lower, ".tar.bz2")) {
        command = "tar -xjf " + quoted_archive + " -C " + quoted_dest;
    } else if (ends_with(lower, ".tar")) {
        command = "tar -xf " + quoted_archive + " -C " + quoted_dest;
    } else if (ends_with(lower, ".zip")) {
        command = "unzip -q -o " + quoted_archive + " -d " + quoted_dest;
    } else {
        error = "unsupported archive format: " + archive.filename().string();
        return false;
    }

    const int code = sys::run_command(command);
    if (code != 0) {
        error = "extraction failed (exit " + std::to_string(code) + "): " + command;
        return false;
    }

    strip_single_top_level(dest);
    return true;
}

} // namespace klua::archive
