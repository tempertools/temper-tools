-- @description Temper Imprint -- Property Selection & Paste Properties
-- @version 1.4.1
-- @author Temper Tools
-- @provides
--   [main] Temper_Imprint.lua
--   [nomain] lib/temper_theme.lua
--   [nomain] lib/temper_pp_apply.lua
--   [nomain] lib/temper_track_utils.lua
--   [nomain] lib/temper_actions.lua
--   [nomain] lib/temper_license.lua
--   [nomain] lib/temper_activation_dialog.lua
--   [nomain] lib/temper_sha256.lua
-- @about
--   Temper Imprint is a property selection GUI for the Temper suite.
--   It controls which item/take properties are enabled for Copy/Paste
--   operations and feeds checkbox state to Vortex and Vortex Mini via
--   ExtState bridge (section "rsg_item_copier_v2", keys "cb_<key>").
--
--   Features:
--   - 24 property toggles organised in Take / Item columns
--   - Quick Preset bar with 4 customisable slots
--   - Save / Load / Manage custom presets via Settings overlay
--   - Copy: capture property values from selected item
--   - Paste: apply captured values to selected items (respects toggles)
--
--   Requires: ReaImGui (install via ReaPack -- Extensions)

-- ============================================================
-- Dependency checks
-- ============================================================

if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox(
    "Temper Imprint requires ReaImGui.\nInstall via ReaPack: Extensions > ReaImGui",
    "Missing Dependency", 0)
  return
end

-- ============================================================
-- Property descriptors
-- ============================================================

-- ExtState section shared with Vortex / Vortex Mini for checkbox bridge.
local _PP_SEC = "rsg_item_copier_v2"

-- Take property descriptors -- superset including t_rate and t_offs
-- that Vortex Mini deliberately omits.
local _PP_TAKE_PROPS = {
  { key = "t_vol",       parmname = "D_VOL",       label = "Volume"       },
  { key = "t_pan",       parmname = "D_PAN",       label = "Pan"          },
  { key = "t_rate",      parmname = "D_PLAYRATE",  label = "Playrate"     },
  { key = "t_pitch",     parmname = "D_PITCH",     label = "Pitch"        },
  { key = "t_chan",       parmname = "I_CHANMODE",  label = "Channel Mode" },
  { key = "t_offs",      parmname = "D_STARTOFFS", label = "Start Offset" },
  { key = "t_plaw",      parmname = "I_PANLAW",    label = "Pan Law"      },
  { key = "t_name",      parmname = "P_NAME",      label = "Name",        is_string   = true },
  { key = "t_env_vol",   env_name = "Volume",      label = "Vol Env",     is_envelope = true },
  { key = "t_env_pan",   env_name = "Pan",         label = "Pan Env",     is_envelope = true },
  { key = "t_env_pitch", env_name = "Pitch",       label = "Pitch Env",   is_envelope = true },
}

-- Item property descriptors -- includes i_pos and i_len (Vortex omits these).
local _PP_ITEM_PROPS = {
  { key = "i_vol",  parmname = "D_VOL",          label = "Volume"           },
  { key = "i_mute", parmname = "B_MUTE",         label = "Mute"             },
  { key = "i_lock", parmname = "C_LOCK",         label = "Lock"             },
  { key = "i_loop", parmname = "B_LOOPSRC",      label = "Loop Source"      },
  { key = "i_fil",  parmname = "D_FADEINLEN",    label = "Fade In Length"   },
  { key = "i_fis",  parmname = "C_FADEINSHAPE",  label = "Fade In Shape"    },
  { key = "i_fol",  parmname = "D_FADEOUTLEN",   label = "Fade Out Length"  },
  { key = "i_fos",  parmname = "C_FADEOUTSHAPE", label = "Fade Out Shape"   },
  { key = "i_lpf",  parmname = "I_FADELPF",      label = "Fade LP"          },
  { key = "i_snap", parmname = "D_SNAPOFFSET",   label = "Snap Offset"      },
  { key = "i_pos",  parmname = "D_POSITION",     label = "Position"         },
  { key = "i_len",  parmname = "D_LENGTH",       label = "Length"           },
}

