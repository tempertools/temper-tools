-- @description Temper Mark -- Intelligent Take Marker Detection & Embedding
-- @version 1.4.1
-- @author Anthony Breslin
-- @provides
--   [main] Temper_Mark.lua
--   [nomain] lib/rsg_wav_io.lua
--   [nomain] lib/rsg_theme.lua
--   [nomain] lib/rsg_mark_analysis.lua
--   [nomain] lib/rsg_license.lua
--   [nomain] lib/rsg_activation_dialog.lua
--   [nomain] lib/rsg_sha256.lua
--   [nomain] lib/rsg_actions.lua
-- @about
--   Temper Mark scans folders of WAV files, detects transient boundaries via
--   a multi-stage algorithm, previews results on a custom waveform display,
--   and embeds RIFF cue chunks without touching any other metadata.
--
--   Features:
--   - Folder scanner with native picker + recursive WAV discovery
--   - Session mode: scan selected items from the REAPER arrange view (v1.4)
--   - Tunable detection parameters (silence floor, sensitivity, min spacing)
--   - Custom DrawList waveform preview with marker overlay
--   - Three-layer marker model (existing, detected, manual)
--   - Take marker writeback to REAPER items in session mode (v1.4)
--   - Safe cue chunk embedding with byte-identical metadata preservation (v1.1)
--
--   Requires: ReaImGui, js_ReaScriptAPI (install via ReaPack)

-- ============================================================
-- Dependency checks
-- ============================================================

if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox(
    "Temper Mark requires ReaImGui.\nInstall via ReaPack: Extensions > ReaImGui",
    "Missing Dependency", 0)
  return
end

if not reaper.JS_Dialog_BrowseForFolder then
  reaper.ShowMessageBox(
    "Temper Mark requires js_ReaScriptAPI.\nInstall via ReaPack: Extensions > js_ReaScriptAPI",
    "Missing Dependency", 0)
  return
end

-- ============================================================
-- CONFIG
-- ============================================================

local CONFIG = {
  -- Window dimensions
  win_w = 700,
  win_h = 500,
  -- File list column width
  file_list_w = 200,
  -- Default detection parameters
  default_silence_db  = -40,
  default_sensitivity = 50,
  default_spacing_ms  = 1000,
  -- Scan limits
  max_files = 5000,
  -- Chunked processing
  files_per_frame = 20,
  -- Enumeration budget (files discovered per frame during folder scan)
  enum_per_frame = 100,
  -- Analysis budget (hops processed per defer frame; ~5-10ms at 200)
  analysis_hops_per_frame = 200,
  -- Mipmap display width (columns for waveform peak data)
  analysis_mipmap_width = 2000,
  -- Parameter change debounce (seconds of slider idle before re-detection)
  param_debounce_sec = 0.030,
  -- Minimum window size for resize constraints
  min_win_w = 800,
  min_win_h = 400,
  -- Phase 3: Waveform interaction
  zoom_max         = 50.0,
  zoom_factor      = 1.15,     -- per wheel tick multiplier
  marker_hit_px    = 5,        -- pixel tolerance for marker click detection
  drag_deadzone_px = 3,        -- pixels before drag activates
}

-- ============================================================
-- Lib loading
-- ============================================================

local _lib           = reaper.GetResourcePath() .. "/Scripts/Temper/lib/"
local wav_io         = dofile(_lib .. "rsg_wav_io.lua")
local mark_analysis  = dofile(_lib .. "rsg_mark_analysis.lua")
local platform       = dofile(_lib .. "rsg_platform.lua")
local rsg_actions    = dofile(_lib .. "rsg_actions.lua")

-- ============================================================
-- ExtState namespace
-- ============================================================

local _NS = "TEMPER_Mark"

-- ============================================================
-- Forward declarations
-- ============================================================

local SC  -- Spectral Core palette (set after theme load)

-- push_undo is declared below the render_* functions (next to the other
-- undo/redo helpers) but must be referenced from render_file_list's right-
-- click menu and from the rsg_actions handler module, both of which are
-- parsed earlier. Forward-declare here so those earlier references bind to
-- this local (as an upvalue) instead of compiling as a global lookup. The
-- actual assignment happens later via `function push_undo(...) end` without
-- the `local` keyword.
local push_undo

-- ============================================================
-- File record factory
-- ============================================================

-- Single source of truth for per-file state. All file records go through here.
local function create_file_record(path, filename, session_item)
  return {
    path              = path,
    filename          = filename,
    size              = 0,
    status            = "pending",
    freshly_embedded  = false,
    existing_markers  = nil,
    detected_markers  = nil,
    manual_markers    = {},
    has_manual_edits  = false,
    analysis          = nil,
    mipmap            = nil,
    wav_info          = nil,
    zoom              = 1.0,
    scroll_offset     = 0,
    zoom_peaks        = nil,
    zoom_peaks_key    = nil,
    ignore_regions    = {},
    undo_stack        = {},
    redo_stack         = {},
    session_item      = session_item,  -- MediaItem* or nil
    error_msg         = nil,
    _orig_idx         = 0,             -- set by caller after insertion
  }
end

-- ============================================================
-- Mode switch & session item acquisition
-- ============================================================

-- Reset all state when switching between folder and session modes.
local function reset_for_mode_switch(state)
  -- Cancel any in-progress analysis
  if state.active_analysis then
    mark_analysis.analysis_cancel(state.active_analysis)
    state.active_analysis = nil
    state.analysis_file_idx = nil
  end
  state.files = {}
  state.current_idx = nil
  state.scan_read_idx = 1
  state.scan_progress = 0
  state.scan_total = 0
  state.filter = "all"
  state.analysis_cache = {}
  state.analysis_queue = {}
  state.analysis_queue_pos = 1
  state.embed_queue = {}
  state.embed_queue_pos = 1
  state.selected_indices = {}
  state.last_click_idx = nil
  state.selected_marker = nil
  state.drag_active = false
  state.enum = nil
  state.status = "idle"
  state.error_msg = nil
  state.footer_warning = nil
  state.footer_warning_ts = nil
end

