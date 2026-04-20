-- @description Temper Nexus
-- @version 1.7.0
-- v1.7.0: rsg_actions framework integration. 13 keyboard/macro-dispatchable
--         commands (cycle_mode, copy, paste, toggle_pin, toggle_active_filter,
--         5 filter chip toggles, 3 per-row property toggles for mute/phase/mono)
--         plus toggle_window and close framework built-ins. Extracted toolbar
--         button bodies into a nexus_actions module table dispatched by both
--         render_toolbar (mouse) and HANDLERS (keyboard). Adds _btn_flash
--         feedback on keyboard paths. Subset-of-GUI invariant holds -- every
--         handler calls the same core that the GUI button calls.
-- v1.6.7: slider drag now promotes the dragged row to sole Nexus selection
--         on activation. Previously, dragging a slider on a non-selected row
--         left the prior selection intact for one drag, so the live-broadcast
--         display visually pulled the previously-selected row's slider in
--         lockstep even though only the dragged track's value was committed.
--         Adds promote_drag_focus() helper, called after every nexus_slider
--         site (parent VOL/PAN, send VOL/PAN).
-- v1.6.6: fix infinite recursion in invalidate_routing helper introduced
--         during the visible-row memoization pass (replace_all caught its
--         own definition). Also clears one missed cache-clear site in
--         delete_selected_rows so the memo invalidates correctly after
--         bulk deletes.
-- v1.6.5: Mode cycle button gets per-mode color identity -- PARENT (inactive
--         pill), SENDS (filled teal), RECEIVES (filled coral), HW OUTS
--         (black w/ white text). Matches the Post / Pre-FX / Post-FX palette pattern.
-- v1.6.4: HW OUTS parity — picker enumerates hardware output channels via
--         GetOutputChannelName; peer-name pill shows "Output N"; MONO button
--         and dst_chan dropdown omitted in hw_outs mode; MONO filter chip
--         hidden in hw_outs.
-- @author Temper Tools
-- @provides
--   [main] .
--   [nomain] lib/temper_actions.lua
--   lib/temper_nexus_routing.lua
--   lib/temper_nexus_clipboard.lua
--   lib/temper_routing_math.lua
--   lib/temper_theme.lua
--   lib/temper_license.lua
--   lib/temper_platform.lua
-- @about Centralized routing control surface for REAPER

local R = reaper

-- ── Dependency checks ──────────────────────────────────────────────
if not R.ImGui_CreateContext then
  R.ShowMessageBox(
    "Temper Nexus requires ReaImGui.\n\nInstall via ReaPack:\n  Extensions > ReaPack > Browse packages > ReaImGui",
    "Missing Dependency", 0)
  return
end

-- ── Configuration ──────────────────────────────────────────────────
local CONFIG = {
  win_w = 700, win_h = 500, min_win_w = 624, min_win_h = 350,
  title_h = 28, toolbar_h = 30, footer_h = 20, row_h = 24,
  btn_sz = 26, btn_w = 61, dot_r = 3,
  -- Track-name input column widths -- narrower in collapsed headers where a
  -- CH count shares the row, wider in parent mode where the name is the
  -- only label on the row.
  header_name_w = 180, parent_name_w = 210,
  -- Row state tint colors (live outside SC because they're Nexus-local).
  row_sel_bg = 0x1E3A3AFF,  -- dark teal tint, Vortex-style row selection
  row_pin_bg = 0x4A1F0FFF,  -- dark coral tint for pinned rows
  instance_guard_timeout_sec = 2.0, instance_guard_heartbeat_sec = 1.0,
  debounce_sec = 0.15, flash_sec = 1.2,
}

-- ── Libraries ──────────────────────────────────────────────────────
-- Resolve lib/ as a sibling of this script (works for both dev layout and
-- per-package ReaPack layout — see Temper_Vortex.lua for context).
local _script_path = debug.getinfo(1, "S").source:sub(2)
local _lib         = (_script_path:match("^(.*)[\\/]") or ".") .. "/lib/"
local routing     = dofile(_lib .. "temper_nexus_routing.lua")
local clip_mod    = dofile(_lib .. "temper_nexus_clipboard.lua")
local platform    = dofile(_lib .. "temper_platform.lua")
local rsg_actions = dofile(_lib .. "temper_actions.lua")

pcall(dofile, _lib .. "temper_theme.lua")
local SC = (type(temper_theme) == "table") and temper_theme.SC or {}

local _lic_ok, lic = pcall(dofile, _lib .. "temper_license.lua")
if not _lic_ok then lic = nil end

-- Fallback colors when theme unavailable
if not SC.PRIMARY then
  SC = {
    WINDOW = 0x0E0E10FF, PANEL = 0x1E1E20FF, PANEL_HIGH = 0x282828FF,
    PANEL_TOP = 0x323232FF, HOVER_LIST = 0x39393BFF,
    PRIMARY = 0x26A69AFF, PRIMARY_LT = 0x66D9CCFF,
    PRIMARY_HV = 0x30B8ACFF, PRIMARY_AC = 0x1A8A7EFF,
    TERTIARY = 0xDA7C5AFF, TERTIARY_HV = 0xE08A6AFF, TERTIARY_AC = 0xC46A4AFF,
    TEXT_ON = 0xDEDEDEFF, TEXT_MUTED = 0xBCC9C6FF, TEXT_OFF = 0x505050FF,
    ERROR_RED = 0xC0392BFF, TITLE_BAR = 0x1A1A1CFF,
    SEL_BG = 0x1E3A3AFF,
    HOVER_INACTIVE = 0x2A2A2CFF, ACTIVE_DARK = 0x141416FF,
    ACTIVE_DARKER = 0x161618FF, ICON_DISABLED = 0x606060FF,
    HOVER_GHOST = 0xFFFFFF1A, ACTIVE_GHOST = 0x0000001F,
    BORDER_INPUT = 0x505055FF, BORDER_SUBTLE = 0x50505066,
  }
end

-- Button style helpers (push 5 colors, pop with PopStyleColor(ctx, 5))
-- Visually center labels in combo preview by left-padding to target width
local function center_label(s)
  local n = #s
  if n >= 5 then return s end
  local pad = math.floor((5 - n) / 2)
  return string.rep(" ", pad) .. s
end

-- Combo pill: lighter bg + teal text/arrow, matching Alloy's inactive pill style
local function push_combo_pill(ctx)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_FrameBg(), SC.PANEL_TOP)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_FrameBgHovered(), SC.HOVER_LIST)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_FrameBgActive(), SC.PANEL_TOP)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_PopupBg(), SC.PANEL)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.PRIMARY)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(), SC.PANEL_TOP)
end

-- Pill styles matching Alloy: inactive = dark bg / teal text, active = teal bg / dark text
local function push_pill(ctx)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(), SC.PANEL_TOP)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), SC.HOVER_LIST)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(), SC.ACTIVE_DARK)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.PRIMARY)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(), 0)
end
local function push_pill_hot(ctx)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(), SC.TERTIARY)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), SC.TERTIARY_HV)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(), SC.TERTIARY_AC)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.WINDOW)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(), 0)
end
local function push_btn(ctx, bg, hv, ac, text)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(), bg)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), hv)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(), ac)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), text)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(), 0)
end

local _NS = "TEMPER_Nexus"

-- ── Mode definitions ──────────────────────────────────────────────
local MODE_LABELS = { sends = "SENDS", receives = "RECEIVES", hw_outs = "HW OUTS", parent = "PARENT" }
local MODE_NEXT   = { sends = "receives", receives = "hw_outs", hw_outs = "parent", parent = "sends" }

-- ── State seed ────────────────────────────────────────────────────
-- Single source of truth for Nexus's runtime state shape. Every field used
-- anywhere in the script is declared here, including the ones touched lazily
-- by slider / picker / row-selection / channel-popup code. Adding a new
-- field elsewhere without declaring it here is a bug.
local function init_state(clipper)
  return {
    -- ── Status / mode ─────────────────────────────────────────────
    status             = "init",
    mode               = "sends",
    should_close       = false,
    settings_open      = false,

    -- ── Track / selection model ───────────────────────────────────
    track_count        = 0,
    _visible_tracks    = {},  -- current-frame snapshot of visible tracks
    nexus_selected     = {},  -- {[guid]=true} track-level selection (header + batch edits)
    _btn_flash         = {},  -- button_key -> expires_at. Keyboard-dispatched
                              -- HANDLERS set a short-lived entry so render_toolbar
                              -- can swap to the pressed shade for ~250ms, mimicking
                              -- the native ImGui active feedback that mouse clicks
                              -- get for free.
    _sel_anchor        = nil, -- last-clicked track guid (range-select anchor)
    pinned             = false,
    pinned_tracks      = {},  -- frozen snapshot (not auto-merged with REAPER selection)
    collapsed          = {},  -- {[guid]=true} collapsed track headers (non-parent modes)
    _auto_collapsed    = false,

    -- ── Routing cache ─────────────────────────────────────────────
    cached_routing     = {},  -- {[guid]={sends,receives,hw_outs,parent}}
    last_state_count   = -1,  -- tick_state invalidation cursor

    -- ── Row selection ─────────────────────────────────────────────
    row_selected       = {},  -- {[guid|cat|idx]=true} per-row visual selection
    _row_sel_anchor    = nil, -- last-clicked row key (range-select anchor)
    _visible_rows      = nil, -- memoized flat clipper row list
    _row_lookup        = nil, -- {[row_key]={track_entry, descriptor}}

    -- ── Filter state ──────────────────────────────────────────────
    filter_text        = "",
    filter_committed   = "",
    filter_pending_ts  = 0,
    filter_active_only = false,
    filter_state       = {    -- chip filters (AND); persisted via ExtState
      mute   = false,
      mono   = false,
      phase  = false,
      pre    = false,         -- I_SENDMODE == 1
      postfx = false,         -- I_SENDMODE == 3
    },

    -- ── Clipboard ─────────────────────────────────────────────────
    clipboard          = nil, -- track-level routing clipboard (clip_mod)
    send_clipboard     = nil, -- single-row routing snapshot (right-click menu)
    highlight_dest     = nil, -- currently-highlighted dest_guid (pill + row group)

    -- ── Inline-rename buffer ──────────────────────────────────────
    _name_buf          = {},  -- {[guid]=pending_name_text} while rename active

    -- ── Slider machinery (nexus_slider) ───────────────────────────
    _slider_editing       = nil, -- currently inline-editing slider id
    _slider_edit_pending  = nil, -- promoted to _slider_editing one frame later
    _slider_edit_focus    = nil, -- first-frame focus flag
    _slider_edit_val      = nil, -- edit buffer
    _slider_dragging      = nil, -- currently-dragged slider id
    _slider_pending       = nil, -- deferred drag value (emitted on mouse-up)
    _dblclick_id          = nil, -- last double-click target id
    _dblclick_time        = 0,   -- last double-click timestamp
    _drag_live            = {},  -- {[broadcast_key]=live_value} cross-row drag broadcast

    -- ── Channel popup (header) ────────────────────────────────────
    _ch_edit_for       = nil, -- track entry being edited
    _ch_edit_val       = nil, -- edit buffer
    _ch_popup_opened   = false,

    -- ── Track picker ──────────────────────────────────────────────
    add_send_for       = nil, -- source track entry the picker is targeting
    _picker_opened     = false,
    _picker_filter     = nil, -- picker's own filter input

    -- ── Transient feedback ────────────────────────────────────────
    flash_msg          = nil,
    flash_until        = 0,

    -- ── Memoization ───────────────────────────────────────────────
    _routing_gen       = 0,   -- bumps on every invalidate_routing()
    _collapsed_gen     = 0,   -- bumps on every collapsed[guid] mutation
    _memo_key          = nil, -- last-built flat-list key
    _memo_flat         = nil, -- last-built flat row list
    _memo_visible_rows = nil, -- last-built row_sel_key list
    _memo_row_lookup   = nil, -- last-built row_sel_key -> {track, desc}

    -- ── Infra ─────────────────────────────────────────────────────
    _clipper           = clipper,
    _last_heartbeat    = 0,   -- throttle guard for instance-guard ExtState write
  }
end

-- ── Helper functions ──────────────────────────────────────────────

local function flash(state, msg)
  state.flash_msg   = msg
  state.flash_until = R.time_precise() + CONFIG.flash_sec
end

local function load_settings(state)
  local mode = R.GetExtState(_NS, "mode")
  if mode ~= "" and MODE_LABELS[mode] then state.mode = mode end
  local filt = R.GetExtState(_NS, "filter_active_only")
  if filt == "true" then state.filter_active_only = true end
  if state.filter_state then
    for _, k in ipairs({ "mute", "mono", "phase", "pre", "postfx" }) do
      if R.GetExtState(_NS, "filter_chip_" .. k) == "true" then
        state.filter_state[k] = true
      end
    end
  end
end

local function save_settings(state)
  R.SetExtState(_NS, "mode", state.mode, true)
  R.SetExtState(_NS, "filter_active_only", state.filter_active_only and "true" or "false", true)
  if state.filter_state then
    for _, k in ipairs({ "mute", "mono", "phase", "pre", "postfx" }) do
      R.SetExtState(_NS, "filter_chip_" .. k, state.filter_state[k] and "true" or "false", true)
    end
  end
end

