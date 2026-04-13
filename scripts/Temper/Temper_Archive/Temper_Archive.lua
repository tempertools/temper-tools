-- @description Temper Archive -- Cross-platform project folder archival
-- @version 1.3.1
-- @author Temper Tools
-- @provides
--   [main] Temper_Archive.lua
--   [nomain] lib/rsg_theme.lua
--   [nomain] lib/rsg_sha256.lua
--   [nomain] lib/rsg_license.lua
--   [nomain] lib/rsg_activation_dialog.lua
--   [nomain] lib/rsg_actions.lua
--   [nomain] lib/rsg_platform.lua
--   [nomain] lib/rsg_archive.lua
-- @about
--   Temper Archive scans a source directory of audio project folders,
--   flags each as already-archived / pending / invalid, and sequentially
--   compresses selected folders into .zip files in a destination directory.
--
--   Designed for audio professionals with hundreds of session folders who
--   need safe, selective, OS-aware archival.
--
--   Features:
--   - Input and output folder pickers with persistent paths
--   - Tri-state row indicators: green (archived) / orange (pending) /
--     red (invalid: no .rpp/.ptx/.pts)
--   - Right-click approve to promote red rows for archival
--   - Multi-select with Ctrl/Shift-range
--   - Stop-on-failure queue with per-item stage feedback
--   - Safe cancellation between items; interrupted .part files always
--     cleaned up
--   - Case-insensitive archive identity; auto-suffix for name collisions
--   - Cross-platform via PowerShell Compress-Archive (Windows) or
--     /usr/bin/zip (macOS)
--   - Append-mode log at <OutputDir>/temper_archive.log
--
--   Requires: ReaImGui, js_ReaScriptAPI, SWS (for ExecProcess).

-- ============================================================
-- Dependency checks
-- ============================================================

if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox(
    "Temper Archive requires ReaImGui.\nInstall via ReaPack: Extensions > ReaImGui",
    "Missing Dependency", 0)
  return
end

if not reaper.JS_Dialog_BrowseForFolder then
  reaper.ShowMessageBox(
    "Temper Archive requires js_ReaScriptAPI for the folder picker.\n"
    .. "Install via ReaPack: Extensions > js_ReaScriptAPI",
    "Missing Dependency", 0)
  return
end

if not reaper.ExecProcess then
  reaper.ShowMessageBox(
    "Temper Archive requires the SWS extension for cross-platform compression.\n"
    .. "Install from https://www.sws-extension.org/",
    "Missing Dependency", 0)
  return
end

-- ============================================================
-- CONFIG
-- ============================================================

local CONFIG = {
  win_default_w = 720,
  win_default_h = 520,
  win_min_w     = 568,
  win_min_h     = 400,
  title_bar_h   = 28,
  row_h         = 22,
  footer_h      = 20,
  dot_r         = 4,
  btn_h         = 26,
  scan_budget_per_tick = 64,            -- top-level subdirs evaluated per frame
  archive_done_display_sec = 3.0,
  footer_warning_display_sec = 3.0,
  compress_timeout_sec = 1800,          -- 30 min; fail if background process silent
  log_filename = "temper_archive.log",
  -- Button widths
  input_icon_w  = 36,
  output_btn_w  = 160,
  hide_btn_w    = 150,
  archive_btn_w = 180,
  gear_btn_w    = 22,
}

local _NS = "TEMPER_Archive"

-- ============================================================
-- lib/ module loading
-- ============================================================

-- Resolve lib/ as a sibling of this script (works for both dev layout and
-- per-package ReaPack layout — see Temper_Vortex.lua for context).
local _script_path = debug.getinfo(1, "S").source:sub(2)
local _lib         = (_script_path:match("^(.*)[\\/]") or ".") .. "/lib/"
local rsg_actions = dofile(_lib .. "rsg_actions.lua")
local platform    = dofile(_lib .. "rsg_platform.lua")
local archive     = dofile(_lib .. "rsg_archive.lua")

-- Theme is set on the global `rsg_theme` table by the lib's dofile.
pcall(dofile, _lib .. "rsg_theme.lua")
local SC = (rsg_theme and rsg_theme.SC) or {}

-- ============================================================
-- Constants derived from theme
-- ============================================================

local COL = {
  WINDOW        = SC.WINDOW        or 0x0E0E10FF,
  PANEL         = SC.PANEL         or 0x1E1E20FF,
  PANEL_HIGH    = SC.PANEL_HIGH    or 0x282828FF,
  PANEL_TOP     = SC.PANEL_TOP     or 0x323232FF,
  HOVER_LIST    = SC.HOVER_LIST    or 0x39393BFF,
  TITLE_BAR     = SC.TITLE_BAR     or 0x1A1A1CFF,
  PRIMARY       = SC.PRIMARY       or 0x26A69AFF,
  PRIMARY_HV    = SC.PRIMARY_HV    or 0x30B8ACFF,
  PRIMARY_AC    = SC.PRIMARY_AC    or 0x1A8A7EFF,
  TERTIARY      = SC.TERTIARY      or 0xDA7C5AFF,
  TERTIARY_HV   = SC.TERTIARY_HV   or 0xE08A6AFF,
  TERTIARY_AC   = SC.TERTIARY_AC   or 0xC46A4AFF,
  TEXT_ON       = SC.TEXT_ON       or 0xDEDEDEFF,
  TEXT_MUTED    = SC.TEXT_MUTED    or 0xBCC9C6FF,
  TEXT_OFF      = SC.TEXT_OFF      or 0x505050FF,
  ERROR_RED     = SC.ERROR_RED     or 0xC0392BFF,
  ACTIVE_DARK   = SC.ACTIVE_DARK   or 0x141416FF,
  HOVER_INACTIVE = SC.HOVER_INACTIVE or 0x2A2A2CFF,
  -- Script-locals reused from Alloy
  SEL_BG        = 0x26A69A80,  -- 50% alpha teal (Vortex-style)
  GREEN_ARCHIVED = 0x2ECC71FF,
}

-- ============================================================
-- ExtState persistence
-- ============================================================

local function load_settings(state)
  state.input_dir     = reaper.GetExtState(_NS, "input_dir")   or ""
  state.output_dir    = reaper.GetExtState(_NS, "output_dir")  or ""
  state.hide_archived = reaper.GetExtState(_NS, "hide_archived") == "1"
