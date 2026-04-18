-- temper_nexus_clipboard.lua — Clipboard capture/paste/cascade for Temper Nexus.
-- Routing module injected as parameter to avoid circular deps.
local M = {}

local r = reaper

-------------------------------------------------------------------------------
-- Capture
-------------------------------------------------------------------------------

--- Snapshot routing state from a single track.
--- @param track MediaTrack*
--- @param routing table  temper_nexus_routing module
--- @return table clipboard descriptor
function M.capture(track, routing)
  local guid = r.GetTrackGUID(track)
  local _, name = r.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
  return {
    source_guid = guid,
    source_name = name or "",
    sends       = routing.get_sends(track),
    receives    = routing.get_receives(track),
    hw_outs     = routing.get_hw_outs(track),
    parent      = routing.get_parent(track),
    scope       = { sends = true, receives = true, hw_outs = true, parent = true },
  }
end

-------------------------------------------------------------------------------
-- Validate paste (pre-flight)
-------------------------------------------------------------------------------

--- Pre-flight check before pasting clipboard to a target track.
--- @param clipboard table  from M.capture
--- @param target_track MediaTrack*
--- @param routing table  temper_nexus_routing module
--- @return table { valid=bool, warnings={string} }
function M.validate_paste(clipboard, target_track, routing)
  local warnings = {}
  local target_guid = r.GetTrackGUID(target_track)

  -- Self-paste guard
  if target_guid == clipboard.source_guid then
    return { valid = false, warnings = { "Cannot paste routing onto the source track itself" } }
  end

  -- Channel capacity warnings for sends
  local target_nchan = routing.get_track_nchan(target_track)
  for _, s in ipairs(clipboard.sends) do
    local offset, count = routing.decode_src_channels(s.src_chan)
    if offset >= 0 and offset + count > target_nchan then
      warnings[#warnings + 1] = string.format(
        "Send to '%s': source channels %d-%d exceed target's %d channels",
        s.dest_name, offset + 1, offset + count, target_nchan
      )
    end
  end

  -- Receive source track existence
  for _, recv in ipairs(clipboard.receives) do
    if recv.dest_track and not r.ValidatePtr(recv.dest_track, "MediaTrack*") then
      warnings[#warnings + 1] = string.format(
        "Receive source track '%s' no longer exists", recv.dest_name
      )
    end
  end

  return { valid = true, warnings = warnings }
end

-------------------------------------------------------------------------------
-- Paste helpers (private)
-------------------------------------------------------------------------------

local _SEND_PROPS = {
  "D_VOL", "D_PAN", "B_MUTE", "B_PHASE", "B_MONO", "I_SENDMODE", "I_SRCCHAN", "I_DSTCHAN",
}

--- Find an existing send from track to dest_guid in the given category.
--- Returns send index or nil.
local function _find_send(track, cat, dest_guid, routing)
  local list
  if cat == routing.CAT_SENDS then
    list = routing.get_sends(track)
  else
    list = routing.get_receives(track)
  end
  for _, d in ipairs(list) do
    if d.dest_guid == dest_guid then return d.idx end
  end
  return nil
end

--- Apply the 8 standard properties to a send/receive.
local function _apply_props(track, cat, idx, descriptor)
  local vals = {
    D_VOL      = descriptor.vol,
    D_PAN      = descriptor.pan,
    B_MUTE     = descriptor.mute and 1 or 0,
    B_PHASE    = descriptor.phase and 1 or 0,
    B_MONO     = descriptor.mono and 1 or 0,
    I_SENDMODE = descriptor.mode,
    I_SRCCHAN  = descriptor.src_chan,
    I_DSTCHAN  = descriptor.dst_chan,
  }
  for _, key in ipairs(_SEND_PROPS) do
    r.SetTrackSendInfo_Value(track, cat, idx, key, vals[key])
  end
end

-------------------------------------------------------------------------------
-- Paste
-------------------------------------------------------------------------------

