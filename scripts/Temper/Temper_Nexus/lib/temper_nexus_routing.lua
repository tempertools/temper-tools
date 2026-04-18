-- temper_nexus_routing.lua — REAPER routing API wrapper for Temper Nexus.
-- All send/receive/HW-out API calls go through this module.
--
-- Pure math (bit encoding, vol/pan formatters) lives in temper_routing_math.lua
-- so it can be unit-tested without a live REAPER. This module re-exports
-- those names so existing callers don't need to know the split.
local M = {}

local r = reaper

-- Resolve routing math as a sibling file so deployed and dev layouts both work.
local _script_path = debug.getinfo(1, "S").source:sub(2)
local _lib_dir     = (_script_path:match("^(.*)[\\/]") or ".") .. "/"
local math_mod     = dofile(_lib_dir .. "temper_routing_math.lua")

-- Category constants (matches REAPER TrackSendInfo convention)
M.CAT_RECEIVES = -1
M.CAT_SENDS    =  0
M.CAT_HW_OUTS  =  1

-- Send mode labels and cycle order
M.MODE_LABELS = { [0] = "Post", [1] = "Pre-FX", [3] = "Post-FX" }
M.MODE_CYCLE  = { [0] = 1, [1] = 3, [3] = 0 }

-------------------------------------------------------------------------------
-- Re-exports from temper_routing_math (pure, unit-testable)
-------------------------------------------------------------------------------
M.decode_src_channels = math_mod.decode_src_channels
M.encode_src_channels = math_mod.encode_src_channels
M.decode_dst_channels = math_mod.decode_dst_channels
M.encode_dst_channels = math_mod.encode_dst_channels
M.vol_to_db           = math_mod.vol_to_db
M.db_to_vol           = math_mod.db_to_vol
M.format_pan          = math_mod.format_pan


-------------------------------------------------------------------------------
-- Send descriptor builder (private)
-------------------------------------------------------------------------------

local function _G(track, cat, idx, key)
  return r.GetTrackSendInfo_Value(track, cat, idx, key)
end

local function _build_descriptor(track, cat, idx)
  local dest_track, dest_name, dest_guid, dest_index
  local cur_nchan = math.floor(r.GetMediaTrackInfo_Value(track, "I_NCHAN"))

  if cat == M.CAT_HW_OUTS then
    dest_track = nil
    dest_name  = "HW Out"
    dest_guid  = "hw_" .. math.floor(_G(track, cat, idx, "I_DSTCHAN"))
    dest_index = nil
  else
    local parm  = (cat == M.CAT_SENDS) and "P_DESTTRACK" or "P_SRCTRACK"
    dest_track  = r.GetTrackSendInfo_Value(track, cat, idx, parm)
    if dest_track and r.ValidatePtr(dest_track, "MediaTrack*") then
      local _, name = r.GetSetMediaTrackInfo_String(dest_track, "P_NAME", "", false)
      dest_name  = name or ""
      dest_guid  = r.GetTrackGUID(dest_track)
      dest_index = math.floor(r.GetMediaTrackInfo_Value(dest_track, "IP_TRACKNUMBER"))
    else
      dest_name  = ""
      dest_guid  = ""
      dest_index = nil
    end
  end

  -- Canonical source/destination channel-count bounds per category.
  -- I_SRCCHAN and I_DSTCHAN mean different things in each mode:
  --   Sends:    src = current track,     dst = dest_track (P_DESTTRACK)
  --   Receives: src = dest_track (P_SRCTRACK),  dst = current track
  --   HW outs:  src = current track,     dst = hardware outputs
  local src_max_nchan, dst_max_nchan
  if cat == M.CAT_SENDS then
    src_max_nchan = cur_nchan
    dst_max_nchan = (dest_track and r.ValidatePtr(dest_track, "MediaTrack*"))
      and math.floor(r.GetMediaTrackInfo_Value(dest_track, "I_NCHAN")) or 2
  elseif cat == M.CAT_RECEIVES then
    src_max_nchan = (dest_track and r.ValidatePtr(dest_track, "MediaTrack*"))
      and math.floor(r.GetMediaTrackInfo_Value(dest_track, "I_NCHAN")) or 2
    dst_max_nchan = cur_nchan
  else -- HW outs
    src_max_nchan = cur_nchan
    dst_max_nchan = r.GetNumAudioOutputs()
  end

  return {
    idx      = idx,
    category = cat,
    vol      = _G(track, cat, idx, "D_VOL"),
    pan      = _G(track, cat, idx, "D_PAN"),
    mute     = _G(track, cat, idx, "B_MUTE") == 1,
    phase    = _G(track, cat, idx, "B_PHASE") == 1,
    mono     = _G(track, cat, idx, "B_MONO") == 1,
    mode     = math.floor(_G(track, cat, idx, "I_SENDMODE")),
    src_chan  = math.floor(_G(track, cat, idx, "I_SRCCHAN")),
    dst_chan  = math.floor(_G(track, cat, idx, "I_DSTCHAN")),
    dest_track = dest_track,
    dest_name  = dest_name,
    dest_guid  = dest_guid,
    dest_index = dest_index,
    src_max_nchan = src_max_nchan,
    dst_max_nchan = dst_max_nchan,
  }
