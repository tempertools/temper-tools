-- AUTO-GENERATED from actions/manifest.toml. Do not edit.
-- @description Temper: Slice Mini – Remove Selected
-- @author Temper Tools
-- @noindex
-- Resolve sibling lib/ via this stub's own location, so the same code works in
-- both the dev layout (Scripts/Temper/Actions/) and the per-package ReaPack
-- layout (Scripts/Temper/Temper/Temper_<Script>/Actions/).
local sep = package.config:sub(1, 1)
local _stub_path = debug.getinfo(1, "S").source:sub(2)
local _stub_dir  = (_stub_path:match("^(.*)[\\/]") or ".")
package.path = _stub_dir .. sep .. ".." .. sep .. "lib" .. sep .. "?.lua;" .. package.path
local actions = require("temper_actions")
if actions.gui_is_running("TEMPER_SliceMini") then
  actions.dispatch("TEMPER_SliceMini", "remove_selected")
else
  actions.notify_gui_required("Slice Mini")
end
