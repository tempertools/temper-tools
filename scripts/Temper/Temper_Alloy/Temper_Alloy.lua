-- @description Temper Alloy -- WAV Variant Merger
-- @version 1.2.2
-- @author Temper Tools
-- @provides
--   [main] Temper_Alloy.lua
--   [nomain] lib/rsg_wav_io.lua
--   [nomain] lib/rsg_alloy_merge.lua
--   [nomain] lib/rsg_theme.lua
--   [nomain] lib/rsg_mediadb.lua
--   [nomain] lib/rsg_license.lua
--   [nomain] lib/rsg_activation_dialog.lua
--   [nomain] lib/rsg_sha256.lua
--   [nomain] lib/rsg_actions.lua
-- @about
--   Temper Alloy scans folders or MediaDB, groups WAV variants by naming
--   pattern, and merges them into consolidated files with cue markers and
--   metadata preservation.
--
--   Requires: ReaImGui, js_ReaScriptAPI (install via ReaPack)

-- ============================================================
-- Dependency checks
-- ============================================================

if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox(
    "Temper Alloy requires ReaImGui.\nInstall via ReaPack: Extensions > ReaImGui",
    "Missing Dependency", 0)
  return
end

if not reaper.JS_Dialog_BrowseForFolder then
  reaper.ShowMessageBox(
    "Temper Alloy requires js_ReaScriptAPI.\nInstall via ReaPack: Extensions > js_ReaScriptAPI",
    "Missing Dependency", 0)
  return
end

-- CF_Preview (SWS) availability -- graceful fallback without it
local _has_cf_preview = reaper.CF_CreatePreview ~= nil

-- ============================================================
-- CONFIG
-- ============================================================

local CONFIG = {
  -- Window dimensions
  win_w = 500,
  win_h = 500,
  min_win_w = 400,
  min_win_h = 350,
  -- Chunked processing
  enum_per_frame = 5000,    -- files discovered per defer frame during folder scan
  blocks_per_frame = 16,    -- PCM blocks per defer frame during merge
  block_size = 65536,       -- 64KB read blocks
  silence_files_per_frame = 10,  -- silence analysis batch size
  -- MediaDB search debounce
  debounce_sec = 0.150,
  -- UI dimensions
  row_h = 22,               -- tree row height
  indent = 20,              -- tree item indent
  dot_r = 3,                -- status dot radius
  btn_sz = 26,              -- button height
  btn_w = 61,               -- button width
  min_tree_w = 120,         -- splitter min tree width
  min_wave_w = 200,         -- splitter min waveform width
  footer_h = 20,            -- footer bar height
  -- Timing
  reanalysis_debounce_sec = 0.4,
  merge_done_display_sec = 3.0,
  playback_end_tolerance_sec = 0.05,
  instance_guard_timeout_sec = 2.0,
  -- Limits
  max_file_size_bytes = 2147483648,  -- 2GB WAV safety limit
}

-- ============================================================
-- Lib loading
-- ============================================================

-- Resolve lib/ as a sibling of this script (works for both dev layout and
-- per-package ReaPack layout — see Temper_Vortex.lua for context).
local _script_path = debug.getinfo(1, "S").source:sub(2)
local _lib         = (_script_path:match("^(.*)[\\/]") or ".") .. "/lib/"
local wav_io         = dofile(_lib .. "rsg_wav_io.lua")
local merge_mod      = dofile(_lib .. "rsg_alloy_merge.lua")
local rsg_actions    = dofile(_lib .. "rsg_actions.lua")
-- mark_analysis is optional (waveform peaks) -- Alloy works without it
local mark_analysis
do
  local ok, mod = pcall(dofile, _lib .. "rsg_mark_analysis.lua")
  if ok and type(mod) == "table" then mark_analysis = mod end
end

-- ============================================================
-- ExtState namespace
-- ============================================================

local _NS = "TEMPER_Alloy"

-- ============================================================
-- Instance guard
-- ============================================================

local function check_instance_guard()
  local ts_str = reaper.GetExtState(_NS, "instance_ts")
  if ts_str and ts_str ~= "" then
    local ts = tonumber(ts_str)
    if ts and (reaper.time_precise() - ts) < CONFIG.instance_guard_timeout_sec then
      reaper.ShowMessageBox(
        "Temper Alloy is already running.",
        "Temper Alloy", 0)
      return false
    end
  end
  return true
end

-- ============================================================
-- Forward declarations
-- ============================================================

local SC  -- Spectral Core palette (set after theme load)
local preview_stop  -- defined after render_tree_content; used by tick_merging

-- ============================================================
-- State reset
-- ============================================================

-- Reset state when switching modes or starting a new scan
local function reset_state(state)
  state.status = "idle"
  state.files = {}
  state.groups = {}
  state.selected_groups = {}
  state.expanded_groups = {}
  state.selected_files = {}
  state.merge_queue = {}
  state.merge_idx = 0
  state.merge_state = nil
  state.merge_results = {}
  state.mediadb_error = false
  state.scan_queue = {}
  state.scan_progress = 0
  state._scan_fi = nil
end

-- ============================================================
-- State machine tick
-- ============================================================

-- Scan one frame of folder enumeration (up to CONFIG.enum_per_frame files)
local function tick_scanning(state)
  if state.input_mode ~= "folder" then return end

  -- Initialize scan_queue from scan_dir if needed
  if #state.scan_queue == 0 and state.scan_dir ~= "" then
    state.scan_queue = {state.scan_dir}
  end

  local R = reaper
  local budget = CONFIG.enum_per_frame
  local processed = 0

  while processed < budget and #state.scan_queue > 0 do
    local dir = state.scan_queue[#state.scan_queue]

    -- Enumerate files in this directory
    local fi = state._scan_fi or 0
    while processed < budget do
      local fname = R.EnumerateFiles(dir, fi)
      if not fname then break end
      fi = fi + 1
      processed = processed + 1

      if fname:lower():match("%.wav$") then
        local path = dir .. "/" .. fname
        local stem = fname:match("^(.+)%.[wW][aA][vV]$") or fname
        state.files[#state.files + 1] = {
          path = path,
          stem = stem,
          folder = dir,
        }
        state.scan_progress = state.scan_progress + 1
      end
    end

    -- If we finished this directory's files, enumerate subdirs and pop
    if not R.EnumerateFiles(dir, fi) then
      table.remove(state.scan_queue, #state.scan_queue)
      state._scan_fi = nil

      -- Push subdirectories onto stack
      local si = 0
      while true do
        local subdir = R.EnumerateSubdirectories(dir, si)
        if not subdir then break end
        si = si + 1
        state.scan_queue[#state.scan_queue + 1] = dir .. "/" .. subdir
      end
    else
      -- Budget exhausted mid-directory; remember file index for next frame
      state._scan_fi = fi
    end
  end

  -- If queue is empty, scanning is complete
  if #state.scan_queue == 0 then
    state._scan_fi = nil
    if #state.files > 0 then
      state.status = "grouping"
    else
      state.status = "idle"
    end
  end
end

-- Group discovered files by variant naming pattern and read durations
local function tick_grouping(state)
  state.groups = merge_mod.group_variants(state.files)

  -- Read durations and file sizes for all files via REAPER PCM_Source
  for _, group in ipairs(state.groups) do
    for _, file in ipairs(group.files) do
      local src = reaper.PCM_Source_CreateFromFile(file.path)
      if src then
        file.duration = reaper.GetMediaSourceLength(src)
        reaper.PCM_Source_Destroy(src)
      else
        file.duration = 0
      end
      -- Check file size for 2GB safety limit
      local fh = io.open(file.path, "rb")
      if fh then
        file.file_size = fh:seek("end") or 0
        fh:close()
        file.oversized = file.file_size >= CONFIG.max_file_size_bytes
      else
        file.file_size = 0
      end
    end
  end

  -- Build flat file list for silence analysis
  state._silence_files = {}
  for _, group in ipairs(state.groups) do
    for _, file in ipairs(group.files) do
      state._silence_files[#state._silence_files + 1] = file
    end
  end
  state._silence_idx = 1
  state.status = "analyzing_silence"
end

-- Apply trim mode as a display filter over cached analysis data (no disk I/O)
local function apply_trim_mode(file, mode)
  local dur = file.original_duration or file.duration or 0
  if mode == "off" or not file._cache_trim_start_sec then
    file.trim_start_sec = 0
    file.trim_end_sec = dur
    file.trimmed_duration = dur
  elseif mode == "leading" then
    file.trim_start_sec = file._cache_trim_start_sec
    file.trim_end_sec = dur
    file.trimmed_duration = dur - file.trim_start_sec
  elseif mode == "trailing" then
    file.trim_start_sec = 0
    file.trim_end_sec = file._cache_trim_end_sec
    file.trimmed_duration = file.trim_end_sec
  else -- "both"
    file.trim_start_sec = file._cache_trim_start_sec
    file.trim_end_sec = file._cache_trim_end_sec
    file.trimmed_duration = file.trim_end_sec - file.trim_start_sec
  end
end

-- Apply current trim mode to all files using cached data (instant, no I/O)
local function apply_trim_mode_all(state)
  for _, group in ipairs(state.groups) do
    for _, file in ipairs(group.files) do
      apply_trim_mode(file, state.silence_trim_mode)
    end
  end
end

-- Process one frame of silence analysis (~10 files per frame for responsive UI)
-- Always analyzes with mode="both" and caches raw boundaries.
local function tick_analyzing_silence(state)
  local files_per_frame = CONFIG.silence_files_per_frame
  local last = math.min(state._silence_idx + files_per_frame - 1, #state._silence_files)

  for i = state._silence_idx, last do
    local file = state._silence_files[i]
    -- Always analyze "both" so we cache leading + trailing boundaries
    local result = wav_io.analyze_silence(file.path, state.silence_threshold_db, "both")
    if result then
      file._cache_trim_start_sec = result.trim_start_sec
      file._cache_trim_end_sec = result.trim_end_sec
      file._cache_threshold_db = state.silence_threshold_db
      file.original_duration = result.original_duration
    else
      file._cache_trim_start_sec = 0
      file._cache_trim_end_sec = file.duration or 0
      file.original_duration = file.duration or 0
    end
    -- Apply current display mode
    apply_trim_mode(file, state.silence_trim_mode)
  end

  state._silence_idx = last + 1
  if state._silence_idx > #state._silence_files then
    state._silence_files = {}
    state.status = "ready"
  end
end

-- Process one frame of merge work (start next group or continue active merge)
local function tick_merging(state)
  -- Stop preview playback when merge starts
  if state.preview and state.preview.is_playing then
    preview_stop(state)
  end

  -- If no active merge state, start the next group
  if not state.merge_state then
    if state.merge_idx > #state.merge_queue then
      -- All groups done
      state.status = "merge_done"
      state.merge_done_ts = reaper.time_precise()
      -- Delete originals if requested and merges succeeded
      if state.delete_originals then
        for qi, entry in ipairs(state.merge_queue) do
          local result = state.merge_results[qi]
          if result and result.ok then
            merge_mod.delete_originals(entry.plan_output.files)
          end
        end
      end
      return
    end

    local entry = state.merge_queue[state.merge_idx]

    -- Validate format first
    local format_ok, format_err = merge_mod.validate_format(entry.plan_output.files)
    if not format_ok then
      state.merge_results[#state.merge_results + 1] = {ok = false, error = format_err}
      state.merge_idx = state.merge_idx + 1
      return
    end

    -- Determine output directory
    local out_dir = state.output_mode == "folder" and state.output_dir or ""

    -- Build trim data lookup from per-file analysis
    local trim_data = {}
    for _, file in ipairs(entry.plan_output.files) do
      if file.trim_start_sec or file.trim_end_sec then
        trim_data[file.path] = {
          trim_start_sec = file.trim_start_sec or 0,
          trim_end_sec = file.trim_end_sec or (file.original_duration or file.duration or 0),
        }
      end
    end

    local ms, err = merge_mod.merge_begin(entry.plan_output, out_dir, state.output_mode, wav_io, trim_data)
    if not ms then
      state.merge_results[#state.merge_results + 1] = {ok = false, error = err}
      state.merge_idx = state.merge_idx + 1
      return
    end
    state.merge_state = ms
    state.merge_progress.current_idx = state.merge_idx
    state.merge_progress.current_name = entry.plan_output.output_name or entry.plan_output.name or ""
    state.merge_progress.bytes_total = state.merge_state.bytes_planned_total or 0
  end

  -- Process blocks
  local result, tick_err = merge_mod.merge_tick(state.merge_state, CONFIG.blocks_per_frame)

  if state.merge_state then
    state.merge_progress.bytes_written = state.merge_state.bytes_written_total or 0
  end

  if result == "pcm_done" then
    local ok, err = merge_mod.merge_finalize(state.merge_state)
    state.merge_results[#state.merge_results + 1] = {
      ok = ok,
      error = err,
      output_path = ok and state.merge_state.final_path or nil,
    }
    if ok then
      local entry_group = state.merge_queue[state.merge_idx] and state.merge_queue[state.merge_idx].group
      if entry_group then entry_group.merged = true end
    end
    state.merge_state = nil
    state.merge_idx = state.merge_idx + 1
  elseif result ~= "in_progress" then
    -- Error during tick
    state.merge_results[#state.merge_results + 1] = {ok = false, error = tick_err or tostring(result)}
    if state.merge_state and state.merge_state.fh then
      state.merge_state.fh:close()
    end
    state.merge_state = nil
    state.merge_idx = state.merge_idx + 1
  end
end

-- Trigger a MediaDB search (debounce has elapsed)
local function start_mediadb_search(state, db)
  if not db then
    state.mediadb_error = true
    return
  end
  if state.search_query == "" then return end

  reset_state(state)
  state.input_mode = "mediadb"  -- preserve mode

  -- MediaDB search requires a loaded index with file_lists.
  -- Full integration is deferred -- for now, show a clear message.
  state.mediadb_error = true
  state.status = "idle"
end

-- Processes one frame of scanning/grouping/merging
local function tick_state(state, db)
  if state.status == "scanning" then
    tick_scanning(state)
  elseif state.status == "grouping" then
    tick_grouping(state)
  elseif state.status == "analyzing_silence" then
    tick_analyzing_silence(state)
  elseif state.status == "merging" then
    tick_merging(state)
  end

  -- Transition merge_done -> ready after display timeout
  if state.status == "merge_done"
     and reaper.time_precise() - state.merge_done_ts >= CONFIG.merge_done_display_sec then
    state.status = "ready"
  end

  -- MediaDB search debounce (when in mediadb mode and idle/ready)
  if state.input_mode == "mediadb" and state.search_debounce_ts > 0 then
    local elapsed = reaper.time_precise() - state.search_debounce_ts
    if elapsed >= CONFIG.debounce_sec then
      state.search_debounce_ts = 0
      start_mediadb_search(state, db)
    end
  end

  -- Silence re-analysis debounce (400ms after last settings change)
  if state._reanalyze_ts and state._reanalyze_ts > 0 and state.status == "ready" then
    local elapsed = reaper.time_precise() - state._reanalyze_ts
    if elapsed >= CONFIG.reanalysis_debounce_sec then
      state._reanalyze_ts = 0
      -- Clear stale trim data so display doesn't show old values
      state._silence_files = {}
      for _, group in ipairs(state.groups) do
        for _, file in ipairs(group.files) do
          file.trim_start_sec = nil
          file.trim_end_sec = nil
          file.trimmed_duration = nil
          file.original_duration = file.duration
          state._silence_files[#state._silence_files + 1] = file
        end
      end
      state._silence_idx = 1
      state.status = "analyzing_silence"
    end
  end
end

-- ============================================================
-- Pill toggle helpers
-- ============================================================

local function push_pill_active(ctx)
  local R = reaper
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        SC.PRIMARY)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), SC.PRIMARY_HV)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  SC.PRIMARY_AC)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          SC.WINDOW)
end

local function push_pill_inactive(ctx)
  local R = reaper
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        SC.PANEL_TOP)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), SC.HOVER_LIST)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  SC.ACTIVE_DARK)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          SC.PRIMARY)
end

