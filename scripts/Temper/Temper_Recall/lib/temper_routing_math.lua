-- temper_routing_math.lua -- Pure math helpers for REAPER send/receive routing.
--
-- Extracted from temper_nexus_routing.lua so the bit-encoding and volume/pan
-- formatters can be unit-tested without a live REAPER context. This module
-- has NO dependency on `reaper` and can be loaded from plain Lua
-- (or LuaJIT, or a test harness subprocess).
--
-- temper_nexus_routing.lua re-exports the same names so existing callers
-- don't need to know the split. The one-way dep is:
--     temper_nexus_routing.lua -> temper_routing_math.lua
--
-- Do not add REAPER API calls to this file.

local M = {}

-------------------------------------------------------------------------------
-- I_SRCCHAN / I_DSTCHAN bit encoding
-------------------------------------------------------------------------------

--- Decode I_SRCCHAN bitfield. Returns offset, channel_count.
--- Special: raw == -1 means "no audio".
--- Code: 0=stereo(2ch), 1=mono(1ch), N>=2 -> N*2 channels
function M.decode_src_channels(raw)
  if raw == -1 then return -1, 0 end
  local offset = raw & 0x3FF          -- low 10 bits
  local code   = (raw >> 10) & 0x3F   -- bits 10+
  local count
  if code == 0 then count = 2
  elseif code == 1 then count = 1
  else count = code * 2
  end
  return offset, count
end

--- Encode I_SRCCHAN from offset and channel count.
function M.encode_src_channels(offset, count)
  if offset == -1 then return -1 end
  local code
  if count == 2 then code = 0
  elseif count == 1 then code = 1
  else code = count // 2
  end
  return offset + (code << 10)
end

--- Decode I_DSTCHAN. Returns offset, mono flag.
function M.decode_dst_channels(raw)
  local mono   = (raw & 1024) ~= 0
  local offset = raw & 0x3FF
  return offset, mono
end

--- Encode I_DSTCHAN from offset and mono flag.
function M.encode_dst_channels(offset, mono)
  return offset + (mono and 1024 or 0)
end

-------------------------------------------------------------------------------
-- Volume / pan formatting
-------------------------------------------------------------------------------

local _LOG10 = math.log(10)

--- Convert linear volume to dB string ("+0.0", "-6.0", "-inf").
function M.vol_to_db(linear)
  if linear <= 0 then return "-inf" end
  local db = 20 * math.log(linear) / _LOG10
  if db > 0 then
    return string.format("+%.1f", db)
  end
  return string.format("%.1f", db)
end

--- Convert dB to linear float.
function M.db_to_vol(db)
  return 10 ^ (db / 20)
end

--- Format pan value to "C" / "L50" / "R50".
function M.format_pan(pan_val)
  if math.abs(pan_val) < 0.005 then return "C" end
  local pct = math.floor(math.abs(pan_val) * 100 + 0.5)
  return (pan_val < 0 and "L" or "R") .. pct
end

return M
