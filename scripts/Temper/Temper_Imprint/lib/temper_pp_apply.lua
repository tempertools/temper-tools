-- temper_pp_apply.lua — Item property snapshot application via state-chunk surgery
-- Shared library for Temper scripts (Vortex, Vortex Mini, etc.)
--
-- Two-part API:
--   1. Module-level chunk helpers (always available after dofile):
--        local pp_mod = dofile(_lib .. "temper_pp_apply.lua")
--        pp_mod.extract_block(chunk, "TAKEFX")
--        pp_mod.find_take_block(chunk, 0)
--
--   2. Factory for property application (call to configure):
--        local _pp = pp_mod.create(take_props, item_props, trim_fn)
--        _pp.apply_to_item(item, take_idx, snapshot)

-- ============================================================
-- Module-level chunk-surgery helpers
-- ============================================================

local function _pp_is_ws(c)
  return c == "\n" or c == "\r" or c == " " or c == "\t"
end

--- Extract the first <TAG ...> block from a state chunk (nesting-aware).
--- Returns the block as a string (including opening/closing tags), or "".
local function _chunk_extract_block(chunk, tag)
  local search = "<" .. tag
  local pos = 1
  while pos <= #chunk do
    local s = chunk:find(search, pos, true)
    if not s then return "" end
    local c = chunk:sub(s + #search, s + #search)
    if _pp_is_ws(c) then
      local depth, j = 1, s + 1
      while j <= #chunk and depth > 0 do
        local ch = chunk:sub(j, j)
        if ch == "<" then depth = depth + 1
        elseif ch == ">" then depth = depth - 1 end
        j = j + 1
      end
      return chunk:sub(s, j - 1)
    end
    pos = s + 1
  end
  return ""
end

--- Return the nth <TAKE ...> block from a state chunk (0-based), or nil.
local function _take_block_in_chunk(chunk, take_idx)
  local count, pos = 0, 1
  while pos <= #chunk do
    local s = chunk:find("<TAKE", pos, true)
    if not s then return nil end
    if _pp_is_ws(chunk:sub(s + 5, s + 5)) then
      if count == take_idx then
        local depth, j = 1, s + 1
        while j <= #chunk and depth > 0 do
          local ch = chunk:sub(j, j)
          if ch == "<" then depth = depth + 1
          elseif ch == ">" then depth = depth - 1 end
          j = j + 1
        end
        return chunk:sub(s, j - 1)
      end
      count = count + 1
    end
    pos = s + 1
  end
  return nil
end

-- ============================================================
-- Factory: property application
-- ============================================================

local function _create_pp(take_props, item_props, trim_item_to_max)

-- Return (start, end) indices of the nth <TAKE ...> block (0-based).
local function _pp_find_take_block(chunk, n)
  local count, i = 0, 1
  while true do
    local s = chunk:find("<TAKE", i, true)
    if not s then return nil end
    if _pp_is_ws(chunk:sub(s + 5, s + 5)) then
      if count == n then
        local depth, j = 1, s + 1
        while j <= #chunk and depth > 0 do
          local c = chunk:sub(j, j)
          if c == "<" then depth = depth + 1
          elseif c == ">" then depth = depth - 1 end
          j = j + 1
        end
        return s, j - 1
      end
      count = count + 1
    end
    i = s + 1
  end
end

-- Remove first <TAG ...> block from chunk (nesting-aware, preceding newline included).
local function _pp_remove_block(chunk, tag)
  local search = "<" .. tag
  local pos = 1
  while true do
    local s = chunk:find(search, pos, true)
    if not s then return chunk end
    if _pp_is_ws(chunk:sub(s + #search, s + #search)) then
      local pre = s - 1
      while pre >= 1 and (chunk:sub(pre, pre) == " " or chunk:sub(pre, pre) == "\t") do
        pre = pre - 1
      end
      if pre >= 1 and chunk:sub(pre, pre) == "\n" then pre = pre - 1 end
      if pre >= 1 and chunk:sub(pre, pre) == "\r" then pre = pre - 1 end
      local depth, i2 = 1, s + 1
      while i2 <= #chunk and depth > 0 do
        local c = chunk:sub(i2, i2)
        if c == "<" then depth = depth + 1
        elseif c == ">" then depth = depth - 1 end
        i2 = i2 + 1
      end
      if chunk:sub(i2, i2) == "\r" then i2 = i2 + 1 end
      if chunk:sub(i2, i2) == "\n" then i2 = i2 + 1 end
      return chunk:sub(1, pre) .. chunk:sub(i2)
    end
    pos = s + 1
  end
end

local _PP_TAKEFX_HEADER = { WNDRECT = true, SHOW = true, LASTSEL = true, DOCKED = true }

-- Extract plugin payload from a <TAKEFX> chunk (strips header metadata lines).
local function _pp_takefx_payload(fx_chunk)
  local lines, line_n, depth = {}, 0, 0
  for line in (fx_chunk .. "\n"):gmatch("([^\n]*)\n") do
    line_n = line_n + 1
    if line_n > 1 then
      local trimmed = line:match("^%s*(.-)%s*$")
      if trimmed == ">" and depth == 0 then break end
      if    trimmed:sub(1, 1) == "<" then depth = depth + 1
      elseif trimmed == ">"           then depth = depth - 1 end
      local key = trimmed:match("^(%S+)")
      if depth > 0 or not _PP_TAKEFX_HEADER[key] then
        lines[#lines + 1] = line
      end
    end
  end
  while #lines > 0 and lines[#lines]:match("^%s*$") do table.remove(lines) end
  return table.concat(lines, "\n")
end

-- Inject fx_chunk into an item via state-chunk surgery (appends to existing chain).
local function _pp_apply_takefx(item, take_idx, fx_chunk)
  if fx_chunk == "" then return false end
  local ok, item_chunk = reaper.GetItemStateChunk(item, "", false)
  if not ok or item_chunk == "" then return false end
  local t_s, t_e = _pp_find_take_block(item_chunk, take_idx)
  local container, c_s, c_e
  if t_s then
    container, c_s, c_e = item_chunk:sub(t_s, t_e), t_s, t_e
  else
    container, c_s, c_e = item_chunk, 1, #item_chunk
  end
  local existing_fx, spos = "", 1
  while true do
    local s = container:find("<TAKEFX", spos, true)
    if not s then break end
    if _pp_is_ws(container:sub(s + 7, s + 7)) then
      local depth, j = 1, s + 1
      while j <= #container and depth > 0 do
        local c = container:sub(j, j)
        if c == "<" then depth = depth + 1
        elseif c == ">" then depth = depth - 1 end
        j = j + 1
      end
      existing_fx = container:sub(s, j - 1):gsub("%s+$", "")
      break
    end
    spos = s + 1
  end
  local final_fx
  if existing_fx ~= "" then
    local payload = _pp_takefx_payload(fx_chunk)
    if payload == "" then return false end
    local trimmed   = existing_fx:gsub("%s+$", "")
    local close_pos = trimmed:match("^.*()\n>$")
    if not close_pos then return false end
    final_fx = trimmed:sub(1, close_pos) .. "\n" .. payload .. "\n>"
  else
    final_fx = fx_chunk:gsub("%s+$", "")
  end
  container = _pp_remove_block(container, "TAKEFX"):gsub("%s+$", "")
  -- Backward-scan for the container's closing '>'. Cannot rely on '\n>'
  -- because _pp_remove_block eats the newlines on both sides of the removed
  -- block, producing adjacent '>>' when TAKEFX was wedged between two blocks.
  local cp = #container
  while cp > 1 and container:sub(cp, cp) ~= ">" do cp = cp - 1 end
  if cp <= 1 then return false end
  local new_container = container:sub(1, cp - 1) .. "\n" .. final_fx .. "\n>"
  local new_chunk     = item_chunk:sub(1, c_s - 1) .. new_container .. item_chunk:sub(c_e + 1)
  return reaper.SetItemStateChunk(item, new_chunk, false)
end

-- Return the 0-based index of the active take within item.
local function _pp_active_take_idx(item)
  local active = reaper.GetActiveTake(item)
  if not active then return 0 end
  local n = reaper.GetMediaItemNumTakes(item)
  for i = 0, n - 1 do
    if reaper.GetMediaItemTake(item, i) == active then return i end
  end
  return 0
end

-- Extract the tag name from the first line of an envelope state chunk (e.g. "VOLENV2").
local function _pp_get_chunk_key(chunk)
  return chunk:match("^<(%S+)")
end

-- Scale envelope point times by dst_len/src_len ratio.
-- Rewrites PT lines: "PT <time> ..." -> "PT <scaled_time> ..."
local function _pp_scale_env_chunk(chunk, src_len, dst_len)
  if not src_len or src_len <= 0 or not dst_len or dst_len <= 0 then return chunk end
  if math.abs(src_len - dst_len) < 0.001 then return chunk end
  local ratio = dst_len / src_len
  return chunk:gsub("(PT )([%d%.%-e]+)", function(prefix, time_str)
    local t = tonumber(time_str)
    if t then return prefix .. string.format("%.10f", t * ratio) end
    return prefix .. time_str
  end)
end

-- Inject env_chunk into the target take via state-chunk surgery.
-- Works for both multi-take (<TAKE> wrapper) and flat single-take items (no wrapper).
local function _pp_apply_take_env(item, take_idx, env_chunk)
  if env_chunk == "" then return false end
  local env_key = _pp_get_chunk_key(env_chunk)
  if not env_key then return false end
  local ok, item_chunk = reaper.GetItemStateChunk(item, "", false)
  if not ok or item_chunk == "" then return false end
  local t_s, t_e = _pp_find_take_block(item_chunk, take_idx)
  local container, c_s, c_e
  if t_s then
    container, c_s, c_e = item_chunk:sub(t_s, t_e), t_s, t_e
  else
    container, c_s, c_e = item_chunk, 1, #item_chunk
  end
  container   = _pp_remove_block(container, env_key)
  local clean = env_chunk:gsub("%s+$", "")
  local src_pos = container:find("\n<SOURCE", 1, true)
  local new_container
  if src_pos then
    new_container = container:sub(1, src_pos) .. clean .. "\n" .. container:sub(src_pos + 1)
  else
    local cp = #container
    while cp > 1 and container:sub(cp, cp) ~= ">" do cp = cp - 1 end
    if cp <= 1 then return false end
    new_container = container:sub(1, cp - 1) .. "\n" .. clean .. "\n>"
  end
  local new_chunk = item_chunk:sub(1, c_s - 1) .. new_container .. item_chunk:sub(c_e + 1)
  return reaper.SetItemStateChunk(item, new_chunk, false)
end

-- Apply multiple envelope chunks in a single state-chunk pass.
-- env_list: array of {chunk = "...", src_len = number|nil}
local function _pp_apply_take_envs_batched(item, take_idx, env_list)
  if #env_list == 0 then return false end
  local ok, item_chunk = reaper.GetItemStateChunk(item, "", false)
  if not ok or item_chunk == "" then return false end

  local t_s, t_e = _pp_find_take_block(item_chunk, take_idx)
  local container, c_s, c_e
  if t_s then
    container, c_s, c_e = item_chunk:sub(t_s, t_e), t_s, t_e
  else
    container, c_s, c_e = item_chunk, 1, #item_chunk
  end

  local dst_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

  for _, entry in ipairs(env_list) do
    local env_key = _pp_get_chunk_key(entry.chunk)
    if env_key then
      container = _pp_remove_block(container, env_key)
      local clean = entry.chunk:gsub("%s+$", "")
      clean = _pp_scale_env_chunk(clean, entry.src_len, dst_len)

      local src_pos = container:find("\n<SOURCE", 1, true)
      if src_pos then
        container = container:sub(1, src_pos) .. clean .. "\n" .. container:sub(src_pos + 1)
      else
        local cp = #container
        while cp > 1 and container:sub(cp, cp) ~= ">" do cp = cp - 1 end
        if cp > 1 then
          container = container:sub(1, cp - 1) .. "\n" .. clean .. "\n>"
        end
      end
    end
  end

  local new_chunk = item_chunk:sub(1, c_s - 1) .. container .. item_chunk:sub(c_e + 1)
  return reaper.SetItemStateChunk(item, new_chunk, false)
end

-- ============================================================
-- _pp_apply_to_item — apply a property snapshot to one placed item
-- ============================================================

-- Apply the snapshot to a single newly-placed item.
-- Position and length are intentionally NOT overwritten.
-- @param snapshot   table   Property snapshot from _pp_capture (or equivalent)
-- @param item       MediaItem*
-- @param track_guid string  GUID of the item's track
local function _pp_apply_to_item(snapshot, item, track_guid)
  if not snapshot then return end
  local slot = snapshot.tracks[track_guid]
  if not slot then return end
  local take     = reaper.GetActiveTake(item)
  local take_idx = _pp_active_take_idx(item)
  local env_batch = {}
  for _, p in ipairs(take_props) do
    if snapshot.enabled[p.key] and slot.props[p.key] then
      if p.is_envelope then
        env_batch[#env_batch + 1] = { chunk = slot.props[p.key], src_len = snapshot.source_length }
      elseif take then
        if p.is_string then
          reaper.GetSetMediaItemTakeInfo_String(take, p.parmname, slot.props[p.key], true)
        else
          local v = tonumber(slot.props[p.key])
          if v then reaper.SetMediaItemTakeInfo_Value(take, p.parmname, v) end
        end
      end
    end
  end
  if #env_batch > 0 then
    _pp_apply_take_envs_batched(item, take_idx, env_batch)
  end
  for _, p in ipairs(item_props) do
    if snapshot.enabled[p.key] and slot.props[p.key] then
      local v = tonumber(slot.props[p.key])
      if v then reaper.SetMediaItemInfo_Value(item, p.parmname, v) end
    end
  end
  -- Cap item to the captured reference length so files without cue markers
  -- don't bloat to their full source duration.
  if snapshot.enabled["i_len"] and slot.props["i_len"] then
    local ref_len = tonumber(slot.props["i_len"])
    if ref_len and ref_len > 0 then
      trim_item_to_max(item, ref_len)
    end
  end
  -- Clamp fade lengths so they never exceed item length (prevents "all fade" on short files).
  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local fi_len   = reaper.GetMediaItemInfo_Value(item, "D_FADEINLEN")
  local fo_len   = reaper.GetMediaItemInfo_Value(item, "D_FADEOUTLEN")
  if item_len > 0 and (fi_len + fo_len) > item_len then
    local scale = item_len / (fi_len + fo_len)
    reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN",  fi_len * scale)
    reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", fo_len * scale)
  end
  if snapshot.enabled["i_fx"] and slot.fx_chunk ~= "" then
    -- Skip FX re-application when target IS the source item. Appending a copy
    -- of the source's own FX to itself produces duplicate FXID entries, which
    -- REAPER's state-chunk parser does not tolerate — resulting in the source
    -- appearing to lose its FX entirely.
    local skip = false
    if snapshot.source_item_guid then
      local _, target_guid = reaper.GetSetMediaItemInfo_String(item, "GUID", "", false)
      if target_guid == snapshot.source_item_guid then skip = true end
    end
    if not skip then
      _pp_apply_takefx(item, take_idx, slot.fx_chunk)
    end
  end
end

return {
  apply_to_item = _pp_apply_to_item,
}

end  -- _create_pp

-- ============================================================
-- Module return: chunk helpers + factory
-- ============================================================

return {
  extract_block      = _chunk_extract_block,
  take_block         = _take_block_in_chunk,
  create             = _create_pp,
}
