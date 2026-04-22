-- @description Temper Recall -- Rolling Audio Capture
-- @version 0.5.5
-- @author Temper Tools
-- @provides
--   [main] Temper_Recall.lua
--   [effect] Temper_Recall.jsfx
--   [nomain] lib/temper_theme.lua
--   [nomain] lib/temper_license.lua
--   [nomain] lib/temper_activation_dialog.lua
--   [nomain] lib/temper_sha256.lua
--   [nomain] lib/temper_actions.lua
--   [nomain] lib/temper_mark_analysis.lua
--   [nomain] lib/temper_routing_math.lua
-- @about
--   Rolling audio capture for REAPER. Continuously buffers recent audio
--   output so you can recover moments you didn't explicitly record.
--   Select regions on the waveform and drag them into your session.
--
--   Requires: ReaImGui, SWS Extension, js_ReaScriptAPI

if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox(
    "Temper Recall requires ReaImGui.\nInstall via ReaPack: Extensions > ReaImGui",
    "Missing Dependency", 0)
  return
end

if not reaper.APIExists("CF_GetSWSVersion") then
  reaper.ShowMessageBox(
    "Temper Recall requires SWS Extension.\nDownload from sws-extension.org",
    "Missing Dependency", 0)
  return
end

if not reaper.APIExists("JS_ReaScriptAPI_Version") then
  reaper.ShowMessageBox(
    "Temper Recall requires js_ReaScriptAPI.\nInstall via ReaPack: Extensions > js_ReaScriptAPI",
    "Missing Dependency", 0)
  return
end

local CONFIG = {
  title_h       = 26,
  btn_w         = 26,
  btn_gap       = 4,
  status_gap    = 12,
  waveform_col  = 0x26A69A99,   -- PRIMARY at 60% alpha
  sel_col       = 0x26A69A44,   -- PRIMARY at 27% alpha
  sel_border    = 0x26A69AFF,   -- PRIMARY solid
  instance_guard_timeout_sec = 2.0,
  jsfx_name     = "JS:Temper/Temper_Recall",
  gmem_ns       = "Temper_Recall",
  buf_dur_default = 60,
  buf_dur_min     = 10,
  buf_dur_max     = 120,
  quick_dur_default = 5,
  quick_dur_min     = 1,
  quick_dur_max     = 30,
  force_mono_default  = false, -- mono fold on export; capture nch driven by JSFX num_ch
  jsfx_proto_expected = 23,    -- bump with JSFX gmem[10] whenever protocol changes
  -- Spectrogram tuning converged via live user slider exploration on
  -- typical IR/3OA content (2026-04-21). -45 dB gain + 435 permille
  -- floor hits the sweet spot where tonal detail reads cleanly without
  -- the background graininess that dominated at defaults. Range kept
  -- wide in both directions for atypical material.
  spec_gain_db_default = -45,
  spec_gain_db_min     = -60,
  spec_gain_db_max     = 20,
  spec_thresh_permille_default = 435,
  spec_thresh_permille_min     = 0,
  spec_thresh_permille_max     = 500,
  view_mode_default = "waveform", -- "waveform" | "spectral"
  cue_col        = 0xDA7C5A80,  -- TERTIARY at 50% alpha (thin vertical tick)
  cue_enabled_default     = true,
  cue_silence_db_default  = -40, cue_silence_db_min = -60, cue_silence_db_max = -20,
  cue_sensitivity_default = 50,  cue_sensitivity_min  = 0,  cue_sensitivity_max  = 100,
  cue_spacing_ms_default  = 1000, cue_spacing_ms_min  = 200, cue_spacing_ms_max  = 5000,
  cue_max        = 100,
}

-- Peak-ring resolution in JSFX gmem. Must match DISP_RES in Temper_Recall.jsfx.
-- Lua resamples these to the current window pixel width at render time with
-- max-pool, so resizing the window never reshuffles stored peaks.
local DISP_RES = 2048
-- Spectral bins per disp_px slot. Must match BINS in Temper_Recall.jsfx.
local BINS = 96

local _script_path = debug.getinfo(1, "S").source:sub(2)
local _lib         = (_script_path:match("^(.*)[\\/]") or ".") .. "/lib/"
local rsg_actions  = dofile(_lib .. "temper_actions.lua")
local mark_analysis = dofile(_lib .. "temper_mark_analysis.lua")
local routing_math = dofile(_lib .. "temper_routing_math.lua")

local _NS = "TEMPER_Recall"

local R = reaper

local function check_instance_guard()
  local ts_str = R.GetExtState(_NS, "instance_ts")
  if ts_str and ts_str ~= "" then
    local ts = tonumber(ts_str)
    if ts and (R.time_precise() - ts) < CONFIG.instance_guard_timeout_sec then
      R.ShowMessageBox("Temper Recall is already running.", "Temper Recall", 0)
      return false
    end
  end
  return true
end

-- gmem slot constants (match JSFX protocol)
local GM = {
  EXPORT_TRIGGER  = 0,
  EXPORT_TYPE     = 1,
  EXPORT_TRACK    = 2,
  EXPORT_DURATION = 3,
  BUF_DUR         = 4,
  FORCE_MONO      = 5,   -- 0 = pass through at capture nch, 1 = sum to mono on export
  CAP_NCH         = 11,  -- JSFX broadcasts live nch each @block (Settings readout)
  SET_NCH         = 12,  -- Lua writes master.I_NCHAN each frame; JSFX consumes in @block
  EFFECTIVE_NCH   = 13,  -- JSFX broadcasts highest active channel (+1) in buf_dur window
  JSFX_PROTO      = 10,  -- version handshake; JSFX writes on @block reinit
  SEL_START       = 6,
  SEL_WIDTH       = 7,
  DISP_SIZE       = 8,
  PAUSE           = 9,
  INITIALIZED     = 16,
  WRITE_HEAD      = 17,
  DISP_BUF_OFFSET = 18,
  SRATE           = 19,
  -- Export handshake (protocol v13, 2026-04-19): JSFX samples the ring into
  -- gmem staging, Lua reads & writes WAV + InsertMedia. Replaces the old
  -- export_buffer_to_project() call which was capped at 8 channels.
  EXPORT_READY        = 14,  -- JSFX -> Lua: 1 when staging buffer populated
  EXPORT_NUM_FRAMES   = 15,  -- JSFX -> Lua: frames written to staging
  EXPORT_ACTUAL_NCH   = 20,  -- JSFX -> Lua: channel count of staged block (post mono fold)
  -- Spectrogram user-gain (guard-band slot, outside every ring index).
  -- = disp_buf_base + DISP_RES + DISP_RES*BINS = 21 + 2048 + 2048*96.
  SPEC_GAIN_DB        = 198677,
}

-- Mirror of JSFX @block: export_buf_base = gmem_ctrl + 1 + DISP_RES + DISP_RES*BINS + 1024
--                                        = 21 + 2048 + 2048*96 + 1024 = 199701
-- Previously broadcast via gmem[25], but that slot sits inside the display ring
-- (gmem[21..2068]) and was overwritten by @sample every frame. Hardcoding here
-- removes the slot-collision fragility; the JSFX layout is compile-time-fixed.
local EXPORT_BUF_BASE = 21 + 2048 + 2048 * 96 + 1024

local function gm_read(slot)  return R.gmem_read(slot)  end
local function gm_write(slot, val)  R.gmem_write(slot, val)  end

-- Export-path diagnostics. Flip DIAG=false once the regression is pinned
-- and a non-diagnostic patch has shipped. Gated so leaving the logger in
-- place costs nothing and the next regression can flip the switch.
local DIAG = false
local _last_not_ready_log = 0
local function _diag(fmt, ...)
  if DIAG then R.ShowConsoleMsg(string.format("[Recall] " .. fmt .. "\n", ...)) end
end

