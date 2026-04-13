-- rsg_wav_io.lua -- RIFF/WAV chunk reader and cue chunk writer for Temper Mark
-- Reads WAV metadata, cue markers, and audio samples via binary I/O.
-- Writes cue chunks back to WAV files with surgical metadata-only modification.
-- No external dependencies (no SWS, no PCM_Source).
--
-- Usage:
--   local wav_io = dofile(reaper.GetResourcePath() .. "/Scripts/Temper/lib/rsg_wav_io.lua")
--   local result = wav_io.read_wav_all(path)   -- single-pass: info + markers + file_size
--   local info = wav_io.read_wav_info(path)     -- convenience wrapper
--   local markers = wav_io.read_cue_markers(path)
--   local ok, err = wav_io.embed_markers(path, markers)  -- write cue chunks to WAV

local wav_io = {}

-- Parse a 2-byte little-endian unsigned integer from a binary string.
local function _le2(b)
  return b:byte(1) + b:byte(2) * 256
end

-- Parse a 4-byte little-endian unsigned integer from a binary string.
local function _le4(b)
  return b:byte(1) + b:byte(2) * 256 + b:byte(3) * 65536 + b:byte(4) * 16777216
end

-- Validate RIFF/WAVE header. Returns file handle positioned after "WAVE" or nil.
local function _open_wav(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local riff = f:read(4)
  if riff ~= "RIFF" then f:close(); return nil end
  f:read(4) -- file size (skip)
  local wave = f:read(4)
  if wave ~= "WAVE" then f:close(); return nil end
  return f
end

-- Single-pass WAV reader: opens file once, extracts fmt info, cue markers, and file size.
-- Returns { info = {...}, markers = {...}, file_size = N } or nil on invalid WAV.
function wav_io.read_wav_all(path)
  local f = _open_wav(path)
  if not f then return nil end

  -- Get file size from the open handle
  local file_size = f:seek("end") or 0
  f:seek("set", 12) -- back to after RIFF/WAVE header

  local info = {}
  local sr = nil
  local cue_entries = {}  -- {id, sample_offset}
  local labels = {}       -- cue_id -> label string

  while true do
    local id = f:read(4)
    if not id or #id < 4 then break end
    local sb = f:read(4)
    if not sb or #sb < 4 then break end
    local sz = _le4(sb)
    local chunk_start = f:seek("cur", 0)

    if id == "fmt " and sz >= 16 then
      local fmt_data = f:read(math.min(sz, 40))
      if fmt_data and #fmt_data >= 16 then
        info.audio_format    = _le2(fmt_data:sub(1, 2))
        info.channels        = _le2(fmt_data:sub(3, 4))
        info.sample_rate     = _le4(fmt_data:sub(5, 8))
        info.byte_rate       = _le4(fmt_data:sub(9, 12))
        info.block_align     = _le2(fmt_data:sub(13, 14))
        info.bits_per_sample = _le2(fmt_data:sub(15, 16))
        -- WAVE_FORMAT_EXTENSIBLE: resolve actual format from SubFormat GUID
        if info.audio_format == 0xFFFE and #fmt_data >= 40 then
          info.audio_format = _le2(fmt_data:sub(25, 26))
        end
        sr = info.sample_rate
      end

    elseif id == "data" then
      info.data_size   = sz
      info.data_offset = chunk_start
      if info.sample_rate and info.channels and info.bits_per_sample
         and info.bits_per_sample > 0 then
        local bytes_per_sample = info.bits_per_sample / 8
        local total_samples = sz / (info.channels * bytes_per_sample)
        info.duration = total_samples / info.sample_rate
        info.total_samples = math.floor(total_samples)
      end

    elseif id == "cue " and sz >= 4 then
      local nb = f:read(4)
      local n = nb and _le4(nb) or 0
      for _ = 1, n do
        local cue_id_b = f:read(4)
        f:read(4)   -- position (play-order, unreliable)
        f:read(12)  -- data_chunk_id + chunk_start + block_start
        local so_b = f:read(4)  -- sample_offset
        if cue_id_b and #cue_id_b == 4 and so_b and #so_b == 4 then
          cue_entries[#cue_entries + 1] = {
            id = _le4(cue_id_b),
            sample_offset = _le4(so_b),
          }
        end
      end

    elseif id == "LIST" and sz >= 4 then
      local list_type = f:read(4)
      if list_type == "adtl" then
        local adtl_end = chunk_start + sz
        while f:seek("cur", 0) < adtl_end do
          local sub_id = f:read(4)
          if not sub_id or #sub_id < 4 then break end
          local sub_sb = f:read(4)
          if not sub_sb or #sub_sb < 4 then break end
          local sub_sz = _le4(sub_sb)
          local sub_start = f:seek("cur", 0)

          if sub_id == "labl" and sub_sz >= 4 then
            local label_cue_id_b = f:read(4)
            if label_cue_id_b and #label_cue_id_b == 4 then
              local label_cue_id = _le4(label_cue_id_b)
              local text_len = sub_sz - 4
              if text_len > 0 then
                local text = f:read(text_len)
                if text then
                  labels[label_cue_id] = text:gsub("%z+$", "")
                end
              end
            end
          end

          f:seek("set", sub_start + sub_sz + (sub_sz % 2))
        end
      end
    end

    -- Seek to end of chunk (word-aligned)
    f:seek("set", chunk_start + sz + (sz % 2))
  end

  f:close()

  -- Build markers list
  local markers = {}
  if sr and sr > 0 and #cue_entries > 0 then
    table.sort(cue_entries, function(a, b) return a.sample_offset < b.sample_offset end)
    local threshold = math.max(1, math.floor(sr * 0.001))
    for i, entry in ipairs(cue_entries) do
      if entry.sample_offset > threshold then
        markers[#markers + 1] = {
          time_sec      = entry.sample_offset / sr,
          label         = labels[entry.id] or string.format("Take %d", i),
          sample_offset = entry.sample_offset,
        }
      end
    end
  end

  local valid_info = (info.sample_rate and info.data_size) and info or nil
  return { info = valid_info, markers = markers, file_size = file_size }
end

-- Read basic WAV file information (sample rate, channels, bits per sample, duration, format).
-- Returns nil if the file is not a valid WAV. Delegates to read_wav_all.
function wav_io.read_wav_info(path)
  local result = wav_io.read_wav_all(path)
  if not result then return nil end
  return result.info
end

-- Read all cue markers from a WAV file.
-- Returns a sorted list of {time_sec, label, sample_offset} tables.
-- Delegates to read_wav_all.
function wav_io.read_cue_markers(path)
  local result = wav_io.read_wav_all(path)
  if not result then return {} end
  return result.markers
end

-- ============================================================
-- Write helpers
-- ============================================================

-- Encode a uint32 as a 4-byte little-endian binary string.
local function _le4_write(n)
  return string.char(
    n & 0xFF,
    (n >> 8) & 0xFF,
    (n >> 16) & 0xFF,
    (n >> 24) & 0xFF
  )
end

-- Unpack a single PCM sample at byte offset to float [-1, 1].
-- Supports 16-bit and 24-bit. Returns 0 for unsupported bit depths.
local function _unpack_sample(raw, offset, bps)
  if bps == 16 then
    local lo, hi = raw:byte(offset), raw:byte(offset + 1)
    local v = lo + hi * 256
    if v >= 32768 then v = v - 65536 end
    return v / 32768.0
  elseif bps == 24 then
    local lo, mid, hi = raw:byte(offset), raw:byte(offset + 1), raw:byte(offset + 2)
    local v = lo + mid * 256 + hi * 65536
    if v >= 8388608 then v = v - 16777216 end
    return v / 8388608.0
  end
  return 0
end

-- Pack a float [-1, 1] back to PCM bytes.
-- Supports 16-bit and 24-bit. Returns "\0\0" for unsupported bit depths.
local function _pack_sample(val, bps)
  val = math.max(-1.0, math.min(1.0, val))
  if bps == 16 then
    local v = math.floor(val * 32767 + 0.5)
    if v < 0 then v = v + 65536 end
    return string.char(v % 256, math.floor(v / 256) % 256)
  elseif bps == 24 then
    local v = math.floor(val * 8388607 + 0.5)
    if v < 0 then v = v + 16777216 end
    return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256)
  end
  return "\0\0"
