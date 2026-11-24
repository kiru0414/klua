#include "http.hpp"

#include <httplib.h>

#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <optional>
#include <string>
#include <thread>

namespace klua::http {

namespace fs = std::filesystem;

namespace {

struct Url {
    std::string scheme;
    std::string host;
    int port = -1;
    std::string path; // includes the query string
};

// Minimal absolute-URL splitter: scheme://host[:port][/path][?query].
std::optional<Url> parse_url(const std::string& url) {
    const auto scheme_end = url.find("://");
    if (scheme_end == std::string::npos) {
        return std::nullopt;
    }
    Url parsed;
    parsed.scheme = url.substr(0, scheme_end);
    if (parsed.scheme != "http" && parsed.scheme != "https") {
        return std::nullopt;
    }

    const auto authority_start = scheme_end + 3;
    const auto path_start = url.find('/', authority_start);
    const std::string authority = url.substr(
        authority_start,
        path_start == std::string::npos ? std::string::npos : path_start - authority_start);
    parsed.path = path_start == std::string::npos ? "/" : url.substr(path_start);

    const auto colon = authority.rfind(':');
    if (colon != std::string::npos) {
        parsed.host = authority.substr(0, colon);
        try {
            parsed.port = std::stoi(authority.substr(colon + 1));
        } catch (...) {
            return std::nullopt;
        }
    } else {
        parsed.host = authority;
    }
    if (parsed.host.empty()) {
        return std::nullopt;
    }
    return parsed;
}

httplib::Client make_client(const Url& url, bool follow_redirects = true) {
    std::string base = url.scheme + "://" + url.host;
    if (url.port > 0) {
        base += ":" + std::to_string(url.port);
    }
    httplib::Client client{base};
    client.set_connection_timeout(30, 0);
    client.set_read_timeout(300, 0);
    client.set_write_timeout(120, 0);
    client.set_follow_location(follow_redirects);
    return client;
}

std::string env_or_empty(const char* name) {
    const char* value = std::getenv(name);
    return value != nullptr ? std::string{value} : std::string{};
}

std::string github_token() {
    for (const char* name : {"GITHUB_TOKEN", "GH_TOKEN"}) {
        const std::string value = env_or_empty(name);
        if (!value.empty()) {
            return value;
        }
    }
    return {};
}

bool is_api_path(const std::string& path) {
    return path.find("/api/") == 0 || path.find("/repos/") != std::string::npos;
}

// Tokens are sent only to API endpoints by default. A user who points a
// provider at a trusted mirror can opt in with KLUA_GITHUB_API_HOST or
// KLUA_GITLAB_API_HOST (GitHub Enterprise, self-hosted GitLab, test servers).
// The override still limits the token to API-looking paths, never raw files or
// release downloads.
bool github_token_allowed(const Url& url) {
    if (url.host == "api.github.com") {
        return true;
    }
    const std::string override = env_or_empty("KLUA_GITHUB_API_HOST");
    return !override.empty() && url.host == override && is_api_path(url.path);
}

bool gitlab_token_allowed(const Url& url) {
    if (url.host == "gitlab.com") {
        return is_api_path(url.path);
    }
    const std::string override = env_or_empty("KLUA_GITLAB_API_HOST");
    return !override.empty() && url.host == override && is_api_path(url.path);
}

httplib::Headers default_headers(const Url& url) {
    httplib::Headers headers{{"User-Agent", std::string{"klua/"} + KLUA_VERSION}};
    if (github_token_allowed(url)) {
        const std::string token = github_token();
        if (!token.empty()) {
            headers.emplace("Authorization", "Bearer " + token);
        }
    }
    if (gitlab_token_allowed(url)) {
        const std::string token = env_or_empty("GITLAB_TOKEN");
        if (!token.empty()) {
            // PRIVATE-TOKEN is GitLab's canonical PAT header. Bearer is also
            // accepted on modern GitLab and keeps custom mirrors simple.
            headers.emplace("PRIVATE-TOKEN", token);
            headers.emplace("Authorization", "Bearer " + token);
        }
    }
    return headers;
}

} // namespace

Response get(const std::string& url) {
    Response response;
    const auto parsed = parse_url(url);
    if (!parsed) {
        response.error = "invalid URL: " + url;
        return response;
    }

    httplib::Client client = make_client(*parsed);
    const auto result = client.Get(parsed->path, default_headers(*parsed));
    if (!result) {
        response.error = httplib::to_string(result.error());
        return response;
    }
    response.status = result->status;
    response.body = std::move(result->body);
    return response;
}

HeadResponse head_redirect(const std::string& url) {
    HeadResponse result;
    const auto parsed = parse_url(url);
    if (!parsed) {
        result.error = "invalid URL: " + url;
        return result;
    }

    httplib::Client client = make_client(*parsed, /*follow_redirects=*/false);
    const auto response = client.Head(parsed->path, default_headers(*parsed));
    if (!response) {
        result.error = httplib::to_string(response.error());
        return result;
    }

    result.status = response->status;
    result.location = response->get_header_value("Location");
    return result;
}

bool download(const std::string& url, const std::string& dest, std::string& error) {
    const auto parsed = parse_url(url);
    if (!parsed) {
        error = "invalid URL: " + url;
        return false;
    }

    const fs::path target{dest};
    std::error_code ec;
    if (target.has_parent_path()) {
        fs::create_directories(target.parent_path(), ec);
        if (ec) {
            error = "could not create directory: " + target.parent_path().string();
            return false;
        }
    }

    // GitHub's release-asset CDN occasionally answers transient 403/429/5xx
    // or drops the connection; retry with a short backoff before giving up.
    constexpr int max_attempts = 4;
    std::string last_error;

    for (int attempt = 1; attempt <= max_attempts; ++attempt) {
        std::ofstream out{target, std::ios::binary | std::ios::trunc};
        if (!out) {
            error = "could not open destination: " + dest;
            return false;
        }

        httplib::Client client = make_client(*parsed);
        const auto result = client.Get(
            parsed->path, default_headers(*parsed),
            [&](const char* data, size_t length) {
                out.write(data, static_cast<std::streamsize>(length));
                return out.good();
            },
            nullptr);
        out.close();

        if (result && result->status == 200) {
            if (!out) {
                error = "write failed for " + dest; // local write, not retryable
                return false;
            }
            return true;
        }

        if (!result) {
            last_error = httplib::to_string(result.error());
        } else {
            last_error = "HTTP " + std::to_string(result->status) + " for " + url;
        }

        const bool retryable = !result
            || result->status == 403 || result->status == 429
            || result->status == 500 || result->status == 502
            || result->status == 503 || result->status == 504;
        if (!retryable || attempt == max_attempts) {
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(500 * (1 << (attempt - 1))));
    }

    fs::remove(target, ec);
    error = last_error;
    return false;
}

} // namespace klua::http