local function make_track_entry(tr)
  local _, name = R.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
  return {
    ptr   = tr,
    guid  = R.GetTrackGUID(tr),
    name  = name or "",
    nchan = math.floor(R.GetMediaTrackInfo_Value(tr, "I_NCHAN")),
    index = math.floor(R.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER")),
  }
end

local function get_selected_tracks(state)
  -- Always start from REAPER's current track selection (this is the live driver)
  local n = R.CountSelectedTracks(0)
  local out = {}
  local seen = {}
  for i = 0, n - 1 do
    local tr = R.GetSelectedTrack(0, i)
    local entry = make_track_entry(tr)
    out[#out + 1] = entry
    seen[entry.guid] = true
  end

  -- Overlay pinned tracks: any pinned track not already in REAPER selection is appended.
  -- pinned_tracks itself is NOT rewritten here (avoids the old "all tracks pinned" bug
  -- where the merged set was being written back into the pinned set).
  if state.pinned and state.pinned_tracks then
    local still_valid = {}
    for _, entry in ipairs(state.pinned_tracks) do
      if R.ValidatePtr(entry.ptr, "MediaTrack*") then
        still_valid[#still_valid + 1] = entry
        if not seen[entry.guid] then
          out[#out + 1] = make_track_entry(entry.ptr)
          seen[entry.guid] = true
        end
      end
    end
    -- Drop invalidated pinned tracks (deleted from the project) but keep the rest pinned.
    if #still_valid ~= #state.pinned_tracks then
      state.pinned_tracks = still_valid
      if #still_valid == 0 then state.pinned = false end
    end
  end

  return out
end

-- Single point of routing-cache invalidation. Bumps _routing_gen so the
-- flat-list memo in render_content knows to rebuild. Every callsite that
-- previously did `invalidate_routing(state)` should use this.
local function invalidate_routing(state)
  state.cached_routing = {}
  state._routing_gen = (state._routing_gen or 0) + 1
end

local function check_cache(state)
  local sc = R.GetProjectStateChangeCount(0)
  if sc ~= state.last_state_count then
    invalidate_routing(state)
    state.last_state_count = sc
  end
end

local function get_cached_routing(state, track_entry)
  local guid = track_entry.guid
  if state.cached_routing[guid] then return state.cached_routing[guid] end

  local tr = track_entry.ptr
  local data = {
    sends    = routing.get_sends(tr),
    receives = routing.get_receives(tr),
    hw_outs  = routing.get_hw_outs(tr),
    parent   = routing.get_parent(tr),
  }
  state.cached_routing[guid] = data
  return data
end

-- ── tick_state ────────────────────────────────────────────────────

local function tick_state(state)
  if state.status == "init" then
    state.status = "ready"
  end

  -- Filter debounce
  if state.filter_pending_ts > 0 then
    if R.time_precise() - state.filter_pending_ts >= CONFIG.debounce_sec then
      state.filter_committed = state.filter_text
      state.filter_pending_ts = 0
    end
  end
end

-- ── Constants ────────────────────────────────────────────────────

local _LOG10 = math.log(10)

-- Row state colors -- aliased from CONFIG so existing call sites stay short.
local ROW_SEL_BG = CONFIG.row_sel_bg
local ROW_PIN_BG = CONFIG.row_pin_bg

-- Send mode color cycle (Post / Pre-FX / Post-FX) -- mirrors Vortex FREE/UNIQ/LOCK.
-- Each entry: { Col_Button, Col_ButtonHovered, Col_ButtonActive, Col_Text }.
-- The keys match routing.MODE_LABELS ints so dispatch is a direct lookup.
local SEND_MODE_COL  -- forward decl; populated after SC is resolved inside init
local function _build_send_mode_col()
  SEND_MODE_COL = {
    [0] = { SC.PANEL_TOP, SC.HOVER_LIST,  SC.ACTIVE_DARK, SC.PRIMARY }, -- Post    = inactive pill
    [1] = { SC.PRIMARY,   SC.PRIMARY_HV,  SC.PRIMARY_AC,  SC.WINDOW  }, -- Pre-FX  = filled teal
    [3] = { SC.TERTIARY,  SC.TERTIARY_HV, SC.TERTIARY_AC, SC.WINDOW  }, -- Post-FX = filled coral
  }
end
_build_send_mode_col()

-- Mode cycle button palette (PARENT / SENDS / RECEIVES / HW OUTS). Extends the
-- send-mode cycle palette with a 4th "gold" variant for hw_outs so the button
-- reads differently across all four routing views. Gold hover/active are
-- inlined here rather than added to temper_theme.SC -- only this button uses them.
-- Each entry: { Col_Button, Col_ButtonHovered, Col_ButtonActive, Col_Text }.
local MODE_CYCLE_COL  -- forward decl; populated after SC is resolved
local function _build_mode_cycle_col()
  MODE_CYCLE_COL = {
    parent   = { SC.PANEL_TOP, SC.HOVER_LIST,  SC.ACTIVE_DARK, SC.PRIMARY }, -- inactive pill (default state)
    sends    = { SC.PRIMARY,   SC.PRIMARY_HV,  SC.PRIMARY_AC,  SC.WINDOW  }, -- filled teal
    receives = { SC.TERTIARY,  SC.TERTIARY_HV, SC.TERTIARY_AC, SC.WINDOW  }, -- filled coral
    hw_outs  = { 0x000000FF,   0x1A1A1CFF,     0x000000FF,     0xFFFFFFFF }, -- filled black, white text
  }
end
_build_mode_cycle_col()

-- ── Slider Widget ────────────────────────────────────────────────
-- Bold label, orange grab when modified, double-click reset, right-click inline text input.
-- Undo: deferred — slider only reports the final value on mouse-release, not per-frame.

-- Call right after nexus_slider returns. If the user just started dragging
-- (this slider id matches state._slider_dragging) on a row whose track is
-- not currently Nexus-selected, promote that track to sole selection. This
-- keeps the live drag broadcast (_drag_live) from visually pulling rows
-- that the user implicitly deselected by clicking outside the set, and
-- aligns slider activation with the existing get_nexus_selected promote-
-- on-click semantics.
local function promote_drag_focus(state, track_entry, slider_id)
  if state._slider_dragging == slider_id
     and not state.nexus_selected[track_entry.guid] then
    state.nexus_selected = { [track_entry.guid] = true }
    state._sel_anchor = track_entry.guid
  end
end

local function nexus_slider(ctx, label, id, value, lo, hi, default, fmt, width, state, format_fn, broadcast_key)
  -- (label intentionally unused -- VOL/PAN labels removed; the slider readout is self-explanatory)
  local changed = false
  local new_val = value

  -- Promote pending edit (delayed by one frame to avoid right-click glitch)
  if state._slider_edit_pending == id then
    state._slider_editing = id
    state._slider_edit_pending = nil
    state._slider_edit_focus = true
  end

  -- ── Right-click inline text input mode ──
  if state._slider_editing == id then
    local first_frame = state._slider_edit_focus
    if first_frame then
      R.ImGui_SetKeyboardFocusHere(ctx, 0)
      state._slider_edit_focus = nil
    end
    R.ImGui_SetNextItemWidth(ctx, width)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_FrameBg(), SC.PANEL)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(), SC.PRIMARY)
    local enter, txt = R.ImGui_InputText(ctx, id .. "_ed",
      state._slider_edit_val or "",
      R.ImGui_InputTextFlags_EnterReturnsTrue() | R.ImGui_InputTextFlags_AutoSelectAll())
    R.ImGui_PopStyleColor(ctx, 2)
    state._slider_edit_val = txt
    if enter then
      local num = tonumber(txt)
      if num then
        new_val = math.max(lo, math.min(hi, num))
        changed = true
      end
      state._slider_editing = nil
    elseif R.ImGui_IsKeyPressed(ctx, R.ImGui_Key_Escape()) then
      state._slider_editing = nil
    elseif not first_frame and not R.ImGui_IsItemActive(ctx) and not R.ImGui_IsItemFocused(ctx) then
      -- Only check lost-focus after the first frame (focus takes one frame to apply)
      state._slider_editing = nil
    end
    return changed, new_val
  end

  -- ── Slider mode ──
  local is_modified = math.abs(value - default) > 0.01
  if is_modified then
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_SliderGrab(), SC.TERTIARY)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_SliderGrabActive(), SC.TERTIARY_HV)
  end

  -- If currently dragging this slider, show the pending value
  local display_val = value
  if state._slider_dragging == id and state._slider_pending then
    display_val = state._slider_pending
  end

  local effective_fmt = fmt
  if format_fn then
    effective_fmt = format_fn(display_val)
  end

  R.ImGui_SetNextItemWidth(ctx, width)
  local _, slider_val = R.ImGui_SliderDouble(ctx, id, display_val, lo, hi, effective_fmt)

  -- Track drag state: only emit changed on release
  if R.ImGui_IsItemActivated(ctx) then
    state._slider_dragging = id
    state._slider_pending = nil
  end
  if R.ImGui_IsItemActive(ctx) and slider_val ~= display_val then
    state._slider_pending = slider_val
    -- Broadcast live value so other Nexus-selected rows mirror in real time
    if broadcast_key then
      state._drag_live = state._drag_live or {}
      state._drag_live[broadcast_key] = slider_val
    end
  end
  if R.ImGui_IsItemDeactivated(ctx) then
    if state._slider_dragging == id and state._slider_pending then
      new_val = state._slider_pending
      changed = true
    end
    state._slider_dragging = nil
    state._slider_pending = nil
    -- Clear broadcast now that drag has released
    if broadcast_key and state._drag_live then
      state._drag_live[broadcast_key] = nil
    end
  end

  -- Double-click reset: track click timestamps (slider eats ImGui double-click)
  if R.ImGui_IsItemActivated(ctx) then
    local now = R.time_precise()
    if state._dblclick_id == id and now - (state._dblclick_time or 0) < 0.3 then
      -- Second click within threshold → reset
      state._slider_dragging = nil
      state._slider_pending = nil
      state._dblclick_id = nil
      new_val = default
      changed = true
    else
      state._dblclick_id = id
      state._dblclick_time = now
    end
  end

  -- Right-click → queue inline text input for next frame (avoids same-frame glitch)
  if R.ImGui_IsItemClicked(ctx, 1) then
    state._slider_edit_pending = id
    state._slider_edit_val = string.format("%.2f", value)
    state._slider_dragging = nil
    state._slider_pending = nil
  end

  if is_modified then R.ImGui_PopStyleColor(ctx, 2) end
  return changed, new_val
end

-- ── Render: Title Bar ─────────────────────────────────────────────

local function render_title_bar(ctx, state)
  local dl = R.ImGui_GetWindowDrawList(ctx)
  local win_x, win_y = R.ImGui_GetWindowPos(ctx)
  local win_w = R.ImGui_GetWindowSize(ctx)

  -- Background
  R.ImGui_DrawList_AddRectFilled(dl, win_x, win_y, win_x + win_w, win_y + CONFIG.title_h,
    SC.TITLE_BAR)

  -- Title text
  local font_b = temper_theme and temper_theme.font_bold
  if font_b then R.ImGui_PushFont(ctx, font_b, 13) end
  R.ImGui_DrawList_AddText(dl, win_x + 10, win_y + 8, SC.PRIMARY, "TEMPER - NEXUS")
  if font_b then R.ImGui_PopFont(ctx) end

  -- Gear button (right-aligned)
  local gear_w = 22
  R.ImGui_SetCursorScreenPos(ctx, win_x + win_w - gear_w - 8, win_y + 3)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(), SC.TITLE_BAR)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), SC.PANEL)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(), SC.ACTIVE_DARK)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.PRIMARY)
  if R.ImGui_Button(ctx, "\xe2\x9a\x99##settings_nexus", gear_w, 0) then
    R.ImGui_OpenPopup(ctx, "##settings_popup_nexus")
  end
  R.ImGui_PopStyleColor(ctx, 4)

  -- Settings popup
  if R.ImGui_BeginPopup(ctx, "##settings_popup_nexus") then
    if R.ImGui_Button(ctx, "Close##popup_close") then
      state.should_close = true
      R.ImGui_CloseCurrentPopup(ctx)
    end
    if lic then
      local ls = lic.check("NEXUS", ctx)
      if ls ~= "licensed" then
        if R.ImGui_Button(ctx, "Activate\xe2\x80\xa6##popup_lic") then
          lic.open_dialog(ctx)
          R.ImGui_CloseCurrentPopup(ctx)
        end
      end
    end
    R.ImGui_EndPopup(ctx)
  end

  R.ImGui_SetCursorPosY(ctx, CONFIG.title_h)
end

-- ── Action core ──────────────────────────────────────────────────
-- Every key corresponds to a command in actions/manifest.toml. Each method
-- is the single core entry point for that command — called both from
-- render_toolbar (mouse clicks) and from HANDLERS (keyboard dispatch via
-- rsg_actions). Subset-of-GUI invariant: no logic here that the GUI cannot
-- already perform.
local nexus_actions = {}

local function _toggle_filter_chip(state, chip_key)
  local fs = state.filter_state or {}
  fs[chip_key] = not fs[chip_key]
  state.filter_state = fs
  state.row_selected    = {}
  state._row_sel_anchor = nil
  save_settings(state)
end

function nexus_actions.do_cycle_mode(state)
  state.mode = MODE_NEXT[state.mode]
  state.row_selected = {}
  state._row_sel_anchor = nil
  if state.mode == "hw_outs" and state.filter_state then
    state.filter_state.mono = false
  end
  save_settings(state)
  invalidate_routing(state)
end

function nexus_actions.do_copy(state)
  local sel = get_selected_tracks(state)
  local source
  for _, entry in ipairs(sel) do
    if state.nexus_selected[entry.guid] then source = entry; break end
  end
  if source then
    state.clipboard = clip_mod.capture(source.ptr, routing)
    flash(state, "Copied from " .. (source.name ~= "" and source.name or "Track " .. source.index))
  else
    flash(state, "Select tracks in Nexus first")
  end
end