-- All property keys for iteration (including i_fx, excluding i_len which is special).
local _ALL_KEYS = {}
for _, p in ipairs(_PP_TAKE_PROPS) do _ALL_KEYS[#_ALL_KEYS + 1] = p.key end
for _, p in ipairs(_PP_ITEM_PROPS) do _ALL_KEYS[#_ALL_KEYS + 1] = p.key end
_ALL_KEYS[#_ALL_KEYS + 1] = "i_fx"

-- ============================================================
-- lib/ module loading
-- ============================================================

-- Resolve lib/ as a sibling of this script (works for both dev layout and
-- per-package ReaPack layout — see Temper_Vortex.lua for context).
local _script_path = debug.getinfo(1, "S").source:sub(2)
local _lib         = (_script_path:match("^(.*)[\\/]") or ".") .. "/lib/"
local track_mod   = dofile(_lib .. "temper_track_utils.lua")
local rsg_actions = dofile(_lib .. "temper_actions.lua")

-- rsg_pp_apply needs a trim_item_to_max function; provide a simple one for Imprint.
local function _trim_item_to_max(item, max_len)
  local cur = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  if cur > max_len then reaper.SetMediaItemLength(item, max_len, false) end
end
local _pp_mod = dofile(_lib .. "temper_pp_apply.lua")
local _pp = _pp_mod.create(_PP_TAKE_PROPS, _PP_ITEM_PROPS, _trim_item_to_max)

-- ============================================================
-- ExtState namespaces
-- ============================================================

local _IMP_NS  = "TEMPER_Imprint"   -- script-local state (presets, instance guard)

-- ============================================================
-- Spectral Core color tokens (local alias)
-- ============================================================

pcall(dofile, _lib .. "temper_theme.lua")
local SC = (type(temper_theme) == "table") and temper_theme.SC or {}

-- Fallback if theme failed to load (should not happen in normal use).
if not SC.PRIMARY then
  SC = {
    WINDOW = 0x0E0E10FF, PANEL = 0x1E1E20FF, PANEL_HIGH = 0x282828FF,
    PANEL_TOP = 0x323232FF, HOVER_LIST = 0x39393BFF,
    PRIMARY = 0x26A69AFF, PRIMARY_LT = 0x66D9CCFF,
    PRIMARY_HV = 0x30B8ACFF, PRIMARY_AC = 0x1A8A7EFF,
    TEXT_ON = 0xDEDEDEFF, TEXT_MUTED = 0xBCC9C6FF, TEXT_OFF = 0x505050FF,
    TITLE_BAR = 0x1A1A1CFF, HOVER_INACTIVE = 0x2A2A2CFF,
    ACTIVE_DARK = 0x141416FF, ACTIVE_DARKER = 0x161618FF,
    TERTIARY = 0xDA7C5AFF, TERTIARY_HV = 0xE08A6AFF, TERTIARY_AC = 0xC46A4AFF,
    DEL_BTN = 0x282828FF, DEL_HV = 0x39393BFF, DEL_AC = 0x1E1E20FF,
    HOVER_GHOST = 0xFFFFFF1A, ACTIVE_GHOST = 0x0000001F,
    ICON_DISABLED = 0x606060FF,
  }
end

-- Override red delete colors with orange (on-palette TERTIARY family)
SC.DEL_BTN = SC.TERTIARY
SC.DEL_HV  = SC.TERTIARY_HV
SC.DEL_AC  = SC.TERTIARY_AC

-- ============================================================
-- Built-in preset definitions
-- ============================================================

local _FULL_RESET = {}  -- sentinel: distinct table ref means "all ON"
local _NONE       = {}  -- sentinel: distinct table ref means "all OFF"
local _BUILTIN_PRESETS = {
  ["All"]      = _FULL_RESET,
  ["None"]     = _NONE,
  ["Fades"]    = { i_fis = true, i_fos = true, i_fil = true, i_fol = true },
  ["Envs"]     = { t_env_vol = true, t_env_pan = true, t_env_pitch = true },
  ["FX"]       = { i_fx = true },
}

local _BUILTIN_NAMES = { "All", "None", "Fades", "Envs", "FX" }
local _MAX_SLOTS       = 6
local _MAX_PRESETS     = 6
local _MAX_NAME_LEN    = 6
local _SETTINGS_WIN_H  = 300   -- shorter window when settings overlay is open
local _DEFAULT_QUICK_SLOTS = { "All", "None", "Fades", "Envs" }  -- slots 5-6 default nil

-- ============================================================
-- Preset persistence helpers
-- ============================================================

local function _serialize_keys(tbl)
  local parts = {}
  for k, v in pairs(tbl) do
    if v then parts[#parts + 1] = k end
  end
  table.sort(parts)
  return table.concat(parts, "|")
end

local function _deserialize_keys(str)
  if not str or str == "" then return nil end
  local t = {}
  for k in str:gmatch("[^|]+") do t[k] = true end
  return t
end

local function _load_presets()
  local presets = {}
  -- Load user presets from ExtState
  local list_str = reaper.GetExtState(_IMP_NS, "preset_list")
  if list_str ~= "" then
    for name in list_str:gmatch("[^|]+") do
      local data = reaper.GetExtState(_IMP_NS, "preset_" .. name)
      if data ~= "" then presets[name] = _deserialize_keys(data) end
    end
  end
  return presets
end

local function _save_presets(presets)
  local names = {}
  for name in pairs(presets) do names[#names + 1] = name end
  table.sort(names)
  reaper.SetExtState(_IMP_NS, "preset_list", table.concat(names, "|"), true)
  for _, name in ipairs(names) do
    reaper.SetExtState(_IMP_NS, "preset_" .. name, _serialize_keys(presets[name]), true)
  end
end

local function _load_quick_slots()
  local str = reaper.GetExtState(_IMP_NS, "quick_slots_v2")
  if str == "" then
    -- Fall back to v1 format (no nil support)
    str = reaper.GetExtState(_IMP_NS, "quick_slots")
  end
  if str == "" then return { table.unpack(_DEFAULT_QUICK_SLOTS) } end
  local slots = {}
  for seg in str:gmatch("[^|]+") do
    slots[#slots + 1] = (seg == "_NIL_") and nil or seg
  end
  if #slots == 0 then return { table.unpack(_DEFAULT_QUICK_SLOTS) } end
  -- Validate slot references: nil out any that point to deleted presets.
  -- Built-in presets and user presets loaded separately; user presets not
  -- available yet at this point, so defer full validation to after _load_presets.
  -- Here we validate built-in names only; orphaned user refs cleaned in entry point.
  return slots
end

-- Remove slot references that point to neither a built-in nor a user preset.
local function _clean_orphaned_slots(slots, presets)
  local dirty = false
  for i = 1, _MAX_SLOTS do
    local name = slots[i]
    if name and not _BUILTIN_PRESETS[name] and not presets[name] then
      slots[i] = nil
      dirty = true
    end
  end
  if dirty then _save_quick_slots(slots) end
end

local function _save_quick_slots(slots)
  local parts = {}
  for i = 1, _MAX_SLOTS do
    parts[i] = slots[i] or "_NIL_"
  end
  reaper.SetExtState(_IMP_NS, "quick_slots_v2", table.concat(parts, "|"), true)
end

local function _count_user_presets(presets)
  local n = 0
  for _ in pairs(presets) do n = n + 1 end
  return n
end

-- ============================================================
-- Checkbox state helpers
-- ============================================================

-- Properties that default to OFF on first use (can move items unexpectedly).
local _DEFAULTS_OFF = { i_pos = true, i_len = true }

local function _init_checks()
  local checks = {}
  for _, k in ipairs(_ALL_KEYS) do
    local v = reaper.GetExtState(_PP_SEC, "cb_" .. k)
    if v == "" then
      checks[k] = not _DEFAULTS_OFF[k]  -- absent: ON unless dangerous
    else
      checks[k] = (v == "1")
    end
  end
  return checks
end

local function _write_check(key, val)
  reaper.SetExtState(_PP_SEC, "cb_" .. key, val and "1" or "0", true)
end

local function _write_all_checks(checks)
  for _, k in ipairs(_ALL_KEYS) do _write_check(k, checks[k]) end
end

local function _apply_preset(checks, preset_keys)
  -- preset_keys is nil for "All" (all ON), or a table of enabled keys.
  for _, k in ipairs(_ALL_KEYS) do
    if preset_keys then
      checks[k] = preset_keys[k] or false
    else
      checks[k] = true
    end
  end
  _write_all_checks(checks)
end


-- ============================================================
-- Snapshot persistence (survives script close / REAPER restart)
-- ============================================================

local function _persist_snapshot(snapshot)
  if not snapshot then return end
  local slot = snapshot.tracks["__default__"]
  if not slot then return end
  -- Persist scalar props as individual ExtState keys
  for _, p in ipairs(_PP_TAKE_PROPS) do
    local v = slot.props[p.key] or ""
    reaper.SetExtState(_IMP_NS, "snap_" .. p.key, v, true)
  end
  for _, p in ipairs(_PP_ITEM_PROPS) do
    local v = slot.props[p.key] or ""
    reaper.SetExtState(_IMP_NS, "snap_" .. p.key, v, true)
  end
  reaper.SetExtState(_IMP_NS, "snap_fx_chunk", slot.fx_chunk or "", true)
  reaper.SetExtState(_IMP_NS, "snap_source_length",
    tostring(snapshot.source_length or 0), true)
  reaper.SetExtState(_IMP_NS, "snap_count",
    tostring(snapshot.count or 1), true)
  reaper.SetExtState(_IMP_NS, "snap_source_item_guid",
    snapshot.source_item_guid or "", true)
end

local function _restore_snapshot()
  local count_str = reaper.GetExtState(_IMP_NS, "snap_count")
  if count_str == "" then return nil end
  local slot = { props = {}, fx_chunk = "" }
  for _, p in ipairs(_PP_TAKE_PROPS) do
    local v = reaper.GetExtState(_IMP_NS, "snap_" .. p.key)
    if v ~= "" then slot.props[p.key] = v end
  end
  for _, p in ipairs(_PP_ITEM_PROPS) do
    local v = reaper.GetExtState(_IMP_NS, "snap_" .. p.key)
    if v ~= "" then slot.props[p.key] = v end
  end
  slot.fx_chunk = reaper.GetExtState(_IMP_NS, "snap_fx_chunk")
  local src_len = tonumber(reaper.GetExtState(_IMP_NS, "snap_source_length")) or 0
  local src_guid = reaper.GetExtState(_IMP_NS, "snap_source_item_guid")
  return {
    tracks           = { ["__default__"] = slot },
    enabled          = {},
    count            = tonumber(count_str) or 1,
    source_length    = src_len,
    source_item_guid = src_guid ~= "" and src_guid or nil,
  }
end

-- ============================================================
-- Copy / Paste operations
-- ============================================================

-- Capture a single item's properties into `snapshot.tracks[track_key]`.
-- Extracted from _do_copy so the multi-item branch can reuse it. Returns
-- the item's source length (D_LENGTH) and the item's GUID string, so the
-- caller can aggregate source_length and build the source_item_guids set.
local function _capture_one(item, snapshot, track_key)
  local take = reaper.GetActiveTake(item)
  local slot = { props = {}, fx_chunk = "" }

  -- Take scalar properties
  for _, p in ipairs(_PP_TAKE_PROPS) do
    if not p.is_envelope and take then
      if p.is_string then
        local _, v = reaper.GetSetMediaItemTakeInfo_String(take, p.parmname, "", false)
        if v and v ~= "" then slot.props[p.key] = v end
      else
        slot.props[p.key] = tostring(reaper.GetMediaItemTakeInfo_Value(take, p.parmname))
      end
    end
  end

  -- Take envelope chunks
  if take then
    for _, p in ipairs(_PP_TAKE_PROPS) do
      if p.is_envelope then
        local env = reaper.GetTakeEnvelopeByName(take, p.env_name)
        if env and reaper.CountEnvelopePoints(env) > 0 then
          local _, chunk = reaper.GetEnvelopeStateChunk(env, "", false)
          if chunk and chunk ~= "" then slot.props[p.key] = chunk end
        end
      end
    end
  end

  -- Item scalar properties
  for _, p in ipairs(_PP_ITEM_PROPS) do
    slot.props[p.key] = tostring(reaper.GetMediaItemInfo_Value(item, p.parmname))
  end

  -- FX chain via state-chunk extraction
  local ok_chunk, item_chunk = reaper.GetItemStateChunk(item, "", false)
  if ok_chunk and item_chunk ~= "" then
    local s = item_chunk:find("<TAKEFX", 1, true)
    if s and item_chunk:sub(s + 7, s + 7):match("[%s>]") then
      local depth, j = 1, s + 1
      while j <= #item_chunk and depth > 0 do
        local c = item_chunk:sub(j, j)
        if c == "<" then depth = depth + 1 elseif c == ">" then depth = depth - 1 end
        j = j + 1
      end
      slot.fx_chunk = item_chunk:sub(s, j - 1)
    end
  end

  snapshot.tracks[track_key] = slot

  local _, item_guid = reaper.GetSetMediaItemInfo_String(item, "GUID", "", false)
  if item_guid == "" then item_guid = nil end
  return reaper.GetMediaItemInfo_Value(item, "D_LENGTH"), item_guid
end

local function _do_copy(state)
  local count = reaper.CountSelectedMediaItems(0)
  if count == 0 then return false end

  local snapshot = {
    tracks            = {},
    enabled           = {},
    count             = count,
    source_length     = 0,
    mode              = (count >= 2) and "per_track" or "broadcast",
    source_item_guids = {},
    source_item_guid  = nil,
  }

  if count == 1 then
    -- Broadcast path (byte-identical to v1.3.10).
    local item = reaper.GetSelectedMediaItem(0, 0)
    if not item or not reaper.ValidatePtr(item, "MediaItem*") then return false end
    local d_length, item_guid = _capture_one(item, snapshot, "__default__")
    snapshot.source_length   = d_length
    snapshot.source_item_guid = item_guid
    if item_guid then snapshot.source_item_guids[item_guid] = true end
  else
    -- Per-track path: one slot per unique source track, first-encountered
    -- item per track wins (same-track duplicates silently dropped).
    local seen_tracks = {}
    local max_length = 0
    for i = 0, count - 1 do
      local item = reaper.GetSelectedMediaItem(0, i)
      if item and reaper.ValidatePtr(item, "MediaItem*") then
        local tr = reaper.GetMediaItem_Track(item)
        local tguid = tr and reaper.GetTrackGUID(tr) or nil
        if tguid and not seen_tracks[tguid] then
          seen_tracks[tguid] = true
          local d_length, item_guid = _capture_one(item, snapshot, tguid)
          if d_length and d_length > max_length then max_length = d_length end
          if item_guid then snapshot.source_item_guids[item_guid] = true end
        end
      end
    end
    snapshot.source_length = max_length
    -- Degenerate case: user selected multiple items but all on the same
    -- track (only one slot was captured). mode stays "per_track" so paste
    -- only matches items on that one track — consistent with same-track
    -- collision rule.
    local any = false
    for _ in pairs(snapshot.tracks) do any = true; break end
    if not any then return false end
  end

  state.snapshot     = snapshot
  state.has_source   = true
  state.source_count = count
  state.copy_flash   = reaper.time_precise() + 1.2
  _persist_snapshot(state.snapshot)
  return true
end

local function _do_paste(state)
  if not state.snapshot then return 0 end
  local count = reaper.CountSelectedMediaItems(0)
  if count == 0 then return 0 end

  -- Build enabled from current checkbox state.
  local enabled = {}
  for _, k in ipairs(_ALL_KEYS) do enabled[k] = state.checks[k] or false end
  state.snapshot.enabled = enabled

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local mode = state.snapshot.mode or "broadcast"
  local applied = 0
  if mode == "broadcast" then
    for i = 0, count - 1 do
      local item = reaper.GetSelectedMediaItem(0, i)
      if item and reaper.ValidatePtr(item, "MediaItem*") then
        _pp.apply_to_item(state.snapshot, item, "__default__")
        applied = applied + 1
      end
    end
  else
    -- per_track: look up each target item's track GUID in the snapshot;
    -- skip silently if no matching slot.
    for i = 0, count - 1 do
      local item = reaper.GetSelectedMediaItem(0, i)
      if item and reaper.ValidatePtr(item, "MediaItem*") then
        local tr = reaper.GetMediaItem_Track(item)
        local tguid = tr and reaper.GetTrackGUID(tr) or nil
        if tguid and state.snapshot.tracks[tguid] then
          _pp.apply_to_item(state.snapshot, item, tguid)
          applied = applied + 1
        end
      end
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Temper Imprint: Paste Properties", -1)

  if reaper.JS_Window_SetFocus then reaper.JS_Window_SetFocus(reaper.GetMainHwnd()) end
  state.paste_flash = reaper.time_precise() + 1.2
  return applied
end

-- ============================================================
-- Action handlers (rsg_actions framework)
-- ============================================================
-- imprint_actions: 1:1 mirror of the GUI button callbacks, called by both
-- the GUI and rsg_actions keyboard dispatch. Subset-of-GUI invariant —
-- no action introduces new logic, every entry is a thin pointer.
--
-- MUST be declared above every render_* function that references it,
-- otherwise Lua resolves `imprint_actions` as a global at parse time and
-- button callbacks throw `attempt to index a nil value (global 'imprint_actions')`
-- at runtime.

local imprint_actions = {}

function imprint_actions.do_copy(state)  _do_copy(state)  end
function imprint_actions.do_paste(state) _do_paste(state) end

-- Resolve a Quick Preset slot name to its preset_keys table, matching the
-- GUI pill callback's resolution logic exactly (_BUILTIN_PRESETS >
-- user presets > _FULL_RESET / _NONE sentinels).
local function _apply_slot(state, slot_idx)
  local slot_name = state.quick_slots[slot_idx]
  if not slot_name then return end
  local preset_keys = _BUILTIN_PRESETS[slot_name]
  if not preset_keys then preset_keys = state.presets[slot_name] end
  if preset_keys == _FULL_RESET then preset_keys = nil
  elseif preset_keys == _NONE then preset_keys = {} end
  if preset_keys ~= nil or slot_name == "All" then
    _apply_preset(state.checks, preset_keys)
  end
end

for i = 1, _MAX_SLOTS do
  imprint_actions["apply_preset_" .. i] = function(state) _apply_slot(state, i) end
end

-- Returns true if the keyboard-dispatched flash for `btn_key` is still active.
-- Used by render_* functions to swap a button's background to its pressed shade
-- while the flash timer is live, visually mimicking a mouse click.
--
-- Harness-only: when _TEMPER_HARNESS is set, state._harness_hold_flash[btn_key]
-- forces the flash to read as active regardless of the real timer. This lets
-- the testing harness capture the 250ms-flashed button state in a static
-- screenshot (the real flash window is shorter than the screenshot settle).
local function _is_btn_flashing(state, btn_key)
  if _TEMPER_HARNESS and state._harness_hold_flash and state._harness_hold_flash[btn_key] then
    return true
  end
  local expires_at = state._btn_flash and state._btn_flash[btn_key]
  return expires_at ~= nil and reaper.time_precise() < expires_at
end

-- ============================================================
-- GUI: Title bar + settings popup
-- ============================================================

-- Forward-declare so render_title_bar can call it (resolved at call time).
local render_settings_popup

local function render_title_bar(ctx, state, lic, lic_status)
  local R      = reaper
  local w      = R.ImGui_GetWindowWidth(ctx)
  local btn_w  = 22
  local font_b = temper_theme and temper_theme.font_bold

  if font_b then R.ImGui_PushFont(ctx, font_b, 13) end
  R.ImGui_SetCursorPosX(ctx, 8)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.PRIMARY)
  R.ImGui_Text(ctx, "TEMPER - IMPRINT")
  R.ImGui_PopStyleColor(ctx, 1)
  if font_b then R.ImGui_PopFont(ctx) end

  -- Source count (muted text, right of title)
  R.ImGui_SameLine(ctx)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.TEXT_MUTED)
  if state.has_source then
    R.ImGui_Text(ctx, string.format("Sources: %d copied", state.source_count))
  else
    R.ImGui_Text(ctx, "No source")
  end
  R.ImGui_PopStyleColor(ctx, 1)

  -- Settings gear: DrawList primitives (font-free, OS-agnostic)
  R.ImGui_SameLine(ctx)
  R.ImGui_SetCursorPosX(ctx, w - btn_w - 8)
  local bx, by = R.ImGui_GetCursorScreenPos(ctx)
  local dl = R.ImGui_GetWindowDrawList(ctx)
  R.ImGui_PushClipRect(ctx, bx, by, bx + btn_w, by + btn_w, false)
  local clicked = R.ImGui_InvisibleButton(ctx, "##settings_imp", btn_w, btn_w)
  local hovered = R.ImGui_IsItemHovered(ctx)
  if hovered then
    R.ImGui_DrawList_AddRectFilled(dl, bx, by, bx + btn_w, by + btn_w, SC.HOVER_LIST)
  end
  local cx, cy = bx + btn_w * 0.5, by + btn_w * 0.5
  R.ImGui_DrawList_AddCircle(dl, cx, cy, 7, SC.PRIMARY, 16, 1.5)
  R.ImGui_DrawList_AddCircleFilled(dl, cx, cy, 2.5, SC.PRIMARY, 12)
  R.ImGui_PopClipRect(ctx)
  if clicked then R.ImGui_OpenPopup(ctx, "##settings_popup_imp") end
  if hovered then R.ImGui_SetTooltip(ctx, "Settings") end
  render_settings_popup(ctx, state, lic, lic_status)
end

-- Settings popup (gear dropdown): Settings / Close / Activate (trial only).
-- Assigned to forward-declared local so render_title_bar can call it.
render_settings_popup = function(ctx, state, lic, lic_status)
  local R = reaper
  if not R.ImGui_BeginPopup(ctx, "##settings_popup_imp") then return end

  R.ImGui_TextDisabled(ctx, "Settings")
  R.ImGui_Separator(ctx)
  R.ImGui_Spacing(ctx)

  if R.ImGui_Button(ctx, "Close##popup_close") then
    state.should_close = true
    R.ImGui_CloseCurrentPopup(ctx)
  end

  if lic_status == "trial" and lic then
    R.ImGui_Spacing(ctx)
    R.ImGui_Separator(ctx)
    R.ImGui_Spacing(ctx)
    if R.ImGui_Button(ctx, "Activate\xE2\x80\xA6##popup_lic") then
      lic.open_dialog(ctx)
      R.ImGui_CloseCurrentPopup(ctx)
    end
  end

  R.ImGui_Spacing(ctx)
  R.ImGui_Separator(ctx)
  R.ImGui_Spacing(ctx)

  local presets_label = state.settings_open and "Main##popup_settings" or "Presets##popup_settings"
  if R.ImGui_Button(ctx, presets_label) then
    state.settings_open = not state.settings_open
    R.ImGui_CloseCurrentPopup(ctx)
  end

  R.ImGui_EndPopup(ctx)
end

-- ============================================================
-- GUI: Quick Presets bar
-- ============================================================

local function render_quick_presets(ctx, state)
  local R      = reaper
  local font_b = temper_theme and temper_theme.font_bold
  local font_r = temper_theme and temper_theme.font_regular

  -- "PRESETS" header: bold teal
  if font_b then R.ImGui_PushFont(ctx, font_b, 13) end
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.PRIMARY)
  R.ImGui_Text(ctx, "PRESETS")
  R.ImGui_PopStyleColor(ctx, 1)
  if font_b then R.ImGui_PopFont(ctx) end

  -- Preset pills: regular weight, teal text, equal width
  if font_r then R.ImGui_PushFont(ctx, font_r, 13) end

  -- Count visible slots for equal-width calculation
  local n_visible = 0
  for i = 1, _MAX_SLOTS do
    if state.quick_slots[i] then n_visible = n_visible + 1 end
  end

  local gap = 4
  local avail_w = select(1, R.ImGui_GetContentRegionAvail(ctx))
  local btn_w = n_visible > 0 and math.floor((avail_w - (n_visible - 1) * gap) / n_visible) or 0

  local first = true
  for i = 1, _MAX_SLOTS do
    local slot_name = state.quick_slots[i]
    if slot_name then
      if not first then R.ImGui_SameLine(ctx, 0, gap) end
      first = false
      local _qp_flash = _is_btn_flashing(state, "apply_preset_" .. i)
      local _qp_bg = _qp_flash and SC.ACTIVE_DARK or SC.PANEL_TOP
      local _qp_hv = _qp_flash and SC.ACTIVE_DARK or SC.HOVER_LIST
      R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        _qp_bg)
      R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), _qp_hv)
      R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  SC.ACTIVE_DARK)
      R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          SC.PRIMARY)
      if R.ImGui_Button(ctx, slot_name .. "##qp" .. i, btn_w, 0) then
        imprint_actions["apply_preset_" .. i](state)
      end
      R.ImGui_PopStyleColor(ctx, 4)
    end
  end

  if font_r then R.ImGui_PopFont(ctx) end
