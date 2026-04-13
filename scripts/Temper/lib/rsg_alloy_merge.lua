-- rsg_alloy_merge.lua -- Variant grouping and merge planning for Temper Alloy
-- Groups WAV files by naming pattern, validates format consistency,
-- and plans concatenation into merged output files.
-- No external dependencies beyond REAPER API (for format validation and duration).
--
-- Usage:
--   local merge = dofile(reaper.GetResourcePath() .. "/Scripts/Temper/lib/rsg_alloy_merge.lua")
--   local groups = merge.group_variants(file_list)
--   local ok, fmt = merge.validate_format(groups[1].files)
--   local plan = merge.plan_concat(groups[1], 30, 300)

local merge = {}

-- Local helpers for binary uint32 LE parsing/writing
local function _le4(b)
  return b:byte(1) + b:byte(2) * 256 + b:byte(3) * 65536 + b:byte(4) * 16777216
end

--- Parse a filename stem for a trailing numeric variant suffix.
-- Pattern: base + separator ("_", "-", or ".") + digits at end of stem.
-- Uses greedy .+ so the LAST separator before trailing digits wins.
-- @param stem string Filename without extension
-- @return base, sep, number_str on match; nil on no match
function merge.parse_variant_suffix(stem)
  if not stem or stem == "" then return nil end
  local base, sep, num = stem:match("^(.+)([_.%-])(%d+)$")
  if base and base ~= "" then
    return base, sep, num
  end
  return nil
end

--- Group files by variant naming pattern.
-- Files sharing the same folder + base name + separator are grouped together.
-- Groups with fewer than 2 files are discarded.
-- @param file_list table List of {path=string, stem=string, folder=string}
-- @return table List of group tables sorted by key
function merge.group_variants(file_list)
  if not file_list or #file_list == 0 then return {} end

  local groups_by_key = {}

  for _, file in ipairs(file_list) do
    local base, sep, num_str = merge.parse_variant_suffix(file.stem)
    if base then
      local key = file.folder .. "|" .. base .. "|" .. sep
      if not groups_by_key[key] then
        groups_by_key[key] = {
          key = key,
          base = base,
          sep = sep,
          folder = file.folder,
          files = {},
        }
      end
      local entry = {
        path = file.path,
        stem = file.stem,
        folder = file.folder,
        num = tonumber(num_str),
      }
      table.insert(groups_by_key[key].files, entry)
    end
  end

  -- Collect groups with 2+ files, sort files within each by integer suffix
  local result = {}
  for _, group in pairs(groups_by_key) do
    if #group.files >= 2 then
      table.sort(group.files, function(a, b) return a.num < b.num end)
      table.insert(result, group)
    end
  end

  -- Sort groups alphabetically by key for deterministic ordering
  table.sort(result, function(a, b) return a.key < b.key end)

  return result
end

--- Validate that all files in a group share the same audio format.
-- Uses REAPER PCM_Source API to read sample rate and channels.
-- Bit depth is not checked (REAPER has no GetMediaSourceBitsPerSample API);
-- the output inherits the first file's fmt chunk verbatim.
-- @param files table List of file entries with .path field
-- @return true, format_table on success; false, error_string on mismatch
function merge.validate_format(files)
  if not files or #files == 0 then
    return false, "no files to validate"
  end

  local ref_sr, ref_ch
  local ref_name

  for _, file in ipairs(files) do
    local src = reaper.PCM_Source_CreateFromFile(file.path)
    if not src then
      return false, file.stem .. ": unable to read file"
    end

    local channels = reaper.GetMediaSourceNumChannels(src)
    local sample_rate = reaper.GetMediaSourceSampleRate(src)
    reaper.PCM_Source_Destroy(src)

    if not ref_sr then
      ref_sr = sample_rate
      ref_ch = channels
      ref_name = file.stem
    else
      if sample_rate ~= ref_sr then
        return false, file.stem .. ": sample rate " .. sample_rate .. " != " .. ref_sr
      end
      if channels ~= ref_ch then
        return false, file.stem .. ": channels " .. channels .. " != " .. ref_ch
      end
    end
  end

  return true, {
    sample_rate = ref_sr,
    channels = ref_ch,
  }
end

