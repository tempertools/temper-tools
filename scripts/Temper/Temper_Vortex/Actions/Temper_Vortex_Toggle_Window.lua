-- AUTO-GENERATED from actions/manifest.toml. Do not edit.
-- @description Temper: Vortex – Toggle Window
-- @author Temper Tools
-- @noindex
-- Resolve sibling lib/ via this stub's own location (see _COMMAND_STUB).
local sep = package.config:sub(1, 1)
local _stub_path = debug.getinfo(1, "S").source:sub(2)
local _stub_dir  = (_stub_path:match("^(.*)[\\/]") or ".")
package.path = _stub_dir .. sep .. ".." .. sep .. "lib" .. sep .. "?.lua;" .. package.path
local actions = require("temper_actions")
actions.toggle_window("TEMPER_Vortex", "Vortex", "Temper_Vortex.lua")
