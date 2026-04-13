-- AUTO-GENERATED from actions/manifest.toml. Do not edit.
-- @description Temper: Vortex – Capture Properties
-- @author Temper
-- @noindex
local sep = package.config:sub(1, 1)
package.path = reaper.GetResourcePath() .. sep .. "Scripts" .. sep .. "Temper" .. sep .. "lib" .. sep .. "?.lua;" .. package.path
local actions = require("rsg_actions")
if actions.gui_is_running("TEMPER_Vortex") then
  actions.dispatch("TEMPER_Vortex", "capture")
else
  actions.notify_gui_required("Vortex")
end