end

local function save_settings(state)
  reaper.SetExtState(_NS, "input_dir",     state.input_dir     or "", true)
  reaper.SetExtState(_NS, "output_dir",    state.output_dir    or "", true)
  reaper.SetExtState(_NS, "hide_archived", state.hide_archived and "1" or "0", true)
end

-- ============================================================
-- Pure helpers
-- ============================================================

-- Classify a row into one of the four display states. "approved" is
-- functionally the same as "pending" for queue eligibility but is drawn
-- with a distinct tooltip / label so users can tell the difference.
local function row_state(row)
  if row.archived                   then return "archived" end
  if row._override == "unapprove"   then return "invalid"  end
  if row._override == "approve"     then return "approved"  end
  if row.valid                      then return "pending"   end
  return "invalid"
end

local function row_dot_color(row)
  local st = row_state(row)
  if st == "archived" then return COL.GREEN_ARCHIVED end
  if st == "pending"  then return COL.TERTIARY      end
  if st == "approved" then return COL.TERTIARY      end
  return COL.ERROR_RED
end

local function row_is_eligible(row)
  if row.archived                 then return false end
  if row._override == "unapprove" then return false end
  if row._override == "approve"   then return true  end
  if row.valid                    then return true   end
  return false
end

local function count_row_states(rows)
  local total, arc, pend, inv = 0, 0, 0, 0
  for _, row in ipairs(rows) do
    total = total + 1
    local st = row_state(row)
    if st == "archived" then arc = arc + 1
    elseif st == "invalid" then inv = inv + 1
    else pend = pend + 1
    end
  end
  return total, arc, pend, inv
end

local function folder_leaf_name(path)
  local norm = (path or ""):gsub("\\", "/"):gsub("/+$", "")
  return norm:match("([^/]+)$") or norm
end

-- Format byte count as human-readable string.
local function fmt_bytes(n)
  if not n or n < 0 then return "" end
  if n < 1024 then return string.format("%d B", n) end
  if n < 1024 * 1024 then return string.format("%.1f KB", n / 1024) end
  if n < 1024 * 1024 * 1024 then return string.format("%.1f MB", n / (1024 * 1024)) end
  return string.format("%.2f GB", n / (1024 * 1024 * 1024))
end

-- Truncate a path-like string from the left so the tail remains visible.
local function trunc_left(s, max_len)
  s = s or ""
  if #s <= max_len then return s end
  return "..." .. s:sub(-(max_len - 3))
end

-- ============================================================
-- Logging
-- ============================================================

local function _timestamp()
  return os.date("%Y-%m-%d %H:%M:%S")
end

local function log_open(state)
  if not state.output_dir or state.output_dir == "" then return nil end
  local path = state.output_dir .. "/" .. CONFIG.log_filename
  local f = io.open(path, "a")
  if not f then return nil end
  state.log_file = f
  state.log_path = path
  return f
end

local function log_line(state, msg)
  if not state.log_file then return end
  state.log_file:write(string.format("[%s] %s\n", _timestamp(), msg))
  state.log_file:flush()
end

local function log_close(state)
  if state.log_file then
    pcall(function() state.log_file:close() end)
  end
  state.log_file = nil
end

local function log_run_header(state, total)
  log_line(state, string.format("RUN START os=%s input=%s output=%s queue=%d",
    reaper.GetOS(), state.input_dir or "?", state.output_dir or "?", total))
end

local function log_run_summary(state, ok_n, fail_n, cancel_n)
  log_line(state, string.format("RUN END ok=%d fail=%d cancel=%d",
    ok_n, fail_n, cancel_n))
end

-- ============================================================
-- Transient footer warning
-- ============================================================

local function flash_warning(state, msg)
  state.footer_warning    = msg
  state.footer_warning_ts = reaper.time_precise()
end

-- ============================================================
-- Scanner
-- ============================================================