end

-- ============================================================
-- GUI: Checkbox grid (two-column text toggles)
-- ============================================================

local function _render_toggle(ctx, key, label, is_on)
  local R = reaper
  local bg  = is_on and SC.PANEL_TOP     or SC.PANEL
  local hv  = is_on and SC.HOVER_LIST    or SC.HOVER_INACTIVE
  local ac  = is_on and SC.ACTIVE_DARK   or SC.ACTIVE_DARKER
  local txt = is_on and SC.PRIMARY       or SC.TEXT_OFF

  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        bg)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), hv)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  ac)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          txt)

  local avail_w = select(1, R.ImGui_GetContentRegionAvail(ctx))
  local clicked = R.ImGui_Button(ctx, label .. "##" .. key, avail_w, 0)

  R.ImGui_PopStyleColor(ctx, 4)
  return clicked
end

local function render_checkbox_grid(ctx, state, grid_h)
  local R      = reaper
  local font_b = temper_theme and temper_theme.font_bold
  local font_r = temper_theme and temper_theme.font_regular
  local gap    = 8
  local avail  = select(1, R.ImGui_GetContentRegionAvail(ctx))
  local col_w  = math.floor((avail - gap) * 0.5)
  -- Guard against transient negative/zero sizes (e.g. monitor resolution
  -- change): BeginChild with non-positive size fails to push a child
  -- window, then the unconditional EndChild asserts.
  if col_w  < 1 then col_w  = 1 end
  if grid_h < 1 then grid_h = 1 end

  -- Left-align toggle button text
  R.ImGui_PushStyleVar(ctx, R.ImGui_StyleVar_ButtonTextAlign(), 0.0, 0.5)

  -- Use BeginChild for each column to get independent content regions.
  -- LEFT: Take
  if R.ImGui_BeginChild(ctx, "##take_col", col_w, grid_h, R.ImGui_ChildFlags_None()) then
    if font_b then R.ImGui_PushFont(ctx, font_b, 13) end
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.PRIMARY)
    local tw = R.ImGui_CalcTextSize(ctx, "TAKE")
    R.ImGui_SetCursorPosX(ctx, (col_w - tw) * 0.5)
    R.ImGui_Text(ctx, "TAKE")
    R.ImGui_PopStyleColor(ctx, 1)
    if font_b then R.ImGui_PopFont(ctx) end
    R.ImGui_SetCursorPosY(ctx, R.ImGui_GetCursorPosY(ctx) + 2)

    if font_r then R.ImGui_PushFont(ctx, font_r, 13) end
    for _, p in ipairs(_PP_TAKE_PROPS) do
      if _render_toggle(ctx, p.key, p.label, state.checks[p.key]) then
        state.checks[p.key] = not state.checks[p.key]
        _write_check(p.key, state.checks[p.key])
      end
    end
    -- FX toggle (key is i_fx; placed in take column for column balance)
    if _render_toggle(ctx, "i_fx", "FX", state.checks["i_fx"]) then
      state.checks["i_fx"] = not state.checks["i_fx"]
      _write_check("i_fx", state.checks["i_fx"])
    end
    if font_r then R.ImGui_PopFont(ctx) end
  end
  R.ImGui_EndChild(ctx)

  -- RIGHT: Item
  R.ImGui_SameLine(ctx, 0, gap)
  if R.ImGui_BeginChild(ctx, "##item_col", col_w, grid_h, R.ImGui_ChildFlags_None()) then
    if font_b then R.ImGui_PushFont(ctx, font_b, 13) end
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.PRIMARY)
    local iw = R.ImGui_CalcTextSize(ctx, "ITEM")
    R.ImGui_SetCursorPosX(ctx, (col_w - iw) * 0.5)
    R.ImGui_Text(ctx, "ITEM")
    R.ImGui_PopStyleColor(ctx, 1)
    if font_b then R.ImGui_PopFont(ctx) end
    R.ImGui_SetCursorPosY(ctx, R.ImGui_GetCursorPosY(ctx) + 2)

    if font_r then R.ImGui_PushFont(ctx, font_r, 13) end
    for _, p in ipairs(_PP_ITEM_PROPS) do
      if _render_toggle(ctx, p.key, p.label, state.checks[p.key]) then
        state.checks[p.key] = not state.checks[p.key]
        _write_check(p.key, state.checks[p.key])
      end
    end
    if font_r then R.ImGui_PopFont(ctx) end
  end
  R.ImGui_EndChild(ctx)

  R.ImGui_PopStyleVar(ctx, 1)
