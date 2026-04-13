-- AUTO-GENERATED from actions/manifest.toml. Do not edit.
-- @description Temper: Imprint – Apply Preset Slot 5
-- @author Temper
-- @noindex
local sep = package.config:sub(1, 1)
package.path = reaper.GetResourcePath() .. sep .. "Scripts" .. sep .. "Temper" .. sep .. "lib" .. sep .. "?.lua;" .. package.path
local actions = require("rsg_actions")
if actions.gui_is_running("TEMPER_Imprint") then
  actions.dispatch("TEMPER_Imprint", "apply_preset_5")
else
  actions.notify_gui_required("Imprint")
end
