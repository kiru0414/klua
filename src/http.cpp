#include "http.hpp"

#include <httplib.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <exception>
#include <filesystem>
#include <fstream>
#include <optional>
#include <set>
#include <string>
#include <thread>
#include <vector>

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

// cpp-httplib's built-in redirect follower copies every request header to the
// next host. That leaks API tokens to release CDNs and adds Authorization
// headers to presigned S3 URLs (which answers 403). klua follows redirects
// itself instead, so headers can be rebuilt for every hop.
httplib::Client make_client(const Url& url) {
    std::string base = url.scheme + "://" + url.host;
    if (url.port > 0) {
        base += ":" + std::to_string(url.port);
    }
    httplib::Client client{base};
    client.set_connection_timeout(30, 0);
    client.set_read_timeout(300, 0);
    client.set_write_timeout(120, 0);
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

// ---------------------------------------------------------------------------
// Manual redirect handling.
//
// Each hop is a fresh request built from the new URL. That keeps User-Agent on
// every hop while dropping Authorization / PRIVATE-TOKEN as soon as the host,
// port, or API path changes. Query strings are preserved verbatim so GitHub
// asset redirects and S3 presigned URLs keep working.
// ---------------------------------------------------------------------------

constexpr int kMaxRedirects = 10;

bool is_redirect(long status) {
    return status == 301 || status == 302 || status == 303
        || status == 307 || status == 308;
}

bool is_retryable_status(long status) {
    return status == 403 || status == 429 || status == 500
        || status == 502 || status == 503 || status == 504;
}

std::string url_string(const Url& url) {
    std::string result = url.scheme + "://" + url.host;
    if (url.port > 0) {
        result += ":" + std::to_string(url.port);
    }
    return result + url.path;
}

std::string strip_fragment(const std::string& value) {
    const auto hash = value.find('#');
    return hash == std::string::npos ? value : value.substr(0, hash);
}

// Collapse '.' / '..' segments without touching the raw query string.
std::string normalize_path(std::string path) {
    const auto query_pos = path.find('?');
    const std::string query = query_pos == std::string::npos ? "" : path.substr(query_pos);
    const std::string pure = query_pos == std::string::npos ? path : path.substr(0, query_pos);
    const bool trailing_slash = !pure.empty() && pure.back() == '/';

    std::vector<std::string> parts;
    std::size_t start = 0;
    while (start < pure.size()) {
        const auto end = pure.find('/', start);
        const auto stop = end == std::string::npos ? pure.size() : end;
        const std::string part = pure.substr(start, stop - start);
        if (!part.empty() && part != ".") {
            if (part == "..") {
                if (!parts.empty()) {
                    parts.pop_back();
                }
            } else {
                parts.push_back(part);
            }
        }
        if (end == std::string::npos) {
            break;
        }
        start = end + 1;
    }

    std::string result = "/";
    for (std::size_t index = 0; index < parts.size(); ++index) {
        if (index > 0) {
            result += "/";
        }
        result += parts[index];
    }
    if (trailing_slash && result != "/") {
        result += "/";
    }
    return result + query;
}

std::optional<Url> resolve_location(const Url& base, const std::string& location) {
    const std::string value = strip_fragment(location);
    if (value.empty()) {
        return std::nullopt;
    }

    if (auto direct = parse_url(value)) {
        return direct;
    }
    if (value.rfind("//", 0) == 0) {
        return parse_url(base.scheme + ":" + value);
    }

    Url next = base;
    if (value[0] == '?') {
        const auto query = next.path.find('?');
        const std::string path = query == std::string::npos ? next.path
                                                          : next.path.substr(0, query);
        next.path = path + value;
        return next;
    }
    if (value[0] == '/') {
        next.path = normalize_path(value);
        return next;
    }

    const auto query = next.path.find('?');
    const std::string base_path = query == std::string::npos ? next.path
                                                            : next.path.substr(0, query);
    const auto last_slash = base_path.rfind('/');
    const std::string prefix = last_slash == std::string::npos
        ? "/" : base_path.substr(0, last_slash + 1);
    next.path = normalize_path(prefix + value);
    return next;
}

// Run `fn(index)` for each index in [0, count) using at most eight workers.
// Work is claimed through an atomic cursor, so slow requests do not block the
// other workers even when the input order is uneven.
template <typename Fn>
void parallel_for(std::size_t count, Fn&& fn) {
    if (count == 0) {
        return;
    }
    constexpr std::size_t kMaxWorkers = 8;
    const std::size_t workers = std::min(count, kMaxWorkers);
    std::atomic<std::size_t> next{0};
    std::vector<std::thread> threads;
    threads.reserve(workers);
    for (std::size_t worker = 0; worker < workers; ++worker) {
        threads.emplace_back([&]() {
            for (;;) {
                const std::size_t index = next.fetch_add(1, std::memory_order_relaxed);
                if (index >= count) {
                    return;
                }
                fn(index);
            }
        });
    }
    for (auto& thread : threads) {
        thread.join();
    }
}

} // namespace

