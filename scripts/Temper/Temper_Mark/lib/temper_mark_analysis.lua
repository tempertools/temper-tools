-- temper_mark_analysis.lua -- Audio analysis engine for Temper Mark
-- Streaming WAV sample decoding (via string.unpack), transient detection,
-- PCM_Source peak reading, and waveform mipmap generation.
--
-- Usage:
--   local analysis = dofile(reaper.GetResourcePath() .. "/Scripts/Temper/lib/temper_mark_analysis.lua")
--   local ctx = analysis.analysis_begin(path, wav_info)
--   while not analysis.analysis_step(ctx, 200) do end
--   local markers = analysis.detect_markers(ctx, params, existing_markers)
--   local peaks   = analysis.read_peaks(path, width)  -- fast C-level waveform peaks

local M = {}

local unpack_str = string.unpack
local math_sqrt  = math.sqrt
local math_abs   = math.abs
local math_max   = math.max
local math_floor = math.floor

-- ============================================================
-- string.unpack format strings for batch decoding
-- ============================================================

-- Build a format string that decodes `count` interleaved samples.
-- Returns (fmt, normalizer) where normalizer converts raw int to [-1,1] float.
local function _make_unpack_fmt(audio_format, bits_per_sample, channels, count)
  local frames = count * channels
  if audio_format == 1 then
    if bits_per_sample == 16 then
      return "<" .. string.rep("i2", frames), 1 / 32768
    elseif bits_per_sample == 24 then
      return "<" .. string.rep("i3", frames), 1 / 8388608
    elseif bits_per_sample == 32 then
      return "<" .. string.rep("i4", frames), 1 / 2147483648
    end
  elseif audio_format == 3 and bits_per_sample == 32 then
    return "<" .. string.rep("f", frames), 1.0
  end
  return nil, 0
end

-- ============================================================
-- Detection pipeline helpers
-- ============================================================

local function _percentile(arr, pct)
  local n = #arr
  if n == 0 then return 0 end
  local sorted = {}
  for i = 1, n do sorted[i] = arr[i] end
  table.sort(sorted)
  local idx = math_max(1, math_floor(n * pct / 100 + 0.5))
  if idx > n then idx = n end
  return sorted[idx]
end

-- Half-wave rectified first derivative of the RMS envelope.
local function _build_flux(rms_env)
  local flux = { [1] = 0 }
  for i = 2, #rms_env do
    local d = rms_env[i] - rms_env[i - 1]
    flux[i] = d > 0 and d or 0
  end
  return flux
end