--- Bin-pack a group's files into merge output plans.
-- Files exceeding max_seg_s are skipped. Remaining files are accumulated
-- into output bins that do not exceed max_merged_s total duration.
-- @param group table A group from group_variants()
-- @param max_seg_s number Maximum single-segment duration in seconds
-- @param max_merged_s number Maximum merged output duration in seconds
-- @return table {outputs={...}, skipped={...}}
function merge.plan_concat(group, max_seg_s, max_merged_s)
  local skipped = {}
  local eligible = {}

  for _, file in ipairs(group.files) do
    if file.oversized then
      table.insert(skipped, { file = file, reason = "exceeds 2 GB limit" })
    else
      local src = reaper.PCM_Source_CreateFromFile(file.path)
      if not src then
        table.insert(skipped, {
          file = file,
          reason = "unable to read file",
        })
      else
        local duration = reaper.GetMediaSourceLength(src)
        reaper.PCM_Source_Destroy(src)

        if duration > max_seg_s then
          table.insert(skipped, {
            file = file,
            reason = string.format("exceeds max segment (%.1fs > %gs)", duration, max_seg_s),
          })
        else
          table.insert(eligible, { file = file, duration = duration })
        end
      end
    end
  end

  -- Bin-pack eligible files into outputs
  local outputs = {}
  local current_files = {}
  local current_duration = 0

  for _, entry in ipairs(eligible) do
    if #current_files > 0 and current_duration + entry.duration > max_merged_s then
      table.insert(outputs, { files = current_files, total_duration = current_duration })
      current_files = {}
      current_duration = 0
    end
    table.insert(current_files, entry.file)
    current_duration = current_duration + entry.duration
  end

  if #current_files > 0 then
    table.insert(outputs, { files = current_files, total_duration = current_duration })
  end

  -- Assign output names
  local base = group.base
  local sep = group.sep

  if #outputs == 1 then
    outputs[1].output_name = base .. ".wav"
  else
    for i, output in ipairs(outputs) do
      output.output_name = base .. sep .. tostring(i) .. ".wav"
    end
  end

  -- Conflict check: if an output stem matches a source stem, append _m
  local source_stems = {}
  for _, f in ipairs(group.files) do source_stems[f.stem or ""] = true end
  for _, output in ipairs(outputs) do
    local stem = output.output_name:match("^(.+)%.wav$")
    if source_stems[stem] then
      output.output_name = stem .. "_m.wav"
    end
  end

  return {
    outputs = outputs,
    skipped = skipped,
  }
end

-- ============================================================
-- Merge execution engine
-- ============================================================

--- Initialize merge state for one output group.
-- Uses a _start/_tick/_finalize pattern for non-blocking processing.
-- @param plan_output table One entry from plan_concat().outputs
-- @param output_dir string Target directory path
-- @param mode string "folder" or "inplace"
-- @param wav_io table The rsg_wav_io module
-- @param trim_data table|nil Optional {[path]={trim_start_sec=N, trim_end_sec=N}}
-- @return merge_state table on success, or nil + error_msg on failure
function merge.merge_begin(plan_output, output_dir, mode, wav_io, trim_data)
  -- Determine final output path
  local final_path
  if mode == "inplace" then
    final_path = plan_output.files[1].folder .. "/" .. plan_output.output_name
  else
    final_path = output_dir .. "/" .. plan_output.output_name
  end

  -- Determine temp file directory
  local temp_dir = (mode == "inplace") and plan_output.files[1].folder or output_dir
  local temp_path = temp_dir .. "/.tmp_alloy_" .. os.time() .. ".wav"

  local fh, err = io.open(temp_path, "w+b")
  if not fh then
    return nil, "failed to open temp file: " .. tostring(err)
  end

  local riff_size_offset = wav_io.write_riff_header(fh)

  local fmt_data = wav_io.read_fmt_raw(plan_output.files[1].path)
  if not fmt_data then
    fh:close()
    os.remove(temp_path)
    return nil, "failed to read fmt from first source"
  end

  wav_io.write_fmt_chunk(fh, fmt_data)
  local data_size_offset = wav_io.write_data_header(fh)

  -- Parse format info from raw fmt bytes
  local channels = fmt_data:byte(3) + fmt_data:byte(4) * 256
  local sample_rate = fmt_data:byte(5) + fmt_data:byte(6) * 256
                    + fmt_data:byte(7) * 65536 + fmt_data:byte(8) * 16777216
  local bits_per_sample = fmt_data:byte(15) + fmt_data:byte(16) * 256
  local bytes_per_frame = channels * (bits_per_sample / 8)

  local ms = {
    fh = fh,
    temp_path = temp_path,
    final_path = final_path,
    wav_io = wav_io,
    files = plan_output.files,
    file_idx = 1,
    source_fh = nil,
    source_data_remaining = 0,
    cumulative_frames = 0,
    data_bytes = 0,
    cue_points = {},
    riff_size_offset = riff_size_offset,
    data_size_offset = data_size_offset,
    first_source_path = plan_output.files[1].path,
    block_size = 65536,
    bytes_written_total = 0,
    bytes_planned_total = 0,
    format = {
      channels = channels,
      sample_rate = sample_rate,
      bits_per_sample = bits_per_sample,
      bytes_per_frame = bytes_per_frame,
    },
  }

  -- Pre-compute per-file trim info and total planned bytes
  for _, file in ipairs(ms.files) do
    local trim = trim_data and trim_data[file.path]
    if trim and trim.trim_start_sec then
      file.trim_start_bytes = math.floor(trim.trim_start_sec * sample_rate) * bytes_per_frame
    else
      file.trim_start_bytes = 0
    end
    if trim and trim.trim_end_sec then
      file.trim_end_bytes = math.floor(trim.trim_end_sec * sample_rate) * bytes_per_frame
    else
      file.trim_end_bytes = 0
    end
    local full_info = wav_io.read_wav_info(file.path)
    local full_data = full_info and full_info.data_size or 0
    local trimmed = full_data - file.trim_start_bytes
    if file.trim_end_bytes > 0 then
      trimmed = math.min(trimmed, file.trim_end_bytes - file.trim_start_bytes)
    end
    file.trimmed_data_size = math.max(0, trimmed)
    ms.bytes_planned_total = ms.bytes_planned_total + file.trimmed_data_size
  end

  return ms
