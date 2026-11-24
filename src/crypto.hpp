#pragma once

#include <string>

namespace klua::crypto {

// Return the lowercase hex SHA-256 digest of a file. On failure the returned
// string is empty and `error` describes the problem.
std::string sha256_file(const std::string& path, std::string& error);

// Return the lowercase hex SHA-256 digest of an in-memory string. Used for
// stable, collision-free store paths derived from a full download URL.
std::string sha256_text(const std::string& text);

} // namespace klua::crypto
