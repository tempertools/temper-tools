-- @description Temper Slice Mini -- Stereo to Mono WAV Converter
-- @version 1.1.5
-- @author Temper Tools
-- @provides
--   [main] Temper_Slice_Mini.lua
--   [nomain] lib/temper_wav_io.lua
--   [nomain] lib/temper_theme.lua
--   [nomain] lib/temper_license.lua
--   [nomain] lib/temper_activation_dialog.lua
--   [nomain] lib/temper_sha256.lua
--   [nomain] lib/temper_actions.lua
--   [nomain] lib/temper_platform.lua
-- @about
--   Temper Slice Mini converts stereo WAV files to mono via drag-and-drop.
--   Drop files from your OS file browser, choose a channel extraction mode
--   (Take Left, Take Right, or Downmix to Mono), and click SLICE.
--
--   Supports files from multiple directories simultaneously.
--   Non-stereo files are flagged and skipped automatically.
--
--   Requires: ReaImGui, js_ReaScriptAPI (install via ReaPack)

-- ============================================================
-- Dependency checks
-- ============================================================

if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox(
    "Temper Slice Mini requires ReaImGui.\nInstall via ReaPack: Extensions > ReaImGui",
    "Missing Dependency", 0)
  return
end

if not reaper.JS_Dialog_BrowseForFolder then
  reaper.ShowMessageBox(
    "Temper Slice Mini requires js_ReaScriptAPI.\nInstall via ReaPack: Extensions > js_ReaScriptAPI",
    "Missing Dependency", 0)
  return
end

-- ============================================================
-- CONFIG
-- ============================================================

local CONFIG = {
  win_w = 420,
  win_h = 340,
  min_win_w = 410,
  min_win_h = 200,
  row_h = 22,
  dot_r = 3,
  btn_sz = 26,
  btn_w = 61,
  title_h = 28,
  footer_h = 20,
  block_size = 65536,        -- 64KB read blocks
  blocks_per_frame = 8,      -- PCM blocks per defer frame
  done_display_sec = 3.0,    -- how long "Complete" footer shows
  instance_guard_timeout_sec = 2.0,
}

-- ============================================================
-- Lib loading
-- ============================================================

-- Resolve lib/ as a sibling of this script (works for both dev layout and
-- per-package ReaPack layout — see Temper_Vortex.lua for context).
local _script_path = debug.getinfo(1, "S").source:sub(2)
local _lib         = (_script_path:match("^(.*)[\\/]") or ".") .. "/lib/"
local wav_io      = dofile(_lib .. "temper_wav_io.lua")
local platform    = dofile(_lib .. "temper_platform.lua")
local rsg_actions = dofile(_lib .. "temper_actions.lua")

-- ============================================================
-- ExtState namespace
-- ============================================================

local _NS = "TEMPER_SliceMini"

-- ============================================================
-- Instance guard
-- ============================================================

local function check_instance_guard()
  local ts_str = reaper.GetExtState(_NS, "instance_ts")
  if ts_str and ts_str ~= "" then
    local ts = tonumber(ts_str)
    if ts and (reaper.time_precise() - ts) < CONFIG.instance_guard_timeout_sec then
      reaper.ShowMessageBox(
        "Temper Slice Mini is already running.",
        "Temper Slice Mini", 0)
      return false
    end
  end
  return true
end

-- ============================================================
-- Forward declarations
-- ============================================================

local SC  -- Spectral Core palette (set after theme load)
local COL_SEL_BG = 0x1E3A3AFF  -- script-local selection background

-- PCM utilities (imported from rsg_wav_io public API)
local unpack_sample = wav_io.unpack_sample
local pack_sample   = wav_io.pack_sample

-- ============================================================
-- File management
-- ============================================================

local function add_file(state, filepath)
  -- Dedup by path
  for _, f in ipairs(state.files) do
    if f.path == filepath then return end
  end
  -- Clear stale results from previous processing run
  if next(state.process_results) then state.process_results = {} end

  local info = wav_io.read_wav_info(filepath)
  if not info then return end  -- invalid WAV

  local filename = filepath:match("[/\\]([^/\\]+)$") or filepath
  local folder = filepath:match("^(.+)[/\\]") or ""

  state.files[#state.files + 1] = {
    path            = filepath,
    filename        = filename,
    folder          = folder,
    channels        = info.channels or 0,
    is_stereo       = (info.channels == 2),
    sample_rate     = info.sample_rate or 0,
    bits_per_sample = info.bits_per_sample or 0,
    audio_format    = info.audio_format or 0,
    data_offset     = info.data_offset or 0,
    data_size       = info.data_size or 0,
    duration        = info.duration or 0,
  }
  table.sort(state.files, function(a, b) return a.filename:lower() < b.filename:lower() end)
end

-- ============================================================
-- Output path resolution
-- ============================================================

local function resolve_output_path(file, channel_mode, output_mode, output_dir)
  if output_mode == "delete" then
    -- Write to temp file; caller replaces original after conversion succeeds
    return file.folder .. "/" .. file.filename .. ".tmp"
  end
  local stem = file.filename:match("^(.+)%.[wW][aA][vV]$") or file.filename
  local suffix = ({left = "_left", right = "_right", downmix = "_downmix"})[channel_mode]
  local out_name = stem .. suffix .. ".wav"
  if output_mode == "folder" then
    return output_dir .. "/" .. out_name
  else
    return file.folder .. "/" .. out_name
  end
end

-- ============================================================
-- Mono conversion engine
-- ============================================================

local le2_write = wav_io.le2_write
local le4_write = wav_io.le4_write