function nexus_actions.do_paste(state)
  if not state.clipboard then return end
  local sel = get_selected_tracks(state)
  local targets = {}
  for _, entry in ipairs(sel) do
    if state.nexus_selected[entry.guid] then
      targets[#targets + 1] = entry.ptr
    end
  end
  if #targets > 0 then
    R.Undo_BeginBlock()
    local result = clip_mod.paste(state.clipboard, targets, routing)
    R.Undo_EndBlock("Nexus: Paste routing", -1)
    invalidate_routing(state)
    flash(state, "Pasted to " .. result.applied .. " track" .. (result.applied ~= 1 and "s" or ""))
  else
    flash(state, "Select tracks in Nexus first")
  end
end

function nexus_actions.toggle_pin(state)
  if state.pinned then
    state.pinned = false
    state.pinned_tracks = {}
    return
  end
  local visible = get_selected_tracks(state)
  local to_pin = {}
  for _, entry in ipairs(visible) do
    if state.nexus_selected[entry.guid] then
      to_pin[#to_pin + 1] = entry
    end
  end
  if #to_pin > 0 then
    state.pinned = true
    state.pinned_tracks = to_pin
    flash(state, "Pinned " .. #to_pin .. " track" .. (#to_pin > 1 and "s" or ""))
  else
    flash(state, "Select tracks in Nexus first")
  end
end

function nexus_actions.toggle_active_filter(state)
  if state.mode == "parent" then return end  -- matches GUI disabled state
  state.filter_active_only = not state.filter_active_only
  save_settings(state)
end

function nexus_actions.toggle_filter_mute(state)   _toggle_filter_chip(state, "mute")   end
function nexus_actions.toggle_filter_phase(state)  _toggle_filter_chip(state, "phase")  end
function nexus_actions.toggle_filter_mono(state)   _toggle_filter_chip(state, "mono")   end
function nexus_actions.toggle_filter_pre(state)    _toggle_filter_chip(state, "pre")    end
function nexus_actions.toggle_filter_postfx(state) _toggle_filter_chip(state, "postfx") end

-- Toggle a B_* property on the current row/track selection, per-row flip.
-- Priority: row_selected (shift-click multi-row) → nexus_selected (track
-- multi-select) → flash warning. Each matched routing flips from its own
-- current value (no dominant-state aggregation), matching the rule in
-- docs/knowledge/actions-framework.md § "Cycle-type actions: per-row".
function nexus_actions.toggle_prop_on_selection(state, prop_key)
  -- Parent mode has no per-row routing properties.
  if state.mode == "parent" then return end
  -- HW OUTS sends never carry B_MONO.
  if prop_key == "B_MONO" and state.mode == "hw_outs" then return end

  local short_key = ({ B_MUTE = "mute", B_PHASE = "phase", B_MONO = "mono" })[prop_key]
  if not short_key then return end

  local lookup = state._row_lookup or {}
  local touched = 0

  -- Row-selected path: shift-click multi-row selection.
  if state.row_selected and next(state.row_selected) then
    R.Undo_BeginBlock()
    for k in pairs(state.row_selected) do
      local pair = lookup[k]
      if pair then
        local t_entry, desc = pair[1], pair[2]
        local new_val = (desc[short_key]) and 0 or 1
        routing.set_prop(t_entry.ptr, desc.category, desc.idx, prop_key, new_val)
        touched = touched + 1
      end
    end
    R.Undo_EndBlock("Nexus: Toggle " .. prop_key, -1)
  else
    -- Track-selected fallback: every routing on every nexus_selected track
    -- in the current mode.
    local has_track_sel = false
    for _ in pairs(state.nexus_selected) do has_track_sel = true; break end
    if not has_track_sel then
      flash(state, "Select routings or tracks first")
      return
    end

    R.Undo_BeginBlock()
    local visible = get_selected_tracks(state)
    for _, entry in ipairs(visible) do
      if state.nexus_selected[entry.guid] then
        local data = get_cached_routing(state, entry)
        local list = data and data[state.mode] or {}
        for _, desc in ipairs(list) do
          local new_val = (desc[short_key]) and 0 or 1
          routing.set_prop(entry.ptr, desc.category, desc.idx, prop_key, new_val)
          touched = touched + 1
        end
      end
    end
    R.Undo_EndBlock("Nexus: Toggle " .. prop_key, -1)
  end

  if touched > 0 then
    invalidate_routing(state)
    flash(state, "Toggled " .. prop_key .. " on " .. touched .. " routing" ..
      (touched ~= 1 and "s" or ""))
  else
    flash(state, "Select routings or tracks first")
  end
end

function nexus_actions.toggle_row_mute(state)  nexus_actions.toggle_prop_on_selection(state, "B_MUTE")  end
function nexus_actions.toggle_row_phase(state) nexus_actions.toggle_prop_on_selection(state, "B_PHASE") end
function nexus_actions.toggle_row_mono(state)  nexus_actions.toggle_prop_on_selection(state, "B_MONO")  end

-- ── Render: Toolbar ───────────────────────────────────────────────

local _BTN_FLASH_DUR = 0.25  -- seconds; matches Imprint

local function _is_btn_flashing(state, btn_key)
  local expires_at = state._btn_flash and state._btn_flash[btn_key]
  return (expires_at and R.time_precise() < expires_at) or false
end

local function render_toolbar(ctx, state)
  if temper_theme and temper_theme.font_bold then
    R.ImGui_PushFont(ctx, temper_theme.font_bold, 13)
  end

  -- Mode cycle button -- per-mode color identity so PARENT / SENDS / RECEIVES /
  -- HW OUTS each read distinctly at a glance. Palette defined in MODE_CYCLE_COL
  -- above. Falls back to the inactive-pill colors if mode is somehow unknown.
  local _mc = MODE_CYCLE_COL[state.mode] or MODE_CYCLE_COL.parent
  if _is_btn_flashing(state, "cycle_mode") then
    push_btn(ctx, _mc[3], _mc[3], _mc[3], _mc[4])  -- pressed shade on bg + hover + active
  else
    push_btn(ctx, _mc[1], _mc[2], _mc[3], _mc[4])
  end
  if R.ImGui_Button(ctx, MODE_LABELS[state.mode] .. "##mode_cycle", 90, CONFIG.btn_sz) then
    nexus_actions.do_cycle_mode(state)
  end
  R.ImGui_PopStyleColor(ctx, 5)  -- push_btn

  R.ImGui_SameLine(ctx)

  -- COPY button (pill default, coral when clipboard loaded)
  if _is_btn_flashing(state, "copy") then
    push_btn(ctx, SC.ACTIVE_DARK, SC.ACTIVE_DARK, SC.ACTIVE_DARK, SC.PRIMARY)
  elseif state.clipboard then
    push_pill_hot(ctx)
  else
    push_pill(ctx)
  end
  if R.ImGui_Button(ctx, "COPY##clip_copy", 55, CONFIG.btn_sz) then
    nexus_actions.do_copy(state)
  end
  R.ImGui_PopStyleColor(ctx, 5)  -- push_btn

  R.ImGui_SameLine(ctx)

  -- PASTE button (pill when clipboard, disabled when empty)
  if _is_btn_flashing(state, "paste") and state.clipboard then
    push_btn(ctx, SC.ACTIVE_DARK, SC.ACTIVE_DARK, SC.ACTIVE_DARK, SC.PRIMARY)
  elseif state.clipboard then
    push_pill(ctx)
  else
    -- Disabled style: 5 colors
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(), SC.PANEL)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), SC.HOVER_INACTIVE)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(), SC.ACTIVE_DARKER)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.TEXT_OFF)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(), SC.BORDER_SUBTLE)
  end
  if R.ImGui_Button(ctx, "PASTE##clip_paste", 58, CONFIG.btn_sz) then
    nexus_actions.do_paste(state)
  end
  R.ImGui_PopStyleColor(ctx, 5)  -- push_btn or disabled style

  R.ImGui_SameLine(ctx)

  -- Filter input (leave room for PIN + ACT buttons)
  local avail_w = R.ImGui_GetContentRegionAvail(ctx)
  local pin_btn_w = 36
  local act_btn_w = 36
  R.ImGui_PushItemWidth(ctx, avail_w - pin_btn_w - act_btn_w - 14)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_FrameBg(), SC.WINDOW)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(), SC.BORDER_INPUT)
  local changed, new_text = R.ImGui_InputTextWithHint(ctx, "##filter", "Filter...", state.filter_text)
  if changed then
    state.filter_text = new_text
    state.filter_pending_ts = R.time_precise()
  end
  R.ImGui_PopStyleColor(ctx, 2)
  R.ImGui_PopItemWidth(ctx)

  R.ImGui_SameLine(ctx)

  -- PIN button (pumpkin orange when active, pill when idle)
  if _is_btn_flashing(state, "toggle_pin") then
    push_btn(ctx, 0xE57A30FF, 0xE57A30FF, 0xE57A30FF, 0x000000FF)  -- pressed pumpkin
  elseif state.pinned then
    push_btn(ctx, 0xFF8C42FF, 0xFF9D5AFF, 0xE57A30FF, 0x000000FF)
  else
    push_pill(ctx)
  end
  if R.ImGui_Button(ctx, "PIN##pin_nexus", pin_btn_w, CONFIG.btn_sz) then
    nexus_actions.toggle_pin(state)
  end
  local _pin_hovered = R.ImGui_IsItemHovered(ctx)
  R.ImGui_PopStyleColor(ctx, 5)
  -- Tooltip drawn after the pop so its text color isn't inherited from the
  -- button's active-state push (SC.WINDOW black would be unreadable).
  if _pin_hovered then R.ImGui_SetTooltip(ctx, "Pin selected tracks") end

  R.ImGui_SameLine(ctx)

  -- Active-only filter toggle (greyed out in parent mode)
  local act_disabled = state.mode == "parent"
  if _is_btn_flashing(state, "toggle_active_filter") and not act_disabled then
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        SC.PRIMARY_AC)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), SC.PRIMARY_AC)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  SC.PRIMARY_AC)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          SC.WINDOW)
  elseif act_disabled then
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(), SC.PANEL)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), SC.HOVER_INACTIVE)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(), SC.ACTIVE_DARKER)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.TEXT_OFF)
  elseif state.filter_active_only then
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(), SC.PRIMARY)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), SC.PRIMARY_HV)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(), SC.PRIMARY_AC)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.WINDOW)
  else
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(), SC.PANEL_TOP)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), SC.HOVER_LIST)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(), SC.ACTIVE_DARK)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.TEXT_MUTED)
  end
  if R.ImGui_Button(ctx, "ACT##act_filter", act_btn_w, CONFIG.btn_sz) and not act_disabled then
    nexus_actions.toggle_active_filter(state)
  end
  local _act_hovered = R.ImGui_IsItemHovered(ctx)
  R.ImGui_PopStyleColor(ctx, 4)
  -- Same pattern as PIN: draw tooltip after the pop so the active-state
  -- Col_Text push (black on black) doesn't make it unreadable.
  if _act_hovered then R.ImGui_SetTooltip(ctx, "Show only tracks with routing") end

  -- ── Second toolbar row: state filter chips ─────────────────────
  -- Hidden in PARENT mode (none of these flags apply).
  if state.mode ~= "parent" then
    R.ImGui_Spacing(ctx)
    local fs = state.filter_state or {}
    -- MONO chip is hidden in HW OUTS mode because REAPER's hardware output
    -- sends never carry B_MONO=1 (the toggle isn't exposed there) — toggling
    -- the filter would silently hide every row in hw_outs.
    local chips = {
      { key = "mute",   label = "MUTED",   tip = "Show only muted routings",        w = 56 },
      { key = "phase",  label = "PHASE",   tip = "Show only phase-flipped routings", w = 60 },
    }
    if state.mode ~= "hw_outs" then
      chips[#chips + 1] = { key = "mono", label = "MONO", tip = "Show only mono routings", w = 56 }
    end
    chips[#chips + 1] = { key = "pre",    label = "PRE-FX",  tip = "Show only Pre-FX routings",  w = 60 }
    chips[#chips + 1] = { key = "postfx", label = "POST-FX", tip = "Show only Post-FX routings", w = 68 }
    for ci, chip in ipairs(chips) do
      local on = fs[chip.key]
      if on then
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        SC.PRIMARY)
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), SC.PRIMARY_HV)
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  SC.PRIMARY_AC)
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          SC.WINDOW)
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(),        0)
      else
        push_pill(ctx)
      end
      if R.ImGui_Button(ctx, chip.label .. "##chip_" .. chip.key, chip.w, 0) then
        _toggle_filter_chip(state, chip.key)
      end
      local _chip_hovered = R.ImGui_IsItemHovered(ctx)
      R.ImGui_PopStyleColor(ctx, 5)
      if _chip_hovered then R.ImGui_SetTooltip(ctx, chip.tip) end
      if ci < #chips then R.ImGui_SameLine(ctx, 0, 4) end
    end
  end

  if temper_theme and temper_theme.font_bold then R.ImGui_PopFont(ctx) end

  R.ImGui_Dummy(ctx, 0, 8)
end

-- ── Nexus Selection ──────────────────────────────────────────────
-- Returns tracks selected within Nexus (for batch edits).
--   - Nothing Nexus-selected                → fall back to {current_entry}
--   - current_entry is in the selection set → return the full set (batch edit)
--   - current_entry is NOT in the set       → replace selection with {current_entry}
--     and return {current_entry}. This matches user expectation that interacting
--     with a control on an unselected row acts on that row (and moves the selection
--     there), rather than silently dispatching to the previously selected tracks.

local function get_nexus_selected(state, current_entry)
  if not state.nexus_selected[current_entry.guid] then
    state.nexus_selected = { [current_entry.guid] = true }
    state._sel_anchor = current_entry.guid
    return { current_entry }
  end
  local sel = get_selected_tracks(state)
  local out = {}
  for _, entry in ipairs(sel) do
    if state.nexus_selected[entry.guid] then
      out[#out + 1] = entry
    end
  end
  if #out == 0 then return { current_entry } end
  return out
end

-- ── Pin Detection ────────────────────────────────────────────────

local function is_track_pinned(state, guid)
  if not state.pinned then return false end
  for _, entry in ipairs(state.pinned_tracks or {}) do
    if entry.guid == guid then return true end
  end
  return false
end

-- Click selection — two variants, both use an invisible button BEHIND visible
-- widgets. Must be called BEFORE any other widgets in the row, cursor reset after.

-- Build the stable key for a row-level selection entry.
local function row_sel_key(track_entry, descriptor)
  return track_entry.guid .. "|" .. descriptor.category .. "|" .. descriptor.idx
end

-- Track-level selector (used by the collapsible track header in non-parent
-- modes and by parent rows). Toggles state.nexus_selected for batch edits.
local function track_click_selector(ctx, state, track_entry, row_idx, cx, cy, avail_w)
  R.ImGui_SetCursorScreenPos(ctx, cx, cy)
  R.ImGui_SetNextItemAllowOverlap(ctx)
  R.ImGui_InvisibleButton(ctx, "##tsel_" .. track_entry.guid .. "_" .. row_idx, avail_w, CONFIG.row_h)

  if R.ImGui_IsItemActive(ctx) then
    local dl = R.ImGui_GetWindowDrawList(ctx)
    R.ImGui_DrawList_AddRectFilled(dl, cx, cy, cx + avail_w, cy + CONFIG.row_h, SC.PRIMARY)
  end

  if R.ImGui_IsItemClicked(ctx, 0) then
    local guid = track_entry.guid
    local is_sel = state.nexus_selected[guid]
    local ctrl  = R.ImGui_IsKeyDown(ctx, R.ImGui_Mod_Ctrl())
    local shift = R.ImGui_IsKeyDown(ctx, R.ImGui_Mod_Shift())

    local handled = false
    if shift and state._sel_anchor and state._visible_tracks then
      local visible = state._visible_tracks
      local anchor_idx, cur_idx
      for i, entry in ipairs(visible) do
        if entry.guid == state._sel_anchor then anchor_idx = i end
        if entry.guid == guid                 then cur_idx    = i end
      end
      if anchor_idx and cur_idx then
        local lo = math.min(anchor_idx, cur_idx)
        local hi = math.max(anchor_idx, cur_idx)
        state.nexus_selected = {}
        for i = lo, hi do
          state.nexus_selected[visible[i].guid] = true
        end
        handled = true
      end
    end

    if not handled then
      if ctrl then
        if is_sel then state.nexus_selected[guid] = nil
        else           state.nexus_selected[guid] = true end
      else
        if is_sel then state.nexus_selected = {}
        else           state.nexus_selected = { [guid] = true } end
      end
      state._sel_anchor = guid
    end
  end

  R.ImGui_SetCursorScreenPos(ctx, cx, cy)
end

-- Row-level selector for individual sends/receives/hw_outs. Toggles
-- state.row_selected (guid|category|idx keys) — purely visual for v1.6.0,
-- batch ops continue to key off nexus_selected.
local function row_click_selector(ctx, state, track_entry, descriptor, row_idx, cx, cy, avail_w)
  R.ImGui_SetCursorScreenPos(ctx, cx, cy)
  R.ImGui_SetNextItemAllowOverlap(ctx)
  R.ImGui_InvisibleButton(ctx, "##rsel_" .. row_sel_key(track_entry, descriptor), avail_w, CONFIG.row_h)

  if R.ImGui_IsItemActive(ctx) then
    local dl = R.ImGui_GetWindowDrawList(ctx)
    R.ImGui_DrawList_AddRectFilled(dl, cx, cy, cx + avail_w, cy + CONFIG.row_h, SC.PRIMARY)
  end

  if R.ImGui_IsItemClicked(ctx, 0) then
    state.row_selected = state.row_selected or {}
    local key = row_sel_key(track_entry, descriptor)
    local is_sel = state.row_selected[key]
    local ctrl  = R.ImGui_IsKeyDown(ctx, R.ImGui_Mod_Ctrl())
    local shift = R.ImGui_IsKeyDown(ctx, R.ImGui_Mod_Shift())

    local handled = false
    if shift and state._row_sel_anchor and state._visible_rows then
      local visible = state._visible_rows
      local anchor_idx, cur_idx
      for i, k in ipairs(visible) do
        if k == state._row_sel_anchor then anchor_idx = i end
        if k == key                    then cur_idx    = i end
      end
      if anchor_idx and cur_idx then
        local lo = math.min(anchor_idx, cur_idx)
        local hi = math.max(anchor_idx, cur_idx)
        state.row_selected = {}
        for i = lo, hi do
          state.row_selected[visible[i]] = true
        end
        handled = true
      end
    end

    if not handled then
      if ctrl then
        if is_sel then state.row_selected[key] = nil
        else           state.row_selected[key] = true end
      else
        if is_sel then state.row_selected = {}
        else           state.row_selected = { [key] = true } end
      end
      state._row_sel_anchor = key
    end

    -- Manual row action invalidates any "highlighted destination" label --
    -- the selection no longer represents a clean dest group.
    state.highlight_dest = nil
  end

  R.ImGui_SetCursorScreenPos(ctx, cx, cy)
end

-- ── Track Name Widget ────────────────────────────────────────────
-- Editable InputTextWithHint matching Vortex's Seek column. Commit on
-- IsItemDeactivatedAfterEdit (Enter or click-away). Row selection is
-- handled by row_click_selector for clicks outside the field.

local function render_track_name(ctx, state, track_entry, width)
  local font_b = temper_theme and temper_theme.font_bold
  if font_b then R.ImGui_PushFont(ctx, font_b, 13) end

  -- Transparent FrameBg in all states so the name blends into whatever row
  -- background is drawn behind it (parent row, track header, etc.). The visual
  -- row highlight comes from the row's own DrawList rect, not from this widget.
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_FrameBg(),        0)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_FrameBgHovered(), 0)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_FrameBgActive(),  0)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_TextDisabled(),   SC.PANEL_TOP)
  -- Track-selected name goes teal so the user can tell at a glance which
  -- track(s) will receive COPY / PASTE / batch edits. Subtle, single-color.
  local _name_sel = state.nexus_selected and state.nexus_selected[track_entry.guid]
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),           _name_sel and SC.PRIMARY or SC.TEXT_ON)

  R.ImGui_SetNextItemWidth(ctx, width)
  local hint = "Track " .. track_entry.index
  state._name_buf = state._name_buf or {}
  local buf = state._name_buf[track_entry.guid] or track_entry.name
  local _, new_buf = R.ImGui_InputTextWithHint(
    ctx, "##tn_" .. track_entry.guid, hint, buf)
  -- Only persist buffer while actively editing; otherwise let REAPER's
  -- current name flow through on the next frame.
  if R.ImGui_IsItemActive(ctx) then
    state._name_buf[track_entry.guid] = new_buf
  end

  if R.ImGui_IsItemDeactivatedAfterEdit(ctx) then
    local final = new_buf
    if final ~= track_entry.name then
      R.Undo_BeginBlock()
      R.GetSetMediaTrackInfo_String(track_entry.ptr, "P_NAME", final, true)
      R.Undo_EndBlock("Nexus: Rename track", -1)
      track_entry.name = final
      invalidate_routing(state)
    end
  end

  R.ImGui_PopStyleColor(ctx, 5)
  if font_b then R.ImGui_PopFont(ctx) end
