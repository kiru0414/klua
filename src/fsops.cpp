#include "fsops.hpp"

#include <algorithm>
#include <array>
#include <cstdint>
#include <filesystem>
#include <fstream>

namespace klua::fsops {

namespace fs = std::filesystem;

namespace {

bool has_exec_bit(fs::perms permissions) {
    return (permissions & (fs::perms::owner_exec | fs::perms::group_exec | fs::perms::others_exec))
        != fs::perms::none;
}

// Detect ELF and Mach-O (thin + fat, both endiannesses) magic bytes.
bool has_binary_magic(const fs::path& file) {
    std::ifstream in{file, std::ios::binary};
    if (!in) {
        return false;
    }
    std::array<unsigned char, 4> magic{};
    in.read(reinterpret_cast<char*>(magic.data()), static_cast<std::streamsize>(magic.size()));
    if (in.gcount() < 4) {
        return false;
    }
    const std::uint32_t word = (static_cast<std::uint32_t>(magic[0]) << 24)
        | (static_cast<std::uint32_t>(magic[1]) << 16)
        | (static_cast<std::uint32_t>(magic[2]) << 8)
        | static_cast<std::uint32_t>(magic[3]);

    if (magic[0] == 0x7F && magic[1] == 'E' && magic[2] == 'L' && magic[3] == 'F') {
        return true; // ELF
    }
    switch (word) {
        case 0xFEEDFACE: // Mach-O 32-bit
        case 0xFEEDFACF: // Mach-O 64-bit
        case 0xCEFAEDFE: // Mach-O 32-bit, reversed endian
        case 0xCFFAEDFE: // Mach-O 64-bit, reversed endian
        case 0xCAFEBABE: // Mach-O universal (fat)
        case 0xBEBAFECA: // Mach-O universal, reversed endian
            return true;
        default:
            return false;
    }
}

bool has_ignored_extension(const fs::path& file) {
    std::string ext = file.extension().string();
    std::transform(ext.begin(), ext.end(), ext.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    static const std::array<const char*, 12> ignored{
        ".sha256", ".sha256sum", ".sig", ".asc", ".md", ".txt",
        ".json", ".yaml", ".yml", ".pem", ".pub", ".html"};
    for (const char* candidate : ignored) {
        if (ext == candidate) {
            return true;
        }
    }
    return false;
}

} // namespace

bool symlink(const std::string& target_path, const std::string& link_path, std::string& error) {
    const fs::path link{link_path};
    std::error_code ec;

    if (link.has_parent_path()) {
        fs::create_directories(link.parent_path(), ec);
        if (ec) {
            error = "could not create directory: " + link.parent_path().string();
            return false;
        }
    }

    // Replace any existing entry, including dangling symlinks (fs::exists
    // follows links, so probe the symlink status as well).
    const auto status = fs::symlink_status(link, ec);
    if (status.type() != fs::file_type::not_found) {
        fs::remove(link, ec);
        if (ec) {
            error = "could not replace existing entry: " + link_path;
            return false;
        }
    }

    fs::create_symlink(target_path, link, ec);
    if (ec) {
        error = "could not create symlink " + link_path + " -> " + target_path + ": " + ec.message();
        return false;
    }
    return true;
}

bool chmod_exec(const std::string& path, std::string& error) {
    std::error_code ec;
    fs::permissions(fs::path{path},
                    fs::perms::owner_exec | fs::perms::group_exec | fs::perms::others_exec,
                    fs::perm_options::add, ec);
    if (ec) {
        error = "chmod failed for " + path + ": " + ec.message();
        return false;
    }
    return true;
}

bool copy(const std::string& src, const std::string& dest, std::string& error) {
    const fs::path target{dest};
    std::error_code ec;
    if (target.has_parent_path()) {
        fs::create_directories(target.parent_path(), ec);
        if (ec) {
            error = "could not create directory: " + target.parent_path().string();
            return false;
        }
    }
    fs::copy_file(fs::path{src}, target, fs::copy_options::overwrite_existing, ec);
    if (ec) {
        error = "copy failed " + src + " -> " + dest + ": " + ec.message();
        return false;
    }
    return true;
}

bool remove(const std::string& path, std::string& error) {
    std::error_code ec;
    fs::remove_all(fs::path{path}, ec);
    if (ec) {
        error = "remove failed for " + path + ": " + ec.message();
        return false;
    }
    return true;
}

std::vector<std::string> find_executables(const std::string& dir) {
    std::vector<std::string> found;
    std::error_code ec;
    fs::recursive_directory_iterator it{fs::path{dir}, fs::directory_options::skip_permission_denied, ec};
    if (ec) {
        return found;
    }
    for (const auto& entry : it) {
        if (!entry.is_regular_file(ec) || ec) {
            continue;
        }
        const fs::path file = entry.path();
        if (has_ignored_extension(file)) {
            continue;
        }
        if (has_binary_magic(file) || has_exec_bit(entry.status().permissions())) {
            found.push_back(file.string());
        }
    }
    std::sort(found.begin(), found.end());
    return found;
}

std::vector<DirEntry> list_dir(const std::string& dir) {
    std::vector<DirEntry> entries;
    std::error_code ec;
    for (const auto& entry : fs::directory_iterator(fs::path{dir}, ec)) {
        DirEntry item;
        item.name = entry.path().filename().string();
        item.path = entry.path().string();
        item.is_dir = entry.is_directory(ec);
        entries.push_back(std::move(item));
    }
    std::sort(entries.begin(), entries.end(),
              [](const DirEntry& a, const DirEntry& b) { return a.name < b.name; });
    return entries;
}

} // namespace klua::fsops
