-- temper_track_utils.lua — REAPER track utility functions
-- Shared library for Temper scripts (Vortex, Vortex Mini, etc.)
-- Returns the `track` table.
--
-- Usage:
--   local track = dofile(reaper.GetResourcePath() .. "/Scripts/ABS/lib/temper_track_utils.lua")

local track = {}

-- Returns true when t is a live MediaTrack pointer.
function track.is_valid(t)
  return reaper.ValidatePtr(t, "MediaTrack*")
end

-- Returns the user-set track name (P_NAME). Returns "" for unnamed tracks.
-- Uses P_NAME (not GetTrackName) so that REAPER's auto "Track N" labels are
-- treated as blank and do not pollute search queries with numeric identifiers.
function track.get_name(t)
  local _, pname = reaper.GetSetMediaTrackInfo_String(t, "P_NAME", "", false)
  return (pname ~= nil and pname ~= "") and pname or ""
end

-- Returns the 0-based track index within the project.
function track.get_idx(t)
  return math.floor(reaper.GetMediaTrackInfo_Value(t, "IP_TRACKNUMBER")) - 1
end

-- Returns true when t is a folder track (I_FOLDERDEPTH == 1).
function track.is_folder(t)
  return reaper.GetMediaTrackInfo_Value(t, "I_FOLDERDEPTH") == 1
end

-- Find the immediate folder-track ancestor of t by scanning forward from track 0.
-- Builds a parent stack: push on fd >= 1, pop |fd| times on fd <= -1.
-- After processing all tracks before t, the stack top is t's nearest folder parent.
-- @param t MediaTrack*
-- @return MediaTrack* | nil  Nearest folder ancestor, or nil if t is at project root
function track.find_folder_ancestor(t)
  local target_idx = track.get_idx(t)
  local stack      = {}
  for i = 0, target_idx - 1 do
    local tr = reaper.GetTrack(0, i)
    local fd = math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH"))
    if fd >= 1 then
      stack[#stack + 1] = tr
    elseif fd <= -1 then
      for _ = 1, -fd do
        if #stack > 0 then table.remove(stack) end
      end
    end
  end
  return stack[#stack]
end

-- Enumerate direct children (depth == 1) of a folder track.
-- Uses I_FOLDERDEPTH to traverse without recursing into grandchildren.
-- @param parent_track MediaTrack*
-- @return table  List of child MediaTrack* pointers
function track.get_folder_children(parent_track)
  local children = {}
  local depth    = 1
  local i        = track.get_idx(parent_track) + 1
  while i < reaper.CountTracks(0) and depth > 0 do
    local t = reaper.GetTrack(0, i)
    if depth == 1 then children[#children + 1] = t end
    depth = depth + reaper.GetMediaTrackInfo_Value(t, "I_FOLDERDEPTH")
    i = i + 1
  end
  return children
end

return track
