#pragma once

#include <string>
#include <vector>

namespace klua::fsops {

struct DirEntry {
    std::string name;
    std::string path;
    bool is_dir = false;
};

// Create (or replace) a POSIX symlink: link_path -> target_path.
bool symlink(const std::string& target_path, const std::string& link_path, std::string& error);

// Add executable permission bits for owner/group/other.
bool chmod_exec(const std::string& path, std::string& error);

// Copy a file byte-for-byte (parent directories are created).
bool copy(const std::string& src, const std::string& dest, std::string& error);

// Remove a file or directory tree. Missing paths are a no-op.
bool remove(const std::string& path, std::string& error);

// Recursively find executable candidates: ELF/Mach-O magic bytes or any
// executable permission bit. Checksums, signatures and docs are skipped.
// Results are sorted for deterministic ordering.
std::vector<std::string> find_executables(const std::string& dir);

// Non-recursive directory listing, sorted by name. Empty when missing.
std::vector<DirEntry> list_dir(const std::string& dir);

} // namespace klua::fsops