end

-- ============================================================
-- GUI: Footer (Copy / Paste action buttons)
-- ============================================================

-- Height of the footer action buttons (matches hero-button feel from Vortex Mini).
local _FOOTER_BTN_H = 80

local function render_footer(ctx, state)
  local R       = reaper
  local font_h  = temper_theme and temper_theme.font_hero
  local avail   = select(1, R.ImGui_GetContentRegionAvail(ctx))
  local gap     = 8
  local copy_w  = math.floor((avail - gap) * 0.45)
  local paste_w = avail - copy_w - gap

  if font_h then R.ImGui_PushFont(ctx, font_h, 16) end

  -- COPY button (secondary action)
  local _copy_flash = _is_btn_flashing(state, "copy")
  local _copy_bg = _copy_flash and SC.ACTIVE_DARK or SC.PANEL_TOP
  local _copy_hv = _copy_flash and SC.ACTIVE_DARK or SC.HOVER_LIST
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        _copy_bg)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), _copy_hv)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  SC.ACTIVE_DARK)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          SC.PRIMARY)
  if R.ImGui_Button(ctx, "COPY##cp", copy_w, _FOOTER_BTN_H) then imprint_actions.do_copy(state) end
  R.ImGui_PopStyleColor(ctx, 4)
  if R.ImGui_IsItemHovered(ctx) then
    if state.copy_flash > 0 and reaper.time_precise() < state.copy_flash then
      R.ImGui_SetTooltip(ctx, "Copied!")
    else
      R.ImGui_SetTooltip(ctx, "Copy properties from selected item")
    end
  end

  R.ImGui_SameLine(ctx, 0, gap)

  -- PASTE button (hero action -- teal; muted when no source)
  local has_src = state.has_source
  local paste_bg  = has_src and SC.PRIMARY    or SC.PANEL_TOP
  local paste_hv  = has_src and SC.PRIMARY_HV or SC.HOVER_LIST
  local paste_ac  = has_src and SC.PRIMARY_AC or SC.ACTIVE_DARK
  local paste_txt = has_src and 0x000000FF    or SC.TEXT_MUTED
  if _is_btn_flashing(state, "paste") then
    paste_bg = paste_ac
    paste_hv = paste_ac  -- hover over PASTE while keyboard fires shouldn't mask
  end
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        paste_bg)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), paste_hv)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  paste_ac)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          paste_txt)
  if R.ImGui_Button(ctx, "PASTE##ps", paste_w, _FOOTER_BTN_H) and has_src then imprint_actions.do_paste(state) end
  R.ImGui_PopStyleColor(ctx, 4)
  if R.ImGui_IsItemHovered(ctx) then
    if not has_src then
      R.ImGui_SetTooltip(ctx, "Copy properties first")
    elseif state.paste_flash > 0 and reaper.time_precise() < state.paste_flash then
      R.ImGui_SetTooltip(ctx, "Pasted!")
    else
      R.ImGui_SetTooltip(ctx, "Paste to selected items")
    end
  end

  if font_h then R.ImGui_PopFont(ctx) end