local function convert_file_begin(file, channel_mode, output_path)
  local src = io.open(file.path, "rb")
  if not src then return nil, "Cannot open source file" end

  local dst = io.open(output_path, "wb")
  if not dst then src:close(); return nil, "Cannot create output file" end

  local bps = file.bits_per_sample
  local bytes_per_sample = bps / 8
  local sr = file.sample_rate
  local mono_byte_rate = sr * bytes_per_sample
  local mono_block_align = bytes_per_sample

  -- Write RIFF header
  wav_io.write_riff_header(dst)

  -- Build mono fmt chunk data (16 bytes for PCM format)
  local fmt_data = le2_write(1)                    -- audio_format = PCM
                .. le2_write(1)                    -- channels = 1
                .. le4_write(sr)                   -- sample_rate
                .. le4_write(mono_byte_rate)        -- byte_rate
                .. le2_write(mono_block_align)      -- block_align
                .. le2_write(bps)                   -- bits_per_sample
  wav_io.write_fmt_chunk(dst, fmt_data)

  -- Write data header (returns offset for patching)
  local data_size_offset = wav_io.write_data_header(dst)

  -- Position source at PCM data start
  src:seek("set", file.data_offset)

  local stereo_frame_size = bytes_per_sample * 2
  local total_frames = math.floor(file.data_size / stereo_frame_size)

  return {
    src = src,
    dst = dst,
    data_size_offset = data_size_offset,
    channel_mode = channel_mode,
    bps = bps,
    bytes_per_sample = bytes_per_sample,
    stereo_frame_size = stereo_frame_size,
    mono_frame_size = bytes_per_sample,
    total_frames = total_frames,
    frames_written = 0,
    bytes_written = 0,
  }
end

