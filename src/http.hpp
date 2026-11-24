#pragma once

#include <string>

namespace klua::http {

struct Response {
    long status = 0;          // HTTP status code (0 on transport failure)
    std::string body;         // response body
    std::string error;        // non-empty on transport failure

    bool ok() const { return error.empty() && status >= 200 && status < 300; }
};

struct HeadResponse {
    long status = 0;          // HTTP status code (0 on transport failure)
    std::string location;     // raw Location header (may be empty)
    std::string error;        // non-empty on transport failure
};

// GET a URL over HTTP(S), following redirects. Sends a klua User-Agent and,
// for api.github.com, an Authorization: Bearer header when GITHUB_TOKEN or
// GH_TOKEN is set.
Response get(const std::string& url);

// HEAD a URL without following redirects. Used to discover the final tag URL
// of https://github.com/<user>/<repo>/releases/latest without the REST API.
HeadResponse head_redirect(const std::string& url);

// Stream a URL to `dest` (parent directories are created). On failure the
// partial file is removed and `error` describes the problem.
bool download(const std::string& url, const std::string& dest, std::string& error);

} // namespace klua::http