-- Recessed/disabled pill (like Mark's EMBED inactive: dark bg, grey text)
local function push_pill_disabled(ctx)
  local R = reaper
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        SC.PANEL)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), SC.HOVER_INACTIVE)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  SC.ACTIVE_DARKER)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          SC.TEXT_OFF)
end

-- ============================================================
-- Row 1: Title bar
-- ============================================================

-- Settings popup (opened by gear button in title bar, matching Mark)
local function render_settings_popup(ctx, state, lic, lic_status)
  local R = reaper
  if not R.ImGui_BeginPopup(ctx, "##settings_popup_alloy") then return end
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_HeaderHovered(), SC.HOVER_LIST)

  -- Output Folder — browse button with tooltip showing current path
  if R.ImGui_Button(ctx, "Output Folder##settings_outdir") then
    local rv, path = R.JS_Dialog_BrowseForFolder(
      "Output directory", state.output_dir, "")
    if rv == 1 and path and path ~= "" then
      state.output_dir = path
    end
    R.ImGui_CloseCurrentPopup(ctx)
  end
  if R.ImGui_IsItemHovered(ctx) then
    local tip = state.output_dir ~= "" and state.output_dir or "(not set)"
    R.ImGui_SetTooltip(ctx, tip)
  end

  R.ImGui_Spacing(ctx)

  if R.ImGui_Button(ctx, "Close##settings_close") then
    state.should_close = true
    R.ImGui_CloseCurrentPopup(ctx)
  end

  if lic_status == "trial" and lic then
    R.ImGui_Spacing(ctx)
    R.ImGui_Separator(ctx)
    R.ImGui_Spacing(ctx)
    if R.ImGui_Selectable(ctx, "Activate\xE2\x80\xA6##alloy_activate") then
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
  local win_x, win_y = R.ImGui_GetWindowPos(ctx)
  local win_w = R.ImGui_GetWindowSize(ctx)
  local h = 28

  -- Background (full width from top edge)
  R.ImGui_DrawList_AddRectFilled(dl, win_x, win_y, win_x + win_w, win_y + h,
    SC.TITLE_BAR)

  -- Title text
  local font_b = rsg_theme and rsg_theme.font_bold
  if font_b then R.ImGui_PushFont(ctx, font_b, 13) end
  R.ImGui_DrawList_AddText(dl, win_x + 10, win_y + 8, SC.PRIMARY, "TEMPER - ALLOY")
  if font_b then R.ImGui_PopFont(ctx) end

  -- Gear button (right-aligned, opens settings popup)
  local btn_w = 22
  R.ImGui_SetCursorScreenPos(ctx, win_x + win_w - btn_w - 8, win_y + 3)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        SC.TITLE_BAR)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), SC.PANEL)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  SC.ACTIVE_DARK)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          SC.PRIMARY)
  if R.ImGui_Button(ctx, "\xe2\x9a\x99##settings_alloy", btn_w, 0) then
    R.ImGui_OpenPopup(ctx, "##settings_popup_alloy")
  end
  R.ImGui_PopStyleColor(ctx, 4)
  if R.ImGui_IsItemHovered(ctx) then R.ImGui_SetTooltip(ctx, "Settings") end
  render_settings_popup(ctx, state, lic, lic_status)

  -- Advance cursor past title bar
  R.ImGui_SetCursorPosY(ctx, h + 8)
end

-- ============================================================
-- Row 2: Controls (mode toggle + input + merge button)
-- ============================================================

-- Trigger folder scan from a path (shared by controls + tree path input)
local function start_folder_scan(state, path)
  state.last_folder = path
  reset_state(state)
  state.input_mode = "folder"
  state.scan_dir = path
  state.scan_queue = {path}
  state.files = {}
  state.scan_progress = 0
  state.status = "scanning"
end

-- ============================================================
-- Reusable UI widgets
-- ============================================================

local function inline_slider(ctx, label, id, value, min, max, fmt, state, popup_key, spacing)
  local R = reaper
  R.ImGui_SameLine(ctx, 0, spacing or 18)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.TEXT_ON)
  R.ImGui_Text(ctx, label)
  R.ImGui_PopStyleColor(ctx, 1)
  R.ImGui_SameLine(ctx)
  R.ImGui_SetNextItemWidth(ctx, 80)
  local changed, new_val = R.ImGui_SliderInt(ctx, id, value, min, max, fmt)
  if R.ImGui_IsItemClicked(ctx, 1) then
    state._input_popup_request = popup_key
    state._input_popup_val = value
  end
  return changed, new_val
end

-- ============================================================
-- State handlers (extracted from render functions for auditability)
-- ============================================================

local function handle_silence_threshold_change(state, new_db)
  state.silence_threshold_db = new_db
  if #state.groups > 0 then
    state._reanalyze_ts = reaper.time_precise()
  end
end

local function handle_output_mode_cycle(state)
  if state.output_mode == "folder" then
    state.output_mode = "inplace"
    state.delete_originals = false
  elseif state.output_mode == "inplace" and not state.delete_originals then
    state.delete_originals = true
  else
    state.output_mode = "folder"
    state.delete_originals = false
  end
end