-- Enumerate top-level subdirectories of state.input_dir, building one row
-- per child. Archive existence and validity are evaluated lazily across
-- ticks so the GUI stays responsive even with hundreds of folders.
local function scan_begin(state)
  state.rows              = {}
  state.status            = "scanning"
  state.scan_subdirs      = {}
  state.scan_idx          = 1
  local input = state.input_dir
  if not input or input == "" then
    state.status = "idle"
    return
  end
  -- Read subdir list in one pass; the expensive work (validity) is done
  -- per-row across frames in scan_tick.
  local si = 0
  while true do
    local name = reaper.EnumerateSubdirectories(input, si)
    if not name then break end
    state.scan_subdirs[#state.scan_subdirs + 1] = name
    si = si + 1
  end
  if #state.scan_subdirs == 0 then
    state.status = "idle"
  end
end

local function scan_tick(state)
  if state.status ~= "scanning" then return end
  local budget = CONFIG.scan_budget_per_tick
  local subdirs = state.scan_subdirs or {}
  while budget > 0 and state.scan_idx <= #subdirs do
    local name = subdirs[state.scan_idx]
    state.scan_idx = state.scan_idx + 1
    budget = budget - 1
    -- Skip folders the user removed from the list during this session.
    if not (state.removed_names and state.removed_names[name]) then
      local full = state.input_dir .. "/" .. name
      local row = {
        name       = name,
        path       = full,
        valid      = archive.is_valid_project(full),
        archived   = archive.archive_name_exists(state.output_dir or "", name),
        _override  = (state.override_map and state.override_map[name]) or nil,
        _user_sel  = false,
        error      = nil,
      }
      state.rows[#state.rows + 1] = row
    end
  end
  if state.scan_idx > #subdirs then
    -- Alphabetical, case-insensitive sort for stable display order.
    table.sort(state.rows, function(a, b) return a.name:lower() < b.name:lower() end)
    state.status       = "ready"
    state.scan_subdirs = nil
    state.scan_idx     = 0
    state.last_click_idx = nil
  end
end

-- ============================================================
-- Archive queue execution
-- ============================================================

-- Write a sentinel file to prove the output directory is writable.
local function output_dir_writable(out_dir)
  if not out_dir or out_dir == "" then return false end
  local probe = out_dir .. "/.temper_archive_write_test"
  local f = io.open(probe, "w")
  if not f then return false end
  f:write("ok")
  f:close()
  os.remove(probe)
  return true
end

local function build_queue(state)
  local queue       = {}
  local any_sel     = false
  for _, row in ipairs(state.rows) do
    if row._user_sel then any_sel = true; break end
  end
  for _, row in ipairs(state.rows) do
    if row_is_eligible(row) and (not any_sel or row._user_sel) then
      queue[#queue + 1] = row
    end
  end
  return queue
end

local function archive_begin(state)
  if state.status ~= "ready" then
    flash_warning(state, "Scan first.")
    return
  end
  if not state.output_dir or state.output_dir == "" then
    flash_warning(state, "Set an output directory first.")
    return
  end
  if not output_dir_writable(state.output_dir) then
    flash_warning(state, "Output directory is not writable.")
    return
  end
  local queue = build_queue(state)
  if #queue == 0 then
    flash_warning(state, "No eligible folders to archive.")
    return
  end
  state.queue              = queue
  state.archive_idx        = 1
  state.cancel_requested   = false
  state.archive_ok         = 0
  state.archive_fail       = 0
  state.archive_cancel     = 0
  state._compress_job      = nil
  state.current_stage      = "preparing"
  state.current_row        = queue[1]
  state.status             = "archiving"
  log_open(state)
  log_run_header(state, #queue)
end

-- Async archive: compress runs as a background process. Each frame we poll
-- for completion, keeping ImGui responsive. Cancel is instant -- checked
-- every frame during the polling loop.
local function archive_tick(state)
  if state.status ~= "archiving" then return end

  -- Cancel: responds instantly, even mid-compress.
  if state.cancel_requested then
    if state._compress_job then
      archive.compress_cancel(
        state._compress_job.sentinel,
        state._compress_job.dest_part,
        state._compress_job.script_path
      )
      state._compress_job = nil
    end
    local row = state.current_row
    if row and not row.archived then
      row.error = "cancelled"
      log_line(state, "CANCEL " .. row.path)
      state.archive_cancel = state.archive_cancel + 1
    end
    local remaining = math.max(0, #state.queue - state.archive_idx)
    log_run_summary(state, state.archive_ok, state.archive_fail, state.archive_cancel + remaining)
    log_close(state)
    state.status      = "ready"
    state.current_row = nil
    state.queue       = nil
    flash_warning(state, "Archive run cancelled.")
    return
  end

  -- Poll: check if background compress finished.
  if state._compress_job then
    local job = state._compress_job
    local ok, err, bytes, full_err = archive.compress_poll(
      job.sentinel, job.dest_part, job.dest_final, job.script_path
    )
    if ok == nil then
      -- Timeout guard: fail if background process has been silent too long.
      if state._compress_start_ts
         and (reaper.time_precise() - state._compress_start_ts) > CONFIG.compress_timeout_sec then
        archive.compress_cancel(job.sentinel, job.dest_part, job.script_path)
        state._compress_job = nil
        local row = state.current_row
        row.error = "compress timed out after " .. CONFIG.compress_timeout_sec .. "s"
        row.valid = false
        row._override = nil
        log_line(state, string.format("FAIL %s reason=%s", row.path, row.error))
        state.archive_fail = state.archive_fail + 1
        log_run_summary(state, state.archive_ok, state.archive_fail, state.archive_cancel)
        log_close(state)
        state.status = "archive_failed"
        flash_warning(state, "Archive failed: compress timed out.")
        state.current_row = nil
        state.queue = nil
        return
      end
      return  -- still running
    end
    state._compress_job = nil
    local row = state.current_row

    if not ok then
      row.error     = err or "unknown error"
      row.valid     = false
      row._override = nil
      log_line(state, string.format("FAIL %s reason=%s", row.path, full_err or err or "unknown error"))
      state.archive_fail = state.archive_fail + 1
      log_run_summary(state, state.archive_ok, state.archive_fail, state.archive_cancel)
      log_close(state)
      state.status      = "archive_failed"
      flash_warning(state, "Archive failed: " .. (err or "unknown error"))
      state.current_row = nil
      state.queue       = nil
      return
    end

    state.current_stage = "verifying"
    row.archived = true
    row.error    = nil
    log_line(state, string.format("OK %s bytes=%d", job.dest_final, bytes or 0))
    state.archive_ok  = state.archive_ok + 1
    state.archive_idx = state.archive_idx + 1
    return
  end

  -- Start next item.
  local idx   = state.archive_idx
  local queue = state.queue
  local row   = queue[idx]
  if not row then
    log_run_summary(state, state.archive_ok, state.archive_fail, state.archive_cancel)
    log_close(state)
    state.status          = "archive_done"
    state.archive_done_ts = reaper.time_precise()
    state.current_row     = nil
    return
  end

  state.current_row   = row
  state.current_stage = "preparing"
  local suffix     = archive.next_collision_suffix(state.output_dir, row.name)
  local dest_final = state.output_dir .. "/" .. row.name .. suffix .. ".zip"

  -- Launch background compress.
  state.current_stage = "compressing"
  local sentinel, dest_part, script_path = archive.compress_start(row.path, dest_final)
  if not sentinel then
    row.error     = dest_part or "unknown error"  -- error in 2nd return
    row.valid     = false
    row._override = nil
    log_line(state, string.format("FAIL %s reason=%s", row.path, row.error))
    state.archive_fail = state.archive_fail + 1
    log_run_summary(state, state.archive_ok, state.archive_fail, state.archive_cancel)
    log_close(state)
    state.status      = "archive_failed"
    flash_warning(state, "Archive failed: " .. (row.error or "unknown error"))
    state.current_row = nil
    state.queue       = nil
    return
  end

  state._compress_job = {
    sentinel    = sentinel,
    dest_part   = dest_part,
    dest_final  = dest_final,
    script_path = script_path,
  }
  state._compress_start_ts = reaper.time_precise()
end

-- ============================================================
-- Tick dispatcher
-- ============================================================

local function tick_state(state)
  -- Auto-revert archive_done -> ready after display interval.
  if state.status == "archive_done"
     and reaper.time_precise() - (state.archive_done_ts or 0) >= CONFIG.archive_done_display_sec then
    state.status = "ready"
  end
  if state.status == "scanning" then
    scan_tick(state)
  elseif state.status == "archiving" then
    archive_tick(state)
  end
end

-- ============================================================
-- Button style helpers
-- ============================================================

-- ============================================================
-- Folder picker
-- ============================================================

local function pick_folder(title, default)
  local rv, path = reaper.JS_Dialog_BrowseForFolder(title, default or "")
  if rv == 1 and path and path ~= "" then return path end
  return nil
end

-- ============================================================
-- Render: title bar
-- ============================================================

-- Settings popup (opened by gear button in title bar, matching Alloy/Mark)
local function render_settings_popup(ctx, state, lic, lic_status)
  local R = reaper
  if not R.ImGui_BeginPopup(ctx, "##settings_popup_archive") then return end
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_HeaderHovered(), COL.HOVER_LIST)

  if R.ImGui_Button(ctx, "Close##settings_close") then
    state.should_close = true
    R.ImGui_CloseCurrentPopup(ctx)
  end

  if lic_status == "trial" and lic then
    R.ImGui_Spacing(ctx)
    R.ImGui_Separator(ctx)
    R.ImGui_Spacing(ctx)
    if R.ImGui_Selectable(ctx, "Activate\xE2\x80\xA6##archive_activate") then
      lic.open_dialog(ctx)
      R.ImGui_CloseCurrentPopup(ctx)
    end
  end

  R.ImGui_PopStyleColor(ctx, 1)
  R.ImGui_EndPopup(ctx)
end

local function render_title_bar(ctx, state, lic, lic_status)
  local R = reaper
  local dl = R.ImGui_GetWindowDrawList(ctx)
  local wx, wy = R.ImGui_GetWindowPos(ctx)
  local ww    = select(1, R.ImGui_GetWindowSize(ctx))
  -- Background (full width from top edge)
  R.ImGui_DrawList_AddRectFilled(dl, wx, wy, wx + ww, wy + CONFIG.title_bar_h, COL.TITLE_BAR)
  -- Title text
  local font_b = rsg_theme and rsg_theme.font_bold
  if font_b then R.ImGui_PushFont(ctx, font_b, 13) end
  R.ImGui_DrawList_AddText(dl, wx + 12, wy + 7, COL.PRIMARY, "TEMPER - ARCHIVE")
  if font_b then R.ImGui_PopFont(ctx) end
  -- Gear button (right-aligned in title bar, opens settings popup)
  local gear_w = CONFIG.gear_btn_w
  R.ImGui_SetCursorScreenPos(ctx, wx + ww - gear_w - 8, wy + 3)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        COL.TITLE_BAR)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), COL.PANEL)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  COL.ACTIVE_DARK)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          COL.PRIMARY)
  if R.ImGui_Button(ctx, "\xe2\x9a\x99##settings_archive", gear_w, 0) then
    R.ImGui_OpenPopup(ctx, "##settings_popup_archive")
  end
  R.ImGui_PopStyleColor(ctx, 4)
  if R.ImGui_IsItemHovered(ctx) then R.ImGui_SetTooltip(ctx, "Settings") end
  render_settings_popup(ctx, state, lic, lic_status)
  -- Advance cursor past title bar (matching Alloy's SetCursorPosY pattern)
  R.ImGui_SetCursorPosY(ctx, CONFIG.title_bar_h + 8)
end

-- ============================================================
-- Render: controls row
-- ============================================================

-- Draw Alloy's folder icon (filled rect + tab) centered in the last item rect.
-- icol is the rect fill color; use PRIMARY (teal) when active.
local function _draw_folder_icon(ctx, icol)
  local R = reaper
  local dl = R.ImGui_GetWindowDrawList(ctx)
  local bx1, by1 = R.ImGui_GetItemRectMin(ctx)
  local bx2, by2 = R.ImGui_GetItemRectMax(ctx)
  local icx = math.floor((bx1 + bx2) * 0.5)
  local icy = math.floor((by1 + by2) * 0.5)
  R.ImGui_DrawList_AddRectFilled(dl, icx - 8, icy - 4, icx + 8, icy + 6, icol, 2.0)
  R.ImGui_DrawList_AddRectFilled(dl, icx - 8, icy - 7, icx - 2, icy - 4, icol, 1.5)
end

-- Alloy-style pill button styles (5 colors: Button/Hovered/Active/Text/Border).
local function _push_pill_inactive(ctx)
  local R = reaper
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        COL.PANEL_TOP)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), COL.HOVER_LIST)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  COL.ACTIVE_DARK)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          COL.PRIMARY)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(),        COL.PANEL_TOP)
end