local function convert_tick(cs, blocks_per_frame)
  local bps = cs.bps
  local bps_bytes = cs.bytes_per_sample
  local stereo_fs = cs.stereo_frame_size
  local mode = cs.channel_mode
  local frames_remaining = cs.total_frames - cs.frames_written

  if frames_remaining <= 0 then return "done" end

  local budget_frames = math.floor(CONFIG.block_size / stereo_fs) * blocks_per_frame
  local to_read = math.min(budget_frames, frames_remaining)
  local raw = cs.src:read(to_read * stereo_fs)
  if not raw or #raw == 0 then return "done" end

  local actual_frames = math.floor(#raw / stereo_fs)
  local parts = {}

  if mode == "left" then
    -- Pure byte copy: extract first sample from each stereo frame
    for i = 0, actual_frames - 1 do
      local off = i * stereo_fs + 1
      parts[#parts + 1] = raw:sub(off, off + bps_bytes - 1)
    end
  elseif mode == "right" then
    -- Pure byte copy: extract second sample from each stereo frame
    for i = 0, actual_frames - 1 do
      local off = i * stereo_fs + bps_bytes + 1
      parts[#parts + 1] = raw:sub(off, off + bps_bytes - 1)
    end
  else -- downmix
    for i = 0, actual_frames - 1 do
      local base = i * stereo_fs + 1
      local l = unpack_sample(raw, base, bps)
      local r = unpack_sample(raw, base + bps_bytes, bps)
      parts[#parts + 1] = pack_sample((l + r) * 0.5, bps)
    end
  end

  local mono_block = table.concat(parts)
  cs.dst:write(mono_block)
  cs.frames_written = cs.frames_written + actual_frames
  cs.bytes_written = cs.bytes_written + #mono_block

  if cs.frames_written >= cs.total_frames then return "done" end
  return "in_progress"
end

local function convert_finalize(cs)
  -- Patch data size
  wav_io.patch_uint32_le(cs.dst, cs.data_size_offset, cs.bytes_written)
  -- Patch RIFF size
  local total = cs.dst:seek("end")
  wav_io.patch_uint32_le(cs.dst, 4, total - 8)
  cs.dst:close()
  cs.src:close()
  return true
end

-- ============================================================
-- REAPER source management (for DELETE SOURCES file replacement)
-- ============================================================

local function release_reaper_sources(filepath)
  local norm = filepath:gsub("\\", "/"):lower()
  local takes = {}
  local item_count = reaper.CountMediaItems(0)
  for i = 0, item_count - 1 do
    local item = reaper.GetMediaItem(0, i)
    for t = 0, reaper.GetMediaItemNumTakes(item) - 1 do
      local take = reaper.GetMediaItemTake(item, t)
      local source = reaper.GetMediaItemTake_Source(take)
      if source then
        local fn = reaper.GetMediaSourceFileName(source)
        if fn and fn:gsub("\\", "/"):lower() == norm then
          takes[#takes + 1] = {take = take, source = source}
          if reaper.CF_SetMediaSourceOnline then
            reaper.CF_SetMediaSourceOnline(source, false)
          end
        end
      end
    end
  end
  return takes
end

local function restore_reaper_sources(takes)
  for _, t in ipairs(takes) do
    if reaper.CF_SetMediaSourceOnline then
      reaper.CF_SetMediaSourceOnline(t.source, true)
    end
  end
  reaper.UpdateArrange()
end

-- ============================================================
-- Processing state machine
-- ============================================================

local function can_process_file(file)
  return file.is_stereo and file.audio_format == 1
end

local function count_processable(state)
  local n = 0
  for _, f in ipairs(state.files) do
    if can_process_file(f) then n = n + 1 end
  end
  return n
end

local function start_processing(state)
  if state.output_mode == "folder" and (state.output_dir == "" or not state.output_dir) then
    state.footer_warning = "Set output directory first (gear menu)"
    state.footer_warning_ts = reaper.time_precise()
    return
  end

  local n = count_processable(state)
  if n == 0 then return end

  -- Confirmation for destructive DELETE SOURCES mode
  if state.output_mode == "delete" then
    local answer = reaper.ShowMessageBox(
      string.format("This will DELETE %d original source file(s) after conversion.\n\nProceed?", n),
      "Temper Slice Mini", 4)
    if answer ~= 6 then return end  -- 6 = Yes
  end

  state.status = "processing"
  state.process_idx = 1
  state.process_total = n
  state.process_results = {}
  state.process_state = nil
  state.process_done_count = 0
end

-- DELETE SOURCES post-processing: replace originals with converted mono files.
-- Offlines REAPER sources first to release file handles, then rename-swaps.
local function finalize_delete_mode(state)
  for _, file in ipairs(state.files) do
    local pr = state.process_results[file.path]
    if pr and pr.ok then
      local tmp = pr.output_path
      local takes = release_reaper_sources(file.path)
      local bak = file.path .. ".bak"
      local ok1, err1 = os.rename(file.path, bak)
      if ok1 then
        local ok2, err2 = os.rename(tmp, file.path)
        if ok2 then
          os.remove(bak)
          file.is_stereo = false
          file.channels = 1
        else
          os.rename(bak, file.path)
          state.process_results[file.path] = {ok = false, error = "Replace failed: " .. tostring(err2)}
        end
      else
        state.process_results[file.path] = {ok = false, error = "File locked: " .. tostring(err1)}
      end
      restore_reaper_sources(takes)
    end
  end
end

local function tick_processing(state)
  local R = reaper

  -- Cancel requested: close active handles, clean up .tmp, go idle
  if state.cancel_requested then
    if state.process_state then
      pcall(function() state.process_state.src:close() end)
      pcall(function() state.process_state.dst:close() end)
      -- Remove partial output file
      if state.process_current_path then
        os.remove(state.process_current_path)
      end
      state.process_state = nil
    end
    state.cancel_requested = false
    state.status = "idle"
    state.footer_warning = "Conversion cancelled"
    state.footer_warning_ts = R.time_precise()
    return
  end

  -- If no active conversion, find next stereo file
  if not state.process_state then
    while state.process_idx <= #state.files do
      local file = state.files[state.process_idx]
      if can_process_file(file) then
        local out_path = resolve_output_path(file, state.channel_mode, state.output_mode, state.output_dir)
        local cs, err = convert_file_begin(file, state.channel_mode, out_path)
        if cs then
          state.process_state = cs
          state.process_current_file = file
          state.process_current_path = out_path
        else
          state.process_results[file.path] = {ok = false, error = err}
          state.process_done_count = (state.process_done_count or 0) + 1
          state.process_idx = state.process_idx + 1
        end
        return
      end
      state.process_idx = state.process_idx + 1
    end

    -- All files processed -- finalize DELETE mode if active
    if state.output_mode == "delete" then
      finalize_delete_mode(state)
    end

    state.status = "done"
    state.done_ts = R.time_precise()
    state.process_state = nil
    return
  end

  -- Tick active conversion (pcall to prevent file handle leaks on I/O errors)
  local tick_ok, result = pcall(convert_tick, state.process_state, CONFIG.blocks_per_frame)
  if not tick_ok then
    pcall(function() state.process_state.src:close() end)
    pcall(function() state.process_state.dst:close() end)
    state.process_results[state.process_current_file.path] = {ok = false, error = tostring(result)}
    state.process_done_count = (state.process_done_count or 0) + 1
    state.process_state = nil
    state.process_idx = state.process_idx + 1
    return
  end
  if result == "done" then
    convert_finalize(state.process_state)
    state.process_results[state.process_current_file.path] = {ok = true, output_path = state.process_current_path}
    state.process_done_count = (state.process_done_count or 0) + 1
    state.process_state = nil
    state.process_idx = state.process_idx + 1
  end
end

local function tick_state(state)
  if state.status == "processing" then
    tick_processing(state)
  end
  if state.status == "done" and reaper.time_precise() - state.done_ts >= CONFIG.done_display_sec then
    state.status = "idle"
  end
end

-- ============================================================
-- Output mode cycle
-- ============================================================

local function handle_output_mode_cycle(state)
  if state.output_mode == "folder" then
    state.output_mode = "source"
  elseif state.output_mode == "source" then
    state.output_mode = "delete"
  else
    state.output_mode = "folder"
  end
end

-- ============================================================
-- Channel mode cycle
-- ============================================================

local function handle_channel_mode_cycle(state)
  if state.channel_mode == "left" then
    state.channel_mode = "right"
  elseif state.channel_mode == "right" then
    state.channel_mode = "downmix"
  else
    state.channel_mode = "left"
  end
end

-- ============================================================
-- Selection handling
-- ============================================================

local function handle_file_click(ctx, state, idx)
  local R = reaper
  local ctrl  = R.ImGui_IsKeyDown(ctx, R.ImGui_Mod_Ctrl())
  local shift = R.ImGui_IsKeyDown(ctx, R.ImGui_Mod_Shift())

  if shift and state.last_click_idx then
    local lo = math.min(state.last_click_idx, idx)
    local hi = math.max(state.last_click_idx, idx)
    if not ctrl then state.selected_indices = {} end
    for k = lo, hi do state.selected_indices[k] = true end
  elseif ctrl then
    state.selected_indices[idx] = not state.selected_indices[idx] or nil
  else
    state.selected_indices = {}
    state.selected_indices[idx] = true
  end

  if not shift then state.last_click_idx = idx end
end

local function remove_selected(state)
  if state.status == "processing" then return end
  local new_files = {}
  for i, f in ipairs(state.files) do
    if not state.selected_indices[i] then
      new_files[#new_files + 1] = f
    end
  end
  state.files = new_files
  state.selected_indices = {}
  state.last_click_idx = nil
end

-- ============================================================
-- Action handlers (keyboard dispatch via lib/temper_actions.lua)
-- Placed above all render_* functions (subset-of-GUI invariant).
-- ============================================================

local slice_mini_actions = {}

function slice_mini_actions.slice(state)
  if state.status ~= "idle" then return end
  start_processing(state)
end

function slice_mini_actions.cancel(state)
  if state.status ~= "processing" then return end
  state.cancel_requested = true
end

function slice_mini_actions.clear(state)
  if state.status == "processing" then return end
  if #state.files == 0 then return end
  state.files = {}
  state.selected_indices = {}
  state.last_click_idx = nil
  state.process_results = {}
end

function slice_mini_actions.cycle_output_mode(state)
  handle_output_mode_cycle(state)
end

function slice_mini_actions.cycle_channel_mode(state)
  handle_channel_mode_cycle(state)
end

function slice_mini_actions.remove_selected(state)
  remove_selected(state)
end

-- Button flash helper — keyboard actions bypass ImGui's click feedback.
-- Push a 250ms shade on both Col_Button AND Col_ButtonHovered so hover
-- cannot mask the flash (Imprint v1.3.4 fix).
local function _is_btn_flashing(state, btn_key)
  local expires_at = state._btn_flash and state._btn_flash[btn_key]
  return expires_at ~= nil and reaper.time_precise() < expires_at
end

-- ============================================================
-- Row 1: Title bar
-- ============================================================

local function render_settings_popup(ctx, state, lic, lic_status)
  local R = reaper
  if not R.ImGui_BeginPopup(ctx, "##settings_popup_slice") then return end
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_HeaderHovered(), SC.HOVER_LIST)

  if R.ImGui_MenuItem(ctx, "Close##settings_close") then
    state.should_close = true
    R.ImGui_CloseCurrentPopup(ctx)
  end

  R.ImGui_Separator(ctx)

  if R.ImGui_MenuItem(ctx, "Output Folder##settings_outdir") then
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

  if lic_status == "trial" and lic then
    R.ImGui_Separator(ctx)
    if R.ImGui_Selectable(ctx, "Activate\xE2\x80\xA6##slice_activate") then
      lic.open_dialog(ctx)
      R.ImGui_CloseCurrentPopup(ctx)
    end
  end

  R.ImGui_PopStyleColor(ctx, 1)
  R.ImGui_EndPopup(ctx)
end

-- (Window dragging handled by ImGui natively -- no custom drag needed with NoTitleBar)

local function render_title_bar(ctx, state, lic, lic_status)
  local R = reaper
  local dl = R.ImGui_GetWindowDrawList(ctx)
  local win_x, win_y = R.ImGui_GetWindowPos(ctx)
  local win_w = R.ImGui_GetWindowSize(ctx)
  local h = CONFIG.title_h

  -- Background
  R.ImGui_DrawList_AddRectFilled(dl, win_x, win_y, win_x + win_w, win_y + h,
    SC.TITLE_BAR)

  -- Title text
  local font_b = temper_theme and temper_theme.font_bold
  if font_b then R.ImGui_PushFont(ctx, font_b, 13) end
  R.ImGui_DrawList_AddText(dl, win_x + 10, win_y + 8, SC.PRIMARY, "TEMPER - SLICE MINI")
  if font_b then R.ImGui_PopFont(ctx) end

  -- Gear button: DrawList primitives (font-free, OS-agnostic). PushClipRect
  -- lets the button render inside WindowPadding.y on macOS.
  local btn_w = 22
  local bx, by = win_x + win_w - btn_w - 8, win_y + 3
  R.ImGui_PushClipRect(ctx, win_x, win_y, win_x + win_w, win_y + h, false)
  R.ImGui_SetCursorScreenPos(ctx, bx, by)
  local clicked = R.ImGui_InvisibleButton(ctx, "##settings_slice_mini", btn_w, btn_w)
  local hovered = R.ImGui_IsItemHovered(ctx)
  if hovered then
    R.ImGui_DrawList_AddRectFilled(dl, bx, by, bx + btn_w, by + btn_w, SC.PANEL)
  end
  local cx, cy = bx + btn_w * 0.5, by + btn_w * 0.5
  R.ImGui_DrawList_AddCircle(dl, cx, cy, 7, SC.PRIMARY, 16, 1.5)
  R.ImGui_DrawList_AddCircleFilled(dl, cx, cy, 2.5, SC.PRIMARY, 12)
  R.ImGui_PopClipRect(ctx)
  if clicked then R.ImGui_OpenPopup(ctx, "##settings_popup_slice") end
  if hovered then R.ImGui_SetTooltip(ctx, "Settings") end
  render_settings_popup(ctx, state, lic, lic_status)

  -- Advance cursor past title bar
  R.ImGui_SetCursorPosY(ctx, h + 8)
end

-- ============================================================
-- Row 2: Toolbar
-- ============================================================

local function render_controls(ctx, state, n_stereo)
  local R = reaper
  local btn_sz = CONFIG.btn_sz
  local btn_w = CONFIG.btn_w

  local font_b = temper_theme and temper_theme.font_bold
  if font_b then R.ImGui_PushFont(ctx, font_b, 13) end
  R.ImGui_PushStyleVar(ctx, R.ImGui_StyleVar_FramePadding(), 4, 4)

  -- Channel mode tables
  local CH_LABELS = {left = "TAKE LEFT", right = "TAKE RIGHT", downmix = "DOWNMIX"}
  local CH_TIPS = {
    left    = "Extract left channel\nClick: Take Right",
    right   = "Extract right channel\nClick: Downmix to Mono",
    downmix = "Average L+R to mono\nClick: Take Left",
  }
  local CH_COL = {
    left    = {SC.PANEL_TOP, SC.HOVER_LIST,  SC.ACTIVE_DARK, SC.PRIMARY},
    right   = {SC.PRIMARY,   SC.PRIMARY_HV,  SC.PRIMARY_AC,  SC.WINDOW},
    downmix = {SC.TERTIARY,  SC.TERTIARY_HV, SC.TERTIARY_AC, SC.WINDOW},
  }

  -- 1. Channel mode cycle button
  local ch_w = btn_w * 2
  local cc = CH_COL[state.channel_mode]
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        cc[1])
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), cc[2])
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  cc[3])
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          cc[4])
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(),        cc[1])
  local _ch_flash = _is_btn_flashing(state, "cycle_channel_mode")
  if _ch_flash then
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(), cc[3])
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), cc[3])
  end
  if R.ImGui_Button(ctx, CH_LABELS[state.channel_mode] .. "##ch_cycle", ch_w, btn_sz) then
    slice_mini_actions.cycle_channel_mode(state)
  end
  R.ImGui_PopStyleColor(ctx, _ch_flash and 7 or 5)
  if R.ImGui_IsItemHovered(ctx) then R.ImGui_SetTooltip(ctx, CH_TIPS[state.channel_mode]) end

  -- 2. CLEAR button (disabled during processing)
  R.ImGui_SameLine(ctx, 0, 8)
  local empty = #state.files == 0
  if empty or state.status == "processing" then R.ImGui_BeginDisabled(ctx) end
  local _clear_flash = _is_btn_flashing(state, "clear")
  if _clear_flash then
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(), SC.ACTIVE_DARK)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), SC.ACTIVE_DARK)
  end
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        SC.PANEL_TOP)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), SC.HOVER_LIST)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  SC.ACTIVE_DARK)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          SC.PRIMARY)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(),        SC.PANEL_TOP)
  if R.ImGui_Button(ctx, "CLEAR##clear", btn_w, btn_sz) then
    slice_mini_actions.clear(state)
  end
  R.ImGui_PopStyleColor(ctx, _clear_flash and 7 or 5)
  if empty or state.status == "processing" then R.ImGui_EndDisabled(ctx) end
  if R.ImGui_IsItemHovered(ctx) then R.ImGui_SetTooltip(ctx, "Clear all files from list") end

  -- 3. SLICE button
  R.ImGui_SameLine(ctx, 0, 8)
  local need_dir = (state.output_mode == "folder" and (state.output_dir == "" or not state.output_dir))
  local can_slice = (state.status == "idle" and n_stereo > 0 and not need_dir)
  local is_processing = (state.status == "processing")

  local _slice_flash = _is_btn_flashing(state, is_processing and "cancel" or "slice")
  if _slice_flash then
    local flash_c = is_processing and SC.TERTIARY_AC or SC.PRIMARY_AC
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(), flash_c)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), flash_c)
  end
  if is_processing then
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        SC.TERTIARY)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), SC.TERTIARY_HV)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  SC.TERTIARY_AC)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          SC.WINDOW)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(),        SC.TERTIARY)
  elseif can_slice then
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        SC.PRIMARY)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), SC.PRIMARY_HV)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  SC.PRIMARY_AC)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          SC.WINDOW)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(),        SC.PRIMARY)
  else
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        SC.PANEL)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), SC.HOVER_LIST)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  SC.ACTIVE_DARK)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          SC.TEXT_OFF)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(),        SC.PANEL)
  end

  local slice_label = is_processing and "CANCEL" or "SLICE"
  if R.ImGui_Button(ctx, slice_label .. "##slice_run", btn_w, btn_sz) then
    if can_slice then
      slice_mini_actions.slice(state)
    elseif is_processing then
      slice_mini_actions.cancel(state)
    end
  end
  R.ImGui_PopStyleColor(ctx, _slice_flash and 7 or 5)

  if not can_slice and not is_processing then
    if R.ImGui_IsItemHovered(ctx) then
      if need_dir then
        R.ImGui_SetTooltip(ctx, "Set output directory first (gear menu)")
      elseif n_stereo == 0 then
        R.ImGui_SetTooltip(ctx, "No processable stereo files in list")
      end
    end
  elseif can_slice and R.ImGui_IsItemHovered(ctx) then
    R.ImGui_SetTooltip(ctx, "Convert stereo files to mono")
  end

  -- 4. Output mode cycle (right-aligned)
  local OUT_LABELS = {folder = "OUTPUT FOLDER", source = "SOURCE FOLDER", delete = "DELETE SOURCES"}
  local OUT_TIPS = {
    folder = "Mono files go to output folder\nClick: Source Folder",
    source = "Mono files go alongside sources\nClick: Delete Sources",
    delete = "WARNING: Sources DELETED after conversion\nClick: Output Folder",
  }
  local OUT_COL = {
    folder = {SC.PANEL_TOP, SC.HOVER_LIST,  SC.ACTIVE_DARK, SC.PRIMARY},
    source = {SC.PRIMARY,   SC.PRIMARY_HV,  SC.PRIMARY_AC,  SC.WINDOW},
    delete = {SC.TERTIARY,  SC.TERTIARY_HV, SC.TERTIARY_AC, SC.WINDOW},
  }

  local out_btn_w = btn_w * 2 + 4
  R.ImGui_SameLine(ctx, 0, 8)

  local oc = OUT_COL[state.output_mode]
  local _out_flash = _is_btn_flashing(state, "cycle_output_mode")
  if _out_flash then
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(), oc[3])
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), oc[3])
  end
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        oc[1])
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), oc[2])
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  oc[3])
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          oc[4])
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(),        oc[1])
  if R.ImGui_Button(ctx, OUT_LABELS[state.output_mode] .. "##out_cycle", out_btn_w, btn_sz) then
    slice_mini_actions.cycle_output_mode(state)
  end
  R.ImGui_PopStyleColor(ctx, _out_flash and 7 or 5)
  if R.ImGui_IsItemHovered(ctx) then R.ImGui_SetTooltip(ctx, OUT_TIPS[state.output_mode]) end

  R.ImGui_PopStyleVar(ctx, 1)  -- FramePadding
  if font_b then R.ImGui_PopFont(ctx) end