end

--- Scan a binary WAV file handle to the start of the "data" chunk.
-- Assumes file is open in binary mode and positioned at byte 0.
-- @param f file handle
-- @return data_size number, or nil + error_msg
local function _seek_to_data_chunk(f)
  -- Read and skip 12-byte RIFF header
  local hdr = f:read(12)
  if not hdr or #hdr < 12 then
    return nil, "truncated RIFF header"
  end

  while true do
    local id = f:read(4)
    if not id or #id < 4 then
      return nil, "data chunk not found"
    end
    local sb = f:read(4)
    if not sb or #sb < 4 then
      return nil, "truncated chunk size"
    end
    local sz = _le4(sb)

    if id == "data" then
      return sz
    end

    -- Skip to next chunk (word-aligned)
    f:seek("cur", sz + (sz % 2))
  end
end

--- Apply 1ms fade-out to the tail of the output to prevent clicks at segment boundary.
-- @param ms table merge_state
local function _apply_segment_fade(ms)
  local fade_frames = math.ceil(ms.format.sample_rate * 0.001)
  local fade_bytes = fade_frames * ms.format.bytes_per_frame
  if ms.data_bytes < fade_bytes then return end

  local cur_pos = ms.fh:seek("cur")
  ms.fh:seek("set", cur_pos - fade_bytes)
  local tail = ms.fh:read(fade_bytes)
  if tail and #tail == fade_bytes then
    ms.fh:seek("set", cur_pos - fade_bytes)
    local faded = ms.wav_io.apply_fade_out(tail, ms.format.bits_per_sample, ms.format.channels, fade_frames)
    ms.fh:write(faded)
  else
    ms.fh:seek("set", cur_pos)
  end
end

--- Close the current source, apply fade, and advance to next file.
-- @param ms table merge_state
local function _finish_source(ms)
  _apply_segment_fade(ms)
  ms.source_fh:close()
  ms.source_fh = nil
  ms.file_idx = ms.file_idx + 1
end