end

-- ============================================================
-- GUI: Settings overlay
-- ============================================================

-- Delete a user preset and nil out any slots pointing to it.
local function _delete_preset(state, name)
  state.presets[name] = nil
  reaper.DeleteExtState(_IMP_NS, "preset_" .. name, true)
  _save_presets(state.presets)
  for si = 1, _MAX_SLOTS do
    if state.quick_slots[si] == name then state.quick_slots[si] = nil end
  end
  _save_quick_slots(state.quick_slots)
end

-- Render a single slot dropdown (custom BeginChild, not native Combo).
local function _render_slot_button(ctx, state, si, slot_w)
  local R       = reaper
  local current = state.quick_slots[si] or "---"
  local is_active = state.slot_open[si]

  local btn_bg  = is_active and SC.PRIMARY     or SC.PANEL
  local btn_hv  = is_active and SC.PRIMARY_HV  or SC.HOVER_LIST
  local btn_ac  = is_active and SC.PRIMARY_AC  or SC.ACTIVE_DARK
  local btn_txt = is_active and SC.WINDOW      or SC.TEXT_ON

  R.ImGui_PushStyleVar(ctx, R.ImGui_StyleVar_ButtonTextAlign(), 0.0, 0.5)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        btn_bg)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), btn_hv)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  btn_ac)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          btn_txt)
  if R.ImGui_Button(ctx, si .. ": " .. current .. "##slot" .. si, slot_w, 0) then
    for j = 1, _MAX_SLOTS do state.slot_open[j] = (j == si) and not state.slot_open[j] or false end
  end
  R.ImGui_PopStyleColor(ctx, 4)
  R.ImGui_PopStyleVar(ctx, 1)