--- Paste clipboard routing onto one or more target tracks.
--- Caller wraps in undo block — this function does not manage undo.
--- @param clipboard table  from M.capture
--- @param targets table  array of MediaTrack*
--- @param routing table  temper_nexus_routing module
--- @return table { applied=N, skipped=N, warnings={} }
function M.paste(clipboard, targets, routing)
  local applied  = 0
  local skipped  = 0
  local warnings = {}

  for _, target in ipairs(targets) do
    local target_guid = r.GetTrackGUID(target)

    -- Self-paste guard
    if target_guid == clipboard.source_guid then
      skipped = skipped + 1
      goto continue_target
    end

    -- Sends
    if clipboard.scope.sends then
      for _, s in ipairs(clipboard.sends) do
        -- Skip deleted dest tracks
        if not s.dest_track or not r.ValidatePtr(s.dest_track, "MediaTrack*") then
          warnings[#warnings + 1] = string.format("Send dest '%s' deleted, skipped", s.dest_name)
          goto continue_send
        end
        -- Skip self-routing
        if s.dest_guid == target_guid then goto continue_send end

        local idx = _find_send(target, routing.CAT_SENDS, s.dest_guid, routing)
        if not idx then
          idx = routing.create_send(target, s.dest_track)
        end
        _apply_props(target, routing.CAT_SENDS, idx, s)
        ::continue_send::
      end
    end

    -- Receives
    if clipboard.scope.receives then
      for _, recv in ipairs(clipboard.receives) do
        -- In receives, dest_track is actually the source track (P_SRCTRACK)
        local src_track = recv.dest_track
        if not src_track or not r.ValidatePtr(src_track, "MediaTrack*") then
          warnings[#warnings + 1] = string.format("Receive source '%s' deleted, skipped", recv.dest_name)
          goto continue_recv
        end
        local src_guid = r.GetTrackGUID(src_track)
        -- Skip self-routing
        if src_guid == target_guid then goto continue_recv end

        -- Check if source already sends to target
        local idx = _find_send(src_track, routing.CAT_SENDS, target_guid, routing)
        if not idx then
          idx = routing.create_send(src_track, target)
        end
        _apply_props(src_track, routing.CAT_SENDS, idx, recv)
        ::continue_recv::
      end
    end

    -- HW Outputs: remove all existing, then recreate from clipboard
    if clipboard.scope.hw_outs then
      local hw_count = r.GetTrackNumSends(target, routing.CAT_HW_OUTS)
      for i = hw_count - 1, 0, -1 do
        routing.remove_send(target, routing.CAT_HW_OUTS, i)
      end
      for _, hw in ipairs(clipboard.hw_outs) do
        local idx = r.CreateTrackSend(target, nil)
        _apply_props(target, routing.CAT_HW_OUTS, idx, hw)
      end
    end

    -- Parent send. Routed through routing.set_parent_* wrappers so the
    -- "all REAPER mutation flows through routing.lua" invariant holds
    -- universally (clipboard used to bypass these three and call
    -- SetMediaTrackInfo_Value directly).
    if clipboard.scope.parent then
      routing.set_parent_enabled(target,   clipboard.parent.enabled)
      routing.set_parent_vol(target,       clipboard.parent.vol)
      routing.set_parent_pan(target,       clipboard.parent.pan)
      routing.set_parent_ch_offset(target, clipboard.parent.ch_offset)
    end

    applied = applied + 1
    ::continue_target::
  end

  return { applied = applied, skipped = skipped, warnings = warnings }
end

-------------------------------------------------------------------------------
-- Cascade
-------------------------------------------------------------------------------

--- Cascade channel offsets across an ordered set of tracks.
--- @param tracks table  array of MediaTrack* in order
--- @param category number|string  routing.CAT_SENDS, routing.CAT_HW_OUTS, or "parent"
--- @param send_idx number  send index (ignored for "parent")
--- @param start_ch number  starting channel offset (0-based)
--- @param step number  1 (mono) or 2 (stereo)
--- @param routing table  temper_nexus_routing module
--- @return table { total=N, clamped={track_ptr, ...} }
function M.cascade(tracks, category, send_idx, start_ch, step, routing)
  local clamped = {}
  local offset  = start_ch

  for _, track in ipairs(tracks) do
    if category == "parent" then
      -- Get dest channel count from parent or master
      local parent = r.GetParentTrack(track)
      local dest
      if parent then
        dest = parent
      else
        dest = r.GetMasterTrack(0)
      end
      local dest_nchan = routing.get_track_nchan(dest)

      -- Clamp check
      if offset + step > dest_nchan then
        offset = dest_nchan - step
        if offset < 0 then offset = 0 end
        clamped[#clamped + 1] = track
      end

      r.SetMediaTrackInfo_Value(track, "C_MAINSEND_OFFS", offset)
    else
      -- Sends or HW outs: get destination channel count for overflow check
      local dest_nchan
      local dest_track = r.GetTrackSendInfo_Value(track, category, send_idx, "P_DESTTRACK")
      if dest_track and r.ValidatePtr(dest_track, "MediaTrack*") then
        dest_nchan = routing.get_track_nchan(dest_track)
      else
        -- HW out or invalid: use a safe default
        dest_nchan = 1024
      end

      -- Clamp check
      if offset + step > dest_nchan then
        offset = dest_nchan - step
        if offset < 0 then offset = 0 end
        clamped[#clamped + 1] = track
      end

      local encoded = routing.encode_src_channels(offset, step)
      routing.set_prop(track, category, send_idx, "I_SRCCHAN", encoded)
    end

    offset = offset + step
  end

  return { total = #tracks, clamped = clamped }
end

return M