-- Pure-Lua 32-bit-float WAV writer. Replaces the JSFX-side
-- export_buffer_to_project() which was capped at 8 channels by REAPER.
-- Writing from Lua lets us support the full 16ch capture range. Format
-- tag 0x0003 = WAVE_FORMAT_IEEE_FLOAT; REAPER and every modern DAW reads
-- this without conversion.
local function _pack_wav_header(num_frames, nch, srate)
  local data_size = num_frames * nch * 4
  local fmt_body = string.pack("<I2I2I4I4I2I2",
    3, nch, srate, srate * nch * 4, nch * 4, 32)
  local riff_payload = "WAVE" ..
    "fmt " .. string.pack("<I4", #fmt_body) .. fmt_body ..
    "data" .. string.pack("<I4", data_size)
  return "RIFF" .. string.pack("<I4", #riff_payload + data_size) .. riff_payload
end

local _WAV_CHUNK = 4096
local _WAV_CHUNK_FMT = "<" .. string.rep("f", _WAV_CHUNK)

local function write_wav_float32_from_gmem(path, base, num_frames, nch, srate)
  _diag("wav path: %s", path)
  local f = io.open(path, "wb")
  if not f then
    _diag("wav open FAILED")
    return false
  end
  f:write(_pack_wav_header(num_frames, nch, srate))
  local total = num_frames * nch
  local gmem_read = R.gmem_read
  local buf = {}
  local i = 0
  while i + _WAV_CHUNK <= total do
    for j = 1, _WAV_CHUNK do buf[j] = gmem_read(base + i + j - 1) end
    f:write(string.pack(_WAV_CHUNK_FMT, table.unpack(buf, 1, _WAV_CHUNK)))
    i = i + _WAV_CHUNK
  end
  if i < total then
    local tail = total - i
    for j = 1, tail do buf[j] = gmem_read(base + i + j - 1) end
    f:write(string.pack("<" .. string.rep("f", tail),
      table.unpack(buf, 1, tail)))
  end
  f:close()
  _diag("wav written: %d frames x %d ch", num_frames, nch)
  if DIAG and num_frames > 0 and nch > 0 then
    -- Re-open the WAV and scan the first min(2048, num_frames) interleaved
    -- float32 frames for per-channel max-abs. Settles whether channel loss
    -- lives between gmem and the file bytes (WAV writer bug) versus
    -- between the file bytes and REAPER's item (PCM_Source / take mode).
    local f2 = io.open(path, "rb")
    if f2 then
      f2:seek("set", 44)  -- past RIFF/fmt(16)/data header
      local sample_n = math.min(2048, num_frames)
      local want_bytes = sample_n * nch * 4
      local data = f2:read(want_bytes)
      f2:close()
      if data and #data == want_bytes then
        local maxabs = {}
        for c = 0, nch - 1 do maxabs[c] = 0 end
        local pos = 1
        for _ = 0, sample_n - 1 do
          for c = 0, nch - 1 do
            local v = string.unpack("<f", data, pos)
            pos = pos + 4
            if v < 0 then v = -v end
            if v > maxabs[c] then maxabs[c] = v end
          end
        end
        local parts = {}
        for c = 0, nch - 1 do
          parts[#parts + 1] = string.format("ch%d=%.4f", c, maxabs[c])
        end
        _diag("  wav-file ch-maxabs over %d frames: %s",
          sample_n, table.concat(parts, " "))
      else
        _diag("  wav-file scan: read failed (got %s of %d bytes)",
          tostring(data and #data or nil), want_bytes)
      end
    end
  end
  return true
end

-- Insert a pre-written WAV file as a media item on `track` at `pos`,
-- without touching the user's track/time selection or edit cursor.
-- Matches the positioning contract of the deprecated
-- export_buffer_to_project()+SetEditCurPos flow.
local function insert_wav_on_track_at(track, pos, path, dur_sec)
  R.Undo_BeginBlock()
  local item = R.AddMediaItemToTrack(track)
  local take = R.AddTakeToMediaItem(item)
  local src  = R.PCM_Source_CreateFromFile(path)
  R.SetMediaItemTake_Source(take, src)
  R.SetMediaItemInfo_Value(item, "D_POSITION", pos)
  R.SetMediaItemInfo_Value(item, "D_LENGTH",   dur_sec)
  R.UpdateItemInProject(item)
  _diag("item inserted: pos=%g dur=%g", pos, dur_sec)
  -- Force an immediate peak build. Without this REAPER defers peaks
  -- until the item is rendered on-screen at a zoom level that triggers
  -- the cache, which for a short transient inside a longer item
  -- presents as "blank waveform at wide zoom, visible only when deep-
  -- zoomed". Mode 0 kicks and returns; REAPER finishes async on its
  -- worker thread. No wait, no defer-loop impact.
  R.PCM_Source_BuildPeaks(src, 0)
  if DIAG then
    local source_len = R.GetMediaSourceLength(src)
    _diag("  geometry: source_len=%.4f requested_dur=%.4f delta=%.6f",
      source_len, dur_sec, source_len - dur_sec)
    _diag("  peaks: BuildPeaks(mode=0) kicked")
  end
  R.Undo_EndBlock("Temper Recall: insert capture", -1)
end

local function _build_wav_path()
  local proj_path = R.GetProjectPath(""):gsub("\\", "/")
  if proj_path == "" then
    proj_path = (os.getenv("TEMP") or "."):gsub("\\", "/")
  end
  return string.format("%s/recall_%d_%d.wav",
    proj_path, math.floor(R.time_precise() * 1000), math.random(0, 99999))
end

local function find_jsfx_in_mon_fx()
  local master = R.GetMasterTrack(0)
  local count = R.TrackFX_GetRecCount(master)
  for i = 0, count - 1 do
    local idx = 0x1000000 + i
    local _, name = R.TrackFX_GetFXName(master, idx)
    if name and name:find("Temper Recall") then
      return idx
    end
  end
  return nil
end

local function install_jsfx()
  local master = R.GetMasterTrack(0)
  local idx = R.TrackFX_AddByName(master, CONFIG.jsfx_name, true, -1)
  if idx < 0 then return nil end
  idx = 0x1000000 + idx
  -- Briefly show JSFX window to activate @gfx (gfx_idle needs this)
  R.TrackFX_Show(master, idx, 1)  -- show floating
  R.TrackFX_Show(master, idx, 0)  -- hide floating
  return idx
end

-- LD-2026-04-018 observable.  Bumped every time reinstall_jsfx runs, so
-- the harness can assert the auto-reinstall path fired on proto mismatch.
local _reinstall_count = 0

-- Remove the existing JSFX and re-add a fresh copy. Used when the running
-- instance predates a gmem-protocol bump, so the user never has to
-- manually Reload JS after updating the script.
local function reinstall_jsfx(existing_idx)
  local master = R.GetMasterTrack(0)
  R.TrackFX_Delete(master, existing_idx)
  _reinstall_count = _reinstall_count + 1
  return install_jsfx()
end

local function ensure_jsfx()
  local idx = find_jsfx_in_mon_fx()
  if not idx then return install_jsfx() end
  local running_proto = R.gmem_read(GM.JSFX_PROTO)
  if running_proto ~= CONFIG.jsfx_proto_expected then
    return reinstall_jsfx(idx)
  end
  return idx
end

-- Channel-count probes + one-knob setter.
--
-- Recall lives on the master track's Monitor FX chain, which sits downstream
-- of the master's HW Out sends. Two gates govern how many channels reach it:
--   1. Master track I_NCHAN (must carry the mix).
--   2. HW Out send width (gates the device-output buffer the Monitor FX
--      chain reads from). Empirically verified: if HW Out is 2ch, the JSFX
--      only sees 2ch of real audio no matter what I_NCHAN is.
-- Monitor FX per-FX Track Channels is NOT readable from inside the plugin
-- (num_ch returns declared in-pin count of 16), so we don't surface it.

-- Max HW Out send width across all HW Outs on the master. Returns 0 when
-- no HW Out send exists.
local function probe_hw_out_nch(master)
  local n = R.GetTrackNumSends(master, 1)  -- category 1 = HW OUT
  local maxw = 0
  for i = 0, n - 1 do
    local raw = R.GetTrackSendInfo_Value(master, 1, i, "I_SRCCHAN")
    local _, count = routing_math.decode_src_channels(math.floor(raw))
    if count > maxw then maxw = count end
  end
  return maxw
end

-- Set identity pin mapping on fx_idx for the first n input+output pins
-- (pin P wired to track channel P) and clear pins [n..RECALL_MAX_PINS-1].
-- This is what the "Track channels: N" dropdown in REAPER's FX I/O window
-- actually writes under the hood -- setting pin bitmasks directly here
-- routes audio without having to go through the UI dropdown.
local RECALL_MAX_PINS = 16  -- matches in_pin/out_pin count in JSFX
local function set_fx_pin_mappings(master, fx_idx, n)
  for pin = 0, RECALL_MAX_PINS - 1 do
    local mask = (pin < n) and (1 << pin) or 0
    R.TrackFX_SetPinMappings(master, fx_idx, 0, pin, mask, 0)
    R.TrackFX_SetPinMappings(master, fx_idx, 1, pin, mask, 0)
  end
  if DIAG then
    local in_parts, out_parts = {}, {}
    for pin = 0, RECALL_MAX_PINS - 1 do
      local imask = R.TrackFX_GetPinMappings(master, fx_idx, 0, pin)
      local omask = R.TrackFX_GetPinMappings(master, fx_idx, 1, pin)
      in_parts[#in_parts + 1]  = string.format("p%d=%d", pin, imask)
      out_parts[#out_parts + 1] = string.format("p%d=%d", pin, omask)
    end
    _diag("pin-map readback n=%d in[%s] out[%s]", n,
      table.concat(in_parts, ","), table.concat(out_parts, ","))
  end
end

-- Wrap a REAPER state mutation in one undo step with UI refresh guards.
-- Single-entry wrapper so set_capture_channels and any future atomic
-- mutation share the begin/prevent/end idiom verbatim.
local function with_undo(name, fn)
  R.Undo_BeginBlock()
  R.PreventUIRefresh(1)
  fn()
  R.PreventUIRefresh(-1)
  R.Undo_EndBlock(name, -1)
end

-- Set master I_NCHAN + every HW Out send width + the Recall JSFX's pin
-- matrix to N in one undo step. The pin matrix step is load-bearing:
-- existing Monitor FX instances retain whatever Track Channels count
-- they had at install time, so raising I_NCHAN alone leaves pins 9..16
-- unwired even though the master now carries them. SetPinMappings writes
-- the same state the "Track channels" dropdown does, without needing
-- an undocumented parm name.
--
-- Idempotent: returns false when everything is already aligned (no undo
-- entry, no pin write). Returns true when something changed.
local function set_capture_channels(master, n, fx_idx)
  local cur_master = math.floor(
    R.GetMediaTrackInfo_Value(master, "I_NCHAN"))
  local num_sends = R.GetTrackNumSends(master, 1)
  local send_diffs = {}
  for i = 0, num_sends - 1 do
    local raw = math.floor(
      R.GetTrackSendInfo_Value(master, 1, i, "I_SRCCHAN"))
    local offset, count = routing_math.decode_src_channels(raw)
    if offset ~= -1 and count ~= n then
      send_diffs[#send_diffs + 1] = { idx = i, offset = offset }
    end
  end
  -- Always rewrite pin mappings when fx_idx is provided. Prior version
  -- guarded the rewrite on `cur_master ~= n`, which left pins stale in
  -- two common cases: (a) fresh JSFX install -- REAPER's default is
  -- stereo identity (pins 0..1) so channels 2..N-1 silently receive
  -- nothing; (b) user set I_NCHAN directly in REAPER without cycling
  -- the action, so cur_master already matched target. Root cause of
  -- the 2026-04-19 "eff_nch=0 at 12ch" regression.
  if cur_master == n and #send_diffs == 0 and not fx_idx then
    return false
  end

  with_undo(string.format("Temper Recall: set capture to %dch", n), function()
    if cur_master ~= n then
      R.SetMediaTrackInfo_Value(master, "I_NCHAN", n)
    end
    for _, d in ipairs(send_diffs) do
      local encoded = routing_math.encode_src_channels(d.offset, n)
      R.SetTrackSendInfo_Value(master, 1, d.idx, "I_SRCCHAN", encoded)
    end
    if fx_idx then set_fx_pin_mappings(master, fx_idx, n) end
  end)
  return true
end

-- Icon draw helpers: geometric shapes via DrawList so colors are guaranteed
-- (Unicode media glyphs render as OS emojis on some systems, ignoring text color).
local function draw_icon_pause(dl, cx, cy, col)
  R.ImGui_DrawList_AddRectFilled(dl, cx - 4, cy - 5, cx - 1, cy + 5, col)
  R.ImGui_DrawList_AddRectFilled(dl, cx + 1, cy - 5, cx + 4, cy + 5, col)
end

local function draw_icon_play(dl, cx, cy, col)
  -- Simple black right-pointing triangle, classic play shape
  R.ImGui_DrawList_AddTriangleFilled(dl,
    cx - 4, cy - 6,
    cx - 4, cy + 6,
    cx + 6, cy,
    col)
end

local function draw_icon_print(dl, cx, cy, col)
  -- Down arrow (bounce to track): 3px shaft + wide triangle head; centered on (cx, cy)
  R.ImGui_DrawList_AddRectFilled(dl, cx - 1.5, cy - 6, cx + 1.5, cy, col)
  R.ImGui_DrawList_AddTriangleFilled(dl,
    cx - 5, cy,
    cx + 5, cy,
    cx,     cy + 6,
    col)
end

local function draw_icon_gear(dl, cx, cy, col)
  -- Monochrome DrawList gear: 8 teeth dots + outlined ring body.
  -- Replaces U+2699 text-button rendering to bypass OS-emoji
  -- substitution under fallback fonts (LD-2026-04-017 pattern).
  -- Sized to match the visual weight of U+2699 at 13pt (~12-13px
  -- diameter) so Recall's gear reads at parity with suite Unicode
  -- gears until Wave 4(b) is propagated suite-wide.
  local R_TEETH  = 1.0
  local R_CIRCUM = 5.3
  local R_BODY   = 3.5
  for i = 0, 7 do
    local a  = (i / 8) * math.pi * 2 + math.pi / 8
    local tx = cx + math.cos(a) * R_CIRCUM
    local ty = cy + math.sin(a) * R_CIRCUM
    R.ImGui_DrawList_AddCircleFilled(dl, tx, ty, R_TEETH, col, 8)
  end
  R.ImGui_DrawList_AddCircle(dl, cx, cy, R_BODY, col, 20, 1.3)
end

local function icon_button(ctx_r, id, draw_icon, icon_col, bw, bh, bg, bg_hov, bg_act)
  local bx, by = R.ImGui_GetCursorScreenPos(ctx_r)
  local clicked = R.ImGui_InvisibleButton(ctx_r, id, bw, bh)
  local hovered = R.ImGui_IsItemHovered(ctx_r)
  local active  = R.ImGui_IsItemActive(ctx_r)
  local col = bg
  if active then col = bg_act
  elseif hovered then col = bg_hov end
  local dl = R.ImGui_GetWindowDrawList(ctx_r)
  R.ImGui_DrawList_AddRectFilled(dl, bx, by, bx + bw, by + bh, col, 3)
  draw_icon(dl, bx + bw * 0.5, by + bh * 0.5, icon_col, col)
  return clicked
end

local SC  -- color palette, set during init

do
  if not check_instance_guard() then return end

  local _ctx_ok, ctx = pcall(R.ImGui_CreateContext, "Temper Recall##trecall")
  if not _ctx_ok or not ctx then
    R.ShowMessageBox(
      "Temper Recall could not start. Close any existing instance, wait " ..
      "~15 seconds, then try again.",
      "Temper Recall", 0)
    return
  end

  -- Theme
  pcall(dofile, _lib .. "temper_theme.lua")
  if type(temper_theme) == "table" then
    temper_theme.attach_fonts(ctx)
    SC = temper_theme.SC
  else
    SC = {
      WINDOW     = 0x0E0E10FF, PANEL      = 0x1E1E20FF,
      PANEL_HIGH = 0x282828FF, PANEL_TOP  = 0x323232FF,
      HOVER_LIST = 0x39393BFF, PRIMARY    = 0x26A69AFF,
      PRIMARY_LT = 0x66D9CCFF, PRIMARY_HV = 0x30B8ACFF,
      PRIMARY_AC = 0x1A8A7EFF, TERTIARY   = 0xDA7C5AFF,
      TERTIARY_HV = 0xE08A6AFF, TERTIARY_AC = 0xC46A4AFF,
      TEXT_ON    = 0xDEDEDEFF, TEXT_MUTED = 0xBCC9C6FF,
      TEXT_OFF   = 0x505050FF, ERROR_RED  = 0xC0392BFF,
      TITLE_BAR  = 0x1A1A1CFF, ACTIVE_DARK = 0x141416FF,
      HOVER_INACTIVE = 0x2A2A2CFF, ICON_DISABLED = 0x606060FF,
    }
  end

  -- License
  local _lic_ok, lic = pcall(dofile, _lib .. "temper_license.lua")
  if not _lic_ok then lic = nil end
  if lic then lic.configure({
    namespace    = "TEMPER_Recall",
    scope_id     = 0xA,
    display_name = "Recall",
    buy_url      = "https://www.tempertools.com/scripts/recall",
  }) end

  -- Persisted settings (ExtState namespace _NS = "TEMPER_Recall").
  local function save_setting(key, val)
    R.SetExtState(_NS, key, tostring(val), true)
  end
  local function load_setting_num(key, default)
    local s = R.GetExtState(_NS, key)
    return tonumber(s) or default
  end
  local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
  end
  local loaded_buf_dur   = clamp(load_setting_num("buf_dur",   CONFIG.buf_dur_default),
                                 CONFIG.buf_dur_min,   CONFIG.buf_dur_max)
  local loaded_quick_dur = clamp(load_setting_num("quick_dur", CONFIG.quick_dur_default),
                                 CONFIG.quick_dur_min, CONFIG.quick_dur_max)
  local function load_setting_bool(key, default)
    local s = R.GetExtState(_NS, key)
    if s == "" then return default end
    return s == "1" or s == "true"
  end
  local function load_setting_str(key, default)
    local s = R.GetExtState(_NS, key)
    if s == "" then return default end
    return s
  end
  -- Capture nch is now driven by the JSFX's own Track Channels (per-FX I/O
  -- matrix). The legacy "channel_mode" ExtState (0=stereo, 1=mono sum)
  -- maps cleanly to force_mono: a user who chose Mono before the rewrite
  -- still wants mono after. Run the migration once, then clear the legacy
  -- key so subsequent loads read force_mono directly.
  local loaded_force_mono = load_setting_bool("force_mono", CONFIG.force_mono_default)
  local legacy_ch_mode = R.GetExtState(_NS, "channel_mode")
  if legacy_ch_mode ~= "" then
    if R.GetExtState(_NS, "force_mono") == "" then
      loaded_force_mono = (tonumber(legacy_ch_mode) == 1)
      save_setting("force_mono", loaded_force_mono and 1 or 0)
    end
    R.DeleteExtState(_NS, "channel_mode", true)
  end
  local loaded_cue_enabled     = load_setting_bool("cue_enabled",     CONFIG.cue_enabled_default)
  local loaded_cue_silence_db  = clamp(load_setting_num("cue_silence_db",  CONFIG.cue_silence_db_default),
                                       CONFIG.cue_silence_db_min,  CONFIG.cue_silence_db_max)
  local loaded_cue_sensitivity = clamp(load_setting_num("cue_sensitivity", CONFIG.cue_sensitivity_default),
                                       CONFIG.cue_sensitivity_min, CONFIG.cue_sensitivity_max)
  local loaded_cue_spacing_ms  = clamp(load_setting_num("cue_spacing_ms",  CONFIG.cue_spacing_ms_default),
                                       CONFIG.cue_spacing_ms_min,  CONFIG.cue_spacing_ms_max)
  local loaded_spec_gain_db    = clamp(load_setting_num("spec_gain_db", CONFIG.spec_gain_db_default),
                                       CONFIG.spec_gain_db_min, CONFIG.spec_gain_db_max)
  local loaded_spec_thresh_pm  = clamp(load_setting_num("spec_thresh_permille", CONFIG.spec_thresh_permille_default),
                                       CONFIG.spec_thresh_permille_min, CONFIG.spec_thresh_permille_max)

  -- gmem attach
  R.gmem_attach(CONFIG.gmem_ns)

  -- Initial handshake before JSFX first tick:
  --  - BUF_DUR: JSFX @block reads slot 4 and re-inits on change.
  --  - PAUSE=0: force LIVE state; gmem persists across sessions, so a
  --    prior session that exited while paused would leave slot 9 at 1
  --    and the script would appear "live" on the UI but silent in the
  --    ring until the user toggled pause twice.
  R.gmem_write(GM.BUF_DUR, loaded_buf_dur)
  R.gmem_write(GM.PAUSE, 0)
  R.gmem_write(GM.FORCE_MONO, loaded_force_mono and 1 or 0)
  R.gmem_write(GM.SPEC_GAIN_DB, loaded_spec_gain_db)
  -- Seed SET_NCH before JSFX's first @block so the initial buffer allocation
  -- sizes correctly for master.I_NCHAN. Per-frame updates keep it in sync.
  local _master = R.GetMasterTrack(0)
  R.gmem_write(GM.SET_NCH, math.floor(R.GetMediaTrackInfo_Value(_master, "I_NCHAN")))

  -- JSFX
  local jsfx_idx = ensure_jsfx()

  -- Force pin-mapping sync on launch. A fresh JSFX install (first run, or
  -- reinstall-after-proto-bump) inherits REAPER's default 2-pin stereo
  -- identity, leaving pins 2..15 unwired even when master I_NCHAN is
  -- wider. Channels beyond stereo stay silent until the user cycles
  -- capture channels *through* a different value -- opaque failure mode.
  -- Sync once here, then `set_capture_channels` (always-pin-rewrite now)
  -- keeps them aligned for every subsequent change.
  if jsfx_idx then
    local _cur_nch = math.floor(R.GetMediaTrackInfo_Value(_master, "I_NCHAN"))
    set_fx_pin_mappings(_master, jsfx_idx, _cur_nch)
  end

  -- State
  local state = {
    jsfx_ok        = jsfx_idx ~= nil,
    capturing      = true,
    selections     = {},      -- array of {start, width} entries; each normalized [0,1)
    _active_idx    = nil,     -- index into selections, for single-selection operations
    sel_dragging   = false,
    drag_export    = false,
    _click_norm    = nil,
    should_close   = false,
    buf_dur        = loaded_buf_dur,
    quick_dur      = loaded_quick_dur,
    force_mono     = loaded_force_mono,
    cap_nch        = 2,  -- updated each frame from gmem CAP_NCH broadcast
    effective_nch  = 2,  -- updated each frame from gmem EFFECTIVE_NCH broadcast
    -- Post-export signal-gap detector. Set by _consume_export when the
    -- staged gmem shows signal on fewer channels than the declared
    -- capture width. Fires the upstream-routing warning in the settings
    -- popup. Reset to 0 when a capture comes back clean.
    last_capture_signal_ch      = 0,
    last_capture_declared_nch   = 0,
    last_capture_signal_ts      = 0,
    cues            = {},      -- array of { norm = <0..1> }, re-detected each frame
    cue_enabled     = loaded_cue_enabled,
    cue_silence_db  = loaded_cue_silence_db,
    cue_sensitivity = loaded_cue_sensitivity,
    cue_spacing_ms  = loaded_cue_spacing_ms,
    view_mode       = load_setting_str("view_mode", CONFIG.view_mode_default),
    -- Spectrogram live controls. spec_thresh_permille is the integer
    -- form (0..100) the slider edits; _spec_threshold is the divided
    -- form (0.000..0.100) the render path reads.
    spec_gain_db         = loaded_spec_gain_db,
    spec_thresh_permille = loaded_spec_thresh_pm,
    _spec_threshold      = loaded_spec_thresh_pm / 1000,
  }

  local function active_sel(st)
    if not st._active_idx then return nil end
    return st.selections[st._active_idx]
  end

  -- Selection shape: {start_norm, width_norm, cum_age}.
  -- cum_age is the unbounded cumulative age of the older edge since
  -- creation; unlike (wh - start_norm) % 1.0 it does not wrap, so
  -- clip vs prune can be distinguished.
  local function set_active_sel(st, start_n, width_n)
    local cum = ((st._write_head or 0) - start_n) % 1.0
    st.selections = {{start_n, width_n, cum}}
    st._active_idx = 1
  end

  local function clear_selections(st)
    st.selections = {}
    st._active_idx = nil
  end

  local function add_selection(st, start_n, width_n)
    local cum = ((st._write_head or 0) - start_n) % 1.0
    st.selections[#st.selections + 1] = {start_n, width_n, cum}
    st._active_idx = #st.selections
  end

  local function remove_selection_at(st, idx)
    table.remove(st.selections, idx)
    if #st.selections == 0 then
      st._active_idx = nil
    elseif st._active_idx and st._active_idx > #st.selections then
      st._active_idx = #st.selections
    end
  end

  -- Pixel -> normalized buffer position. Matches the age-based render
  -- orientation: rightmost pixel = newest (wh), leftmost = oldest
  -- (wh + ~1/dw mod 1). Without this matching orientation, clicks at
  -- non-rightmost pixels produce sel[1] values pointing at the wrong
  -- buffer slot; export reads wrong audio; hit-test misses.
  local function px_to_norm_s(px_x, dx, dw, wh)
    local i = px_x - dx
    if i < 0 then i = 0 end
    if i > dw - 1 then i = dw - 1 end
    local age = (dw - 1 - i) / dw    -- 0 at right, (dw-1)/dw at left
    return (wh - age) % 1.0
  end

  local function hit_test_selection(st, mx, dx, dw, wh)
    local click_norm = px_to_norm_s(mx, dx, dw, wh)
    for i, s in ipairs(st.selections) do
      if s[2] > 0 then
        local offset = click_norm - s[1]
        if offset < 0 then offset = offset + 1.0 end
        if offset <= s[2] then return i end
      end
    end
    return nil
  end

  -- Multi-item drag-to-track export. The JSFX handles one trigger at a time
  -- and clears gmem[EXPORT_TRIGGER] when done, so Lua queues the selections
  -- and drains one per frame, setting the edit cursor ahead of each so items
  -- land sequentially on the target track.
  local function enqueue_exports(st, drop_pos, track_idx)
    local buf_dur = st.buf_dur
    local wh_now = st._write_head or 0
    local ordered = {}
    for _, s in ipairs(st.selections) do
      if s[2] > 0 then
        -- Clip export to the portion still present in the ring buffer.
        -- When cum_age (s[3]) has passed 1.0, the first (cum - 1) buffer-
        -- units of the stored start have been overwritten; shift start
        -- forward and shrink width so the exported audio matches the
        -- drawn rectangle. Fully-aged selections should have been pruned.
        local cum = s[3] or ((wh_now - s[1]) % 1.0)
        if cum < 1.0 + s[2] then
          local valid_start_age = math.min(cum, 1.0)
          local valid_end_age   = math.max(cum - s[2], 0.0)
          local valid_width     = valid_start_age - valid_end_age
          if valid_width > 0 then
            ordered[#ordered + 1] = {
              norm  = (wh_now - valid_start_age) % 1.0,
              width = valid_width,
              age   = valid_start_age,
            }
          end
        end
      end
    end
    table.sort(ordered, function(a, b) return a.age > b.age end)

    st._export_queue = st._export_queue or {}
    local cursor = drop_pos
    for _, item in ipairs(ordered) do
      st._export_queue[#st._export_queue + 1] = {
        kind      = "drag",
        pos       = cursor,
        sel_start = item.norm,
        sel_width = item.width,
        track_idx = track_idx,
      }
      cursor = cursor + item.width * buf_dur
    end
  end

  -- Drain a single staged export from gmem: read metadata + samples, write
  -- WAV, insert on target track at cached position. Returns true if the
  -- insertion completed (success or benign skip), false if the ready flag
  -- wasn't actually set (caller shouldn't advance the queue).
  local function _consume_export(st, req)
    local ready = gm_read(GM.EXPORT_READY)
    if ready ~= 1 then
      local now = R.time_precise()
      if _last_not_ready_log + 1.0 < now then
        _diag("waiting: READY=%s trigger=%s",
          tostring(ready), tostring(gm_read(GM.EXPORT_TRIGGER)))
        _last_not_ready_log = now
      end
      return false
    end
    local num_frames = math.floor(gm_read(GM.EXPORT_NUM_FRAMES))
    local nch        = math.floor(gm_read(GM.EXPORT_ACTUAL_NCH))
    local srate      = gm_read(GM.SRATE)
    local base       = EXPORT_BUF_BASE
    _diag("consume: frames=%d nch=%d srate=%g base=%d",
      num_frames, nch, srate, base)
    -- Always-run per-channel signal scan covering the full num_frames
    -- under a bounded gmem_read budget. Stride-sampled when a full
    -- per-frame scan would exceed budget; full-scan for short captures
    -- so 2-ch short transients keep per-sample precision. Replaces the
    -- v0.4.10 head-1000 window that misread multi-second captures as
    -- "ch2..ch15 dead" when signal simply sat past the first ~10 ms.
    -- See docs/knowledge/dead-ends-and-lessons.md — "Recall S1 — The
    -- Too-Narrow Diagnostic".
    if num_frames > 0 and nch > 0 then
      local READ_BUDGET = 100000
      local total_reads_if_full = num_frames * nch
      local stride
      if total_reads_if_full <= READ_BUDGET then
        stride = 1
      else
        stride = math.floor(total_reads_if_full / READ_BUDGET)
        if stride < 1 then stride = 1 end
      end
      local il_max = {}
      for c = 0, nch - 1 do il_max[c] = 0 end
      local reads = 0
      local f = 0
      while f < num_frames do
        local fbase = base + f * nch
        for c = 0, nch - 1 do
          local vi = gm_read(fbase + c)
          if vi < 0 then vi = -vi end
          if vi > il_max[c] then il_max[c] = vi end
        end
        reads = reads + nch
        f = f + stride
      end
      -- Count channels carrying real signal (floor ≈ -80 dBFS). Stores
      -- the measured-vs-declared pair on state for the warning renderer.
      local ACTIVE_FLOOR = 1e-4
      local active = 0
      for c = 0, nch - 1 do
        if il_max[c] > ACTIVE_FLOOR then active = active + 1 end
      end
      st.last_capture_signal_ch    = active
      st.last_capture_declared_nch = nch
      st.last_capture_signal_ts    = R.time_precise()

      if DIAG then
        local span_ms = (srate > 0) and math.floor((num_frames / srate) * 1000) or 0
        local srate_i = math.floor(srate)
        local il_parts = {}
        for c = 0, nch - 1 do
          il_parts[#il_parts + 1] = string.format("ch%d=%.4f", c, il_max[c])
        end
        _diag("  widened scan: frames=%d stride=%d reads=%d (~%dms span); ch-maxabs: %s",
          num_frames, stride, reads, span_ms, table.concat(il_parts, " "))
        _diag("  gmem head-1000 probe (layout forensics, not a capture summary):")
        local probe_n = math.min(1000, num_frames)
        local head_ms = (srate > 0) and ((probe_n / srate) * 1000) or 0
        local pil_max = {}
        for c = 0, nch - 1 do pil_max[c] = 0 end
        for pf = 0, probe_n - 1 do
          local fbase = base + pf * nch
          for c = 0, nch - 1 do
            local vi = gm_read(fbase + c)
            if vi < 0 then vi = -vi end
            if vi > pil_max[c] then pil_max[c] = vi end
          end
        end
        local pil_parts = {}
        for c = 0, nch - 1 do
          pil_parts[#pil_parts + 1] = string.format("ch%d=%.4f", c, pil_max[c])
        end
        _diag("    interleaved (%d frames, ~%.1fms @ %dHz): %s",
          probe_n, head_ms, srate_i, table.concat(pil_parts, " "))
        local pl_max = {}
        for c = 0, nch - 1 do pl_max[c] = 0 end
        for pf = 0, probe_n - 1 do
          for c = 0, nch - 1 do
            local vp = gm_read(base + c * num_frames + pf)
            if vp < 0 then vp = -vp end
            if vp > pl_max[c] then pl_max[c] = vp end
          end
        end
        local pl_parts = {}
        for c = 0, nch - 1 do
          pl_parts[#pl_parts + 1] = string.format("ch%d=%.4f", c, pl_max[c])
        end
        _diag("    planar      (sparse %d frames): %s",
          probe_n, table.concat(pl_parts, " "))
        _diag("    raw[base+0..7]: %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f",
          gm_read(base+0), gm_read(base+1), gm_read(base+2), gm_read(base+3),
          gm_read(base+4), gm_read(base+5), gm_read(base+6), gm_read(base+7))
      end
    end
    if num_frames > 0 and nch > 0 and srate > 0 and base > 0 then
      local path = _build_wav_path()
      if write_wav_float32_from_gmem(path, base, num_frames, nch, srate) then
        -- LD-2026-04-019 observable: latch the channel count the WAV
        -- writer was invoked with.  force_mono must produce nch=1 here;
        -- a regression that produces dual-mono would leave nch=2.
        st.last_export_nch = nch
        local track = R.GetTrack(0, req.track_idx)
        if track then
          insert_wav_on_track_at(track, req.pos, path, num_frames / srate)
        end
      end
    end
    gm_write(GM.EXPORT_READY, 0)
    return true
  end

  -- Per-tick state machine. Waits for JSFX to populate the staging buffer
  -- (EXPORT_READY = 1) before reading it out, then dispatches the next
  -- queued request. Print (kind="print") uses EXPORT_TYPE=2 with a
  -- duration; drag (kind="drag") uses type=3 with a selection window.
  local function pump_export_queue(st)
    if st._export_waiting then
      if _consume_export(st, st._export_current) then
        st._export_waiting = false
        st._export_current = nil
        if st._export_queue and #st._export_queue > 0 then
          table.remove(st._export_queue, 1)
        end
      else
        return
      end
    end
    if not st._export_queue or #st._export_queue == 0 then
      return
    end
    local req = st._export_queue[1]
    gm_write(GM.EXPORT_TRACK, req.track_idx)
    if req.kind == "print" then
      gm_write(GM.EXPORT_DURATION, req.duration)
      gm_write(GM.EXPORT_TYPE,     2)
    else
      gm_write(GM.SEL_START,       req.sel_start)
      gm_write(GM.SEL_WIDTH,       req.sel_width)
      gm_write(GM.EXPORT_TYPE,     3)
    end
    _diag("dispatch %s track=%d type=%d trigger_was=%s ready_was=%s base=%d",
      req.kind, req.track_idx,
      (req.kind == "print") and 2 or 3,
      tostring(gm_read(GM.EXPORT_TRIGGER)),
      tostring(gm_read(GM.EXPORT_READY)),
      EXPORT_BUF_BASE)
    -- Phase A diag (2026-04-19): log capture gating so we can tell at a
    -- glance whether I_NCHAN, pins, and upstream signal are all wide
    -- enough for N-channel capture at dispatch time.
    if DIAG then
      local _m = R.GetMasterTrack(0)
      _diag("  capture: I_NCHAN=%d eff_nch=%d force_mono=%d",
        math.floor(R.GetMediaTrackInfo_Value(_m, "I_NCHAN")),
        math.floor(gm_read(GM.EFFECTIVE_NCH)),
        math.floor(gm_read(GM.FORCE_MONO)))
    end
    gm_write(GM.EXPORT_TRIGGER, 1)
    st._export_waiting = true
    st._export_current = req
  end

  -- Alloy-style segmented pill push/pop. Active = teal on dark-text,
  -- inactive = dark-panel with teal text. Callers must PopStyleColor(4)
  -- after ImGui_Button.
  local function push_pill_active(c)
    R.ImGui_PushStyleColor(c, R.ImGui_Col_Button(),        SC.PRIMARY)
    R.ImGui_PushStyleColor(c, R.ImGui_Col_ButtonHovered(), SC.PRIMARY_HV)
    R.ImGui_PushStyleColor(c, R.ImGui_Col_ButtonActive(),  SC.PRIMARY_AC)
    R.ImGui_PushStyleColor(c, R.ImGui_Col_Text(),          SC.WINDOW)
  end
  local function push_pill_inactive(c)
    R.ImGui_PushStyleColor(c, R.ImGui_Col_Button(),        SC.PANEL_TOP)
    R.ImGui_PushStyleColor(c, R.ImGui_Col_ButtonHovered(), SC.HOVER_LIST)
    R.ImGui_PushStyleColor(c, R.ImGui_Col_ButtonActive(),  SC.ACTIVE_DARK)
    R.ImGui_PushStyleColor(c, R.ImGui_Col_Text(),          SC.PRIMARY)
  end

  -- Numeric-slider configuration: single source of truth for label, id,
  -- range, format, and the commit action (state + ExtState + side effects).
  -- Both the slider drag-commit path and the right-click inline-edit popup
  -- dispatch through `apply`, so there is one place to change per-key
  -- behaviour. Inline-edit clamping uses min/max from this table as well.
  local SLIDER_CONFIGS = {
    buf_dur = {
      label = "Buffer duration", id = "##buf_dur_sec",
      min = CONFIG.buf_dur_min, max = CONFIG.buf_dur_max, fmt = "%d s",
      apply = function(st, v)
        st.buf_dur = v
        R.gmem_write(GM.BUF_DUR, v)
        save_setting("buf_dur", v)
        clear_selections(st)
      end,
    },
    quick_dur = {
      label = "Print duration", id = "##quick_dur_sec",
      min = CONFIG.quick_dur_min, max = CONFIG.quick_dur_max, fmt = "%d s",
      apply = function(st, v)
        st.quick_dur = v
        save_setting("quick_dur", v)
      end,
    },
    cue_silence_db = {
      label = "Silence floor", id = "##cue_silence_db",
      min = CONFIG.cue_silence_db_min, max = CONFIG.cue_silence_db_max, fmt = "%d dB",
      apply = function(st, v)
        st.cue_silence_db = v
        save_setting("cue_silence_db", v)
      end,
    },
    cue_sensitivity = {
      label = "Sensitivity", id = "##cue_sensitivity",
      min = CONFIG.cue_sensitivity_min, max = CONFIG.cue_sensitivity_max, fmt = "%d%%",
      apply = function(st, v)
        st.cue_sensitivity = v
        save_setting("cue_sensitivity", v)
      end,
    },
    cue_spacing_ms = {
      label = "Min spacing", id = "##cue_spacing_ms",
      min = CONFIG.cue_spacing_ms_min, max = CONFIG.cue_spacing_ms_max, fmt = "%d ms",
      apply = function(st, v)
        st.cue_spacing_ms = v
        save_setting("cue_spacing_ms", v)
      end,
    },
    spec_gain_db = {
      label = "Spec gain", id = "##spec_gain_db",
      min = CONFIG.spec_gain_db_min, max = CONFIG.spec_gain_db_max, fmt = "%d dB",
      apply = function(st, v)
        st.spec_gain_db = v
        R.gmem_write(GM.SPEC_GAIN_DB, v)
        save_setting("spec_gain_db", v)
      end,
    },
    spec_thresh_permille = {
      label = "Noise floor", id = "##spec_thresh_permille",
      min = CONFIG.spec_thresh_permille_min, max = CONFIG.spec_thresh_permille_max,
      fmt = "%d\xE2\x80\xAF\xE2\x80\xB0",
      apply = function(st, v)
        st.spec_thresh_permille = v
        st._spec_threshold = v / 1000
        save_setting("spec_thresh_permille", v)
      end,
    },
  }

  -- Render a labelled SliderInt for one SLIDER_CONFIGS key, with the
  -- right-click-to-inline-edit hook wired to _input_popup_request. width
  -- is the pixel width of the slider (label sits above, full-width text).
  local function persisted_slider(ctx_r, st, key, width)
    local cfg = SLIDER_CONFIGS[key]
    R.ImGui_Text(ctx_r, cfg.label)
    R.ImGui_SetNextItemWidth(ctx_r, width)
    local changed, new_v = R.ImGui_SliderInt(
      ctx_r, cfg.id, st[key], cfg.min, cfg.max, cfg.fmt)
    if R.ImGui_IsItemClicked(ctx_r, 1) then
      st._input_popup_request = key
      st._input_popup_val     = st[key]
    end
    if changed then cfg.apply(st, new_v) end
  end

  -- One-frame snapshot of the downstream routing gates. Settings popup
  -- and title-bar pill both read this; computing once per frame avoids
  -- duplicate send-loop probes and keeps the gates consistent between
  -- the two readers within a single frame.
  local function probe_routing()
    local master_tr   = R.GetMasterTrack(0)
    local master_nch  = math.floor(
      R.GetMediaTrackInfo_Value(master_tr, "I_NCHAN"))
    local hw_out_nch  = probe_hw_out_nch(master_tr)
    local device_outs = R.GetNumAudioOutputs()
    local hw_low      = hw_out_nch  > 0 and hw_out_nch  < master_nch
    local device_low  = device_outs > 0 and device_outs < master_nch
    return {
      master_tr   = master_tr,
      master_nch  = master_nch,
      hw_out_nch  = hw_out_nch,
      device_outs = device_outs,
      hw_low      = hw_low,
      device_low  = device_low,
      routing_gap = hw_low or device_low,
    }
  end

  -- Settings popup body. Runs inside BeginPopup/EndPopup; caller owns the
  -- gear-button OpenPopup trigger. Reads routing snapshot computed once
  -- per frame by render_title_bar. Does not push the bold font -- relies
  -- on the outer render_title_bar's PushFont still being active.
  local function settings_popup(ctx_r, st, lic_mod, lic_status, routing)
    R.ImGui_SetNextWindowSize(ctx_r, 235, 0, R.ImGui_Cond_Always())
    if not R.ImGui_BeginPopup(ctx_r, "##settings_recall") then return end

    if R.ImGui_Button(ctx_r, "Close##settings_close") then
      st.should_close = true
      R.ImGui_CloseCurrentPopup(ctx_r)
    end
    if lic_status == "trial" and lic_mod then
      R.ImGui_SameLine(ctx_r)
      if R.ImGui_Button(ctx_r, "Activate\xE2\x80\xA6##recall_activate") then
        lic_mod.open_dialog(ctx_r)
        R.ImGui_CloseCurrentPopup(ctx_r)
      end
    end
    R.ImGui_Spacing(ctx_r)
    R.ImGui_Separator(ctx_r)
    R.ImGui_Spacing(ctx_r)

    -- Two-column layout geometry. Content area = 219px (popup 235 -
    -- 2*8 WindowPadding); 108 + 3 + 108 matches the channel button row
    -- below exactly, so visual rhythm stays consistent across the popup.
    local COL_W = 108
    local COL_GAP = 3
    local BTN_H = 22

    -- Row: Waveform|Spectral cycle button  |  Force Mono toggle button.
    -- Waveform cycle is always teal-active (Alloy SOURCE FOLDER style).
    -- Force Mono is grey+grey-text when off, orange+black-text when on.
    -- Column-2 anchored by explicit SetCursorPos off row_x/row_y so the
    -- 3px gap is exact regardless of previous-item or group bounding
    -- boxes (SameLine(offset) is window-origin-absolute, not
    -- content-relative, so passing COL_W + COL_GAP silently subtracted
    -- WindowPadding and caused overlap).
    local row_x, row_y = R.ImGui_GetCursorPos(ctx_r)
    local wv_label = (st.view_mode == "spectral") and "SPECTRAL" or "WAVEFORM"
    push_pill_active(ctx_r)
    if R.ImGui_Button(ctx_r, wv_label .. "##view_mode_cycle", COL_W, BTN_H) then
      st.view_mode = (st.view_mode == "spectral") and "waveform" or "spectral"
      st._spec_decay = nil
      save_setting("view_mode", st.view_mode)
    end
    R.ImGui_PopStyleColor(ctx_r, 4)

    R.ImGui_SetCursorPos(ctx_r, row_x + COL_W + COL_GAP, row_y)

    if st.force_mono then
      R.ImGui_PushStyleColor(ctx_r, R.ImGui_Col_Button(),        SC.TERTIARY)
      R.ImGui_PushStyleColor(ctx_r, R.ImGui_Col_ButtonHovered(), SC.TERTIARY_HV or 0xE08A6AFF)
      R.ImGui_PushStyleColor(ctx_r, R.ImGui_Col_ButtonActive(),  SC.TERTIARY_AC or 0xC46A4AFF)
      R.ImGui_PushStyleColor(ctx_r, R.ImGui_Col_Text(),          SC.WINDOW)
    else
      R.ImGui_PushStyleColor(ctx_r, R.ImGui_Col_Button(),        SC.PANEL)
      R.ImGui_PushStyleColor(ctx_r, R.ImGui_Col_ButtonHovered(), SC.HOVER_INACTIVE)
      R.ImGui_PushStyleColor(ctx_r, R.ImGui_Col_ButtonActive(),  SC.PANEL)
      R.ImGui_PushStyleColor(ctx_r, R.ImGui_Col_Text(),          SC.TEXT_OFF)
    end
    if R.ImGui_Button(ctx_r, "FORCE MONO##force_mono_cycle", COL_W, BTN_H) then
      st.force_mono = not st.force_mono
      R.gmem_write(GM.FORCE_MONO, st.force_mono and 1 or 0)
      save_setting("force_mono", st.force_mono and 1 or 0)
    end
    R.ImGui_PopStyleColor(ctx_r, 4)

    -- Row: Buffer duration  |  Print duration (two-column sliders).
    R.ImGui_Dummy(ctx_r, 0, 4)
    row_x, row_y = R.ImGui_GetCursorPos(ctx_r)
    R.ImGui_BeginGroup(ctx_r)
    persisted_slider(ctx_r, st, "buf_dur", COL_W)
    R.ImGui_EndGroup(ctx_r)
    R.ImGui_SetCursorPos(ctx_r, row_x + COL_W + COL_GAP, row_y)
    R.ImGui_BeginGroup(ctx_r)
    persisted_slider(ctx_r, st, "quick_dur", COL_W)
    R.ImGui_EndGroup(ctx_r)

    R.ImGui_Dummy(ctx_r, 0, 4)
    R.ImGui_Text(ctx_r, "Capture channels")
    local master_tr   = routing.master_tr
    local master_nch  = routing.master_nch
    local hw_out_nch  = routing.hw_out_nch
    local device_outs = routing.device_outs
    local effective_cap = master_nch
    if hw_out_nch  > 0 and hw_out_nch  < effective_cap then
      effective_cap = hw_out_nch
    end
    if device_outs > 0 and device_outs < effective_cap then
      effective_cap = device_outs
    end
    local CHANNEL_OPTS = { 2, 4, 6, 8, 12, 16 }
    for pi, n in ipairs(CHANNEL_OPTS) do
      if pi > 1 then R.ImGui_SameLine(ctx_r, 0, 3) end
      local exceeds_device = device_outs > 0 and n > device_outs
      local is_active = (n == effective_cap)
      if exceeds_device then
        R.ImGui_PushStyleColor(ctx_r, R.ImGui_Col_Button(),        SC.PANEL)
        R.ImGui_PushStyleColor(ctx_r, R.ImGui_Col_ButtonHovered(), SC.HOVER_INACTIVE)
        R.ImGui_PushStyleColor(ctx_r, R.ImGui_Col_ButtonActive(),  SC.PANEL)
        R.ImGui_PushStyleColor(ctx_r, R.ImGui_Col_Text(),          SC.TEXT_OFF)
        R.ImGui_BeginDisabled(ctx_r)
      elseif is_active then push_pill_active(ctx_r)
      else push_pill_inactive(ctx_r) end
      if R.ImGui_Button(ctx_r,
          string.format("%d##cap_ch_%d", n, n), 34, 22) then
        if set_capture_channels(master_tr, n, jsfx_idx) then
          -- Force gmem refresh so JSFX picks up the new nch next frame.
          R.gmem_write(GM.SET_NCH, n)
          clear_selections(st)
          -- Propagate NCHAN to the user's currently-selected track too so
          -- a print target stays matched to capture width. Skip if nothing
          -- selected, if master itself is selected (already handled above),
          -- or if the track already has the right channel count.
          local sel = R.GetSelectedTrack(0, 0)
          if sel and sel ~= master_tr then
            local cur = math.floor(R.GetMediaTrackInfo_Value(sel, "I_NCHAN"))
            if cur ~= n then
              with_undo(
                string.format("Temper Recall: match selected track to %dch", n),
                function()
                  R.SetMediaTrackInfo_Value(sel, "I_NCHAN", n)
                end)
            end
          end
        end
      end
      if exceeds_device then
        R.ImGui_EndDisabled(ctx_r)
        if R.ImGui_IsItemHovered(ctx_r) then
          R.ImGui_SetTooltip(ctx_r, string.format(
            "Audio device exposes only %dch. Raise in REAPER Prefs \xe2\x86\x92 Device.",
            device_outs))
        end
      end
      R.ImGui_PopStyleColor(ctx_r, 4)
    end
    R.ImGui_PushStyleColor(ctx_r, R.ImGui_Col_Text(), SC.TEXT_MUTED)
    if device_outs > 0 then
      R.ImGui_TextWrapped(ctx_r, string.format(
        "Audio Device Exposes %dch\n(Master Track & HW Out)",
        device_outs))
    else
      R.ImGui_TextWrapped(ctx_r, "(Master Track & HW Out)")
    end
    R.ImGui_PopStyleColor(ctx_r, 1)

    -- Routing-gap warning: fires when a probe-able downstream gate is
    -- narrower than master I_NCHAN. Two cases:
    --   hw_low     -- HW Out send is narrower than master (Lua-fixable)
    --   device_low -- audio device exposes fewer channels than master
    --                 (user must raise in REAPER Prefs, no Lua fix)
    -- effective_nch is intentionally NOT used: it decays on silence and
    -- would cry wolf every time playback stops. Monitor FX per-FX Track
    -- Channels is not readable, so we don't diagnose it.
    if routing.routing_gap then
      R.ImGui_Dummy(ctx_r, 0, 6)
      R.ImGui_PushStyleColor(ctx_r, R.ImGui_Col_Text(), SC.TERTIARY)
      if routing.device_low then
        R.ImGui_TextWrapped(ctx_r, string.format(
          "Audio device exposes %dch. Recall can capture %dch only after " ..
          "raising output count in REAPER Prefs \xe2\x86\x92 Device.",
          device_outs, master_nch))
      else
        R.ImGui_TextWrapped(ctx_r, string.format(
          "HW Out is %dch. Recall needs %dch to capture the full mix.",
          hw_out_nch, master_nch))
      end
      R.ImGui_PopStyleColor(ctx_r, 1)
      if routing.hw_low and not routing.device_low then
        R.ImGui_Dummy(ctx_r, 0, 2)
        R.ImGui_PushStyleColor(ctx_r, R.ImGui_Col_Button(),        SC.TERTIARY)
        R.ImGui_PushStyleColor(ctx_r, R.ImGui_Col_ButtonHovered(), SC.TERTIARY_HV)
        R.ImGui_PushStyleColor(ctx_r, R.ImGui_Col_ButtonActive(),  SC.TERTIARY_AC)
        R.ImGui_PushStyleColor(ctx_r, R.ImGui_Col_Text(),          SC.WINDOW)
        if R.ImGui_Button(ctx_r,
            string.format("Widen HW Out to %dch##cap_fix", master_nch),
            -1, 0) then
          if set_capture_channels(master_tr, master_nch, jsfx_idx) then
            R.gmem_write(GM.SET_NCH, master_nch)
            clear_selections(st)
          end
        end
        R.ImGui_PopStyleColor(ctx_r, 4)
      end
      R.ImGui_Dummy(ctx_r, 0, 2)
      R.ImGui_PushStyleColor(ctx_r, R.ImGui_Col_Button(),        SC.PANEL_TOP)
      R.ImGui_PushStyleColor(ctx_r, R.ImGui_Col_ButtonHovered(), SC.HOVER_LIST)
      R.ImGui_PushStyleColor(ctx_r, R.ImGui_Col_ButtonActive(),  SC.ACTIVE_DARK)
      R.ImGui_PushStyleColor(ctx_r, R.ImGui_Col_Text(),          SC.PRIMARY)
      if R.ImGui_Button(ctx_r, "Open Monitor FX##open_monfx", -1, 0) then
        if jsfx_idx then
          R.TrackFX_Show(R.GetMasterTrack(0), jsfx_idx, 3)
        end
      end
      R.ImGui_PopStyleColor(ctx_r, 4)
    end

    -- Signal-gap warning: declared capture width exceeds the number of
    -- channels that actually carried signal in the last capture. This
    -- is upstream of Recall -- source track I_NCHAN narrower than
    -- master, Media Explorer preview using a stereo bus, or a pre-
    -- master FX chain folding the signal -- so there's no Lua fix
    -- button, only guidance. Threshold declared >= 4 avoids flagging
    -- the standard stereo capture; signal_ch > 0 avoids flagging
    -- captures that happened during total silence.
    local sig_ch  = st.last_capture_signal_ch
    local sig_dec = st.last_capture_declared_nch
    -- Allow 1-ch slack: 3OA 16-ch IRs intrinsically leave ch15 silent, so
    -- "15 of 16" is expected. Stereo-into-8 and other real mismatches still
    -- fire because they fall two or more channels short.
    if sig_dec >= 4 and sig_ch > 0 and sig_ch < sig_dec - 1 then
      R.ImGui_Dummy(ctx_r, 0, 6)
      R.ImGui_PushStyleColor(ctx_r, R.ImGui_Col_Text(), SC.TERTIARY)
      R.ImGui_TextWrapped(ctx_r, string.format(
        "Last capture carried signal on %d of %d channels. Source " ..
        "track, Media Explorer preview, or a pre-master FX may be " ..
        "narrowing the signal before it reaches Recall.",
        sig_ch, sig_dec))
      R.ImGui_PopStyleColor(ctx_r, 1)
    end

    R.ImGui_Dummy(ctx_r, 0, 8)
    R.ImGui_Separator(ctx_r)
    R.ImGui_Dummy(ctx_r, 0, 4)
    -- Row: CUE DETECT toggle (narrower + visually centered in column
    -- so a 22px button doesn't anchor-top against a ~42px label+slider
    -- column)  |  Silence floor slider.
    -- Disabled wrap is column-scoped: toggling off greys the right
    -- column (Silence) without dimming the CUE DETECT button itself.
    row_x, row_y = R.ImGui_GetCursorPos(ctx_r)
    local CUE_BTN_W = 96
    local CUE_COL_H = 42   -- approx label(~18) + itemspacing(~4) + slider(~20)
    R.ImGui_BeginGroup(ctx_r)
    R.ImGui_SetCursorPos(ctx_r,
      row_x + math.floor((COL_W - CUE_BTN_W) / 2),
      row_y + math.floor((CUE_COL_H - BTN_H) / 2))
    if st.cue_enabled then
      push_pill_active(ctx_r)
    else
      R.ImGui_PushStyleColor(ctx_r, R.ImGui_Col_Button(),        SC.PANEL)
      R.ImGui_PushStyleColor(ctx_r, R.ImGui_Col_ButtonHovered(), SC.HOVER_INACTIVE)
      R.ImGui_PushStyleColor(ctx_r, R.ImGui_Col_ButtonActive(),  SC.PANEL)
      R.ImGui_PushStyleColor(ctx_r, R.ImGui_Col_Text(),          SC.TEXT_OFF)
    end
    if R.ImGui_Button(ctx_r, "CUE DETECT##cue_on", CUE_BTN_W, BTN_H) then
      st.cue_enabled = not st.cue_enabled
      save_setting("cue_enabled", st.cue_enabled and 1 or 0)
    end
    R.ImGui_PopStyleColor(ctx_r, 4)
    R.ImGui_EndGroup(ctx_r)
    R.ImGui_SetCursorPos(ctx_r, row_x + COL_W + COL_GAP, row_y)
    R.ImGui_BeginGroup(ctx_r)
    if not st.cue_enabled then R.ImGui_BeginDisabled(ctx_r) end
    persisted_slider(ctx_r, st, "cue_silence_db", COL_W)
    if not st.cue_enabled then R.ImGui_EndDisabled(ctx_r) end
    R.ImGui_EndGroup(ctx_r)

    -- Row: Sensitivity  |  Min spacing (two-column sliders, disabled
    -- together when cue detection is off).
    R.ImGui_Dummy(ctx_r, 0, 4)
    row_x, row_y = R.ImGui_GetCursorPos(ctx_r)
    if not st.cue_enabled then R.ImGui_BeginDisabled(ctx_r) end
    R.ImGui_BeginGroup(ctx_r)
    persisted_slider(ctx_r, st, "cue_sensitivity", COL_W)
    R.ImGui_EndGroup(ctx_r)
    R.ImGui_SetCursorPos(ctx_r, row_x + COL_W + COL_GAP, row_y)
    R.ImGui_BeginGroup(ctx_r)
    persisted_slider(ctx_r, st, "cue_spacing_ms", COL_W)
    R.ImGui_EndGroup(ctx_r)
    if not st.cue_enabled then R.ImGui_EndDisabled(ctx_r) end

    -- Row: Spectrogram gain | Noise floor. Shown regardless of view_mode
    -- so the user can tune while on WAVEFORM too, then flip back.
    R.ImGui_Dummy(ctx_r, 0, 4)
    R.ImGui_Separator(ctx_r)
    R.ImGui_Dummy(ctx_r, 0, 2)
    row_x, row_y = R.ImGui_GetCursorPos(ctx_r)
    R.ImGui_BeginGroup(ctx_r)
    persisted_slider(ctx_r, st, "spec_gain_db", COL_W)
    R.ImGui_EndGroup(ctx_r)
    R.ImGui_SetCursorPos(ctx_r, row_x + COL_W + COL_GAP, row_y)
    R.ImGui_BeginGroup(ctx_r)
    persisted_slider(ctx_r, st, "spec_thresh_permille", COL_W)
    R.ImGui_EndGroup(ctx_r)

    -- Right-click slider popup for manual value entry. One-shot:
    -- OpenPopup fires exactly once per right-click request (mirrors
    -- Alloy's pattern so cross-script muscle memory carries over).
    if st._input_popup_request then
      st._input_popup = st._input_popup_request
      st._input_popup_request = nil
      R.ImGui_OpenPopup(ctx_r, "##slider_input_popup")
      st._input_popup_opening = true
    end
    R.ImGui_PushStyleColor(ctx_r, R.ImGui_Col_FrameBg(),        SC.WINDOW)
    R.ImGui_PushStyleColor(ctx_r, R.ImGui_Col_FrameBgHovered(), SC.PANEL_HIGH)
    R.ImGui_PushStyleColor(ctx_r, R.ImGui_Col_FrameBgActive(),  SC.PANEL)
    R.ImGui_PushStyleColor(ctx_r, R.ImGui_Col_TextSelectedBg(), 0x26A69A66)
    R.ImGui_PushStyleColor(ctx_r, R.ImGui_Col_Text(),           SC.TEXT_ON)
    if R.ImGui_BeginPopup(ctx_r, "##slider_input_popup") then
      R.ImGui_SetNextItemWidth(ctx_r, 80)
      if st._input_popup_opening then
        R.ImGui_SetKeyboardFocusHere(ctx_r)
        st._input_popup_opening = nil
      end
      local inp_changed, inp_val = R.ImGui_InputInt(ctx_r, "##popup_input",
        st._input_popup_val, 0, 0)
      if inp_changed then st._input_popup_val = inp_val end
      if R.ImGui_IsKeyPressed(ctx_r, R.ImGui_Key_Enter())
         or R.ImGui_IsKeyPressed(ctx_r, R.ImGui_Key_KeypadEnter()) then
        local v = math.floor(st._input_popup_val + 0.5)
        local cfg = SLIDER_CONFIGS[st._input_popup]
        if cfg then
          v = clamp(v, cfg.min, cfg.max)
          cfg.apply(st, v)
        end
        st._input_popup = nil
        R.ImGui_CloseCurrentPopup(ctx_r)
      end
      if R.ImGui_IsKeyPressed(ctx_r, R.ImGui_Key_Escape()) then
        st._input_popup = nil
        R.ImGui_CloseCurrentPopup(ctx_r)
      end
      R.ImGui_EndPopup(ctx_r)
    else
      st._input_popup = nil
    end
    R.ImGui_PopStyleColor(ctx_r, 5)

    R.ImGui_EndPopup(ctx_r)
  end

  local function render_title_bar(ctx_r, st, lic_mod, lic_status)
    local w = R.ImGui_GetWindowWidth(ctx_r)
    local font_b = temper_theme and temper_theme.font_bold

    -- No background: header elements overlay the waveform directly.
    -- Window moves are handled by ImGui native drag on empty header space
    -- (waveform InvisibleButton is clipped below the header so clicks in the
    -- header zone fall through to ImGui for native drag + REAPER dock support).

    -- Title text (non-capturing; native drag passes through)
    if font_b then R.ImGui_PushFont(ctx_r, font_b, 13) end
    R.ImGui_SetCursorPos(ctx_r, 8, 5)
    R.ImGui_PushStyleColor(ctx_r, R.ImGui_Col_Text(), SC.PRIMARY)
    R.ImGui_Text(ctx_r, "TEMPER - RECALL")
    R.ImGui_PopStyleColor(ctx_r, 1)

    -- Center-aligned buttons (all icon buttons, same width)
    local total_btns_w = CONFIG.btn_w * 2 + CONFIG.btn_gap
    local center_x = (w - total_btns_w) * 0.5
    R.ImGui_SetCursorPos(ctx_r, center_x, 2)

    -- Capture/Pause toggle: pause icon on teal when live, record icon on coral when paused
    local cap_bg, cap_hov, cap_act
    if st.capturing then
      cap_bg, cap_hov, cap_act = SC.PRIMARY_AC, SC.PRIMARY_HV, SC.PRIMARY
    else
      cap_bg, cap_hov, cap_act = SC.TERTIARY, SC.TERTIARY_HV, SC.TERTIARY_AC
    end
    local cap_icon_fn = st.capturing and draw_icon_pause or draw_icon_play
    if icon_button(ctx_r, "##cap", cap_icon_fn, 0x000000FF,
                   CONFIG.btn_w, 22, cap_bg, cap_hov, cap_act) then
      st.capturing = not st.capturing
      gm_write(GM.PAUSE, st.capturing and 0 or 1)
    end
    if R.ImGui_IsItemHovered(ctx_r) then
      R.ImGui_SetTooltip(ctx_r, st.capturing and "Pause capture" or "Resume capture")
    end

    -- PRINT: bounce last N seconds to edit cursor on selected track (teal down-arrow icon)
    R.ImGui_SameLine(ctx_r, 0, CONFIG.btn_gap)
    if icon_button(ctx_r, "##print", draw_icon_print, SC.PRIMARY,
                   CONFIG.btn_w, 22, SC.PANEL_TOP, SC.HOVER_LIST, SC.ACTIVE_DARK) then
      local sel_track = R.GetSelectedTrack(0, 0)
      if sel_track then
        local track_idx = R.CSurf_TrackToID(sel_track, false) - 1
        st._export_queue = st._export_queue or {}
        st._export_queue[#st._export_queue + 1] = {
          kind      = "print",
          pos       = R.GetCursorPosition(),
          duration  = st.quick_dur,
          track_idx = track_idx,
        }
      end
    end
    if R.ImGui_IsItemHovered(ctx_r) then
      R.ImGui_SetTooltip(ctx_r,
        string.format("Print last %ds to cursor on selected track", st.quick_dur))
    end

    -- Status pills (right-aligned)
    local status_text = st.capturing and "LIVE" or "PAUSED"
    local status_col  = st.capturing and SC.PRIMARY or SC.TERTIARY
    local sel_text = ""
    local n = #st.selections
    if n > 1 then
      sel_text = string.format("Sel:%dx  ", n)
    elseif n == 1 and st.selections[1][2] > 0 then
      sel_text = string.format("Sel:%.1fs  ", st.selections[1][2] * st.buf_dur)
    end
    -- Live capture nch from JSFX broadcast (gmem[11]). Fall back to last
    -- known value if read returns 0 -- happens for one frame after a
    -- proto-bump reinstall before @block has run.
    local cap_nch = math.floor(gm_read(GM.CAP_NCH))
    if cap_nch >= 1 then st.cap_nch = cap_nch end
    local eff_nch = math.floor(gm_read(GM.EFFECTIVE_NCH))
    if eff_nch >= 1 then st.effective_nch = eff_nch end
    -- Routing gap: compare actual downstream gates against master I_NCHAN.
    -- Probed once per frame here and reused by settings_popup. effective_nch
    -- is intentionally NOT used: it decays on silence and would cry wolf
    -- on every pause. Monitor FX per-FX Track Channels is not readable.
    local routing = probe_routing()
    local ch_label
    if st.force_mono then
      ch_label = "Mono"
    elseif routing.routing_gap then
      ch_label = string.format("%dch(!)", st.cap_nch)
    else
      ch_label = string.format("%dch", st.cap_nch)
    end
    local pill = string.format("%s | %ds | %s%s", ch_label, st.buf_dur, sel_text, status_text)
    local tw = R.ImGui_CalcTextSize(ctx_r, pill)
    R.ImGui_SetCursorPos(ctx_r, w - tw - 36, 5)
    R.ImGui_PushStyleColor(ctx_r, R.ImGui_Col_Text(), SC.TEXT_MUTED)
    R.ImGui_Text(ctx_r, string.format("%s | %ds | %s", ch_label, st.buf_dur, sel_text))
    R.ImGui_PopStyleColor(ctx_r, 1)
    R.ImGui_SameLine(ctx_r)
    R.ImGui_PushStyleColor(ctx_r, R.ImGui_Col_Text(), status_col)
    R.ImGui_Text(ctx_r, status_text)
    R.ImGui_PopStyleColor(ctx_r, 1)

    -- Gear icon: pure floating glyph, no button chrome in any state.
    -- DrawList geometry (not U+2699) so the OS can't substitute a
    -- colour emoji under fallback fonts (LD-2026-04-017 pattern).
    R.ImGui_SetCursorPos(ctx_r, w - 30, 2)
    if icon_button(ctx_r, "##gear", draw_icon_gear, SC.PRIMARY,
                   22, 22, 0x00000000, 0x00000000, 0x00000000) then
      R.ImGui_OpenPopup(ctx_r, "##settings_recall")
    end
    if R.ImGui_IsItemHovered(ctx_r) then
      R.ImGui_SetTooltip(ctx_r, "Settings")
    end

    settings_popup(ctx_r, st, lic_mod, lic_status, routing)

    if font_b then R.ImGui_PopFont(ctx_r) end
  end

  local function render_waveform(ctx_r, st)
    local w = R.ImGui_GetContentRegionAvail(ctx_r)
    local win_w = R.ImGui_GetWindowWidth(ctx_r)
    local win_h = R.ImGui_GetWindowHeight(ctx_r)
    local disp_y = 2  -- waveform fills full window; header elements overlay on top
    local disp_h = win_h - disp_y - 2  -- 2px top + 2px bottom
    local disp_w = math.floor(win_w - 4)  -- 2px left + 2px right
    -- Minimum height leaves a positive InvisibleButton area after the header
    -- clip (title_h) below, so collapsing the docked frame to near-zero
    -- height doesn't feed a zero size to ImGui_InvisibleButton.
    if disp_w < 10 or disp_h < CONFIG.title_h + 10 then
      st._disp_x = nil
      return
    end

    -- Peak ring is fixed at DISP_RES; we resample to disp_w below with
    -- max-pool. No gmem write from Lua; JSFX ignores gmem[8].
    local initialized = gm_read(GM.INITIALIZED)
    local write_head  = gm_read(GM.WRITE_HEAD)
    local disp_offset = gm_read(GM.DISP_BUF_OFFSET)
    if initialized ~= 1 or disp_offset < 1 then
      R.ImGui_SetCursorPos(ctx_r, 4, disp_y + disp_h / 2 - 7)
      R.ImGui_TextColored(ctx_r, SC.TEXT_MUTED, "  Waiting for capture engine...")
      return
    end

    -- Draw waveform via DrawList
    local dl = R.ImGui_GetWindowDrawList(ctx_r)
    local wx, wy = R.ImGui_GetWindowPos(ctx_r)
    local dx = wx + 2
    local dy = wy + disp_y
    local cy = dy + disp_h * 0.5

    -- Background
    R.ImGui_DrawList_AddRectFilled(dl, dx, dy, dx + disp_w, dy + disp_h, SC.WINDOW, 4)

    -- Waveform peaks. Orientation: pixel 0 = oldest, pixel disp_w-1 = newest.
    -- For each screen pixel, max-pool across the source slots it covers to
    -- kill per-frame alignment jitter. `ws` is shifted back by one slot so
    -- the rightmost pixel reads the last COMPLETED slot, not the in-progress
    -- one (JSFX zeros each slot on entry and accumulates peaks over ~29ms,
    -- so the in-progress slot flickers). ~29ms display latency; imperceptible.
    local ws = math.floor(write_head * DISP_RES) - 1
    if ws < 0 then ws = ws + DISP_RES end
    for i = 0, disp_w - 1 do
      local age_hi = math.floor((disp_w - 1 - i)     * DISP_RES / disp_w)
      local age_lo = math.floor((disp_w     - i)     * DISP_RES / disp_w) - 1
      if age_lo < age_hi then age_lo = age_hi end

      local peak = 0
      for age = age_hi, age_lo do
        local src = (ws - age) % DISP_RES
        if src < 0 then src = src + DISP_RES end
        local v = math.abs(gm_read(disp_offset + src))
        if v > peak then peak = v end
      end
      if peak > 1.0 then peak = 1.0 end

      local h = math.floor(peak * disp_h * 0.45)
      if h > 0 then
        local x = dx + i
        R.ImGui_DrawList_AddLine(dl, x, cy - h, x, cy + h, CONFIG.waveform_col, 1.0)
      end
    end

    -- Store display geometry for selection interaction + overlay pass.
    st._disp_x = dx
    st._disp_y = dy
    st._disp_w = disp_w
    st._disp_h = disp_h
    st._write_head = write_head
  end

  -- Spectral color LUT, built once from the current palette. norm in [0,1]
  -- rounds to one of LUT_N-1 buckets. Hot path stays a single table lookup.
  local LUT_N = 64
  local spec_lut = nil
  local function lerp_rgba(a, b, t)
    local ar = (a >> 24) & 0xFF
    local ag = (a >> 16) & 0xFF
    local ab = (a >> 8)  & 0xFF
    local aa = a & 0xFF
    local br = (b >> 24) & 0xFF
    local bg = (b >> 16) & 0xFF
    local bb = (b >> 8)  & 0xFF
    local ba = b & 0xFF
    local r  = math.floor(ar + (br - ar) * t + 0.5)
    local g  = math.floor(ag + (bg - ag) * t + 0.5)
    local bl = math.floor(ab + (bb - ab) * t + 0.5)
    local al = math.floor(aa + (ba - aa) * t + 0.5)
    return (r << 24) | (g << 16) | (bl << 8) | al
  end
  local function build_spec_lut()
    -- Roseus 9-stop ramp -- reproduces Audacity 3.4+'s 256-entry
    -- perceptually-uniform CAM16-UCS LUT to ~1% via linear interpolation.
    -- Source: dofuuz/roseus, baked into Audacity via AColor::GetColorGradient.
    -- JSFX normalises to [0,1] linearly in dB (no curve), so perceptual
    -- smoothness comes entirely from this LUT being monotone-luminance.
    -- Intentionally off-brand for v0.5.0; brand-adjacent perceptually-uniform
    -- palette is a tracked follow-up once the math is visually confirmed.
    local stops = {
      {0.000, 0x010101FF},  -- near-black
      {0.125, 0x023B76FF},  -- deep indigo
      {0.250, 0x41248DFF},  -- violet
      {0.375, 0xA6189AFF},  -- magenta
      {0.500, 0x92159EFF},  -- purple-pink
      {0.625, 0xF8B05EFF},  -- warm orange
      {0.750, 0xECDAA5FF},  -- pale gold
      {0.875, 0xF7F7F0FF},  -- cream
      {1.000, 0xFFFAF9FF},  -- off-white
    }
    spec_lut = {}
    for i = 0, LUT_N - 1 do
      local norm = i / (LUT_N - 1)
      local s = 1
      while s < #stops - 1 and norm > stops[s + 1][1] do
        s = s + 1
      end
      local t0, c1 = stops[s][1], stops[s][2]
      local t1, c2 = stops[s + 1][1], stops[s + 1][2]
      local t = (norm - t0) / (t1 - t0)
      spec_lut[i] = lerp_rgba(c1, c2, t)
    end
  end

  local function render_spectrogram(ctx_r, st)
    local win_w = R.ImGui_GetWindowWidth(ctx_r)
    local win_h = R.ImGui_GetWindowHeight(ctx_r)
    local disp_y = 2
    local disp_h = win_h - disp_y - 2
    local disp_w = math.floor(win_w - 4)
    if disp_w < 10 or disp_h < CONFIG.title_h + 10 then
      st._disp_x = nil
      return
    end

    local initialized = gm_read(GM.INITIALIZED)
    local write_head  = gm_read(GM.WRITE_HEAD)
    local disp_offset = gm_read(GM.DISP_BUF_OFFSET)
    if initialized ~= 1 or disp_offset < 1 then
      R.ImGui_SetCursorPos(ctx_r, 4, disp_y + disp_h / 2 - 7)
      R.ImGui_TextColored(ctx_r, SC.TEXT_MUTED, "  Waiting for capture engine...")
      return
    end

    if spec_lut == nil then build_spec_lut() end

    local spec_offset = disp_offset + DISP_RES
    local dl = R.ImGui_GetWindowDrawList(ctx_r)
    local wx, wy = R.ImGui_GetWindowPos(ctx_r)
    local dx = wx + 2
    local dy = wy + disp_y

    R.ImGui_DrawList_AddRectFilled(dl, dx, dy, dx + disp_w, dy + disp_h, SC.WINDOW, 4)

    local ws = math.floor(write_head * DISP_RES) - 1
    if ws < 0 then ws = ws + DISP_RES end

    -- Low bins at the bottom, high bins at the top (audio convention).
    local cell_h = disp_h / BINS
    local lut_max = LUT_N - 1

    -- Temporal decay cache. Persists per src-slot across frames so a bin
    -- fades smoothly instead of strobing when the JSFX overwrites it with
    -- a quieter magnitude. Keyed on src (DISP_RES slots) so it follows the
    -- ring naturally. Reset on view-mode switch via reset_spec_decay().
    if st._spec_decay == nil then st._spec_decay = {} end
    local cache = st._spec_decay
    local decay = 0.85

    for i = 0, disp_w - 1 do
      local age = math.floor((disp_w - 1 - i) * DISP_RES / disp_w)
      local src = (ws - age) % DISP_RES
      if src < 0 then src = src + DISP_RES end
      local col_base = spec_offset + src * BINS

      local col_row = cache[src]
      if col_row == nil then
        col_row = {}
        cache[src] = col_row
      end

      local col_x = dx + i
      for b = 0, BINS - 1 do
        local fresh = gm_read(col_base + b)
        local prev  = col_row[b] or 0
        local decayed = prev * decay
        local norm = (fresh > decayed) and fresh or decayed
        col_row[b] = norm
        -- Threshold is a DrawList perf optimisation -- the JSFX math
        -- already puts silent input at norm=0 (Audacity recipe: -160 dB
        -- zero-power sentinel + clamp at the -100 dB window floor), so
        -- this only skips denormal-adjacent fully-black cells.
        if norm > st._spec_threshold then
          if norm > 1.0 then norm = 1.0 end
          local lut_idx = math.floor(norm * lut_max + 0.5)
          local y_hi = dy + disp_h - (b + 1) * cell_h
          local y_lo = dy + disp_h - b * cell_h
          R.ImGui_DrawList_AddRectFilled(dl, col_x, y_hi, col_x + 1, y_lo,
            spec_lut[lut_idx], 0)
        end
      end
    end

    st._disp_x = dx
    st._disp_y = dy
    st._disp_w = disp_w
    st._disp_h = disp_h
    st._write_head = write_head
  end

  -- Accumulate s[3] each frame using the delta of write_head since the
  -- previous frame. Skips the active selection while dragging so the
  -- drag-update's explicit refresh is authoritative. Called from
  -- render_gui between render_waveform (which sets _write_head) and
  -- handle_waveform_interaction.
  local function update_selection_ages(st)
    local wh = st._write_head or 0
    if st._prev_wh == nil then
      st._prev_wh = wh
      return
    end
    local dt = (wh - st._prev_wh) % 1.0
    local active = st._active_idx
    for j, s in ipairs(st.selections) do
      if not (st.sel_dragging and j == active) then
        s[3] = (s[3] or (wh - s[1]) % 1.0) + dt
      end
    end
    st._prev_wh = wh
  end

  -- Remove selections whose audio has been fully overwritten. cum_age
  -- (s[3]) reaching 1 + width means the newer edge has also crossed
  -- the buffer horizon.
  local function prune_aged_selections(st)
    for i = #st.selections, 1, -1 do
      local s = st.selections[i]
      if s[2] > 0 and (s[3] or 0) >= 1.0 + s[2] then
        remove_selection_at(st, i)
      end
    end
  end

  -- Cue detection. Walk the DISP_RES peak ring in chronological order,
  -- build a linear envelope array, and feed it through the flux-based
  -- onset detector in temper_mark_analysis.lua (same pipeline as Temper
  -- Mark). Output is stored as a list of { norm } entries in st.cues.
  --
  -- Fresh detection each frame, no persistent cue state: when the write
  -- head sweeps past an old cue's position, that slot gets overwritten
  -- and re-detection naturally stops emitting it. Cost: one gmem read
  -- per slot + the 7-stage pipeline = ~2048 float ops/frame, negligible.
  local function detect_cues(st)
    st.cues = {}
    if not st.cue_enabled then return end
    local initialized = gm_read(GM.INITIALIZED)
    local disp_offset = gm_read(GM.DISP_BUF_OFFSET)
    if initialized ~= 1 or disp_offset < 1 then return end

    -- Match render_waveform's `-1`: the JSFX is still accumulating peaks
    -- into the slot at floor(wh * DISP_RES); use the last completed slot
    -- as "newest" so cue ticks land on the same pixel as the transient
    -- drawn in the waveform.
    local wh = st._write_head or 0
    local ws = math.floor(wh * DISP_RES) - 1
    if ws < 0 then ws = ws + DISP_RES end

    -- Build chronologically-ordered envelope: env[1] = oldest (slot ws+1),
    -- env[DISP_RES] = newest (slot ws).
    local env = {}
    for k = 1, DISP_RES do
      local slot = (ws + k) % DISP_RES
      env[k] = math.abs(gm_read(disp_offset + slot))
    end

    local hop_sec = st.buf_dur / DISP_RES
    local params = {
      silence_db  = st.cue_silence_db,
      sensitivity = st.cue_sensitivity,
      spacing_ms  = st.cue_spacing_ms,
    }
    local onsets = mark_analysis.detect_onsets_from_envelope(env, hop_sec, params)

    -- Convert chronological indices back to ring slot -> normalized position.
    -- Cap at cue_max so a noisy signal can't flood the overlay.
    local limit = math.min(#onsets, CONFIG.cue_max)
    for i = 1, limit do
      local k = onsets[i]
      local slot = (ws + k) % DISP_RES
      st.cues[#st.cues + 1] = { norm = slot / DISP_RES }
    end
  end

  -- Thin vertical ticks between the waveform and the selection overlay.
  -- Uses the same age-based orientation as render_selection_overlay so
  -- ticks stay locked to the audio that triggered them.
  local function render_cue_overlay(ctx_r, st)
    if not st._disp_x then return end
    if not st.cues or #st.cues == 0 then return end
    local dx, dy         = st._disp_x, st._disp_y
    local disp_w, disp_h = st._disp_w, st._disp_h
    local wh             = st._write_head or 0
    local dl             = R.ImGui_GetWindowDrawList(ctx_r)
    local y0             = dy + 1
    local y1             = dy + disp_h - 1

    for _, cue in ipairs(st.cues) do
      local age = (wh - cue.norm) % 1.0
      if age >= 0 and age < 1.0 then
        local px = dx + disp_w - math.floor(age * disp_w + 0.5)
        if px >= dx and px <= dx + disp_w then
          R.ImGui_DrawList_AddLine(dl, px, y0, px, y1, CONFIG.cue_col, 1.0)
        end
      end
    end
  end

  -- Drawn AFTER handle_waveform_interaction so the overlay reflects the
  -- selection values just written this frame -- not the prior frame's.
  --
  -- Orientation matches render_waveform: age 0 (at write head) -> right
  -- edge, age 1 (one buffer old) -> left edge. No modulo wrap -- partial
  -- selections clip at the left edge; fully-aged ones are removed by
  -- prune_aged_selections before this runs.
  local function render_selection_overlay(ctx_r, st)
    if not st._disp_x then return end
    local dx, dy         = st._disp_x, st._disp_y
    local disp_w, disp_h = st._disp_w, st._disp_h
    local write_head     = st._write_head or 0

    local dl = R.ImGui_GetWindowDrawList(ctx_r)

    local function age_to_px(age)
      return dx + disp_w - math.floor(age * disp_w + 0.5)
    end

    local hov_idx = nil
    if not R.ImGui_IsMouseDown(ctx_r, 0) then
      local hmx, hmy = R.ImGui_GetMousePos(ctx_r)
      if hmx >= dx and hmx <= dx + disp_w and hmy >= dy and hmy <= dy + disp_h then
        hov_idx = hit_test_selection(st, hmx, dx, disp_w, write_head)
      end
    end

    for i, s in ipairs(st.selections) do
      if s[2] > 0 then
        -- Cumulative age of the older edge; falls back to initial relative
        -- age if s[3] hasn't been set yet this frame.
        local cum = s[3] or ((write_head - s[1]) % 1.0)
        -- Clip start to buffer horizon (age 1.0 -> left edge).
        local draw_start_age = cum
        if draw_start_age > 1.0 then draw_start_age = 1.0 end
        local draw_end_age = cum - s[2]
        if draw_end_age < 0 then draw_end_age = 0 end
        if draw_start_age > draw_end_age then
          local sel_px_start = age_to_px(draw_start_age)
          local sel_px_end   = age_to_px(draw_end_age)
          if sel_px_end > sel_px_start then
            local thickness = (i == hov_idx) and 2.0 or 1.0
            R.ImGui_DrawList_AddRectFilled(dl, sel_px_start, dy + 1,
              sel_px_end, dy + disp_h - 1, CONFIG.sel_col, 2)
            R.ImGui_DrawList_AddRect(dl, sel_px_start, dy + 1,
              sel_px_end, dy + disp_h - 1, CONFIG.sel_border, 2, 0, thickness)
          end
        end
      end
    end
  end

  local function handle_waveform_interaction(ctx_r, st)
    if not st._disp_x then return end
    local dx, dy, dw, dh = st._disp_x, st._disp_y, st._disp_w, st._disp_h
    local wh = st._write_head or 0

    -- Invisible button over the waveform area, but clipped BELOW the header.
    -- Clicks in the header zone fall through to ImGui so native window drag
    -- (and REAPER docking) engages on empty header space.
    local hdr_clip = CONFIG.title_h - 2  -- title_h above dy; dy is already +2 from window top
    local btn_y = dy + hdr_clip
    if dw <= 0 or dh - hdr_clip <= 0 then return end
    local btn_h = dh - hdr_clip
    R.ImGui_SetCursorScreenPos(ctx_r, dx, btn_y)
    R.ImGui_InvisibleButton(ctx_r, "##waveform_area", dw, btn_h)

    local hovered = R.ImGui_IsItemHovered(ctx_r)
    local mx, my  = R.ImGui_GetMousePos(ctx_r)

    -- Convert pixel x to normalized buffer position. Must mirror
    -- px_to_norm_s above -- same age-based orientation as the render.
    local function px_to_norm(px_x)
      local i = px_x - dx
      if i < 0 then i = 0 end
      if i > dw - 1 then i = dw - 1 end
      local age = (dw - 1 - i) / dw
      return (wh - age) % 1.0
    end

    -- Modifier-aware click dispatch.
    -- Double-click: auto-select between nearest cues to either side of
    --   the click point (in age-space). Plain DC replaces, Ctrl+DC adds.
    -- Shift+click: remove selection under cursor.
    -- Ctrl+click: additive selection drag.
    -- Plain click on an existing selection: arm drag-export on the hit one.
    --   (handle_drag_export must only run for mouse-downs landing on a
    --   selection -- otherwise a native window-drag on the header fires
    --   SetEditCurPos / SetOnlyTrackSelected every frame.)
    -- Plain click on empty: replace-all + new selection drag.
    if hovered and R.ImGui_IsMouseClicked(ctx_r, 0) then
      local mods  = R.ImGui_GetKeyMods(ctx_r)
      local ctrl  = (mods & R.ImGui_Mod_Ctrl())  ~= 0
      local shift = (mods & R.ImGui_Mod_Shift()) ~= 0
      local is_dc = R.ImGui_IsMouseDoubleClicked(ctx_r, 0)
      local hit_idx = hit_test_selection(st, mx, dx, dw, wh)

      if is_dc and not shift and st.cues and #st.cues > 0 then
        -- Age-space neighbor search. Cue with age > click_age is "older"
        -- (left of click on screen); cue with age < click_age is "newer"
        -- (right of click). Fall back to buffer edges (age 1 / age 0)
        -- if no neighbor exists on one side.
        local click_norm = px_to_norm_s(mx, dx, dw, wh)
        local click_age  = (wh - click_norm) % 1.0
        local left_age, right_age = 1.0, 0.0
        for _, cue in ipairs(st.cues) do
          local ca = (wh - cue.norm) % 1.0
          if ca > click_age and ca < left_age  then left_age  = ca end
          if ca < click_age and ca > right_age then right_age = ca end
        end
        local width = left_age - right_age
        if width > 0 then
          local start_norm = (wh - left_age) % 1.0
          if ctrl then
            add_selection(st, start_norm, width)
          else
            set_active_sel(st, start_norm, width)
          end
          st.sel_dragging      = false
          st._click_norm       = nil
          st.drag_export       = false
          st._drag_export_armed = false
        end
      elseif shift then
        if hit_idx then remove_selection_at(st, hit_idx) end
      elseif ctrl then
        if hit_idx then
          -- Ctrl+Click on an existing selection: don't spawn a zero-width
          -- ghost on top of it. Arm drag-export on the hit selection.
          st._active_idx = hit_idx
          st._drag_export_armed = true
        else
          st.sel_dragging = true
          st._click_norm = px_to_norm_s(mx, dx, dw, wh)
          add_selection(st, st._click_norm, 0)
          st.drag_export = false
          st._drag_export_armed = false
        end
      elseif hit_idx then
        st._active_idx = hit_idx
        st._drag_export_armed = true
      else
        st.sel_dragging = true
        st._click_norm = px_to_norm_s(mx, dx, dw, wh)
        set_active_sel(st, st._click_norm, 0)
        st.drag_export = false
        st._drag_export_armed = false
      end
    end

    -- Drag update. Selection anchors to AUDIO, not to screen pixels.
    -- click_norm is locked at click-time; the other endpoint tracks the
    -- current mouse pixel resolved against the current write-head. The
    -- older of the two endpoints (larger age-from-write-head) becomes the
    -- left visual edge; width is their ring-distance.
    if st.sel_dragging and R.ImGui_IsMouseDown(ctx_r, 0) and st._click_norm then
      local cur_px = math.max(0, math.min(mx - dx, dw))
      local end_norm = px_to_norm(dx + cur_px)
      local click_norm = st._click_norm
      local click_age = (wh - click_norm) % 1.0
      local end_age   = (wh - end_norm)   % 1.0

      -- Clamp end_age against sibling selections so dragging cannot enter
      -- overlap. Age space is monotonic within the buffer, so this is a
      -- plain interval-on-line problem.
      local active_idx = st._active_idx
      for j, sib in ipairs(st.selections) do
        if j ~= active_idx and sib[2] > 0 then
          local sib_start_age = (wh - sib[1])             % 1.0
          local sib_end_age   = (wh - (sib[1] + sib[2])) % 1.0
          if sib_start_age >= sib_end_age then
            if end_age > click_age then
              -- Dragging toward older: clamp at sibling's younger edge.
              if sib_end_age > click_age and sib_end_age < end_age then
                end_age = sib_end_age
              end
            elseif end_age < click_age then
              -- Dragging toward newer: clamp at sibling's older edge.
              if sib_start_age < click_age and sib_start_age > end_age then
                end_age = sib_start_age
              end
            end
          end
        end
      end
      end_norm = (wh - end_age) % 1.0

      local sel = active_sel(st)
      if click_age >= end_age then
        sel[1] = click_norm
        sel[2] = (end_norm - click_norm) % 1.0
      else
        sel[1] = end_norm
        sel[2] = (click_norm - end_norm) % 1.0
      end
      -- Keep cum_age in sync with the moving start endpoint during drag.
      -- update_selection_ages skips the active selection while dragging;
      -- this line is the authoritative source for its s[3].
      sel[3] = (wh - sel[1]) % 1.0
    end

    -- End selection drag. Discard a tiny (< 3px) newly-created selection.
    -- Remove only the active index so sibling selections added via Ctrl+Click
    -- survive an accidental no-drag click.
    if st.sel_dragging and R.ImGui_IsMouseReleased(ctx_r, 0) then
      st.sel_dragging = false
      local sel = active_sel(st)
      if sel and sel[2] * dw < 3 and st._active_idx then
        remove_selection_at(st, st._active_idx)
      end
      -- Clear the drag-anchor so stale click coordinates can't leak into
      -- the next frame's branches (the drag loop is the only reader; a
      -- stale value here is always wrong).
      st._click_norm = nil
    end

    if R.ImGui_IsWindowFocused(ctx_r)
       and R.ImGui_IsKeyPressed(ctx_r, R.ImGui_Key_Escape(), false) then
      clear_selections(st)
    end
  end

  local function handle_drag_export(ctx_r, st)
    -- Disarm on mouse release, regardless of whether export fired.
    if not R.ImGui_IsMouseDown(ctx_r, 0) and not st.drag_export then
      st._drag_export_armed = false
      st._drag_check_start = nil
    end

    local sel = active_sel(st)
    if not sel or sel[2] <= 0 then return end
    if st.sel_dragging then return end  -- still defining selection
    if not st._drag_export_armed and not st.drag_export then return end

    -- Detect drag initiation: armed + mouse moved > 5px
    if not st.drag_export then
      if R.ImGui_IsMouseDown(ctx_r, 0) then
        local mx, my = R.ImGui_GetMousePos(ctx_r)
        if not st._drag_check_start then
          st._drag_check_start = {mx, my}
        else
          local ox, oy = st._drag_check_start[1], st._drag_check_start[2]
          local dist = math.sqrt((mx - ox)^2 + (my - oy)^2)
          if dist > 5 then
            st.drag_export = true
            st._drag_check_start = nil
          end
        end
      end
    end

    -- During drag export: track mouse globally
    if st.drag_export then
      local mmx, mmy = R.GetMousePosition()
      local window, segment = R.BR_GetMouseCursorContext()

      if window == "arrange" then
        -- Highlight target position and track
        local pos = R.BR_GetMouseCursorContext_Position()
        pos = R.SnapToGrid(0, pos)
        R.SetEditCurPos(pos, false, false)

        local tr = R.GetTrackFromPoint(mmx, mmy)
        if tr then R.SetOnlyTrackSelected(tr) end
      end

      -- Mouse released: execute export
      if not R.ImGui_IsMouseDown(ctx_r, 0) then
        st.drag_export = false
        st._drag_export_armed = false

        if window == "arrange" then
          local pos = R.BR_GetMouseCursorContext_Position()
          pos = R.SnapToGrid(0, pos)

          local tr = R.GetTrackFromPoint(mmx, mmy)
          if tr then
            local track_idx = R.CSurf_TrackToID(tr, false) - 1
            enqueue_exports(st, pos, track_idx)
          end
        end
      end
    end
  end

  local function render_gui(ctx_r, st, lic_mod, lic_status)
    if st.view_mode == "spectral" then
      render_spectrogram(ctx_r, st)
    else
      render_waveform(ctx_r, st)
    end
    detect_cues(st)
    update_selection_ages(st)
    handle_waveform_interaction(ctx_r, st)
    prune_aged_selections(st)
    render_cue_overlay(ctx_r, st)
    render_selection_overlay(ctx_r, st)
    render_title_bar(ctx_r, st, lic_mod, lic_status)
    handle_drag_export(ctx_r, st)
  end

  -- Window flags
  local win_flags = R.ImGui_WindowFlags_NoCollapse()
                  | R.ImGui_WindowFlags_NoTitleBar()
                  | R.ImGui_WindowFlags_NoScrollbar()
                  | R.ImGui_WindowFlags_NoScrollWithMouse()

  -- Action handlers: every command listed in actions/manifest.toml must
  -- have a matching entry here (manifest-handler sync test enforces).
  -- Each handler mirrors behaviour the user can reach through the GUI,
  -- so keyboard / macro invocations have identical effect.
  local HANDLERS = {
    close = function() state.should_close = true end,
    toggle_capture = function()
      state.capturing = not state.capturing
      gm_write(GM.PAUSE, state.capturing and 0 or 1)
    end,
    print = function()
      local sel_track = R.GetSelectedTrack(0, 0)
      if sel_track then
        local track_idx = R.CSurf_TrackToID(sel_track, false) - 1
        state._export_queue = state._export_queue or {}
        state._export_queue[#state._export_queue + 1] = {
          kind      = "print",
          pos       = R.GetCursorPosition(),
          duration  = state.quick_dur,
          track_idx = track_idx,
        }
      end
    end,
    cycle_view = function()
      state.view_mode = (state.view_mode == "spectral") and "waveform" or "spectral"
      state._spec_decay = nil
      save_setting("view_mode", state.view_mode)
    end,
    toggle_force_mono = function()
      state.force_mono = not state.force_mono
      R.gmem_write(GM.FORCE_MONO, state.force_mono and 1 or 0)
      save_setting("force_mono", state.force_mono and 1 or 0)
    end,
    clear_selections = function() clear_selections(state) end,
    cycle_capture_channels = function()
      local order = { 2, 4, 6, 8, 12, 16 }
      local master = R.GetMasterTrack(0)
      local cur = math.floor(R.GetMediaTrackInfo_Value(master, "I_NCHAN"))
      local idx = 1
      for i, v in ipairs(order) do if v == cur then idx = i; break end end
      local next_nch = order[(idx % #order) + 1]
      if set_capture_channels(master, next_nch, jsfx_idx) then
        R.gmem_write(GM.SET_NCH, next_nch)
        clear_selections(state)
      end
    end,
    toggle_cue_detect = function()
      state.cue_enabled = not state.cue_enabled
      save_setting("cue_enabled", state.cue_enabled and 1 or 0)
    end,
  }

  -- Testing harness registration: exposes projected state via _harness_dump
  -- command when _TEMPER_HARNESS is set at launch.  Gated, so production
  -- runs skip all of this.  See tests/harness/README.md.
  if _TEMPER_HARNESS then
    local _tts_ok, _tts = pcall(dofile, _lib .. "temper_test_state.lua")
    if _tts_ok and type(_tts) == "table" and _tts.register and _tts.dump_to_file then
      _tts.register(_NS, function()
        -- Live JSFX read for LD-2026-04-020 decay check.  state.effective_nch
        -- has a `>= 1` guard so it never shows the silence-decay value; the
        -- raw gmem slot does.  Exposed as effective_nch_raw so scenarios
        -- observing JSFX-side decay can assert on it directly.
        local raw_eff = math.floor(gm_read(GM.EFFECTIVE_NCH))
        -- LD-2026-04-022 pin-matrix identity check.  After a cap_nch change
        -- every pin p < cap_nch must carry bitmask (1 << p) on both input
        -- and output; pins >= cap_nch must be zero.  A regressed
        -- implementation (FX-reinstall without SetPinMappings) leaves the
        -- old matrix and this boolean flips false.
        local pin_matrix_identity_ok = false
        if state.jsfx_ok and jsfx_idx then
          local _m = R.GetMasterTrack(0)
          local _n = state.cap_nch or 2
          pin_matrix_identity_ok = true
          for pin = 0, RECALL_MAX_PINS - 1 do
            local want = (pin < _n) and (1 << pin) or 0
            local imask = R.TrackFX_GetPinMappings(_m, jsfx_idx, 0, pin)
            local omask = R.TrackFX_GetPinMappings(_m, jsfx_idx, 1, pin)
            if imask ~= want or omask ~= want then
              pin_matrix_identity_ok = false
              break
            end
          end
        end
        -- LD-2026-04-025 routing-gate readback. Live re-probe so the
        -- assertion can't be fooled by stale per-frame snapshots.
        local _master_for_probe = R.GetMasterTrack(0)
        local hw_out_nch_live   = probe_hw_out_nch(_master_for_probe)
        local master_nch_live   = math.floor(
          R.GetMediaTrackInfo_Value(_master_for_probe, "I_NCHAN"))
        return {
          jsfx_ok                = state.jsfx_ok,
          capturing              = state.capturing,
          force_mono             = state.force_mono,
          cap_nch             = state.cap_nch,
          effective_nch       = state.effective_nch,
          effective_nch_raw      = raw_eff,
          pin_matrix_identity_ok = pin_matrix_identity_ok,
          last_export_nch        = state.last_export_nch,
          reinstall_count        = _reinstall_count,
          buf_dur             = state.buf_dur,
          quick_dur           = state.quick_dur,
          view_mode           = state.view_mode,
          cue_enabled         = state.cue_enabled,
          selections_count    = state.selections and #state.selections or 0,
          should_close        = state.should_close,
          hw_out_nch          = hw_out_nch_live,
          master_nch          = master_nch_live,
        }
      end)
      HANDLERS._harness_dump = function() _tts.dump_to_file() end
    end
  end

  rsg_actions.clear_pending_on_init(_NS)

  -- Defer loop
  local _first_loop = true
  local function loop()
    R.SetExtState(_NS, "instance_ts", tostring(R.time_precise()), false)
    rsg_actions.heartbeat(_NS)
    rsg_actions.poll(_NS, HANDLERS)
    -- Track master nchan changes mid-session. JSFX @block picks this up and
    -- rebuilds the ring buffer; prior capture is discarded (by design).
    -- Phase C (2026-04-19): on any I_NCHAN change -- including external
    -- changes from REAPER UI, project load, or anything outside the Recall
    -- cycle action -- force-resync FX pin mappings. Root cause of the
    -- post-Phase-B regression where pins reverted to stereo without a
    -- traceable user action. Idempotent; only 32 API calls per change.
    local _mt_loop = R.GetMasterTrack(0)
    local _cur_nchan = math.floor(R.GetMediaTrackInfo_Value(_mt_loop, "I_NCHAN"))
    if state._last_nchan_seen ~= _cur_nchan then
      if jsfx_idx then
        set_fx_pin_mappings(_mt_loop, jsfx_idx, _cur_nchan)
      end
      _diag("pin resync on I_NCHAN change -> %d", _cur_nchan)
      state._last_nchan_seen = _cur_nchan
    end
    R.gmem_write(GM.SET_NCH, _cur_nchan)
    pump_export_queue(state)

    if _first_loop then
      local sx = tonumber(R.GetExtState(_NS, "win_x"))
      local sy = tonumber(R.GetExtState(_NS, "win_y"))
      local sw = tonumber(R.GetExtState(_NS, "win_w"))
      local sh = tonumber(R.GetExtState(_NS, "win_h"))
      if sx and sy then
        R.ImGui_SetNextWindowPos(ctx, sx, sy, R.ImGui_Cond_Always())
      end
      if sw and sh then
        R.ImGui_SetNextWindowSize(ctx, sw, sh, R.ImGui_Cond_Always())
      else
        R.ImGui_SetNextWindowSize(ctx, 600, 180, R.ImGui_Cond_FirstUseEver())
      end
    end
    R.ImGui_SetNextWindowSizeConstraints(ctx, 300, 100, 9999, 9999)
    _first_loop = false

    local n_theme = temper_theme and temper_theme.push(ctx) or 0
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_WindowBg(), SC.PANEL)

    local visible, open = R.ImGui_Begin(ctx, "Temper Recall##trecall", true, win_flags)
    if visible then
      local wx, wy = R.ImGui_GetWindowPos(ctx)
      local ww, wh = R.ImGui_GetWindowSize(ctx)
      state._last_geom = {x = wx, y = wy, w = ww, h = wh}

      local lic_status = lic and lic.check("RECALL", ctx)
      if lic_status == "expired" then
        R.ImGui_TextColored(ctx, SC.ERROR_RED, "  Trial expired.")
        lic.open_dialog(ctx)
        lic.draw_dialog(ctx)
      else
        render_gui(ctx, state, lic, lic_status)
        if lic and lic.is_dialog_open() then lic.draw_dialog(ctx) end
      end
      R.ImGui_End(ctx)
    end

    if temper_theme then temper_theme.pop(ctx, n_theme) end
    R.ImGui_PopStyleColor(ctx, 1)

    if open and not state.should_close then
      R.defer(loop)
    else
      if state._last_geom then
        local g = state._last_geom
        save_setting("win_x", math.floor(g.x + 0.5))
        save_setting("win_y", math.floor(g.y + 0.5))
        save_setting("win_w", math.floor(g.w + 0.5))
        save_setting("win_h", math.floor(g.h + 0.5))
      end
      R.SetExtState(_NS, "instance_ts", "", false)
    end
  end

  if not _RSG_TEST_MODE then R.defer(loop) end
end