end

local function _render_slot_dropdown(ctx, state, si, dd_w)
  local R          = reaper
  local _DD_ITEM_H = 20

  -- Build options list: --- (nil), built-ins, user presets
  local options = { { name = "---", is_builtin = true } }
  for _, bn in ipairs(_BUILTIN_NAMES) do options[#options + 1] = { name = bn, is_builtin = true } end
  local user_sorted = {}
  for n in pairs(state.presets) do user_sorted[#user_sorted + 1] = n end
  table.sort(user_sorted)
  for _, n in ipairs(user_sorted) do options[#options + 1] = { name = n, is_builtin = false } end

  local slot_col_h = _MAX_SLOTS * 24  -- match left column height
  local dd_h = math.min(#options * _DD_ITEM_H + 4, slot_col_h)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ChildBg(), SC.PANEL)
  local dd_flags = R.ImGui_ChildFlags_Borders()
  if R.ImGui_BeginChild(ctx, "##sldd" .. si, dd_w, dd_h, dd_flags) then
    local deleted = false
    for oi, opt in ipairs(options) do
      -- X delete for user presets
      if not opt.is_builtin then
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        SC.DEL_BTN)
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), SC.DEL_HV)
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  SC.DEL_AC)
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          SC.TEXT_ON)
        if R.ImGui_SmallButton(ctx, "x##sld" .. si .. "_" .. oi) then
          _delete_preset(state, opt.name)
          deleted = true
        end
        R.ImGui_PopStyleColor(ctx, 4)
        if deleted then break end
        R.ImGui_SameLine(ctx, 0, 4)
      end

      -- Selectable item with dark text on hover
      local sx, sy = R.ImGui_GetCursorScreenPos(ctx)
      local is_hov = R.ImGui_IsMouseHoveringRect(ctx, sx, sy, sx + dd_w, sy + _DD_ITEM_H)
      R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), is_hov and SC.WINDOW or SC.TEXT_ON)
      if R.ImGui_Selectable(ctx, opt.name .. "##sls" .. si .. "_" .. oi) then
        state.quick_slots[si] = (opt.name == "---") and nil or opt.name
        _save_quick_slots(state.quick_slots)
        state.slot_open[si] = false
      end
      R.ImGui_PopStyleColor(ctx, 1)
    end
    R.ImGui_EndChild(ctx)
  end
  R.ImGui_PopStyleColor(ctx, 1)
end

local function render_settings_overlay(ctx, state, grid_h)
  if not state.settings_open then return end
  local R      = reaper
  local font_b = temper_theme and temper_theme.font_bold
  local font_r = temper_theme and temper_theme.font_regular

  local win_w = R.ImGui_GetWindowWidth(ctx) - 16
  -- Guard against transient non-positive sizes on monitor resolution change.
  if win_w  < 1 then win_w  = 1 end
  if grid_h < 1 then grid_h = 1 end

  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ChildBg(), SC.PANEL_HIGH)
  local showing = R.ImGui_BeginChild(ctx, "##settings_overlay", win_w, grid_h,
    R.ImGui_ChildFlags_Borders())
  if showing then
    -- "SETTINGS" header: bold teal (matches PRESETS header style)
    if font_b then R.ImGui_PushFont(ctx, font_b, 13) end
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.PRIMARY)
    R.ImGui_Text(ctx, "SETTINGS")
    R.ImGui_PopStyleColor(ctx, 1)
    if font_b then R.ImGui_PopFont(ctx) end

    -- Save row: [input] [SAVE] — styled to match Vortex Mini Seek/Omit inputs
    if font_b then R.ImGui_PushFont(ctx, font_b, 13) end
    R.ImGui_PushStyleVar(ctx, R.ImGui_StyleVar_FramePadding(), 4, 4)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_FrameBg(), SC.WINDOW)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_TextDisabled(), SC.PANEL_TOP)
    R.ImGui_SetNextItemWidth(ctx, win_w * 0.55)
    local _, new_name = R.ImGui_InputTextWithHint(ctx, "##preset_name", "Name...",
      state.preset_name_buf or "")
    R.ImGui_PopStyleColor(ctx, 2)
    R.ImGui_PopStyleVar(ctx, 1)
    if font_b then R.ImGui_PopFont(ctx) end
    state.preset_name_buf = new_name

    R.ImGui_SameLine(ctx, 0, 4)

    -- SAVE button: flash orange "Saved" for 1s after saving
    local is_flashing = state.save_flash > 0 and reaper.time_precise() < state.save_flash
    local save_bg = is_flashing and SC.TERTIARY    or SC.PRIMARY
    local save_hv = is_flashing and SC.TERTIARY_HV or SC.PRIMARY_HV
    local save_ac = is_flashing and SC.TERTIARY_AC or SC.PRIMARY_AC
    local save_label = is_flashing and "Saved" or "SAVE"

    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        save_bg)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), save_hv)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  save_ac)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          SC.WINDOW)
    if R.ImGui_Button(ctx, save_label .. "##sv") then
      local save_name = state.preset_name_buf
      if save_name == "" then
        local n = 1
        while state.presets["Pre" .. n] do n = n + 1 end
        save_name = "Pre" .. n
      end
      save_name = save_name:sub(1, _MAX_NAME_LEN)
      -- Check max count (overwrite existing is always OK)
      if state.presets[save_name] or _count_user_presets(state.presets) < _MAX_PRESETS then
        local preset_data = {}
        for _, k in ipairs(_ALL_KEYS) do
          if state.checks[k] then preset_data[k] = true end
        end
        state.presets[save_name] = preset_data
        _save_presets(state.presets)
        state.preset_name_buf = ""
        state.save_flash = reaper.time_precise() + 1.0
      end
    end
    R.ImGui_PopStyleColor(ctx, 4)
    -- Max presets tooltip
    if R.ImGui_IsItemHovered(ctx) and _count_user_presets(state.presets) >= _MAX_PRESETS then
      R.ImGui_SetTooltip(ctx, "Max " .. _MAX_PRESETS .. " presets")
    end

    R.ImGui_SetCursorPosY(ctx, R.ImGui_GetCursorPosY(ctx) + 6)

    -- Slots header
    if font_b then R.ImGui_PushFont(ctx, font_b, 13) end
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.TEXT_MUTED)
    R.ImGui_Text(ctx, "Slots")
    R.ImGui_PopStyleColor(ctx, 1)
    if font_b then R.ImGui_PopFont(ctx) end

    -- 6 slot buttons (left column), then dropdown overlay (right column)
    local slot_w = math.floor((win_w - 8) * 0.5)
    local dd_w   = win_w - 8 - slot_w - 4
    local slot1_y = nil
    for si = 1, _MAX_SLOTS do
      if si == 1 then
        local _, sy = R.ImGui_GetCursorScreenPos(ctx)
        slot1_y = sy
      end
      _render_slot_button(ctx, state, si, slot_w)
    end
    -- Dropdown rendered after all buttons, always at slot 1 Y
    if slot1_y then
      for si = 1, _MAX_SLOTS do
        if state.slot_open[si] then
          local sx = R.ImGui_GetCursorScreenPos(ctx)
          R.ImGui_SetCursorScreenPos(ctx, sx + slot_w + 4, slot1_y)
          _render_slot_dropdown(ctx, state, si, dd_w)
          break
        end
      end
    end

    R.ImGui_EndChild(ctx)
  end
  R.ImGui_PopStyleColor(ctx, 1)