local function handle_merge_request(state, merge_mod_ref)
  state.merge_queue = {}
  state.merge_results = {}
  for i, grp in ipairs(state.groups) do
    if state.selected_groups[i] then
      local plan = merge_mod_ref.plan_concat(grp, state.max_segment_s, state.max_merged_s)
      for _, output in ipairs(plan.outputs) do
        state.merge_queue[#state.merge_queue + 1] = {
          plan_output = output,
          group = grp,
        }
      end
    end
  end
  state.merge_total = #state.merge_queue
  state.merge_idx = 1
  state.status = "merging"
end

local function handle_select_all(state)
  for i = 1, #state.groups do state.selected_groups[i] = true end
end

local function handle_file_deletion(state)
  -- Remove selected files from groups, then remove empty/singleton groups
  if state.selected_files then
    for key in pairs(state.selected_files) do
      if state.selected_files[key] then
        local gi, fi = key:match("^(%d+)_(%d+)$")
        gi, fi = tonumber(gi), tonumber(fi)
        if gi and fi and state.groups[gi] and state.groups[gi].files[fi] then
          table.remove(state.groups[gi].files, fi)
          state.selected_files[key] = nil
        end
      end
    end
  end
  -- Remove groups with < 2 files
  local i = 1
  while i <= #state.groups do
    if #state.groups[i].files < 2 then
      table.remove(state.groups, i)
      -- Reindex selected_groups and expanded_groups
      local new_sel, new_exp = {}, {}
      for k, v in pairs(state.selected_groups) do
        if k < i then new_sel[k] = v
        elseif k > i then new_sel[k - 1] = v end
      end
      for k, v in pairs(state.expanded_groups) do
        if k < i then new_exp[k] = v
        elseif k > i then new_exp[k - 1] = v end
      end
      state.selected_groups = new_sel
      state.expanded_groups = new_exp
    else
      i = i + 1
    end
  end
  -- Rebuild selected_files keys to match new indices
  local new_sf = {}
  for gi, group in ipairs(state.groups) do
    for fi = 1, #group.files do
      local key = gi .. "_" .. fi
      -- Preserve selection for files still present
      if state.selected_files and state.selected_files[key] then
        new_sf[key] = true
      end
    end
  end
  state.selected_files = new_sf
end

local function validate_merge_preconditions(state)
  local any_selected = false
  for _, v in pairs(state.selected_groups) do
    if v then any_selected = true; break end
  end
  if not any_selected then
    return false, "Select groups to merge"
  end
  if state.output_mode == "folder" and (state.output_dir == "" or not state.output_dir) then
    return false, "Set output directory first (gear menu)"
  end
  -- Check output dir is writable
  if state.output_mode == "folder" and state.output_dir ~= "" then
    local test_path = state.output_dir .. "/.alloy_write_test"
    local fh = io.open(test_path, "w")
    if fh then
      fh:close()
      os.remove(test_path)
    else
      return false, "Output directory is not writable"
    end
  end
  return true
end

-- ============================================================
-- Action handlers (subset-of-GUI mirrors; see manifest.toml [alloy])
-- ============================================================
-- Must live above render_controls (first render_* that references it).
-- Lua binds free references at parse time — declaring this below
-- render_controls would resolve as a global lookup and nil-crash on
-- keyboard dispatch (same trap hit on Vortex Mini Phase C).
local alloy_actions = {}

function alloy_actions.scan_folder(state)
  local rv, path = reaper.JS_Dialog_BrowseForFolder(
    "Select folder to scan", state.last_folder, "")
  if rv == 1 and path and path ~= "" then
    start_folder_scan(state, path)
  end
end

function alloy_actions.cycle_trim_mode(state)
  local TRIM_MODES = {"off", "leading", "trailing", "both"}
  local cur_i = 1
  for ii, m in ipairs(TRIM_MODES) do
    if m == state.silence_trim_mode then cur_i = ii; break end
  end
  state.silence_trim_mode = TRIM_MODES[(cur_i % #TRIM_MODES) + 1]
  if #state.groups > 0 then apply_trim_mode_all(state) end
end

function alloy_actions.cycle_output_mode(state)
  handle_output_mode_cycle(state)
end

function alloy_actions.merge(state, merge_mod_ref)
  local ok, err = validate_merge_preconditions(state)
  if ok and state.status == "ready" then
    handle_merge_request(state, merge_mod_ref)
  else
    state.footer_warning = err or "Merge not available"
    state.footer_warning_ts = reaper.time_precise()
  end
end

function alloy_actions.toggle_select_all_groups(state)
  -- Toggle: if all selected → deselect all, else select all
  local all_sel = #state.groups > 0
  for i = 1, #state.groups do
    if not state.selected_groups[i] then all_sel = false; break end
  end
  if all_sel then
    state.selected_groups = {}
  else
    handle_select_all(state)
  end
end

function alloy_actions.delete_selected_files(state)
  local any = false
  if state.selected_files then
    for _, v in pairs(state.selected_files) do
      if v then any = true; break end
    end
  end
  if any then
    handle_file_deletion(state)
  else
    state.footer_warning = "Select files to delete"
    state.footer_warning_ts = reaper.time_precise()
  end
end

-- Button flash helper — keyboard actions bypass ImGui's click feedback.
-- Push a 250ms shade on both Col_Button AND Col_ButtonHovered so hover
-- cannot mask the flash (Imprint v1.3.4 fix).
local function _is_btn_flashing(state, btn_key)
  local expires_at = state._btn_flash and state._btn_flash[btn_key]
  return expires_at ~= nil and reaper.time_precise() < expires_at
end

local function render_controls(ctx, state)
  local R = reaper
  local btn_sz = CONFIG.btn_sz
  local btn_w = CONFIG.btn_w
  local pill_gap = 0

  -- Use bold font for controls row (matching Mark)
  local font_b = rsg_theme and rsg_theme.font_bold
  if font_b then R.ImGui_PushFont(ctx, font_b, 13) end

  R.ImGui_PushStyleVar(ctx, R.ImGui_StyleVar_FrameRounding(), 4)
  R.ImGui_PushStyleVar(ctx, R.ImGui_StyleVar_FrameBorderSize(), 1.0)

  -- 1. Folder icon button (scan folder, matching Mark)
  local _scan_flash = _is_btn_flashing(state, "scan_folder")
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),
    _scan_flash and SC.ACTIVE_DARK or SC.PANEL_TOP)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(),
    _scan_flash and SC.ACTIVE_DARK or SC.HOVER_LIST)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  SC.ACTIVE_DARK)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(),        SC.PANEL_TOP)
  if R.ImGui_Button(ctx, "##alloy_folder_icon", btn_w, btn_sz) then
    alloy_actions.scan_folder(state)
  end
  R.ImGui_PopStyleColor(ctx, 4)
  -- Draw folder icon via DrawList
  local dl = R.ImGui_GetWindowDrawList(ctx)
  local bx1, by1 = R.ImGui_GetItemRectMin(ctx)
  local bx2, by2 = R.ImGui_GetItemRectMax(ctx)
  local icx = math.floor((bx1 + bx2) * 0.5)
  local icy = math.floor((by1 + by2) * 0.5)
  local icol = SC.PRIMARY
  R.ImGui_DrawList_AddRectFilled(dl, icx - 8, icy - 4, icx + 8, icy + 6, icol, 2.0)
  R.ImGui_DrawList_AddRectFilled(dl, icx - 8, icy - 7, icx - 2, icy - 4, icol, 1.5)
  if R.ImGui_IsItemHovered(ctx) then R.ImGui_SetTooltip(ctx, "Scan Folder") end

  -- 2. Trim mode cycle button (OFF -> LEADING -> TRAILING -> BOTH -> OFF)
  R.ImGui_SameLine(ctx, 0, 8)
  local TRIM_MODES  = {"off", "leading", "trailing", "both"}
  local TRIM_LABELS = {off = "OFF", leading = "PRE", trailing = "POST", both = "BOTH"}
  local TRIM_COL = {
    off      = {SC.PANEL,   SC.HOVER_INACTIVE, SC.ACTIVE_DARKER, SC.TEXT_OFF},
    leading  = {SC.PANEL_TOP, SC.HOVER_LIST, SC.ACTIVE_DARK, SC.PRIMARY},
    trailing = {SC.PANEL_TOP, SC.HOVER_LIST, SC.ACTIVE_DARK, SC.PRIMARY},
    both     = {SC.PANEL_TOP, SC.HOVER_LIST, SC.ACTIVE_DARK, SC.PRIMARY},
  }
  local tc = TRIM_COL[state.silence_trim_mode]
  local _trim_flash = _is_btn_flashing(state, "cycle_trim_mode")
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),
    _trim_flash and SC.ACTIVE_DARK or tc[1])
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(),
    _trim_flash and SC.ACTIVE_DARK or tc[2])
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),   tc[3])
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),           tc[4])
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(),         tc[1])
  local trim_label = TRIM_LABELS[state.silence_trim_mode] or "BOTH"
  if R.ImGui_Button(ctx, trim_label .. "##trim_cycle", btn_w, btn_sz) then
    alloy_actions.cycle_trim_mode(state)
  end
  R.ImGui_PopStyleColor(ctx, 5)
  if R.ImGui_IsItemHovered(ctx) then
    R.ImGui_SetTooltip(ctx, "Silence trim mode: " .. (TRIM_LABELS[state.silence_trim_mode] or "BOTH")
      .. "\nClick to cycle")
  end

  -- 3. MERGE button (beside trim cycle)
  R.ImGui_SameLine(ctx, 0, 8)
  local n_sel = 0
  for _, v in pairs(state.selected_groups) do
    if v then n_sel = n_sel + 1 end
  end
  local need_output_dir = (state.output_mode == "folder" and state.output_dir == "")
  local can_merge = (state.status == "ready" and n_sel > 0 and not need_output_dir)
  local is_merging = (state.status == "merging")

  local _merge_flash = _is_btn_flashing(state, "merge")
  if can_merge or is_merging then
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),
      _merge_flash and SC.ACTIVE_DARK or SC.PRIMARY)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(),
      _merge_flash and SC.ACTIVE_DARK or SC.PRIMARY_HV)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  SC.PRIMARY_AC)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          SC.WINDOW)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(),        SC.PRIMARY)
  else
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),
      _merge_flash and SC.ACTIVE_DARK or SC.PANEL)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(),
      _merge_flash and SC.ACTIVE_DARK or SC.HOVER_INACTIVE)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  SC.ACTIVE_DARKER)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          SC.TEXT_OFF)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(),        SC.PANEL)
  end

  local merge_label = is_merging and "MERGING" or "MERGE"
  if R.ImGui_Button(ctx, merge_label .. "##alloy_merge", btn_w, btn_sz) then
    alloy_actions.merge(state, merge_mod)
  end
  R.ImGui_PopStyleColor(ctx, 5)

  if not can_merge and not is_merging then
    local hf = R.ImGui_HoveredFlags_AllowWhenDisabled
            and R.ImGui_HoveredFlags_AllowWhenDisabled() or 0
    if R.ImGui_IsItemHovered(ctx, hf) then
      if need_output_dir then
        R.ImGui_SetTooltip(ctx, "Set output directory in Settings first")
      else
        R.ImGui_SetTooltip(ctx, "Select groups to merge")
      end
    end
  end

  -- 4. Inline settings: Silence / Max Seg / Max Merged (Silence first, matching Mark)
  local thr_changed, new_thr = inline_slider(ctx, "Silence:", "##sil_thresh_ctrl",
    state.silence_threshold_db, -96, -24, "%d dB", state, "sil", 28)
  if thr_changed then handle_silence_threshold_change(state, new_thr) end

  local seg_changed, new_seg = inline_slider(ctx, "Seg:", "##max_seg_ctrl",
    state.max_segment_s, 1, 300, "%d s", state, "seg")
  if seg_changed then state.max_segment_s = new_seg end

  local mrg_changed, new_mrg = inline_slider(ctx, "Merged:", "##max_mrg_ctrl",
    state.max_merged_s, 1, 600, "%d s", state, "mrg")
  if mrg_changed then state.max_merged_s = new_mrg end

  -- Right-click popup for manual value entry
  -- One-shot: OpenPopup fires exactly once per right-click request
  if state._input_popup_request then
    state._input_popup = state._input_popup_request
    state._input_popup_request = nil
    R.ImGui_OpenPopup(ctx, "##slider_input_popup")
    state._input_popup_opening = true
  end
  -- Style: replace default blue text selection highlight with palette teal
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_FrameBg(),        SC.WINDOW)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_FrameBgHovered(), SC.PANEL_HIGH)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_FrameBgActive(),  SC.PANEL)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_TextSelectedBg(), 0x26A69A66)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),           SC.TEXT_ON)
  if R.ImGui_BeginPopup(ctx, "##slider_input_popup") then
    R.ImGui_SetNextItemWidth(ctx, 80)
    if state._input_popup_opening then
      R.ImGui_SetKeyboardFocusHere(ctx)
      state._input_popup_opening = nil
    end
    local inp_changed, inp_val = R.ImGui_InputInt(ctx, "##popup_input",
      state._input_popup_val, 0, 0)
    if inp_changed then state._input_popup_val = inp_val end
    if R.ImGui_IsKeyPressed(ctx, R.ImGui_Key_Enter())
       or R.ImGui_IsKeyPressed(ctx, R.ImGui_Key_KeypadEnter()) then
      local v = math.floor(state._input_popup_val + 0.5)
      if state._input_popup == "seg" then
        state.max_segment_s = math.max(1, math.min(300, v))
      elseif state._input_popup == "mrg" then
        state.max_merged_s = math.max(1, math.min(600, v))
      elseif state._input_popup == "sil" then
        local old_db = state.silence_threshold_db
        state.silence_threshold_db = math.max(-96, math.min(-24, v))
        if state.silence_threshold_db ~= old_db and #state.groups > 0 then
          state._reanalyze_ts = reaper.time_precise()
        end
      end
      state._input_popup = nil
      R.ImGui_CloseCurrentPopup(ctx)
    end
    if R.ImGui_IsKeyPressed(ctx, R.ImGui_Key_Escape()) then
      state._input_popup = nil
      R.ImGui_CloseCurrentPopup(ctx)
    end
    R.ImGui_EndPopup(ctx)
  else
    state._input_popup = nil
  end
  R.ImGui_PopStyleColor(ctx, 5)

  -- 5. Output mode 3-way cycle button — right-aligned, double width
  --    FOLDER -> SOURCE -> DELETE SOURCES -> FOLDER
  local avail_w = R.ImGui_GetContentRegionAvail(ctx)
  local out_btn_w = btn_w * 2 + 4  -- double width
  R.ImGui_SameLine(ctx, R.ImGui_GetCursorPosX(ctx) + avail_w - out_btn_w)

  -- Derive visual state from output_mode + delete_originals
  local out_state  -- "folder" | "source" | "delete"
  if state.output_mode == "folder" then
    out_state = "folder"
  elseif state.delete_originals then
    out_state = "delete"
  else
    out_state = "source"
  end

  local OUT_LABELS = {folder = "OUTPUT FOLDER", source = "SOURCE FOLDER", delete = "DELETE SOURCES"}
  local OUT_TIPS = {
    folder = "Merged files go to output folder\nClick: Source Folder",
    source = "Merged files go alongside sources\nClick: Delete Sources",
    delete = "WARNING: Sources DELETED after merge\nClick: Output Folder",
  }
  local OUT_COL = {
    folder = {SC.PANEL_TOP, SC.HOVER_LIST,  SC.ACTIVE_DARK, SC.PRIMARY},
    source = {SC.PRIMARY,   SC.PRIMARY_HV,  SC.PRIMARY_AC,  SC.WINDOW},
    delete = {SC.TERTIARY,  SC.TERTIARY_HV or 0xE08A6AFF, SC.TERTIARY_AC or 0xC46A4AFF, SC.WINDOW},
  }
  local oc = OUT_COL[out_state]
  local _out_flash = _is_btn_flashing(state, "cycle_output_mode")
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),
    _out_flash and SC.ACTIVE_DARK or oc[1])
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(),
    _out_flash and SC.ACTIVE_DARK or oc[2])
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  oc[3])
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          oc[4])
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(),        oc[1])
  if R.ImGui_Button(ctx, OUT_LABELS[out_state] .. "##out_cycle", out_btn_w, btn_sz) then
    alloy_actions.cycle_output_mode(state)
  end
  R.ImGui_PopStyleColor(ctx, 5)
  if R.ImGui_IsItemHovered(ctx) then
    R.ImGui_SetTooltip(ctx, OUT_TIPS[out_state])
  end

  R.ImGui_PopStyleVar(ctx, 2)  -- FrameRounding, FrameBorderSize
  if font_b then R.ImGui_PopFont(ctx) end