--- Process N blocks per call. Called each defer frame.
-- @param ms table merge_state from merge_begin
-- @param blocks_per_tick number blocks to process per call (default 16)
-- @return "in_progress" or "pcm_done"
function merge.merge_tick(ms, blocks_per_tick)
  blocks_per_tick = blocks_per_tick or 16

  for _ = 1, blocks_per_tick do
    -- Open next source if none is active
    if not ms.source_fh then
      if ms.file_idx > #ms.files then
        return "pcm_done"
      end

      local file = ms.files[ms.file_idx]
      local sf, err = io.open(file.path, "rb")
      if not sf then
        return nil, "failed to open source: " .. tostring(err)
      end

      local data_size, seek_err = _seek_to_data_chunk(sf)
      if not data_size then
        sf:close()
        return nil, "source " .. file.stem .. ": " .. tostring(seek_err)
      end

      -- Apply trim offsets
      if file.trim_start_bytes > 0 then
        sf:seek("cur", file.trim_start_bytes)
      end
      local remaining = data_size - file.trim_start_bytes
      if file.trim_end_bytes > 0 then
        remaining = math.min(remaining, file.trim_end_bytes - file.trim_start_bytes)
      end

      ms.source_fh = sf
      ms.source_data_remaining = math.max(0, remaining)

      -- Record cue point
      if ms.file_idx == 1 then
        ms.cue_points[#ms.cue_points + 1] = {
          offset = 0,
          label = ms.files[1].stem,
        }
      else
        ms.cue_points[#ms.cue_points + 1] = {
          offset = ms.cumulative_frames,
          label = ms.files[ms.file_idx].stem,
        }
      end
    end

    -- Read a block from current source
    local bytes_to_read = math.min(ms.block_size, ms.source_data_remaining)
    if bytes_to_read <= 0 then
      _finish_source(ms)
    else
      local data = ms.source_fh:read(bytes_to_read)
      if not data or #data == 0 then
        _finish_source(ms)
      else
        ms.wav_io.write_pcm_block(ms.fh, data)
        ms.data_bytes = ms.data_bytes + #data
        ms.bytes_written_total = ms.bytes_written_total + #data
        ms.source_data_remaining = ms.source_data_remaining - #data
        ms.cumulative_frames = ms.cumulative_frames + (#data / ms.format.bytes_per_frame)

        -- Source exhausted after this read
        if ms.source_data_remaining <= 0 then
          _finish_source(ms)
        end
      end
    end
  end

  -- Check if all sources are exhausted after processing blocks
  if not ms.source_fh and ms.file_idx > #ms.files then
    return "pcm_done"
  end

  return "in_progress"
end

--- Finalize the merge: patch sizes, write metadata chunks, atomic rename.
-- @param ms table merge_state from merge_begin
-- @return true on success, or false + error_msg on failure
function merge.merge_finalize(ms)
  -- Patch data chunk size
  ms.wav_io.patch_uint32_le(ms.fh, ms.data_size_offset, ms.data_bytes)

  -- Seek back to end for appending metadata
  ms.fh:seek("end")

  -- Copy BEXT from first source (reset time_reference to zero)
  local bext_data = ms.wav_io.read_chunk_raw(ms.first_source_path, "bext")
  if bext_data then
    if #bext_data >= 354 then
      bext_data = bext_data:sub(1, 346) .. "\0\0\0\0\0\0\0\0" .. bext_data:sub(355)
    end
    ms.wav_io.write_chunk(ms.fh, "bext", bext_data)
  end

  -- Copy iXML from first source (byte-exact)
  local ixml_data = ms.wav_io.read_chunk_raw(ms.first_source_path, "iXML")
  if ixml_data then
    ms.wav_io.write_chunk(ms.fh, "iXML", ixml_data)
  end

  -- Build and write cue chunk
  if #ms.cue_points > 0 then
    local le4w = ms.wav_io.le4_write
    local parts = { le4w(#ms.cue_points) }
    for i, pt in ipairs(ms.cue_points) do
      parts[#parts + 1] = le4w(i)                       -- dwName (1-based)
      parts[#parts + 1] = le4w(0)                       -- dwPosition
      parts[#parts + 1] = "data"                         -- fccChunk
      parts[#parts + 1] = le4w(0)                       -- dwChunkStart
      parts[#parts + 1] = le4w(0)                       -- dwBlockStart
      parts[#parts + 1] = le4w(math.floor(pt.offset))   -- dwSampleOffset
    end
    ms.wav_io.write_chunk(ms.fh, "cue ", table.concat(parts))
  end

  -- Patch RIFF size
  local total_size = ms.fh:seek("end")
  ms.wav_io.patch_uint32_le(ms.fh, ms.riff_size_offset, total_size - 8)

  ms.fh:close()

  -- Atomic rename (Windows: remove target first since os.rename can't overwrite)
  if jit and jit.os == "Windows" then
    os.remove(ms.final_path)
  end
  local ok, err = os.rename(ms.temp_path, ms.final_path)
  if not ok then
    os.remove(ms.temp_path)
    return false, "rename failed: " .. tostring(err)
  end

  return true
end

--- Delete source files after successful merge.
-- @param files table List of file entries with .path field
-- @return number Count of successfully deleted files
function merge.delete_originals(files)
  local count = 0
  for _, file in ipairs(files) do
    local ok = os.remove(file.path)
    if ok then
      count = count + 1
    end
  end
  return count
end

return merge