end

-- ============================================================
-- GUI: Main render
-- ============================================================

local function render_gui(ctx, state, lic, lic_status)
  local R = reaper

  -- Row 1: Title bar background via DrawList (matches Vortex Mini dimensions)
  local win_x, win_y = R.ImGui_GetWindowPos(ctx)
  local dl = R.ImGui_GetWindowDrawList(ctx)
  local win_w = select(1, R.ImGui_GetWindowSize(ctx))
  local tbx, tby = R.ImGui_GetCursorScreenPos(ctx)
  R.ImGui_DrawList_AddRectFilled(dl, win_x, win_y, win_x + win_w, tby + 24, SC.TITLE_BAR)
  render_title_bar(ctx, state, lic, lic_status)
  R.ImGui_SetCursorPosY(ctx, R.ImGui_GetCursorPosY(ctx) + 4)

  -- Row 2: Quick Presets (hidden when settings overlay is open)
  if not state.settings_open then
    render_quick_presets(ctx, state)
    R.ImGui_SetCursorPosY(ctx, R.ImGui_GetCursorPosY(ctx) + 4)
  end

  local window_h = select(2, R.ImGui_GetWindowSize(ctx))
  local cur_y    = R.ImGui_GetCursorPosY(ctx)

  -- Row 3: Checkbox grid OR Settings overlay
  if state.settings_open then
    -- Settings fills all remaining space (no footer)
    render_settings_overlay(ctx, state, window_h - cur_y - 8)
  else
    -- Grid gets everything above the footer zone
    -- Footer zone = 8px gap + button height + 8px bottom pad = 96px from bottom
    local grid_h = window_h - cur_y - _FOOTER_BTN_H - 10
    render_checkbox_grid(ctx, state, grid_h)

    -- Pin footer to bottom (tight against grid)
    R.ImGui_SetCursorPosY(ctx, window_h - _FOOTER_BTN_H - 8)
    render_footer(ctx, state)
  end
end

-- ============================================================
-- Instance guard
-- ============================================================

do
  local _inst_ts = reaper.GetExtState(_IMP_NS, "instance_ts")
  if _inst_ts ~= "" and tonumber(_inst_ts) and (reaper.time_precise() - tonumber(_inst_ts)) < 1.0 then
    reaper.ShowMessageBox(
      "Temper Imprint is already running.\nClose the existing window before opening a new instance.",
      "Temper Imprint", 0)
    return
  end
end
reaper.SetExtState(_IMP_NS, "instance_ts", tostring(reaper.time_precise()), false)

-- ============================================================
-- Entry point
-- ============================================================