end

-- ── Batch Helpers ────────────────────────────────────────────────

-- Row-level dispatch: when the user multi-selects individual sends (via
-- click / Ctrl+click / Shift-range), batch ops operate on exactly those
-- rows. Mirrors get_nexus_selected's "clicked an unselected target -> move
-- selection to it" rule so button clicks on unselected rows act locally.
--
-- Returns a list of {track_entry, descriptor} pairs, or nil when row-level
-- selection is not active (fall through to track-level batch).
local function get_row_selected_targets(state, track_entry, descriptor)
  if not state.row_selected then return nil end
  local cur_key = row_sel_key(track_entry, descriptor)

  -- Clicked row not in the set -> promote to sole selection and act locally.
  if not state.row_selected[cur_key] then
    state.row_selected  = { [cur_key] = true }
    state._row_sel_anchor = cur_key
    return nil  -- single-row case; caller falls through to direct set_prop
  end

  local n = 0
  for _ in pairs(state.row_selected) do n = n + 1 end
  if n <= 1 then return nil end  -- single row, no batching needed

  local out = {}
  local lookup = state._row_lookup or {}
  for k in pairs(state.row_selected) do
    local pair = lookup[k]
    if pair then out[#out + 1] = pair end
  end
  return out
end

-- Apply a property change -- row-level selection wins when active, otherwise
-- falls through to the track-level "matching dest across Nexus-selected
-- tracks" dispatch (unchanged from v1.5.x).
local function batch_set_prop(state, track_entry, descriptor, key, value)
  local row_targets = get_row_selected_targets(state, track_entry, descriptor)
  if row_targets then
    for _, pair in ipairs(row_targets) do
      local t_entry, desc = pair[1], pair[2]
      routing.set_prop(t_entry.ptr, desc.category, desc.idx, key, value)
    end
    return
  end

  local sel = get_nexus_selected(state, track_entry)
  if #sel <= 1 then
    routing.set_prop(sel[1].ptr, descriptor.category, descriptor.idx, key, value)
    return
  end
  for _, entry in ipairs(sel) do
    local data = get_cached_routing(state, entry)
    local list = data[state.mode] or {}
    for _, desc in ipairs(list) do
      if desc.dest_guid == descriptor.dest_guid then
        routing.set_prop(entry.ptr, desc.category, desc.idx, key, value)
      end
    end
  end
end

-- Bulk delete: removes every send referenced in state.row_selected. Sends
-- are grouped by track_guid and sorted in DESCENDING idx order before the
-- routing.remove_send loop so deletions don't shift surviving indices on
-- the same track. Wrapped in a single Undo block.
local function delete_selected_rows(state)
  if not state.row_selected then return 0 end
  local lookup = state._row_lookup or {}

  local per_track = {}
  for key in pairs(state.row_selected) do
    local pair = lookup[key]
    if pair then
      local entry, desc = pair[1], pair[2]
      local g = entry.guid
      per_track[g] = per_track[g] or { entry = entry, items = {} }
      table.insert(per_track[g].items, desc)
    end
  end
  if next(per_track) == nil then return 0 end

  local n = 0
  R.Undo_BeginBlock()
  for _, group in pairs(per_track) do
    table.sort(group.items, function(a, b) return a.idx > b.idx end)
    for _, d in ipairs(group.items) do
      routing.remove_send(group.entry.ptr, d.category, d.idx)
      n = n + 1
    end
  end
  R.Undo_EndBlock("Nexus: Delete " .. n .. " routing" .. (n ~= 1 and "s" or ""), -1)

  state.row_selected    = {}
  state._row_sel_anchor = nil
  invalidate_routing(state)
  flash(state, "Deleted " .. n .. " routing" .. (n ~= 1 and "s" or ""))
  return n
end

-- Send clipboard helpers (right-click menu: Copy / Paste / Duplicate).
-- The clipboard is a flat snapshot of one descriptor + the dest track ptr.
-- It lives in state.send_clipboard, distinct from state.clipboard (which is
-- the existing track-level routing clipboard).

local function _snapshot_send(state, track_entry, descriptor)
  state.send_clipboard = {
    src_mode    = state.mode,
    dest_track  = descriptor.dest_track,
    dest_guid   = descriptor.dest_guid,
    dest_index  = descriptor.dest_index,
    vol         = descriptor.vol,
    pan         = descriptor.pan,
    mute        = descriptor.mute,
    phase       = descriptor.phase,
    mono        = descriptor.mono,
    mode        = descriptor.mode,
    src_chan    = descriptor.src_chan,
    dst_chan    = descriptor.dst_chan,
  }
  flash(state, "Copied routing")
end

-- Apply a snapshot's properties to the send at (track, cat, idx).
local function _apply_send_snapshot(track_ptr, cat, idx, snap)
  routing.set_prop(track_ptr, cat, idx, "D_VOL",     snap.vol)
  routing.set_prop(track_ptr, cat, idx, "D_PAN",     snap.pan)
  routing.set_prop(track_ptr, cat, idx, "B_MUTE",    snap.mute  and 1 or 0)
  routing.set_prop(track_ptr, cat, idx, "B_PHASE",   snap.phase and 1 or 0)
  routing.set_prop(track_ptr, cat, idx, "B_MONO",    snap.mono  and 1 or 0)
  routing.set_prop(track_ptr, cat, idx, "I_SENDMODE", snap.mode)
  routing.set_prop(track_ptr, cat, idx, "I_SRCCHAN", snap.src_chan)
  routing.set_prop(track_ptr, cat, idx, "I_DSTCHAN", snap.dst_chan)
end

-- Resolve (src, dest) for create_send based on current view mode.
-- Sends mode    : the row "owner" is the source, dest_track is the destination.
-- Receives mode : the row "owner" is the destination, dest_track is the source.
local function _resolve_send_pair(view_mode, owner_track, dest_track)
  if view_mode == "receives" then
    return dest_track, owner_track
  else
    return owner_track, dest_track
  end
end

-- Returns the highest send index (0-based) on a track for the given category,
-- after a fresh CreateTrackSend. routing.create_send does not reliably return
-- the new index across categories, so we recount.
local function _last_send_index(track_ptr, cat)
  if cat == routing.CAT_SENDS then
    return R.GetTrackNumSends(track_ptr, 0) - 1
  elseif cat == routing.CAT_RECEIVES then
    return R.GetTrackNumSends(track_ptr, -1) - 1
  else
    return R.GetTrackNumSends(track_ptr, 1) - 1
  end
end

local function _paste_send_to(state, target_track_entry)
  local snap = state.send_clipboard
  if not snap then return end
  if not snap.dest_track or not R.ValidatePtr(snap.dest_track, "MediaTrack*") then
    flash(state, "Send clipboard target no longer exists")
    state.send_clipboard = nil
    return
  end

  local src, dest = _resolve_send_pair(state.mode, target_track_entry.ptr, snap.dest_track)
  R.Undo_BeginBlock()
  routing.create_send(src, dest)
  -- Determine the category and new index from the perspective of the row owner.
  local cat = (state.mode == "receives") and routing.CAT_RECEIVES or routing.CAT_SENDS
  local new_idx = _last_send_index(target_track_entry.ptr, cat)
  if new_idx >= 0 then
    _apply_send_snapshot(target_track_entry.ptr, cat, new_idx, snap)
  end
  R.Undo_EndBlock("Nexus: Paste routing", -1)
  invalidate_routing(state)
  flash(state, "Pasted routing")
end

local function _duplicate_send(state, track_entry, descriptor)
  if not descriptor.dest_track or not R.ValidatePtr(descriptor.dest_track, "MediaTrack*") then
    return
  end
  local snap = {
    src_mode   = state.mode,
    dest_track = descriptor.dest_track,
    dest_guid  = descriptor.dest_guid,
    dest_index = descriptor.dest_index,
    vol        = descriptor.vol,
    pan        = descriptor.pan,
    mute       = descriptor.mute,
    phase      = descriptor.phase,
    mono       = descriptor.mono,
    mode       = descriptor.mode,
    src_chan   = descriptor.src_chan,
    dst_chan   = descriptor.dst_chan,
  }
  local src, dest = _resolve_send_pair(state.mode, track_entry.ptr, descriptor.dest_track)
  R.Undo_BeginBlock()
  routing.create_send(src, dest)
  local cat = (state.mode == "receives") and routing.CAT_RECEIVES or routing.CAT_SENDS
  local new_idx = _last_send_index(track_entry.ptr, cat)
  if new_idx >= 0 then
    _apply_send_snapshot(track_entry.ptr, cat, new_idx, snap)
  end
  R.Undo_EndBlock("Nexus: Duplicate routing", -1)
  invalidate_routing(state)
  flash(state, "Duplicated routing")
end

-- Hardware output label for row pill + picker. Reads REAPER's output channel
-- name; when REAPER returns a bare number or empty (default unnamed outputs),
-- we render "Output N" so the row is self-describing. Multi-channel ranges
-- render as "<first>-<last_index_1based>" so the user sees the actual span.
local function _hw_label(hw_off, src_cnt)
  local function _name(idx)
    local n = R.GetOutputChannelName(idx) or ""
    if n == "" or n:match("^%d+$") then
      return "Output " .. (idx + 1)
    end
    return n
  end
  if (src_cnt or 1) <= 1 then
    return _name(hw_off)
  end
  return _name(hw_off) .. "-" .. (hw_off + src_cnt)
end

-- Create a hardware output routing on `source_track` targeting hardware
-- channel `hw_channel_idx` (0-based). Mirrors REAPER's native "Add new
-- hardware output..." behavior: stereo pair by default when the source track
-- has >=2 channels, mono otherwise.
local function _create_hw_out(state, source_track, hw_channel_idx)
  R.Undo_BeginBlock()
  routing.create_send(source_track, nil)  -- nil dest = hardware output
  local new_idx = _last_send_index(source_track, routing.CAT_HW_OUTS)
  if new_idx >= 0 then
    routing.set_prop(source_track, routing.CAT_HW_OUTS, new_idx,
      "I_DSTCHAN", routing.encode_dst_channels(hw_channel_idx, false))
    local src_nchan = math.floor(R.GetMediaTrackInfo_Value(source_track, "I_NCHAN"))
    local default_cnt = (src_nchan >= 2) and 2 or 1
    routing.set_prop(source_track, routing.CAT_HW_OUTS, new_idx,
      "I_SRCCHAN", routing.encode_src_channels(0, default_cnt))
  end
  R.Undo_EndBlock("Nexus: Add hardware output", -1)
  invalidate_routing(state)
end

-- Jump to the routing peer. In sends mode `descriptor.dest_track` is the send
-- destination; in receives mode it is the source track; in hw_outs mode it is
-- nil and the caller must gate on `has_dest`. Same function, mode-agnostic.
local function _jump_to_peer(descriptor)
  if not descriptor.dest_track or not R.ValidatePtr(descriptor.dest_track, "MediaTrack*") then
    return
  end
  R.SetOnlyTrackSelected(descriptor.dest_track)
  -- Track: Vertical scroll selected tracks into view
  R.Main_OnCommand(40913, 0)
end

-- State-filter predicate (Fix 5). Multiple chips compound with AND semantics.
local function _descriptor_passes_state_filter(descriptor, fs)
  if not fs then return true end
  if fs.mute   and not descriptor.mute  then return false end
  if fs.mono   and not descriptor.mono  then return false end
  if fs.phase  and not descriptor.phase then return false end
  if fs.pre    and descriptor.mode ~= 1 then return false end
  if fs.postfx and descriptor.mode ~= 3 then return false end
  return true
end

local function _any_state_filter_active(fs)
  return fs and (fs.mute or fs.mono or fs.phase or fs.pre or fs.postfx)
end

local function batch_set_parent(state, track_entry, key, value)
  local sel = get_nexus_selected(state, track_entry)
  for _, entry in ipairs(sel) do
    if key == "B_MAINSEND" then
      routing.set_parent_enabled(entry.ptr, value)
    elseif key == "D_VOL" then
      routing.set_parent_vol(entry.ptr, value)
    elseif key == "D_PAN" then
      routing.set_parent_pan(entry.ptr, value)
    elseif key == "C_MAINSEND_NCH" then
      routing.set_parent_nchan(entry.ptr, value)
    elseif key == "C_MAINSEND_OFFS" then
      routing.set_parent_ch_offset(entry.ptr, value)
    end
  end
end

-- Apply a track-level I_NCHAN change to all Nexus-selected tracks (fallback: current row)
local function batch_set_track_nchan(state, track_entry, nchan)
  local sel = get_nexus_selected(state, track_entry)
  for _, entry in ipairs(sel) do
    routing.set_track_nchan(entry.ptr, nchan)
    entry.nchan = nchan
  end
end

-- ── Render: Send/Receive Row ──────────────────────────────────────

local function render_send_row(ctx, state, track_entry, descriptor, row_idx)
  local dl = R.ImGui_GetWindowDrawList(ctx)
  local cx, cy = R.ImGui_GetCursorScreenPos(ctx)
  local avail_w = R.ImGui_GetContentRegionAvail(ctx) - 4  -- trim 4px from right end of row
  local _row_font = temper_theme and temper_theme.font_bold
  if _row_font then R.ImGui_PushFont(ctx, _row_font, 13) end

  -- Row background: alternating grey + pin + per-row selection + hover + dest highlight.
  -- Per-row selection (state.row_selected) is the only source of the teal row tint —
  -- track-level nexus_selected lights up the HEADER, never the sub-rows.
  local rkey = row_sel_key(track_entry, descriptor)
  local is_row_sel = state.row_selected and state.row_selected[rkey]
  local is_pinned = is_track_pinned(state, track_entry.guid)
  local row_bg = (row_idx % 2 == 0) and SC.PANEL_HIGH or SC.PANEL
  R.ImGui_DrawList_AddRectFilled(dl, cx, cy, cx + avail_w, cy + CONFIG.row_h, row_bg)
  if is_pinned then
    R.ImGui_DrawList_AddRectFilled(dl, cx, cy, cx + avail_w, cy + CONFIG.row_h, ROW_PIN_BG)
  end
  if is_row_sel then
    R.ImGui_DrawList_AddRectFilled(dl, cx, cy, cx + avail_w, cy + CONFIG.row_h, ROW_SEL_BG)
  end
  local mx, my = R.ImGui_GetMousePos(ctx)
  if mx >= cx and mx <= cx + avail_w and my >= cy and my <= cy + CONFIG.row_h then
    R.ImGui_DrawList_AddRectFilled(dl, cx, cy, cx + avail_w, cy + CONFIG.row_h, SC.HOVER_LIST)
  end
  -- Note: the dest-pill click also populates state.row_selected, so the
  -- is_row_sel tint above already covers "highlighted destination group".

  -- Dim every widget on this row when the send is muted. StyleVar_Alpha
  -- does NOT affect DrawList rects, so the bg + pin + selection tints
  -- above stay solid while the widgets fade. Single push, single pop --
  -- no early-return paths inside this function.
  local _row_dimmed = false
  if descriptor.mute then
    R.ImGui_PushStyleVar(ctx, R.ImGui_StyleVar_Alpha(), 0.55)
    _row_dimmed = true
  end

  -- Row-wide invisible button for click selection (behind real widgets)
  row_click_selector(ctx, state, track_entry, descriptor, row_idx, cx, cy, avail_w)

  -- Right-click anywhere on the full row opens the send context menu.
  -- OpenPopup fires off the invisible button from row_click_selector so
  -- the trigger area matches the full row, not just the dest pill.
  local _send_ctx_id = "##sendctx_" .. track_entry.guid .. "_" .. row_idx
  if R.ImGui_IsItemClicked(ctx, 1) then
    R.ImGui_OpenPopup(ctx, _send_ctx_id)
  end

  -- Vertical centering: pixel-exact offset based on actual frame height
  local _frame_h = R.ImGui_GetFrameHeight(ctx)
  local _v_off = math.floor((CONFIG.row_h - _frame_h) * 0.5 + 0.5)
  -- Left gutter so controls don't hug the window edge
  R.ImGui_SetCursorScreenPos(ctx, cx + 8, cy + _v_off)

  -- Row-wide text color
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.TEXT_ON)

  -- Mode branch: HW OUTS renders without the MONO toggle and without a
  -- separate destination-channel dropdown. The peer-name pill surfaces the
  -- actual hardware output name (mirroring REAPER's native "Hardware: Output N"
  -- header label), so the destination is self-describing.
  local is_hw = (state.mode == "hw_outs")
  -- Decode src/dst channels once; both the peer-name pill (hw_outs) and the
  -- later channel combos read these.
  local src_off, src_cnt = routing.decode_src_channels(descriptor.src_chan)
  local dst_off, dst_mono = routing.decode_dst_channels(descriptor.dst_chan)

  -- Arrow prefix (sub-row indent)
  local arrow = (state.mode == "sends" or state.mode == "hw_outs") and "\xe2\x86\x92" or "\xe2\x86\x90"
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.TEXT_MUTED)
  R.ImGui_Text(ctx, arrow)
  R.ImGui_PopStyleColor(ctx, 1)
  R.ImGui_SameLine(ctx)

  -- Destination name (pill-styled button, click toggles highlight)
  local dest_hot = (descriptor.dest_guid == state.highlight_dest)
  if dest_hot then
    push_pill_hot(ctx)
  else
    push_pill(ctx)
  end
  -- Destination label:
  --   hw_outs   : "Output N" / "Output N-M" from GetOutputChannelName
  --   sends/rcv : "N · Name" when the peer is a real track, raw dest_name otherwise
  local dest_label
  if is_hw then
    dest_label = _hw_label(dst_off, src_cnt)
  else
    local _dest_raw = descriptor.dest_name ~= "" and descriptor.dest_name or "(unnamed)"
    dest_label = descriptor.dest_index
      and (descriptor.dest_index .. " \xc2\xb7 " .. _dest_raw)
      or _dest_raw
  end
  -- Left-align so the track-number prefix lines up vertically across rows.
  R.ImGui_PushStyleVar(ctx, R.ImGui_StyleVar_ButtonTextAlign(), 0.0, 0.5)
  if R.ImGui_Button(ctx, dest_label .. "##dest_" .. track_entry.guid .. "_" .. row_idx, 140, 0) then
    if state.highlight_dest == descriptor.dest_guid then
      state.highlight_dest = nil
      state.row_selected    = {}
      state._row_sel_anchor = nil
    else
      state.highlight_dest = descriptor.dest_guid
      -- Promote the visual group into a real row-level selection so the
      -- batch_set_prop row-dispatch path picks it up. All visible rows whose
      -- descriptor shares dest_guid become selected.
      local sel = {}
      local lookup = state._row_lookup or {}
      for rk, pair in pairs(lookup) do
        if pair[2].dest_guid == descriptor.dest_guid then
          sel[rk] = true
        end
      end
      state.row_selected    = sel
      state._row_sel_anchor = row_sel_key(track_entry, descriptor)
    end
  end
  R.ImGui_PopStyleVar(ctx, 1)
  R.ImGui_PopStyleColor(ctx, 5)

  -- Routing context menu body. Triggered by the full-row invisible button's
  -- right-click detection above (OpenPopup path). Rendered after the dest
  -- pill's color stack is popped so the menu uses default theme colors.
  -- Labels use the neutral word "routing" so the same strings read correctly
  -- in sends, receives, and hw_outs modes.
  if R.ImGui_BeginPopup(ctx, _send_ctx_id) then
    local has_dest = descriptor.dest_track and R.ValidatePtr(descriptor.dest_track, "MediaTrack*")
    local hw = (state.mode == "hw_outs")
    -- "Jump to source" in receives mode reads more accurately; every other
    -- mode reads as "destination".
    local jump_label = (state.mode == "receives") and "Jump to source" or "Jump to destination"
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.PRIMARY)
    R.ImGui_Text(ctx, "Routing")
    R.ImGui_PopStyleColor(ctx, 1)
    R.ImGui_Separator(ctx)

    if has_dest and not hw then
      if R.ImGui_Selectable(ctx, jump_label) then
        _jump_to_peer(descriptor)
      end
    end

    if R.ImGui_Selectable(ctx, "Copy routing") then
      _snapshot_send(state, track_entry, descriptor)
    end

    local can_paste = state.send_clipboard
      and not hw
      and state.send_clipboard.dest_track
      and R.ValidatePtr(state.send_clipboard.dest_track, "MediaTrack*")
    if can_paste then
      if R.ImGui_Selectable(ctx, "Paste routing here") then
        _paste_send_to(state, track_entry)
      end
    end

    if has_dest and not hw then
      R.ImGui_Separator(ctx)
      if R.ImGui_Selectable(ctx, "Duplicate routing") then
        _duplicate_send(state, track_entry, descriptor)
      end
    end

    R.ImGui_Separator(ctx)
    if R.ImGui_Selectable(ctx, "Delete routing") then
      R.Undo_BeginBlock()
      routing.remove_send(track_entry.ptr, descriptor.category, descriptor.idx)
      R.Undo_EndBlock("Nexus: Delete routing", -1)
      invalidate_routing(state)
    end

    local _rkey = row_sel_key(track_entry, descriptor)
    if state.row_selected and state.row_selected[_rkey] then
      local _n = 0
      for _ in pairs(state.row_selected) do _n = _n + 1 end
      if _n >= 2 then
        if R.ImGui_Selectable(ctx, "Delete selected (" .. _n .. ")") then
          delete_selected_rows(state)
        end
      end
    end

    R.ImGui_EndPopup(ctx)
  end

  R.ImGui_SameLine(ctx, 0, 8)

  -- M / Ø / MONO — three peer toggles, REAPER-native send strip grouping.
  -- Filled-teal pill when on, inactive pill when off. No coral in this group.
  local function _push_toggle(on)
    if on then
      R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        SC.TERTIARY)
      R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), SC.TERTIARY_HV)
      R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  SC.TERTIARY_AC)
      R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          SC.WINDOW)
      R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(),        0)
    else
      push_pill(ctx)
    end
  end

  -- M (Mute)
  _push_toggle(descriptor.mute)
  if R.ImGui_Button(ctx, "M##mute_" .. track_entry.guid .. "_" .. row_idx, 22, 0) then
    R.Undo_BeginBlock()
    batch_set_prop(state, track_entry, descriptor, "B_MUTE", descriptor.mute and 0 or 1)
    R.Undo_EndBlock("Nexus: Toggle mute", -1)
    invalidate_routing(state)
  end
  R.ImGui_PopStyleColor(ctx, 5)
  if R.ImGui_IsItemHovered(ctx) then
    local tip = state.mode == "receives" and "Mute receive" or "Mute send"
    R.ImGui_SetTooltip(ctx, tip)
  end
  R.ImGui_SameLine(ctx, 0, 4)

  -- Ø (Phase invert)
  _push_toggle(descriptor.phase)
  if R.ImGui_Button(ctx, "\xe2\x88\x85##phase_" .. track_entry.guid .. "_" .. row_idx, 22, 0) then
    R.Undo_BeginBlock()
    batch_set_prop(state, track_entry, descriptor, "B_PHASE", descriptor.phase and 0 or 1)
    R.Undo_EndBlock("Nexus: Toggle phase", -1)
    invalidate_routing(state)
  end
  R.ImGui_PopStyleColor(ctx, 5)
  if R.ImGui_IsItemHovered(ctx) then R.ImGui_SetTooltip(ctx, "Invert phase") end
  -- 4px inner gap before MONO (sends/receives) or 8px outer gap before
  -- src_chan when MONO is skipped (hw_outs).
  R.ImGui_SameLine(ctx, 0, is_hw and 8 or 4)

  -- Mono (sum send to center) -- REAPER-style circled-dot symbol ⊙
  -- HW OUTS: REAPER's native HW output strip has no mono toggle, so we omit
  -- it here. Spacing into src_chan handled by the Ø SameLine above.
  if not is_hw then
    _push_toggle(descriptor.mono)
    if R.ImGui_Button(ctx, "\xe2\x8a\x99##mono_" .. track_entry.guid .. "_" .. row_idx, 22, 0) then
      R.Undo_BeginBlock()
      batch_set_prop(state, track_entry, descriptor, "B_MONO", descriptor.mono and 0 or 1)
      R.Undo_EndBlock("Nexus: Toggle mono", -1)
      invalidate_routing(state)
    end
    R.ImGui_PopStyleColor(ctx, 5)
    if R.ImGui_IsItemHovered(ctx) then R.ImGui_SetTooltip(ctx, "Mono (sum to center)") end
    R.ImGui_SameLine(ctx, 0, 8)
  end

  -- Source channel count combo (src_off/src_cnt/dst_off/dst_mono decoded earlier)
  local uid = track_entry.guid .. "_" .. row_idx

  R.ImGui_PushItemWidth(ctx, 52)
  push_combo_pill(ctx)
  local src_is_all = src_off == 0 and src_cnt == track_entry.nchan
  local src_label
  if src_off == -1 then
    src_label = "---"
  elseif src_is_all then
    src_label = "All"
  elseif src_cnt == 1 then
    src_label = tostring(src_off + 1)
  else
    src_label = (src_off + 1) .. "-" .. (src_off + src_cnt)
  end
  if R.ImGui_BeginCombo(ctx, "##sch_" .. uid, center_label(src_label)) then
    -- Channel count options, capped by the source track's actual channel count
    local src_cap = descriptor.src_max_nchan or track_entry.nchan
    for _, n in ipairs({1, 2, 4, 6, 8, 10, 12, 16, 24, 32, 64}) do
      if n <= src_cap then
        local sel = (n == src_cnt and src_off >= 0)
        local start = src_off >= 0 and (src_off + 1) or 1
        local range_lbl = n == 1 and tostring(start) or (start .. "-" .. (start + n - 1))
        if R.ImGui_Selectable(ctx, range_lbl, sel) then
          local off = src_off >= 0 and src_off or 0
          R.Undo_BeginBlock()
          batch_set_prop(state, track_entry, descriptor,
            "I_SRCCHAN", routing.encode_src_channels(off, n))
          R.Undo_EndBlock("Nexus: Set source channels", -1)
          invalidate_routing(state)
        end
      end
    end
    -- Cascade (only for multi-track)
    local sel = get_selected_tracks(state)
    if #sel >= 2 then
      R.ImGui_Separator(ctx)
      R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.PRIMARY)
      R.ImGui_Text(ctx, "Cascade")
      R.ImGui_PopStyleColor(ctx, 1)
      local track_ptrs = {}
      for _, entry in ipairs(sel) do track_ptrs[#track_ptrs + 1] = entry.ptr end
      local start_ch = src_off >= 0 and src_off or 0
      if R.ImGui_Selectable(ctx, "Mono from ch " .. (start_ch + 1)) then
        R.Undo_BeginBlock()
        local result = clip_mod.cascade(track_ptrs, descriptor.category, descriptor.idx, start_ch, 1, routing)
        R.Undo_EndBlock("Nexus: Cascade mono", -1)
        invalidate_routing(state)
        flash(state, #result.clamped > 0
          and ("Cascade: " .. #result.clamped .. " clamped")
          or ("Cascaded mono x" .. result.total))
      end
      if R.ImGui_Selectable(ctx, "Stereo from ch " .. (start_ch + 1)) then
        R.Undo_BeginBlock()
        local result = clip_mod.cascade(track_ptrs, descriptor.category, descriptor.idx, start_ch, 2, routing)
        R.Undo_EndBlock("Nexus: Cascade stereo", -1)
        invalidate_routing(state)
        flash(state, #result.clamped > 0
          and ("Cascade: " .. #result.clamped .. " clamped")
          or ("Cascaded stereo x" .. result.total))
      end
    end
    R.ImGui_EndCombo(ctx)
  end
  R.ImGui_PopStyleColor(ctx, 6)
  R.ImGui_PopItemWidth(ctx)
  R.ImGui_SameLine(ctx, 0, 8)

  -- Dest start channel combo. HW OUTS mode omits this dropdown: the
  -- destination is already self-describing in the peer-name pill via
  -- GetOutputChannelName, matching REAPER's native hardware-output strip
  -- (which encodes the dest as a header label, not a second dropdown).
  if not is_hw then
    R.ImGui_PushItemWidth(ctx, 52)
    push_combo_pill(ctx)
    local dst_label
    if src_cnt <= 1 then
      dst_label = tostring(dst_off + 1)
    else
      dst_label = (dst_off + 1) .. "-" .. (dst_off + src_cnt)
    end
    -- Cap by the destination track's actual channel count.
    local dst_cap = descriptor.dst_max_nchan or 2
    local max_dst_ch = math.max(1, dst_cap - src_cnt + 1)
    if R.ImGui_BeginCombo(ctx, "##dch_" .. uid, center_label(dst_label)) then
      for ch = 1, max_dst_ch do
        local sel = (ch == dst_off + 1)
        local ch_lbl = src_cnt <= 1 and tostring(ch) or (ch .. "-" .. (ch + src_cnt - 1))
        if R.ImGui_Selectable(ctx, ch_lbl, sel) then
          R.Undo_BeginBlock()
          batch_set_prop(state, track_entry, descriptor,
            "I_DSTCHAN", routing.encode_dst_channels(ch - 1, dst_mono))
          R.Undo_EndBlock("Nexus: Set dest channel", -1)
          invalidate_routing(state)
        end
      end
      R.ImGui_EndCombo(ctx)
    end
    R.ImGui_PopStyleColor(ctx, 6)
    R.ImGui_PopItemWidth(ctx)
    R.ImGui_SameLine(ctx, 0, 8)
  end

  -- Volume slider (live broadcast scoped to matching sends — dest_guid keys the broadcast)
  local vol_bkey = "send_vol:" .. (descriptor.dest_guid or "")
  local live_svol = state._drag_live and state._drag_live[vol_bkey]
  local vol_db_num
  if live_svol and state.nexus_selected[track_entry.guid] then
    vol_db_num = live_svol
  else
    vol_db_num = descriptor.vol <= 0 and -60 or (20 * math.log(descriptor.vol) / _LOG10)
  end
  local vol_changed, vol_new_db = nexus_slider(ctx, "VOL", "##vol_" .. uid,
    vol_db_num, -60.0, 12.0, 0.0, "%.1f dB", 60, state, nil, vol_bkey)
  promote_drag_focus(state, track_entry, "##vol_" .. uid)
  if vol_changed then
    batch_set_prop(state, track_entry, descriptor, "D_VOL",
      routing.db_to_vol(vol_new_db))
    invalidate_routing(state)
  end
  R.ImGui_SameLine(ctx, 0, 8)

  -- Pan slider (display -100..+100, REAPER stores -1..+1)
  local pan_bkey = "send_pan:" .. (descriptor.dest_guid or "")
  local live_span = state._drag_live and state._drag_live[pan_bkey]
  local pan_display
  if live_span and state.nexus_selected[track_entry.guid] then
    pan_display = live_span
  else
    pan_display = descriptor.pan * 100
  end
  local pan_changed, pan_new = nexus_slider(ctx, "PAN", "##pan_" .. uid,
    pan_display, -100.0, 100.0, 0.0, "", 60, state,
    function(v) return routing.format_pan(v / 100) end, pan_bkey)
  promote_drag_focus(state, track_entry, "##pan_" .. uid)
  if pan_changed then
    batch_set_prop(state, track_entry, descriptor, "D_PAN", pan_new / 100)
    invalidate_routing(state)
  end
  R.ImGui_SameLine(ctx, 0, 8)

  -- Mode cycle (Post / Pre-FX / Post-FX) -- three-state color scheme,
  -- matching Vortex FREE/UNIQ/LOCK semantics.
  local mode_label = routing.MODE_LABELS[descriptor.mode] or "Post"
  local mc = SEND_MODE_COL[descriptor.mode] or SEND_MODE_COL[0]
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        mc[1])
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), mc[2])
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  mc[3])
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          mc[4])
  if R.ImGui_Button(ctx, mode_label .. "##smode_" .. track_entry.guid .. "_" .. row_idx, 55, 0) then
    local next_mode = routing.MODE_CYCLE[descriptor.mode] or 0
    R.Undo_BeginBlock()
    batch_set_prop(state, track_entry, descriptor, "I_SENDMODE", next_mode)
    R.Undo_EndBlock("Nexus: Cycle send mode", -1)
    invalidate_routing(state)
  end
  R.ImGui_PopStyleColor(ctx, 4)
  R.ImGui_SameLine(ctx, 0, 8)

  -- Delete button — ghost style. Transparent bg, muted X at rest, coral tint on hover.
  -- Delete button -- inactive-pill style (PANEL_TOP bg + teal X) matching
  -- M/Ø/Mono inactive. Hover flips to destructive coral + black.
  -- ImGui has no Col_TextHovered, so we pre-probe the predicted button rect
  -- with IsMouseHoveringRect and swap Col_Text before rendering.
  local _del_cx, _del_cy = R.ImGui_GetCursorScreenPos(ctx)
  local _del_h = R.ImGui_GetFrameHeight(ctx)
  local _del_hover = R.ImGui_IsMouseHoveringRect(ctx, _del_cx, _del_cy, _del_cx + 22, _del_cy + _del_h)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        SC.PANEL_TOP)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), SC.TERTIARY)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  SC.TERTIARY_AC)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          _del_hover and SC.WINDOW or SC.PRIMARY)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(),        0)
  if R.ImGui_Button(ctx, "X##del_" .. track_entry.guid .. "_" .. row_idx, 22, 0) then
    -- If this row is part of a multi-row selection, X deletes the whole
    -- set (same semantics as Delete key + context menu). Otherwise single.
    local _xrk = row_sel_key(track_entry, descriptor)
    local _xn = 0
    if state.row_selected and state.row_selected[_xrk] then
      for _ in pairs(state.row_selected) do _xn = _xn + 1 end
    end
    if _xn >= 2 then
      delete_selected_rows(state)
    else
      R.Undo_BeginBlock()
      routing.remove_send(track_entry.ptr, descriptor.category, descriptor.idx)
      R.Undo_EndBlock("Nexus: Remove routing", -1)
      invalidate_routing(state)
    end
  end
  R.ImGui_PopStyleColor(ctx, 5)
  if R.ImGui_IsItemHovered(ctx) then R.ImGui_SetTooltip(ctx, "Remove") end
  R.ImGui_PopStyleColor(ctx, 1)  -- row-wide text color
  if _row_dimmed then R.ImGui_PopStyleVar(ctx, 1) end
  if _row_font then R.ImGui_PopFont(ctx) end