local function _push_pill_active(ctx)
  local R = reaper
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        COL.PRIMARY)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), COL.PRIMARY_HV)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  COL.PRIMARY_AC)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          COL.WINDOW)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(),        COL.PRIMARY)
end

local function _push_pill_cancel(ctx)
  local R = reaper
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        COL.TERTIARY)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), COL.TERTIARY_HV)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  COL.TERTIARY_AC)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          COL.WINDOW)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(),        COL.TERTIARY)
end

local function _pop_pill(ctx)
  reaper.ImGui_PopStyleColor(ctx, 5)
end

-- ============================================================
-- Action handler module (keyboard shortcuts via rsg_actions)
-- Placed above render_controls so forward-ref is safe.
-- Each function replicates the exact inline GUI callback —
-- no new logic, no new side effects (subset-of-GUI invariant).
-- ============================================================

local archive_actions = {}

function archive_actions.scan_folder(state)
  local picked = pick_folder("Select input directory", state.input_dir)
  if picked then
    state.input_dir     = picked
    state.override_map  = {}
    state.removed_names = {}
    save_settings(state)
    scan_begin(state)
  end
end

function archive_actions.set_output(state)
  local picked = pick_folder("Select output directory", state.output_dir)
  if picked then
    state.output_dir = picked
    save_settings(state)
    if state.input_dir ~= "" then scan_begin(state) end
  end
end

function archive_actions.toggle_hide_archived(state)
  state.hide_archived = not state.hide_archived
  save_settings(state)
end

function archive_actions.archive(state)
  if state.status ~= "idle" then
    state.footer_warning    = "Archive not available"
    state.footer_warning_ts = reaper.time_precise()
    return
  end
  archive_begin(state)
end

function archive_actions.cancel(state)
  if state.status ~= "archiving" then return end
  state.cancel_requested = true
end