do
  -- Guard ReaImGui's short-lived-resource rate limit (see Temper_Vortex.lua).
  local _ctx_ok, ctx = pcall(reaper.ImGui_CreateContext, "Temper Imprint##imprint")
  if not _ctx_ok or not ctx then
    reaper.ShowMessageBox(
      "Temper Imprint could not start because ReaImGui is still cleaning " ..
      "up from a previous instance.\n\n" ..
      "Close any existing Imprint window, wait ~15 seconds, then try again.\n" ..
      "If it keeps happening, restart REAPER.",
      "Temper Imprint", 0)
    return
  end
  if type(temper_theme) == "table" then temper_theme.attach_fonts(ctx) end

  local _lic_ok, lic = pcall(dofile, _lib .. "temper_license.lua")
  if not _lic_ok then lic = nil end
  if lic then lic.configure({
    namespace    = "TEMPER_Imprint",
    scope_id     = 0x3,
    display_name = "Imprint",
    buy_url      = "https://www.tempertools.com/scripts/imprint",
  }) end

  local restored_snap = _restore_snapshot()
  local _loaded_presets = _load_presets()
  local _loaded_slots   = _load_quick_slots()
  _clean_orphaned_slots(_loaded_slots, _loaded_presets)
  local state = {
    checks          = _init_checks(),
    has_source      = restored_snap ~= nil,
    source_count    = restored_snap and restored_snap.count or 0,
    snapshot        = restored_snap,
    copy_flash      = 0,
    paste_flash     = 0,
    presets         = _loaded_presets,
    quick_slots     = _loaded_slots,
    settings_open   = false,
    preset_name_buf = "",
    should_close    = false,
    save_flash      = 0,
    slot_open       = { false, false, false, false, false, false },
    _btn_flash      = {},  -- button_key -> expires_at. Wrapped HANDLERS set this
                            -- so keyboard-dispatched actions get a brief "pressed"
                            -- render, mimicking the natural ImGui mouse-click feedback
                            -- that keyboard paths skip. Mouse clicks go straight to
                            -- imprint_actions and rely on ImGui's built-in active state.
    _harness_hold_flash = {}, -- harness-only: test_runner toggles to hold flash indefinitely
  }

  -- ── Action dispatch (rsg_actions framework) ───────────────────
  -- Every key MUST correspond to a command in scripts/lua/actions/manifest.toml.
  -- Entries are thin pointers: they call through imprint_actions, which mirrors
  -- the GUI button callbacks 1:1 (subset-of-GUI invariant). Each handler also
  -- sets a short-lived entry in state._btn_flash so render_* functions can swap
  -- the corresponding button to its pressed shade for ~120ms, visually mimicking
  -- the ImGui active-state feedback that mouse clicks get natively. Mouse clicks
  -- invoke imprint_actions directly and rely on the built-in feedback.
  -- NOTE: test_manifest_sync's regex requires each value to start with `function`,
  -- so flash-setting is inlined per entry rather than wrapped in a helper closure.
  -- `close` is a framework built-in dispatched by rsg_actions.toggle_window.
  local _BTN_FLASH_DUR = 0.25
  local function _set_flash(k) state._btn_flash[k] = reaper.time_precise() + _BTN_FLASH_DUR end
  local HANDLERS = {
    copy           = function() _set_flash("copy");           imprint_actions.do_copy(state)       end,
    paste          = function() _set_flash("paste");          imprint_actions.do_paste(state)      end,
    apply_preset_1 = function() _set_flash("apply_preset_1"); imprint_actions.apply_preset_1(state) end,
    apply_preset_2 = function() _set_flash("apply_preset_2"); imprint_actions.apply_preset_2(state) end,
    apply_preset_3 = function() _set_flash("apply_preset_3"); imprint_actions.apply_preset_3(state) end,
    apply_preset_4 = function() _set_flash("apply_preset_4"); imprint_actions.apply_preset_4(state) end,
    apply_preset_5 = function() _set_flash("apply_preset_5"); imprint_actions.apply_preset_5(state) end,
    apply_preset_6 = function() _set_flash("apply_preset_6"); imprint_actions.apply_preset_6(state) end,
    close          = function() state.should_close = true end,
  }
  -- Harness-only hold_flash/unhold_flash commands: mirror every real
  -- flash-emitting command with a test-mode twin that keeps the flash
  -- rendered indefinitely (for screenshot capture). Gated on
  -- _TEMPER_HARNESS so production users never see them in the manifest
  -- or action list; generated inline so each handler satisfies the
  -- `function` prefix that test_manifest_sync's regex enforces.
  if _TEMPER_HARNESS then
    HANDLERS._harness_hold_copy           = function() state._harness_hold_flash["copy"]           = true end
    HANDLERS._harness_hold_paste          = function() state._harness_hold_flash["paste"]          = true end
    HANDLERS._harness_hold_apply_preset_1 = function() state._harness_hold_flash["apply_preset_1"] = true end
    HANDLERS._harness_hold_apply_preset_2 = function() state._harness_hold_flash["apply_preset_2"] = true end
    HANDLERS._harness_hold_apply_preset_3 = function() state._harness_hold_flash["apply_preset_3"] = true end
    HANDLERS._harness_hold_apply_preset_4 = function() state._harness_hold_flash["apply_preset_4"] = true end
    HANDLERS._harness_hold_apply_preset_5 = function() state._harness_hold_flash["apply_preset_5"] = true end
    HANDLERS._harness_hold_apply_preset_6 = function() state._harness_hold_flash["apply_preset_6"] = true end
    HANDLERS._harness_unhold_all          = function() state._harness_hold_flash = {} end

    -- State projection for LD-2026-04-027 scenario. Scans the project for
    -- items tagged via P_EXT:imprint_test_tag and reports the number of
    -- <VST ...> blocks in each item's state chunk. Primary bug: after
    -- COPY-then-PASTE with source included in the selection, the source
    -- must still have 1 VST (not 0) and the target with pre-existing FX
    -- must have 2 VST (original + appended).
    local _tts_ok, _tts = pcall(dofile, _lib .. "temper_test_state.lua")
    if _tts_ok and type(_tts) == "table" and _tts.register and _tts.dump_to_file then
      _tts.register(_IMP_NS, function()
        -- Legacy LD-027 predicates (source/target) plus per-track multi-slot
        -- predicates (t1_source/t1_target/t2_source/t2_target/...). Any item
        -- carrying P_EXT:imprint_test_tag is counted; the tag string is used
        -- verbatim as the field-name suffix, so "t1_source" becomes the key
        -- "t1_source_vst_count". Unknown tags are ignored.
        local counts = {}
        local n_tracks = reaper.CountTracks(0)
        for t = 0, n_tracks - 1 do
          local tr = reaper.GetTrack(0, t)
          local n_items = reaper.CountTrackMediaItems(tr)
          for i = 0, n_items - 1 do
            local it = reaper.GetTrackMediaItem(tr, i)
            local _, tag = reaper.GetSetMediaItemInfo_String(it, "P_EXT:imprint_test_tag", "", false)
            if tag and tag ~= "" then
              local _, chunk = reaper.GetItemStateChunk(it, "", false)
              local _, n = chunk:gsub("<VST ", "<VST ")
              counts[tag] = (counts[tag] or 0) + n
            end
          end
        end
        local out = {
          has_snapshot       = state.snapshot ~= nil,
          snapshot_mode      = state.snapshot and state.snapshot.mode or nil,
          source_guid_stored = state.snapshot and state.snapshot.source_item_guid or nil,
          source_vst_count   = counts["source"] ~= nil and counts["source"] or -1,
          target_vst_count   = counts["target"] ~= nil and counts["target"] or -1,
        }
        -- Expose every observed tag as <tag>_vst_count, so scenarios can
        -- author predicates like path="t1_vst_count".
        for tag, n in pairs(counts) do
          out[tag .. "_vst_count"] = n
        end
        if state.snapshot and state.snapshot.tracks then
          local tk = 0
          for _ in pairs(state.snapshot.tracks) do tk = tk + 1 end
          out.snapshot_track_count = tk
        else
          out.snapshot_track_count = 0
        end
        return out
      end)
      HANDLERS._harness_dump = function() _tts.dump_to_file() end
    end
  end
  rsg_actions.clear_pending_on_init(_IMP_NS)

  local _first_loop = true
  local function loop()
    reaper.SetExtState(_IMP_NS, "instance_ts", tostring(reaper.time_precise()), false)
    rsg_actions.heartbeat(_IMP_NS)
    local _focus_requested = rsg_actions.poll(_IMP_NS, HANDLERS)

    if not _first_loop then
      local win_h = state.settings_open and _SETTINGS_WIN_H or 530
      reaper.ImGui_SetNextWindowSize(ctx, 300, win_h, reaper.ImGui_Cond_Always())
    end
    _first_loop = false

    if _focus_requested then
      reaper.ImGui_SetNextWindowFocus(ctx)
      if reaper.APIExists and reaper.APIExists("JS_Window_SetForeground") then
        local hwnd = reaper.JS_Window_Find and reaper.JS_Window_Find("Temper Imprint", true)
        if hwnd then reaper.JS_Window_SetForeground(hwnd) end
      end
    end

    local n_theme = temper_theme and temper_theme.push(ctx) or 0
    -- Override WindowBg to PANEL (lighter than theme's WINDOW) so the dense toggle
    -- grid has visible contrast against its PANEL_TOP/PANEL background shifts.
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), SC.PANEL)

    local win_flags = reaper.ImGui_WindowFlags_NoCollapse()
                    | reaper.ImGui_WindowFlags_NoTitleBar()
                    | reaper.ImGui_WindowFlags_NoResize()
                    | reaper.ImGui_WindowFlags_NoScrollbar()
                    | reaper.ImGui_WindowFlags_NoScrollWithMouse()

    local visible, open = reaper.ImGui_Begin(ctx, "Temper Imprint##imprint", true, win_flags)

    if visible then
      local lic_status = lic and lic.check("IMPRINT", ctx)
      render_gui(ctx, state, lic, lic_status)
      if lic and lic.is_dialog_open() then lic.draw_dialog(ctx) end
      reaper.ImGui_End(ctx)
    end

    if temper_theme then temper_theme.pop(ctx, n_theme) end
    reaper.ImGui_PopStyleColor(ctx, 1)

    if open and not state.should_close then
      reaper.defer(loop)
    else
      reaper.SetExtState(_IMP_NS, "instance_ts", "", false)
    end
  end

  reaper.defer(loop)
end