end

-- ============================================================
-- Row 3: File list
-- ============================================================

local function render_file_list(ctx, state)
  local R = reaper
  local row_h = CONFIG.row_h
  local dot_r = CONFIG.dot_r
  local font_b = temper_theme and temper_theme.font_bold

  -- Calculate available height for the file list
  local _, avail_h_raw = R.ImGui_GetContentRegionAvail(ctx)
  local avail_h = avail_h_raw - CONFIG.footer_h - 4
  if avail_h < 40 then avail_h = 40 end

  R.ImGui_BeginChild(ctx, "##file_list", 0, avail_h)

  local dl = R.ImGui_GetWindowDrawList(ctx)
  local child_w = R.ImGui_GetContentRegionAvail(ctx)

  if #state.files == 0 then
    -- Empty state: centered text
    if font_b then R.ImGui_PushFont(ctx, font_b, 13) end
    local msg = "Drop WAV files here"
    local tw = R.ImGui_CalcTextSize(ctx, msg)
    local cx = (child_w - tw) * 0.5
    local cy = avail_h * 0.4
    R.ImGui_SetCursorPos(ctx, cx, cy)
    R.ImGui_TextColored(ctx, SC.TEXT_MUTED, msg)
    if font_b then R.ImGui_PopFont(ctx) end
  else
    if font_b then R.ImGui_PushFont(ctx, font_b, 13) end

    local pending_remove_idx = nil  -- deferred removal (avoids table.remove during iteration)

    for i, file in ipairs(state.files) do
      local is_sel = state.selected_indices[i]
      local cx, cy = R.ImGui_GetCursorScreenPos(ctx)

      -- Selection highlight
      if is_sel then
        R.ImGui_DrawList_AddRectFilled(dl, cx, cy, cx + child_w, cy + row_h, COL_SEL_BG)
      end

      -- Selectable (invisible, for click handling)
      local sel_flags = R.ImGui_SelectableFlags_SpanAllColumns()
                      | R.ImGui_SelectableFlags_AllowOverlap()
      local clicked = R.ImGui_Selectable(ctx, "##file_" .. i, is_sel, sel_flags, 0, row_h)
      local row_hovered = R.ImGui_IsItemHovered(ctx)

      -- Context menu
      if R.ImGui_BeginPopupContextItem(ctx, "##file_ctx_" .. i) then
        if R.ImGui_MenuItem(ctx, "Remove from List") then
          if is_sel then
            remove_selected(state)
          else
            pending_remove_idx = i
          end
        end
        if R.ImGui_MenuItem(ctx, "Open Location") then
          platform.reveal_in_explorer(file.path)
        end
        R.ImGui_EndPopup(ctx)
      end

      -- Handle click
      if clicked then handle_file_click(ctx, state, i) end

      -- Draw overlay content on top of selectable
      -- Status dot
      local dot_col
      local dot_tip
      if file.is_stereo and file.audio_format == 1 then
        -- Check if processed
        local pr = state.process_results[file.path]
        if pr and pr.ok then
          dot_col = 0x2ECC71FF  -- green: done
          dot_tip = "Converted successfully"
        elseif pr and not pr.ok then
          dot_col = SC.ERROR_RED
          dot_tip = "Conversion failed: " .. (pr.error or "unknown")
        else
          dot_col = SC.PRIMARY
        end
      elseif file.channels == 1 then
        dot_col = SC.ERROR_RED
        dot_tip = "Mono file (1 channel) -- will be skipped"
      elseif file.channels > 2 then
        dot_col = SC.ERROR_RED
        dot_tip = string.format("Multichannel (%d channels) -- not supported in Mini", file.channels)
      elseif file.audio_format ~= 1 then
        dot_col = SC.ERROR_RED
        dot_tip = "Format not supported (non-PCM)"
      else
        dot_col = SC.ERROR_RED
        dot_tip = "Not stereo -- will be skipped"
      end

      R.ImGui_DrawList_AddCircleFilled(dl, cx + dot_r + 5, cy + row_h * 0.5, dot_r, dot_col)

      -- Filename text (DrawList to avoid cursor interference with scroll)
      R.ImGui_DrawList_AddText(dl, cx + dot_r * 2 + 12, cy + 3, SC.TEXT_ON, file.filename)

      -- Tooltip on hover (for non-processable or processed files)
      if dot_tip and row_hovered then
        R.ImGui_SetTooltip(ctx, dot_tip)
      end
    end

    if font_b then R.ImGui_PopFont(ctx) end

    -- Deferred single-item removal from context menu
    if pending_remove_idx and state.status ~= "processing" then
      table.remove(state.files, pending_remove_idx)
      state.selected_indices = {}
      state.last_click_idx = nil
    end

    -- Keyboard shortcuts
    if R.ImGui_IsWindowFocused(ctx) then
      -- Delete key: remove selected
      if R.ImGui_IsKeyPressed(ctx, R.ImGui_Key_Delete()) then
        local any_sel = false
        for _ in pairs(state.selected_indices) do any_sel = true; break end
        if any_sel then remove_selected(state) end
      end
      -- Ctrl+A: select all
      if R.ImGui_IsKeyDown(ctx, R.ImGui_Mod_Ctrl()) and R.ImGui_IsKeyPressed(ctx, R.ImGui_Key_A()) then
        for k = 1, #state.files do state.selected_indices[k] = true end
      end
    end
  end

  R.ImGui_EndChild(ctx)
