cmake_minimum_required(VERSION 3.24)

# FetchContent dependencies still declare legacy minimum CMake versions.
# Their deprecation notices are not actionable by klua and would otherwise
# make a clean configure noisy. klua's own CMake uses current APIs.
set(CMAKE_WARN_DEPRECATED OFF CACHE BOOL "" FORCE)

project(klua
    VERSION 0.8.0
    DESCRIPTION "A fast, self-healing package manager powered by C++20 and Lua 5.4"
    LANGUAGES C CXX)

# ---------------------------------------------------------------------------
# Global settings
# ---------------------------------------------------------------------------
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

# klua targets POSIX platforms first (Linux & macOS).
if(NOT UNIX)
    message(WARNING "klua targets Linux and macOS; this platform is out of scope for the MVP.")
endif()

# FetchContent_Populate is used for header-only / CMake-less dependencies.
if(POLICY CMP0169)
    cmake_policy(SET CMP0169 OLD)
endif()

include(FetchContent)

# OpenSSL supplies both HTTPS (cpp-httplib) and the EVP SHA-256 primitive.
# Threads backs the bounded HTTP/download worker pool.
find_package(OpenSSL REQUIRED)
find_package(Threads REQUIRED)

# ---------------------------------------------------------------------------
# Dependencies (fetched at configure time, no system packages required)
# ---------------------------------------------------------------------------

# CLI11: subcommand parsing (well-behaved CMake package).
FetchContent_Declare(cli11
    GIT_REPOSITORY https://github.com/CLIUtils/CLI11.git
    GIT_TAG        v2.4.2
    GIT_SHALLOW    TRUE)
FetchContent_MakeAvailable(cli11)

# sol2: use the header tree directly so its own CMake logic
# (which probes for a system Lua) never runs.
FetchContent_Declare(sol2
    GIT_REPOSITORY https://github.com/ThePhD/sol2.git
    GIT_TAG        v3.3.0
    GIT_SHALLOW    TRUE)
FetchContent_GetProperties(sol2)
if(NOT sol2_POPULATED)
    FetchContent_Populate(sol2)
endif()
add_library(klua_sol2 INTERFACE)
target_include_directories(klua_sol2 INTERFACE "${sol2_SOURCE_DIR}/include")

# Lua 5.4: the upstream repository ships no CMakeLists.txt, so build the
# interpreter core as a static library ourselves (no lua.c / luac.c).
FetchContent_Declare(lua
    GIT_REPOSITORY https://github.com/lua/lua.git
    GIT_TAG        v5.4.7
    GIT_SHALLOW    TRUE)
FetchContent_GetProperties(lua)
if(NOT lua_POPULATED)
    FetchContent_Populate(lua)
endif()

set(KLUA_LUA_CORE_SOURCES
    lapi.c lauxlib.c lbaselib.c lcode.c lcorolib.c lctype.c ldblib.c
    ldebug.c ldo.c ldump.c lfunc.c lgc.c linit.c liolib.c llex.c
    lmathlib.c lmem.c loadlib.c lobject.c lopcodes.c loslib.c lparser.c
    lstate.c lstring.c lstrlib.c ltable.c ltablib.c ltm.c lundump.c
    lutf8lib.c lvm.c lzio.c)
list(TRANSFORM KLUA_LUA_CORE_SOURCES PREPEND "${lua_SOURCE_DIR}/")

add_library(klua_lua54 STATIC ${KLUA_LUA_CORE_SOURCES})
target_include_directories(klua_lua54 PUBLIC "${lua_SOURCE_DIR}")
if(APPLE)
    target_compile_definitions(klua_lua54 PRIVATE LUA_USE_MACOSX)
elseif(UNIX)
    target_compile_definitions(klua_lua54 PRIVATE LUA_USE_LINUX)
endif()
target_link_libraries(klua_lua54 PUBLIC ${CMAKE_DL_LIBS})
if(UNIX AND NOT APPLE)
    target_link_libraries(klua_lua54 PUBLIC m)
endif()