end

-------------------------------------------------------------------------------
-- Enumeration
-------------------------------------------------------------------------------

local function _enumerate(track, cat)
  local n = r.GetTrackNumSends(track, cat)
  local out = {}
  for i = 0, n - 1 do
    out[#out + 1] = _build_descriptor(track, cat, i)
  end
  return out
end

function M.get_sends(track)    return _enumerate(track, M.CAT_SENDS)    end
function M.get_receives(track) return _enumerate(track, M.CAT_RECEIVES) end
function M.get_hw_outs(track)  return _enumerate(track, M.CAT_HW_OUTS)  end

--- Get parent/master send info for a track.
function M.get_parent(track)
  local parent = r.GetParentTrack(track) or r.GetMasterTrack(0)
  local dest_nchan = parent and math.floor(r.GetMediaTrackInfo_Value(parent, "I_NCHAN")) or 2
  return {
    enabled    = r.GetMediaTrackInfo_Value(track, "B_MAINSEND") == 1,
    vol        = r.GetMediaTrackInfo_Value(track, "D_VOL"),
    pan        = r.GetMediaTrackInfo_Value(track, "D_PAN"),
    ch_offset  = math.floor(r.GetMediaTrackInfo_Value(track, "C_MAINSEND_OFFS")),
    nchan_send = math.floor(r.GetMediaTrackInfo_Value(track, "C_MAINSEND_NCH")),
    dest_nchan = dest_nchan,
  }
end

-------------------------------------------------------------------------------
-- Mutation
-------------------------------------------------------------------------------

function M.create_send(src, dest)
  return r.CreateTrackSend(src, dest)
end

function M.remove_send(track, cat, idx)
  return r.RemoveTrackSend(track, cat, idx)
end

function M.set_prop(track, cat, idx, key, value)
  return r.SetTrackSendInfo_Value(track, cat, idx, key, value)
end

function M.set_parent_enabled(track, enabled)
  r.SetMediaTrackInfo_Value(track, "B_MAINSEND", enabled and 1 or 0)
end

function M.set_parent_vol(track, vol)
  r.SetMediaTrackInfo_Value(track, "D_VOL", vol)
end

function M.set_parent_pan(track, pan)
  r.SetMediaTrackInfo_Value(track, "D_PAN", pan)
end

function M.set_parent_ch_offset(track, offset)
  r.SetMediaTrackInfo_Value(track, "C_MAINSEND_OFFS", offset)
end

function M.set_parent_nchan(track, nchan)
  r.SetMediaTrackInfo_Value(track, "C_MAINSEND_NCH", nchan)
end

-------------------------------------------------------------------------------
-- Track info helpers
-------------------------------------------------------------------------------

function M.get_track_name(track)
  local _, name = r.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
  return name or ""
end

function M.get_track_nchan(track)
  return math.floor(r.GetMediaTrackInfo_Value(track, "I_NCHAN"))
end

function M.set_track_nchan(track, nchan)
  r.SetMediaTrackInfo_Value(track, "I_NCHAN", nchan)
end

function M.get_track_index(track)
  return math.floor(r.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER"))
end

function M.get_all_tracks()
  local n   = r.CountTracks(0)
  local out = {}
  for i = 0, n - 1 do
    local tr = r.GetTrack(0, i)
    out[#out + 1] = {
      ptr   = tr,
      guid  = r.GetTrackGUID(tr),
      name  = M.get_track_name(tr),
      nchan = M.get_track_nchan(tr),
      index = i + 1,
    }
  end
  return out
end

return M