-- Find local maxima in flux, skipping the first skip_hops.
local function _find_flux_peaks(flux, skip_hops)
  local peaks = {}
  local start = skip_hops + 2
  for i = start, #flux - 1 do
    if flux[i] > flux[i - 1] and flux[i] >= flux[i + 1] and flux[i] > 0 then
      peaks[#peaks + 1] = i
    end
  end
  return peaks
end

-- Filter peaks by prominence (adaptive threshold) and silence gate.
-- Sensitivity controls an absolute flux threshold derived from the signal's max flux.
-- This ensures weak transients (far from strong ones) are included/excluded by sensitivity,
-- even after min-spacing's greedy dedup picks the strongest per window.
--   sensitivity 0   → threshold at ~50% of max flux (only strongest transients)
--   sensitivity 50  → threshold at ~13% of max flux
--   sensitivity 100 → threshold at ~1% of max flux (detect subtle transients)
local function _apply_prominence_filter(peaks, flux, rms_env, params, bg_rms)
  if #peaks == 0 then return {} end

  -- Compute max flux across the entire signal (not just at peak positions)
  local max_flux = 0
  for i = 1, #flux do
    if flux[i] > max_flux then max_flux = flux[i] end
  end
  if max_flux <= 0 then return {} end

  -- Quadratic curve: more resolution in the high-sensitivity range
  local t = 1 - params.sensitivity / 100
  local threshold = max_flux * (0.01 + 0.49 * t * t)

  -- Silence gate: linear amplitude from dB
  local silence_lin = 10 ^ (params.silence_db / 20)

  local kept = {}
  for _, idx in ipairs(peaks) do
    if flux[idx] >= threshold and rms_env[idx] > silence_lin then
      kept[#kept + 1] = idx
    end
  end
  return kept
end

-- Greedy min-spacing deduplication: keep higher-flux peaks, enforce min_hops gap.
local function _apply_min_spacing(peaks, flux, min_hops)
  if #peaks == 0 then return {} end

  -- Sort by flux descending (greedy: keep strongest first)
  local by_flux = {}
  for _, idx in ipairs(peaks) do by_flux[#by_flux + 1] = idx end
  table.sort(by_flux, function(a, b) return flux[a] > flux[b] end)

  local kept = {}
  for _, idx in ipairs(by_flux) do
    local too_close = false
    for _, k in ipairs(kept) do
      if math_abs(idx - k) < min_hops then
        too_close = true
        break
      end
    end
    if not too_close then
      kept[#kept + 1] = idx
    end
  end

  -- Re-sort chronologically
  table.sort(kept)
  return kept
end

-- Walk backward from peak to find actual onset (where amplitude drops to silence).
local function _backtrack_to_onset(peak_idx, amp_env, silence_lin, max_hops)
  local best = peak_idx
  for i = peak_idx - 1, math_max(1, peak_idx - max_hops), -1 do
    if amp_env[i] <= silence_lin then
      best = i + 1
      break
    end
    best = i
  end
  return best
end

-- Linear scan enforcement of min spacing after backtracking.
local function _enforce_spacing(hop_indices, min_hops)
  if #hop_indices == 0 then return {} end
  local result = { hop_indices[1] }
  for i = 2, #hop_indices do
    if hop_indices[i] - result[#result] >= min_hops then
      result[#result + 1] = hop_indices[i]
    end
  end
  return result
end

-- ============================================================
-- Exported: Streaming analysis (string.unpack batch decode)
-- ============================================================

local HOP_SIZE = 512

--- Begin streaming analysis of a WAV file.
-- Returns an analysis context table, or nil on failure.
function M.analysis_begin(path, wav_info)
  if not wav_info or not wav_info.data_offset or not wav_info.audio_format then
    return nil
  end

  local fmt, norm = _make_unpack_fmt(wav_info.audio_format, wav_info.bits_per_sample,
    wav_info.channels or 1, HOP_SIZE)
  if not fmt then return nil end

  local f = io.open(path, "rb")
  if not f then return nil end

  f:seek("set", wav_info.data_offset)

  local ch = wav_info.channels or 1
  local bps = math_floor(wav_info.bits_per_sample / 8)
  local bytes_per_frame = bps * ch
  local total_samples = wav_info.total_samples or 0
  local total_hops = math_floor(total_samples / HOP_SIZE)
  if total_hops < 1 then
    f:close()
    return nil
  end

  return {
    -- Private (file I/O state)
    _file           = f,
    _fmt            = fmt,
    _norm           = norm,
    _channels       = ch,
    _chunk_bytes    = HOP_SIZE * bytes_per_frame,
    _hop_idx        = 0,
    _is_float       = wav_info.audio_format == 3,
    -- Public (analysis results)
    rms_env         = {},
    amp_env         = {},
    bg_rms          = 0,
    sr              = wav_info.sample_rate,
    channels        = ch,
    duration        = wav_info.duration or 0,
    total_hops      = total_hops,
    complete        = false,
  }
end

--- Process up to num_hops of audio data using string.unpack batch decode.
-- Returns true when analysis is complete.
function M.analysis_step(actx, num_hops)
  if actx.complete then return true end

  local f = actx._file
  local fmt = actx._fmt
  local norm = actx._norm
  local ch = actx._channels
  local chunk_bytes = actx._chunk_bytes
  local rms_env = actx.rms_env
  local amp_env = actx.amp_env
  local hop_size = HOP_SIZE

  for _ = 1, num_hops do
    if actx._hop_idx >= actx.total_hops then break end

    local buf = f:read(chunk_bytes)
    if not buf or #buf < chunk_bytes then break end

    -- Batch decode: string.unpack returns all values at once (single C call)
    local vals = { unpack_str(fmt, buf) }
    -- Last return value from string.unpack is the next position; discard it
    local nvals = #vals - 1

    local sum_sq = 0
    local peak = 0

    if ch == 1 then
      -- Mono: fast path, no channel interleave
      for i = 1, nvals do
        local s = vals[i] * norm
        if s < 0 then s = -s end
        sum_sq = sum_sq + s * s
        if s > peak then peak = s end
      end
    else
      -- Multichannel: take absolute max across channels per sample
      local vi = 1
      for _ = 1, hop_size do
        local sample_max = 0
        for _ = 1, ch do
          local s = vals[vi] * norm
          if s < 0 then s = -s end
          if s > sample_max then sample_max = s end
          vi = vi + 1
        end
        sum_sq = sum_sq + sample_max * sample_max
        if sample_max > peak then peak = sample_max end
      end
    end

    actx._hop_idx = actx._hop_idx + 1
    rms_env[actx._hop_idx] = math_sqrt(sum_sq / hop_size)
    amp_env[actx._hop_idx] = peak
  end

  -- Check completion
  if actx._hop_idx >= actx.total_hops then
    f:close()
    actx._file = nil

    -- Zero first 4 hops (DAW header artifact suppression)
    local zero_count = math.min(4, actx._hop_idx)
    for i = 1, zero_count do
      rms_env[i] = 0
      amp_env[i] = 0
    end

    -- Background RMS: 10th percentile
    actx.bg_rms = _percentile(rms_env, 10)
    actx.complete = true
    return true
  end

  return false
end

--- Cancel an in-progress analysis and close the file handle.
function M.analysis_cancel(actx)
  if actx and actx._file then
    actx._file:close()
    actx._file = nil
  end
end

-- ============================================================
-- Exported: PCM_Source peak reading (C-level, fast)
-- ============================================================

--- Read waveform peaks from a file using REAPER's PCM_Source engine.
-- Returns { peak_pos[], peak_neg[], width, sr, duration, channels } or nil.
-- This is orders of magnitude faster than Lua-level sample decoding.
function M.read_peaks(path, width)
  width = width or 2000

  local src = reaper.PCM_Source_CreateFromFile(path)
  if not src then return nil end

  local sr = reaper.GetMediaSourceSampleRate(src)
  local nch = reaper.GetMediaSourceNumChannels(src)
  local dur = reaper.GetMediaSourceLength(src)
  if sr <= 0 or dur <= 0 then
    reaper.PCM_Source_Destroy(src)
    return nil
  end

  -- Build peaks if needed (async-safe: mode 0 checks, mode 1 runs, mode 2 finalizes)
  local need = reaper.PCM_Source_BuildPeaks(src, 0)
  if need ~= 0 then
    while reaper.PCM_Source_BuildPeaks(src, 1) ~= 0 do end
    reaper.PCM_Source_BuildPeaks(src, 2)
  end

  -- Request peak data at a rate that gives us `width` peak points
  local peak_rate = width / dur
  local buf = reaper.new_array(width * nch * 3)  -- max/min/extra blocks
  buf.clear()

  local retval = reaper.PCM_Source_GetPeaks(src, peak_rate, 0.0, nch, width, 0, buf)
  local actual_count = retval & 0xFFFFF  -- low 20 bits = sample count

  reaper.PCM_Source_Destroy(src)

  if actual_count < 1 then return nil end

  -- Extract max and min blocks (interleaved by channel)
  -- Layout: [max_ch1, max_ch2, ...] * actual_count, then [min_ch1, min_ch2, ...] * actual_count
  local peak_pos = {}
  local peak_neg = {}
  local max_block_size = actual_count * nch

  for i = 1, actual_count do
    local mx = 0
    for c = 0, nch - 1 do
      local v = math_abs(buf[(i - 1) * nch + c + 1])
      if v > mx then mx = v end
    end
    peak_pos[i] = mx

    local mn = 0
    for c = 0, nch - 1 do
      local v = math_abs(buf[max_block_size + (i - 1) * nch + c + 1])
      if v > mn then mn = v end
    end
    peak_neg[i] = -mn
  end

  return {
    peak_pos = peak_pos,
    peak_neg = peak_neg,
    width    = actual_count,
    sr       = sr,
    duration = dur,
    channels = nch,
  }
end

--- Read waveform peaks for a specific time range at display resolution.
-- Used for zoomed waveform display -- re-queries REAPER's C-level peak engine
-- at the exact visible window, giving pixel-perfect data at any zoom level.
-- Returns same format as read_peaks(), or nil on failure.
function M.read_peaks_range(path, start_sec, end_sec, width)
  width = width or 400
  local range = end_sec - start_sec
  if range <= 0 or width <= 0 then return nil end

  local src = reaper.PCM_Source_CreateFromFile(path)
  if not src then return nil end

  local sr = reaper.GetMediaSourceSampleRate(src)
  local nch = reaper.GetMediaSourceNumChannels(src)
  local dur = reaper.GetMediaSourceLength(src)
  if sr <= 0 or dur <= 0 then
    reaper.PCM_Source_Destroy(src)
    return nil
  end

  -- Build peaks if needed
  local need = reaper.PCM_Source_BuildPeaks(src, 0)
  if need ~= 0 then
    while reaper.PCM_Source_BuildPeaks(src, 1) ~= 0 do end
    reaper.PCM_Source_BuildPeaks(src, 2)
  end

  -- Request peaks at display resolution for the visible time window
  local peak_rate = width / range
  local buf = reaper.new_array(width * nch * 3)
  buf.clear()

  local retval = reaper.PCM_Source_GetPeaks(src, peak_rate, start_sec, nch, width, 0, buf)
  local actual_count = retval & 0xFFFFF

  reaper.PCM_Source_Destroy(src)

  if actual_count < 1 then return nil end

  -- Extract max and min blocks (same layout as read_peaks)
  local peak_pos = {}
  local peak_neg = {}
  local max_block_size = actual_count * nch

  for i = 1, actual_count do
    local mx = 0
    for c = 0, nch - 1 do
      local v = math_abs(buf[(i - 1) * nch + c + 1])
      if v > mx then mx = v end
    end
    peak_pos[i] = mx

    local mn = 0
    for c = 0, nch - 1 do
      local v = math_abs(buf[max_block_size + (i - 1) * nch + c + 1])
      if v > mn then mn = v end
    end
    peak_neg[i] = -mn
  end

  return {
    peak_pos = peak_pos,
    peak_neg = peak_neg,
    width    = actual_count,
    sr       = sr,
    duration = dur,
    channels = nch,
  }
end

-- ============================================================
-- Exported: Marker detection (7-stage pipeline)
-- ============================================================

--- Detect transient markers from a completed analysis.
-- params: { silence_db, sensitivity, spacing_ms }
-- existing_markers: array of { time_sec, ... } from WAV cue chunks
-- ignore_regions: optional array of { start_sec, end_sec } to suppress markers
-- Returns sorted array of { time_sec, label }.
function M.detect_markers(analysis, params, existing_markers, ignore_regions)
  if not analysis or not analysis.complete then return {} end

  -- Gate 1: Existing marker suppression
  if existing_markers and #existing_markers > 0 then
    for _, m in ipairs(existing_markers) do
      if m.time_sec > 0.001 then return {} end
    end
  end

  local rms_env = analysis.rms_env
  local amp_env = analysis.amp_env
  local n = #amp_env
  if n == 0 then return {} end

  -- Gate 2: Amplitude threshold (peak < 0.01 = -40dB)
  local max_amp = 0
  for i = 1, n do
    if amp_env[i] > max_amp then max_amp = amp_env[i] end
  end
  if max_amp < 0.01 then return {} end

  -- Gate 3: Dynamic range gate (< 6dB)
  local min_amp = max_amp
  for i = 1, n do
    if amp_env[i] < min_amp and amp_env[i] > 0 then min_amp = amp_env[i] end
  end
  if min_amp <= 0 then min_amp = 1e-10 end
  local dynamic_range_db = 20 * math.log(max_amp / min_amp, 10)
  if dynamic_range_db < 6 then return {} end

  -- Stage 1: Energy flux
  local flux = _build_flux(rms_env)

  -- Stage 2: Local maxima (skip first 4 hops)
  local peaks = _find_flux_peaks(flux, 4)
  if #peaks == 0 then return {} end

  -- Stage 3: Prominence filtering (sensitivity-dependent)
  peaks = _apply_prominence_filter(peaks, flux, rms_env, params, analysis.bg_rms)
  if #peaks == 0 then return {} end

  -- Stage 4: Min-spacing deduplication
  local sr = analysis.sr or 48000
  local hop_sec = HOP_SIZE / sr
  local min_hops = math_max(1, math_floor((params.spacing_ms / 1000) / hop_sec))
  peaks = _apply_min_spacing(peaks, flux, min_hops)
  if #peaks == 0 then return {} end

  -- Stage 5: Onset backtracking (up to 15 hops)
  local silence_lin = 10 ^ (params.silence_db / 20)
  local onsets = {}
  for _, idx in ipairs(peaks) do
    onsets[#onsets + 1] = _backtrack_to_onset(idx, amp_env, silence_lin, 15)
  end

  -- Stage 6: Post-backtrack spacing enforcement
  onsets = _enforce_spacing(onsets, min_hops)

  -- Convert hop indices to time + labels
  local markers = {}
  for i, hop in ipairs(onsets) do
    markers[#markers + 1] = {
      time_sec = (hop - 1) * hop_sec,
      label    = string.format("Take %d", i),
    }
  end

  -- Stage 7: Ignore region filtering (suppress markers in user-excluded ranges)
  if ignore_regions and #ignore_regions > 0 then
    local filtered = {}
    for _, m in ipairs(markers) do
      local suppressed = false
      for _, r in ipairs(ignore_regions) do
        if m.time_sec >= r.start_sec and m.time_sec <= r.end_sec then
          suppressed = true
          break
        end
      end
      if not suppressed then filtered[#filtered + 1] = m end
    end
    -- Re-label after filtering
    for i, m in ipairs(filtered) do
      m.label = string.format("Take %d", i)
    end
    markers = filtered
  end

  return markers
end

-- ============================================================
-- Exported: Mipmap from analysis (fallback if PCM_Source unavailable)
-- ============================================================

--- Downsample amplitude envelope to a fixed-width peak display.
-- Returns { peak_pos[], peak_neg[], width }.
function M.build_mipmap(analysis, width)
  width = width or 2000
  if not analysis or not analysis.amp_env or #analysis.amp_env == 0 then
    return { peak_pos = {}, peak_neg = {}, width = 0 }
  end

  local amp = analysis.amp_env
  local n = #amp
  local peak_pos = {}
  local peak_neg = {}

  for i = 1, width do
    local lo = math_floor((i - 1) / width * n) + 1
    local hi = math_floor(i / width * n)
    if hi < lo then hi = lo end
    if hi > n then hi = n end

    local mx = 0
    for j = lo, hi do
      if amp[j] > mx then mx = amp[j] end
    end
    peak_pos[i] = mx
    peak_neg[i] = -mx
  end

  return { peak_pos = peak_pos, peak_neg = peak_neg, width = width }
end

return M