end

-- ============================================================
-- Row 3: Group tree
-- ============================================================

-- Script-local colors (see design-system.md "Script-Local Colors")
local COL_SEL_BG = 0x1E3A3AFF  -- selected row background (teal tint, visible against WINDOW bg)



local function render_tree_content(ctx, state)
  local R = reaper

  local n_groups = #state.groups

  -- Empty state
  if n_groups == 0 then
    local cw, ch = R.ImGui_GetContentRegionAvail(ctx)
    local msg
    if #state.files > 0 then
      -- Scan found files but no variant groups
      msg = string.format("%d files scanned, no variant groups found\n\n"
        .. "Files need numbered suffixes: Name_01.wav, Name_02.wav, ...",
        #state.files)
    elseif state.mediadb_error then
      msg = "MediaDB index not available. Scan a folder instead."
    else
      msg = "Scan a folder or search MediaDB to find variant groups"
    end
    -- Center first line (bold, matching Mark)
    local font_b = rsg_theme and rsg_theme.font_bold
    if font_b then R.ImGui_PushFont(ctx, font_b, 13) end
    local first_line = msg:match("^([^\n]+)") or msg
    local tw = R.ImGui_CalcTextSize(ctx, first_line)
    R.ImGui_SetCursorPos(ctx, math.max(0, (cw - tw) * 0.5), ch * 0.4)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.TEXT_MUTED)
    R.ImGui_TextWrapped(ctx, msg)
    R.ImGui_PopStyleColor(ctx, 1)
    if font_b then R.ImGui_PopFont(ctx) end
    return
  end

  local dl = R.ImGui_GetWindowDrawList(ctx)
  local row_h = CONFIG.row_h
  local dot_r = CONFIG.dot_r
  local indent = CONFIG.indent
  local tree_focused = R.ImGui_IsWindowFocused(ctx)

  -- Keyboard: Ctrl+A to select all
  if tree_focused and R.ImGui_IsKeyDown(ctx, R.ImGui_Mod_Ctrl())
     and R.ImGui_IsKeyPressed(ctx, R.ImGui_Key_A()) then
    handle_select_all(state)
  end

  -- Keyboard: Delete to remove selected files, then selected groups
  if tree_focused and R.ImGui_IsKeyPressed(ctx, R.ImGui_Key_Delete()) then
    -- First: remove selected files from their groups
    local had_file_removals = false
    if state.selected_files then
      local removals = {}  -- gi -> {fi, fi, ...}
      for key in pairs(state.selected_files) do
        if state.selected_files[key] then
          local g, f = key:match("^(%d+)_(%d+)$")
          g, f = tonumber(g), tonumber(f)
          if g and f then
            if not removals[g] then removals[g] = {} end
            removals[g][#removals[g] + 1] = f
            had_file_removals = true
          end
        end
      end
      for gi, fis in pairs(removals) do
        table.sort(fis, function(a, b) return a > b end)  -- reverse
        if state.groups[gi] then
          for _, fi in ipairs(fis) do
            table.remove(state.groups[gi].files, fi)
          end
          -- Remove group if < 2 files remain
          if #state.groups[gi].files < 2 then
            state.selected_groups[gi] = true  -- mark for group removal below
          end
        end
      end
      state.selected_files = {}
    end

    -- Remove selected groups (reverse to preserve indices)
    -- When files were removed, only auto-remove groups that fell below 2 files
    -- (those were marked in selected_groups by the file removal loop above).
    -- When no files were removed, remove explicitly selected groups.
    if had_file_removals then
      -- Clear user-selected groups; only keep auto-marked ones (< 2 files)
      -- The file removal loop sets selected_groups[gi] = true only for
      -- groups that dropped below 2 files. User selections were cleared
      -- when the file was clicked. So selected_groups is already correct.
    end
    -- Collect indices of groups to remove (reverse order)
    local groups_to_remove = {}
    for i = n_groups, 1, -1 do
      if state.selected_groups[i] then
        groups_to_remove[#groups_to_remove + 1] = i
      end
    end
    -- Remove groups and shift indices
    for _, i in ipairs(groups_to_remove) do
      table.remove(state.groups, i)
    end
    if #groups_to_remove > 0 then
      -- Rebuild selection/expanded with shifted indices
      local new_sel, new_exp = {}, {}
      local old_exp = state.expanded_groups
      -- The groups table is already compacted by table.remove
      -- We need to map old indices to new indices
      local new_idx = 0
      for old_i = 1, n_groups do
        local was_removed = false
        for _, ri in ipairs(groups_to_remove) do
          if ri == old_i then was_removed = true; break end
        end
        if not was_removed then
          new_idx = new_idx + 1
          if old_exp[old_i] then new_exp[new_idx] = true end
        end
      end
      state.selected_groups = new_sel
      state.expanded_groups = new_exp
    end
    n_groups = #state.groups
  end

  for gi = 1, n_groups do
    local group = state.groups[gi]
    local is_selected = state.selected_groups[gi] and true or false
    local is_expanded = state.expanded_groups[gi] and true or false

    local cx, cy = R.ImGui_GetCursorScreenPos(ctx)
    local row_w = R.ImGui_GetContentRegionAvail(ctx)

    -- Selection background
    if is_selected then
      R.ImGui_DrawList_AddRectFilled(dl, cx, cy, cx + row_w, cy + row_h, COL_SEL_BG)
    end

    -- Selectable (invisible, for click handling)
    local clicked = R.ImGui_Selectable(ctx, "##group_" .. gi, is_selected,
      R.ImGui_SelectableFlags_SpanAllColumns()
      | R.ImGui_SelectableFlags_AllowOverlap(), 0, row_h)

    if clicked then
      local ctrl  = R.ImGui_IsKeyDown(ctx, R.ImGui_Mod_Ctrl())
      local shift = R.ImGui_IsKeyDown(ctx, R.ImGui_Mod_Shift())

      -- Clear file selection when clicking a group
      state.selected_files = {}

      -- Toggle expand on every click
      state.expanded_groups[gi] = not is_expanded

      if shift and state.last_click_idx then
        -- Range select
        local lo = math.min(state.last_click_idx, gi)
        local hi = math.max(state.last_click_idx, gi)
        if not ctrl then
          for k = 1, n_groups do state.selected_groups[k] = nil end
        end
        for k = lo, hi do state.selected_groups[k] = true end
      elseif ctrl then
        -- Toggle this group selection
        state.selected_groups[gi] = not is_selected or nil
      else
        -- Select this group
        for k = 1, n_groups do state.selected_groups[k] = nil end
        state.selected_groups[gi] = true
        state.last_click_idx = gi
      end
    end

    -- Context menu (right-click)
    if R.ImGui_BeginPopupContextItem(ctx, "##group_ctx_" .. gi) then
      if R.ImGui_MenuItem(ctx, "Open Location") then
        if reaper.CF_ShellExecute then reaper.CF_ShellExecute(group.folder) end
      end
      if R.ImGui_MenuItem(ctx, "Copy Name") then
        if reaper.CF_SetClipboard then reaper.CF_SetClipboard(group.base) end
      end
      R.ImGui_Separator(ctx)
      if R.ImGui_MenuItem(ctx, "Remove from List") then
        table.remove(state.groups, gi)
        -- Shift selection/expansion indices down to match new positions
        local new_sel, new_exp = {}, {}
        for k, v in pairs(state.selected_groups) do
          if k < gi then new_sel[k] = v
          elseif k > gi then new_sel[k - 1] = v end
        end
        for k, v in pairs(state.expanded_groups) do
          if k < gi then new_exp[k] = v
          elseif k > gi then new_exp[k - 1] = v end
        end
        state.selected_groups = new_sel
        state.expanded_groups = new_exp
      end
      R.ImGui_EndPopup(ctx)
    end

    -- Draw row content on same line as selectable (overlay)
    -- Reposition cursor to row start
    R.ImGui_SetCursorScreenPos(ctx, cx, cy)

    -- Status dot (green after successful merge, teal otherwise)
    R.ImGui_SameLine(ctx, 0, 4)
    local dot_sx, dot_sy = R.ImGui_GetCursorScreenPos(ctx)
    local group_dot_col = group.merged and 0x2ECC71FF or SC.PRIMARY
    R.ImGui_DrawList_AddCircleFilled(dl, dot_sx + dot_r + 1, dot_sy + row_h * 0.5,
      dot_r, group_dot_col)
    R.ImGui_SetCursorScreenPos(ctx, dot_sx + dot_r * 2 + 6, dot_sy)

    -- Group label (bold)
    local n_files = group.files and #group.files or 0
    local sep = group.sep or "_"
    local label = (group.base or "?") .. sep .. "* (" .. n_files .. " files)"

    local font_b = rsg_theme and rsg_theme.font_bold
    if font_b then R.ImGui_PushFont(ctx, font_b, 13) end
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.TEXT_ON)
    R.ImGui_Text(ctx, label)
    R.ImGui_PopStyleColor(ctx, 1)
    if font_b then R.ImGui_PopFont(ctx) end

    -- Expanded file rows
    if is_expanded and group.files then
      for fi = 1, #group.files do
        local file = group.files[fi]
        local fcx, fcy = R.ImGui_GetCursorScreenPos(ctx)

        -- Selectable for click handling (spans full row)
        local file_key = gi .. "_" .. fi
        local file_sel = state.selected_files and state.selected_files[file_key]
        if file_sel then
          R.ImGui_DrawList_AddRectFilled(dl, fcx, fcy, fcx + row_w, fcy + row_h, COL_SEL_BG)
        end
        local file_clicked = R.ImGui_Selectable(ctx, "##file_" .. file_key, file_sel or false,
          R.ImGui_SelectableFlags_SpanAllColumns()
          | R.ImGui_SelectableFlags_AllowOverlap()
          , 0, row_h)

        -- File context menu (right-click) -- must be right after the Selectable
        local file_removed = false
        if R.ImGui_BeginPopupContextItem(ctx, "##file_ctx_" .. file_key) then
          if R.ImGui_MenuItem(ctx, "Remove from Group") then
            table.remove(group.files, fi)
            if state.selected_files then state.selected_files[file_key] = nil end
            if #group.files < 2 then
              table.remove(state.groups, gi)
              local new_sel2, new_exp2 = {}, {}
              for k, v in pairs(state.selected_groups) do
                if k < gi then new_sel2[k] = v
                elseif k > gi then new_sel2[k - 1] = v end
              end
              for k, v in pairs(state.expanded_groups) do
                if k < gi then new_exp2[k] = v
                elseif k > gi then new_exp2[k - 1] = v end
              end
              state.selected_groups = new_sel2
              state.expanded_groups = new_exp2
            end
            file_removed = true
          end
          R.ImGui_EndPopup(ctx)
        end
        if file_removed then break end  -- indices shifted, stop iterating files

        if file_clicked then
          if not state.selected_files then state.selected_files = {} end
          -- Clear group selection when clicking a file
          for k = 1, n_groups do state.selected_groups[k] = nil end
          local ctrl = R.ImGui_IsKeyDown(ctx, R.ImGui_Mod_Ctrl())
          local shift = R.ImGui_IsKeyDown(ctx, R.ImGui_Mod_Shift())
          if shift and state.last_click_idx then
            -- Range select within same group
            local last_gi, last_fi = state.last_click_idx:match("^(%d+)_(%d+)$")
            last_gi, last_fi = tonumber(last_gi), tonumber(last_fi)
            if last_gi == gi and last_fi then
              local lo = math.min(last_fi, fi)
              local hi = math.max(last_fi, fi)
              if not ctrl then state.selected_files = {} end
              for sf = lo, hi do
                state.selected_files[gi .. "_" .. sf] = true
              end
            else
              state.selected_files = {}
              state.selected_files[file_key] = true
            end
          elseif ctrl then
            state.selected_files[file_key] = not file_sel or nil
          else
            state.selected_files = {}
            state.selected_files[file_key] = true
          end
          if not shift then state.last_click_idx = file_key end
        end

        -- Reposition to draw content over the selectable
        R.ImGui_SetCursorScreenPos(ctx, fcx + indent, fcy)

        -- File status dot (red if oversized, coral if over max_segment, teal otherwise)
        local dot_col = SC.PRIMARY
        if file.oversized then
          dot_col = SC.ERROR_RED
        else
          local check_dur = file.trimmed_duration or file.duration
          if check_dur and check_dur > state.max_segment_s then
            dot_col = SC.TERTIARY
          end
        end
        local fdx, fdy = R.ImGui_GetCursorScreenPos(ctx)
        R.ImGui_DrawList_AddCircleFilled(dl, fdx + dot_r + 1, fdy + row_h * 0.5,
          dot_r, dot_col)
        R.ImGui_SetCursorScreenPos(ctx, fdx + dot_r * 2 + 6, fdy)

        -- Filename (stem + extension)
        local fname = file.stem or file.name or "?"
        if file.ext then fname = fname .. file.ext end
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.TEXT_ON)
        R.ImGui_Text(ctx, fname)
        R.ImGui_PopStyleColor(ctx, 1)

        -- Duration (right-aligned, muted) -- show trim arrow if silence was trimmed
        local dur_str
        if file.trimmed_duration and file.original_duration
           and math.abs(file.trimmed_duration - file.original_duration) > 0.05 then
          dur_str = string.format("%.1fs -> %.1fs", file.original_duration, file.trimmed_duration)
        else
          dur_str = file.duration and string.format("%.1fs", file.duration) or "-"
        end
        local dtw = R.ImGui_CalcTextSize(ctx, dur_str)
        R.ImGui_SameLine(ctx, 0, 0)
        local rem = R.ImGui_GetContentRegionAvail(ctx)
        if rem > dtw + 8 then
          R.ImGui_SameLine(ctx, 0, rem - dtw - 4)
          R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.TEXT_MUTED)
          R.ImGui_Text(ctx, dur_str)
          R.ImGui_PopStyleColor(ctx, 1)
        end

        -- Tooltip for oversized files
        if file.oversized and R.ImGui_IsItemHovered(ctx) then
          R.ImGui_SetTooltip(ctx, string.format(
            "File exceeds 2 GB (%.1f GB) \xe2\x80\x94 excluded from merge",
            (file.file_size or 0) / (1024 * 1024 * 1024)))
        end

      end
    end
  end