function archive_actions.remove_from_list(state)
  if state.status == "archiving" then return end
  local any = false
  for _, row in ipairs(state.rows or {}) do
    if row._user_sel then row._remove = true; any = true end
  end
  if not any then
    state.footer_warning    = "No rows selected"
    state.footer_warning_ts = reaper.time_precise()
  end
end

local function _is_btn_flashing(state, btn_key)
  local expires_at = state._btn_flash and state._btn_flash[btn_key]
  return expires_at ~= nil and reaper.time_precise() < expires_at
end

local function render_controls(ctx, state)
  local R = reaper
  local busy = (state.status == "archiving") or (state.status == "scanning")
  local btn_h = CONFIG.btn_h
  local icon_w = CONFIG.input_icon_w
  local out_w  = CONFIG.output_btn_w
  local hide_w = CONFIG.hide_btn_w
  local arc_w  = CONFIG.archive_btn_w

  local font_b = rsg_theme and rsg_theme.font_bold
  if font_b then R.ImGui_PushFont(ctx, font_b, 13) end

  R.ImGui_PushStyleVar(ctx, R.ImGui_StyleVar_FrameRounding(),   4)
  R.ImGui_PushStyleVar(ctx, R.ImGui_StyleVar_FrameBorderSize(), 1.0)

  if busy then R.ImGui_BeginDisabled(ctx) end

  -- 1. INPUT folder icon button -----------------------------------
  local _scan_flash = _is_btn_flashing(state, "scan_folder")
  if _scan_flash then
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        COL.ACTIVE_DARK)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), COL.ACTIVE_DARK)
  end
  _push_pill_inactive(ctx)
  if R.ImGui_Button(ctx, "##arc_input", icon_w, btn_h) then
    archive_actions.scan_folder(state)
  end
  _pop_pill(ctx)
  if _scan_flash then R.ImGui_PopStyleColor(ctx, 2) end
  _draw_folder_icon(ctx, COL.PRIMARY)
  if R.ImGui_IsItemHovered(ctx) then
    R.ImGui_SetTooltip(ctx, "INPUT FOLDER\n"
      .. (state.input_dir ~= "" and state.input_dir or "(not set)"))
  end

  -- 2. OUTPUT FOLDER text pill ------------------------------------
  R.ImGui_SameLine(ctx, 0, 8)
  local _out_flash = _is_btn_flashing(state, "set_output")
  if _out_flash then
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        COL.ACTIVE_DARK)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), COL.ACTIVE_DARK)
  end
  _push_pill_inactive(ctx)
  if R.ImGui_Button(ctx, "OUTPUT FOLDER##arc_output", out_w, btn_h) then
    archive_actions.set_output(state)
  end
  _pop_pill(ctx)
  if _out_flash then R.ImGui_PopStyleColor(ctx, 2) end
  if R.ImGui_IsItemHovered(ctx) then
    R.ImGui_SetTooltip(ctx, "OUTPUT FOLDER\n"
      .. (state.output_dir ~= "" and state.output_dir or "(not set)"))
  end

  -- 3. HIDE ARCHIVED toggle pill ----------------------------------
  R.ImGui_SameLine(ctx, 0, 8)
  local _hide_flash = _is_btn_flashing(state, "toggle_hide_archived")
  if _hide_flash then
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        COL.ACTIVE_DARK)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), COL.ACTIVE_DARK)
  end
  if state.hide_archived then _push_pill_active(ctx) else _push_pill_inactive(ctx) end
  if R.ImGui_Button(ctx, "HIDE ARCHIVED##arc_hide", hide_w, btn_h) then
    archive_actions.toggle_hide_archived(state)
  end
  _pop_pill(ctx)
  if _hide_flash then R.ImGui_PopStyleColor(ctx, 2) end

  if busy then R.ImGui_EndDisabled(ctx) end

  -- 4. Right-aligned ARCHIVE / CANCEL primary action --------------
  -- SameLine FIRST so GetContentRegionAvail returns the remaining width
  -- after the prior buttons, not the full window width.
  R.ImGui_SameLine(ctx, 0, 8)
  local avail_w = select(1, R.ImGui_GetContentRegionAvail(ctx))
  if state.status == "archiving" then
    R.ImGui_Dummy(ctx, math.max(0, avail_w - arc_w - 4), 0)
    R.ImGui_SameLine(ctx, 0, 0)
    local _cancel_flash = _is_btn_flashing(state, "cancel")
    if _cancel_flash then
      R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        COL.ACTIVE_DARK)
      R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), COL.ACTIVE_DARK)
    end
    _push_pill_cancel(ctx)
    local cancel_label = state.cancel_requested
      and "CANCELLING...##arc_cancel" or "CANCEL##arc_cancel"
    if R.ImGui_Button(ctx, cancel_label, arc_w, btn_h) then
      archive_actions.cancel(state)
    end
    _pop_pill(ctx)
    if _cancel_flash then R.ImGui_PopStyleColor(ctx, 2) end
  else
    local sel_eligible = 0
    for _, row in ipairs(state.rows or {}) do
      if row._user_sel and row_is_eligible(row) then sel_eligible = sel_eligible + 1 end
    end
    local label = (sel_eligible > 0)
      and string.format("ARCHIVE SELECTED (%d)##arc_go", sel_eligible)
      or  "ARCHIVE##arc_go"
    R.ImGui_Dummy(ctx, math.max(0, avail_w - arc_w - 4), 0)
    R.ImGui_SameLine(ctx, 0, 0)
    local _arc_flash = _is_btn_flashing(state, "archive")
    if _arc_flash then
      R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        COL.ACTIVE_DARK)
      R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), COL.ACTIVE_DARK)
    end
    _push_pill_active(ctx)
    if R.ImGui_Button(ctx, label, arc_w, btn_h) then
      archive_actions.archive(state)
    end
    _pop_pill(ctx)
    if _arc_flash then R.ImGui_PopStyleColor(ctx, 2) end
  end

  R.ImGui_PopStyleVar(ctx, 2)
  if font_b then R.ImGui_PopFont(ctx) end
end

-- ============================================================
-- Render: list selection helper
-- ============================================================