Response get(const std::string& url) {
    Response response;
    auto current = parse_url(url);
    if (!current) {
        response.error = "invalid URL: " + url;
        return response;
    }

    std::set<std::string> visited;
    for (int hop = 0; hop <= kMaxRedirects; ++hop) {
        const std::string current_url = url_string(*current);
        if (!visited.insert(current_url).second) {
            response.error = "redirect loop detected at " + current_url;
            return response;
        }

        httplib::Client client = make_client(*current);
        const auto result = client.Get(current->path, default_headers(*current));
        if (!result) {
            response.error = httplib::to_string(result.error());
            return response;
        }

        if (!is_redirect(result->status)) {
            response.status = result->status;
            response.body = std::move(result->body);
            return response;
        }

        if (hop == kMaxRedirects) {
            response.status = result->status;
            response.error = "too many redirects for " + url;
            return response;
        }

        const std::string location = result->get_header_value("Location");
        const auto next = resolve_location(*current, location);
        if (!next) {
            response.status = result->status;
            response.error = "invalid redirect location '" + location
                + "' for " + current_url;
            return response;
        }
        current = *next;
    }

    response.error = "too many redirects for " + url;
    return response;
}

std::vector<Response> get_batch(const std::vector<std::string>& urls) {
    std::vector<Response> responses(urls.size());
    parallel_for(urls.size(), [&](std::size_t index) {
        try {
            responses[index] = get(urls[index]);
        } catch (const std::exception& exception) {
            responses[index].error = exception.what();
        } catch (...) {
            responses[index].error = "unknown error";
        }
    });
    return responses;
}

HeadResponse head_redirect(const std::string& url) {
    HeadResponse result;
    const auto parsed = parse_url(url);
    if (!parsed) {
        result.error = "invalid URL: " + url;
        return result;
    }

    httplib::Client client = make_client(*parsed);
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
    // Redirects are followed manually so each hop gets fresh, host-scoped
    // headers (see get() above).
    constexpr int max_attempts = 4;
    std::string last_error;

    for (int attempt = 1; attempt <= max_attempts; ++attempt) {
        std::ofstream out{target, std::ios::binary | std::ios::trunc};
        if (!out) {
            error = "could not open destination: " + dest;
            return false;
        }

        auto current = parsed;
        std::set<std::string> visited;
        long attempt_status = 0;
        bool transport_failure = false;
        bool fatal_redirect = false;

        for (int hop = 0; hop <= kMaxRedirects; ++hop) {
            const std::string current_url = url_string(*current);
            if (!visited.insert(current_url).second) {
                last_error = "redirect loop detected at " + current_url;
                fatal_redirect = true;
                break;
            }

            bool write_body = false;
            httplib::Client client = make_client(*current);
            const auto result = client.Get(
                current->path, default_headers(*current),
                [&write_body](const httplib::Response& response) {
                    // Never stage redirect/error bodies as package payloads.
                    write_body = response.status == 200;
                    return true;
                },
                [&](const char* data, size_t length) {
                    if (write_body) {
                        out.write(data, static_cast<std::streamsize>(length));
                    }
                    return out.good();
                },
                nullptr);

            if (!result) {
                last_error = httplib::to_string(result.error()) + " for " + current_url;
                transport_failure = true;
                break;
            }
            attempt_status = result->status;

            if (!is_redirect(attempt_status)) {
                if (attempt_status == 200) {
                    out.close();
                    if (!out) {
                        error = "write failed for " + dest; // local write, not retryable
                        return false;
                    }
                    return true;
                }
                last_error = "HTTP " + std::to_string(attempt_status)
                    + " for " + current_url;
                break;
            }

            if (hop == kMaxRedirects) {
                last_error = "too many redirects for " + url;
                fatal_redirect = true;
                break;
            }

            const std::string location = result->get_header_value("Location");
            const auto next = resolve_location(*current, location);
            if (!next) {
                last_error = "invalid redirect location '" + location
                    + "' for " + current_url;
                fatal_redirect = true;
                break;
            }
            current = *next;
        }

        out.close();
        const bool retryable = !fatal_redirect
            && (transport_failure || is_retryable_status(attempt_status));
        if (!retryable || attempt == max_attempts) {
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(500 * (1 << (attempt - 1))));
    }

    fs::remove(target, ec);
    error = last_error;
    return false;
}

std::vector<DownloadResult> download_batch(const std::vector<DownloadItem>& items) {
    std::vector<DownloadResult> results(items.size());
    parallel_for(items.size(), [&](std::size_t index) {
        try {
            std::string error;
            results[index].ok = download(items[index].url, items[index].dest, error);
            results[index].error = std::move(error);
        } catch (const std::exception& exception) {
            results[index].error = exception.what();
        } catch (...) {
            results[index].error = "unknown error";
        }
    });
    return results;
}

} // namespace klua::http
