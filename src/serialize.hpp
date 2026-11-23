#pragma once

#include <sol/sol.hpp>

#include <string>

namespace klua::serialize {

// Parse JSON text into Lua values (objects -> tables, arrays -> 1-based
// tables). Returns nil and fills `error` on parse failure.
sol::object json_to_lua(sol::state& lua, const std::string& text, std::string& error);

// Parse YAML text into Lua values (mappings -> tables, sequences -> 1-based
// tables, scalars -> string/number/boolean/nil). Returns nil and fills
// `error` on parse failure.
sol::object yaml_to_lua(sol::state& lua, const std::string& text, std::string& error);

} // namespace klua::serialize
