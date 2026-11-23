#pragma once

#include <string>

namespace klua::archive {

// Extract an archive intact into dest_dir using system tar/unzip.
// Supported: .tar.gz/.tgz, .tar.xz/.txz, .tar.bz2, .tar, .zip.
// If the extraction produces a single top-level directory, its contents
// are moved up one level (the wrapper directory is stripped).
bool extract(const std::string& archive_path, const std::string& dest_dir, std::string& error);

// True when the file name looks like a supported archive.
bool is_archive_name(const std::string& name);

} // namespace klua::archive