-- Visible-row index map -> real state.rows index, so shift-click range
-- behaves against what the user actually sees.
local function build_visible_index(state)
  local vis = {}
  for i, row in ipairs(state.rows) do
    if not (state.hide_archived and row.archived) then
      vis[#vis + 1] = i
    end
  end
  return vis
end

local function apply_click(state, vis, vis_pos, ctrl, shift)
  local real_idx = vis[vis_pos]
  if not real_idx then return end
  if shift and state.last_click_idx then
    -- Find anchor in visible list; if anchor is hidden, treat as plain click.
    local anchor_vis = nil
    for vp, ri in ipairs(vis) do
      if ri == state.last_click_idx then anchor_vis = vp; break end
    end
    if anchor_vis then
      if not ctrl then
        for _, ri in ipairs(vis) do state.rows[ri]._user_sel = false end
      end
      local lo, hi = math.min(anchor_vis, vis_pos), math.max(anchor_vis, vis_pos)
      for vp = lo, hi do state.rows[vis[vp]]._user_sel = true end
      return
    end
  end
  if ctrl then
    state.rows[real_idx]._user_sel = not state.rows[real_idx]._user_sel
  else
    -- If this is the only selected row, deselect it (toggle off).
    -- If multiple rows are selected, narrow to just this one.
    local sel_count = 0
    for _, ri in ipairs(vis) do
      if state.rows[ri]._user_sel then sel_count = sel_count + 1 end
    end
    local was_sole = state.rows[real_idx]._user_sel and sel_count == 1
    for _, ri in ipairs(vis) do state.rows[ri]._user_sel = false end
    if not was_sole then
      state.rows[real_idx]._user_sel = true
    end
  end
  state.last_click_idx = real_idx
end

local function clear_selection(state)
  for _, row in ipairs(state.rows or {}) do row._user_sel = false end
  state.last_click_idx = nil
end

-- ============================================================
-- Render: list
-- ============================================================

local function render_list_empty(ctx, state)
  local R = reaper
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), COL.TEXT_MUTED)
  if state.status == "scanning" then
    R.ImGui_Text(ctx, "  Scanning...")
  elseif state.input_dir == "" then
    R.ImGui_Text(ctx, "  Set an input directory to begin.")
  elseif state.output_dir == "" then
    R.ImGui_Text(ctx, "  Set an output directory to evaluate archive state.")
  else
    R.ImGui_Text(ctx, "  No folders found.")
  end
  R.ImGui_PopStyleColor(ctx, 1)
end

