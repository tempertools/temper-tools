-- AUTO-GENERATED from actions/manifest.toml. Do not edit.
-- @description Temper: Vortex – Toggle Window
-- @author Temper
-- @noindex
local sep = package.config:sub(1, 1)
package.path = reaper.GetResourcePath() .. sep .. "Scripts" .. sep .. "Temper" .. sep .. "lib" .. sep .. "?.lua;" .. package.path
local actions = require("rsg_actions")
actions.toggle_window("TEMPER_Vortex", "Vortex", "Temper_Vortex.lua")
