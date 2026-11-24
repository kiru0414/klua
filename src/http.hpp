#pragma once

#include <string>
#include <vector>

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

struct DownloadItem {
    std::string url;
    std::string dest;
};

struct DownloadResult {
    bool ok = false;
    std::string error;
};

// GET a URL over HTTP(S). 301/302/303/307/308 redirects are followed manually:
// each hop gets a fresh User-Agent and only the host-appropriate auth headers,
// so tokens never leak to release CDNs or presigned S3 URLs.
Response get(const std::string& url);

// Bounded parallel GET (at most 8 workers). Results are returned in input
// order; each request creates its own httplib::Client for thread safety.
std::vector<Response> get_batch(const std::vector<std::string>& urls);

// HEAD a URL without following redirects. Used to discover the final tag URL
// of https://github.com/<user>/<repo>/releases/latest without the REST API.
HeadResponse head_redirect(const std::string& url);

// Stream a URL to `dest` (parent directories are created). On failure the
// partial file is removed and `error` describes the problem.
bool download(const std::string& url, const std::string& dest, std::string& error);

// Bounded parallel download (at most 8 workers). Results are returned in input
// order; callers must not provide two items with the same destination.
std::vector<DownloadResult> download_batch(const std::vector<DownloadItem>& items);

} // namespace klua::http