end

-- ── Render: Track Header ──────────────────────────────────────────

local function render_track_header(ctx, state, track_entry)
  local dl = R.ImGui_GetWindowDrawList(ctx)
  local cx, cy = R.ImGui_GetCursorScreenPos(ctx)
  local avail_w = R.ImGui_GetContentRegionAvail(ctx)

  -- Background (teal tint if Nexus-selected) — track-level selection, header only.
  -- Header stays neutral grey regardless of Nexus selection -- the blocky
  -- teal fill read as too heavy; subtler selection affordance TBD.
  R.ImGui_DrawList_AddRectFilled(dl, cx, cy, cx + avail_w, cy + CONFIG.row_h, SC.PANEL_HIGH)

  -- Invisible click selector covers the whole header row. Must run before
  -- visible widgets so their overlap-allow click-through semantics line up.
  track_click_selector(ctx, state, track_entry, 0, cx, cy, avail_w)

  -- Right-click anywhere on the header row opens the context menu. Using
  -- explicit OpenPopup + BeginPopup (rather than BeginPopupContextItem on
  -- the name InputText) so the trigger area matches the full header width.
  if R.ImGui_IsItemClicked(ctx, 1) then
    R.ImGui_OpenPopup(ctx, "##hdr_ctx_" .. track_entry.guid)
  end

  local font_b = temper_theme and temper_theme.font_bold
  if font_b then R.ImGui_PushFont(ctx, font_b, 13) end

  -- Vertical centering for widgets drawn on top of the invisible button.
  local _frame_h = R.ImGui_GetFrameHeight(ctx)
  local _v_off = math.floor((CONFIG.row_h - _frame_h) * 0.5 + 0.5)
  R.ImGui_SetCursorScreenPos(ctx, cx + 4, cy + _v_off)

  -- Collapse/expand caret.
  --   - Teal when the track has entries in the current mode (sends/receives/hw_outs),
  --     muted grey when empty -- a cheap "something to see here" signal.
  --   - Collapsed + expanded glyphs are the SAME weight (▶ / ▼) so the
  --     collapsed state doesn't visually shrink the track header.
  local is_collapsed = state.collapsed[track_entry.guid]
  local _data = get_cached_routing(state, track_entry)
  local _mode_list = _data and _data[state.mode] or nil
  local _has_entries = _mode_list and #_mode_list > 0
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(), 0)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), SC.HOVER_LIST)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(), SC.ACTIVE_DARK)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), _has_entries and SC.PRIMARY or SC.TEXT_OFF)
  local arrow = is_collapsed and "\xe2\x96\xb6" or "\xe2\x96\xbc"
  R.ImGui_SetNextItemAllowOverlap(ctx)
  if R.ImGui_Button(ctx, arrow .. "##col_" .. track_entry.guid, 16, 0) then
    state.collapsed[track_entry.guid] = not is_collapsed or nil
    state._collapsed_gen = state._collapsed_gen + 1
  end
  R.ImGui_PopStyleColor(ctx, 4)
  R.ImGui_SameLine(ctx, 0, 4)

  -- Track index prefix -- sits left of the editable name. Goes teal when
  -- the track is Nexus-selected so the "this is the target" cue on the
  -- name carries left into the index column too.
  local _hdr_sel = state.nexus_selected and state.nexus_selected[track_entry.guid]
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), _hdr_sel and SC.PRIMARY or SC.TEXT_MUTED)
  R.ImGui_Text(ctx, tostring(track_entry.index))
  R.ImGui_PopStyleColor(ctx, 1)
  R.ImGui_SameLine(ctx, 0, 6)

  -- Track name -- editable InputText with transparent FrameBg. Clicking the
  -- name both focuses it for rename (ImGui widget) AND registers a click on
  -- the invisible button behind (track-level selection).
  R.ImGui_SetNextItemAllowOverlap(ctx)
  render_track_name(ctx, state, track_entry, CONFIG.header_name_w)

  -- Header right-click menu body (opened by the full-row IsItemClicked
  -- check above). Expand / Collapse all + Set channels...
  if R.ImGui_BeginPopup(ctx, "##hdr_ctx_" .. track_entry.guid) then
    if R.ImGui_Selectable(ctx, "Expand All") then
      state.collapsed = {}
      state._collapsed_gen = state._collapsed_gen + 1
    end
    if R.ImGui_Selectable(ctx, "Collapse All") then
      for _, t in ipairs(state._visible_tracks or {}) do
        state.collapsed[t.guid] = true
      end
      state._collapsed_gen = state._collapsed_gen + 1
    end
    R.ImGui_Separator(ctx)
    if R.ImGui_Selectable(ctx, "Set channels...") then
      state._ch_edit_for = track_entry
      state._ch_edit_val = track_entry.nchan
    end
    R.ImGui_EndPopup(ctx)
  end

  -- Channel count (right-aligned bold text) — only in non-parent modes.
  -- Double-click opens the Set-channels popup (same entry point as the
  -- header right-click menu item, so there are two ways to trigger it).
  if state.mode ~= "parent" then
    R.ImGui_SameLine(ctx)
    local ch_text = track_entry.nchan .. " CH"
    local ch_w = R.ImGui_CalcTextSize(ctx, ch_text)
    local right_edge = avail_w - 52  -- leave room for ADD pill
    R.ImGui_SetCursorPosX(ctx, right_edge - ch_w)
    local _ch_hit_x, _ch_hit_y = R.ImGui_GetCursorScreenPos(ctx)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.TEXT_ON)
    R.ImGui_Text(ctx, ch_text)
    R.ImGui_PopStyleColor(ctx, 1)
    -- Manual hit test against the text's screen rect. The row's invisible
    -- click selector sits underneath and breaks IsItemHovered for the Text
    -- widget, so we query mouse position + double-click directly. Full row
    -- height as the target so the click zone is finger-friendly.
    if R.ImGui_IsMouseHoveringRect(ctx, _ch_hit_x, cy,
                                        _ch_hit_x + ch_w, cy + CONFIG.row_h)
        and R.ImGui_IsMouseDoubleClicked(ctx, 0) then
      state._ch_edit_for = track_entry
      state._ch_edit_val = track_entry.nchan
    end
  end

  if font_b then R.ImGui_PopFont(ctx) end

  -- ADD pill — mode-aware tooltip. Hidden in parent mode.
  if state.mode ~= "parent" then
    R.ImGui_SameLine(ctx, 0, 8)
    if font_b then R.ImGui_PushFont(ctx, font_b, 13) end
    push_pill(ctx)
    R.ImGui_SetNextItemAllowOverlap(ctx)
    if R.ImGui_Button(ctx, "ADD##add_" .. track_entry.guid, 44, 0) then
      state.add_send_for = track_entry
    end
    R.ImGui_PopStyleColor(ctx, 5)
    if R.ImGui_IsItemHovered(ctx) then
      local tip
      if state.mode == "sends"    then tip = "Add send to this track"
      elseif state.mode == "receives" then tip = "Add receive to this track"
      else                              tip = "Add hardware output"
      end
      R.ImGui_SetTooltip(ctx, tip)
    end
    if font_b then R.ImGui_PopFont(ctx) end
  end