end

-- ============================================================
-- Preview playback lifecycle (CF_Preview / SWS)
-- ============================================================

preview_stop = function(state)
  if state.preview.handle and _has_cf_preview then
    reaper.CF_Preview_Stop(state.preview.handle)
  end
  if state.preview.source then
    reaper.PCM_Source_Destroy(state.preview.source)
  end
  state.preview.handle = nil
  state.preview.source = nil
  state.preview.is_playing = false
  -- Preserve file_path and position so spacebar can restart
end

local function preview_set_file(state, path)
  preview_stop(state)
  state.preview.file_path = path
  state.preview.position = 0.0
end

local function preview_start_playback(state, position)
  -- Create fresh preview handle + start playback immediately
  -- (CF_Preview handles are destroyed each defer cycle if Play wasn't called)
  preview_stop(state)
  if not _has_cf_preview or not state.preview.file_path then return end
  local src = reaper.PCM_Source_CreateFromFile(state.preview.file_path)
  if not src then return end
  local handle = reaper.CF_CreatePreview(src)
  if not handle then
    reaper.PCM_Source_Destroy(src)
    return
  end
  reaper.CF_Preview_SetValue(handle, "D_VOLUME", 1.0)
  reaper.CF_Preview_SetValue(handle, "D_POSITION", position or 0.0)
  reaper.CF_Preview_Play(handle)
  state.preview.handle = handle
  state.preview.source = src
  state.preview.is_playing = true
  state.preview.position = position or 0.0
end

local function preview_toggle_play(state, sel_file)
  if state.preview.is_playing then
    preview_stop(state)
    -- Reset to start of trimmed region
    local start_time = (sel_file and sel_file.trim_start_sec) or 0
    state.preview.position = start_time
  else
    local start_time = (sel_file and sel_file.trim_start_sec) or 0
    local end_time = (sel_file and (sel_file.trim_end_sec or sel_file.duration)) or 0
    local pos = state.preview.position
    -- If position is at/past end or before start, restart from trimmed start
    if pos >= end_time or pos < start_time then pos = start_time end
    preview_start_playback(state, pos)
  end
end

-- ============================================================
-- Waveform preview panel
-- ============================================================

local function render_waveform_panel(ctx, state, w, h)
  local R = reaper
  -- Find selected file
  local sel_file = nil
  if state.selected_files then
    for key in pairs(state.selected_files) do
      if state.selected_files[key] then
        local gi, fi = key:match("^(%d+)_(%d+)$")
        gi, fi = tonumber(gi), tonumber(fi)
        if gi and fi and state.groups[gi] and state.groups[gi].files[fi] then
          sel_file = state.groups[gi].files[fi]
        end
        break
      end
    end
  end

  if not sel_file then
    -- Stop preview when no file selected
    if state.preview.file_path then preview_stop(state) end
    local font_b = rsg_theme and rsg_theme.font_bold
    if font_b then R.ImGui_PushFont(ctx, font_b, 13) end
    local tw = R.ImGui_CalcTextSize(ctx, "Select a file to preview")
    R.ImGui_SetCursorPos(ctx, math.max(0, (w - tw) * 0.5), h * 0.4)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.TEXT_MUTED)
    R.ImGui_Text(ctx, "Select a file to preview")
    R.ImGui_PopStyleColor(ctx, 1)
    if font_b then R.ImGui_PopFont(ctx) end
    return
  end

  -- Update preview if file changed
  if sel_file.path ~= state.preview.file_path then
    preview_set_file(state, sel_file.path)
  end

  -- Update playback position each frame + auto-stop at end of trimmed region
  if state.preview.handle and state.preview.is_playing then
    local ok, pos = reaper.CF_Preview_GetValue(state.preview.handle, "D_POSITION")
    if ok then
      state.preview.position = pos
      local end_time = sel_file.trim_end_sec or sel_file.original_duration or sel_file.duration or 0
      -- Use file duration as hard stop (trim_end may be < duration)
      local hard_end = sel_file.original_duration or sel_file.duration or 0
      -- Tolerance: 50ms before end to avoid missing the stop on slow frames
      if (end_time > 0 and pos >= end_time - CONFIG.playback_end_tolerance_sec) or (hard_end > 0 and pos >= hard_end - CONFIG.playback_end_tolerance_sec) then
        preview_stop(state)
        state.preview.position = sel_file.trim_start_sec or 0
      end
    end
  end

  -- Initialize per-file zoom/scroll state
  if not sel_file.zoom then sel_file.zoom = 1.0 end
  if not sel_file.scroll_offset then sel_file.scroll_offset = 0.0 end

  -- Layout
  local px, py = R.ImGui_GetCursorScreenPos(ctx)
  local draw_x = px + 8
  local draw_w = math.max(1, w - 16)
  local wave_y = py + 4
  local wave_h = math.max(20, h - 50)
  local wave_mid = wave_y + wave_h * 0.5
  local half_h = wave_h * 0.5

  local dl = R.ImGui_GetWindowDrawList(ctx)
  local orig_dur = sel_file.original_duration or sel_file.duration or 0

  -- Lazy-load overview mipmap (requires mark_analysis)
  if not sel_file.mipmap and mark_analysis then
    sel_file.mipmap = mark_analysis.read_peaks(sel_file.path, 2000)
  end
  local mip = sel_file.mipmap

  -- Fallback: no waveform peaks available (mark_analysis missing)
  if not mip and not mark_analysis then
    local font_b = rsg_theme and rsg_theme.font_bold
    if font_b then R.ImGui_PushFont(ctx, font_b, 13) end
    local msg = "Waveform preview unavailable"
    local tw = R.ImGui_CalcTextSize(ctx, msg)
    R.ImGui_SetCursorPos(ctx, math.max(0, (w - tw) * 0.5), h * 0.4)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.TEXT_MUTED)
    R.ImGui_Text(ctx, msg)
    R.ImGui_PopStyleColor(ctx, 1)
    if font_b then R.ImGui_PopFont(ctx) end
    return
  end

  -- Determine visible range for zoom/scroll
  local vis_start = 0.0
  local vis_end = 1.0
  if sel_file.zoom > 1.01 then
    local visible_frac = 1.0 / sel_file.zoom
    vis_start = sel_file.scroll_offset
    vis_end = vis_start + visible_frac
    if vis_end > 1.0 then
      vis_end = 1.0
      vis_start = 1.0 - visible_frac
      sel_file.scroll_offset = vis_start
    end
  end

  -- Use zoomed peaks when zoomed in, overview otherwise
  local draw_peaks = mip
  if sel_file.zoom > 1.01 and orig_dur > 0 then
    local start_sec = vis_start * orig_dur
    local end_sec = vis_end * orig_dur
    local cache_key = string.format("%.4f|%.4f|%d", start_sec, end_sec, draw_w)
    if sel_file.zoom_peaks_key ~= cache_key and mark_analysis then
      sel_file.zoom_peaks = mark_analysis.read_peaks_range(sel_file.path, start_sec, end_sec, draw_w)
      sel_file.zoom_peaks_key = cache_key
    end
    if sel_file.zoom_peaks then
      draw_peaks = sel_file.zoom_peaks
    end
  end

  -- Draw waveform
  if draw_peaks and draw_peaks.width > 0 then
    local wave_color = SC.PRIMARY
    for i = 0, draw_w - 1 do
      local src_idx = math.floor(i / draw_w * draw_peaks.width) + 1
      if src_idx > draw_peaks.width then src_idx = draw_peaks.width end
      local top = wave_mid - draw_peaks.peak_pos[src_idx] * half_h
      local bot = wave_mid - draw_peaks.peak_neg[src_idx] * half_h
      R.ImGui_DrawList_AddLine(dl, draw_x + i, top, draw_x + i, bot, wave_color, 1.0)
    end
  end

  -- Center line
  R.ImGui_DrawList_AddLine(dl, draw_x, wave_mid, draw_x + draw_w, wave_mid,
    SC.PANEL_HIGH, 1.0)

  -- Silence trim overlay (red semi-transparent rectangles)
  if orig_dur > 0 then
    local trim_col = 0xC0392B40
    local trim_s = sel_file.trim_start_sec or 0
    local trim_e = sel_file.trim_end_sec or orig_dur

    -- Map to visible range
    local function dur_to_px(sec)
      local frac = sec / orig_dur
      if sel_file.zoom > 1.01 then
        local visible_frac = 1.0 / sel_file.zoom
        frac = (frac - vis_start) / visible_frac
      end
      return draw_x + math.floor(frac * draw_w)
    end

    -- Leading silence
    if trim_s > 0 then
      local lead_end = math.max(draw_x, math.min(draw_x + draw_w, dur_to_px(trim_s)))
      local lead_start = math.max(draw_x, dur_to_px(0))
      if lead_end > lead_start then
        R.ImGui_DrawList_AddRectFilled(dl, lead_start, wave_y, lead_end, wave_y + wave_h, trim_col)
      end
    end

    -- Trailing silence
    if trim_e < orig_dur then
      local trail_start = math.max(draw_x, math.min(draw_x + draw_w, dur_to_px(trim_e)))
      local trail_end = math.min(draw_x + draw_w, dur_to_px(orig_dur))
      if trail_end > trail_start then
        R.ImGui_DrawList_AddRectFilled(dl, trail_start, wave_y, trail_end, wave_y + wave_h, trim_col)
      end
    end
  end

  -- Playhead (white vertical line)
  if state.preview.is_playing and orig_dur > 0 then
    local play_frac = state.preview.position / orig_dur
    if sel_file.zoom > 1.01 then
      local visible_frac = 1.0 / sel_file.zoom
      play_frac = (play_frac - vis_start) / visible_frac
    end
    if play_frac >= 0 and play_frac <= 1 then
      local play_x = draw_x + math.floor(play_frac * draw_w)
      R.ImGui_DrawList_AddLine(dl, play_x, wave_y, play_x, wave_y + wave_h, 0xFFFFFFFF, 1.0)
    end
  end

  -- Zoom/pan input: Ctrl+Shift+Wheel = zoom, Shift+Wheel = scroll L/R
  if R.ImGui_IsWindowHovered(ctx) then
    local wheel = R.ImGui_GetMouseWheel(ctx)
    if wheel ~= 0 then
      local ctrl  = R.ImGui_IsKeyDown(ctx, R.ImGui_Mod_Ctrl())
      local shift = R.ImGui_IsKeyDown(ctx, R.ImGui_Mod_Shift())
      if ctrl and shift then
        -- Zoom to cursor
        local mx = R.ImGui_GetMousePos(ctx)
        local cursor_frac = (mx - draw_x) / draw_w
        cursor_frac = math.max(0, math.min(1, cursor_frac))
        local old_zoom = sel_file.zoom
        local new_zoom = old_zoom * (wheel > 0 and 1.3 or (1.0 / 1.3))
        new_zoom = math.max(1.0, math.min(50.0, new_zoom))
        sel_file.zoom = new_zoom
        -- Adjust scroll to keep cursor position stable
        if new_zoom > 1.01 then
          local old_vis = 1.0 / old_zoom
          local new_vis = 1.0 / new_zoom
          local world_frac = vis_start + cursor_frac * old_vis
          sel_file.scroll_offset = math.max(0, math.min(1.0 - new_vis, world_frac - cursor_frac * new_vis))
        else
          sel_file.scroll_offset = 0.0
        end
      elseif shift and sel_file.zoom > 1.01 then
        -- Shift+Wheel: horizontal scroll
        local visible_frac = 1.0 / sel_file.zoom
        local pan_step = visible_frac * 0.2
        sel_file.scroll_offset = sel_file.scroll_offset - wheel * pan_step
        sel_file.scroll_offset = math.max(0, math.min(1.0 - visible_frac, sel_file.scroll_offset))
      end
      -- Plain wheel (no modifier): do nothing — let ImGui handle normal scrolling
    end
  end

  -- Click-to-scrub on waveform
  local mx, my = R.ImGui_GetMousePos(ctx)
  if R.ImGui_IsMouseClicked(ctx, 0) and _has_cf_preview
     and mx >= draw_x and mx <= draw_x + draw_w
     and my >= wave_y and my <= wave_y + wave_h then
    local frac = (mx - draw_x) / draw_w
    frac = math.max(0, math.min(1, frac))
    if sel_file.zoom > 1.01 then
      local visible_frac = 1.0 / sel_file.zoom
      frac = sel_file.scroll_offset + frac * visible_frac
    end
    local time_sec = frac * orig_dur
    -- Start playback from clicked position
    preview_start_playback(state, time_sec)
  end

  -- File info line below waveform
  R.ImGui_SetCursorScreenPos(ctx, px + 8, wave_y + wave_h + 6)
  local fname = sel_file.stem or sel_file.name or "?"
  if sel_file.ext then fname = fname .. sel_file.ext end
  local display_dur = sel_file.trimmed_duration or sel_file.duration or orig_dur
  local dur_str = display_dur > 0 and string.format("  %.1fs", display_dur) or ""
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.TEXT_ON)
  R.ImGui_Text(ctx, fname .. dur_str)
  R.ImGui_PopStyleColor(ctx, 1)

  -- Play status
  if _has_cf_preview then
    R.ImGui_SameLine(ctx, 0, 12)
    local play_icon = state.preview.is_playing and "||" or ">"
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.PRIMARY)
    R.ImGui_Text(ctx, play_icon)
    R.ImGui_PopStyleColor(ctx, 1)

    R.ImGui_SameLine(ctx, 0, 6)
    local pos_str = string.format("%.1f/%.1fs", state.preview.position, display_dur)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.TEXT_MUTED)
    R.ImGui_Text(ctx, pos_str)
    R.ImGui_PopStyleColor(ctx, 1)
  end
