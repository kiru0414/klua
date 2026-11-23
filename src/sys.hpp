#pragma once

#include <string>

namespace klua::sys {

// Run a shell command and return a normalized exit code (0 = success).
int run_command(const std::string& command);

// Quote a string for safe use inside a POSIX shell command.
std::string shell_quote(const std::string& value);

} // namespace klua::sys