end

-- ── Render: Parent Row ────────────────────────────────────────────

local function render_parent_row(ctx, state, track_entry, parent_data, row_idx)
  local dl = R.ImGui_GetWindowDrawList(ctx)
  local cx, cy = R.ImGui_GetCursorScreenPos(ctx)
  local avail_w = R.ImGui_GetContentRegionAvail(ctx) - 4  -- trim 4px from right end of row
  local _row_font = temper_theme and temper_theme.font_bold
  if _row_font then R.ImGui_PushFont(ctx, _row_font, 13) end

  -- Row background: alternating brighter grey (Vortex-style) + pin + selection + hover
  local is_nexus_sel = state.nexus_selected[track_entry.guid]
  local is_pinned = is_track_pinned(state, track_entry.guid)
  local row_bg = (row_idx % 2 == 0) and SC.PANEL_HIGH or SC.PANEL
  R.ImGui_DrawList_AddRectFilled(dl, cx, cy, cx + avail_w, cy + CONFIG.row_h, row_bg)
  if is_pinned then
    R.ImGui_DrawList_AddRectFilled(dl, cx, cy, cx + avail_w, cy + CONFIG.row_h, ROW_PIN_BG)
  end
  if is_nexus_sel then
    R.ImGui_DrawList_AddRectFilled(dl, cx, cy, cx + avail_w, cy + CONFIG.row_h, ROW_SEL_BG)
  end
  local mx, my = R.ImGui_GetMousePos(ctx)
  if mx >= cx and mx <= cx + avail_w and my >= cy and my <= cy + CONFIG.row_h then
    R.ImGui_DrawList_AddRectFilled(dl, cx, cy, cx + avail_w, cy + CONFIG.row_h, SC.HOVER_LIST)
  end

  -- Parent row has one entry per track → track-level click selection is correct.
  track_click_selector(ctx, state, track_entry, row_idx, cx, cy, avail_w)

  -- Vertical centering: pixel-exact offset based on actual frame height
  local _frame_h = R.ImGui_GetFrameHeight(ctx)
  local _v_off = math.floor((CONFIG.row_h - _frame_h) * 0.5 + 0.5)
  -- Left gutter so controls don't hug the window edge
  R.ImGui_SetCursorScreenPos(ctx, cx + 8, cy + _v_off)

  -- Row-wide text color
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.TEXT_ON)

  -- Enabled toggle (ON/OFF) — pill style when ON
  if parent_data.enabled then
    push_pill(ctx)
  else
    push_btn(ctx, SC.PANEL, SC.HOVER_INACTIVE, SC.ACTIVE_DARKER, SC.TEXT_OFF)
  end
  local on_label = parent_data.enabled and "ON" or "OFF"
  if R.ImGui_Button(ctx, on_label .. "##parent_en_" .. track_entry.guid, 36, 0) then
    R.Undo_BeginBlock()
    batch_set_parent(state, track_entry, "B_MAINSEND", not parent_data.enabled)
    R.Undo_EndBlock("Nexus: Toggle parent send", -1)
    invalidate_routing(state)
  end
  R.ImGui_PopStyleColor(ctx, 5)  -- push_btn
  R.ImGui_SameLine(ctx, 0, 8)

  -- Track name
  render_track_name(ctx, state, track_entry, CONFIG.parent_name_w)
  R.ImGui_SameLine(ctx, 0, 16)

  -- Volume slider (live broadcast to other Nexus-selected rows during drag)
  local live_pvol = state._drag_live and state._drag_live["parent_vol"]
  local pvol_db
  if live_pvol and state.nexus_selected[track_entry.guid] then
    pvol_db = live_pvol
  else
    pvol_db = parent_data.vol <= 0 and -60 or (20 * math.log(parent_data.vol) / _LOG10)
  end
  local vol_changed, pvol_new = nexus_slider(ctx, "VOL", "##pvol_" .. track_entry.guid,
    pvol_db, -60.0, 12.0, 0.0, "%.1f dB", 60, state, nil, "parent_vol")
  promote_drag_focus(state, track_entry, "##pvol_" .. track_entry.guid)
  if vol_changed then
    batch_set_parent(state, track_entry, "D_VOL", routing.db_to_vol(pvol_new))
    invalidate_routing(state)
  end
  R.ImGui_SameLine(ctx, 0, 8)

  -- Pan slider (display -100..+100, REAPER stores -1..+1)
  local live_ppan = state._drag_live and state._drag_live["parent_pan"]
  local ppan_display
  if live_ppan and state.nexus_selected[track_entry.guid] then
    ppan_display = live_ppan
  else
    ppan_display = parent_data.pan * 100
  end
  local pan_changed, pan_new = nexus_slider(ctx, "PAN", "##ppan_" .. track_entry.guid,
    ppan_display, -100.0, 100.0, 0.0, "", 60, state,
    function(v) return routing.format_pan(v / 100) end, "parent_pan")
  promote_drag_focus(state, track_entry, "##ppan_" .. track_entry.guid)
  if pan_changed then
    batch_set_parent(state, track_entry, "D_PAN", pan_new / 100)
    invalidate_routing(state)
  end
  R.ImGui_SameLine(ctx, 0, 12)

  -- Send channels combo (extra gap to separate from pan knob)
  -- "All" means use track channels, but clamped to what the dest track can receive
  local is_all = parent_data.nchan_send == 0
  local raw_nchan = is_all and track_entry.nchan or parent_data.nchan_send
  local eff_nchan = math.min(raw_nchan, parent_data.dest_nchan or 64)
  R.ImGui_PushItemWidth(ctx, 52)
  push_combo_pill(ctx)
  local psch_label = is_all and "All" or (eff_nchan == 1 and "1" or ("1-" .. eff_nchan))
  if R.ImGui_BeginCombo(ctx, "##psch_" .. track_entry.guid, center_label(psch_label)) then
    -- "All" option (sets nchan_send to 0)
    if R.ImGui_Selectable(ctx, "All", is_all) then
      R.Undo_BeginBlock()
      batch_set_parent(state, track_entry, "C_MAINSEND_NCH", 0)
      R.Undo_EndBlock("Nexus: Set parent send channels", -1)
      invalidate_routing(state)
    end
    for _, n in ipairs({1, 2, 4, 6, 8, 10, 12, 16, 24, 32, 64}) do
      if n <= track_entry.nchan then
        local sel = (not is_all and n == eff_nchan)
        local n_lbl = n == 1 and "1" or ("1-" .. n)
        if R.ImGui_Selectable(ctx, n_lbl, sel) then
          R.Undo_BeginBlock()
          batch_set_parent(state, track_entry, "C_MAINSEND_NCH", n)
          R.Undo_EndBlock("Nexus: Set parent send channels", -1)
          invalidate_routing(state)
        end
      end
    end
    R.ImGui_EndCombo(ctx)
  end
  R.ImGui_PopStyleColor(ctx, 6)
  R.ImGui_PopItemWidth(ctx)
  R.ImGui_SameLine(ctx, 0, 8)

  -- Dest start channel combo (limit to positions where range fits)
  local dst_start = parent_data.ch_offset + 1
  local pdst_label = eff_nchan <= 1 and tostring(dst_start)
    or (dst_start .. "-" .. (dst_start + eff_nchan - 1))
  R.ImGui_PushItemWidth(ctx, 52)
  push_combo_pill(ctx)
  -- Cap by what the parent/master actually has. E.g. 6-ch parent + 6-ch range = only position 1 fits.
  local dest_cap = parent_data.dest_nchan or 2
  local max_dst = math.max(1, dest_cap - eff_nchan + 1)
  if R.ImGui_BeginCombo(ctx, "##pdch_" .. track_entry.guid, center_label(pdst_label)) then
    for ch = 1, max_dst do
      local sel = (ch == dst_start)
      local pch_lbl = eff_nchan <= 1 and tostring(ch) or (ch .. "-" .. (ch + eff_nchan - 1))
      if R.ImGui_Selectable(ctx, pch_lbl, sel) then
        R.Undo_BeginBlock()
        batch_set_parent(state, track_entry, "C_MAINSEND_OFFS", ch - 1)
        R.Undo_EndBlock("Nexus: Set parent dest offset", -1)
        invalidate_routing(state)
      end
    end
    R.ImGui_EndCombo(ctx)
  end
  R.ImGui_PopStyleColor(ctx, 6)
  R.ImGui_PopItemWidth(ctx)
  R.ImGui_SameLine(ctx, 0, 8)

  -- Track channels combo (editable, on the row beside other controls)
  R.ImGui_PushItemWidth(ctx, 52)
  push_combo_pill(ctx)
  if R.ImGui_BeginCombo(ctx, "##trch_" .. track_entry.guid, center_label(tostring(track_entry.nchan))) then
    for _, n in ipairs({2, 4, 6, 8, 10, 12, 16, 24, 32, 64}) do
      local sel = (n == track_entry.nchan)
      if R.ImGui_Selectable(ctx, tostring(n), sel) then
        R.Undo_BeginBlock()
        batch_set_track_nchan(state, track_entry, n)
        R.Undo_EndBlock("Nexus: Set track channels", -1)
        invalidate_routing(state)
      end
    end
    R.ImGui_EndCombo(ctx)
  end
  R.ImGui_PopStyleColor(ctx, 6)
  R.ImGui_PopItemWidth(ctx)
  R.ImGui_PopStyleColor(ctx, 1)  -- row-wide text color
  if _row_font then R.ImGui_PopFont(ctx) end