end

-- Build binary cue + LIST adtl chunks from a marker list.
-- Pure function, no I/O. Returns cue_binary, adtl_binary (two strings).
-- Markers with time_sec within 1ms of origin are excluded (matches read threshold).
function wav_io.build_cue_chunks(markers, sample_rate)
  -- Filter and sort
  local threshold_sec = 0.001
  local sorted = {}
  for _, m in ipairs(markers) do
    if m.time_sec > threshold_sec then
      sorted[#sorted + 1] = { time_sec = m.time_sec, label = m.label or "" }
    end
  end
  table.sort(sorted, function(a, b) return a.time_sec < b.time_sec end)

  local n = #sorted

  -- Build cue chunk: "cue " + size + numCuePoints + 24 bytes per point
  local cue_data_size = 4 + n * 24  -- 4 for count, 24 per cue point
  local cue_parts = { "cue ", _le4_write(cue_data_size), _le4_write(n) }
  for i, m in ipairs(sorted) do
    local sample_offset = math.floor(m.time_sec * sample_rate + 0.5)
    cue_parts[#cue_parts + 1] = _le4_write(i)          -- dwName (cue ID, 1-based)
    cue_parts[#cue_parts + 1] = _le4_write(0)          -- dwPosition (play order, unused)
    cue_parts[#cue_parts + 1] = "data"                  -- fccChunk
    cue_parts[#cue_parts + 1] = _le4_write(0)          -- dwChunkStart
    cue_parts[#cue_parts + 1] = _le4_write(0)          -- dwBlockStart
    cue_parts[#cue_parts + 1] = _le4_write(sample_offset) -- dwSampleOffset
  end
  local cue_binary = table.concat(cue_parts)

  -- Build LIST adtl chunk with labl subchunks
  local labl_parts = {}
  for i, m in ipairs(sorted) do
    local text = m.label .. "\0"  -- null-terminated
    local text_len = #text
    local labl_data_size = 4 + text_len  -- 4 for cue ID + text
    labl_parts[#labl_parts + 1] = "labl"
    labl_parts[#labl_parts + 1] = _le4_write(labl_data_size)
    labl_parts[#labl_parts + 1] = _le4_write(i)  -- cue point ID
    labl_parts[#labl_parts + 1] = text
    -- Word-align: pad with a zero byte if labl_data_size is odd
    if labl_data_size % 2 == 1 then
      labl_parts[#labl_parts + 1] = "\0"
    end
  end
  local adtl_payload = table.concat(labl_parts)
  local adtl_size = 4 + #adtl_payload  -- 4 for "adtl" type ID
  local adtl_binary = "LIST" .. _le4_write(adtl_size) .. "adtl" .. adtl_payload

  return cue_binary, adtl_binary
end

-- Build a chunk index from raw WAV bytes.
-- Returns a list of {id, header_offset, data_offset, size, skip} tables.
-- header_offset = position of the 4-byte chunk ID in the raw bytes (1-based).
-- skip = true for chunks that should be replaced (cue, LIST adtl).
local function _build_chunk_index(raw)
  local chunks = {}
  local pos = 13  -- 1-based; skip 12-byte RIFF header ("RIFF" + size + "WAVE")
  local file_len = #raw

  while pos + 7 <= file_len do
    local id = raw:sub(pos, pos + 3)
    local sz = _le4(raw:sub(pos + 4, pos + 7))
    local data_start = pos + 8

    local skip = false
    if id == "cue " then
      skip = true
    elseif id == "LIST" and sz >= 4 then
      local list_type = raw:sub(data_start, data_start + 3)
      if list_type == "adtl" then
        skip = true
      end
    end

    -- Total chunk span: 8 (header) + sz + word-alignment padding
    local padded_size = sz + (sz % 2)
    chunks[#chunks + 1] = {
      id            = id,
      header_offset = pos,
      data_offset   = data_start,
      size          = sz,
      padded_size   = padded_size,
      skip          = skip,
    }

    pos = data_start + padded_size
  end

  return chunks
end

-- Embed markers into a WAV file by surgically replacing cue + LIST adtl chunks.
-- All other chunks are preserved as opaque byte copies in their original order.
-- Returns true on success, or nil + error message on failure.
function wav_io.embed_markers(path, markers)
  -- Read WAV info for sample rate
  local result = wav_io.read_wav_all(path)
  if not result or not result.info then
    return nil, "cannot read WAV file"
  end
  local sample_rate = result.info.sample_rate
  if not sample_rate or sample_rate <= 0 then
    return nil, "invalid sample rate"
  end

  -- Read entire file as raw bytes
  local f = io.open(path, "rb")
  if not f then return nil, "cannot open file for reading" end
  local raw = f:read("*a")
  f:close()
  if not raw or #raw < 12 then return nil, "file too small" end

  -- Validate RIFF/WAVE header
  if raw:sub(1, 4) ~= "RIFF" or raw:sub(9, 12) ~= "WAVE" then
    return nil, "not a valid RIFF/WAVE file"
  end

  -- Build chunk index
  local chunks = _build_chunk_index(raw)

  -- Build new cue + adtl binary
  local cue_binary, adtl_binary = wav_io.build_cue_chunks(markers, sample_rate)

  -- Reassemble: RIFF header + preserved chunks (original order) + new cue + new adtl
  local parts = {}
  for _, chunk in ipairs(chunks) do
    if not chunk.skip then
      -- Extract the full chunk (header + data + padding) as raw bytes
      local chunk_end = chunk.header_offset + 7 + chunk.padded_size
      parts[#parts + 1] = raw:sub(chunk.header_offset, chunk_end)
    end
  end
  -- Append new cue and adtl chunks
  parts[#parts + 1] = cue_binary
  parts[#parts + 1] = adtl_binary

  local body = table.concat(parts)
  local total_size = 4 + #body  -- 4 for "WAVE" + all chunks
  local output = "RIFF" .. _le4_write(total_size) .. "WAVE" .. body

  -- Write to temp file, then atomic rename
  local tmp_path = path .. ".tmp"
  local fw = io.open(tmp_path, "wb")
  if not fw then return nil, "cannot create temp file for writing" end
  local ok = fw:write(output)
  fw:close()
  if not ok then
    os.remove(tmp_path)
    return nil, "write failed"
  end

  -- Replace original: Windows os.rename cannot overwrite, so remove first
  os.remove(path)
  local rename_ok, rename_err = os.rename(tmp_path, path)
  if not rename_ok then
    os.remove(tmp_path)
    return nil, "rename failed: " .. tostring(rename_err)
  end

  return true
end

-- ============================================================
-- Alloy write helpers
-- ============================================================

-- Write 12-byte RIFF/WAVE header with placeholder size.
-- Returns the offset of the RIFF size field (4).
function wav_io.write_riff_header(fh)
  fh:write("RIFF")
  fh:write(_le4_write(0))  -- placeholder for total file size - 8
  fh:write("WAVE")
  return 4
end

-- Write fmt chunk from raw format bytes.
function wav_io.write_fmt_chunk(fh, fmt_data)
  fh:write("fmt ")
  fh:write(_le4_write(#fmt_data))
  fh:write(fmt_data)
end

-- Write WAVE_FORMAT_EXTENSIBLE fmt chunk for multichannel output (>2 channels).
-- channel_mask: dwChannelMask from ksmedia.h speaker position bits.
-- SubFormat GUID for PCM: 00000001-0000-0010-8000-00aa00389b71
function wav_io.write_fmt_chunk_extensible(fh, channels, sample_rate, bits_per_sample, channel_mask)
  local bytes_per_sample = math.floor(bits_per_sample / 8)
  local block_align = channels * bytes_per_sample
  local byte_rate = sample_rate * block_align
  -- 40-byte fmt chunk: 18 base + 22 extension
  local fmt_data = string.pack("<I2I2I4I4I2I2",
    0xFFFE,            -- wFormatTag = WAVE_FORMAT_EXTENSIBLE
    channels,
    sample_rate,
    byte_rate,
    block_align,
    bits_per_sample)
  -- cbSize = 22 (size of extension)
  fmt_data = fmt_data .. string.pack("<I2", 22)
  -- wValidBitsPerSample
  fmt_data = fmt_data .. string.pack("<I2", bits_per_sample)
  -- dwChannelMask
  fmt_data = fmt_data .. string.pack("<I4", channel_mask)
  -- SubFormat GUID: PCM = {00000001-0000-0010-8000-00aa00389b71}
  -- Byte layout: 01 00 00 00 00 00 10 00 80 00 00 aa 00 38 9b 71
  fmt_data = fmt_data .. "\x01\x00\x00\x00\x00\x00\x10\x00\x80\x00\x00\xaa\x00\x38\x9b\x71"
  fh:write("fmt ")
  fh:write(_le4_write(#fmt_data))
  fh:write(fmt_data)
end

-- Write data chunk header with placeholder size.
-- Returns the offset of the data size field for later patching.
function wav_io.write_data_header(fh)
  fh:write("data")
  local size_offset = fh:seek("cur", 0)
  fh:write(_le4_write(0))  -- placeholder for data size
  return size_offset
end

-- Write raw PCM bytes to output. Returns number of bytes written.
function wav_io.write_pcm_block(fh, block_bytes)
  fh:write(block_bytes)
  return #block_bytes
end

-- Seek to offset and overwrite a uint32 LE value (for patching placeholders).
function wav_io.patch_uint32_le(fh, offset, value)
  if value > 0xFFFFFFFF then
    return nil, "size exceeds WAV uint32 limit"
  end
  fh:seek("set", offset)
  fh:write(_le4_write(value))
  return true
end

-- Write an arbitrary RIFF chunk with word-alignment padding.
function wav_io.write_chunk(fh, id, data_bytes)
  fh:write(id)
  fh:write(_le4_write(#data_bytes))
  fh:write(data_bytes)
  if #data_bytes % 2 == 1 then
    fh:write("\0")
  end
end

-- Read raw bytes of a named chunk from a WAV file.
-- Returns the chunk data as a string, or nil if not found.
function wav_io.read_chunk_raw(path, chunk_id)
  local f = _open_wav(path)
  if not f then return nil end

  while true do
    local id = f:read(4)
    if not id or #id < 4 then break end
    local sb = f:read(4)
    if not sb or #sb < 4 then break end
    local sz = _le4(sb)

    if id == chunk_id then
      local data = f:read(sz)
      f:close()
      return data
    end

    -- Skip to next chunk (word-aligned)
    f:seek("cur", sz + (sz % 2))
  end

  f:close()
  return nil
end

-- Read raw fmt chunk bytes from a WAV file. Convenience wrapper.
function wav_io.read_fmt_raw(path)
  return wav_io.read_chunk_raw(path, "fmt ")
end

-- Read bext, iXML, and LIST/INFO metadata chunks from a WAV file in one pass.
-- Returns { bext = string|nil, ixml = string|nil, list_info = string|nil }.
-- Values are raw chunk data bytes (no 8-byte header), matching read_chunk_raw convention.
-- LIST/adtl is skipped (handled by cue logic); only LIST/INFO is captured.
function wav_io.read_metadata_chunks(path)
  local f = _open_wav(path)
  if not f then return {} end

  local meta = {}
  while true do
    local id = f:read(4)
    if not id or #id < 4 then break end
    local sb = f:read(4)
    if not sb or #sb < 4 then break end
    local sz = _le4(sb)
    local chunk_start = f:seek("cur", 0)

    if id == "bext" and sz > 0 then
      meta.bext = f:read(sz)
    elseif id == "iXML" and sz > 0 then
      meta.ixml = f:read(sz)
    elseif id == "LIST" and sz >= 4 then
      local list_type = f:read(4)
      if list_type == "INFO" then
        local info_data = f:read(sz - 4)
        if info_data then
          meta.list_info = "INFO" .. info_data
        end
      end
    end

    f:seek("set", chunk_start + sz + (sz % 2))
  end

  f:close()
  return meta
end

-- Strip CodingHistory from bext chunk data (contains channel count info).
-- Truncates to the fixed header; BWF v0/v1 = 346 bytes, v2 = 602 bytes.
function wav_io.strip_bext_coding_history(data)
  if #data <= 346 then return data end
  local version = _le2(data:sub(339, 340))
  local hdr_size = version >= 2 and 602 or 346
  if #data <= hdr_size then return data end
  return data:sub(1, hdr_size)
end

-- Strip TRACK_LIST and TRACK_COUNT elements from iXML data.
-- These reference per-channel metadata that becomes invalid on channel count change.
function wav_io.strip_ixml_track_list(data)
  data = data:gsub("<TRACK_LIST>.-</TRACK_LIST>%s*", "")
  data = data:gsub("<TRACK_COUNT>.-</TRACK_COUNT>%s*", "")
  return data
end

-- Scan a PCM buffer for the first frame exceeding threshold.
-- Returns frame index (0-based) within the buffer, or nil if all silent.
-- buf: raw PCM string, frame_size: bytes per frame, bps: 16 or 24,
-- nch: channels, bytes_per_sample: bps/8, threshold: linear amplitude.
local function _scan_buf_leading(buf, frame_size, bps, nch, bytes_per_sample, threshold)
  local buflen = #buf
  local nframes = math.floor(buflen / frame_size)
  for i = 0, nframes - 1 do
    local base = i * frame_size
    for c = 0, nch - 1 do
      local off = base + c * bytes_per_sample + 1
      local s = _unpack_sample(buf, off, bps)
      if s > threshold or s < -threshold then
        return i
      end
    end
  end
  return nil
end

-- Scan a PCM buffer backwards for the last frame exceeding threshold.
-- Returns frame index (0-based) within the buffer, or nil if all silent.
local function _scan_buf_trailing(buf, frame_size, bps, nch, bytes_per_sample, threshold)
  local buflen = #buf
  local nframes = math.floor(buflen / frame_size)
  for i = nframes - 1, 0, -1 do
    local base = i * frame_size
    for c = 0, nch - 1 do
      local off = base + c * bytes_per_sample + 1
      local s = _unpack_sample(buf, off, bps)
      if s > threshold or s < -threshold then
        return i
      end
    end
  end
  return nil
end

-- Analyze silence boundaries in a WAV file.
-- Uses buffered I/O: one file open, 2-3 bulk reads (header + leading + trailing).
-- trim_mode: "leading" | "trailing" | "both" | "off"
-- Returns {trim_start_sec, trim_end_sec, trimmed_duration, original_duration} or nil, err.
function wav_io.analyze_silence(path, threshold_db, trim_mode)
  if not path then return nil, "path required" end
  if not threshold_db or threshold_db > -24 or threshold_db < -96 then
    return nil, "threshold_db must be between -96 and -24"
  end
  if trim_mode == "off" then
    return nil, "trim_mode is off"
  end
  if trim_mode ~= "leading" and trim_mode ~= "trailing" and trim_mode ~= "both" then
    return nil, "trim_mode must be 'off', 'leading', 'trailing', or 'both'"
  end

  -- Single file open for everything
  local f = io.open(path, "rb")
  if not f then return nil, "cannot open file" end

  -- Minimal header parse: read first 128 bytes to find fmt + data chunks
  local hdr = f:read(128)
  if not hdr or #hdr < 44 then f:close(); return nil, "file too small" end
  -- Verify RIFF/WAVE
  if hdr:sub(1, 4) ~= "RIFF" or hdr:sub(9, 12) ~= "WAVE" then
    f:close(); return nil, "not a WAV file"
  end

  -- Walk chunks starting at byte 13 (1-based)
  local sr, bps, nch, data_offset, data_size
  local pos = 13
  while pos + 8 <= #hdr do
    local ck_id = hdr:sub(pos, pos + 3)
    local b1, b2, b3, b4 = hdr:byte(pos + 4, pos + 7)
    local ck_sz = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216

    if ck_id == "fmt " and pos + 8 + 15 <= #hdr then
      local fmt_off = pos + 8
      local a1, a2 = hdr:byte(fmt_off + 2, fmt_off + 3)
      nch = a1 + a2 * 256
      local s1, s2, s3, s4 = hdr:byte(fmt_off + 4, fmt_off + 7)
      sr = s1 + s2 * 256 + s3 * 65536 + s4 * 16777216
      local d1, d2 = hdr:byte(fmt_off + 14, fmt_off + 15)
      bps = d1 + d2 * 256
    elseif ck_id == "data" then
      data_offset = pos + 8 - 1  -- convert to 0-based file offset
      data_size = ck_sz
      break
    end

    -- Advance to next chunk (word-aligned)
    pos = pos + 8 + ck_sz + (ck_sz % 2)
  end

  -- If data chunk not found in first 128 bytes, do a longer scan
  if not data_offset then
    f:seek("set", 12)
    local big_hdr = f:read(4096)
    if big_hdr then
      pos = 1
      while pos + 8 <= #big_hdr do
        local ck_id = big_hdr:sub(pos, pos + 3)
        local b1, b2, b3, b4 = big_hdr:byte(pos + 4, pos + 7)
        local ck_sz = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216

        if ck_id == "fmt " and not sr and pos + 8 + 15 <= #big_hdr then
          local fmt_off = pos + 8
          local a1, a2 = big_hdr:byte(fmt_off + 2, fmt_off + 3)
          nch = a1 + a2 * 256
          local s1, s2, s3, s4 = big_hdr:byte(fmt_off + 4, fmt_off + 7)
          sr = s1 + s2 * 256 + s3 * 65536 + s4 * 16777216
          local d1, d2 = big_hdr:byte(fmt_off + 14, fmt_off + 15)
          bps = d1 + d2 * 256
        elseif ck_id == "data" then
          data_offset = 12 + pos + 8 - 1  -- 12 for RIFF header offset
          data_size = ck_sz
          break
        end

        pos = pos + 8 + ck_sz + (ck_sz % 2)
      end
    end
  end

  if not sr or sr <= 0 or not bps or (bps ~= 16 and bps ~= 24)
     or not nch or nch <= 0 or not data_offset or not data_size then
    f:close()
    return nil, "cannot parse WAV header"
  end

  local bytes_per_sample = bps / 8
  local frame_size = bytes_per_sample * nch
  local total_frames = math.floor(data_size / frame_size)
  if total_frames == 0 then f:close(); return nil, "no audio frames" end
  local original_duration = total_frames / sr

  local threshold_linear = 10 ^ (threshold_db / 20.0)

  -- For files >1s, only scan first/last 10% of frames
  local scan_frames = total_frames
  if original_duration > 1.0 then
    scan_frames = math.ceil(total_frames * 0.1)
  end
  -- Cap scan buffer at 2MB to avoid huge allocations on long files
  local max_scan_bytes = 2 * 1024 * 1024
  local scan_bytes = scan_frames * frame_size
  if scan_bytes > max_scan_bytes then
    scan_frames = math.floor(max_scan_bytes / frame_size)
    scan_bytes = scan_frames * frame_size
  end

  local trim_start_frames = 0
  local trim_end_frames = total_frames

  -- Leading scan: bulk read + scan buffer
  if trim_mode == "leading" or trim_mode == "both" then
    f:seek("set", data_offset)
    local buf = f:read(scan_bytes)
    if buf then
      local idx = _scan_buf_leading(buf, frame_size, bps, nch, bytes_per_sample, threshold_linear)
      if idx then
        trim_start_frames = idx
      else
        trim_start_frames = scan_frames  -- entire scan region is silent
      end
    end
  end

  -- Trailing scan: bulk read from end + scan buffer backwards
  if trim_mode == "trailing" or trim_mode == "both" then
    local trail_offset = data_offset + math.max(0, total_frames - scan_frames) * frame_size
    f:seek("set", trail_offset)
    local buf = f:read(scan_bytes)
    if buf then
      local idx = _scan_buf_trailing(buf, frame_size, bps, nch, bytes_per_sample, threshold_linear)
      if idx then
        trim_end_frames = math.max(0, total_frames - scan_frames) + idx + 1
      else
        trim_end_frames = math.max(0, total_frames - scan_frames)
      end
    end
  end

  f:close()

  -- Clamp: if silence spans entire file, return full duration untrimmed
  if trim_start_frames >= trim_end_frames then
    trim_start_frames = 0
    trim_end_frames = total_frames
  end

  local trim_start_sec = trim_start_frames / sr
  local trim_end_sec = trim_end_frames / sr
  return {
    trim_start_sec   = trim_start_sec,
    trim_end_sec     = trim_end_sec,
    trimmed_duration = trim_end_sec - trim_start_sec,
    original_duration = original_duration,
  }
end

-- Apply a linear fade-out to the last fade_frames frames of raw PCM data.
-- Returns a new string with the fade applied. Supports 16-bit and 24-bit.
function wav_io.apply_fade_out(pcm_bytes, bps, nch, fade_frames)
  local bytes_per_sample = bps / 8
  local frame_size = bytes_per_sample * nch
  local total_frames = math.floor(#pcm_bytes / frame_size)

  local actual_fade = math.min(fade_frames, total_frames)
  if actual_fade <= 0 then return pcm_bytes end

  local fade_start = total_frames - actual_fade
  local prefix_bytes = fade_start * frame_size
  local parts = { pcm_bytes:sub(1, prefix_bytes) }

  for i = 0, actual_fade - 1 do
    local gain = 1.0 - (i / actual_fade)
    local frame_offset = prefix_bytes + i * frame_size
    for c = 0, nch - 1 do
      local sample_offset = frame_offset + c * bytes_per_sample + 1
      local sample = _unpack_sample(pcm_bytes, sample_offset, bps)
      parts[#parts + 1] = _pack_sample(sample * gain, bps)
    end
  end

  return table.concat(parts)
end

-- Public exports for PCM utility functions (used by Slice Mini, Alloy Merge)
wav_io.le2_write = function(n)
  return string.char(n & 0xFF, (n >> 8) & 0xFF)
end
wav_io.le4_write = _le4_write
wav_io.unpack_sample = _unpack_sample
wav_io.pack_sample = _pack_sample

return wav_io
