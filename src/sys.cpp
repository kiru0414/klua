#include "sys.hpp"

#include <cstdlib>

#if defined(__unix__) || defined(__APPLE__)
#include <sys/wait.h>
#endif

namespace klua::sys {

int run_command(const std::string& command) {
    const int raw = std::system(command.c_str());
#if defined(__unix__) || defined(__APPLE__)
    if (WIFEXITED(raw)) {
        return WEXITSTATUS(raw);
    }
    return 1;
#else
    return raw;
#endif
}

std::string shell_quote(const std::string& value) {
    // Wrap in single quotes; embedded single quotes become '\''.
    std::string quoted = "'";
    for (const char c : value) {
        if (c == '\'') {
            quoted += "'\\''";
        } else {
            quoted += c;
        }
    }
    quoted += "'";
    return quoted;
}

} // namespace klua::sys
