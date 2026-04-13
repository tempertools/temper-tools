-- AUTO-GENERATED from actions/manifest.toml. Do not edit.
-- @description Temper: Alloy – Toggle Select All Groups
-- @author Temper
-- @noindex
local sep = package.config:sub(1, 1)
package.path = reaper.GetResourcePath() .. sep .. "Scripts" .. sep .. "Temper" .. sep .. "lib" .. sep .. "?.lua;" .. package.path
local actions = require("rsg_actions")
if actions.gui_is_running("TEMPER_Alloy") then
  actions.dispatch("TEMPER_Alloy", "toggle_select_all_groups")
else
  actions.notify_gui_required("Alloy")
end