end

-- ── Render: Content ───────────────────────────────────────────────

local function render_content(ctx, state)
  local tracks = get_selected_tracks(state)
  -- Expose to track_click_selector for shift-click range selection
  state._visible_tracks = tracks
  if #tracks == 0 then
    local font_b = temper_theme and temper_theme.font_bold
    if font_b then R.ImGui_PushFont(ctx, font_b, 13) end
    local avail_w = R.ImGui_GetContentRegionAvail(ctx)
    local txt = "Select tracks in REAPER"
    local tw = R.ImGui_CalcTextSize(ctx, txt)
    R.ImGui_SetCursorPosX(ctx, (avail_w - tw) * 0.5)
    R.ImGui_SetCursorPosY(ctx, R.ImGui_GetCursorPosY(ctx) + 80)
    R.ImGui_TextColored(ctx, SC.PRIMARY, txt)
    if font_b then R.ImGui_PopFont(ctx) end
    state.track_count = 0
    return
  end

  check_cache(state)

  -- Auto-collapse: first time we see >20 tracks, collapse all
  if #tracks > 20 and not state._auto_collapsed and state.mode ~= "parent" then
    for _, t in ipairs(tracks) do state.collapsed[t.guid] = true end
    state._auto_collapsed = true
    state._collapsed_gen = state._collapsed_gen + 1
  end

  local filter = state.filter_committed:lower()

  -- Memo key -- the flat list depends on: routing invalidation generation,
  -- mode, filter (text + chips + active-only), collapsed set version, and the
  -- identity (count + guid order) of the visible track set. Any change to
  -- these requires a rebuild; otherwise we reuse last frame's tables and skip
  -- ~500 allocations per frame on large sessions.
  local fs = state.filter_state
  local _chip_bits = (fs.mute   and 1  or 0)
                   + (fs.phase  and 2  or 0)
                   + (fs.mono   and 4  or 0)
                   + (fs.pre    and 8  or 0)
                   + (fs.postfx and 16 or 0)
  local _track_digest = #tracks > 0 and (tracks[1].guid .. "|" .. tracks[#tracks].guid .. "|" .. #tracks) or "0"
  local memo_key = table.concat({
    state._routing_gen, state._collapsed_gen, state.mode,
    state.filter_active_only and 1 or 0, _chip_bits,
    filter, _track_digest,
  }, "\0")

  if state._memo_key == memo_key and state._memo_flat then
    -- Cache hit -- reuse prior frame's flat list + row bookkeeping verbatim.
    local flat = state._memo_flat
    state._visible_rows = state._memo_visible_rows
    state._row_lookup   = state._memo_row_lookup
    local _lc = state._clipper
    R.ImGui_ListClipper_Begin(_lc, #flat, CONFIG.row_h)
    while R.ImGui_ListClipper_Step(_lc) do
      local disp_start, disp_end = R.ImGui_ListClipper_GetDisplayRange(_lc)
      for ri = disp_start + 1, disp_end do
        local row = flat[ri]
        if row[1] == "parent" then
          render_parent_row(ctx, state, row[2], row[5], row[4])
        elseif row[1] == "header" then
          render_track_header(ctx, state, row[2])
        elseif row[1] == "send" then
          render_send_row(ctx, state, row[2], row[3], row[4])
        end
      end
    end
    state.track_count = #tracks
    return
  end

  local visible_count = 0

  -- Build flat row list for ListClipper virtualization.
  -- Each entry: { kind, track_entry [, descriptor, row_idx, parent_data] }
  -- kind: "parent" | "header" | "send"
  local flat = {}
  -- Row-level selection bookkeeping:
  --   _visible_rows: ordered list of row_sel_keys for shift-range resolution
  --   _row_lookup: reverse map row_sel_key -> { track_entry, descriptor }
  --               so batch_set_prop can resolve selection entries back to pairs
  state._visible_rows = {}
  state._row_lookup   = {}
  for _, track_entry in ipairs(tracks) do
    local data = get_cached_routing(state, track_entry)

    local descriptors
    if state.mode == "sends" then descriptors = data.sends
    elseif state.mode == "receives" then descriptors = data.receives
    elseif state.mode == "hw_outs" then descriptors = data.hw_outs
    end

    -- Filter by text
    if filter ~= "" then
      local match = false
      if track_entry.name:lower():find(filter, 1, true) then
        match = true
      end
      if not match and descriptors then
        for _, d in ipairs(descriptors) do
          if d.dest_name:lower():find(filter, 1, true) then
            match = true; break
          end
        end
      end
      if not match then goto continue_track end
    end

    -- State-chip filter (mute / mono / phase / pre / postfx). Compounds with
    -- AND. Filtered descriptors feed the per-track render below; tracks with
    -- zero passing descriptors fall through to the active-only check.
    if state.mode ~= "parent" and _any_state_filter_active(state.filter_state) then
      local kept = {}
      for _, d in ipairs(descriptors or {}) do
        if _descriptor_passes_state_filter(d, state.filter_state) then
          kept[#kept + 1] = d
        end
      end
      descriptors = kept
    end

    -- Active-only filter
    if state.filter_active_only and state.mode ~= "parent" then
      if not descriptors or #descriptors == 0 then goto continue_track end
    end

    visible_count = visible_count + 1

    if state.mode == "parent" then
      flat[#flat + 1] = { "parent", track_entry, nil, 0, data.parent }
    elseif state.collapsed[track_entry.guid] or not descriptors or #descriptors == 0 then
      flat[#flat + 1] = { "header", track_entry }
    else
      flat[#flat + 1] = { "header", track_entry }
      for i, desc in ipairs(descriptors) do
        flat[#flat + 1] = { "send", track_entry, desc, i }
        local rk = row_sel_key(track_entry, desc)
        state._visible_rows[#state._visible_rows + 1] = rk
        state._row_lookup[rk] = { track_entry, desc }
      end
    end

    ::continue_track::
  end

  -- Store memo so the next frame can skip the rebuild when inputs are unchanged.
  state._memo_key          = memo_key
  state._memo_flat         = flat
  state._memo_visible_rows = state._visible_rows
  state._memo_row_lookup   = state._row_lookup

  -- Render via ListClipper (only visible rows). The clipper was created
  -- and Attach'd to the context at script init (see entry block below),
  -- so we can safely reuse it each frame from state._clipper.
  local _lc = state._clipper
  R.ImGui_ListClipper_Begin(_lc, #flat, CONFIG.row_h)
  while R.ImGui_ListClipper_Step(_lc) do
    local disp_start, disp_end = R.ImGui_ListClipper_GetDisplayRange(_lc)
    for ri = disp_start + 1, disp_end do  -- 0-indexed -> 1-indexed
      local row = flat[ri]
      if row[1] == "parent" then
        render_parent_row(ctx, state, row[2], row[5], row[4])
      elseif row[1] == "header" then
        render_track_header(ctx, state, row[2])
      elseif row[1] == "send" then
        render_send_row(ctx, state, row[2], row[3], row[4])
      end
    end
  end

  state.track_count = visible_count
end

-- ── Render: Track Picker Popup ────────────────────────────────────

-- ── Render: Channel Count Popup ──────────────────────────────────
-- Triggered from the track header's right-click context menu ("Set channels...").
-- Applies via batch_set_track_nchan → matches the current batch semantics
-- (Nexus-selected tracks update together, fallback to the single row).

local function render_channel_popup(ctx, state)
  if not state._ch_edit_for then
    state._ch_popup_opened = false
    return
  end
  -- OpenPopup fires ONCE on transition; same anti-stick fix as the track
  -- picker. Calling it every frame pins the popup to the cursor because
  -- ImGui keeps reopening it the frame it tries to close itself.
  if not state._ch_popup_opened then
    R.ImGui_OpenPopup(ctx, "##ch_edit_nexus")
    state._ch_popup_opened = true
  end
  if R.ImGui_BeginPopup(ctx, "##ch_edit_nexus") then
    local track_entry = state._ch_edit_for
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.PRIMARY)
    R.ImGui_Text(ctx, "Set channels")
    R.ImGui_PopStyleColor(ctx, 1)
    R.ImGui_Separator(ctx)
    R.ImGui_SetNextItemWidth(ctx, 80)
    local changed, new_val = R.ImGui_InputInt(ctx, "##ch_edit_input", state._ch_edit_val or track_entry.nchan, 2, 2)
    if changed then state._ch_edit_val = new_val end
    R.ImGui_SameLine(ctx, 0, 8)
    push_pill(ctx)
    if R.ImGui_Button(ctx, "Apply##ch_apply", 60, 0) then
      local v = state._ch_edit_val or track_entry.nchan
      if v and v >= 2 and v <= 64 then
        if v % 2 ~= 0 then v = v + 1 end
        R.Undo_BeginBlock()
        batch_set_track_nchan(state, track_entry, v)
        R.Undo_EndBlock("Nexus: Set track channels", -1)
        invalidate_routing(state)
      end
      state._ch_edit_for     = nil
      state._ch_edit_val     = nil
      state._ch_popup_opened = false
      R.ImGui_CloseCurrentPopup(ctx)
    end
    R.ImGui_PopStyleColor(ctx, 5)
    R.ImGui_EndPopup(ctx)
  else
    state._ch_edit_for     = nil
    state._ch_edit_val     = nil
    state._ch_popup_opened = false
  end
end

local function render_track_picker(ctx, state)
  if not state.add_send_for then
    state._picker_opened = false
    state._picker_filter = nil
    return
  end

  -- OpenPopup runs ONCE on transition into the picker. Calling it every
  -- frame re-opens the popup the same frame ImGui closes it from a
  -- click-outside, which made the picker sticky.
  if not state._picker_opened then
    R.ImGui_OpenPopup(ctx, "##track_picker_nexus")
    state._picker_opened = true
    state._picker_filter = ""
  end

  R.ImGui_SetNextWindowSizeConstraints(ctx, 280, 120, 360, 420)
  if R.ImGui_BeginPopup(ctx, "##track_picker_nexus") then
    local source = state.add_send_for
    local is_hw = (state.mode == "hw_outs")
    local header
    if is_hw then
      header = "Add hardware output:"
    elseif state.mode == "receives" then
      header = "Receive from:"
    else
      header = "Send to:"
    end

    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.PRIMARY)
    R.ImGui_Text(ctx, header)
    R.ImGui_PopStyleColor(ctx, 1)
    R.ImGui_Separator(ctx)

    -- Filter input -- search by track name or number (or output name in hw_outs).
    R.ImGui_SetNextItemWidth(ctx, -1)
    local _, new_filter = R.ImGui_InputTextWithHint(ctx,
      "##picker_filter", "Filter...", state._picker_filter or "")
    state._picker_filter = new_filter
    local filter_lc = (new_filter or ""):lower()

    -- Scrollable list region -- bounded height so the popup never grows
    -- unbounded regardless of project track count.
    if R.ImGui_BeginChild(ctx, "##picker_list", 0, 300,
        R.ImGui_ChildFlags_None and R.ImGui_ChildFlags_None() or 0,
        R.ImGui_WindowFlags_None and R.ImGui_WindowFlags_None() or 0) then
      if is_hw then
        -- Hardware output channels: enumerate REAPER's audio outputs. Pair
        -- picker semantics with native "Add new hardware output..." menu.
        local num_outs = R.GetNumAudioOutputs() or 0
        for idx = 0, num_outs - 1 do
          local label = _hw_label(idx, 1)
          local visible = filter_lc == "" or label:lower():find(filter_lc, 1, true)
          if visible then
            if R.ImGui_Selectable(ctx, label .. "##pickhw_" .. idx) then
              _create_hw_out(state, source.ptr, idx)
              state.add_send_for   = nil
              state._picker_opened = false
              state._picker_filter = nil
              R.ImGui_CloseCurrentPopup(ctx)
            end
          end
        end
      else
        local all_tracks = routing.get_all_tracks()
        for _, t in ipairs(all_tracks) do
          if t.guid ~= source.guid then
            local _raw = t.name ~= "" and t.name or ("Track " .. t.index)
            local label = t.index .. " \xc2\xb7 " .. _raw
            local visible = filter_lc == ""
              or _raw:lower():find(filter_lc, 1, true)
              or tostring(t.index):find(filter_lc, 1, true)
            if visible then
              if R.ImGui_Selectable(ctx, label .. "##pick_" .. t.guid) then
                R.Undo_BeginBlock()
                if state.mode == "receives" then
                  routing.create_send(t.ptr, source.ptr)
                else
                  routing.create_send(source.ptr, t.ptr)
                end
                R.Undo_EndBlock("Nexus: Create " .. (state.mode == "receives" and "receive" or "send"), -1)
                invalidate_routing(state)
                state.add_send_for = nil
                state._picker_opened = false
                state._picker_filter = nil
                R.ImGui_CloseCurrentPopup(ctx)
              end
            end
          end
        end
      end
      R.ImGui_EndChild(ctx)
    end

    R.ImGui_EndPopup(ctx)
  else
    -- Popup was closed (click-outside, Esc, selection). Reset state so the
    -- next ADD click opens a fresh picker.
    state.add_send_for = nil
    state._picker_opened = false
    state._picker_filter = nil
  end
end


-- ── Render: Footer ────────────────────────────────────────────────

local function render_footer(ctx, state)
  local win_h = R.ImGui_GetWindowHeight(ctx)
  R.ImGui_SetCursorPosY(ctx, win_h - CONFIG.footer_h - 4)

  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.TEXT_MUTED)

  -- Left: flash message OR clipboard scope pills
  local now = R.time_precise()
  if state.flash_msg and state.flash_until and now < state.flash_until then
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.PRIMARY)
    R.ImGui_Text(ctx, state.flash_msg)
    R.ImGui_PopStyleColor(ctx, 1)
  elseif state.clipboard then
    local scope = state.clipboard.scope
    local pills = {
      { key = "sends",    label = "Sends",  data = state.clipboard.sends },
      { key = "hw_outs",  label = "HW",     data = state.clipboard.hw_outs },
      { key = "receives", label = "Recv",   data = state.clipboard.receives },
      { key = "parent",   label = "Parent", data = nil },
    }
    for pi, pill in ipairs(pills) do
      local active = scope[pill.key]
      local count = pill.data and #pill.data or nil
      local text = count and (pill.label .. " (" .. count .. ")") or pill.label
      if active then
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(), SC.PRIMARY_AC)
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), SC.PRIMARY_HV)
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(), SC.PRIMARY)
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.TEXT_ON)
      else
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(), SC.PANEL_TOP)
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), SC.HOVER_LIST)
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(), SC.ACTIVE_DARK)
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.TEXT_MUTED)
      end
      if R.ImGui_SmallButton(ctx, text .. "##scope_" .. pill.key) then
        scope[pill.key] = not scope[pill.key]
      end
      R.ImGui_PopStyleColor(ctx, 4)
      if pi < #pills then R.ImGui_SameLine(ctx) end
    end
    R.ImGui_SameLine(ctx)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.TEXT_MUTED)
    R.ImGui_Text(ctx, "from \"" .. state.clipboard.source_name .. "\"")
    R.ImGui_PopStyleColor(ctx, 1)
  else
    R.ImGui_Text(ctx, "")
  end

  -- Right: track count
  R.ImGui_SameLine(ctx)
  local count_text = (state.track_count or 0) .. " track" .. ((state.track_count or 0) ~= 1 and "s" or "")
  local tw = R.ImGui_CalcTextSize(ctx, count_text)
  local avail_w = R.ImGui_GetContentRegionAvail(ctx)
  R.ImGui_SetCursorPosX(ctx, R.ImGui_GetCursorPosX(ctx) + avail_w - tw)
  R.ImGui_Text(ctx, count_text)

  R.ImGui_PopStyleColor(ctx, 1)  -- TEXT_MUTED