end

-- ============================================================
-- Row 5: Footer
-- ============================================================

local function render_footer(ctx, state, n_stereo)
  local R = reaper
  local font_b = temper_theme and temper_theme.font_bold
  if font_b then R.ImGui_PushFont(ctx, font_b, 13) end

  -- Progress bar during processing
  if state.status == "processing" or (state.status == "done" and R.time_precise() - state.done_ts < CONFIG.done_display_sec) then
    local dl = R.ImGui_GetWindowDrawList(ctx)
    local fx, fy = R.ImGui_GetCursorScreenPos(ctx)
    local fw = R.ImGui_GetContentRegionAvail(ctx)
    local fh = CONFIG.footer_h

    local pct = 0
    if state.process_total > 0 then
      local file_frac = 0
      if state.process_state and state.process_state.total_frames > 0 then
        file_frac = state.process_state.frames_written / state.process_state.total_frames
      end
      pct = ((state.process_done_count or 0) + file_frac) / state.process_total
    end
    if state.status == "done" then pct = 1 end
    pct = math.max(0, math.min(1, pct))

    -- Background + fill
    R.ImGui_DrawList_AddRectFilled(dl, fx, fy, fx + fw, fy + fh, SC.PANEL_HIGH)
    R.ImGui_DrawList_AddRectFilled(dl, fx, fy, fx + math.floor(fw * pct), fy + fh, SC.PRIMARY)

    -- Text
    local left_text
    if state.status == "done" then
      local n_ok = 0
      for _, r in pairs(state.process_results) do if r.ok then n_ok = n_ok + 1 end end
      left_text = string.format("Complete -- %d files converted", n_ok)
    else
      local fname = state.process_current_file and state.process_current_file.filename or ""
      left_text = string.format("Converting %s (%d/%d)", fname, (state.process_done_count or 0) + 1, state.process_total)
    end
    local right_text = string.format("%d%%", math.floor(pct * 100))

    R.ImGui_DrawList_AddText(dl, fx + 6, fy + 3, SC.TEXT_ON, left_text)
    local rtw = R.ImGui_CalcTextSize(ctx, right_text)
    R.ImGui_DrawList_AddText(dl, fx + fw - rtw - 6, fy + 3, SC.TEXT_ON, right_text)
    R.ImGui_SetCursorPosY(ctx, R.ImGui_GetCursorPosY(ctx) + fh)
    R.ImGui_Dummy(ctx, 0, 0)
    if font_b then R.ImGui_PopFont(ctx) end
    return
  end

  -- Normal footer: left status + right summary
  local status_text = "Ready"
  local status_color = SC.TEXT_MUTED

  -- Transient warning override
  if state.footer_warning and state.footer_warning_ts then
    if R.time_precise() - state.footer_warning_ts < CONFIG.done_display_sec then
      status_text = state.footer_warning
      status_color = SC.TERTIARY
    else
      state.footer_warning = nil
      state.footer_warning_ts = nil
    end
  end

  R.ImGui_TextColored(ctx, status_color, status_text)

  -- Right summary: file counts
  if #state.files > 0 then
    local summary = string.format("%d files, %d stereo", #state.files, n_stereo)
    R.ImGui_SameLine(ctx)
    local summary_w = R.ImGui_CalcTextSize(ctx, summary)
    local avail_w = R.ImGui_GetContentRegionAvail(ctx)
    if avail_w > summary_w then
      R.ImGui_SetCursorPosX(ctx, R.ImGui_GetCursorPosX(ctx) + avail_w - summary_w)
    end
    R.ImGui_TextColored(ctx, SC.TEXT_MUTED, summary)
  end

  if font_b then R.ImGui_PopFont(ctx) end
end

-- ============================================================
-- Main GUI
-- ============================================================

local function render_gui(ctx, state, lic, lic_status)
  local n_stereo = count_processable(state)
  render_title_bar(ctx, state, lic, lic_status)
  render_controls(ctx, state, n_stereo)
  render_file_list(ctx, state)
  render_footer(ctx, state, n_stereo)

  -- Drop zone below title bar (avoids stealing input from title bar drag handle)
  local R = reaper
  local win_x, win_y = R.ImGui_GetWindowPos(ctx)
  local win_w, win_h = R.ImGui_GetWindowSize(ctx)
  local title_h = CONFIG.title_h
  R.ImGui_SetCursorScreenPos(ctx, win_x, win_y + title_h)
  R.ImGui_SetNextItemAllowOverlap(ctx)
  R.ImGui_InvisibleButton(ctx, "##drop_zone", win_w, win_h - title_h)

  if R.ImGui_BeginDragDropTarget(ctx) then
    local no_rect = R.ImGui_DragDropFlags_AcceptNoDrawDefaultRect()
    local rv, count = R.ImGui_AcceptDragDropPayloadFiles(ctx, 0, no_rect)
    if rv then
      for fi = 0, count - 1 do
        local ok, filepath = R.ImGui_GetDragDropPayloadFile(ctx, fi)
        if ok and filepath:lower():match("%.wav$") then
          add_file(state, filepath)
        end
      end
    end
    R.ImGui_EndDragDropTarget(ctx)

    -- Custom teal border covering full window
    local dl = R.ImGui_GetForegroundDrawList(ctx)
    R.ImGui_DrawList_AddRect(dl, win_x + 1, win_y + 1,
      win_x + win_w - 1, win_y + win_h - 1, SC.PRIMARY, 0, 0, 2.0)
  end
end

-- ============================================================
-- Entry point
-- ============================================================

do
  if not check_instance_guard() then return end

  -- Guard ReaImGui's short-lived-resource rate limit (see Temper_Vortex.lua).
  local _ctx_ok, ctx = pcall(reaper.ImGui_CreateContext, "Temper Slice Mini##tslice")
  if not _ctx_ok or not ctx then
    reaper.ShowMessageBox(
      "Temper Slice Mini could not start because ReaImGui is still " ..
      "cleaning up from a previous instance.\n\n" ..
      "Close any existing Slice Mini window, wait ~15 seconds, then try again.\n" ..
      "If it keeps happening, restart REAPER.",
      "Temper Slice Mini", 0)
    return
  end

  -- Load theme and attach fonts
  pcall(dofile, _lib .. "temper_theme.lua")
  if type(temper_theme) == "table" then
    temper_theme.attach_fonts(ctx)
    SC = temper_theme.SC
  else
    -- Fallback palette if theme fails to load
    SC = {
      WINDOW        = 0x0E0E10FF,
      PANEL         = 0x1E1E20FF,
      PANEL_HIGH    = 0x282828FF,
      PANEL_TOP     = 0x323232FF,
      HOVER_LIST    = 0x39393BFF,
      PRIMARY       = 0x26A69AFF,
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
      HOVER_INACTIVE = 0x2A2A2CFF,
      ACTIVE_DARKER = 0x161618FF,
      ICON_DISABLED = 0x606060FF,
    }
  end

  -- License
  local _lic_ok, lic = pcall(dofile, _lib .. "temper_license.lua")
  if not _lic_ok then lic = nil end
  if lic then lic.configure({
    namespace    = "TEMPER_SliceMini",
    scope_id     = 0x6,
    display_name = "Slice Mini",
    buy_url      = "https://www.tempertools.com/scripts/slice-mini",
  }) end

  -- State table
  local state = {
    files            = {},
    selected_indices = {},
    last_click_idx   = nil,
    channel_mode     = "left",
    output_mode      = "folder",
    output_dir       = "",
    status           = "idle",
    process_idx      = 0,
    process_total    = 0,
    process_results  = {},
    process_state    = nil,
    process_done_count = 0,
    process_current_file = nil,
    process_current_path = nil,
    done_ts          = 0,
    cancel_requested = false,
    should_close     = false,
    footer_warning   = nil,
    footer_warning_ts = nil,
    -- Action button flash (keyboard dispatch feedback, 250ms)
    _btn_flash       = {},
  }

  -- Load persisted settings
  local function load_settings()
    local v
    v = reaper.GetExtState(_NS, "channel_mode")
    if v == "right" or v == "downmix" then state.channel_mode = v end
    v = reaper.GetExtState(_NS, "output_mode")
    if v == "source" or v == "delete" then state.output_mode = v end
    v = reaper.GetExtState(_NS, "output_dir")
    if v ~= "" then state.output_dir = v end
  end

  local function save_settings()
    reaper.SetExtState(_NS, "channel_mode", state.channel_mode, true)
    reaper.SetExtState(_NS, "output_mode", state.output_mode, true)
    reaper.SetExtState(_NS, "output_dir", state.output_dir, true)
  end

  load_settings()

  -- Window flags
  local win_flags = reaper.ImGui_WindowFlags_NoCollapse()
                  | reaper.ImGui_WindowFlags_NoTitleBar()
                  | reaper.ImGui_WindowFlags_NoScrollbar()
                  | reaper.ImGui_WindowFlags_NoScrollWithMouse()

  -- Action framework wiring (IPC via ExtState; see lib/temper_actions.lua)
  local _BTN_FLASH_DUR = 0.25
  local function _set_flash(k) state._btn_flash[k] = reaper.time_precise() + _BTN_FLASH_DUR end

  local HANDLERS = {
    slice              = function() _set_flash("slice");              slice_mini_actions.slice(state)              end,
    cancel             = function() _set_flash("cancel");             slice_mini_actions.cancel(state)             end,
    clear              = function() _set_flash("clear");              slice_mini_actions.clear(state)              end,
    cycle_output_mode  = function() _set_flash("cycle_output_mode");  slice_mini_actions.cycle_output_mode(state)  end,
    cycle_channel_mode = function() _set_flash("cycle_channel_mode"); slice_mini_actions.cycle_channel_mode(state) end,
    remove_selected    = function() _set_flash("remove_selected");    slice_mini_actions.remove_selected(state)    end,
    close              = function() state.should_close = true end,
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
    tick_state(state)

    -- Window size (skip frame 0). FirstUseEver sets size on first launch
    -- only; user can resize freely after that.
    if not _first_loop then
      reaper.ImGui_SetNextWindowSize(ctx, CONFIG.win_w, CONFIG.win_h,
        reaper.ImGui_Cond_FirstUseEver())
      reaper.ImGui_SetNextWindowSizeConstraints(ctx,
        CONFIG.min_win_w, CONFIG.min_win_h, 9999, 9999)
    end
    _first_loop = false

    if _focus_requested then
      reaper.ImGui_SetNextWindowFocus(ctx)
      if reaper.APIExists("JS_Window_SetForeground") then
        local hwnd = reaper.JS_Window_Find("Temper Slice Mini", true)
        if hwnd then reaper.JS_Window_SetForeground(hwnd) end
      end
    end

    -- Theme push
    local n_theme = temper_theme and temper_theme.push(ctx) or 0
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), SC.PANEL)

    local visible, open = reaper.ImGui_Begin(ctx, "Temper Slice Mini##tslice", true, win_flags)

    if visible then
      local lic_status = lic and lic.check("SLICE_MINI", ctx)
      if lic_status == "expired" then
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_TextColored(ctx, SC and SC.ERROR_RED or 0xC0392BFF,
          "  Your Slice Mini trial has expired.")
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
    if temper_theme then temper_theme.pop(ctx, n_theme) end
    reaper.ImGui_PopStyleColor(ctx, 1)

    -- Continue or exit
    if open and not state.should_close then
      reaper.defer(loop)
    else
      save_settings()
      reaper.SetExtState(_NS, "instance_ts", "", false)
    end
  end

  if not _RSG_TEST_MODE then reaper.defer(loop) end
end
