#pragma once

#include <string>

namespace klua::crypto {

// Return the lowercase hex SHA-256 digest of a file. On failure the returned
// string is empty and `error` describes the problem.
std::string sha256_file(const std::string& path, std::string& error);

} // namespace klua::crypto