end

-- ── Render: Main GUI ──────────────────────────────────────────────

local render_gui

render_gui = function(ctx, state)
  render_title_bar(ctx, state)
  render_toolbar(ctx, state)

  -- Content area (scrollable child)
  local cur_y = R.ImGui_GetCursorPosY(ctx)
  local win_h = R.ImGui_GetWindowHeight(ctx)
  local content_h = win_h - cur_y - CONFIG.footer_h - 8
  -- Guard against transient non-positive size on monitor resolution change:
  -- BeginChild with <=0 height fails to push, then the unconditional
  -- EndChild below asserts (ImGui_EndChild child_window flag check).
  if content_h < 1 then content_h = 1 end

  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ChildBg(), SC.PANEL)
  local showing = R.ImGui_BeginChild(ctx, "##content_area", 0, content_h,
    R.ImGui_ChildFlags_None())
  if showing then
    render_content(ctx, state)
  end
  R.ImGui_EndChild(ctx)  -- ALWAYS called regardless of showing
  R.ImGui_PopStyleColor(ctx, 1)

  render_track_picker(ctx, state)
  render_channel_popup(ctx, state)

  render_footer(ctx, state)
end

-- ── Instance guard ────────────────────────────────────────────────

local function check_instance_guard()
  local ts_str = R.GetExtState(_NS, "instance_ts")
  if ts_str ~= "" then
    local ts = tonumber(ts_str)
    if ts and (R.time_precise() - ts) < CONFIG.instance_guard_timeout_sec then
      R.ShowMessageBox("Temper Nexus is already running.", "Temper Nexus", 0)
      return false
    end
  end
  return true
end

-- ── Entry point ───────────────────────────────────────────────────
do
  if not check_instance_guard() then return end

  -- Guard ReaImGui's short-lived-resource rate limit (see Temper_Vortex.lua).
  local _ctx_ok, ctx = pcall(R.ImGui_CreateContext, "Temper Nexus##nexus")
  if not _ctx_ok or not ctx then
    reaper.ShowMessageBox(
      "Temper Nexus could not start because ReaImGui is still cleaning " ..
      "up from a previous instance.\n\n" ..
      "Close any existing Nexus window, wait ~15 seconds, then try again.\n" ..
      "If it keeps happening, restart REAPER.",
      "Temper Nexus", 0)
    return
  end
  -- ListClipper must be Attach'd to the context to persist across frames;
  -- without it ReaImGui treats it as short-lived and invalidates/rate-limits.
  local clipper = R.ImGui_CreateListClipper(ctx)
  R.ImGui_Attach(ctx, clipper)
  if type(temper_theme) == "table" then temper_theme.attach_fonts(ctx) end

  if lic then lic.configure({
    namespace    = "TEMPER_Nexus",
    scope_id     = 0x8,
    display_name = "Nexus",
    buy_url      = "https://www.tempertools.com/scripts/nexus",
  }) end

  local state = init_state(clipper)
  load_settings(state)

  -- ── Action dispatch (rsg_actions framework) ───────────────────
  -- Every key matches a command in actions/manifest.toml [nexus] block
  -- (landing in Task 5). Entries are thin pointers at nexus_actions.* core
  -- functions, which are the same functions render_toolbar dispatches
  -- through for mouse clicks (subset-of-GUI invariant). Each keyboard-
  -- dispatched entry calls _set_flash to give a visible 250ms press-shade
  -- on the corresponding toolbar button, mimicking ImGui's native active
  -- feedback that mouse clicks get for free. Filter chips skip flash
  -- (state-color swap is already the feedback) and row toggles skip flash
  -- (their feedback is the existing flash(state, msg) footer text).
  -- `close` is a framework built-in dispatched by rsg_actions.toggle_window.
  local function _set_flash(k) state._btn_flash[k] = R.time_precise() + _BTN_FLASH_DUR end
  local HANDLERS = {
    cycle_mode           = function() _set_flash("cycle_mode");           nexus_actions.do_cycle_mode(state)        end,
    copy                 = function() _set_flash("copy");                 nexus_actions.do_copy(state)              end,
    paste                = function() _set_flash("paste");                nexus_actions.do_paste(state)             end,
    toggle_pin           = function() _set_flash("toggle_pin");           nexus_actions.toggle_pin(state)           end,
    toggle_active_filter = function() _set_flash("toggle_active_filter"); nexus_actions.toggle_active_filter(state) end,
    toggle_filter_mute   = function() nexus_actions.toggle_filter_mute(state)   end,
    toggle_filter_phase  = function() nexus_actions.toggle_filter_phase(state)  end,
    toggle_filter_mono   = function() nexus_actions.toggle_filter_mono(state)   end,
    toggle_filter_pre    = function() nexus_actions.toggle_filter_pre(state)    end,
    toggle_filter_postfx = function() nexus_actions.toggle_filter_postfx(state) end,
    toggle_row_mute      = function() nexus_actions.toggle_row_mute(state)      end,
    toggle_row_phase     = function() nexus_actions.toggle_row_phase(state)     end,
    toggle_row_mono      = function() nexus_actions.toggle_row_mono(state)      end,
    close                = function() state.should_close = true end,
  }

  -- Testing harness registration: exposes projected state via _harness_dump
  -- command when _TEMPER_HARNESS is set at launch.  Gated, so production
  -- runs skip all of this.  See tests/harness/ for the scenario executor.
  if _TEMPER_HARNESS then
    local _tts_ok, _tts = pcall(dofile, _lib .. "temper_test_state.lua")
    if _tts_ok and type(_tts) == "table" and _tts.register and _tts.dump_to_file then
      _tts.register(_NS, function()
        local sel_count = 0
        for _ in pairs(state.nexus_selected or {}) do sel_count = sel_count + 1 end
        return {
          status          = state.status,
          mode            = state.mode,
          track_count     = state.track_count,
          nexus_sel_count = sel_count,
          pinned          = state.pinned,
          settings_open   = state.settings_open,
          should_close    = state.should_close,
        }
      end)
      HANDLERS._harness_dump = function() _tts.dump_to_file() end
    end
  end

  rsg_actions.clear_pending_on_init(_NS)

  local win_flags = R.ImGui_WindowFlags_NoCollapse()
                  | R.ImGui_WindowFlags_NoTitleBar()
                  | R.ImGui_WindowFlags_NoScrollbar()
                  | R.ImGui_WindowFlags_NoScrollWithMouse()

  local _first_loop = true

  local function loop()
    -- Instance-guard heartbeat -- throttled to once per
    -- CONFIG.instance_guard_heartbeat_sec so we avoid a per-frame string
    -- allocation + ExtState write that served no purpose. Guard timeout
    -- is CONFIG.instance_guard_timeout_sec (2s), so writing every 1s is
    -- still well inside the detection window.
    local _now = R.time_precise()
    if _now - state._last_heartbeat >= CONFIG.instance_guard_heartbeat_sec then
      R.SetExtState(_NS, "instance_ts", tostring(_now), false)
      state._last_heartbeat = _now
    end
    -- rsg_actions framework: heartbeat so stubs know GUI is alive;
    -- poll drains any pending command and runs its handler.
    rsg_actions.heartbeat(_NS)
    local _focus_requested = rsg_actions.poll(_NS, HANDLERS)
    tick_state(state)

    if not _first_loop then
      R.ImGui_SetNextWindowSizeConstraints(ctx,
        CONFIG.min_win_w, CONFIG.min_win_h, 4096, 4096)
    end
    _first_loop = false

    R.ImGui_SetNextWindowSize(ctx, CONFIG.win_w, CONFIG.win_h,
      R.ImGui_Cond_FirstUseEver())

    if _focus_requested then
      R.ImGui_SetNextWindowFocus(ctx)
      if R.APIExists and R.APIExists("JS_Window_SetForeground") then
        local hwnd = R.JS_Window_Find and R.JS_Window_Find("Temper Nexus", true)
        if hwnd then R.JS_Window_SetForeground(hwnd) end
      end
    end

    local n_theme = temper_theme and temper_theme.push(ctx) or 0

    local visible, open = R.ImGui_Begin(ctx, "Temper Nexus##nexus_main", true, win_flags)
    if visible then
      local lic_status = lic and lic.check("NEXUS", ctx)

      if lic_status == "expired" then
        R.ImGui_Spacing(ctx)
        R.ImGui_TextColored(ctx, SC.ERROR_RED, "  Your Nexus trial has expired.")
        R.ImGui_Spacing(ctx)
        R.ImGui_TextDisabled(ctx, "  Purchase a license at tempertools.com to continue.")
        if not lic.is_dialog_open() then lic.open_dialog(ctx) end
        lic.draw_dialog(ctx)
      else
        render_gui(ctx, state)
        -- Intercept Ctrl+Z/Ctrl+Shift+Z so undo works without clicking back to REAPER.
        -- Also intercept Delete for bulk-delete of row-selected sends.
        if R.ImGui_IsWindowFocused(ctx, R.ImGui_FocusedFlags_RootAndChildWindows()) then
          local ctrl = R.ImGui_IsKeyDown(ctx, R.ImGui_Mod_Ctrl())
          local shift = R.ImGui_IsKeyDown(ctx, R.ImGui_Mod_Shift())
          if ctrl and R.ImGui_IsKeyPressed(ctx, R.ImGui_Key_Z()) then
            if shift then R.Undo_DoRedo2(0) else R.Undo_DoUndo2(0) end
            invalidate_routing(state)
          end
          -- Delete -> bulk-delete row-selected sends.
          -- Gate on `not IsAnyItemActive` so the key never fires while a
          -- text input is focused (filter, rename, channel popup, slider
          -- right-click input). state.mode ~= "parent" because PARENT mode
          -- has no per-row selection model.
          if R.ImGui_IsKeyPressed(ctx, R.ImGui_Key_Delete())
              and not R.ImGui_IsAnyItemActive(ctx)
              and state.mode ~= "parent"
              and state.row_selected then
            local _n = 0
            for _ in pairs(state.row_selected) do _n = _n + 1; break end
            if _n >= 1 then delete_selected_rows(state) end
          end
        end
        if lic_status == "trial" then
          local days_left = lic.days_remaining and lic.days_remaining("NEXUS")
          if days_left then
            R.ImGui_SetCursorPos(ctx, R.ImGui_GetWindowWidth(ctx) - 100, 10)
            R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.TERTIARY)
            R.ImGui_Text(ctx, days_left .. "d trial")
            R.ImGui_PopStyleColor(ctx, 1)
          end
        end
        if lic and lic.is_dialog_open() then lic.draw_dialog(ctx) end
      end

      R.ImGui_End(ctx)
    end

    if temper_theme then temper_theme.pop(ctx, n_theme) end

    if open and not state.should_close then
      R.defer(loop)
    else
      save_settings(state)
      R.SetExtState(_NS, "instance_ts", "", false)
    end
  end

  if not _RSG_TEST_MODE then R.defer(loop) end
end
