#include "serialize.hpp"

#include <nlohmann/json.hpp>
#include <yaml-cpp/yaml.h>

#include <exception>

namespace klua::serialize {

namespace {

sol::object json_node_to_lua(sol::state& lua, const nlohmann::json& node) {
    using nlohmann::json;
    switch (node.type()) {
        case json::value_t::object: {
            sol::table table = lua.create_table();
            for (const auto& [key, value] : node.items()) {
                table[key] = json_node_to_lua(lua, value);
            }
            return table;
        }
        case json::value_t::array: {
            sol::table table = lua.create_table();
            int index = 1;
            for (const auto& value : node) {
                table[index++] = json_node_to_lua(lua, value);
            }
            return table;
        }
        case json::value_t::string:
            return sol::make_object(lua, node.get<std::string>());
        case json::value_t::boolean:
            return sol::make_object(lua, node.get<bool>());
        case json::value_t::number_integer:
            return sol::make_object(lua, node.get<lua_Integer>());
        case json::value_t::number_unsigned:
            return sol::make_object(lua, static_cast<lua_Integer>(node.get<std::uint64_t>()));
        case json::value_t::number_float:
            return sol::make_object(lua, node.get<double>());
        case json::value_t::null:
        default:
            return sol::make_object(lua, sol::nil);
    }
}

sol::object yaml_node_to_lua(sol::state& lua, const YAML::Node& node) {
    switch (node.Type()) {
        case YAML::NodeType::Map: {
            sol::table table = lua.create_table();
            for (const auto& pair : node) {
                table[pair.first.as<std::string>()] = yaml_node_to_lua(lua, pair.second);
            }
            return table;
        }
        case YAML::NodeType::Sequence: {
            sol::table table = lua.create_table();
            int index = 1;
            for (const auto& value : node) {
                table[index++] = yaml_node_to_lua(lua, value);
            }
            return table;
        }
        case YAML::NodeType::Scalar: {
            const std::string tag = node.Tag();
            if (tag == "tag:yaml.org,2002:null" || node.IsNull()) {
                return sol::make_object(lua, sol::nil);
            }
            if (tag == "tag:yaml.org,2002:bool") {
                return sol::make_object(lua, node.as<bool>());
            }
            if (tag == "tag:yaml.org,2002:int") {
                return sol::make_object(lua, node.as<lua_Integer>());
            }
            if (tag == "tag:yaml.org,2002:float") {
                return sol::make_object(lua, node.as<double>());
            }
            return sol::make_object(lua, node.Scalar());
        }
        case YAML::NodeType::Undefined:
        case YAML::NodeType::Null:
        default:
            return sol::make_object(lua, sol::nil);
    }
}

} // namespace

sol::object json_to_lua(sol::state& lua, const std::string& text, std::string& error) {
    const nlohmann::json parsed = nlohmann::json::parse(text, nullptr, false);
    if (parsed.is_discarded()) {
        error = "invalid JSON";
        return sol::make_object(lua, sol::nil);
    }
    return json_node_to_lua(lua, parsed);
}

sol::object yaml_to_lua(sol::state& lua, const std::string& text, std::string& error) {
    try {
        const YAML::Node root = YAML::Load(text);
        return yaml_node_to_lua(lua, root);
    } catch (const YAML::Exception& ex) {
        error = ex.what();
        return sol::make_object(lua, sol::nil);
    }
}

} // namespace klua::serialize