-- Target-row resolver for context-menu actions: if any rows are
-- user-selected, return them; otherwise return the single clicked row.
local function resolve_context_targets(state, clicked_row)
  local targets = {}
  for _, row in ipairs(state.rows) do
    if row._user_sel then targets[#targets + 1] = row end
  end
  if #targets == 0 then targets[1] = clicked_row end
  return targets
end

local function render_row_context_menu(ctx, state, row, menu_id)
  local R = reaper
  if R.ImGui_BeginPopupContextItem(ctx, menu_id) then
    local targets = resolve_context_targets(state, row)
    if not state.override_map then state.override_map = {} end
    if R.ImGui_MenuItem(ctx, "Approve (force archive)") then
      for _, r in ipairs(targets) do
        r._override = "approve"
        state.override_map[r.name] = "approve"
      end
    end
    if R.ImGui_MenuItem(ctx, "Unapprove (force invalid)") then
      for _, r in ipairs(targets) do
        r._override = "unapprove"
        state.override_map[r.name] = "unapprove"
      end
    end
    if R.ImGui_MenuItem(ctx, "Clear override") then
      for _, r in ipairs(targets) do
        r._override = nil
        state.override_map[r.name] = nil
      end
    end
    R.ImGui_Separator(ctx)
    if R.ImGui_MenuItem(ctx, "Open in file manager") then
      platform.open_folder(row.path)
    end
    R.ImGui_Separator(ctx)
    if R.ImGui_MenuItem(ctx, "Remove from list") then
      for _, r in ipairs(targets) do r._remove = true end
    end
    R.ImGui_EndPopup(ctx)
  end
end

local function prune_removed_rows(state)
  local any = false
  for _, row in ipairs(state.rows) do
    if row._remove then any = true; break end
  end
  if not any then return end
  if not state.removed_names then state.removed_names = {} end
  local kept = {}
  for _, row in ipairs(state.rows) do
    if row._remove then
      state.removed_names[row.name] = true
    else
      kept[#kept + 1] = row
    end
  end
  state.rows = kept
  state.last_click_idx = nil
end

local function render_list(ctx, state)
  local R = reaper
  -- Darker child list against the PANEL outer frame (Alloy aesthetic).
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ChildBg(), COL.WINDOW)
  local child_h = select(2, R.ImGui_GetContentRegionAvail(ctx)) - CONFIG.footer_h - 4
  if child_h < 60 then child_h = 60 end
  if R.ImGui_BeginChild(ctx, "##arc_list", 0, child_h, 0) then
    if not state.rows or #state.rows == 0 then
      render_list_empty(ctx, state)
    else
      local vis = build_visible_index(state)
      if #vis == 0 then
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), COL.TEXT_MUTED)
        R.ImGui_Text(ctx, "  All folders are hidden by the current filter.")
        R.ImGui_PopStyleColor(ctx, 1)
      end
      local font_b = rsg_theme and rsg_theme.font_bold
      local lc = state._clipper
      R.ImGui_ListClipper_Begin(lc, #vis, CONFIG.row_h)
      while R.ImGui_ListClipper_Step(lc) do
        local disp_start, disp_end = R.ImGui_ListClipper_GetDisplayRange(lc)
        for vis_pos = disp_start + 1, disp_end do  -- 0-indexed -> 1-indexed
          local real_idx = vis[vis_pos]
          local row = state.rows[real_idx]
          local is_sel = row._user_sel
          local cx, cy = R.ImGui_GetCursorScreenPos(ctx)
          local row_w  = select(1, R.ImGui_GetContentRegionAvail(ctx))
          if is_sel then
            local dl = R.ImGui_GetWindowDrawList(ctx)
            R.ImGui_DrawList_AddRectFilled(dl, cx, cy, cx + row_w, cy + CONFIG.row_h, COL.SEL_BG)
          end
          -- Status dot
          local dl2 = R.ImGui_GetWindowDrawList(ctx)
          R.ImGui_DrawList_AddCircleFilled(dl2,
            cx + CONFIG.dot_r + 4,
            cy + CONFIG.row_h * 0.5,
            CONFIG.dot_r, row_dot_color(row))
          -- Pass false for is_selected so ImGui does NOT draw its own opaque
          -- Col_Header background; we handle selection visuals entirely via
          -- the translucent-teal DrawList rect above.
          local clicked = R.ImGui_Selectable(ctx, "##row_" .. real_idx, false,
            R.ImGui_SelectableFlags_SpanAllColumns() | R.ImGui_SelectableFlags_AllowOverlap(),
            0, CONFIG.row_h)
          if clicked then
            local ctrl  = R.ImGui_IsKeyDown(ctx, R.ImGui_Mod_Ctrl())
            local shift = R.ImGui_IsKeyDown(ctx, R.ImGui_Mod_Shift())
            apply_click(state, vis, vis_pos, ctrl, shift)
          end
          render_row_context_menu(ctx, state, row, "##ctx_" .. real_idx)
          -- Row label (overlaid via SameLine)
          R.ImGui_SameLine(ctx, CONFIG.dot_r * 2 + 14)
          if font_b then R.ImGui_PushFont(ctx, font_b, 13) end
          R.ImGui_TextColored(ctx, COL.TEXT_ON, row.name)
          if font_b then R.ImGui_PopFont(ctx) end
          -- Right-aligned state label
          local st = row_state(row)
          local label = st
          local label_col = COL.TEXT_MUTED
          if row.error then label = "failed"; label_col = COL.ERROR_RED end
          if st == "approved" then label_col = COL.TERTIARY end
          if st == "archived" then label_col = COL.GREEN_ARCHIVED end
          local label_w = R.ImGui_CalcTextSize(ctx, label)
          R.ImGui_SameLine(ctx, row_w - label_w - 12)
          R.ImGui_TextColored(ctx, label_col, label)
          -- Show full error detail in tooltip on hover (avoids visual clutter).
          if row.error and R.ImGui_IsItemHovered(ctx) then
            R.ImGui_SetTooltip(ctx, row.error)
          end
        end
      end
      prune_removed_rows(state)
      -- Click on empty area clears selection.
      if R.ImGui_IsWindowHovered(ctx) and R.ImGui_IsMouseClicked(ctx, 0)
         and not R.ImGui_IsAnyItemHovered(ctx) then
        clear_selection(state)
      end
    end
    R.ImGui_EndChild(ctx)
  end
  R.ImGui_PopStyleColor(ctx, 1)
end

-- ============================================================
-- Render: footer
-- ============================================================

local function render_footer(ctx, state)
  local R = reaper
  local dl = R.ImGui_GetWindowDrawList(ctx)
  local x, y = R.ImGui_GetCursorScreenPos(ctx)
  local w = select(1, R.ImGui_GetContentRegionAvail(ctx))
  -- No background rect — footer text sits directly on the window bg.

  local left_text, right_text, left_col = "", "", COL.TEXT_MUTED
  local show_progress_bg = false

  if state.status == "archiving" and state.queue then
    local total = #state.queue
    local idx = state.archive_idx or 1
    local pct = (idx - 1) / math.max(1, total)
    -- Progress fill only during active archiving.
    R.ImGui_DrawList_AddRectFilled(dl, x, y, x + w * pct, y + CONFIG.footer_h, COL.PRIMARY_AC)
    show_progress_bg = true
    local name = (state.current_row and state.current_row.name) or ""
    local bytes_str = ""
    if state._compress_job and state._compress_job.dest_part then
      local cur = archive.compress_progress(state._compress_job.dest_part)
      if cur and cur > 0 then bytes_str = " (" .. fmt_bytes(cur) .. ")" end
    end
    left_text = string.format("  Archiving [%d/%d]: %s%s", idx, total, name, bytes_str)
    right_text = (state.current_stage or "") .. "  "
  elseif state.status == "archive_failed" then
    left_text = "  Archive failed."
    left_col = COL.ERROR_RED
    right_text = "  "
  elseif state.status == "archive_done" then
    left_text = string.format("  Done: %d archived, %d failed  ",
      state.archive_ok or 0, state.archive_fail or 0)
    left_col = COL.GREEN_ARCHIVED
    right_text = "  "
  elseif state.footer_warning
         and reaper.time_precise() - (state.footer_warning_ts or 0) < CONFIG.footer_warning_display_sec then
    left_text = "  " .. state.footer_warning
    left_col = COL.TERTIARY
    right_text = "  "
  else
    if state.footer_warning then state.footer_warning = nil end
    local total, arc, pend, inv = count_row_states(state.rows or {})
    left_text = string.format("  Scanned: %d  |  Pending: %d  |  Archived: %d  |  Invalid: %d",
      total, pend, arc, inv)
    right_text = ""
  end

  -- Vertically center text within footer_h (font is ~13px).
  local text_y = y + math.floor((CONFIG.footer_h - 13) * 0.5)
  local font_b = rsg_theme and rsg_theme.font_bold
  if font_b then R.ImGui_PushFont(ctx, font_b, 13) end
  R.ImGui_DrawList_AddText(dl, x + 2, text_y, left_col, left_text)
  if right_text ~= "" then
    local right_w = R.ImGui_CalcTextSize(ctx, right_text)
    R.ImGui_DrawList_AddText(dl, x + w - right_w - 4, text_y, COL.TEXT_MUTED, right_text)
  end
  if font_b then R.ImGui_PopFont(ctx) end
  R.ImGui_Dummy(ctx, w, CONFIG.footer_h)
end

-- ============================================================
-- Render: top-level
-- ============================================================

local function render_gui(ctx, state, lic, lic_status)
  -- Delete key removes user-selected rows (gated by focus, selection, and not-busy).
  local R = reaper
  if R.ImGui_IsWindowFocused(ctx, R.ImGui_FocusedFlags_RootAndChildWindows())
     and not R.ImGui_IsAnyItemActive(ctx)
     and state.status ~= "archiving"
     and R.ImGui_IsKeyPressed(ctx, R.ImGui_Key_Delete(), false) then
    for _, row in ipairs(state.rows or {}) do
      if row._user_sel then row._remove = true end
    end
  end
  render_title_bar(ctx, state, lic, lic_status)
  render_controls(ctx, state)
  reaper.ImGui_Spacing(ctx)
  render_list(ctx, state)
  render_footer(ctx, state)
end

-- ============================================================
-- Instance guard
-- ============================================================

do
  local _inst_ts = reaper.GetExtState(_NS, "instance_ts")
  if _inst_ts ~= "" and tonumber(_inst_ts)
     and (reaper.time_precise() - tonumber(_inst_ts)) < 1.0 then
    reaper.ShowMessageBox(
      "Temper Archive is already running.\nClose the existing window first.",
      "Temper Archive", 0)
    return
  end
  reaper.SetExtState(_NS, "instance_ts", tostring(reaper.time_precise()), false)
end

-- ============================================================
-- Entry point
-- ============================================================

do
  local ctx = reaper.ImGui_CreateContext("Temper Archive##archive")
  local clipper = reaper.ImGui_CreateListClipper(ctx)

  -- Attach fonts before the first frame.
  if type(rsg_theme) == "table" and rsg_theme.attach_fonts then
    rsg_theme.attach_fonts(ctx)
  end

  -- License gate (optional; pcall-wrapped so script works without license libs).
  local _lic_ok, lic = pcall(dofile, _lib .. "rsg_license.lua")
  if not _lic_ok then lic = nil end
  if lic then lic.configure({
    namespace    = "TEMPER_Archive",
    scope_id     = 0x9,
    display_name = "Archive",
    buy_url      = "https://www.tempertools.com/scripts/archive",
  }) end

  local state = {
    status             = "idle",
    input_dir          = "",
    output_dir         = "",
    hide_archived      = false,
    rows               = {},
    override_map       = {},
    removed_names      = {},
    scan_subdirs       = nil,
    scan_idx           = 0,
    last_click_idx     = nil,
    queue              = nil,
    archive_idx        = 1,
    cancel_requested   = false,
    archive_ok         = 0,
    archive_fail       = 0,
    archive_cancel     = 0,
    archive_done_ts    = 0,
    _compress_job      = nil,
    _compress_start_ts = 0,
    current_row        = nil,
    current_stage      = "",
    log_file           = nil,
    log_path           = nil,
    footer_warning     = nil,
    footer_warning_ts  = 0,
    should_close       = false,
    _clipper           = clipper,
  }

  load_settings(state)
  -- Auto-scan on launch if we already know where to look.
  if state.input_dir ~= "" then scan_begin(state) end

  -- Action dispatch (v1.3.0): keyboard shortcuts via rsg_actions framework.
  state._btn_flash = {}
  local _BTN_FLASH_DUR = 0.25
  local function _set_flash(k)
    state._btn_flash[k] = reaper.time_precise() + _BTN_FLASH_DUR
  end

  local HANDLERS = {
    scan_folder          = function() _set_flash("scan_folder");          archive_actions.scan_folder(state)          end,
    set_output           = function() _set_flash("set_output");           archive_actions.set_output(state)           end,
    toggle_hide_archived = function() _set_flash("toggle_hide_archived"); archive_actions.toggle_hide_archived(state) end,
    archive              = function() _set_flash("archive");              archive_actions.archive(state)              end,
    cancel               = function() _set_flash("cancel");               archive_actions.cancel(state)               end,
    remove_from_list     = function() _set_flash("remove_from_list");     archive_actions.remove_from_list(state)     end,
    close                = function() state.should_close = true end,
  }
  rsg_actions.clear_pending_on_init(_NS)

  local _first_loop = true
  local function loop()
    reaper.SetExtState(_NS, "instance_ts", tostring(reaper.time_precise()), false)
    rsg_actions.heartbeat(_NS)
    local _focus_requested = rsg_actions.poll(_NS, HANDLERS)
    tick_state(state)

    if _first_loop then
      reaper.ImGui_SetNextWindowSize(ctx, CONFIG.win_default_w, CONFIG.win_default_h,
        reaper.ImGui_Cond_FirstUseEver())
    end
    _first_loop = false
    reaper.ImGui_SetNextWindowSizeConstraints(ctx,
      CONFIG.win_min_w, CONFIG.win_min_h, 4096, 4096)

    if _focus_requested then
      reaper.ImGui_SetNextWindowFocus(ctx)
      if reaper.APIExists and reaper.APIExists("JS_Window_SetForeground") then
        local hwnd = reaper.JS_Window_Find and reaper.JS_Window_Find("Temper Archive", true)
        if hwnd then reaper.JS_Window_SetForeground(hwnd) end
      end
    end

    local n_theme = (rsg_theme and rsg_theme.push) and rsg_theme.push(ctx) or 0
    -- Match Vortex Mini / Alloy: outer window frame = PANEL (lighter grey),
    -- child list overlays on top with SC.WINDOW (near-black) for contrast.
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), COL.PANEL)
    local win_flags = reaper.ImGui_WindowFlags_NoCollapse()
                    | reaper.ImGui_WindowFlags_NoTitleBar()
                    | reaper.ImGui_WindowFlags_NoScrollbar()
                    | reaper.ImGui_WindowFlags_NoScrollWithMouse()
    local visible, open = reaper.ImGui_Begin(ctx, "Temper Archive##archive", true, win_flags)

    if visible then
      local lic_status = lic and lic.check("ARCHIVE", ctx)

      if lic_status == "expired" then
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_TextColored(ctx, COL.ERROR_RED, "  Your Archive trial has expired.")
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_TextDisabled(ctx, "  Purchase a license at temper.tools to continue.")
        if not lic.is_dialog_open() then lic.open_dialog(ctx) end
        lic.draw_dialog(ctx)
      else
        render_gui(ctx, state, lic, lic_status)
        if lic and lic.is_dialog_open() then lic.draw_dialog(ctx) end
      end

      reaper.ImGui_End(ctx)
    end

    if rsg_theme and rsg_theme.pop then rsg_theme.pop(ctx, n_theme) end
    reaper.ImGui_PopStyleColor(ctx, 1)

    if open and not state.should_close then
      reaper.defer(loop)
    else
      -- If the user closes while archiving, release the log handle cleanly.
      if state.log_file then
        log_line(state, "RUN ABORTED (window closed)")
        log_close(state)
      end
      reaper.SetExtState(_NS, "instance_ts", "", false)
    end
  end

  reaper.defer(loop)
end
