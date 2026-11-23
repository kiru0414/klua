#pragma once

#include <string>

namespace klua::http {

struct Response {
    long status = 0;          // HTTP status code (0 on transport failure)
    std::string body;         // response body
    std::string error;        // non-empty on transport failure

    bool ok() const { return error.empty() && status >= 200 && status < 300; }
};

// GET a URL over HTTP(S), following redirects. Sends a klua User-Agent.
Response get(const std::string& url);

// Stream a URL to `dest` (parent directories are created). On failure the
// partial file is removed and `error` describes the problem.
bool download(const std::string& url, const std::string& dest, std::string& error);

} // namespace klua::http