end

-- ============================================================
-- Two-column split layout (tree + waveform)
-- ============================================================

local function render_split_layout(ctx, state)
  local R = reaper
  local avail_w, avail_h = R.ImGui_GetContentRegionAvail(ctx)
  avail_h = avail_h - 25  -- footer reserve

  local min_tree_w = CONFIG.min_tree_w
  local min_wave_w = CONFIG.min_wave_w
  local splitter_w = 4

  local tree_w = math.floor(avail_w * state.split_ratio)
  tree_w = math.max(min_tree_w, math.min(avail_w - min_wave_w - splitter_w, tree_w))
  local wave_w = avail_w - tree_w - splitter_w

  -- Left: Tree panel (dark inner bg, matching Mark's aesthetic)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ChildBg(), SC.WINDOW)
  R.ImGui_BeginChild(ctx, "##tree_panel", tree_w, avail_h, R.ImGui_ChildFlags_None())
  render_tree_content(ctx, state)
  R.ImGui_EndChild(ctx)
  R.ImGui_PopStyleColor(ctx, 1)

  -- Splitter (draggable divider)
  R.ImGui_SameLine(ctx, 0, 0)
  local sx, sy = R.ImGui_GetCursorScreenPos(ctx)
  R.ImGui_InvisibleButton(ctx, "##splitter", splitter_w, avail_h)
  local dl = R.ImGui_GetWindowDrawList(ctx)
  local splitter_active = R.ImGui_IsItemActive(ctx)
  local splitter_hovered = R.ImGui_IsItemHovered(ctx)
  local splitter_col = splitter_active and SC.PRIMARY
    or splitter_hovered and SC.TEXT_MUTED
    or SC.PANEL_HIGH
  R.ImGui_DrawList_AddRectFilled(dl, sx, sy, sx + splitter_w, sy + avail_h, splitter_col)
  if splitter_hovered or splitter_active then
    R.ImGui_SetMouseCursor(ctx, R.ImGui_MouseCursor_ResizeEW())
  end

  if R.ImGui_IsItemActive(ctx) then
    local mouse_x = R.ImGui_GetMousePos(ctx)
    local win_x = R.ImGui_GetWindowPos(ctx)
    local new_ratio = (mouse_x - win_x) / avail_w
    new_ratio = math.max(min_tree_w / avail_w, math.min(1.0 - (min_wave_w + splitter_w) / avail_w, new_ratio))
    state.split_ratio = new_ratio
  end

  -- Right: Waveform panel (dark inner bg)
  R.ImGui_SameLine(ctx, 0, 0)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ChildBg(), SC.WINDOW)
  R.ImGui_BeginChild(ctx, "##wave_panel", wave_w, avail_h, R.ImGui_ChildFlags_None())
  render_waveform_panel(ctx, state, wave_w, avail_h)
  R.ImGui_EndChild(ctx)
  R.ImGui_PopStyleColor(ctx, 1)

  -- Spacebar: toggle play/stop (checked at root level so focus on either panel works)
  if _has_cf_preview and state.preview.file_path
     and R.ImGui_IsKeyPressed(ctx, R.ImGui_Key_Space())
     and not R.ImGui_IsAnyItemActive(ctx) then
    -- Find selected file for trim-aware transport
    local sp_file = nil
    if state.selected_files then
      for key in pairs(state.selected_files) do
        if state.selected_files[key] then
          local gi, fi = key:match("^(%d+)_(%d+)$")
          gi, fi = tonumber(gi), tonumber(fi)
          if gi and fi and state.groups[gi] and state.groups[gi].files[fi] then
            sp_file = state.groups[gi].files[fi]
          end
          break
        end
      end
    end
    preview_toggle_play(state, sp_file)
  end
