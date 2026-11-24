#include "crypto.hpp"

#include <openssl/evp.h>

#include <fstream>
#include <iterator>
#include <string>

namespace klua::crypto {

std::string sha256_file(const std::string& path, std::string& error) {
    std::ifstream in{path, std::ios::binary};
    if (!in) {
        error = "could not open file: " + path;
        return {};
    }

    const std::string contents{std::istreambuf_iterator<char>{in},
                               std::istreambuf_iterator<char>{}};
    if (in.bad()) {
        error = "could not read file: " + path;
        return {};
    }

    unsigned char digest[EVP_MAX_MD_SIZE]{};
    unsigned int length = 0;
    if (EVP_Digest(contents.data(), contents.size(), digest, &length,
                   EVP_sha256(), nullptr)
        != 1) {
        error = "OpenSSL SHA-256 digest failed for " + path;
        return {};
    }

    static constexpr char hex[] = "0123456789abcdef";
    std::string result;
    result.reserve(length * 2);
    for (unsigned int i = 0; i < length; ++i) {
        result.push_back(hex[digest[i] >> 4]);
        result.push_back(hex[digest[i] & 0x0f]);
    }
    error.clear();
    return result;
}

} // namespace klua::crypto