-- Add selected REAPER media items to the file list (session mode).
-- Skips non-WAV sources, offline items, and duplicates.
local function add_selected_items(state)
  local R = reaper
  local count = R.CountSelectedMediaItems(0)
  if count == 0 then return end

  local skipped_non_wav = 0
  local skipped_offline = 0
  local added = 0

  -- Build path lookup for dedup
  local existing_paths = {}
  for _, f in ipairs(state.files) do
    existing_paths[f.path:lower()] = true
  end

  for i = 0, count - 1 do
    local item = R.GetSelectedMediaItem(0, i)
    if item then
      local take = R.GetActiveTake(item)
      if take then
        local src = R.GetMediaItemTake_Source(take)
        if src then
          local fp = R.GetMediaSourceFileName(src, "")
          if not fp or fp == "" then
            skipped_offline = skipped_offline + 1
          elseif not fp:lower():match("%.wav$") then
            skipped_non_wav = skipped_non_wav + 1
          elseif existing_paths[fp:lower()] then
            -- duplicate, skip silently
          else
            existing_paths[fp:lower()] = true
            local norm_path = fp:gsub("\\", "/")
            local fname = fp:match("[/\\]([^/\\]+)$") or fp
            state.files[#state.files + 1] = create_file_record(norm_path, fname, item)
            state.files[#state.files]._orig_idx = #state.files
            added = added + 1
          end
        end
      end
    end
  end

  -- Footer warnings
  local warnings = {}
  if skipped_non_wav > 0 then
    warnings[#warnings + 1] = string.format("Skipped %d non-WAV item%s",
      skipped_non_wav, skipped_non_wav > 1 and "s" or "")
  end
  if skipped_offline > 0 then
    warnings[#warnings + 1] = string.format("Skipped %d offline item%s",
      skipped_offline, skipped_offline > 1 and "s" or "")
  end
  if #warnings > 0 then
    state.footer_warning = table.concat(warnings, "  |  ")
    state.footer_warning_ts = reaper.time_precise()
  end

  -- Transition to scanning if new files were added
  if added > 0 then
    state.scan_read_idx = #state.files - added + 1
    state.scan_total = #state.files
    state.status = "scanning"
  end
end

-- ============================================================
-- Folder scanning (chunked, non-blocking)
-- ============================================================

-- Initialize enumeration state for a new folder scan.
local function start_enumeration(state, root)
  -- Cancel any in-progress analysis to prevent leaked file handles
  if state.active_analysis then
    mark_analysis.analysis_cancel(state.active_analysis)
    state.active_analysis = nil
    state.analysis_file_idx = nil
  end
  state.analysis_queue = {}
  state.analysis_queue_pos = 1

  state.files = {}
  state.current_idx = nil
  state.scan_read_idx = 1
  state.filter = "all"
  state.root_folder = root
  -- Enumeration state machine
  state.enum = {
    dirs     = { root },
    dir      = nil,       -- current directory being enumerated
    fi       = 0,         -- file index within current dir
    done_files = false,   -- finished enumerating files in current dir
  }
  state.status = "enumerating"
  state.scan_progress = 0
  state.scan_total = 0
end

-- Process up to enum_per_frame files in the enumeration phase.
-- Returns true when enumeration is complete.
local function tick_enumeration(state)
  local en = state.enum
  if not en then return true end

  local budget = CONFIG.enum_per_frame
  local count = 0

  while count < budget do
    -- Need a new directory to enumerate?
    if not en.dir then
      if #en.dirs == 0 then
        -- All directories processed
        state.enum = nil
        return true
      end
      en.dir = table.remove(en.dirs)
      en.fi = 0
      en.done_files = false
    end

    -- Enumerate files in current directory
    if not en.done_files then
      local fname = reaper.EnumerateFiles(en.dir, en.fi)
      if not fname then
        en.done_files = true
        -- Now enumerate subdirectories (cheap, do all at once)
        local di = 0
        while true do
          local dname = reaper.EnumerateSubdirectories(en.dir, di)
          if not dname then break end
          en.dirs[#en.dirs + 1] = en.dir .. "/" .. dname
          di = di + 1
        end
        en.dir = nil  -- move to next directory
      else
        en.fi = en.fi + 1
        count = count + 1
        if fname:lower():match("%.wav$") then
          local full_path = en.dir .. "/" .. fname
          state.files[#state.files + 1] = create_file_record(full_path, fname, nil)
          state.files[#state.files]._orig_idx = #state.files
          state.scan_total = #state.files
          if #state.files >= CONFIG.max_files then
            state.enum = nil
            return true
          end
        end
      end
    end
  end

  return false
end

-- ============================================================
-- Chunked cue reading (non-blocking)
-- ============================================================

-- Read WAV info + cue markers for files_per_frame files (single file open per file).
-- Returns true when all files have been processed.
local function tick_cue_reading(state)
  local count = 0
  while state.scan_read_idx <= #state.files and count < CONFIG.files_per_frame do
    local file = state.files[state.scan_read_idx]
    local result = wav_io.read_wav_all(file.path)
    if result then
      file.wav_info = result.info
      file.existing_markers = result.markers
      file.size = result.file_size
      if #result.markers > 0 then
        file.status = "embedded"
      end
    else
      file.existing_markers = {}
    end
    state.scan_read_idx = state.scan_read_idx + 1
    count = count + 1
  end
  return state.scan_read_idx > #state.files
end

-- ============================================================
-- File list filtering
-- ============================================================

local function get_filtered_files(state)
  if state.filter == "all" then return state.files end
  local out = {}
  for _, f in ipairs(state.files) do
    if state.filter == "detected" and (f.status == "detected" or f.has_manual_edits) then
      out[#out + 1] = f
    elseif state.filter == "embedded" and f.status == "embedded" then
      out[#out + 1] = f
    end
  end
  return out
end

-- Get effective markers for display, tagged with source info for hit detection.
-- Returns sorted array of { time_sec, label, _source, _idx }.
local function effective_markers(file, auto_detect)
  local result = {}
  -- Existing (embedded) markers -- always shown
  if file.existing_markers then
    for i, m in ipairs(file.existing_markers) do
      result[#result + 1] = { time_sec = m.time_sec, label = m.label, _source = "existing", _idx = i }
    end
  end
  -- Detected markers -- shown only when auto-detect is on
  if auto_detect ~= false and file.detected_markers then
    for i, m in ipairs(file.detected_markers) do
      result[#result + 1] = { time_sec = m.time_sec, label = m.label, _source = "detected", _idx = i }
    end
  end
  -- Manual markers -- always shown
  if file.manual_markers then
    for i, m in ipairs(file.manual_markers) do
      result[#result + 1] = { time_sec = m.time_sec, label = m.label, _source = "manual", _idx = i }
    end
  end
  table.sort(result, function(a, b) return a.time_sec < b.time_sec end)
  return result
end

-- Cache key for analysis results (invalidates on file change)
local function analysis_cache_key(file)
  return file.path .. "|" .. tostring(file.size)
end

-- Rebuild _orig_idx after files are removed from state.files.
local function rebuild_orig_indices(files)
  for i, f in ipairs(files) do
    f._orig_idx = i
  end
end

-- ============================================================
-- Status dot color
-- ============================================================

local function status_color(file)
  if type(file) == "string" then
    -- Legacy: accept status string directly
    if file == "embedded" then return SC and SC.PRIMARY or 0x26A69AFF end
    if file == "detected" then return SC and SC.TERTIARY or 0xDA7C5AFF end
    if file == "error"    then return SC and SC.ERROR_RED or 0xC0392BFF end
    return 0x606060FF
  end
  if file.freshly_embedded then return SC and SC.FRESHLY_EMBEDDED or 0x4CAF50FF end
  if file.status == "embedded" then return SC and SC.PRIMARY or 0x26A69AFF end       -- teal
  if file.status == "detected" then return SC and SC.TERTIARY or 0xDA7C5AFF end      -- amber/coral
  if file.status == "error"    then return SC and SC.ERROR_RED or 0xC0392BFF end      -- red
  return 0x606060FF                                                                    -- grey (pending)
end

-- ============================================================
-- Format helpers
-- ============================================================

local function format_size(bytes)
  if bytes >= 1048576 then
    return string.format("%.1f MB", bytes / 1048576)
  elseif bytes >= 1024 then
    return string.format("%.0f KB", bytes / 1024)
  end
  return string.format("%d B", bytes)
end

local function format_duration(sec)
  if not sec then return "--:--" end
  local m = math.floor(sec / 60)
  local s = sec - m * 60
  return string.format("%d:%04.1f", m, s)
end

-- ============================================================
-- Render: Title bar (custom DrawList)
-- ============================================================

-- Forward declaration: assigned after render_gui, called from render_title_bar
local render_settings_popup

local function render_title_bar(ctx, w, state, lic, lic_status)
  local R = reaper
  local dl = R.ImGui_GetWindowDrawList(ctx)
  -- Draw edge-to-edge: use window position (ignoring WindowPadding)
  local win_x, win_y = R.ImGui_GetWindowPos(ctx)
  local win_w = R.ImGui_GetWindowSize(ctx)
  local h = 28

  -- Background (full window width, from top edge)
  R.ImGui_DrawList_AddRectFilled(dl, win_x, win_y, win_x + win_w, win_y + h,
    SC and SC.TITLE_BAR or 0x1A1A1CFF)

  -- Title text
  local font_b = rsg_theme and rsg_theme.font_bold
  if font_b then R.ImGui_PushFont(ctx, font_b, 13) end
  local title_color = SC and SC.PRIMARY or 0x26A69AFF
  R.ImGui_DrawList_AddText(dl, win_x + 10, win_y + 8, title_color, "TEMPER - MARK")
  if font_b then R.ImGui_PopFont(ctx) end

  -- Settings gear button (right-aligned)
  local btn_w = 22
  R.ImGui_SetCursorScreenPos(ctx, win_x + win_w - btn_w - 8, win_y + 3)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        SC and SC.TITLE_BAR or 0x1A1A1CFF)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), SC and SC.PANEL or 0x1E1E20FF)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  SC and SC.ACTIVE_DARK or 0x141416FF)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          SC and SC.PRIMARY or 0x26A69AFF)
  if R.ImGui_Button(ctx, "\xe2\x9a\x99##settings_mark", btn_w, 0) then
    R.ImGui_OpenPopup(ctx, "##settings_popup_mark")
  end
  R.ImGui_PopStyleColor(ctx, 4)
  if R.ImGui_IsItemHovered(ctx) then R.ImGui_SetTooltip(ctx, "Settings") end
  render_settings_popup(ctx, state, lic, lic_status)

  -- Advance cursor: title bar bottom + 8px gap
  R.ImGui_SetCursorPosY(ctx, h + 8)
end

-- Forward declarations (defined after tick_analysis; used in render_controls)
local start_embed_single
local start_embed_all

-- ============================================================
-- Action handlers (rsg_actions framework)
-- ============================================================
--
-- `mark_actions` is the single mirror of every GUI button callback that is
-- also exposed as a REAPER action. Subset-of-GUI invariant: every entry must
-- perform only behaviors already reachable via a mouse click in the Mark GUI.
--
-- Placement is critical: this module MUST be declared above every render_*
-- function that references it, otherwise Lua resolves `mark_actions` as a
-- global at parse time and button callbacks throw `attempt to index a nil
-- value (global 'mark_actions')` at runtime.
--
-- All handlers that need push_undo, perform_*, start_embed_*, or any helper
-- declared later in the file rely on forward-declared locals at the top of
-- the chunk so those references bind as upvalues.

local mark_actions = {}

-- Transient footer warning (piggybacks on existing footer_warning plumbing
-- used by session-mode skip messages). 3-second auto-fade handled by
-- render_footer.
local function _mk_notify(state, msg)
  state.footer_warning = msg
  state.footer_warning_ts = reaper.time_precise()
end

-- Return array of target file indices: multi-selected files in the list if
-- any are selected, otherwise a single-element array holding the current
-- preview file index, otherwise empty.
local function _mk_targets(state)
  local out = {}
  local n = 0
  for idx in pairs(state.selected_indices) do
    n = n + 1
    out[n] = idx
  end
  if n == 0 and state.current_idx then
    out[1] = state.current_idx
  end
  return out
end

-- ── Hero verbs ───────────────────────────────────────────────────

function mark_actions.scan_folder(state)
  if state.input_mode ~= "folder" then
    _mk_notify(state, "Scan Folder: switch to FOLDER mode first")
    return
  end
  local ok, folder = reaper.JS_Dialog_BrowseForFolder("Select folder to scan", "")
  if ok == 1 and folder and folder ~= "" then
    folder = folder:gsub("\\", "/")
    start_enumeration(state, folder)
    reaper.SetExtState(_NS, "last_folder", folder, true)
  end
end

function mark_actions.add_session_items(state)
  if state.input_mode ~= "session" then
    _mk_notify(state, "Add Selected Items: switch to SESSION mode first")
    return
  end
  add_selected_items(state)
end

function mark_actions.embed(state)
  local cur = state.current_idx and state.files[state.current_idx]
  local file_ready = cur and (cur.status ~= "pending")
  if not file_ready or state.status == "embedding" then
    _mk_notify(state, "Embed: select a file with markers first")
    return
  end
  start_embed_all(state)
end

-- ── Global toggles ──────────────────────────────────────────────

function mark_actions.cycle_input_mode(state)
  state.input_mode = (state.input_mode == "session") and "folder" or "session"
  reset_for_mode_switch(state)
  reaper.SetExtState(_NS, "input_mode", state.input_mode, true)
end

function mark_actions.cycle_filter(state)
  local FILTERS = { "all", "embedded", "detected" }
  local cur_i = 1
  for ii, f in ipairs(FILTERS) do
    if f == state.filter then cur_i = ii; break end
  end
  state.filter = FILTERS[(cur_i % #FILTERS) + 1]
  state.selected_indices = {}
  state.last_click_idx = nil
end

function mark_actions.toggle_auto_detect(state)
  state.auto_detect = not state.auto_detect
  reaper.SetExtState(_NS, "auto_detect", state.auto_detect and "1" or "0", true)
  if state.auto_detect then
    state.params_changed_ts = reaper.time_precise()
  end
end

-- ── File list context ops ───────────────────────────────────────
-- Target = multi-selected files in the list if any, else the current
-- preview file. Same contextual rule across the three operations.

function mark_actions.clear_markers(state)
  local targets = _mk_targets(state)
  if #targets == 0 then
    _mk_notify(state, "Clear Markers: no file selected")
    return
  end
  for _, idx in ipairs(targets) do
    local f = state.files[idx]
    if f then
      push_undo(f)
      f.existing_markers = {}
      f.detected_markers = {}
      f.manual_markers = {}
      f.ignore_regions = {}
      f.has_manual_edits = true
    end
  end
end

function mark_actions.remove_from_list(state)
  local targets = _mk_targets(state)
  if #targets == 0 then
    _mk_notify(state, "Remove From List: no file selected")
    return
  end
  table.sort(targets, function(a, b) return a > b end)
  for _, idx in ipairs(targets) do
    if state.analysis_file_idx == idx then
      state.active_analysis = nil
      state.analysis_file_idx = nil
    end
    table.remove(state.files, idx)
  end
  rebuild_orig_indices(state.files)
  state.selected_indices = {}
  state.last_click_idx = nil
  if state.current_idx and state.current_idx > #state.files then
    state.current_idx = #state.files > 0 and #state.files or nil
  end
end

-- Clipboard writes need the ImGui context. The HANDLERS table in the entry
-- block captures ctx in scope and passes it here. The right-click menu path
-- also has ctx in scope and passes it directly.
function mark_actions.copy_name(state, ctx)
  local targets = _mk_targets(state)
  local names = {}
  for _, idx in ipairs(targets) do
    local f = state.files[idx]
    if f then names[#names + 1] = f.filename end
  end
  if #names == 0 then
    _mk_notify(state, "Copy Name: no file selected")
    return
  end
  table.sort(names)
  if ctx then
    reaper.ImGui_SetClipboardText(ctx, table.concat(names, "\n"))
  end
end

-- ── Button flash helper ─────────────────────────────────────────
-- Keyboard-dispatched actions skip ImGui's built-in active-state feedback,
-- so each HANDLERS entry sets a short-lived expiry in state._btn_flash. The
-- render_* functions swap the corresponding button's Col_Button AND
-- Col_ButtonHovered to the pressed shade for the flash duration, visually
-- mimicking the feedback a mouse click gets natively. Both are pushed so
-- hover cannot mask the flash (Imprint v1.3.3 → v1.3.4 fix).

local function _is_btn_flashing(state, btn_key)
  local expires_at = state._btn_flash and state._btn_flash[btn_key]
  return expires_at ~= nil and reaper.time_precise() < expires_at
end

-- ============================================================
-- Render: Controls row (scan button, filter, parameters)
-- ============================================================

local function render_controls(ctx, state, cur_file, cur_markers)
  local R = reaper

  -- Input button (folder scan or session add, based on input_mode)
  local font_b = rsg_theme and rsg_theme.font_bold
  if font_b then R.ImGui_PushFont(ctx, font_b, 13) end

  local btn_sz = 26

  if state.input_mode == "folder" then
    -- Scan Folder icon button
    local _scan_flash = _is_btn_flashing(state, "scan_folder")
    local _scan_bg = _scan_flash and (SC and SC.ACTIVE_DARK or 0x141416FF)
                                  or (SC and SC.PANEL_TOP or 0x323232FF)
    local _scan_hv = _scan_flash and (SC and SC.ACTIVE_DARK or 0x141416FF)
                                  or (SC and SC.HOVER_LIST or 0x39393BFF)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(), _scan_bg)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), _scan_hv)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(), SC and SC.ACTIVE_DARK or 0x141416FF)
    if R.ImGui_Button(ctx, " ##scan_folder", 61, btn_sz) then
      mark_actions.scan_folder(state)
    end
    R.ImGui_PopStyleColor(ctx, 3)
    if R.ImGui_IsItemHovered(ctx) then R.ImGui_SetTooltip(ctx, "Scan Folder") end
    -- Draw folder icon via DrawList (centered in button)
    local dl = R.ImGui_GetWindowDrawList(ctx)
    local bx1, by1 = R.ImGui_GetItemRectMin(ctx)
    local bx2, by2 = R.ImGui_GetItemRectMax(ctx)
    local cx = math.floor((bx1 + bx2) * 0.5)
    local cy = math.floor((by1 + by2) * 0.5)
    local icol = SC and SC.PRIMARY or 0x26A69AFF
    -- Folder body (wide rect)
    R.ImGui_DrawList_AddRectFilled(dl, cx - 8, cy - 4, cx + 8, cy + 6, icol, 2.0)
    -- Folder tab (small rect, top-left)
    R.ImGui_DrawList_AddRectFilled(dl, cx - 8, cy - 7, cx - 2, cy - 4, icol, 1.5)
  else
    -- Session mode: "+ Add" button
    local sel_count = R.CountSelectedMediaItems(0)
    local add_disabled = sel_count == 0
    if add_disabled then
      R.ImGui_BeginDisabled(ctx)
    end
    local _add_flash = _is_btn_flashing(state, "add_session_items")
    local _add_bg = _add_flash and (SC and SC.ACTIVE_DARK or 0x141416FF)
                                or (SC and SC.PANEL_TOP or 0x323232FF)
    local _add_hv = _add_flash and (SC and SC.ACTIVE_DARK or 0x141416FF)
                                or (SC and SC.HOVER_LIST or 0x39393BFF)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(), _add_bg)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), _add_hv)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(), SC and SC.ACTIVE_DARK or 0x141416FF)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC and SC.PRIMARY or 0x26A69AFF)
    if R.ImGui_Button(ctx, "+ Add##add_sel", 61, btn_sz) then
      mark_actions.add_session_items(state)
    end
    R.ImGui_PopStyleColor(ctx, 4)
    if add_disabled then
      R.ImGui_EndDisabled(ctx)
    end
    local hf_disabled = R.ImGui_HoveredFlags_AllowWhenDisabled and R.ImGui_HoveredFlags_AllowWhenDisabled() or 0
    if R.ImGui_IsItemHovered(ctx, hf_disabled) then
      R.ImGui_SetTooltip(ctx, add_disabled
        and "Select items in arrange view first"
        or string.format("Add %d selected item%s", sel_count, sel_count > 1 and "s" or ""))
    end
  end

  -- Mode toggle: FOLDER / SESSION
  R.ImGui_SameLine(ctx, 0, 8)
  local is_session = state.input_mode == "session"
  local mode_label = is_session and "SESSION" or "FOLDER"
  local mode_col = is_session
    and { SC and SC.PRIMARY or 0x26A69AFF, SC and SC.PRIMARY_HV or 0x30B8ACFF,
          SC and SC.PRIMARY_AC or 0x1A8A7EFF, SC and SC.WINDOW or 0x0E0E10FF }
    or  { SC and SC.PANEL_TOP or 0x323232FF, SC and SC.HOVER_LIST or 0x39393BFF,
          SC and SC.ACTIVE_DARK or 0x141416FF, SC and SC.PRIMARY or 0x26A69AFF }
  if _is_btn_flashing(state, "cycle_input_mode") then
    local pressed = SC and SC.ACTIVE_DARK or 0x141416FF
    mode_col[1] = pressed
    mode_col[2] = pressed
  end
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(), mode_col[1])
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), mode_col[2])
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(), mode_col[3])
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), mode_col[4])
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(), mode_col[1])
  if R.ImGui_Button(ctx, mode_label .. "##input_mode", 61, btn_sz) then
    mark_actions.cycle_input_mode(state)
  end
  R.ImGui_PopStyleColor(ctx, 5)
  if R.ImGui_IsItemHovered(ctx) then
    R.ImGui_SetTooltip(ctx, is_session
      and "Session mode: add items from arrange view\nClick to switch to Folder mode"
      or "Folder mode: scan a directory\nClick to switch to Session mode")
  end

  -- Filter cycle button (ALL -> EMBEDDED -> DETECTED -> ALL)
  R.ImGui_SameLine(ctx, 0, 8)
  local FILTERS       = { "all", "embedded", "detected" }
  local FILTER_LABELS = { all = "ALL", embedded = "EMBED", detected = "DETECT" }
  local FILTER_DESCS  = {
    all      = "Show all scanned files",
    embedded = "Show files with embedded cue markers",
    detected = "Show files with detected transients",
  }
  local FILTER_COL = {
    all      = { SC and SC.PANEL_TOP or 0x323232FF, SC and SC.HOVER_LIST or 0x39393BFF,
                 SC and SC.ACTIVE_DARK or 0x141416FF, SC and SC.PRIMARY or 0x26A69AFF },
    embedded = { SC and SC.PRIMARY or 0x26A69AFF, SC and SC.PRIMARY_HV or 0x30B8ACFF,
                 SC and SC.PRIMARY_AC or 0x1A8A7EFF, SC and SC.WINDOW or 0x0E0E10FF },
    detected = { SC and SC.TERTIARY or 0xDA7C5AFF, SC and SC.TERTIARY_HV or 0xE08A6AFF,
                 SC and SC.TERTIARY_AC or 0xC46A4AFF, SC and SC.WINDOW or 0x0E0E10FF },
  }
  local fc = FILTER_COL[state.filter]
  local fc_bg, fc_hv = fc[1], fc[2]
  if _is_btn_flashing(state, "cycle_filter") then
    local pressed = SC and SC.ACTIVE_DARK or 0x141416FF
    fc_bg = pressed
    fc_hv = pressed
  end
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(), fc_bg)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), fc_hv)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(), fc[3])
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), fc[4])
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(), fc[1])  -- invisible border
  if R.ImGui_Button(ctx, FILTER_LABELS[state.filter] .. "##filt", 61, btn_sz) then
    mark_actions.cycle_filter(state)
  end
  R.ImGui_PopStyleColor(ctx, 5)
  if R.ImGui_IsItemHovered(ctx) then
    R.ImGui_SetTooltip(ctx, FILTER_DESCS[state.filter])
  end

  -- Auto/Manual cycle button (2-state, same style as filter cycle)
  R.ImGui_SameLine(ctx, 0, 8)
  local det_on = state.auto_detect
  local det_label = det_on and "AUTO" or "MAN"
  local det_col = det_on
    and { SC and SC.PANEL_TOP or 0x323232FF, SC and SC.HOVER_LIST or 0x39393BFF,
          SC and SC.ACTIVE_DARK or 0x141416FF, SC and SC.PRIMARY or 0x26A69AFF }
    or  { SC and SC.PRIMARY or 0x26A69AFF, SC and SC.PRIMARY_HV or 0x30B8ACFF,
          SC and SC.PRIMARY_AC or 0x1A8A7EFF, SC and SC.WINDOW or 0x0E0E10FF }
  if _is_btn_flashing(state, "toggle_auto_detect") then
    local pressed = SC and SC.ACTIVE_DARK or 0x141416FF
    det_col[1] = pressed
    det_col[2] = pressed
  end
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(), det_col[1])
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), det_col[2])
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(), det_col[3])
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), det_col[4])
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(), det_col[1])
  if R.ImGui_Button(ctx, det_label .. "##detect", 61, btn_sz) then
    mark_actions.toggle_auto_detect(state)
  end
  R.ImGui_PopStyleColor(ctx, 5)
  if R.ImGui_IsItemHovered(ctx) then
    R.ImGui_SetTooltip(ctx, det_on
      and "Auto-detect mode: generated markers active"
      or "Manual mode: only user-placed markers")
  end

  -- Embed button (current file) -- same dimensions as filter/auto buttons
  R.ImGui_SameLine(ctx, 0, 8)
  local file_ready = cur_file and (cur_file.status ~= "pending")
  local embed_disabled = (not file_ready) or state.status == "embedding"
  if embed_disabled then
    -- Inactive: receded grey like Imprint disabled properties
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(), SC and SC.PANEL or 0x1E1E20FF)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), SC and SC.HOVER_INACTIVE or 0x2A2A2CFF)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(), SC and SC.ACTIVE_DARKER or 0x161618FF)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC and SC.TEXT_OFF or 0x505050FF)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(), SC and SC.PANEL or 0x1E1E20FF)
  else
    -- Active: tertiary coral with dark text
    local _emb_flash = _is_btn_flashing(state, "embed")
    local _emb_bg = _emb_flash and (SC and SC.TERTIARY_AC or 0xC46A4AFF)
                                or (SC and SC.TERTIARY    or 0xDA7C5AFF)
    local _emb_hv = _emb_flash and (SC and SC.TERTIARY_AC or 0xC46A4AFF)
                                or (SC and SC.TERTIARY_HV or 0xE08A6AFF)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(), _emb_bg)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), _emb_hv)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(), SC and SC.TERTIARY_AC or 0xC46A4AFF)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC and SC.WINDOW or 0x0E0E10FF)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(), SC and SC.TERTIARY or 0xDA7C5AFF)
  end
  if R.ImGui_Button(ctx, "EMBED##embed_btn", 61, btn_sz) then
    if not embed_disabled then
      mark_actions.embed(state)
    end
  end
  R.ImGui_PopStyleColor(ctx, 5)
  if R.ImGui_IsItemHovered(ctx) then
    if embed_disabled then
      R.ImGui_SetTooltip(ctx, "Select a file with markers to embed")
    else
      R.ImGui_SetTooltip(ctx, "Write cue markers to selected files")
    end
  end

  -- Parameter sliders (right side, dimmed when auto-detect is off)
  if not state.auto_detect then R.ImGui_BeginDisabled(ctx) end
  R.ImGui_SameLine(ctx, 0, 28)
  R.ImGui_Text(ctx, "Silence:")
  R.ImGui_SameLine(ctx)
  R.ImGui_SetNextItemWidth(ctx, 100)
  local s_changed
  s_changed, state.silence_db = R.ImGui_SliderDouble(ctx, "##silence",
    state.silence_db, -80, -20, "%.0f dB")
  if s_changed then state.params_changed_ts = R.time_precise() end

  R.ImGui_SameLine(ctx, 0, 24)
  R.ImGui_Text(ctx, "Sens:")
  R.ImGui_SameLine(ctx)
  R.ImGui_SetNextItemWidth(ctx, 80)
  local p_changed
  p_changed, state.sensitivity = R.ImGui_SliderInt(ctx, "##sensitivity",
    state.sensitivity, 0, 100, "%d%%")
  if p_changed then state.params_changed_ts = R.time_precise() end

  R.ImGui_SameLine(ctx, 0, 24)
  R.ImGui_Text(ctx, "Spacing:")
  R.ImGui_SameLine(ctx)
  R.ImGui_SetNextItemWidth(ctx, 80)
  local m_changed
  m_changed, state.spacing_ms = R.ImGui_SliderInt(ctx, "##spacing",
    state.spacing_ms, 100, 5000, "%d ms")
  if m_changed then state.params_changed_ts = R.time_precise() end
  if not state.auto_detect then R.ImGui_EndDisabled(ctx) end

  if font_b then R.ImGui_PopFont(ctx) end