# yaml-cpp: in-memory YAML parsing (alias shards, taps, manifests).
set(YAML_CPP_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(YAML_CPP_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(YAML_CPP_BUILD_CONTRIB OFF CACHE BOOL "" FORCE)
set(YAML_CPP_INSTALL OFF CACHE BOOL "" FORCE)
FetchContent_Declare(yaml-cpp
    GIT_REPOSITORY https://github.com/jbeder/yaml-cpp.git
    GIT_TAG        0.8.0
    GIT_SHALLOW    TRUE)
FetchContent_MakeAvailable(yaml-cpp)

# nlohmann/json: GitHub/GitLab Releases API parsing.
set(JSON_BuildTests OFF CACHE INTERNAL "")
FetchContent_Declare(nlohmann_json
    GIT_REPOSITORY https://github.com/nlohmann/json.git
    GIT_TAG        v3.11.3
    GIT_SHALLOW    TRUE)
FetchContent_MakeAvailable(nlohmann_json)

# cpp-httplib: HTTPS requests and downloads (OpenSSL required).
# zlib/brotli/zstd are disabled so fully static builds need no extra libs.
set(HTTPLIB_REQUIRE_OPENSSL ON CACHE BOOL "" FORCE)
set(HTTPLIB_USE_ZLIB_IF_AVAILABLE OFF CACHE BOOL "" FORCE)
set(HTTPLIB_USE_BROTLI_IF_AVAILABLE OFF CACHE BOOL "" FORCE)
set(HTTPLIB_USE_ZSTD_IF_AVAILABLE OFF CACHE BOOL "" FORCE)
FetchContent_Declare(httplib
    GIT_REPOSITORY https://github.com/yhirose/cpp-httplib.git
    GIT_TAG        v0.18.3
    GIT_SHALLOW    TRUE)
FetchContent_MakeAvailable(httplib)

# ---------------------------------------------------------------------------
# Embedded assets: bake builtin/default_init.lua into a generated header.
# ---------------------------------------------------------------------------
set(KLUA_EMBEDDED_HEADER "${CMAKE_CURRENT_BINARY_DIR}/generated/klua/embedded_assets.hpp")
add_custom_command(
    OUTPUT "${KLUA_EMBEDDED_HEADER}"
    COMMAND "${CMAKE_COMMAND}"
        "-DINPUT=${CMAKE_CURRENT_SOURCE_DIR}/builtin/default_init.lua"
        "-DOUTPUT=${KLUA_EMBEDDED_HEADER}"
        -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/EmbedLua.cmake"
    DEPENDS
        "${CMAKE_CURRENT_SOURCE_DIR}/builtin/default_init.lua"
        "${CMAKE_CURRENT_SOURCE_DIR}/cmake/EmbedLua.cmake"
    COMMENT "Embedding builtin/default_init.lua into embedded_assets.hpp"
    VERBATIM)
add_custom_target(klua_embedded_assets DEPENDS "${KLUA_EMBEDDED_HEADER}")

# ---------------------------------------------------------------------------
# klua executable
# ---------------------------------------------------------------------------
add_executable(klua
    src/main.cpp
    src/paths.cpp
    src/lua_engine.cpp
    src/sys.cpp
    src/http.cpp
    src/crypto.cpp
    src/archive.cpp
    src/fsops.cpp
    src/serialize.cpp)
add_dependencies(klua klua_embedded_assets)

target_include_directories(klua PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
    "${CMAKE_CURRENT_BINARY_DIR}/generated")

target_compile_definitions(klua PRIVATE KLUA_VERSION="${PROJECT_VERSION}")

target_link_libraries(klua PRIVATE
    CLI11::CLI11
    klua_sol2
    klua_lua54
    yaml-cpp::yaml-cpp
    nlohmann_json::nlohmann_json
    httplib::httplib
    OpenSSL::Crypto
    Threads::Threads)

if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    target_compile_options(klua PRIVATE -Wall -Wextra -Wpedantic)
endif()

install(TARGETS klua RUNTIME DESTINATION bin)
