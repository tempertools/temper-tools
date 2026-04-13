-- AUTO-GENERATED from actions/manifest.toml. Do not edit.
-- @description Temper: Imprint – Copy Properties
-- @author Temper
-- @noindex
local sep = package.config:sub(1, 1)
package.path = reaper.GetResourcePath() .. sep .. "Scripts" .. sep .. "Temper" .. sep .. "lib" .. sep .. "?.lua;" .. package.path
local actions = require("rsg_actions")
if actions.gui_is_running("TEMPER_Imprint") then
  actions.dispatch("TEMPER_Imprint", "copy")
else
  actions.notify_gui_required("Imprint")
end
