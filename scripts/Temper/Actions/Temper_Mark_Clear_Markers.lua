-- AUTO-GENERATED from actions/manifest.toml. Do not edit.
-- @description Temper: Mark – Clear Markers
-- @author Temper
-- @noindex
local sep = package.config:sub(1, 1)
package.path = reaper.GetResourcePath() .. sep .. "Scripts" .. sep .. "Temper" .. sep .. "lib" .. sep .. "?.lua;" .. package.path
local actions = require("rsg_actions")
if actions.gui_is_running("TEMPER_Mark") then
  actions.dispatch("TEMPER_Mark", "clear_markers")
else
  actions.notify_gui_required("Mark")
end