end


-- ============================================================
-- Row 5: Footer
-- ============================================================

local function render_footer(ctx, state)
  local R = reaper
  local font_b = rsg_theme and rsg_theme.font_bold
  if font_b then R.ImGui_PushFont(ctx, font_b, 13) end

  -- Merge progress bar (replaces normal footer during merge)
  if state.status == "merging" or (state.status == "merge_done" and reaper.time_precise() - state.merge_done_ts < CONFIG.merge_done_display_sec) then
    local dl = R.ImGui_GetWindowDrawList(ctx)
    local fx, fy = R.ImGui_GetCursorScreenPos(ctx)
    local fw = R.ImGui_GetContentRegionAvail(ctx)
    local fh = CONFIG.footer_h
    local pct = 0
    if state.merge_total > 0 then
      local group_frac = 0
      if state.merge_progress.bytes_total > 0 then
        group_frac = state.merge_progress.bytes_written / state.merge_progress.bytes_total
      end
      pct = ((state.merge_progress.current_idx - 1) + group_frac) / state.merge_total
    end
    if state.status == "merge_done" then pct = 1 end
    pct = math.max(0, math.min(1, pct))

    -- Background bar
    R.ImGui_DrawList_AddRectFilled(dl, fx, fy, fx + fw, fy + fh, SC.PANEL_HIGH)
    -- Fill
    R.ImGui_DrawList_AddRectFilled(dl, fx, fy, fx + math.floor(fw * pct), fy + fh, SC.PRIMARY)
    -- Text: left = group name, right = percentage
    local left_text = string.format("Merging %s (%d/%d)",
      state.merge_progress.current_name, state.merge_progress.current_idx, state.merge_total)
    local right_text = string.format("%d%%", math.floor(pct * 100))
    R.ImGui_DrawList_AddText(dl, fx + 6, fy + 3, SC.TEXT_ON, left_text)
    local rtw = R.ImGui_CalcTextSize(ctx, right_text)
    R.ImGui_DrawList_AddText(dl, fx + fw - rtw - 6, fy + 3, SC.TEXT_ON, right_text)
    R.ImGui_Dummy(ctx, fw, fh)
    if font_b then R.ImGui_PopFont(ctx) end
    return  -- skip normal footer
  end

  -- Left text: status
  local status_text
  if state.status == "idle" then
    status_text = "Ready"
  elseif state.status == "scanning" then
    status_text = string.format("Scanning... (%d files found)", state.scan_progress)
  elseif state.status == "grouping" then
    status_text = "Grouping variants..."
  elseif state.status == "analyzing_silence" then
    local total = #state._silence_files
    local done = math.min(state._silence_idx - 1, total)
    status_text = string.format("Analyzing silence... (%d/%d)", done, total)
  elseif state.status == "ready" then
    if #state.groups == 0 and #state.files > 0 then
      status_text = string.format("%d files scanned, no variant groups", #state.files)
    else
      status_text = "Ready"
    end
  elseif state.status == "merging" then
    status_text = string.format("Merging %d/%d...", state.merge_idx, state.merge_total)
  elseif state.status == "merge_done" then
    local n_ok = 0
    for _, r in ipairs(state.merge_results) do if r.ok then n_ok = n_ok + 1 end end
    status_text = string.format("Merge complete -- %d files created", n_ok)
  else
    status_text = "Ready"
  end

  -- Right text: summary
  local summary_text = ""
  if #state.groups > 0 then
    local total_files = 0
    for _, g in ipairs(state.groups) do total_files = total_files + #g.files end
    local n_sel = 0
    for _, v in pairs(state.selected_groups) do if v then n_sel = n_sel + 1 end end
    if n_sel > 0 then
      summary_text = string.format("%d groups selected", n_sel)
    else
      summary_text = string.format("%d groups, %d files", #state.groups, total_files)
    end
  end

  -- Transient footer warning (3-second display)
  local status_color = SC.TEXT_MUTED
  if state.footer_warning and state.footer_warning_ts then
    if R.time_precise() - state.footer_warning_ts < CONFIG.merge_done_display_sec then
      status_text = state.footer_warning
      status_color = SC.TERTIARY
    else
      state.footer_warning = nil
      state.footer_warning_ts = nil
    end
  end

  -- Render
  R.ImGui_TextColored(ctx, status_color, status_text)
  if summary_text ~= "" then
    R.ImGui_SameLine(ctx)
    local summary_w = R.ImGui_CalcTextSize(ctx, summary_text)
    local avail_w = R.ImGui_GetContentRegionAvail(ctx)
    if avail_w > summary_w then
      R.ImGui_SetCursorPosX(ctx, R.ImGui_GetCursorPosX(ctx) + avail_w - summary_w)
    end
    R.ImGui_TextColored(ctx, SC.TEXT_MUTED, summary_text)
  end

  if font_b then R.ImGui_PopFont(ctx) end
end

-- ============================================================
-- Main UI
-- ============================================================

local function render_gui(ctx, state, lic, lic_status)
  render_title_bar(ctx, state, lic, lic_status)
  render_controls(ctx, state)
  render_split_layout(ctx, state)
  render_footer(ctx, state)
end

-- ============================================================
-- Entry point
-- ============================================================

do
  if not check_instance_guard() then return end

  -- Guard ReaImGui's short-lived-resource rate limit (see Temper_Vortex.lua).
  local _ctx_ok, ctx = pcall(reaper.ImGui_CreateContext, "Temper Alloy##talloy")
  if not _ctx_ok or not ctx then
    reaper.ShowMessageBox(
      "Temper Alloy could not start because ReaImGui is still cleaning " ..
      "up from a previous instance.\n\n" ..
      "Close any existing Alloy window, wait ~15 seconds, then try again.\n" ..
      "If it keeps happening, restart REAPER.",
      "Temper Alloy", 0)
    return
  end

  -- Load theme and attach fonts
  pcall(dofile, _lib .. "rsg_theme.lua")
  if type(rsg_theme) == "table" then
    rsg_theme.attach_fonts(ctx)
    SC = rsg_theme.SC
  else
    -- Fallback palette if theme fails to load
    SC = {
      WINDOW        = 0x0E0E10FF,
      PANEL         = 0x1E1E20FF,
      PANEL_HIGH    = 0x282828FF,
      PANEL_TOP     = 0x323232FF,
      HOVER_LIST    = 0x39393BFF,
      PRIMARY       = 0x26A69AFF,
      PRIMARY_LT    = 0x66D9CCFF,
      PRIMARY_HV    = 0x30B8ACFF,
      PRIMARY_AC    = 0x1A8A7EFF,
      TERTIARY      = 0xDA7C5AFF,
      TERTIARY_HV   = 0xE08A6AFF,
      TERTIARY_AC   = 0xC46A4AFF,
      TEXT_ON       = 0xDEDEDEFF,
      TEXT_MUTED    = 0xBCC9C6FF,
      TEXT_OFF      = 0x505050FF,
      ERROR_RED     = 0xC0392BFF,
      TITLE_BAR     = 0x1A1A1CFF,
      ACTIVE_DARK   = 0x141416FF,
      BORDER_INPUT  = 0x505055FF,
      BORDER_SUBTLE = 0x50505066,
      ICON_DISABLED = 0x606060FF,
    }
  end

  -- License
  local _lic_ok, lic = pcall(dofile, _lib .. "rsg_license.lua")
  if not _lic_ok then lic = nil end
  if lic then lic.configure({
    namespace    = "TEMPER_Alloy",
    scope_id     = 0x5,
    display_name = "Alloy",
    buy_url      = "https://www.tempertools.com/scripts/alloy",
  }) end

  -- MediaDB (loaded here because it needs to be scoped to the do block)
  local _db_ok, db = pcall(dofile, _lib .. "rsg_mediadb.lua")
  if not _db_ok then db = nil end

  -- State table
  local state = {
    -- State machine
    status          = "idle",        -- idle|scanning|grouping|analyzing_silence|ready|merging|merge_done
    input_mode      = "folder",      -- folder|mediadb

    should_close    = false,

    -- Scan
    files           = {},            -- discovered WAV files {path, stem, folder}
    scan_dir        = "",            -- current scanning directory
    scan_queue      = {},            -- folder enumeration stack
    scan_progress   = 0,             -- files found so far

    -- Groups
    groups          = {},            -- variant groups from merge_mod.group_variants
    selected_groups = {},            -- set of selected group indices (true/false)
    expanded_groups = {},            -- set of expanded group indices (true/false)

    -- MediaDB
    search_query    = "",
    search_debounce_ts = 0,
    mediadb_error   = false,

    -- Merge
    merge_queue     = {},            -- list of {plan_output, group} to merge
    merge_idx       = 0,             -- current position in merge queue
    merge_state     = nil,           -- active merge_state from merge_mod.merge_begin
    merge_results   = {},            -- per-group {ok, error, output_path}
    merge_total     = 0,             -- total groups to merge
    merge_progress  = {              -- per-frame progress for footer bar
      total_groups  = 0,
      current_idx   = 0,
      current_name  = "",
      bytes_written = 0,
      bytes_total   = 0,
    },
    merge_done_ts   = 0,             -- time_precise() when merge completed

    -- Settings (persisted to ExtState)
    max_segment_s   = 30,
    max_merged_s    = 60,
    output_dir      = "",
    output_mode     = "folder",      -- folder|inplace
    delete_originals = false,

    -- Silence analysis
    silence_threshold_db = -48,
    silence_trim_mode    = "both",    -- "off"|"leading"|"trailing"|"both"
    _silence_idx         = 0,         -- file analysis iterator
    _silence_files       = {},        -- flat list of all files for iteration
    _reanalyze_ts        = 0,         -- debounce timestamp for re-analysis

    -- UI state
    last_folder     = "",
    last_query      = "",
    last_click_idx  = nil,           -- for shift-click range select
    split_ratio     = 0.35,          -- tree/waveform panel split (persisted)
    selected_files  = {},            -- file selection for waveform preview

    -- Action button flash (keyboard dispatch feedback, 250ms)
    _btn_flash      = {},

    -- Preview playback (CF_Preview / SWS)
    preview = {
      handle    = nil,
      source    = nil,
      file_path = nil,
      is_playing = false,
      position  = 0.0,
    },
  }

  -- Load persisted settings from ExtState
  local function load_settings()
    local v
    v = reaper.GetExtState(_NS, "input_mode")
    if v == "mediadb" then state.input_mode = "mediadb" end
    v = reaper.GetExtState(_NS, "last_folder")
    if v ~= "" then state.last_folder = v end
    v = reaper.GetExtState(_NS, "last_query")
    if v ~= "" then state.last_query = v end
    v = reaper.GetExtState(_NS, "max_segment_s")
    if v ~= "" then state.max_segment_s = tonumber(v) or 30 end
    v = reaper.GetExtState(_NS, "max_merged_s")
    if v ~= "" then state.max_merged_s = tonumber(v) or 60 end
    v = reaper.GetExtState(_NS, "output_dir")
    if v ~= "" then state.output_dir = v end
    v = reaper.GetExtState(_NS, "output_mode")
    if v == "inplace" then state.output_mode = "inplace" end
    v = reaper.GetExtState(_NS, "delete_originals")
    if v == "1" then state.delete_originals = true end
    v = reaper.GetExtState(_NS, "silence_threshold_db")
    if v ~= "" then state.silence_threshold_db = tonumber(v) or -48 end
    v = reaper.GetExtState(_NS, "silence_trim_mode")
    if v ~= "" then state.silence_trim_mode = v end
    v = reaper.GetExtState(_NS, "split_ratio")
    if v ~= "" then state.split_ratio = tonumber(v) or 0.35 end
  end

  local function save_settings()
    reaper.SetExtState(_NS, "input_mode", state.input_mode, true)
    reaper.SetExtState(_NS, "last_folder", state.last_folder, true)
    reaper.SetExtState(_NS, "last_query", state.last_query, true)
    reaper.SetExtState(_NS, "max_segment_s", tostring(state.max_segment_s), true)
    reaper.SetExtState(_NS, "max_merged_s", tostring(state.max_merged_s), true)
    reaper.SetExtState(_NS, "output_dir", state.output_dir, true)
    reaper.SetExtState(_NS, "output_mode", state.output_mode, true)
    reaper.SetExtState(_NS, "delete_originals", state.delete_originals and "1" or "0", true)
    reaper.SetExtState(_NS, "silence_threshold_db", tostring(state.silence_threshold_db), true)
    reaper.SetExtState(_NS, "silence_trim_mode", state.silence_trim_mode, true)
    reaper.SetExtState(_NS, "split_ratio", string.format("%.3f", state.split_ratio), true)
  end

  load_settings()

  -- Action framework wiring (IPC via ExtState; see lib/rsg_actions.lua)
  local _BTN_FLASH_DUR = 0.25
  local function _set_flash(k) state._btn_flash[k] = reaper.time_precise() + _BTN_FLASH_DUR end

  local HANDLERS = {
    scan_folder           = function() _set_flash("scan_folder");           alloy_actions.scan_folder(state)           end,
    cycle_trim_mode       = function() _set_flash("cycle_trim_mode");       alloy_actions.cycle_trim_mode(state)       end,
    cycle_output_mode     = function() _set_flash("cycle_output_mode");     alloy_actions.cycle_output_mode(state)     end,
    merge                 = function() _set_flash("merge");                 alloy_actions.merge(state, merge_mod)      end,
    toggle_select_all_groups     = function() _set_flash("toggle_select_all_groups");     alloy_actions.toggle_select_all_groups(state)     end,
    delete_selected_files = function() _set_flash("delete_selected_files"); alloy_actions.delete_selected_files(state) end,
    close                 = function() state.should_close = true end,
  }

  rsg_actions.clear_pending_on_init(_NS)

  -- Defer loop
  local _first_loop = true
  local function loop()
    -- Instance heartbeat
    reaper.SetExtState(_NS, "instance_ts", tostring(reaper.time_precise()), false)
    rsg_actions.heartbeat(_NS)
    local _focus_requested = rsg_actions.poll(_NS, HANDLERS)

    -- State machine tick
    tick_state(state, db)

    -- Initial size (skip frame 0). FirstUseEver sets size on first launch
    -- only; user can resize freely after that.
    if not _first_loop then
      reaper.ImGui_SetNextWindowSize(ctx, CONFIG.win_w, CONFIG.win_h,
        reaper.ImGui_Cond_FirstUseEver())
      reaper.ImGui_SetNextWindowSizeConstraints(ctx,
        CONFIG.min_win_w, CONFIG.min_win_h, 9999, 9999)
    end
    _first_loop = false

    -- Theme push
    local n_theme = rsg_theme and rsg_theme.push(ctx) or 0
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), SC.PANEL)

    -- Window flags (resizable, no native title bar)
    local win_flags = reaper.ImGui_WindowFlags_NoCollapse()
                    | reaper.ImGui_WindowFlags_NoTitleBar()
                    | reaper.ImGui_WindowFlags_NoScrollbar()
                    | reaper.ImGui_WindowFlags_NoScrollWithMouse()

    -- Honor focus request from toggle_window (re-invocation of already-open window)
    if _focus_requested then
      reaper.ImGui_SetNextWindowFocus(ctx)
      if reaper.APIExists("JS_Window_SetForeground") then
        local hwnd = reaper.JS_Window_Find("Temper Alloy", true)
        if hwnd then reaper.JS_Window_SetForeground(hwnd) end
      end
    end

    local visible, open = reaper.ImGui_Begin(ctx, "Temper Alloy##talloy", true, win_flags)

    if visible then
      local lic_status = lic and lic.check("ALLOY", ctx)
      if lic_status == "expired" then
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_TextColored(ctx, SC and SC.ERROR_RED or 0xC0392BFF,
          "  Your Alloy trial has expired.")
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

    -- Continue or exit
    if open and not state.should_close then
      reaper.defer(loop)
    else
      preview_stop(state)
      save_settings()
      reaper.SetExtState(_NS, "instance_ts", "", false)
    end
  end

  if not _RSG_TEST_MODE then reaper.defer(loop) end
end