end

-- ============================================================
-- Render: File list (left panel)
-- ============================================================

local function render_file_list(ctx, state, h)
  local R = reaper
  local w = CONFIG.file_list_w

  local font_b = rsg_theme and rsg_theme.font_bold
  if font_b then R.ImGui_PushFont(ctx, font_b, 13) end

  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ChildBg(), SC and SC.WINDOW or 0x0E0E10FF)
  if R.ImGui_BeginChild(ctx, "##file_list", w, h, R.ImGui_ChildFlags_Borders()) then
    local filtered = get_filtered_files(state)
    local dl = R.ImGui_GetWindowDrawList(ctx)

    -- Build filtered-to-original index map (O(N) via _orig_idx)
    local filtered_to_orig = {}
    for i, file in ipairs(filtered) do
      filtered_to_orig[i] = file._orig_idx
    end

    -- Read modifiers once
    local mods = R.ImGui_GetKeyMods(ctx)
    local ctrl  = (mods & R.ImGui_Mod_Ctrl()) ~= 0
    local shift = (mods & R.ImGui_Mod_Shift()) ~= 0

    for i, file in ipairs(filtered) do
      local cx, cy = R.ImGui_GetCursorScreenPos(ctx)
      local j = filtered_to_orig[i]

      -- Status dot
      local dot_r = 4
      local dot_color = status_color(file)
      R.ImGui_DrawList_AddCircleFilled(dl, cx + dot_r + 2, cy + 8, dot_r, dot_color)

      -- Selectable row (highlight based on multi-select set)
      R.ImGui_SetCursorPosX(ctx, R.ImGui_GetCursorPosX(ctx) + dot_r * 2 + 8)
      local is_selected = state.selected_indices[j] == true
      if R.ImGui_Selectable(ctx, file.filename .. "##f" .. j, is_selected,
          R.ImGui_SelectableFlags_None(), w - dot_r * 2 - 16, 0) then
        if shift and state.last_click_idx then
          -- Shift+click: range select (visual positions in filtered list)
          local anchor_pos, click_pos
          for fi, orig_j in ipairs(filtered_to_orig) do
            if orig_j == state.last_click_idx then anchor_pos = fi end
            if orig_j == j then click_pos = fi end
          end
          if anchor_pos and click_pos then
            state.selected_indices = {}
            local lo = math.min(anchor_pos, click_pos)
            local hi = math.max(anchor_pos, click_pos)
            for fi = lo, hi do
              state.selected_indices[filtered_to_orig[fi]] = true
            end
          end
        elseif ctrl then
          -- Ctrl+click: toggle individual
          if state.selected_indices[j] then
            state.selected_indices[j] = nil
          else
            state.selected_indices[j] = true
          end
          state.last_click_idx = j
        else
          -- Plain click: single select
          state.selected_indices = { [j] = true }
          state.last_click_idx = j
        end
        if state.current_idx ~= j then
          state.selected_marker = nil
          state.drag_active = false
        end
        state.current_idx = j
      end

      -- Right-click: select if needed + open context menu
      if R.ImGui_IsItemClicked(ctx, 1) then
        if not state.selected_indices[j] then
          state.selected_indices = { [j] = true }
          state.last_click_idx = j
          state.current_idx = j
          state.selected_marker = nil
          state.drag_active = false
        end
        R.ImGui_OpenPopup(ctx, "##file_ctx_menu")
      end

      -- Scroll-to-current on arrow key navigation
      if j == state.current_idx and state._scroll_to_current then
        R.ImGui_SetScrollHereY(ctx, 0.5)
        state._scroll_to_current = false
      end

      -- Tooltip with details
      if R.ImGui_IsItemHovered(ctx) then
        R.ImGui_BeginTooltip(ctx)
        R.ImGui_Text(ctx, file.filename)
        R.ImGui_Text(ctx, format_size(file.size))
        if file.wav_info then
          R.ImGui_Text(ctx, string.format("%d Hz  %dch  %dbit",
            file.wav_info.sample_rate, file.wav_info.channels, file.wav_info.bits_per_sample))
          R.ImGui_Text(ctx, format_duration(file.wav_info.duration))
        end
        local markers = effective_markers(file, state.auto_detect)
        if #markers > 0 then
          R.ImGui_Text(ctx, string.format("%d markers", #markers))
        end
        if file.status == "error" and file.error_msg then
          R.ImGui_TextColored(ctx, SC and SC.ERROR_RED or 0xC0392BFF,
            "Error: " .. file.error_msg)
        end
        R.ImGui_EndTooltip(ctx)
      end
    end

    -- Context menu popup
    if R.ImGui_BeginPopup(ctx, "##file_ctx_menu") then
      R.ImGui_PushStyleColor(ctx, R.ImGui_Col_HeaderHovered(),
        SC and SC.HOVER_LIST or 0x39393BFF)
      local sel_count = 0
      for _ in pairs(state.selected_indices) do sel_count = sel_count + 1 end
      local label_suffix = sel_count > 1 and string.format(" (%d)", sel_count) or ""

      if R.ImGui_MenuItem(ctx, "Open Location" .. label_suffix) then
        -- Group selected files by parent directory
        local dirs = {}  -- dir -> { paths }
        for idx in pairs(state.selected_indices) do
          local f = state.files[idx]
          if f then
            local dir = f.path:match("(.*[/\\])")
            if dir then
              if not dirs[dir] then dirs[dir] = {} end
              dirs[dir][#dirs[dir] + 1] = f.path
            end
          end
        end
        for _, paths in pairs(dirs) do
          platform.reveal_in_explorer(paths[1])
        end
      end

      if R.ImGui_MenuItem(ctx, "Copy Name" .. label_suffix) then
        mark_actions.copy_name(state, ctx)
      end

      R.ImGui_Separator(ctx)

      if R.ImGui_MenuItem(ctx, "Clear Markers" .. label_suffix) then
        mark_actions.clear_markers(state)
      end

      if R.ImGui_MenuItem(ctx, "Remove from List" .. label_suffix) then
        mark_actions.remove_from_list(state)
      end

      R.ImGui_PopStyleColor(ctx, 1)
      R.ImGui_EndPopup(ctx)
    end

    -- Keyboard shortcuts (only when file list is focused)
    if R.ImGui_IsWindowFocused(ctx) and #filtered_to_orig > 0 then
      local kb_mods = R.ImGui_GetKeyMods(ctx)
      local kb_ctrl = (kb_mods & R.ImGui_Mod_Ctrl()) ~= 0

      -- Ctrl+A: select all filtered files
      if kb_ctrl and R.ImGui_IsKeyPressed(ctx, R.ImGui_Key_A()) then
        state.selected_indices = {}
        for _, orig_j in ipairs(filtered_to_orig) do
          state.selected_indices[orig_j] = true
        end
      end

      -- Delete: remove selected files
      if R.ImGui_IsKeyPressed(ctx, R.ImGui_Key_Delete()) then
        local to_remove = {}
        for idx in pairs(state.selected_indices) do
          to_remove[#to_remove + 1] = idx
        end
        if #to_remove > 0 then
          table.sort(to_remove, function(a, b) return a > b end)
          for _, idx in ipairs(to_remove) do
            if state.analysis_file_idx == idx then
              state.active_analysis = nil
              state.analysis_file_idx = nil
            end
            table.remove(state.files, idx)
          end
          rebuild_orig_indices(state.files)
          state.selected_indices = {}
          state.last_click_idx = nil
          if state.current_idx then
            if state.current_idx > #state.files then
              state.current_idx = #state.files > 0 and #state.files or nil
            end
          end
        end
      end

      -- Up/Down arrows: navigate and change active file
      local up   = R.ImGui_IsKeyPressed(ctx, R.ImGui_Key_UpArrow())
      local down = R.ImGui_IsKeyPressed(ctx, R.ImGui_Key_DownArrow())
      if up or down then
        local cur_pos
        for fi, orig_j in ipairs(filtered_to_orig) do
          if orig_j == state.current_idx then cur_pos = fi; break end
        end
        local new_pos
        if cur_pos then
          new_pos = up and (cur_pos > 1 and cur_pos - 1) or
                          (cur_pos < #filtered_to_orig and cur_pos + 1)
        else
          new_pos = down and 1 or #filtered_to_orig
        end
        if new_pos then
          local new_j = filtered_to_orig[new_pos]
          state.current_idx = new_j
          state.selected_indices = { [new_j] = true }
          state.last_click_idx = new_j
          state.selected_marker = nil
          state.drag_active = false
          state._scroll_to_current = true
        end
      end
    end

    R.ImGui_EndChild(ctx)
  end
  R.ImGui_PopStyleColor(ctx, 1)

  if font_b then R.ImGui_PopFont(ctx) end
end

-- ============================================================
-- Waveform coordinate utilities
-- ============================================================

local function clamp_scroll(file)
  local max_scroll = math.max(0, 1.0 - 1.0 / file.zoom)
  file.scroll_offset = math.max(0, math.min(file.scroll_offset, max_scroll))
end

-- Convert pixel x-coordinate to time in seconds (within visible window).
local function pixel_to_time(px, draw_x, draw_w, file, dur)
  local frac = (px - draw_x) / draw_w
  local visible_frac = 1.0 / file.zoom
  local time_frac = file.scroll_offset + frac * visible_frac
  return time_frac * dur
end

-- Convert time in seconds to pixel x-coordinate.
local function time_to_pixel(t, draw_x, draw_w, file, dur)
  local frac = t / dur
  local visible_frac = 1.0 / file.zoom
  return (frac - file.scroll_offset) / visible_frac * draw_w + draw_x
end

-- Find nearest marker within hit tolerance. Returns idx, source, hit_ok.
local function find_nearest_marker(mouse_x, draw_x, draw_w, file, dur, markers)
  local best_dist = CONFIG.marker_hit_px + 1
  local best_idx, best_source = nil, nil
  for i, m in ipairs(markers) do
    local mx = time_to_pixel(m.time_sec, draw_x, draw_w, file, dur)
    local dist = math.abs(mouse_x - mx)
    if dist < best_dist then
      best_dist = dist
      best_idx = i
      best_source = m._source
    end
  end
  return best_idx, best_source, best_dist <= CONFIG.marker_hit_px
end

-- ============================================================
-- Render: Waveform preview (right panel)
-- ============================================================

-- ============================================================
-- Undo / redo for marker operations
-- ============================================================

-- Deep-copy a flat marker array: {{time_sec=N, label=S}, ...}
local function copy_markers(arr)
  if not arr then return {} end
  local out = {}
  for i, m in ipairs(arr) do
    out[i] = { time_sec = m.time_sec, label = m.label }
  end
  return out
end

-- Deep-copy ignore regions: {{start_sec=N, end_sec=N}, ...}
local function copy_regions(arr)
  if not arr then return {} end
  local out = {}
  for i, r in ipairs(arr) do
    out[i] = { start_sec = r.start_sec, end_sec = r.end_sec }
  end
  return out
end

-- Snapshot current marker state and push onto undo stack (max 50 entries).
-- Detected markers are omitted — they are deterministic from analysis + params
-- and recomputed on restore via redetect trigger.
-- Forward-declared near the top of the file; `function push_undo` (no `local`)
-- assigns to that existing local so earlier references bind as upvalues.
function push_undo(file)
  file.undo_stack[#file.undo_stack + 1] = {
    manual_markers   = copy_markers(file.manual_markers),
    ignore_regions   = copy_regions(file.ignore_regions),
    has_manual_edits = file.has_manual_edits,
  }
  -- Cap stack size
  if #file.undo_stack > 50 then
    table.remove(file.undo_stack, 1)
  end
  -- Clear redo stack on new action
  file.redo_stack = {}
end

-- Undo: restore previous state, push current onto redo stack.
-- Triggers redetection since ignore_regions may have changed.
local function perform_undo(file, state)
  if #file.undo_stack == 0 then return end
  -- Push current state to redo
  file.redo_stack[#file.redo_stack + 1] = {
    manual_markers   = copy_markers(file.manual_markers),
    ignore_regions   = copy_regions(file.ignore_regions),
    has_manual_edits = file.has_manual_edits,
  }
  if #file.redo_stack > 50 then table.remove(file.redo_stack, 1) end
  -- Pop and restore
  local snap = table.remove(file.undo_stack)
  file.manual_markers   = snap.manual_markers
  file.ignore_regions   = snap.ignore_regions
  file.has_manual_edits = snap.has_manual_edits
  state.selected_marker = nil
  state.drag_active = false
  -- Trigger redetection (ignore regions may have changed)
  state.params_changed_ts = reaper.time_precise()
end

-- Redo: restore next state, push current onto undo stack.
-- Triggers redetection since ignore_regions may have changed.
local function perform_redo(file, state)
  if #file.redo_stack == 0 then return end
  -- Push current state to undo
  file.undo_stack[#file.undo_stack + 1] = {
    manual_markers   = copy_markers(file.manual_markers),
    ignore_regions   = copy_regions(file.ignore_regions),
    has_manual_edits = file.has_manual_edits,
  }
  -- Pop and restore
  local snap = table.remove(file.redo_stack)
  file.manual_markers   = snap.manual_markers
  file.ignore_regions   = snap.ignore_regions
  file.has_manual_edits = snap.has_manual_edits
  state.selected_marker = nil
  state.drag_active = false
  -- Trigger redetection (ignore regions may have changed)
  state.params_changed_ts = reaper.time_precise()
end

-- Check if a time falls within any ignore region. Returns region index or nil.
local function find_ignore_region(t, ignore_regions)
  for i, r in ipairs(ignore_regions) do
    if t >= r.start_sec and t <= r.end_sec then return i end
  end
  return nil
end

-- Handle waveform interaction (zoom, pan, marker add/select/move/delete, ignore regions).
-- Called after InvisibleButton in render_waveform_preview.
local function handle_waveform_interaction(ctx, state, file, draw_x, draw_w, wave_y, wave_h, markers)
  local R = reaper
  local dur = file.wav_info and file.wav_info.duration or 0
  if dur <= 0 then return end

  local wf_hovered = R.ImGui_IsItemHovered(ctx)

  -- Mouse wheel: plain wheel = pan, Ctrl+Shift+wheel = zoom-to-cursor
  if wf_hovered then
    local wheel = R.ImGui_GetMouseWheel(ctx)
    if wheel ~= 0 then
      local mods = R.ImGui_GetKeyMods(ctx)
      local ctrl_shift = (mods & R.ImGui_Mod_Ctrl()) ~= 0
                     and (mods & R.ImGui_Mod_Shift()) ~= 0

      if ctrl_shift then
        -- Zoom to cursor (Ctrl+Shift+wheel)
        local mouse_x = select(1, R.ImGui_GetMousePos(ctx))
        local cursor_frac = (mouse_x - draw_x) / draw_w
        local time_frac = file.scroll_offset + cursor_frac / file.zoom

        if wheel > 0 then
          file.zoom = math.min(file.zoom * CONFIG.zoom_factor, CONFIG.zoom_max)
        else
          file.zoom = math.max(file.zoom / CONFIG.zoom_factor, 1.0)
        end

        file.scroll_offset = time_frac - cursor_frac / file.zoom
        clamp_scroll(file)
        file.zoom_peaks_key = nil
      else
        -- Pan (plain wheel)
        local pan_step = 0.1 / file.zoom
        file.scroll_offset = file.scroll_offset - wheel * pan_step
        clamp_scroll(file)
        file.zoom_peaks_key = nil
      end
    end
  end

  -- Single left click on detected marker: promote to gold
  if R.ImGui_IsItemClicked(ctx, 0) and not R.ImGui_IsMouseDoubleClicked(ctx, 0) then
    local mouse_x = select(1, R.ImGui_GetMousePos(ctx))
    local hit_idx, hit_source, hit_ok = find_nearest_marker(mouse_x, draw_x, draw_w, file, dur, markers)

    if hit_ok and (hit_source == "detected" or hit_source == "existing") then
      -- Promote detected/existing → manual
      local merged_m = markers[hit_idx]
      local orig_idx = merged_m._idx
      local src_list = hit_source == "detected" and file.detected_markers or file.existing_markers
      if src_list and src_list[orig_idx] then
        push_undo(file)
        local m = src_list[orig_idx]
        file.manual_markers[#file.manual_markers + 1] = { time_sec = m.time_sec, label = m.label }
        table.remove(src_list, orig_idx)
        file.has_manual_edits = true
        state.selected_marker = { source = "manual", idx = #file.manual_markers }
      end
    elseif hit_ok and hit_source == "manual" then
      -- Select the manual marker (for potential double-click+drag)
      state.selected_marker = { source = "manual", idx = markers[hit_idx]._idx }
    end
  end

  -- Double-click: add marker or start drag on existing marker
  if wf_hovered and R.ImGui_IsMouseDoubleClicked(ctx, 0) then
    local mouse_x = select(1, R.ImGui_GetMousePos(ctx))
    local hit_idx, hit_source, hit_ok = find_nearest_marker(mouse_x, draw_x, draw_w, file, dur, markers)

    if hit_ok then
      -- Select marker for drag
      state.selected_marker = { source = hit_source, idx = markers[hit_idx]._idx }
      state.drag_active = false
      state.drag_start_time = markers[hit_idx].time_sec
    else
      -- Add manual marker at click position
      push_undo(file)
      local t = pixel_to_time(mouse_x, draw_x, draw_w, file, dur)
      t = math.max(0, math.min(t, dur))
      local label = string.format("M%d", #file.manual_markers + 1)
      file.manual_markers[#file.manual_markers + 1] = { time_sec = t, label = label }
      file.has_manual_edits = true
      state.selected_marker = { source = "manual", idx = #file.manual_markers }
      state.drag_active = false
    end
  end

  -- Left-button drag: move selected marker (after double-click selects it)
  local wf_active = R.ImGui_IsItemActive(ctx)
  if wf_active and R.ImGui_IsMouseDown(ctx, 0) then
    if state.selected_marker and not state.drag_active then
      local drag_dx = select(1, R.ImGui_GetMouseDragDelta(ctx, 0))
      if math.abs(drag_dx) > CONFIG.drag_deadzone_px then
        push_undo(file)  -- snapshot before drag begins
        state.drag_active = true
      end
    end

    if state.drag_active and state.selected_marker then
      local mouse_x = select(1, R.ImGui_GetMousePos(ctx))
      local new_t = pixel_to_time(mouse_x, draw_x, draw_w, file, dur)
      new_t = math.max(0, math.min(new_t, dur))

      local sel = state.selected_marker
      if sel.source == "manual" and file.manual_markers[sel.idx] then
        file.manual_markers[sel.idx].time_sec = new_t
      elseif sel.source == "detected" or sel.source == "existing" then
        -- Promote to manual on drag (remove from source list)
        local src_list = sel.source == "detected" and file.detected_markers or file.existing_markers
        if src_list and src_list[sel.idx] then
          local m = src_list[sel.idx]
          file.manual_markers[#file.manual_markers + 1] = { time_sec = new_t, label = m.label }
          table.remove(src_list, sel.idx)
          file.has_manual_edits = true
          state.selected_marker = { source = "manual", idx = #file.manual_markers }
        end
      end
    end
  else
    if state.drag_active then
      state.drag_active = false
    end
  end

  -- Right-click: delete manual marker, remove ignore region, or start ignore region drag
  if wf_hovered and R.ImGui_IsMouseClicked(ctx, 1) then
    local mouse_x = select(1, R.ImGui_GetMousePos(ctx))
    local hit_idx, hit_source, hit_ok = find_nearest_marker(mouse_x, draw_x, draw_w, file, dur, markers)

    if hit_ok and (hit_source == "manual" or hit_source == "detected" or hit_source == "existing") then
      -- Delete marker from its source list
      local orig_idx = markers[hit_idx]._idx
      local src_list
      if hit_source == "manual" then src_list = file.manual_markers
      elseif hit_source == "detected" then src_list = file.detected_markers
      else src_list = file.existing_markers end
      if src_list and src_list[orig_idx] then
        push_undo(file)
        table.remove(src_list, orig_idx)
        state.selected_marker = nil
        file.has_manual_edits = true
      end
    else
      -- Check if inside an existing ignore region -> remove it
      local t = pixel_to_time(mouse_x, draw_x, draw_w, file, dur)
      local region_idx = find_ignore_region(t, file.ignore_regions)
      if region_idx then
        push_undo(file)
        table.remove(file.ignore_regions, region_idx)
        -- Re-detect since a suppression region was removed
        state.params_changed_ts = R.time_precise()
      else
        -- Start ignore region drag
        state.ignore_drag = { active = true, start_sec = t }
      end
    end
  end

  -- Right-button drag: extend ignore region
  if state.ignore_drag and state.ignore_drag.active then
    if R.ImGui_IsMouseDown(ctx, 1) then
      -- Still dragging -- region preview is drawn in render function
    else
      -- Released: finalize ignore region
      local mouse_x = select(1, R.ImGui_GetMousePos(ctx))
      local end_sec = pixel_to_time(mouse_x, draw_x, draw_w, file, dur)
      local start_sec = state.ignore_drag.start_sec
      -- Normalize so start < end
      if end_sec < start_sec then start_sec, end_sec = end_sec, start_sec end
      -- Only create region if it spans a minimum duration (>50ms)
      if end_sec - start_sec > 0.05 then
        push_undo(file)
        file.ignore_regions[#file.ignore_regions + 1] = { start_sec = start_sec, end_sec = end_sec }
        -- Erase existing markers within drag range
        if file.existing_markers then
          for k = #file.existing_markers, 1, -1 do
            local m = file.existing_markers[k]
            if m.time_sec >= start_sec and m.time_sec <= end_sec then
              table.remove(file.existing_markers, k)
              file.has_manual_edits = true
            end
          end
        end
        -- Erase manual markers within drag range
        if file.manual_markers then
          for k = #file.manual_markers, 1, -1 do
            local m = file.manual_markers[k]
            if m.time_sec >= start_sec and m.time_sec <= end_sec then
              table.remove(file.manual_markers, k)
            end
          end
        end
        -- Re-detect to suppress markers in the new region
        state.params_changed_ts = R.time_precise()
      end
      state.ignore_drag = nil
    end
  end

  -- Ctrl+Z: undo, Ctrl+Y: redo
  if wf_hovered then
    local mods = R.ImGui_GetKeyMods(ctx)
    local ctrl = (mods & R.ImGui_Mod_Ctrl()) ~= 0
    if ctrl and R.ImGui_IsKeyPressed(ctx, R.ImGui_Key_Z()) then
      perform_undo(file, state)
    elseif ctrl and R.ImGui_IsKeyPressed(ctx, R.ImGui_Key_Y()) then
      perform_redo(file, state)
    end
  end
end

local function render_waveform_preview(ctx, state, w, h, cur_markers)
  local R = reaper
  local dl = R.ImGui_GetWindowDrawList(ctx)
  local x, y = R.ImGui_GetCursorScreenPos(ctx)

  -- Background
  R.ImGui_DrawList_AddRectFilled(dl, x, y, x + w, y + h,
    SC and SC.WINDOW or 0x0E0E10FF)

  local file = state.current_idx and state.files[state.current_idx]
  if not file then
    -- Empty state
    local font_b = rsg_theme and rsg_theme.font_bold
    if font_b then R.ImGui_PushFont(ctx, font_b, 13) end
    local text
    if #state.files > 0 then
      text = "Select a file"
    elseif state.input_mode == "session" then
      text = "Select items in arrange and click + Add"
    else
      text = state.root_folder and "Select a file" or "Scan a folder to begin"
    end
    local text_color = SC and SC.TEXT_MUTED or 0xBCC9C6FF
    local tw = R.ImGui_CalcTextSize(ctx, text)
    R.ImGui_DrawList_AddText(dl, x + (w - tw) / 2, y + h / 2 - 7, text_color, text)
    if font_b then R.ImGui_PopFont(ctx) end
    R.ImGui_Dummy(ctx, w, h)
    return
  end

  local font_b = rsg_theme and rsg_theme.font_bold
  if font_b then R.ImGui_PushFont(ctx, font_b, 13) end

  -- Filename header + zoom indicator
  local title_color = SC and SC.TEXT_ON or 0xDEDEDEFF
  local info_color = SC and SC.TEXT_MUTED or 0xBCC9C6FF
  R.ImGui_DrawList_AddText(dl, x + 8, y + 6, title_color, file.filename)
  if file.zoom > 1.01 then
    local zoom_text = string.format("%.0fx", file.zoom)
    local zoom_tw = R.ImGui_CalcTextSize(ctx, zoom_text)
    R.ImGui_DrawList_AddText(dl, x + w - zoom_tw - 8, y + 6, info_color, zoom_text)
  end

  -- Header action links (right-aligned, drawn right-to-left)
  local header_right = x + w - 8
  if file.zoom > 1.01 then
    local zoom_text = string.format("%.0fx", file.zoom)
    local zoom_tw = R.ImGui_CalcTextSize(ctx, zoom_text)
    header_right = header_right - zoom_tw - 8
  end

  -- Reset link
  if file.has_manual_edits or #file.ignore_regions > 0 then
    local reset_text = "[Reset]"
    local reset_tw = R.ImGui_CalcTextSize(ctx, reset_text)
    header_right = header_right - reset_tw
    R.ImGui_DrawList_AddText(dl, header_right, y + 6,
      SC and SC.TERTIARY or 0xDA7C5AFF, reset_text)
    header_right = header_right - 8
  end

  -- Embed link (per-file)
  if #cur_markers > 0 and state.status ~= "embedding" then
    local embed_text = "[Embed]"
    local embed_tw = R.ImGui_CalcTextSize(ctx, embed_text)
    header_right = header_right - embed_tw
    local embed_color = file.freshly_embedded
      and (SC and SC.FRESHLY_EMBEDDED or 0x4CAF50FF)
      or (SC and SC.PRIMARY or 0x26A69AFF)
    R.ImGui_DrawList_AddText(dl, header_right, y + 6, embed_color, embed_text)
    -- Store hit area for click detection (checked in handle_waveform_interaction)
    state._embed_btn = { x = header_right, y = y + 2, w = embed_tw, h = 18 }
  else
    state._embed_btn = nil
  end

  -- Info line
  if file.wav_info then
    local info_text = string.format("%s  |  %d Hz  %dch  %dbit  |  %s",
      format_size(file.size),
      file.wav_info.sample_rate, file.wav_info.channels, file.wav_info.bits_per_sample,
      format_duration(file.wav_info.duration))
    R.ImGui_DrawList_AddText(dl, x + 8, y + 22, info_color, info_text)
  end

  -- Waveform area (reserve 14px at bottom for ruler)
  local ruler_h = 14
  local wave_y = y + 42
  local wave_h_inner = h - 72 - ruler_h
  local wave_mid = wave_y + wave_h_inner / 2

  -- Center line
  R.ImGui_DrawList_AddLine(dl, x + 8, wave_mid, x + w - 8, wave_mid,
    (SC and SC.PANEL_HIGH or 0x282828FF), 1.0)

  -- Lazy overview peak loading (zoom=1x fallback)
  if not file.mipmap then
    file.mipmap = mark_analysis.read_peaks(file.path, CONFIG.analysis_mipmap_width)
    if not file.mipmap and file.analysis and file.analysis.complete then
      file.mipmap = mark_analysis.build_mipmap(file.analysis, CONFIG.analysis_mipmap_width)
    end
  end

  -- Waveform drawing
  local draw_x = x + 8
  local draw_w = math.max(1, w - 16)
  local half_h = wave_h_inner / 2
  local dur = file.wav_info and file.wav_info.duration or 0

  local mip  -- the peak data to render this frame
  if file.mipmap and file.mipmap.width > 0 then
    if file.zoom > 1.01 and dur > 0 then
      -- Dynamic peak query for zoomed view
      local visible_frac = 1.0 / file.zoom
      local t_start = file.scroll_offset * dur
      local t_end = (file.scroll_offset + visible_frac) * dur
      local cache_key = string.format("%.4f|%.4f|%d", t_start, t_end, draw_w)
      if file.zoom_peaks_key ~= cache_key then
        file.zoom_peaks = mark_analysis.read_peaks_range(file.path, t_start, t_end, draw_w)
        file.zoom_peaks_key = cache_key
      end
      mip = file.zoom_peaks or file.mipmap
    else
      mip = file.mipmap
    end
  end

  if mip and mip.width > 0 then
    local wave_color = SC and SC.PRIMARY or 0x26A69AFF
    for i = 0, draw_w - 1 do
      local src = math.floor(i / draw_w * mip.width) + 1
      if src > mip.width then src = mip.width end
      local top = wave_mid - mip.peak_pos[src] * half_h
      local bot = wave_mid - mip.peak_neg[src] * half_h
      R.ImGui_DrawList_AddLine(dl, draw_x + i, top, draw_x + i, bot, wave_color, 1.0)
    end
  elseif file.analysis and not file.analysis.complete then
    -- Analysis in progress
    local pct = 0
    if state.active_analysis and state.analysis_file_idx == state.current_idx then
      local actx = state.active_analysis
      pct = actx.total_hops > 0 and math.floor(actx._hop_idx / actx.total_hops * 100) or 0
    end
    local ph_text = string.format("Analyzing... %d%%", pct)
    local ph_tw = R.ImGui_CalcTextSize(ctx, ph_text)
    R.ImGui_DrawList_AddText(dl, x + (w - ph_tw) / 2, wave_mid - 7, info_color, ph_text)
  else
    local ph_text = "Pending analysis"
    local ph_tw = R.ImGui_CalcTextSize(ctx, ph_text)
    R.ImGui_DrawList_AddText(dl, x + (w - ph_tw) / 2, wave_mid - 7, info_color, ph_text)
  end

  -- Draw ignore regions (semi-transparent red overlay)
  if #file.ignore_regions > 0 and dur > 0 then
    local visible_frac = 1.0 / file.zoom
    local vis_start = file.scroll_offset
    local vis_end = vis_start + visible_frac
    local ignore_color = 0xC0392B40  -- red, semi-transparent
    for _, rgn in ipairs(file.ignore_regions) do
      local r_start = rgn.start_sec / dur
      local r_end = rgn.end_sec / dur
      if r_end > vis_start and r_start < vis_end then
        local px_left = math.max(draw_x, (r_start - vis_start) / visible_frac * draw_w + draw_x)
        local px_right = math.min(draw_x + draw_w, (r_end - vis_start) / visible_frac * draw_w + draw_x)
        R.ImGui_DrawList_AddRectFilled(dl, px_left, wave_y, px_right, wave_y + wave_h_inner, ignore_color)
      end
    end
  end

  -- Draw in-progress ignore region drag preview
  if state.ignore_drag and state.ignore_drag.active and dur > 0 then
    local mouse_x = select(1, R.ImGui_GetMousePos(ctx))
    local drag_end_sec = pixel_to_time(mouse_x, draw_x, draw_w, file, dur)
    local drag_start_sec = state.ignore_drag.start_sec
    local visible_frac = 1.0 / file.zoom
    local vis_start = file.scroll_offset
    local s_frac = drag_start_sec / dur
    local e_frac = drag_end_sec / dur
    if s_frac > e_frac then s_frac, e_frac = e_frac, s_frac end
    local px_left = math.max(draw_x, (s_frac - vis_start) / visible_frac * draw_w + draw_x)
    local px_right = math.min(draw_x + draw_w, (e_frac - vis_start) / visible_frac * draw_w + draw_x)
    R.ImGui_DrawList_AddRectFilled(dl, px_left, wave_y, px_right, wave_y + wave_h_inner, 0xC0392B60)
  end

  -- Draw marker lines (on top of waveform)
  local markers = cur_markers
  if #markers > 0 and dur > 0 then
    local visible_frac = 1.0 / file.zoom
    local vis_start = file.scroll_offset
    local vis_end = vis_start + visible_frac
    for _, m in ipairs(markers) do
      local frac = m.time_sec / dur
      if frac >= vis_start and frac <= vis_end then
        local mx = (frac - vis_start) / visible_frac * draw_w + draw_x

        -- Per-source color
        local marker_color
        if m._source == "existing" then
          marker_color = SC and SC.PRIMARY or 0x26A69AFF
        elseif m._source == "detected" then
          marker_color = SC and SC.TERTIARY or 0xDA7C5AFF
        else
          marker_color = SC and SC.MANUAL_MARK or 0xF2C94CFF
        end

        -- Selected marker glow
        local is_selected = state.selected_marker
          and m._source == state.selected_marker.source
          and m._idx == state.selected_marker.idx
        if is_selected then
          R.ImGui_DrawList_AddLine(dl, mx, wave_y, mx, wave_y + wave_h_inner,
            (marker_color & 0xFFFFFF00) | 0x60, 3.0)
          R.ImGui_DrawList_AddLine(dl, mx, wave_y, mx, wave_y + wave_h_inner,
            marker_color, 2.0)
        else
          R.ImGui_DrawList_AddLine(dl, mx, wave_y, mx, wave_y + wave_h_inner,
            marker_color, 1.0)
        end
        -- Label suppressed: marker lines are self-explanatory without text
      end
    end
  end

  -- Timeline ruler at bottom of waveform
  if dur > 0 then
    local ruler_y = wave_y + wave_h_inner
    local ruler_color = SC and SC.TEXT_OFF or 0x505050FF
    local tick_color = SC and SC.PANEL_HIGH or 0x282828FF

    -- Top edge line
    R.ImGui_DrawList_AddLine(dl, draw_x, ruler_y, draw_x + draw_w, ruler_y, tick_color, 1.0)

    -- Choose tick interval based on visible duration
    local visible_frac = 1.0 / file.zoom
    local vis_dur = visible_frac * dur
    -- Pick a nice interval: 0.1, 0.25, 0.5, 1, 2, 5, 10, 30, 60 seconds
    local intervals = { 0.1, 0.25, 0.5, 1, 2, 5, 10, 30, 60, 120, 300 }
    local tick_interval = intervals[#intervals]
    for _, iv in ipairs(intervals) do
      if vis_dur / iv <= 20 then  -- aim for max ~20 ticks
        tick_interval = iv
        break
      end
    end

    local vis_start_sec = file.scroll_offset * dur
    local vis_end_sec = vis_start_sec + vis_dur
    local first_tick = math.ceil(vis_start_sec / tick_interval) * tick_interval

    local t = first_tick
    while t <= vis_end_sec do
      local frac = t / dur
      local tx = (frac - file.scroll_offset) / visible_frac * draw_w + draw_x

      if tx >= draw_x and tx <= draw_x + draw_w then
        -- Tick mark
        R.ImGui_DrawList_AddLine(dl, tx, ruler_y, tx, ruler_y + 4, ruler_color, 1.0)

        -- Time label (m:ss or s.d format)
        local label
        if t >= 60 then
          local m = math.floor(t / 60)
          local s = t - m * 60
          label = string.format("%d:%04.1f", m, s)
        elseif tick_interval < 1 then
          label = string.format("%.1fs", t)
        else
          label = string.format("%.0fs", t)
        end
        local lw = R.ImGui_CalcTextSize(ctx, label)
        if tx + 2 + lw <= draw_x + draw_w then
          R.ImGui_DrawList_AddText(dl, tx + 2, ruler_y + 2, ruler_color, label)
        end
      end

      t = t + tick_interval
    end
  end

  if font_b then R.ImGui_PopFont(ctx) end

  -- InvisibleButton for interaction (replaces Dummy)
  R.ImGui_InvisibleButton(ctx, "##waveform_hit", w, h)

  -- Handle interaction (zoom, pan, markers)
  if file.wav_info then
    handle_waveform_interaction(ctx, state, file, draw_x, draw_w, wave_y, wave_h_inner, markers)
  end

  -- Handle Reset click (check if mouse is in the reset text area)
  local has_user_edits = file.has_manual_edits or #file.ignore_regions > 0
  if has_user_edits and R.ImGui_IsItemHovered(ctx) then
    local mouse_x, mouse_y = R.ImGui_GetMousePos(ctx)
    if mouse_y >= y + 2 and mouse_y <= y + 18 then
      local reset_text = "[Reset]"
      local reset_tw = R.ImGui_CalcTextSize(ctx, reset_text)
      local reset_x = x + w - reset_tw - 8
      if file.zoom > 1.01 then
        local zoom_text = string.format("%.0fx", file.zoom)
        local zoom_tw = R.ImGui_CalcTextSize(ctx, zoom_text)
        reset_x = reset_x - zoom_tw - 8
      end
      if mouse_x >= reset_x and mouse_x <= reset_x + reset_tw then
        if R.ImGui_IsMouseClicked(ctx, 0) then
          push_undo(file)
          file.manual_markers = {}
          file.ignore_regions = {}
          file.has_manual_edits = false
          state.selected_marker = nil
          -- Trigger redetection for this file
          if file.analysis and file.analysis.complete then
            local params = {
              silence_db  = state.silence_db,
              sensitivity = state.sensitivity,
              spacing_ms  = state.spacing_ms,
            }
            file.detected_markers = mark_analysis.detect_markers(
              file.analysis, params, file.existing_markers or {}, file.ignore_regions)
            if #file.detected_markers > 0 and file.status ~= "embedded" then
              file.status = "detected"
            end
          end
        end
      end
    end
  end

  -- Handle Embed click
  if state._embed_btn and R.ImGui_IsItemHovered(ctx) then
    local mouse_x, mouse_y = R.ImGui_GetMousePos(ctx)
    local eb = state._embed_btn
    if mouse_x >= eb.x and mouse_x <= eb.x + eb.w
       and mouse_y >= eb.y and mouse_y <= eb.y + eb.h then
      if R.ImGui_IsMouseClicked(ctx, 0) then
        start_embed_single(state, state.current_idx)
      end
    end
  end
end

-- ============================================================
-- Render: Footer / status bar
-- ============================================================

local function render_footer(ctx, state, w)
  local R = reaper
  local font_b = rsg_theme and rsg_theme.font_bold
  if font_b then R.ImGui_PushFont(ctx, font_b, 13) end

  local status_text
  local status_color
  if state.status == "enumerating" then
    status_text = string.format("Discovering files... %d found", #state.files)
    status_color = SC and SC.TEXT_MUTED or 0xBCC9C6FF
  elseif state.status == "scanning" then
    local pct = state.scan_total > 0
      and math.floor(state.scan_read_idx / state.scan_total * 100) or 0
    status_text = string.format("Reading markers... %d%%  (%d/%d files)",
      pct, state.scan_read_idx - 1, state.scan_total)
    status_color = SC and SC.TEXT_MUTED or 0xBCC9C6FF
  elseif state.status == "analyzing" then
    local files_done = state.analysis_queue_pos - 1
    local files_total = #state.analysis_queue
    local overall_pct = files_total > 0 and math.floor(files_done / files_total * 100) or 0
    local file_pct = 0
    if state.active_analysis then
      local actx = state.active_analysis
      file_pct = actx.total_hops > 0 and math.floor(actx._hop_idx / actx.total_hops * 100) or 0
    end
    status_text = string.format("Analyzing... %d%%  (%d/%d files)  [file: %d%%]",
      overall_pct, files_done, files_total, file_pct)
    status_color = SC and SC.TERTIARY or 0xDA7C5AFF
  elseif state.status == "embedding" then
    local done = state.embed_queue_pos - 1
    local total = #state.embed_queue
    status_text = string.format("Embedding... %d/%d files", done, total)
    status_color = SC and SC.FRESHLY_EMBEDDED or 0x4CAF50FF
  elseif state.status == "ready" and #state.files > 0 then
    local n_embedded = 0
    local n_detected = 0
    for _, f in ipairs(state.files) do
      if f.status == "embedded" then n_embedded = n_embedded + 1 end
      if f.status == "detected" then n_detected = n_detected + 1 end
    end
    local n_selected = 0
    for _ in pairs(state.selected_indices) do n_selected = n_selected + 1 end
    local sel_seg = n_selected > 0
      and string.format("  |  %d selected", n_selected)
      or ""
    status_text = string.format("%d files  |  %d with markers  |  %d detected%s",
      #state.files, n_embedded, n_detected, sel_seg)
    status_color = SC and SC.PRIMARY or 0x26A69AFF
  elseif state.status == "idle" then
    status_text = state.input_mode == "session"
      and "Select items in arrange and click + Add"
      or "Scan a folder to begin"
    status_color = SC and SC.TEXT_MUTED or 0xBCC9C6FF
  else
    status_text = state.error_msg or ""
    status_color = SC and SC.ERROR_RED or 0xC0392BFF
  end

  -- Transient footer warning overlay (3-second display)
  if state.footer_warning and state.footer_warning_ts then
    if R.time_precise() - state.footer_warning_ts < 3.0 then
      status_text = state.footer_warning
      status_color = SC and SC.TERTIARY or 0xDA7C5AFF
    else
      state.footer_warning = nil
      state.footer_warning_ts = nil
    end
  end

  R.ImGui_TextColored(ctx, status_color, status_text or "")

  if font_b then R.ImGui_PopFont(ctx) end
end

-- ============================================================
-- Main render function
-- ============================================================

local function render_gui(ctx, state, lic, lic_status)
  local R = reaper
  local win_w = select(1, R.ImGui_GetContentRegionAvail(ctx))
  local win_h = select(2, R.ImGui_GetContentRegionAvail(ctx))

  -- Pre-compute effective markers for current file (avoids 4 redundant calls per frame)
  local cur_file = state.current_idx and state.files[state.current_idx]
  local cur_markers = cur_file and effective_markers(cur_file, state.auto_detect) or {}

  -- Row 1: Title bar
  render_title_bar(ctx, win_w, state, lic, lic_status)

  -- Row 2: Controls
  render_controls(ctx, state, cur_file, cur_markers)
  R.ImGui_Spacing(ctx)

  -- Row 3: Main content (file list + waveform)
  local footer_h = 20
  local main_h = win_h - R.ImGui_GetCursorPosY(ctx) - footer_h - 4
  if main_h < 50 then main_h = 50 end

  -- Left: File list
  render_file_list(ctx, state, main_h)

  -- Right: Waveform preview
  R.ImGui_SameLine(ctx, 0, 8)
  local right_w = win_w - CONFIG.file_list_w - 8
  if right_w < 100 then right_w = 100 end
  render_waveform_preview(ctx, state, right_w, main_h, cur_markers)

  -- Row 5: Footer
  render_footer(ctx, state, win_w)
end

-- Settings popup (opened by gear button in title bar)
render_settings_popup = function(ctx, state, lic, lic_status)
  local R = reaper
  if not R.ImGui_BeginPopup(ctx, "##settings_popup_mark") then return end
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_HeaderHovered(),
    SC and SC.HOVER_LIST or 0x39393BFF)

  R.ImGui_TextDisabled(ctx, "Settings")
  R.ImGui_Separator(ctx)
  R.ImGui_Spacing(ctx)

  if R.ImGui_Button(ctx, "Close##settings_close") then
    state.should_close = true
    R.ImGui_CloseCurrentPopup(ctx)
  end

  if lic_status == "trial" and lic then
    R.ImGui_Spacing(ctx)
    R.ImGui_Separator(ctx)
    R.ImGui_Spacing(ctx)
    if R.ImGui_Selectable(ctx, "Activate\xE2\x80\xA6##mark_activate") then
      lic.open_dialog(ctx)
      R.ImGui_CloseCurrentPopup(ctx)
    end
  end

  R.ImGui_PopStyleColor(ctx, 1)
  R.ImGui_EndPopup(ctx)
end

-- ============================================================
-- Chunked analysis (non-blocking)
-- ============================================================

-- Build the analysis queue after cue reading completes.
-- Restores cached results, queues uncached files for analysis.
local function build_analysis_queue(state)
  state.analysis_queue = {}
  state.analysis_queue_pos = 1
  local params = {
    silence_db  = state.silence_db,
    sensitivity = state.sensitivity,
    spacing_ms  = state.spacing_ms,
  }
  for i, file in ipairs(state.files) do
    if file.wav_info then
      local key = analysis_cache_key(file)
      local cached = state.analysis_cache[key]
      if cached then
        -- Restore from cache and re-detect with current params
        file.analysis = cached
        file.mipmap = nil  -- rebuilt lazily in render
        file.detected_markers = mark_analysis.detect_markers(cached, params, file.existing_markers or {}, file.ignore_regions)
        if #file.detected_markers > 0 and file.status ~= "embedded" then
          file.status = "detected"
        end
      else
        state.analysis_queue[#state.analysis_queue + 1] = i
      end
    end
  end
end

-- Process one step of the analysis queue per frame.
local function tick_analysis(state)
  local params = {
    silence_db  = state.silence_db,
    sensitivity = state.sensitivity,
    spacing_ms  = state.spacing_ms,
  }

  -- Start next file if no active analysis
  if not state.active_analysis then
    if state.analysis_queue_pos > #state.analysis_queue then
      state.status = "ready"
      return
    end
    local file_idx = state.analysis_queue[state.analysis_queue_pos]
    local file = state.files[file_idx]
    if not file then
      -- File was removed while queued; skip to next
      state.analysis_queue_pos = state.analysis_queue_pos + 1
      return
    end
    local actx = mark_analysis.analysis_begin(file.path, file.wav_info)
    if not actx then
      file.status = "error"
      state.analysis_queue_pos = state.analysis_queue_pos + 1
      return
    end
    state.active_analysis = actx
    state.analysis_file_idx = file_idx
    return
  end

  -- Continue active analysis
  local done = mark_analysis.analysis_step(state.active_analysis, CONFIG.analysis_hops_per_frame)
  if done then
    local file_idx = state.analysis_file_idx
    local file = state.files[file_idx]
    local actx = state.active_analysis

    if not file then
      -- File was removed during analysis; discard results
      state.active_analysis = nil
      state.analysis_file_idx = nil
      state.analysis_queue_pos = state.analysis_queue_pos + 1
      return
    end

    -- Store completed analysis
    file.analysis = actx
    state.analysis_cache[analysis_cache_key(file)] = actx

    -- Run detection
    file.detected_markers = mark_analysis.detect_markers(actx, params, file.existing_markers or {}, file.ignore_regions)
    if #file.detected_markers > 0 and file.status ~= "embedded" then
      file.status = "detected"
    end

    -- Build mipmap if this is the currently selected file
    if state.current_idx == file_idx then
      file.mipmap = mark_analysis.build_mipmap(actx, CONFIG.analysis_mipmap_width)
    end

    state.active_analysis = nil
    state.analysis_file_idx = nil
    state.analysis_queue_pos = state.analysis_queue_pos + 1
  end
end

-- Re-detect markers on all analyzed files (called after parameter change debounce).
-- Respects ignore regions; manual (gold) markers are independent and unaffected.
local function redetect_all(state)
  local params = {
    silence_db  = state.silence_db,
    sensitivity = state.sensitivity,
    spacing_ms  = state.spacing_ms,
  }
  for _, file in ipairs(state.files) do
    if file.analysis and file.analysis.complete then
      file.detected_markers = mark_analysis.detect_markers(
        file.analysis, params, file.existing_markers or {}, file.ignore_regions)
      if #file.detected_markers > 0 and file.status ~= "embedded" then
        file.status = "detected"
      elseif #file.detected_markers == 0 and file.status == "detected"
        and #(file.manual_markers or {}) == 0 then
        file.status = "pending"
      end
    end
  end
end

-- ============================================================
-- State machine tick
-- ============================================================

-- ============================================================
-- Chunked embedding (non-blocking, one file per frame)
-- ============================================================

start_embed_single = function(state, file_idx)
  state.embed_queue = { file_idx }
  state.embed_queue_pos = 1
  state.status = "embedding"
end

start_embed_all = function(state)
  -- Scope: selected files if any selected, otherwise all files
  -- Include any file that has been analyzed (not pending)
  local sel_count = 0
  for _ in pairs(state.selected_indices) do sel_count = sel_count + 1 end
  local queue = {}
  if sel_count > 0 then
    for idx in pairs(state.selected_indices) do
      local f = state.files[idx]
      if f and f.status ~= "pending" then
        queue[#queue + 1] = idx
      end
    end
    table.sort(queue)
  else
    for i, f in ipairs(state.files) do
      if f.status ~= "pending" then
        queue[#queue + 1] = i
      end
    end
  end
  if #queue == 0 then return end
  state.embed_queue = queue
  state.embed_queue_pos = 1
  state.status = "embedding"
end

local function tick_embedding(state)
  if state.embed_queue_pos > #state.embed_queue then
    state.status = "ready"
    return
  end

  local file_idx = state.embed_queue[state.embed_queue_pos]
  local file = state.files[file_idx]

  -- Merge all visible markers
  local markers = effective_markers(file, state.auto_detect)

  -- Strip labels from cue markers (avoid "Take N" in WAV cue chunks)
  for _, m in ipairs(markers) do m.label = "" end

  -- Session mode: release REAPER's file lock before embedding
  local session_take, old_src
  if file.session_item then
    local R = reaper
    if R.ValidatePtr(file.session_item, "MediaItem*") then
      session_take = R.GetActiveTake(file.session_item)
      if session_take then
        old_src = R.GetMediaItemTake_Source(session_take)
        if old_src then
          -- Detach source from take, then destroy it to release file handle
          local empty = R.PCM_Source_CreateFromType("EMPTY")
          R.SetMediaItemTake_Source(session_take, empty)
          R.PCM_Source_Destroy(old_src)
          old_src = nil
        end
      end
    else
      file.status = "error"
      file.error_msg = "Session item no longer valid"
      state.embed_queue_pos = state.embed_queue_pos + 1
      return
    end
  end

  -- Embed
  local ok, err = wav_io.embed_markers(file.path, markers)

  -- Session mode: re-attach source from modified file + write take markers
  if session_take then
    local R = reaper
    local new_src = R.PCM_Source_CreateFromFile(file.path)
    if new_src then
      R.SetMediaItemTake_Source(session_take, new_src)
    end
  end

  if ok then
    -- Round-trip verify: re-read cue markers from the written file
    local new_markers = wav_io.read_cue_markers(file.path)
    file.existing_markers = new_markers
    -- Clear editor state (now canonical in the WAV)
    file.detected_markers = {}
    file.manual_markers = {}
    file.ignore_regions = {}
    file.has_manual_edits = false
    file.undo_stack = {}
    file.redo_stack = {}
    file.status = "embedded"
    file.freshly_embedded = true
    -- Session mode: write take markers to the REAPER item
    if session_take then
      local R = reaper
      R.Undo_BeginBlock()
      R.PreventUIRefresh(1)
      local n = R.GetNumTakeMarkers(session_take)
      for ti = n - 1, 0, -1 do
        R.DeleteTakeMarker(session_take, ti)
      end
      for _, m in ipairs(new_markers) do
        R.SetTakeMarker(session_take, -1, " ", m.time_sec)
      end
      if R.ValidatePtr(file.session_item, "MediaItem*") then
        R.UpdateItemInProject(file.session_item)
      end
      R.PreventUIRefresh(-1)
      R.Undo_EndBlock("Temper Mark: embed take markers", -1)
    end
  else
    file.status = "error"
    file.error_msg = err or "embed failed"
  end

  state.embed_queue_pos = state.embed_queue_pos + 1
  if state.embed_queue_pos > #state.embed_queue then
    state.status = "ready"
  end
end

-- ============================================================
-- State machine
-- ============================================================

local function tick_state(state)
  if state.status == "enumerating" then
    local done = tick_enumeration(state)
    if done then
      if #state.files > 0 then
        state.scan_read_idx = 1
        state.scan_total = #state.files
        state.status = "scanning"
      else
        state.status = "ready"
      end
    end

  elseif state.status == "scanning" then
    local done = tick_cue_reading(state)
    if done then
      build_analysis_queue(state)
      if #state.analysis_queue > 0 then
        state.status = "analyzing"
      else
        state.status = "ready"
      end
    end

  elseif state.status == "analyzing" then
    tick_analysis(state)
    -- Allow param changes to re-detect already-analyzed files mid-scan
    if state.params_changed_ts then
      if reaper.time_precise() - state.params_changed_ts >= CONFIG.param_debounce_sec then
        state.params_changed_ts = nil
        redetect_all(state)
      end
    end

  elseif state.status == "embedding" then
    tick_embedding(state)

  elseif state.status == "ready" then
    -- Parameter change debounce: re-detect after slider idle
    if state.params_changed_ts then
      if reaper.time_precise() - state.params_changed_ts >= CONFIG.param_debounce_sec then
        state.params_changed_ts = nil
        redetect_all(state)
      end
    end
  end
end

-- ============================================================
-- Instance guard
-- ============================================================

local function check_instance_guard()
  local ts_str = reaper.GetExtState(_NS, "instance_ts")
  if ts_str and ts_str ~= "" then
    local ts = tonumber(ts_str)
    if ts and (reaper.time_precise() - ts) < 1.0 then
      reaper.ShowMessageBox(
        "Temper Mark is already running.",
        "Temper Mark", 0)
      return false
    end
  end
  return true
end

-- ============================================================
-- Entry point
-- ============================================================

do
  if not check_instance_guard() then return end

  local ctx = reaper.ImGui_CreateContext("Temper Mark##tmark")

  -- Load theme and attach fonts
  pcall(dofile, _lib .. "rsg_theme.lua")
  if type(rsg_theme) == "table" then
    rsg_theme.attach_fonts(ctx)
    SC = rsg_theme.SC
  else
    -- Fallback palette if theme fails to load
    SC = {
      WINDOW      = 0x0E0E10FF,
      PANEL       = 0x1E1E20FF,
      PANEL_HIGH  = 0x282828FF,
      PANEL_TOP   = 0x323232FF,
      HOVER_LIST  = 0x39393BFF,
      PRIMARY     = 0x26A69AFF,
      PRIMARY_LT  = 0x66D9CCFF,
      PRIMARY_HV  = 0x30B8ACFF,
      PRIMARY_AC  = 0x1A8A7EFF,
      TERTIARY    = 0xDA7C5AFF,
      TERTIARY_HV = 0xE08A6AFF,
      TERTIARY_AC = 0xC46A4AFF,
      MANUAL_MARK = 0xF2C94CFF,
      TEXT_ON     = 0xDEDEDEFF,
      TEXT_MUTED  = 0xBCC9C6FF,
      TEXT_OFF    = 0x505050FF,
      ERROR_RED   = 0xC0392BFF,
      TITLE_BAR   = 0x1A1A1CFF,
      ACTIVE_DARK = 0x141416FF,
      BORDER_INPUT = 0x505055FF,
      ICON_DISABLED = 0x606060FF,
    }
  end

  local _lic_ok, lic = pcall(dofile, _lib .. "rsg_license.lua")
  if not _lic_ok then lic = nil end
  if lic then lic.configure({
    namespace    = "TEMPER_Mark",
    scope_id     = 0x4,
    display_name = "Mark",
    buy_url      = "https://www.tempertools.com/scripts/mark",
  }) end

  local state = {
    -- State machine
    status           = "idle",          -- idle | enumerating | scanning | analyzing | embedding | ready | error
    error_msg        = nil,

    -- Folder context
    root_folder      = nil,
    files            = {},              -- [{path, filename, size, status, ...}]
    current_idx      = nil,             -- selected file index (into state.files)
    scan_read_idx    = 1,               -- next file to read cue markers from
    scan_progress    = 0,
    scan_total       = 0,

    -- Filter
    filter           = "all",           -- all | detected | embedded

    -- Detection parameters
    silence_db       = CONFIG.default_silence_db,
    sensitivity      = CONFIG.default_sensitivity,
    spacing_ms       = CONFIG.default_spacing_ms,
    params_changed_ts = nil,            -- debounce timer for param changes

    -- Analysis state
    analysis_cache     = {},            -- keyed by "path|size", stores completed analyses
    active_analysis    = nil,           -- current analysis context (from analysis_begin)
    analysis_file_idx  = nil,           -- index into state.files for active analysis
    analysis_queue     = {},            -- file indices pending analysis
    analysis_queue_pos = 1,             -- current position in analysis queue

    -- Waveform interaction (Phase 3)
    selected_marker  = nil,           -- {source, idx} or nil
    drag_active      = false,
    drag_start_time  = nil,           -- time_sec at drag start (for undo)
    ignore_drag      = nil,           -- {active, start_sec} during right-click+drag
    auto_detect      = true,          -- false = manual-only mode (no generated markers)

    -- Embedding queue
    embed_queue      = {},
    embed_queue_pos  = 1,

    -- File list multi-select
    selected_indices   = {},         -- set: selected_indices[j] = true
    last_click_idx     = nil,        -- anchor for Shift+click range
    _scroll_to_current = false,      -- scroll file list to current_idx next frame

    -- Input mode (folder scan vs session items)
    input_mode       = "folder",     -- "folder" | "session"
    footer_warning   = nil,          -- transient warning text (e.g. "Skipped 2 non-WAV items")
    footer_warning_ts = nil,         -- time_precise() when warning was set

    -- Control
    should_close     = false,

    -- rsg_actions keyboard-dispatch flash feedback. Maps button_key ->
    -- expires_at timestamp; render_controls swaps the matching button's
    -- Col_Button + Col_ButtonHovered to a pressed shade until the timer
    -- expires, mimicking the mouse-click feedback keyboard paths skip.
    _btn_flash       = {},
  }

  -- Restore last folder and auto-detect preference from ExtState
  local last_folder = reaper.GetExtState(_NS, "last_folder")
  if last_folder and last_folder ~= "" then
    state.root_folder = last_folder
  end
  local ad = reaper.GetExtState(_NS, "auto_detect")
  if ad == "0" then state.auto_detect = false end
  local im = reaper.GetExtState(_NS, "input_mode")
  if im == "session" then state.input_mode = "session" end

  -- ── Action dispatch (rsg_actions framework) ───────────────────
  -- Every key MUST correspond to a command in scripts/lua/actions/manifest.toml
  -- (see `[mark]` block). Entries are thin pointers that call through
  -- mark_actions, which mirrors the GUI button callbacks 1:1 (subset-of-GUI
  -- invariant). Each handler also sets a short-lived entry in state._btn_flash
  -- so render_controls swaps the corresponding button to its pressed shade
  -- for ~250ms, visually mimicking the ImGui active-state feedback that mouse
  -- clicks get natively. Mouse clicks invoke mark_actions directly and rely
  -- on the built-in feedback.
  -- NOTE: test_manifest_sync's regex requires each value to start with
  -- `function`, so flash-setting is inlined per entry rather than wrapped in
  -- a helper closure. `close` is a framework built-in dispatched by
  -- rsg_actions.toggle_window.
  local _BTN_FLASH_DUR = 0.25
  local function _set_flash(k) state._btn_flash[k] = reaper.time_precise() + _BTN_FLASH_DUR end
  local HANDLERS = {
    scan_folder        = function() _set_flash("scan_folder");        mark_actions.scan_folder(state)        end,
    add_session_items  = function() _set_flash("add_session_items");  mark_actions.add_session_items(state)  end,
    cycle_input_mode   = function() _set_flash("cycle_input_mode");   mark_actions.cycle_input_mode(state)   end,
    cycle_filter       = function() _set_flash("cycle_filter");       mark_actions.cycle_filter(state)       end,
    toggle_auto_detect = function() _set_flash("toggle_auto_detect"); mark_actions.toggle_auto_detect(state) end,
    embed              = function() _set_flash("embed");              mark_actions.embed(state)              end,
    clear_markers      = function() _set_flash("clear_markers");      mark_actions.clear_markers(state)      end,
    remove_from_list   = function() _set_flash("remove_from_list");   mark_actions.remove_from_list(state)   end,
    copy_name          = function() _set_flash("copy_name");          mark_actions.copy_name(state, ctx)     end,
    close              = function() state.should_close = true end,
  }
  rsg_actions.clear_pending_on_init(_NS)

  local _first_loop = true
  local function loop()
    -- Instance heartbeat
    reaper.SetExtState(_NS, "instance_ts", tostring(reaper.time_precise()), false)
    rsg_actions.heartbeat(_NS)
    local _focus_requested = rsg_actions.poll(_NS, HANDLERS)

    -- State machine tick
    tick_state(state)

    -- Initial size (skip frame 0 -- monitor list not populated). FirstUseEver
    -- sets size on first launch only; user can resize freely after that.
    if not _first_loop then
      reaper.ImGui_SetNextWindowSize(ctx, CONFIG.win_w, CONFIG.win_h,
        reaper.ImGui_Cond_FirstUseEver())
      reaper.ImGui_SetNextWindowSizeConstraints(ctx,
        CONFIG.min_win_w, CONFIG.min_win_h, 9999, 9999)
    end
    _first_loop = false

    -- Honor keyboard-action focus request (dispatched via rsg_actions.poll
    -- when the user fires Toggle_Window while the GUI is already open).
    if _focus_requested then
      reaper.ImGui_SetNextWindowFocus(ctx)
      if reaper.APIExists and reaper.APIExists("JS_Window_SetForeground") then
        local hwnd = reaper.JS_Window_Find and reaper.JS_Window_Find("Temper Mark", true)
        if hwnd then reaper.JS_Window_SetForeground(hwnd) end
      end
    end

    -- Theme push
    local n_theme = rsg_theme and rsg_theme.push(ctx) or 0
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), SC.PANEL)

    -- Window flags (resizable -- no NoResize)
    local win_flags = reaper.ImGui_WindowFlags_NoCollapse()
                    | reaper.ImGui_WindowFlags_NoTitleBar()
                    | reaper.ImGui_WindowFlags_NoScrollbar()
                    | reaper.ImGui_WindowFlags_NoScrollWithMouse()

    local visible, open = reaper.ImGui_Begin(ctx, "Temper Mark##tmark", true, win_flags)

    if visible then
      local lic_status = lic and lic.check("MARK", ctx)
      if lic_status == "expired" then
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_TextColored(ctx, SC and SC.ERROR_RED or 0xC0392BFF,
          "  Your Mark trial has expired.")
        reaper.ImGui_Spacing(ctx)
        lic.open_dialog(ctx)
        lic.draw_dialog(ctx)
      else
        render_gui(ctx, state, lic, lic_status)
        if lic and lic.is_dialog_open() then lic.draw_dialog(ctx) end
      end
      reaper.ImGui_End(ctx)
    end

    -- Theme pop
    if rsg_theme then rsg_theme.pop(ctx, n_theme) end
    reaper.ImGui_PopStyleColor(ctx, 1)  -- SC.PANEL WindowBg

    if open and not state.should_close then
      reaper.defer(loop)
    else
      -- Cleanup: close any in-progress analysis file handle
      if state.active_analysis then
        mark_analysis.analysis_cancel(state.active_analysis)
        state.active_analysis = nil
      end
      reaper.SetExtState(_NS, "input_mode", state.input_mode, true)
      reaper.SetExtState(_NS, "instance_ts", "", false)
    end
  end

  if not _RSG_TEST_MODE then reaper.defer(loop) end
end
