-- temper_import.lua — File import helpers, WAV cue reading, item trim utilities
-- Shared library for Temper scripts (Vortex, Vortex Mini, etc.)
-- Returns a factory function: call with CONFIG to get the import_mod table.
--
-- Usage:
--   local import_mod = (dofile(reaper.GetResourcePath() .. "/Scripts/ABS/lib/temper_import.lua"))(CONFIG)
--
-- CONFIG fields consumed:
--   trim_to_first_cue (boolean)  When true, imported items are trimmed to first cue point.

return function(config)

-- ============================================================
-- WAV cue helpers
-- ============================================================

-- Parse a 4-byte little-endian integer from a binary string starting at byte 1.
local function _le4(b)
  return b:byte(1) + b:byte(2)*256 + b:byte(3)*65536 + b:byte(4)*16777216
end

-- Return a sorted table of all usable WAV cue-point positions (seconds).
-- Each WAV cue entry is 24 bytes: id(4) + position(4) + data_chunk_id(4) +
-- chunk_start(4) + block_start(4) + sample_offset(4).  We use sample_offset
-- (the last field) which is the true sample position in the data chunk.
-- Positions within 1 ms of the origin are excluded (title / start cues).
-- Returns {} when the file is not WAV, has no cue chunk, or none are usable.
local function _read_wav_cue_list_sec(filepath)
  local f = io.open(filepath, "rb")
  if not f then return {} end
  if f:read(4) ~= "RIFF" or not f:read(4) or f:read(4) ~= "WAVE" then
    f:close(); return {}
  end
  local sr, raw = nil, {}
  while true do
    local id = f:read(4); if not id or #id < 4 then break end
    local sb = f:read(4); if not sb or #sb < 4 then break end
    local sz = _le4(sb)
    if id == "fmt " and sz >= 16 then
      local hdr = f:read(8)  -- audio_format(2) + channels(2) + sample_rate(4)
      if hdr and #hdr == 8 then sr = _le4(hdr:sub(5, 8)) end
      local rem = sz - 8 + (sz % 2); if rem > 0 then f:read(rem) end
    elseif id == "cue " and sz >= 4 then
      local nb = f:read(4)
      local n  = nb and _le4(nb) or 0
      for _ = 1, n do
        f:read(4)              -- cue id        (skip)
        f:read(4)              -- position      (play-order field, skip)
        f:read(12)             -- data_chunk_id + chunk_start + block_start
        local pb = f:read(4)  -- sample_offset: true sample position in data chunk
        if pb and #pb == 4 then raw[#raw + 1] = _le4(pb) end
      end
    else
      f:seek("cur", sz + (sz % 2))
    end
    if sr and #raw > 0 then break end
  end
  f:close()
  if not sr or sr <= 0 or #raw == 0 then return {} end
  table.sort(raw)
  local threshold = math.max(1, math.floor(sr * 0.001))
  local out = {}
  for _, s in ipairs(raw) do
    if s > threshold then out[#out + 1] = s / sr end
  end
  return out
end

-- Shorten item to its first cue point after the take start.
-- Checks REAPER take markers first (manual or drag-and-drop imports), then falls
-- back to reading the embedded WAV cue chunk directly (programmatic PCM_Source
-- imports where REAPER has not yet converted embedded cues to take markers).
-- Cues within 1 ms of the origin are skipped to avoid zero-length items.
-- @param item      MediaItem*
-- @param take      MediaItem_Take*
-- @param filepath  string  Source file path used for the WAV cue fallback
local function trim_to_first_cue(item, take, filepath)
  local n = reaper.GetNumTakeMarkers(take)
  for i = 0, n - 1 do
    local mpos = reaper.GetTakeMarker(take, i)  -- take time in seconds
    if mpos > 0.001 then
      reaper.SetMediaItemLength(item, mpos, false)
      reaper.UpdateItemInProject(item)
      return
    end
  end
  local cues = _read_wav_cue_list_sec(filepath)
  if cues[1] then
    reaper.SetMediaItemLength(item, cues[1], false)
    reaper.UpdateItemInProject(item)
  end
end

-- ============================================================
-- import_mod — file-import helpers
-- ============================================================

local import_mod = {}

-- Cap an item's length to max_sec without moving its start position.
-- No-op when max_sec <= 0 or the item is already shorter than max_sec.
-- @param item    MediaItem*
-- @param max_sec number  Maximum allowed length in seconds
function import_mod.trim_item_to_max(item, max_sec)
  if max_sec <= 0 then return end
  local cur = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  if cur > max_sec then
    reaper.SetMediaItemLength(item, max_sec, false)
    reaper.UpdateItemInProject(item)
  end
end

-- Expose WAV cue reader so callers can use cue boundaries directly.
import_mod.read_wav_cue_list_sec = _read_wav_cue_list_sec

-- Resolve the effective import position for a track relative to the cursor.
-- If an item already overlaps pos on this track, returns pos unchanged (will be replaced).
-- Otherwise scans forward for the first item starting after pos and returns its position.
-- Falls back to pos when the track has no items after the cursor.
-- @param t    MediaTrack*
-- @param pos  number  Cursor position in seconds
-- @return number  Effective import position in seconds
function import_mod.find_effective_pos(t, pos)
  local n = reaper.CountTrackMediaItems(t)
  local first_after = nil
  for i = 0, n - 1 do
    local item = reaper.GetTrackMediaItem(t, i)
    local ipos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local ilen = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    if pos >= ipos and pos < ipos + ilen then return pos end
    if ipos > pos and (first_after == nil or ipos < first_after) then
      first_after = ipos
    end
  end
  return first_after or pos
end

-- Find the single media item on track t whose time range covers pos.
-- A range is [D_POSITION, D_POSITION + D_LENGTH).
-- @param t    MediaTrack*
-- @param pos  number  Project time in seconds
-- @return MediaItem* | nil
function import_mod.find_item_at_cursor(t, pos)
  local n = reaper.CountTrackMediaItems(t)
  for i = 0, n - 1 do
    local item = reaper.GetTrackMediaItem(t, i)
    local ipos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local ilen = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    if pos >= ipos and pos < ipos + ilen then
      return item
    end
  end
  return nil
end

-- Find the item on track whose D_POSITION falls within [range_start, range_end).
-- When multiple items qualify, returns the one closest to prefer_near.
-- Used by relative-position-awareness to locate the "slot item" for a row.
-- @param t           MediaTrack*
-- @param range_start number  Inclusive lower bound (project time, seconds)
-- @param range_end   number  Exclusive upper bound (project time, seconds)
-- @param prefer_near number  (optional) Proximity anchor; defaults to range_start
-- @return MediaItem* | nil
function import_mod.find_item_in_range(t, range_start, range_end, prefer_near)
  prefer_near = prefer_near or range_start
  local n = reaper.CountTrackMediaItems(t)
  local best, best_dist = nil, math.huge
  for i = 0, n - 1 do
    local item = reaper.GetTrackMediaItem(t, i)
    local ipos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    if ipos >= range_start and ipos < range_end then
      local dist = math.abs(ipos - prefer_near)
      if dist < best_dist then best, best_dist = item, dist end
    end
  end
  return best
end

-- Import filepath onto track t at pos.
-- Deletes the existing item at pos (if any) before importing.
-- Caller owns the undo block and UpdateArrange() call.
-- Returns true on success, false if the source file could not be loaded.
-- @param t        MediaTrack*
-- @param filepath string
-- @param pos      number  Project time in seconds
function import_mod.import_file(t, filepath, pos)
  local src = reaper.PCM_Source_CreateFromFile(filepath)
  if not src then
    reaper.ShowConsoleMsg(string.format("[Temper Vortex] Could not load source: %s\n", filepath))
    return false
  end

  local old = import_mod.find_item_at_cursor(t, pos)
  if old then reaper.DeleteTrackMediaItem(t, old) end

  local item = reaper.AddMediaItemToTrack(t)
  local take = reaper.AddTakeToMediaItem(item)
  reaper.SetMediaItemTake_Source(take, src)
  -- Name the take after the source file (stem without extension).
  local stem = filepath:match("([^/\\]+)%.[^%.]*$") or filepath:match("([^/\\]+)$") or ""
  if stem ~= "" then
    reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", stem, true)
  end
  reaper.SetMediaItemPosition(item, pos, false)
  reaper.SetMediaItemLength(item, reaper.GetMediaSourceLength(src, false), false)
  reaper.UpdateItemInProject(item)
  if config.trim_to_first_cue then
    trim_to_first_cue(item, take, filepath)
  end
  return true
end

return import_mod

end  -- factory
