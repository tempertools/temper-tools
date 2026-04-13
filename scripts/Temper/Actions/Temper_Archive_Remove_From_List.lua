-- AUTO-GENERATED from actions/manifest.toml. Do not edit.
-- @description Temper: Archive – Remove From List
-- @author Temper
-- @noindex
local sep = package.config:sub(1, 1)
package.path = reaper.GetResourcePath() .. sep .. "Scripts" .. sep .. "Temper" .. sep .. "lib" .. sep .. "?.lua;" .. package.path
local actions = require("rsg_actions")
if actions.gui_is_running("TEMPER_Archive") then
  actions.dispatch("TEMPER_Archive", "remove_from_list")
else
  actions.notify_gui_required("Archive")
end
