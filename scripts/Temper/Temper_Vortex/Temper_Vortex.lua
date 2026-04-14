-- @description Temper Vortex
-- @version 1.7.31
-- @author Temper Tools
-- @provides
--   [main] Temper_Vortex.lua
--   [nomain] lib/rsg_sha256.lua
--   [nomain] lib/rsg_license.lua
--   [nomain] lib/rsg_theme.lua
--   [nomain] lib/rsg_activation_dialog.lua
--   [nomain] lib/rsg_mediadb.lua
--   [nomain] lib/rsg_track_utils.lua
--   [nomain] lib/rsg_import.lua
--   [nomain] lib/rsg_pp_apply.lua
--   [nomain] lib/rsg_actions.lua
-- @about
--   Vortex is a layer-based random audio asset importer for REAPER.
--
--   It reads REAPER's MediaDB index, builds a per-track search query from
--   child track names, and imports a random matching file at the edit cursor
--   for each child track inside a folder track group.
--
--   Features:
--   - Multi-group anchor system: register multiple folder-track groups
--   - Variations mode: place N variations at configurable time spacing
--   - Item property inheritance from ABS_Item_Paste_Properties
--   - Non-blocking MediaDB load with live progress indicator
--   - Trim to first cue point (for multi-cue SFX library files)
--   - LOCK guard: skip rows marked as locked in the UI
--
--   Requires: ReaImGui (install via ReaPack → Extensions)

-- ============================================================
-- CONFIG
-- ============================================================

local CONFIG = {
  -- Tokens stripped during query construction (case-insensitive).
  stop_words = {
    SFX  = true, FX   = true, BG  = true,
    AMB  = true, MUS  = true, ROOM = true,
    EXT  = true, INT  = true,
  },
  -- When true, imported items are trimmed to end at their first take marker
  -- (cue point).  Useful for multi-cue SFX library files where each cue is
  -- a separate variation.  Ignored if the take has no markers.
  trim_to_first_cue = true,
}

-- Lines processed per defer tick during MediaDB load.
-- 5000 lines ≈ 8 ms/tick on typical hardware; keeps the GUI at ~60 fps.
local _LINES_PER_TICK = 5000
-- Fields extracted from USER IXML:USER:* lines into the search haystack.
local _PARSE_WANTED   = { Keywords = true, Category = true, SubCategory = true, CatID = true }

-- ============================================================
-- inherit — ABS_Item_Paste_Properties bridge
-- ============================================================
-- ExtState section that ABS_Item_Paste_Properties writes into.
local _PP_SEC = "rsg_item_copier_v2"

-- ============================================================
-- lib/ module loading
-- ============================================================

-- Resolve lib/ as a sibling of this script, so the same code works in both
-- the dev layout (Scripts/Temper/lib/) and the per-package ReaPack layout
-- (Scripts/Temper/Temper/Temper_Vortex/lib/).
local _script_path = debug.getinfo(1, "S").source:sub(2)
local _lib         = (_script_path:match("^(.*)[\\/]") or ".") .. "/lib/"
local _pp_desc   = dofile(_lib .. "rsg_pp_descriptors.lua")
local _PP_TAKE_PROPS = _pp_desc.take
local _PP_ITEM_PROPS = _pp_desc.item
local db         = dofile(_lib .. "rsg_mediadb.lua")
local track      = dofile(_lib .. "rsg_track_utils.lua")
local import_mod = (dofile(_lib .. "rsg_import.lua"))(CONFIG)
local _pp_mod    = dofile(_lib .. "rsg_pp_apply.lua")
local _pp        = _pp_mod.create(_PP_TAKE_PROPS, _PP_ITEM_PROPS, import_mod.trim_item_to_max)
local rsg_actions = dofile(_lib .. "rsg_actions.lua")

-- ============================================================
-- Seek/Omit history cache (ported from Vortex Mini)
-- ============================================================

local _HIST_NS          = "TEMPER_Vortex"
local _HISTORY_KEY      = "query_history"
local _OMIT_HISTORY_KEY = "omit_history"
local _HISTORY_SEP      = "\x1e"   -- ASCII Record Separator (safe; queries never contain this char)
local _HISTORY_MAX      = 200

local function _hist_normalize(q)
  return (q:lower():gsub("^%s+", ""):gsub("%s+$", ""))
end

local function _hist_tokenize(q)
  local tokens = {}
  for w in (q or ""):gmatch("%S+") do
    if w ~= "NOT" then tokens[#tokens + 1] = w:lower() end
  end
  return tokens
end

local function history_load(key)
  local raw = reaper.GetExtState(_HIST_NS, key)
  local h   = {}
  if raw == "" then return h end
  for entry in (raw .. _HISTORY_SEP):gmatch("(.-)\x1e") do
    if entry ~= "" then
      h[#h + 1] = { text = entry, norm = _hist_normalize(entry), tokens = _hist_tokenize(entry) }
    end
  end
  return h
end

local function history_save(h, key)
  local parts = {}
  for _, e in ipairs(h) do parts[#parts + 1] = e.text end
  reaper.SetExtState(_HIST_NS, key, table.concat(parts, _HISTORY_SEP), true)
end

local function history_add(h, query, key)
  local q = (query or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if q == "" then return end
  local norm = _hist_normalize(q)
  for i = #h, 1, -1 do
    if h[i].norm == norm then table.remove(h, i) end
  end
  table.insert(h, 1, { text = q, norm = norm, tokens = _hist_tokenize(q) })
  while #h > _HISTORY_MAX do table.remove(h) end
  history_save(h, key)
end

local function history_filter(h, input)
  local input_tokens = _hist_tokenize(input or "")
  local results      = {}
  for i, e in ipairs(h) do
    local include = true
    if #input_tokens > 0 then
      for _, t in ipairs(input_tokens) do
        local found = false
        for _, et in ipairs(e.tokens) do
          if et:find(t, 1, true) then found = true; break end
        end
        if not found then include = false; break end
      end
    end
    if include then
      local is_exact = (e.norm == _hist_normalize(input or ""))
      local coverage = #e.tokens > 0 and (#input_tokens / #e.tokens) or 0
      local score    = (is_exact and 10000 or 0) + math.floor(coverage * 100) + (_HISTORY_MAX - i)
      results[#results + 1] = { text = e.text, score = score, orig_idx = i }
    end
  end
  table.sort(results, function(a, b) return a.score > b.score end)
  return results
end

local function apply_random_cue_to_row(row, state, pos)
  local idx_entry = row.current_idx and state.index[row.current_idx]
  local filepath = row.lock_filepath or (idx_entry and idx_entry.filepath)
  if not filepath then return false end
  pos = pos or import_mod.find_effective_pos(row.track, reaper.GetCursorPosition())

  -- F8: check for an existing item at pos before importing. LOCK mode should shift the
  -- cue of the already-placed item (the one the user just rolled and wants to keep),
  -- not replace it with a fresh import. Only import when the slot is empty.
  local item = import_mod.find_item_at_cursor(row.track, pos)
  if not item then
    if not import_mod.import_file(row.track, filepath, pos) then return false end
    item = import_mod.find_item_at_cursor(row.track, pos)
  end
  if not item then return true end
  local take = reaper.GetActiveTake(item)
  if not take then return true end

  -- Collect cue boundaries: REAPER take markers first, WAV cue chunk as fallback.
  local bounds = {0.0}
  local n_tm = reaper.GetNumTakeMarkers(take)
  for i = 0, n_tm - 1 do
    local mpos = reaper.GetTakeMarker(take, i)
    if mpos > 0.001 then bounds[#bounds + 1] = mpos end
  end
  if #bounds < 2 then
    local cues = import_mod.read_wav_cue_list_sec(filepath)
    for _, c in ipairs(cues) do bounds[#bounds + 1] = c end
  end
  if #bounds < 2 then return true end  -- no usable cues; import done

  local src       = reaper.GetMediaItemTake_Source(take)
  local total_len = reaper.GetMediaSourceLength(src, false)

  local chosen    = math.random(1, #bounds)
  local start_sec = bounds[chosen]
  local next_cue  = bounds[chosen + 1]
  local item_len  = (CONFIG.trim_to_first_cue and next_cue)
                    and (next_cue - start_sec) or (total_len - start_sec)

  reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", start_sec)
  reaper.SetMediaItemLength(item, math.max(0.01, item_len), false)
  reaper.UpdateItemInProject(item)
  return true
end

-- ============================================================
-- Row management
-- ============================================================

-- Build a row table for one child track. Results populated later via search_row().
-- @param child_track      MediaTrack*
-- @param parent_name      string  Immediate parent name (sub-folder or top-level)
-- @param group            string|nil  Sub-folder name when grandchild, nil for direct child
-- @param parent_track_ptr MediaTrack*  Immediate parent track pointer
-- @return table
local function make_row(child_track, parent_name, group, parent_track_ptr)
  -- RSG-105: use P_NAME (user-set name) so that REAPER's auto "Track N" labels are treated
  -- as blank and do not pollute the search query with numeric track identifiers.
  local _, pname = reaper.GetSetMediaTrackInfo_String(child_track, "P_NAME", "", false)
  local name = (pname ~= nil and pname ~= "") and pname or ""
  return {
    track          = child_track,
    parent_track   = parent_track_ptr,
    name           = name,
    group          = group,       -- nil = direct child; string = sub-folder grandchild
    parent_name    = parent_name, -- effective parent for search (immediate parent)
    tokens         = db.build_query(parent_name, name, true, CONFIG.stop_words),
    results          = {},
    raw_result_count = 0,
    mode             = "free", -- "free" | "unique" | "lock"
    active         = true,  -- false = excluded from all generation (Roll + Randomize All)
    current_idx    = nil,   -- index into state.index (nil = not yet rolled)
    lock_filepath  = nil,   -- F9: file frozen when LOCK mode is active (survives search resets)
    last_rolled_filepath = nil, -- F9: filepath of last placed file; used as LOCK capture source
    include_parent = true,
    fallback       = false, -- true when child-only fallback search was used
    exclude_text   = "",    -- raw NOT text (GUI buffer; persisted in presets)
    exclude_tokens = {},    -- parsed NOT tokens applied as post-search filter
    inherit_props  = true,  -- false = exclude this track from property inheritance
    selected       = false, -- true = row is GUI-selected for batch operations
    -- `selected` is also written by _sync_reaper_selection_to_gui (REAPER → Vortex),
    -- which makes it ambiguous for action dispatch: a keyboard-shortcut action can't
    -- tell if a row is "selected because the user clicked it in Vortex" vs "because
    -- a child track was picked in REAPER's track panel". `_user_sel` is the stricter
    -- flag — flipped ONLY by explicit clicks in the Vortex table, never by sync —
    -- and is what the action handlers read to decide "user has a row selection".
    _user_sel      = false,
  }
end

-- Enumerate generation targets for a folder track.
-- Direct leaf children → row with group=nil.
-- Sub-folder children with children → their grandchildren each get group=sub-folder-name.
-- Empty sub-folders → treated as regular leaf rows (group=nil, parent=top-level).
-- @param parent_track  MediaTrack*
-- @param parent_name   string  Top-level folder name
-- @return table  List of {track, parent_track, parent_name, group}
local function get_generation_targets(parent_track, parent_name)
  local targets = {}
  local direct  = track.get_folder_children(parent_track)
  for _, child in ipairs(direct) do
    if track.is_folder(child) then
      local sub_children = track.get_folder_children(child)
      if #sub_children > 0 then
        local sub_name = track.get_name(child)
        -- Combined parent includes both top-level and sub-folder so search covers all ancestors.
        local combined = (parent_name ~= "" and (parent_name .. " " .. sub_name) or sub_name)
        for _, gc in ipairs(sub_children) do
          targets[#targets + 1] = { track = gc, parent_track = child, parent_name = combined, group = sub_name }
        end
      else
        -- Empty sub-folder: treat as regular row using the top-level parent name.
        targets[#targets + 1] = { track = child, parent_track = parent_track, parent_name = parent_name, group = nil }
      end
    else
      targets[#targets + 1] = { track = child, parent_track = parent_track, parent_name = parent_name, group = nil }
    end
  end
  return targets
end

-- Run the AND-token search for a single row, updating tokens+results+current_idx.
-- Uses row.parent_name as the effective parent for query construction.
-- @param row    table  Row to update in place
-- @param index  table  Loaded db index
-- Merge per-row, group-level, and global NOT tokens into one list.
-- @param row   table   Row being searched
-- @param state table|nil  App state (nil = no group/global NOT applied)
local function merged_not_tokens(row, state)
  if not state then return row.exclude_tokens end
  local merged = {}
  for _, t in ipairs(row.exclude_tokens) do merged[#merged + 1] = t end
  local gn = state.group_not[row.group or ""]
  if gn then for _, t in ipairs(gn.tokens) do merged[#merged + 1] = t end end
  for _, t in ipairs(state.global_not.tokens) do merged[#merged + 1] = t end
  return merged
end

local function search_row(row, index, state)
  row.tokens   = db.build_query(row.parent_name, row.name, row.include_parent, CONFIG.stop_words)
  local raw    = db.search(index, row.tokens)
  row.fallback = false
  -- When parent-prefix AND-join returns nothing, retry with child-only tokens.
  if #raw == 0 and row.include_parent then
    local child_tok = db.build_query("", row.name, false, CONFIG.stop_words)
    if #child_tok > 0 then
      local child_res = db.search(index, child_tok)
      if #child_res > 0 then
        row.tokens   = child_tok
        raw          = child_res
        row.fallback = true
      end
    end
  end
  -- Apply merged NOT exclusion filter (row + group + global).
  -- raw_result_count lets the zero-result tooltip distinguish "no match" from "all excluded".
  row.raw_result_count = #raw
  row.results          = db.filter_exclusions(index, raw, merged_not_tokens(row, state))
  row.current_idx      = nil
end

-- Pick a random result for a row. No-op if no results.
-- @param row table
-- Pick a new random file for a row, honouring its mode.
-- "free"   → pure random pick
-- "unique" → avoid repeating the previous current_idx when >1 result
-- "lock"   → no-op (file never changes via roll)
local function do_roll(row)
  if #row.results == 0 then return end
  if row.mode == "lock" and (row.lock_filepath or row.current_idx) then return end  -- already imported; cue-shift path handles it
  if row.mode == "unique" and #row.results > 1 then
    local prev = row.current_idx
    local attempts = 0
    repeat
      row.current_idx = row.results[math.random(1, #row.results)]
      attempts = attempts + 1
    until row.current_idx ~= prev or attempts >= 20
  else
    row.current_idx = row.results[math.random(1, #row.results)]
  end
end

-- Pick + import a single row at the edit cursor. Own undo block.
-- @param row   table   Row state
-- @param state table   App state (for index lookup)
-- Mode behaviour:
--   free/unique → pick a new random file and import it
--   lock        → shift the existing item to a random cue within the same file
--   inactive    → no-op (guard against direct calls; UI disables the button anyway)
-- Chunk-surgery helpers — delegated to rsg_pp_apply module.
local _chunk_extract_block = _pp_mod.extract_block
local _take_block_in_chunk = _pp_mod.take_block

-- Build a set of track GUIDs from LR's own rows (scope guard).
local function _pp_row_guids(state)
  local set = {}
  for _, row in ipairs(state.rows) do
    local guid = reaper.GetTrackGUID(row.track)
    if guid then set[guid] = true end
  end
  return set
end

-- Read Paste Properties ExtState and build an in-memory snapshot.
-- Only captures GUIDs that belong to LR's own tracks (scope guard).
-- Returns nil when nothing useful was found.
local function _pp_capture(state)
  local guids_str = reaper.GetExtState(_PP_SEC, "src2_track_guids")
  if guids_str == "" then return nil end
  local allowed  = _pp_row_guids(state)
  local snapshot = { tracks = {}, enabled = {}, count = 0 }
  -- Capture checkbox state at the moment of capture
  local all_keys = {}
  for _, p in ipairs(_PP_TAKE_PROPS) do all_keys[#all_keys + 1] = p.key end
  for _, p in ipairs(_PP_ITEM_PROPS) do all_keys[#all_keys + 1] = p.key end
  all_keys[#all_keys + 1] = "i_fx"
  all_keys[#all_keys + 1] = "i_len"
  for _, k in ipairs(all_keys) do
    local v = reaper.GetExtState(_PP_SEC, "cb_" .. k)
    snapshot.enabled[k] = (v == "" or v == "1")
  end
  -- Capture per-track source slots (filtered to LR's hierarchy)
  for g in guids_str:gmatch("[^|]+") do
    if allowed[g] then
      local pfx  = "src2_" .. g .. "_"
      local slot = { props = {}, fx_chunk = "" }
      for _, p in ipairs(_PP_TAKE_PROPS) do
        local raw = reaper.GetExtState(_PP_SEC, pfx .. p.key)
        if raw ~= "" then slot.props[p.key] = raw end
      end
      for _, p in ipairs(_PP_ITEM_PROPS) do
        local raw = reaper.GetExtState(_PP_SEC, pfx .. p.key)
        if raw ~= "" then slot.props[p.key] = raw end
      end
      -- Read i_len separately — used as a max-cap, not direct assignment.
      local raw_len = reaper.GetExtState(_PP_SEC, pfx .. "i_len")
      if raw_len ~= "" then slot.props["i_len"] = raw_len end
      slot.fx_chunk = reaper.GetExtState(_PP_SEC, pfx .. "fx_chunk")
      snapshot.tracks[g]  = slot
      snapshot.count      = snapshot.count + 1
    end
  end
  if snapshot.count == 0 then return nil end
  return snapshot
end

-- Capture item/take properties directly from selected REAPER items on this group's tracks.
-- Returns a snapshot in the same format as _pp_capture(), or nil when nothing matches.
local function _pp_capture_from_selection(state)
  local n = reaper.CountSelectedMediaItems(0)
  if n == 0 then return nil end
  local allowed  = _pp_row_guids(state)
  local snapshot = { tracks = {}, enabled = {}, count = 0 }
  for _, p in ipairs(_PP_TAKE_PROPS) do snapshot.enabled[p.key] = true end
  for _, p in ipairs(_PP_ITEM_PROPS) do snapshot.enabled[p.key] = true end
  snapshot.enabled["i_fx"]  = true
  snapshot.enabled["i_len"] = true
  for i = 0, n - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    if item then
      local tr   = reaper.GetMediaItemTrack(item)
      local guid = reaper.GetTrackGUID(tr)
      if allowed[guid] and not snapshot.tracks[guid] then
        local take = reaper.GetActiveTake(item)
        local slot = { props = {}, fx_chunk = "" }
        for _, p in ipairs(_PP_ITEM_PROPS) do
          slot.props[p.key] = tostring(reaper.GetMediaItemInfo_Value(item, p.parmname))
        end
        slot.props["i_len"] = tostring(reaper.GetMediaItemInfo_Value(item, "D_LENGTH"))
        if take then
          for _, p in ipairs(_PP_TAKE_PROPS) do
            if p.is_envelope then
              local env = reaper.GetTakeEnvelopeByName(take, p.env_name)
              if env then
                local ok_e, ec = reaper.GetEnvelopeStateChunk(env, "", false)
                if ok_e and ec and ec ~= "" then slot.props[p.key] = ec end
              end
            elseif p.is_string then
              local _, v = reaper.GetSetMediaItemTakeInfo_String(take, p.parmname, "", false)
              if v and v ~= "" then slot.props[p.key] = v end
            else
              slot.props[p.key] = tostring(reaper.GetMediaItemTakeInfo_Value(take, p.parmname))
            end
          end
        end
        local ok_c, ic = reaper.GetItemStateChunk(item, "", false)
        if ok_c and ic and ic ~= "" then
          local n_takes = reaper.GetMediaItemNumTakes(item)
          if n_takes > 1 and take then
            local ti = 0
            for k = 0, n_takes - 1 do
              if reaper.GetMediaItemTake(item, k) == take then ti = k; break end
            end
            local tb = _take_block_in_chunk(ic, ti)
            slot.fx_chunk = tb and _chunk_extract_block(tb, "TAKEFX") or ""
          else
            slot.fx_chunk = _chunk_extract_block(ic, "TAKEFX")
          end
        end
        snapshot.tracks[guid] = slot
        snapshot.count        = snapshot.count + 1
      end
    end
  end
  if snapshot.count == 0 then return nil end
  return snapshot
end

-- True when any selected REAPER item belongs to this group's row tracks.
local function _has_selection_in_rows(state)
  local n = reaper.CountSelectedMediaItems(0)
  if n == 0 then return false end
  local allowed = _pp_row_guids(state)
  for i = 0, n - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    if item then
      local guid = reaper.GetTrackGUID(reaper.GetMediaItemTrack(item))
      if allowed[guid] then return true end
    end
  end
  return false
end

-- True when captured properties should be applied to this row's items.
local function _pp_should_apply(state, row)
  if not state.inherit_global   then return false end
  if not row.inherit_props      then return false end
  if not state.prop_snapshot    then return false end
  local guid = reaper.GetTrackGUID(row.track)
  return state.prop_snapshot.tracks[guid] ~= nil
end

-- Apply property snapshot to item, gating playrate on LOCK mode.
-- D_PLAYRATE is file-specific; only valid when the WAV doesn't change between rolls.
local function _pp_apply(state, row, item)
  local snap = state.prop_snapshot
  local prev_rate = snap.enabled["t_rate"]
  local prev_name = snap.enabled["t_name"]
  snap.enabled["t_rate"] = prev_rate and (row.mode == "lock")
  snap.enabled["t_name"] = false  -- take name belongs to the imported file, not the snapshot
  _pp.apply_to_item(snap, item, reaper.GetTrackGUID(row.track))
  snap.enabled["t_rate"] = prev_rate
  snap.enabled["t_name"] = prev_name
end


-- Scan each active row's track for an item near the time selection and compute
-- its offset relative to ts_start.  Stores result in row.ts_offset (seconds,
-- negative for lead-ins before TS).  Rows with no item default to 0.
-- Scan window extends one TS-width before ts_start to catch lead-in items.
-- @param rows     table   state.rows
-- @param ts_start number  Time selection start (seconds)
-- @param ts_end   number  Time selection end (seconds)
local function scan_row_offsets(rows, ts_start, ts_end)
  local scan_start = ts_start - (ts_end - ts_start)
  for _, row in ipairs(rows) do
    row.ts_offset = 0
    if not row.active then goto continue end
    local item = import_mod.find_item_in_range(row.track, scan_start, ts_end, ts_start)
    if item then
      row.ts_offset = reaper.GetMediaItemInfo_Value(item, "D_POSITION") - ts_start
    end
    ::continue::
  end
end


local function do_roll_and_import(row, state)
  if not row.active then return end
  local cursor_pos = reaper.GetCursorPosition()
  local ts_start, ts_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  local has_ts = ts_end > ts_start
  -- Relative-position-awareness: when TS active, detect per-row offset from
  -- current item position and use it instead of uniform eff_pos.
  local eff_pos, max_len
  if has_ts then
    scan_row_offsets({row}, ts_start, ts_end)
    eff_pos = ts_start + (row.ts_offset or 0)
    max_len = (row.ts_offset or 0) < 0 and (ts_end - ts_start) or (ts_end - eff_pos)
    if max_len < 0.01 then max_len = 0.01 end
  else
    eff_pos = import_mod.find_effective_pos(row.track, cursor_pos)
  end
  if has_ts and eff_pos >= ts_end then return end
  if row.mode == "lock" and (row.lock_filepath or row.current_idx) then
    reaper.Undo_BeginBlock()
    apply_random_cue_to_row(row, state, eff_pos)
    local item = import_mod.find_item_at_cursor(row.track, eff_pos)
    if item then
      if max_len then import_mod.trim_item_to_max(item, max_len) end
      if _pp_should_apply(state, row) then _pp_apply(state, row, item) end
    end
    reaper.UpdateArrange()
    reaper.Main_OnCommand(40047, 0)
    reaper.Undo_EndBlock("Temper Vortex: random cue " .. row.name, -1)
    if reaper.JS_Window_SetFocus then reaper.JS_Window_SetFocus(reaper.GetMainHwnd()) end
    return
  end
  -- LOCK with no file yet, or FREE/UNIQUE: pick and import a file.
  if #row.results == 0 then return end
  do_roll(row)
  local roll_entry = row.current_idx and state.index[row.current_idx]
  if not roll_entry then return end
  reaper.Undo_BeginBlock()
  import_mod.import_file(row.track, roll_entry.filepath, eff_pos)
  row.last_rolled_filepath = roll_entry.filepath  -- F9: track for LOCK capture
  local item = import_mod.find_item_at_cursor(row.track, eff_pos)
  if item then
    if max_len then import_mod.trim_item_to_max(item, max_len) end
    if _pp_should_apply(state, row) then _pp_apply(state, row, item) end
  end
  reaper.UpdateArrange()
  reaper.Main_OnCommand(40047, 0)
  reaper.Undo_EndBlock("Temper Vortex: Roll " .. row.name, -1)
  if reaper.JS_Window_SetFocus then reaper.JS_Window_SetFocus(reaper.GetMainHwnd()) end
end

-- Randomize all rows in a single undo block.
-- lock   rows: shift the existing item to a random cue within the same file.
-- free/unique rows: pick a new random file (unique avoids repeating last pick) and import.
-- When a time selection exists, each placed item is trimmed to not exceed ts_end.
-- @param state table  App state
local function _cache_row_terms(state)
  for _, r in ipairs(state.rows) do
    if r.active then
      history_add(state.query_history, r.name, _HISTORY_KEY)
      history_add(state.omit_history, r.exclude_text, _OMIT_HISTORY_KEY)
    end
  end
end

local function randomize_all(state)
  _cache_row_terms(state)
  local cursor_pos = reaper.GetCursorPosition()
  local ts_start, ts_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  local has_ts = ts_end > ts_start
  local ts_len = has_ts and (ts_end - ts_start) or nil
  if has_ts then scan_row_offsets(state.rows, ts_start, ts_end) end
  reaper.Undo_BeginBlock()
  for _, row in ipairs(state.rows) do
    if not row.active then
      -- skip: inactive tracks are completely excluded from generation
    else
      local eff_pos = has_ts and (ts_start + (row.ts_offset or 0))
                              or import_mod.find_effective_pos(row.track, cursor_pos)
      local max_len = nil
      if has_ts then
        max_len = (row.ts_offset or 0) < 0 and ts_len or (ts_end - eff_pos)
        if max_len < 0.01 then max_len = 0.01 end
      end
      if has_ts and eff_pos >= ts_end then
        -- skip: effective placement position is at or past the time selection end
      elseif row.mode == "lock" and (row.lock_filepath or row.current_idx) then
        apply_random_cue_to_row(row, state, eff_pos)
        local item = import_mod.find_item_at_cursor(row.track, eff_pos)
        if item then
          if max_len then import_mod.trim_item_to_max(item, max_len) end
          if _pp_should_apply(state, row) then
            _pp_apply(state, row, item)
          end
        end
      elseif #row.results > 0 then
        do_roll(row)
        local ra_entry = row.current_idx and state.index[row.current_idx]
        if ra_entry then
          import_mod.import_file(row.track, ra_entry.filepath, eff_pos)
          row.last_rolled_filepath = ra_entry.filepath  -- F9
          local item = import_mod.find_item_at_cursor(row.track, eff_pos)
          if item then
            if max_len then import_mod.trim_item_to_max(item, max_len) end
            if _pp_should_apply(state, row) then
              _pp_apply(state, row, item)
            end
          end
        end
      end
    end
  end
  reaper.UpdateArrange()
  reaper.Main_OnCommand(40047, 0)
  reaper.Undo_EndBlock("Temper Vortex: Randomize All", -1)
  if reaper.JS_Window_SetFocus then reaper.JS_Window_SetFocus(reaper.GetMainHwnd()) end
end

-- Roll only GUI-selected rows in a single undo block.
-- Same logic as randomize_all but filtered to rows where row.selected == true.
-- @param state table  App state
local function do_roll_selected(state)
  _cache_row_terms(state)
  local cursor_pos = reaper.GetCursorPosition()
  local ts_start, ts_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  local has_ts = ts_end > ts_start
  local ts_len = has_ts and (ts_end - ts_start) or nil
  if has_ts then scan_row_offsets(state.rows, ts_start, ts_end) end
  reaper.Undo_BeginBlock()
  for _, row in ipairs(state.rows) do
    if not (row.selected and row.active) then
      -- skip: not selected or inactive
    else
      local eff_pos = has_ts and (ts_start + (row.ts_offset or 0))
                              or import_mod.find_effective_pos(row.track, cursor_pos)
      local max_len = nil
      if has_ts then
        max_len = (row.ts_offset or 0) < 0 and ts_len or (ts_end - eff_pos)
        if max_len < 0.01 then max_len = 0.01 end
      end
      if has_ts and eff_pos >= ts_end then
        -- skip: offset places this row past time selection end
      elseif row.mode == "lock" and (row.lock_filepath or row.current_idx) then
        apply_random_cue_to_row(row, state, eff_pos)
        local item = import_mod.find_item_at_cursor(row.track, eff_pos)
        if item then
          if max_len then import_mod.trim_item_to_max(item, max_len) end
          if _pp_should_apply(state, row) then
            _pp_apply(state, row, item)
          end
        end
      elseif #row.results > 0 then
        do_roll(row)
        local rs_entry = row.current_idx and state.index[row.current_idx]
        if rs_entry then
          import_mod.import_file(row.track, rs_entry.filepath, eff_pos)
          row.last_rolled_filepath = rs_entry.filepath  -- F9
          local item = import_mod.find_item_at_cursor(row.track, eff_pos)
          if item then
            if max_len then import_mod.trim_item_to_max(item, max_len) end
            if _pp_should_apply(state, row) then
              _pp_apply(state, row, item)
            end
          end
        end
      end
    end
  end
  reaper.UpdateArrange()
  reaper.Main_OnCommand(40047, 0)
  reaper.Undo_EndBlock("Temper Vortex: Roll Selected", -1)
  if reaper.JS_Window_SetFocus then reaper.JS_Window_SetFocus(reaper.GetMainHwnd()) end
end

-- Split any item that straddles pos (starts before pos, ends after pos):
-- keeps the left portion intact, deletes the right half to clear space for import.
-- Items starting at or after pos are left alone (import_file handles those).
-- @param track  MediaTrack*
-- @param pos    number  Project time in seconds
local function prepare_slot(track, pos)
  local n = reaper.CountTrackMediaItems(track)
  for i = n - 1, 0, -1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local ipos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local ilen = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    if ipos < pos and ipos + ilen > pos then
      local right = reaper.SplitMediaItem(item, pos)
      if right then reaper.DeleteTrackMediaItem(track, right) end
    end
  end
end

-- Return the project time for variation slot i (1-based) given a cursor start.
-- unit 0 = seconds (linear), unit 1 = beats (respects tempo changes).
-- @param cursor_pos number  Project time at start of first variation
-- @param i          integer 1-based variation index
-- @param x_val      number  Spacing magnitude
-- @param unit       integer 0=sec, 1=beats
-- @return number  Project time in seconds
local function _var_pos(cursor_pos, i, x_val, unit)
  if unit == 0 then
    return cursor_pos + i * x_val
  end
  -- TimeMap2_timeToBeats returns: retval, measures, cBeat, fullbeats, cdenom.
  -- Must use fullbeats (4th return) for linear beat arithmetic (beats regression fix).
  local _, _, _, start_q = reaper.TimeMap2_timeToBeats(0, cursor_pos)
  return reaper.TimeMap2_beatsToTime(0, start_q + i * x_val)
end

-- Place N randomized variation sets spaced X sec/beats apart from the edit cursor.
-- Each slot is prepared (straddling items split), files imported and capped at slot width.
-- Locked rows: re-use current file with a random cue.  Inactive rows: skipped.
-- Edit cursor advances to cursor + N*X when done.
-- @param state table  App state
local function do_variations(state, selected_only)
  _cache_row_terms(state)
  local n     = math.max(1, math.floor(tonumber(state.var_n_buf) or 1))
  local x_val = tonumber(state.var_x_buf) or 4.0
  if x_val <= 0 then x_val = 4.0 end

  local cursor_pos = reaper.GetCursorPosition()

  -- When a time selection exists, derive X (slot spacing) from TS length and
  -- anchor the first variation at ts_start (B4 fix: Variations fill the TS).
  -- start_si=0 means first slot is exactly at base_pos (ts_start when TS active).
  -- When no TS, base_pos=cursor_pos, start_si=1 (first slot at cursor+x, i.e., roll+continue).
  -- RSG-125: do NOT overwrite var_x_buf with TS-derived spacing; preserve user's typed value.
  local ts_start, ts_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  local use_ts = ts_end > ts_start
  -- Detect a TS that this function itself set at the end of the previous call.
  -- Without this guard, back-to-back Variations clicks (especially with n=1)
  -- alias: scan_row_offsets sweeps one slot back and picks up the prior call's
  -- items at exactly -x_val, and/or the start_si=1 shift triggers off items
  -- that straddle ts_start, both of which redirect new placements onto the
  -- previous variations and overwrite them.
  local is_self_advanced_ts = use_ts
    and state._var_last_ts_start ~= nil
    and math.abs(ts_start - state._var_last_ts_start) < 1e-6
    and math.abs(ts_end   - state._var_last_ts_end)   < 1e-6
  local base_pos, start_si
  if use_ts then
    if state.var_unit == 0 then
      x_val = ts_end - ts_start
    else
      local _, _, _, q_s = reaper.TimeMap2_timeToBeats(0, ts_start)
      local _, _, _, q_e = reaper.TimeMap2_timeToBeats(0, ts_end)
      x_val = q_e - q_s
    end
    if x_val <= 0 then x_val = 4.0 end
    base_pos = ts_start  -- B4 fix: anchor to ts_start so first variation fills the TS
    start_si = 0         -- slot 0 = ts_start (variations start at the time selection)
    if is_self_advanced_ts then
      -- TS was auto-advanced from our previous call. Any items one slot back
      -- are that call's output, not user-intentional relative offsets: clear
      -- per-row offsets and skip the occupancy shift.
      for _, row in ipairs(state.rows) do row.ts_offset = 0 end
    else
      -- Scan per-row offsets from current item positions before placing variations.
      scan_row_offsets(state.rows, ts_start, ts_end)
      -- RSG-124: if any active row already has an item at ts_start (e.g. from a prior Roll),
      -- shift first variation slot forward to avoid overwriting the rolled item.
      for _, row in ipairs(state.rows) do
        if row.active and import_mod.find_item_at_cursor(row.track, ts_start) then
          start_si = 1
          break
        end
      end
    end
  else
    base_pos = cursor_pos
    start_si = 1  -- slot 1 = cursor+x (no TS: continue after cursor position)
  end

  reaper.Undo_BeginBlock()
  for i = 1, n do
    -- si: slot index into _var_pos. start_si=0 → first at base_pos; start_si=1 → base_pos+x.
    local si      = start_si + (i - 1)
    local pos     = _var_pos(base_pos, si,     x_val, state.var_unit)
    local next_p  = _var_pos(base_pos, si + 1, x_val, state.var_unit)
    local max_sec = next_p - pos

    for _, row in ipairs(state.rows) do
      if not row.active then goto continue end
      if selected_only and not row.selected then goto continue end
      -- B2 fix: LOCK rows with a current file can produce output even if results is empty.
      local can_place = (#row.results > 0) or (row.mode == "lock" and (row.lock_filepath or row.current_idx))
      if not can_place then goto continue end

      -- Relative-position-awareness: apply per-row offset within each variation slot.
      local row_offset = use_ts and (row.ts_offset or 0) or 0
      local row_pos    = pos + row_offset
      local row_max    = row_offset < 0 and max_sec or math.max(0.01, next_p - row_pos)

      prepare_slot(row.track, row_pos)

      if row.mode == "lock" and (row.lock_filepath or row.current_idx) then
        -- LOCK: reuse the same file, pick a random cue within it (consistent with single-roll).
        apply_random_cue_to_row(row, state, row_pos)
      elseif row.mode == "unique" and #row.results > 1 then
        local prev, attempts = row.current_idx, 0
        repeat
          row.current_idx = row.results[math.random(1, #row.results)]
          attempts = attempts + 1
        until row.current_idx ~= prev or attempts >= 20
        local ve = row.current_idx and state.index[row.current_idx]
        if ve then import_mod.import_file(row.track, ve.filepath, row_pos) end
      else
        row.current_idx = row.results[math.random(1, #row.results)]
        local ve = row.current_idx and state.index[row.current_idx]
        if ve then import_mod.import_file(row.track, ve.filepath, row_pos) end
      end

      local item = import_mod.find_item_at_cursor(row.track, row_pos)
      if item then import_mod.trim_item_to_max(item, row_max) end
      if item and _pp_should_apply(state, row) then
        _pp_apply(state, row, item)
      end

      ::continue::
    end
  end

  -- Advance cursor to the slot immediately after all placed variations.
  -- Next empty slot is at start_si + n (one past the last placed slot).
  local next_si = start_si + n
  local next_s  = _var_pos(base_pos, next_si,     x_val, state.var_unit)
  local next_e  = _var_pos(base_pos, next_si + 1, x_val, state.var_unit)
  reaper.GetSet_LoopTimeRange(true, false, next_s, next_e, false)
  -- Remember the TS we just set so the next call can detect our own output
  -- and avoid the self-overlap bug in the scan_row_offsets / start_si shift
  -- paths (see the is_self_advanced_ts guard at the top of this function).
  state._var_last_ts_start = next_s
  state._var_last_ts_end   = next_e
  reaper.SetEditCurPos(next_s, true, false)
  reaper.UpdateArrange()
  reaper.Main_OnCommand(40047, 0)
  local undo_lbl = selected_only and ("Temper Vortex: Var Selected (" .. n .. ")")
                                  or ("Temper Vortex: Variations (" .. n .. ")")
  reaper.Undo_EndBlock(undo_lbl, -1)
  if reaper.JS_Window_SetFocus then reaper.JS_Window_SetFocus(reaper.GetMainHwnd()) end
end

-- Apply REAPER track colors based on GUI hierarchy and active state.
-- Hierarchy = dark → light (parent darkest, grandchild lightest).
-- Active tracks use GUI teal palette; inactive tracks use grey scale.
-- @param state table  App state (must be "ready")
local function apply_track_colors(state)
  local function native(r, g, b)
    return reaper.ColorToNative(r, g, b) | 0x1000000
  end

  -- Structural (folder) tracks: grey scale, dark → light with depth.
  -- Values are REAPER-visible (not near-black — those read as invisible in the track panel).
  local COL_PARENT = native( 58,  62,  66)  -- darkest grey  (top-level folder)
  local COL_SUB    = native( 96, 102, 108)  -- lighter grey  (sub-folder, one level deeper)

  -- Active leaf tracks: teal — "contributing" state, clearly distinct from grey folders.
  -- Lighter teal for grandchildren (deeper in tree = lighter, mirrors grey scale logic).
  local ACT_CHILD  = native( 38, 118,  92)  -- rich teal     (direct children, active)
  local ACT_GRAND  = native( 52, 145, 114)  -- lighter teal  (grandchildren, active)

  -- Inactive leaf tracks: grey scale, continuing the folder gradient.
  local INACT_CHILD = native( 92,  96, 100)  -- medium grey  (direct children, inactive)
  local INACT_GRAND = native(110, 114, 118)  -- light grey   (grandchildren, inactive)

  reaper.Undo_BeginBlock()

  -- Folder tracks always use structural (charcoal) colors regardless of active state
  reaper.SetTrackColor(state.parent_track, COL_PARENT)

  local colored_sub_folders = {}
  for _, row in ipairs(state.rows) do
    if row.group == nil then
      -- Direct child of the parent folder (leaf track)
      reaper.SetTrackColor(row.track, row.active and ACT_CHILD or INACT_CHILD)
    else
      -- Grandchild (inside a sub-folder — leaf track)
      reaper.SetTrackColor(row.track, row.active and ACT_GRAND or INACT_GRAND)
      -- Color the sub-folder track itself once per group (structural)
      if not colored_sub_folders[row.group] and row.parent_track then
        colored_sub_folders[row.group] = true
        reaper.SetTrackColor(row.parent_track, COL_SUB)
      end
    end
  end

  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Temper Vortex: Color Tracks", -1)
  if reaper.JS_Window_SetFocus then reaper.JS_Window_SetFocus(reaper.GetMainHwnd()) end
end

-- Reconcile state.rows with the current live generation targets of the parent folder.
-- Preserves row state for tracks that still exist; adds rows for new tracks.
-- Handles sub-folder renames and grandchild additions/removals.
-- Sets state.status = "error" if parent track was deleted.
-- @param state table  App state (mutated in place)
local function sync_child_rows(state)
  if not track.is_valid(state.parent_track) then
    state.status    = "error"
    state.error_msg = "Parent track was deleted."
    return
  end

  local targets = get_generation_targets(state.parent_track, state.parent_name)

  -- Fast path: same target count — check for leaf/sub-folder renames only
  if #targets == state.child_count then
    for _, row in ipairs(state.rows) do
      if track.is_valid(row.track) then
        -- Detect sub-folder rename from REAPER side
        if row.group and track.is_valid(row.parent_track) then
          local new_sub = track.get_name(row.parent_track)
          if new_sub ~= row.group then
            row.group       = new_sub
            row.parent_name = state.parent_name .. " " .. new_sub
            if row.include_parent then search_row(row, state.index, state) end
          end
        end
        -- Detect leaf track rename from REAPER side.
        -- RSG-105: use P_NAME so "Track N" auto-labels are treated as blank (same as make_row).
        local _, raw_pname = reaper.GetSetMediaTrackInfo_String(row.track, "P_NAME", "", false)
        local new_name = (raw_pname ~= nil and raw_pname ~= "") and raw_pname or ""
        if new_name ~= row.name then
          row.name = new_name
          search_row(row, state.index, state)
        end
      end
    end
    return
  end

  -- Count changed: rebuild rows, preserving state for surviving tracks
  state.child_count = #targets
  local old_rows    = {}
  for _, row in ipairs(state.rows) do
    old_rows[tostring(row.track)] = row
  end
  state.rows = {}
  for _, tgt in ipairs(targets) do
    local key      = tostring(tgt.track)
    local existing = old_rows[key]
    if existing then
      -- Update parent metadata in case sub-folder was renamed or track moved
      existing.parent_name  = tgt.parent_name
      existing.group        = tgt.group
      existing.parent_track = tgt.parent_track
      state.rows[#state.rows + 1] = existing
    else
      local row = make_row(tgt.track, tgt.parent_name, tgt.group, tgt.parent_track)
      search_row(row, state.index, state)
      state.rows[#state.rows + 1] = row
    end
  end
end

-- ============================================================
-- preset — save/load row state via REAPER ExtState
-- ============================================================

local preset = {}

local _EXT_SEC   = "TEMPER_Vortex"
local _LIST_KEY  = "_preset_names"
local _SEP_ROW   = "~"   -- printable; safe in reaper.ini
local _SEP_FIELD = ";"   -- printable; safe in reaper.ini

-- Serialize row flags to a compact delimited string.
-- Track names and exclusion text containing ";" or "~" are sanitized to "_".
function preset.serialize(rows)
  local parts = {}
  for _, row in ipairs(rows) do
    parts[#parts + 1] = table.concat({
      row.name:gsub("[;~]", "_"),
      row.mode or "free",            -- field 2: "free"/"unique"/"lock" (was "0"/"1" pre-v0.8.6)
      row.active         and "1" or "0",
      row.include_parent and "1" or "0",
      (row.exclude_text or ""):gsub("[;~|]", " "),
      row.inherit_props  and "1" or "0",  -- field 6 (v0.9.4+)
    }, _SEP_FIELD)
  end
  return table.concat(parts, _SEP_ROW)
end

-- Deserialize a string produced by preset.serialize().
function preset.deserialize(str)
  if not str or str == "" then return {} end
  local rows = {}
  for chunk in (str .. _SEP_ROW):gmatch("(.-)" .. _SEP_ROW) do
    local f = {}
    for field in (chunk .. _SEP_FIELD):gmatch("(.-)" .. _SEP_FIELD) do
      f[#f + 1] = field
    end
    if #f >= 4 then
      -- Migrate field 2: old format used "0"/"1" for locked boolean
      local raw_mode = f[2]
      local mode
      if raw_mode == "1" then mode = "lock"
      elseif raw_mode == "0" then mode = "free"
      else mode = raw_mode  -- "free" / "unique" / "lock" (new format)
      end
      rows[#rows + 1] = {
        name           = f[1],
        mode           = mode,
        active         = f[3] == "1",
        include_parent = f[4] == "1",
        exclude_text   = f[5] or "",
        inherit_props  = f[6] ~= "0",  -- field 6 (v0.9.4+); old presets without field 6 default true
      }
    end
  end
  return rows
end

-- Return ordered list of saved preset names.
function preset.list()
  local raw = reaper.GetExtState(_EXT_SEC, _LIST_KEY)
  if not raw or raw == "" then return {} end
  local names = {}
  for name in (raw .. "|"):gmatch("(.-)|") do
    if name ~= "" then names[#names + 1] = name end
  end
  return names
end

-- Save or overwrite a named preset.
-- state is optional; if provided, also persists inherit_global and prop_snapshot.
function preset.save(name, rows, state)
  local existing = preset.list()
  local found = false
  for _, n in ipairs(existing) do if n == name then found = true; break end end
  if not found then
    existing[#existing + 1] = name
    reaper.SetExtState(_EXT_SEC, _LIST_KEY, table.concat(existing, "|"), true)
  end
  reaper.SetExtState(_EXT_SEC, "p_" .. name, preset.serialize(rows), true)
  if not state then return end
  -- Persist inherit_global flag
  reaper.SetExtState(_EXT_SEC, "pi_" .. name, state.inherit_global and "1" or "0", true)
  -- Persist snapshot (write empty list if none, to clear any previously saved snapshot)
  local snap = state.prop_snapshot
  if snap then
    local guid_list = {}
    for g in pairs(snap.tracks) do guid_list[#guid_list + 1] = g end
    reaper.SetExtState(_EXT_SEC, "ps_" .. name, table.concat(guid_list, "|"), true)
    -- Enabled keys
    local en_list = {}
    for k, v in pairs(snap.enabled) do if v then en_list[#en_list + 1] = k end end
    reaper.SetExtState(_EXT_SEC, "pse_" .. name, table.concat(en_list, "|"), true)
    -- Per-track property values and FX chunk
    for g, slot in pairs(snap.tracks) do
      local pfx = "pst_" .. name .. "_" .. g .. "_"
      for _, p in ipairs(_PP_TAKE_PROPS) do
        reaper.SetExtState(_EXT_SEC, pfx .. p.key, slot.props[p.key] or "", true)
      end
      for _, p in ipairs(_PP_ITEM_PROPS) do
        reaper.SetExtState(_EXT_SEC, pfx .. p.key, slot.props[p.key] or "", true)
      end
      reaper.SetExtState(_EXT_SEC, pfx .. "i_len",    slot.props["i_len"] or "", true)
      reaper.SetExtState(_EXT_SEC, pfx .. "fx_chunk", slot.fx_chunk or "", true)
    end
  else
    reaper.SetExtState(_EXT_SEC, "ps_" .. name, "", true)
    reaper.SetExtState(_EXT_SEC, "pse_" .. name, "", true)
  end
end

-- Load preset by name. Returns list of row-data tables, or nil if not found.
function preset.load(name)
  local raw = reaper.GetExtState(_EXT_SEC, "p_" .. name)
  if not raw or raw == "" then return nil end
  return preset.deserialize(raw)
end

-- Delete a named preset from ExtState.
function preset.delete(name)
  local existing = preset.list()
  local new_list = {}
  for _, n in ipairs(existing) do
    if n ~= name then new_list[#new_list + 1] = n end
  end
  reaper.SetExtState(_EXT_SEC, _LIST_KEY, table.concat(new_list, "|"), true)
  reaper.DeleteExtState(_EXT_SEC, "p_" .. name, true)
  -- Clean up inherit/snapshot keys
  reaper.DeleteExtState(_EXT_SEC, "pi_" .. name, true)
  local guids_str = reaper.GetExtState(_EXT_SEC, "ps_" .. name)
  for g in guids_str:gmatch("[^|]+") do
    local pfx = "pst_" .. name .. "_" .. g .. "_"
    for _, p in ipairs(_PP_TAKE_PROPS) do reaper.DeleteExtState(_EXT_SEC, pfx .. p.key, true) end
    for _, p in ipairs(_PP_ITEM_PROPS) do reaper.DeleteExtState(_EXT_SEC, pfx .. p.key, true) end
    reaper.DeleteExtState(_EXT_SEC, pfx .. "i_len",    true)
    reaper.DeleteExtState(_EXT_SEC, pfx .. "fx_chunk", true)
  end
  reaper.DeleteExtState(_EXT_SEC, "ps_" .. name, true)
  reaper.DeleteExtState(_EXT_SEC, "pse_" .. name, true)
end

-- ============================================================
-- track_preset — per-row track search templates
-- ============================================================
-- A track template stores reusable search settings for a single row:
-- mode, include_parent, exclude_text, inherit_props.
-- These are lighter than global presets: no prop snapshot, no row list.
-- Saved as compact semicolon-delimited strings in the same ExtState section.

local track_preset = {}

local _TPL_KEY = "_tpl_names"

-- Return ordered list of saved template names.
function track_preset.list()
  local raw = reaper.GetExtState(_EXT_SEC, _TPL_KEY)
  if raw == "" then return {} end
  local names = {}
  for n in (raw .. "|"):gmatch("(.-)|") do
    if n ~= "" then names[#names + 1] = n end
  end
  return names
end

-- Save or overwrite a named template from a row's current settings.
function track_preset.save(name, row)
  local existing = track_preset.list()
  local found    = false
  for _, n in ipairs(existing) do if n == name then found = true; break end end
  if not found then
    existing[#existing + 1] = name
    reaper.SetExtState(_EXT_SEC, _TPL_KEY, table.concat(existing, "|"), true)
  end
  local val = table.concat({
    row.mode or "free",
    row.include_parent and "1" or "0",
    (row.exclude_text or ""):gsub("[;~|]", " "),
    row.inherit_props  and "1" or "0",
    (row.name or ""):gsub("[;~|]", " "),  -- field 5: track search name (v1.4.0)
  }, ";")
  reaper.SetExtState(_EXT_SEC, "tpl_" .. name, val, true)
end

-- Load a template by name.  Returns a table or nil when not found.
function track_preset.load(name)
  local raw = reaper.GetExtState(_EXT_SEC, "tpl_" .. name)
  if raw == "" then return nil end
  local f = {}
  for field in (raw .. ";"):gmatch("(.-);") do f[#f + 1] = field end
  if #f < 3 then return nil end
  return {
    mode           = f[1],
    include_parent = f[2] == "1",
    exclude_text   = f[3] or "",
    inherit_props  = f[4] ~= "0",
    name           = (f[5] ~= nil and f[5] ~= "") and f[5] or nil,  -- field 5: track name (v1.4.0; nil for old templates)
  }
end

-- Delete a named template from ExtState.
function track_preset.delete(name)
  local existing = track_preset.list()
  local new_list = {}
  for _, n in ipairs(existing) do if n ~= name then new_list[#new_list + 1] = n end end
  reaper.SetExtState(_EXT_SEC, _TPL_KEY, table.concat(new_list, "|"), true)
  reaper.DeleteExtState(_EXT_SEC, "tpl_" .. name, true)
end

-- Apply loaded preset data to live rows (matched by track name).
-- Also restores inherit_global and prop_snapshot if a preset name is provided.
function preset.apply(preset_rows, state, preset_name)
  local by_name = {}
  for _, pr in ipairs(preset_rows) do by_name[pr.name] = pr end
  for _, row in ipairs(state.rows) do
    -- Preset names have [;~] sanitized to "_" during serialize; try sanitized key when direct match fails.
    local pr = by_name[row.name] or by_name[(row.name):gsub("[;~]", "_")]
    if pr then
      local prev_ip    = row.include_parent
      local prev_excl  = row.exclude_text
      row.mode           = pr.mode or "free"
      row.active         = pr.active
      row.include_parent = pr.include_parent
      row.exclude_text   = pr.exclude_text or ""
      row.exclude_tokens = db.tokenize(row.exclude_text, {})
      row.inherit_props  = pr.inherit_props or false
      if row.include_parent ~= prev_ip or row.exclude_text ~= prev_excl then
        search_row(row, state.index, state)
      end
    end
  end
  -- Restore global inherit flag and snapshot (if preset was saved with them)
  if not preset_name then return end
  local ig = reaper.GetExtState(_EXT_SEC, "pi_" .. preset_name)
  if ig ~= "" then state.inherit_global = (ig == "1") end
  local guids_str = reaper.GetExtState(_EXT_SEC, "ps_" .. preset_name)
  if guids_str == "" then state.prop_snapshot = nil; return end
  -- Restore enabled key set
  local enabled = {}
  local en_str  = reaper.GetExtState(_EXT_SEC, "pse_" .. preset_name)
  for k in en_str:gmatch("[^|]+") do enabled[k] = true end
  -- Restore per-track slots
  local tracks, count = {}, 0
  for g in guids_str:gmatch("[^|]+") do
    local pfx  = "pst_" .. preset_name .. "_" .. g .. "_"
    local slot = { props = {}, fx_chunk = "" }
    for _, p in ipairs(_PP_TAKE_PROPS) do
      local raw = reaper.GetExtState(_EXT_SEC, pfx .. p.key)
      if raw ~= "" then slot.props[p.key] = raw end
    end
    for _, p in ipairs(_PP_ITEM_PROPS) do
      local raw = reaper.GetExtState(_EXT_SEC, pfx .. p.key)
      if raw ~= "" then slot.props[p.key] = raw end
    end
    local raw_len = reaper.GetExtState(_EXT_SEC, pfx .. "i_len")
    if raw_len ~= "" then slot.props["i_len"] = raw_len end
    slot.fx_chunk = reaper.GetExtState(_EXT_SEC, pfx .. "fx_chunk")
    tracks[g] = slot
    count     = count + 1
  end
  state.prop_snapshot = { tracks = tracks, enabled = enabled, count = count }
end

-- ============================================================
-- One-time ExtState migration: ABS_Layer_Randomizer → TEMPER_Scatter
-- ============================================================
-- Runs at startup if old namespace keys are present. Copies all preset and
-- track-template data to the new namespace, then deletes the old keys so they
-- do not accumulate in reaper.ini.  Groups use persist=false so they need
-- no migration (they only exist within the current REAPER session).
local function _migrate_extstate_presets(old_raw, old_sec)
  local names = {}
  for n in (old_raw .. "|"):gmatch("(.-)|") do
    if n ~= "" then names[#names + 1] = n end
  end
  for _, name in ipairs(names) do
    local function _mv(key)
      local v = reaper.GetExtState(old_sec, key)
      reaper.SetExtState(_EXT_SEC, key, v, true)
      reaper.DeleteExtState(old_sec, key, true)
    end
    _mv("p_" .. name)
    _mv("pi_" .. name)
    _mv("pse_" .. name)
    local guids_raw = reaper.GetExtState(old_sec, "ps_" .. name)
    reaper.SetExtState(_EXT_SEC, "ps_" .. name, guids_raw, true)
    reaper.DeleteExtState(old_sec, "ps_" .. name, true)
    for g in guids_raw:gmatch("[^|]+") do
      local pfx = "pst_" .. name .. "_" .. g .. "_"
      for _, p in ipairs(_PP_TAKE_PROPS) do _mv(pfx .. p.key) end
      for _, p in ipairs(_PP_ITEM_PROPS) do _mv(pfx .. p.key) end
      _mv(pfx .. "i_len")
      _mv(pfx .. "fx_chunk")
    end
  end
end

local function _migrate_from(OLD_SEC)
  local old_list = reaper.GetExtState(OLD_SEC, _LIST_KEY)
  if old_list ~= "" then
    reaper.SetExtState(_EXT_SEC, _LIST_KEY, old_list, true)
    reaper.DeleteExtState(OLD_SEC, _LIST_KEY, true)
    _migrate_extstate_presets(old_list, OLD_SEC)
  end
  local old_tpl = reaper.GetExtState(OLD_SEC, _TPL_KEY)
  if old_tpl ~= "" then
    reaper.SetExtState(_EXT_SEC, _TPL_KEY, old_tpl, true)
    reaper.DeleteExtState(OLD_SEC, _TPL_KEY, true)
    for n in (old_tpl .. "|"):gmatch("(.-)|") do
      if n ~= "" then
        local v = reaper.GetExtState(OLD_SEC, "tpl_" .. n)
        reaper.SetExtState(_EXT_SEC, "tpl_" .. n, v, true)
        reaper.DeleteExtState(OLD_SEC, "tpl_" .. n, true)
      end
    end
  end
end

local function _migrate_extstate()
  _migrate_from("ABS_Layer_Randomizer")  -- pre-v1.4.0
  _migrate_from("TEMPER_Scatter")         -- v1.4.0–v1.5.0 (never deployed; safety net)
end

-- ============================================================
-- Preset structure check + preset-driven track creation (v1.3.0)
-- ============================================================

-- Determine which preset track names are present or absent in the current row list.
-- Names are compared after [;~] sanitization (mirrors preset.serialize behaviour).
-- @param preset_rows  table  Deserialized preset rows from preset.load()
-- @param state        table  App state
-- @return missing string[], matched string[]
local function preset_structure_check(preset_rows, state)
  local current = {}
  for _, row in ipairs(state.rows) do
    current[row.name] = true
    current[(row.name):gsub("[;~]", "_")] = true
  end
  local missing, matched = {}, {}
  for _, pr in ipairs(preset_rows) do
    local key = (pr.name):gsub("[;~]", "_")
    if current[pr.name] or current[key] then
      matched[#matched + 1] = pr.name
    else
      missing[#missing + 1] = pr.name
    end
  end
  return missing, matched
end

-- Insert one leaf track as the last direct child of parent_track.
-- Correctly adjusts I_FOLDERDEPTH of the previous folder-closer so the
-- hierarchy remains valid.  Works for flat folders and folders with sub-folders.
-- @param parent_track  MediaTrack*
-- @param name          string  Name to assign to the new track
-- @return MediaTrack*|nil  The inserted track, or nil on failure
local function _insert_leaf_in_folder(parent_track, name)
  local tc         = reaper.CountTracks(0)
  local parent_idx = track.get_idx(parent_track)

  -- Walk the folder subtree forward from parent_idx+1 until depth drops to ≤ 0.
  -- Record the last track index still inside the folder.
  local depth           = 1
  local last_inside     = nil
  local last_inside_idx = -1
  for ti = parent_idx + 1, tc - 1 do
    if depth <= 0 then break end
    last_inside     = reaper.GetTrack(0, ti)
    last_inside_idx = ti
    depth           = depth + reaper.GetMediaTrackInfo_Value(last_inside, "I_FOLDERDEPTH")
  end

  local insert_idx = (last_inside_idx >= 0) and (last_inside_idx + 1) or (parent_idx + 1)

  -- Un-close the folder one level from the previous last-inside track.
  -- e.g. fd=-1 (closes parent)  → 0 (normal); fd=-2 (closes sub+parent) → -1 (closes sub only).
  if last_inside then
    local old_fd = math.floor(reaper.GetMediaTrackInfo_Value(last_inside, "I_FOLDERDEPTH"))
    if old_fd < 0 then
      reaper.SetMediaTrackInfo_Value(last_inside, "I_FOLDERDEPTH", old_fd + 1)
    end
  end

  reaper.InsertTrackAtIndex(insert_idx, true)
  local new_track = reaper.GetTrack(0, insert_idx)
  reaper.GetSetMediaTrackInfo_String(new_track, "P_NAME", name, true)
  -- New track closes the parent folder (direct child, placed last).
  reaper.SetMediaTrackInfo_Value(new_track, "I_FOLDERDEPTH", -1)
  return new_track
end

-- Create named leaf tracks inside state.parent_track's folder, in order.
-- Each track is appended after the current last child using _insert_leaf_in_folder.
-- @param names  string[]  Track names to create
-- @param state  table     App state (parent_track must be valid)
local function create_tracks_for_preset(names, state)
  if not names or #names == 0 then return end
  if not track.is_valid(state.parent_track) then return end
  reaper.Undo_BeginBlock()
  for _, name in ipairs(names) do
    _insert_leaf_in_folder(state.parent_track, name)
  end
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Temper Vortex: Create preset tracks", -1)
end

-- ============================================================
-- Groups (v0.10.0)
-- ============================================================

-- Convert a REAPER track GUID string to a safe ExtState key segment.
-- Strips all characters that are not alphanumeric.
-- Example: "{4A2B-...}" → "4A2B..."
-- @param guid string  Raw GUID from reaper.GetTrackGUID
-- @return string
local function _guid_to_key(guid)
  return (guid:gsub("[^%w]", ""))
end

-- Derive a deterministic ImGui RGBA color from a track GUID.
-- Uses HSV with fixed S=0.70, V=0.80; hue derived from a fast hash of the key.
-- @param guid string  Raw GUID from reaper.GetTrackGUID
-- @return integer  Packed RGBA (0xRRGGBBAA) suitable for ImGui_PushStyleColor
local function _guid_to_color(guid)
  local key = _guid_to_key(guid)
  -- FNV-1a-inspired hash over bytes of key
  local hash = 2166136261
  for i = 1, #key do
    hash = ((hash ~ key:byte(i)) * 16777619) & 0xFFFFFFFF
  end
  local hue = (hash % 360) / 360.0
  local r, g, b = reaper.ImGui_ColorConvertHSVtoRGB(hue, 0.70, 0.80)
  -- Pack as RGBA (0xRRGGBBAA — alpha=0xFF = full opacity)
  local ri = math.floor(r * 255 + 0.5)
  local gi = math.floor(g * 255 + 0.5)
  local bi = math.floor(b * 255 + 0.5)
  return (ri << 24) | (gi << 16) | (bi << 8) | 0xFF
end

-- ExtState section / key for the anchor group registry.
-- Each registered anchor is stored as a pipe-separated list of GUIDs.
-- Per-group UI state uses section "TEMPER_Vortex_Groups", key "<guid_key>_state".
local _GRP_SEC = "TEMPER_Vortex_Groups"
local _GRP_KEY = "groups"

local groups = {}

-- Load the anchor registry from ExtState.
-- @return string[]  Ordered array of GUID strings (may be empty).
function groups.list()
  local raw = reaper.GetExtState(_GRP_SEC, _GRP_KEY)
  if raw == "" then return {} end
  local result = {}
  for g in raw:gmatch("[^|]+") do result[#result + 1] = g end
  return result
end

-- Persist the registry to ExtState (session-only; persist=false).
local function _groups_save(list)
  reaper.SetExtState(_GRP_SEC, _GRP_KEY, table.concat(list, "|"), false)
end

-- Register a track as an anchor group.  No-op if already registered.
-- @param track  MediaTrack*
-- @return string|nil  GUID on success, nil if ptr invalid.
function groups.add(track)
  if not reaper.ValidatePtr(track, "MediaTrack*") then return nil end
  local guid = reaper.GetTrackGUID(track)
  local list = groups.list()
  for _, g in ipairs(list) do
    if g == guid then return guid end  -- already registered
  end
  list[#list + 1] = guid
  _groups_save(list)
  return guid
end

-- Unregister an anchor group by GUID.  No-op if not found.
function groups.remove(guid)
  local list = groups.list()
  local trimmed = {}
  for _, g in ipairs(list) do
    if g ~= guid then trimmed[#trimmed + 1] = g end
  end
  _groups_save(trimmed)
end

-- Find a MediaTrack by GUID via linear scan.  Returns nil if not found.
function groups.find_track(guid)
  for i = 0, reaper.CountTracks(0) - 1 do
    local t = reaper.GetTrack(0, i)
    if reaper.GetTrackGUID(t) == guid then return t end
  end
  return nil
end

-- Return the display name of a registered group.
-- Falls back to a truncated key if the track is gone.
function groups.get_name(guid)
  local t = groups.find_track(guid)
  if t then
    local _, name = reaper.GetTrackName(t)
    return name or ("?" .. _guid_to_key(guid):sub(1, 8))
  end
  return "?" .. _guid_to_key(guid):sub(1, 8)
end

-- Return the packed RGBA color for a group (deterministic from GUID).
function groups.get_color(guid)
  return _guid_to_color(guid)
end

-- Scan all registered anchor groups for which one's child tracks appear in
-- the current Paste Properties ExtState GUIDs.  Returns the matching group
-- GUID, or nil when no registered group contains any of those tracks.
local function _find_pp_matching_group()
  local guids_str = reaper.GetExtState(_PP_SEC, "src2_track_guids")
  if guids_str == "" then return nil end
  local pp_set = {}
  for g in guids_str:gmatch("[^|]+") do pp_set[g] = true end
  for _, grp_guid in ipairs(groups.list()) do
    local anchor = groups.find_track(grp_guid)
    if anchor then
      local targets = get_generation_targets(anchor, track.get_name(anchor))
      for _, tgt in ipairs(targets) do
        if pp_set[reaper.GetTrackGUID(tgt.track)] then return grp_guid end
      end
    end
  end
  return nil
end

-- ============================================================
-- Context detection
-- ============================================================

-- Return the most contextually relevant track for group detection.
-- Priority: last-touched track → first-selected item's track → first selected track.
-- @return MediaTrack*|nil
local function _get_active_track()
  local t = reaper.GetLastTouchedTrack()
  if reaper.ValidatePtr(t, "MediaTrack*") then return t end
  if reaper.CountSelectedMediaItems(0) > 0 then
    local item = reaper.GetSelectedMediaItem(0, 0)
    if item then
      local it = reaper.GetMediaItemTrack(item)
      if reaper.ValidatePtr(it, "MediaTrack*") then return it end
    end
  end
  local st = reaper.GetSelectedTrack(0, 0)
  if reaper.ValidatePtr(st, "MediaTrack*") then return st end
  return nil
end

-- Walk up the folder hierarchy from `track`, returning the GUID of the first
-- registered anchor found.  Bounded at 16 levels to prevent runaway loops.
-- @param track MediaTrack*
-- @return string|nil  GUID of matching anchor, or nil if none found.
local function _find_anchor_for_track(track)
  local list = groups.list()
  if #list == 0 then return nil end
  local anchors = {}
  for _, g in ipairs(list) do anchors[g] = true end
  local t = track
  for _ = 1, 16 do
    if not reaper.ValidatePtr(t, "MediaTrack*") then break end
    local g = reaper.GetTrackGUID(t)
    if anchors[g] then return g end
    t = reaper.GetParentTrack(t)
    if not t then break end
  end
  return nil
end

-- Track which anchor group the currently active REAPER track belongs to.
-- Updates app.context_guid (visual hint only) — does NOT auto-switch the
-- loaded group.  User must click a chip to perform a full switch.
-- @param app table  Top-level app wrapper (mutated: app.context_guid)
local function _check_context_switch(app)
  local track = _get_active_track()
  if not track then return end
  local found = _find_anchor_for_track(track)
  app.context_guid = found  -- nil when track is outside all registered anchors
end

-- ============================================================
-- Per-group autosave / autoload
-- ============================================================

-- Serialize the current group's UI state to ExtState (session-only).
-- Persists: row settings (mode, active, include_parent, exclude_text,
-- inherit_props) via preset.serialize, plus the inherit_global flag.
-- Called by _check_context_switch before switching away from a group.
-- @param app table  App wrapper (reads app.active_guid and app.state)
function _autosave_group_state(app)
  if not app.active_guid then return end
  local st = app.state
  if not st or not st.rows then return end
  local key = _guid_to_key(app.active_guid)
  reaper.SetExtState(_GRP_SEC, key .. "_rows", preset.serialize(st.rows),        false)
  reaper.SetExtState(_GRP_SEC, key .. "_ig",   st.inherit_global and "1" or "0", false)
end

-- Restore a group's UI state from ExtState into app.state.
-- No-op when no saved state exists for the incoming group (first visit).
-- Row matching is by track name; unmatched rows keep their defaults.
-- Called by _check_context_switch after updating app.active_guid.
-- @param app table  App wrapper (reads app.active_guid; mutates app.state)
function _autoload_group_state(app)
  if not app.active_guid then return end
  local st = app.state
  if not st or not st.rows then return end
  local key = _guid_to_key(app.active_guid)
  local raw = reaper.GetExtState(_GRP_SEC, key .. "_rows")
  if raw ~= "" then
    preset.apply(preset.deserialize(raw), st)
  end
  local ig = reaper.GetExtState(_GRP_SEC, key .. "_ig")
  if ig ~= "" then st.inherit_global = (ig == "1") end
end

-- Save the outgoing group, build a fresh per-group state for the incoming anchor,
-- overlay saved row settings, and kick off a search pass.
-- The MediaDB index is shared: copied from app.state.index (moved to app.index in
-- the app wrapper refactor chunk).
-- No-op when guid already matches the active group or the anchor track is gone.
-- @param app  table  App wrapper (mutated: app.active_guid, app.state)
-- @param guid string  GUID of the incoming anchor group
local function _switch_to_group(app, guid)
  if guid == app.active_guid then return end
  -- Defer when MediaDB is still loading — prevents a partial-index race condition.
  -- The defer loop resolves app.pending_guid once loading completes.
  if app.state.status == "loading" or app.state.status == "init" then
    app.pending_guid = guid
    return
  end
  local anchor = groups.find_track(guid)
  if not anchor then return end  -- stale GUID (track deleted from project)

  if app.active_guid then
    _autosave_group_state(app)
  end

  local anchor_name = track.get_name(anchor)
  local targets     = get_generation_targets(anchor, anchor_name)
  local new_rows    = {}
  for _, tgt in ipairs(targets) do
    new_rows[#new_rows + 1] = make_row(tgt.track, tgt.parent_name, tgt.group, tgt.parent_track)
  end

  -- Shared index is referenced from the current state; app wrapper refactor will
  -- lift it to app.index.  file_lists needed by any force-rescan path.
  local new_st = {
    status          = "searching",
    error_msg       = nil,
    index           = app.state.index,
    file_lists      = app.state.file_lists,
    load_idx        = 0,
    parse_fh        = nil,
    parse_cur       = nil,
    parse_data_seen = false,
    search_idx      = 0,
    parent_track    = anchor,
    parent_name     = anchor_name,
    rows            = new_rows,
    child_count     = #targets,
    preset_name_buf      = "",
    active_preset_name   = nil,  -- nil = "Default"; string = name of loaded preset (C16)
    preset_overwrite_buf = nil,  -- set when overwrite confirmation is open (C16)
    global_not           = { text = "", tokens = {} },
    group_not            = {},
    var_n_buf            = "1",
    var_x_buf            = "4.0",
    var_unit             = 0,
    font_bold            = app.state.font_bold,
    inherit_global       = true,
    prop_snapshot        = nil,
    tpl_name_buf         = "",
    pending_preset_name  = nil,
    pending_preset_rows  = nil,
    pending_missing      = nil,
    _need_mismatch_popup = false, -- D4: deferred OpenPopup flag (must open from main-window context)
    last_sel_idx         = nil,   -- U2: anchor row index for shift+click range select
    _row_clicked_this_frame = false,  -- U4: set when a row Selectable fires this frame
  }

  app.active_guid  = guid
  app.context_guid = guid  -- keep context in sync when user explicitly switches
  app.state        = new_st

  -- Auto-select the anchor folder track in REAPER so the user sees exactly
  -- which track group is now active without needing to click in the arrange view.
  local tc = reaper.CountTracks(0)
  for ti = 0, tc - 1 do reaper.SetTrackSelected(reaper.GetTrack(0, ti), false) end
  reaper.SetTrackSelected(anchor, true)

  -- Overlay any row settings previously saved for this group.
  _autoload_group_state(app)
end

-- ============================================================
-- State machine
-- ============================================================

-- Finalise the current in-progress entry from a chunked parse and append it to the index.
-- No-op when state.parse_cur is nil (e.g. at EOF or after transition).
-- @param state table  App state
local function _parse_finalize(state)
  local cur = state.parse_cur
  if not cur then return end
  local h = db.build_haystack(cur)
  if h ~= "" then
    state.index[#state.index + 1] = { filepath = cur.filepath, haystack = h }
  end
  state.parse_cur       = nil
  state.parse_data_seen = false
end

-- Process up to _LINES_PER_TICK lines from the current file, or open the next file.
-- Transitions state to "searching" when all files are exhausted.
-- Called once per defer tick while state.status == "loading".
-- @param state table  App state (mutated in place)
local function _tick_loading(state)
  -- Open next file when there is no active reader.
  if not state.parse_fh then
    state.load_idx = state.load_idx + 1
    if state.load_idx > #state.file_lists then
      _parse_finalize(state)
      -- Persist to disk so the next session loads instantly from cache.
      if not state.cache_skip_save then
        db.save_cache(state.file_lists, state.index)
      end
      local targets     = get_generation_targets(state.parent_track, state.parent_name)
      state.child_count = #targets
      state.rows        = {}
      for _, tgt in ipairs(targets) do
        state.rows[#state.rows + 1] = make_row(tgt.track, tgt.parent_name, tgt.group, tgt.parent_track)
      end
      state.search_idx = 0
      state.status     = "searching"
      return
    end
    local fh = io.open(state.file_lists[state.load_idx], "r")
    if not fh then return end  -- unreadable: load_idx already advanced; next tick skips it
    state.parse_fh        = fh
    state.parse_cur       = nil
    state.parse_data_seen = false
  end

  -- Process up to _LINES_PER_TICK lines; keep GUI responsive between ticks.
  local n = 0
  while n < _LINES_PER_TICK do
    local line = state.parse_fh:read("*l")
    if not line then
      _parse_finalize(state)
      state.parse_fh:close()
      state.parse_fh = nil
      return
    end
    n = n + 1
    if line:sub(1, 5) == "FILE " then
      _parse_finalize(state)
      local p = line:match('^FILE "([^"]+)"') or line:match("^FILE (%S+)")
      if p then
        state.parse_cur       = { filepath = p, keywords = "", category = "",
                                  subcategory = "", catid = "", title = "", description = "" }
        state.parse_data_seen = false
      end
    elseif state.parse_cur and line:sub(1, 5) == "DATA " then
      if not state.parse_data_seen then
        state.parse_cur.title = db.parse_title_from_data(line) or ""
        state.parse_data_seen = true
      end
      local d = line:match('"d:([^"]*)"')
      if d and d ~= "" then state.parse_cur.description = d end
    elseif state.parse_cur and line:sub(1, 15) == "USER IXML:USER:" then
      local field, value = db.parse_user_field(line)
      if field and _PARSE_WANTED[field] then
        state.parse_cur[field:lower()] = value
      end
    end
  end
end

-- Advance the application state machine by one step.
-- "loading" processes _LINES_PER_TICK lines per call (non-blocking at ~60 fps).
-- "searching" searches one row per call.
-- @param state table  App state (mutated in place)
local function tick_state(state)
  if state.status == "init" then
    if reaper.CountSelectedTracks(0) == 0 then
      state.status = "select_anchor"
      return
    end
    state.parent_track = reaper.GetSelectedTrack(0, 0)
    if not track.is_folder(state.parent_track) then
      -- Auto-resolve: walk up to the nearest folder-track ancestor so the script
      -- works even when a child or grandchild track is selected at launch.
      local ancestor = track.find_folder_ancestor(state.parent_track)
      if not ancestor then
        state.status = "select_anchor"
        return
      end
      state.parent_track = ancestor
    end
    state.parent_name = track.get_name(state.parent_track)
    state.file_lists  = db.find_file_lists()
    if #state.file_lists == 0 then
      state.status    = "error"
      state.error_msg = "No MediaDB files found. Run Media Explorer scan first."
      return
    end
    -- Fast path: try loading the pre-built cache before starting a full parse.
    -- _load_cache returns nil when no cache exists or when any ReaperFileList
    -- has changed size since the cache was written.
    local cached = db.load_cache(state.file_lists)
    if cached then
      state.index      = cached
      state.from_cache = true
      local targets     = get_generation_targets(state.parent_track, state.parent_name)
      state.child_count = #targets
      state.rows        = {}
      for _, tgt in ipairs(targets) do
        state.rows[#state.rows + 1] = make_row(tgt.track, tgt.parent_name, tgt.group, tgt.parent_track)
      end
      state.search_idx = 0
      state.status     = "searching"
    else
      state.load_idx        = 0
      state.index           = {}
      state.cache_skip_save = false
      state.status          = "loading"
    end

  elseif state.status == "loading" then
    _tick_loading(state)

  elseif state.status == "searching" then
    state.search_idx = state.search_idx + 1
    if state.search_idx <= #state.rows then
      search_row(state.rows[state.search_idx], state.index, state)
    else
      state.status = "ready"
    end

  elseif state.status == "ready" then
    -- Drain incremental re-search queue (one row per frame, no reload)
    if state._research_queue and #state._research_queue > 0 then
      local idx = table.remove(state._research_queue, 1)
      if state.rows[idx] then search_row(state.rows[idx], state.index, state) end
    end
    sync_child_rows(state)
    if state.status ~= "ready" then return end  -- sync may set error
    -- Detect top-level parent rename from REAPER side
    local new_par = track.get_name(state.parent_track)
    if new_par ~= state.parent_name then
      state.parent_name = new_par
      for _, row in ipairs(state.rows) do
        if row.group == nil then
          row.parent_name = new_par
        else
          row.parent_name = new_par .. " " .. row.group
        end
        if row.include_parent then search_row(row, state.index, state) end
      end
    end
  end
end

-- ============================================================
-- GUI rendering
-- ============================================================

local COL_RED   = 0xC0392BFF
local COL_AMBER = 0xCCA030FF
local COL_TEAL  = 0x2A8A7AFF
-- Row selection tint (dark teal): shown on rows selected in the GUI.
local COL_SEL_BG = 0x1A2A2AFF  -- dark teal tint, matches Col_Header

-- Spectral Core palette — mirrors rsg_theme.SC for direct access.
local SC = {
  WINDOW       = 0x0E0E10FF,
  PANEL        = 0x1E1E20FF,
  PANEL_HIGH   = 0x282828FF,
  PANEL_TOP    = 0x323232FF,
  HOVER_LIST   = 0x39393BFF,
  PRIMARY      = 0x26A69AFF,
  PRIMARY_LT   = 0x66D9CCFF,
  PRIMARY_HV   = 0x30B8ACFF,
  PRIMARY_AC   = 0x1A8A7EFF,
  TERTIARY     = 0xDA7C5AFF,
  TERTIARY_HV  = 0xE08A6AFF,
  TERTIARY_AC  = 0xC46A4AFF,
  TEXT_ON      = 0xDEDEDEFF,
  TEXT_MUTED   = 0xBCC9C6FF,
  TEXT_OFF     = 0x505050FF,
  OMIT_BG      = 0x380D00FF,
  OMIT_HV      = 0x4A1200FF,
  ERROR_RED    = 0xC0392BFF,
  ACTIVE_DARK  = 0x141416FF,
  ACTIVE_DARKER= 0x161618FF,
  TITLE_BAR    = 0x1A1A1CFF,
  BORDER_INPUT = 0x505055FF,
  BORDER_SUBTLE= 0x50505066,
  ICON_DISABLED= 0x606060FF,
  HOVER_GHOST  = 0xFFFFFF1A,
  ACTIVE_GHOST = 0x0000001F,
  HOVER_INACTIVE = 0x2A2A2CFF,
  DEL_BTN      = 0x282828FF,
  DEL_HV       = 0x39393BFF,
  DEL_AC       = 0x1E1E20FF,
  BTN_NEUTRAL  = 0x4A4A4AFF,
  BTN_NEUTRAL_HV = 0x5E5E5EFF,
  BTN_NEUTRAL_AC = 0x3A3A3AFF,
  BTN_DARK     = 0x2A2A2AFF,
  BTN_DARK_HV  = 0x3A3A3AFF,
  BTN_DARK_AC  = 0x1A1A1AFF,
  BTN_CONFIRM  = 0x2A4A3AFF,
  BTN_CONFIRM_HV = 0x3A6A50FF,
  BTN_CONFIRM_AC = 0x1A3A2AFF,
  OMIT_ACTIVE  = 0x553010FF,
  OMIT_ACTIVE_HV = 0x664020FF,
  GROUP_HDR_BG = 0x202224FF,
}

--- Push 3 button colors (Button, ButtonHovered, ButtonActive). Pop with PopStyleColor(ctx, 3).
local function push_btn(ctx, bg, hv, ac)
  local C = reaper
  C.ImGui_PushStyleColor(ctx, C.ImGui_Col_Button(),        bg)
  C.ImGui_PushStyleColor(ctx, C.ImGui_Col_ButtonHovered(), hv)
  C.ImGui_PushStyleColor(ctx, C.ImGui_Col_ButtonActive(),  ac)
end

-- Mode color lookup — shared between render_row and render_mini_panel.
local MODE_COL = {
  free   = { SC.PANEL_TOP, SC.HOVER_LIST,  SC.ACTIVE_DARK, SC.PRIMARY },
  unique = { SC.PRIMARY,   SC.PRIMARY_HV,  SC.PRIMARY_AC,  SC.WINDOW },
  lock   = { SC.TERTIARY,  SC.TERTIARY_HV, SC.TERTIARY_AC, 0x00000000 },
}
local MODE_LBL = { free = "FREE", unique = "UNIQ", lock = "LOCK" }

-- ============================================================
-- Action handlers — contextual, keyboard-shortcut aware
-- ============================================================
-- Each entry is the shared target for a Vortex GUI button AND an
-- rsg_actions keyboard dispatch. Both paths call through here so they
-- stay bit-identical.
--
-- Target selection uses `row._user_sel` (flipped only by explicit clicks
-- in the Vortex table), NOT `row.selected` (which also moves under the
-- REAPER → Vortex track-selection sync). That matters for keyboard-driven
-- actions: a child track selected in REAPER's track panel must not
-- silently narrow a Vortex batch action to that row.
local vortex_actions = {}

local _VX_MODES = { "free", "unique", "lock" }

local function _vx_user_sel_count(state)
  local any_sel, n_sel = false, 0
  for _, r in ipairs(state.rows) do
    if r._user_sel then any_sel = true; n_sel = n_sel + 1 end
  end
  return any_sel, n_sel
end

-- Collect the target row set for a contextual batch action:
-- user-selected rows if any, else every row.
local function _vx_targets(state)
  local any_sel = _vx_user_sel_count(state)
  local out = {}
  for _, r in ipairs(state.rows) do
    if (not any_sel) or r._user_sel then out[#out + 1] = r end
  end
  return out
end

local function _vx_cycle_mode_on_row(state, r)
  local from_mode = r.mode or "free"
  local cur_i = 1
  for ii, m in ipairs(_VX_MODES) do if m == from_mode then cur_i = ii; break end end
  local next_mode = _VX_MODES[(cur_i % #_VX_MODES) + 1]
  if next_mode == "lock" then
    local le = r.current_idx and state.index[r.current_idx]
    r.lock_filepath = r.last_rolled_filepath or (le and le.filepath)
  elseif from_mode == "lock" then
    r.lock_filepath = nil
  end
  r.mode = next_mode
end

function vortex_actions.do_roll(state)
  local any_sel, n_sel = _vx_user_sel_count(state)
  local all_sel     = (any_sel and n_sel == #state.rows)
  local roll_as_sel = any_sel and not all_sel
  if roll_as_sel then do_roll_selected(state) else randomize_all(state) end
end

function vortex_actions.do_variations(state)
  local any_sel, n_sel = _vx_user_sel_count(state)
  local all_sel    = (any_sel and n_sel == #state.rows)
  local var_as_sel = any_sel and not all_sel
  do_variations(state, var_as_sel)
end

function vortex_actions.do_capture(state)
  local has_pp = reaper.GetExtState("TEMPER_Vortex", "src2_track_count") ~= ""
  local snap = _pp_capture_from_selection(state)
  if not snap and has_pp then snap = _pp_capture(state) end
  if snap then state.prop_snapshot = snap end
end

function vortex_actions.toggle_active(state)
  local targets = _vx_targets(state)
  local all_on = true
  for _, r in ipairs(targets) do
    if not r.active then all_on = false; break end
  end
  local new_state = not all_on
  for _, r in ipairs(targets) do r.active = new_state end
end

function vortex_actions.toggle_par(state)
  local targets = _vx_targets(state)
  local target_set = {}
  for _, r in ipairs(targets) do target_set[r] = true end
  local any_on = false
  for _, r in ipairs(targets) do
    if r.include_parent then any_on = true; break end
  end
  local new_par = not any_on
  state._research_queue = state._research_queue or {}
  for i, r in ipairs(state.rows) do
    if target_set[r] and r.include_parent ~= new_par then
      r.include_parent = new_par
      state._research_queue[#state._research_queue + 1] = i
      search_row(r, state.index, state)
    end
  end
end

function vortex_actions.toggle_inh(state)
  local targets = _vx_targets(state)
  local any_on = false
  for _, r in ipairs(targets) do
    if r.inherit_props then any_on = true; break end
  end
  local new_inh = not any_on
  for _, r in ipairs(targets) do r.inherit_props = new_inh end
end

function vortex_actions.toggle_inh_global(state)
  state.inherit_global = not state.inherit_global
end

function vortex_actions.cycle_mode(state)
  -- Advance each target from its OWN current mode. Earlier version cycled
  -- from the group's dominant mode and left off-dominant rows stuck, so
  -- repeated clicks appeared to do nothing.
  for _, r in ipairs(_vx_targets(state)) do
    _vx_cycle_mode_on_row(state, r)
  end
end

function vortex_actions.toggle_time_unit(state)
  state.var_unit = 1 - state.var_unit
end

-- SelectableFlags_AllowOverlap lets widgets (On button, inputs) overlap the
-- row-spanning selectable while remaining interactive.  Falls back to 0 (safe)
-- on older ReaImGui builds that lack the flag.
local _SEL_ALLOW_OVERLAP =
    (reaper.ImGui_SelectableFlags_AllowOverlap
        and reaper.ImGui_SelectableFlags_AllowOverlap())
    or (reaper.ImGui_SelectableFlags_AllowItemOverlap
        and reaper.ImGui_SelectableFlags_AllowItemOverlap())
    or 0

-- Status bar: loading progress, search progress, or index/track summary.
local function render_status_bar(ctx, state)
  local s = state.status
  if s == "loading" then
    local entry_info = #state.index > 0
                       and string.format("  |  %d entries", #state.index) or ""
    reaper.ImGui_TextColored(ctx, COL_AMBER,
      string.format("Loading MediaDB... (file %d / %d%s)", state.load_idx, #state.file_lists, entry_info))
  elseif s == "searching" then
    reaper.ImGui_TextColored(ctx, COL_AMBER,
      string.format("Searching... (%d / %d tracks)", state.search_idx, #state.rows))
  elseif s == "ready" then
    local src = state.from_cache and " (cached)" or ""
    reaper.ImGui_TextDisabled(ctx,
      string.format("%d entries indexed%s  |  %d child tracks", #state.index, src, #state.rows))
  elseif s == "error" then
    reaper.ImGui_TextColored(ctx, COL_RED, state.error_msg or "Unknown error.")
  end
end

-- Loading / searching body: shown in the main window area while not yet ready.
local function render_loading_body(ctx, state)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Spacing(ctx)
  if state.status == "loading" then
    reaper.ImGui_TextDisabled(ctx, string.format(
      "Indexing %d / %d file(s) — %d entries so far",
      state.load_idx, #state.file_lists, #state.index))
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_TextDisabled(ctx, "Large libraries may take several seconds on first scan.\nSubsequent loads use a local cache and are near-instant.")
  elseif state.status == "searching" then
    local pct = (#state.rows > 0) and (state.search_idx / #state.rows) or 0
    reaper.ImGui_ProgressBar(ctx, pct, -1, 0,
      string.format("track %d / %d", state.search_idx, #state.rows))
  else
    reaper.ImGui_TextDisabled(ctx, "Initialising...")
  end
end

-- C16: Preset bar — combo dropdown + Save button, pinned right on Row 1.
-- Replaces the old Save / Load button pair.
local function render_preset_bar(ctx, state)
  local R        = reaper
  local btn_w    = 44
  local item_spacing = 6
  -- v2.1: Dynamic combo width — fills available column width minus Save button.
  local avail_w = select(1, R.ImGui_GetContentRegionAvail(ctx))
  local combo_w = avail_w - btn_w - item_spacing

  push_btn(ctx, SC.BTN_NEUTRAL, SC.BTN_NEUTRAL_HV, SC.BTN_NEUTRAL_AC)

  -- Preset dropdown
  local display = state.active_preset_name or "Default"
  R.ImGui_SetNextItemWidth(ctx, combo_w)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Header(),        SC.PANEL_HIGH)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_HeaderHovered(), SC.HOVER_LIST)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_HeaderActive(),  SC.ACTIVE_DARK)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_PopupBg(),       SC.PANEL)
  if R.ImGui_BeginCombo(ctx, "##presets", display) then
    -- "Default" entry (not deletable)
    if R.ImGui_Selectable(ctx, "Default", display == "Default") then
      state.active_preset_name = nil
    end
    R.ImGui_Separator(ctx)
    local names  = preset.list()
    local to_del = nil
    for _, pname in ipairs(names) do
      push_btn(ctx, SC.DEL_BTN, SC.DEL_HV, SC.DEL_AC)
      if R.ImGui_SmallButton(ctx, "x##cdel_" .. pname) then
        to_del = pname
      end
      R.ImGui_PopStyleColor(ctx, 3)
      R.ImGui_SameLine(ctx)
      local sel = R.ImGui_Selectable(ctx, pname, pname == display)
      if sel then
        local prows = preset.load(pname)
        if prows then
          local missing, _ = preset_structure_check(prows, state)
          if #missing == 0 then
            preset.apply(prows, state, pname)
            state.active_preset_name = pname
          else
            state.pending_preset_name  = pname
            state.pending_preset_rows  = prows
            state.pending_missing      = missing
            state._need_mismatch_popup = true  -- open from main-window context in render_preset_popups
          end
        end
        R.ImGui_CloseCurrentPopup(ctx)
      end
    end
    if to_del then
      preset.delete(to_del)
      if state.active_preset_name == to_del then
        state.active_preset_name = nil
      end
    end
    R.ImGui_EndCombo(ctx)
  end
  R.ImGui_PopStyleColor(ctx, 4)  -- Header + HeaderHovered + HeaderActive + PopupBg

  -- Save button
  R.ImGui_SameLine(ctx)
  if R.ImGui_Button(ctx, "Save##pbar", btn_w, 0) then
    if state.active_preset_name then
      state.preset_overwrite_buf = state.active_preset_name
      R.ImGui_OpenPopup(ctx, "overwrite_preset##popup")
    else
      state.preset_name_buf = ""
      R.ImGui_OpenPopup(ctx, "save_preset##popup")
    end
  end
  R.ImGui_PopStyleColor(ctx, 3)
  if R.ImGui_IsItemHovered(ctx) then
    R.ImGui_SetTooltip(ctx, state.active_preset_name
      and ("Overwrite preset: " .. state.active_preset_name)
      or  "Save current state as a new preset")
  end
end

-- Save popup, overwrite confirmation popup, and mismatch popup.
-- The old "Load" popup is replaced by the combo dropdown in render_preset_bar (C16).
local function render_preset_popups(ctx, state)
  if reaper.ImGui_BeginPopup(ctx, "save_preset##popup") then
    reaper.ImGui_Text(ctx, "Preset name:")
    reaper.ImGui_SetNextItemWidth(ctx, 200)
    local _, new_buf = reaper.ImGui_InputText(ctx, "##pname", state.preset_name_buf)
    state.preset_name_buf = new_buf
    local can_save = (state.preset_name_buf ~= "")
    if not can_save then reaper.ImGui_BeginDisabled(ctx) end
    if reaper.ImGui_Button(ctx, "Save##do") then
      local pname = state.preset_name_buf:gsub("[|;~]", "_")
      preset.save(pname, state.rows, state)
      state.active_preset_name = pname
      state.preset_name_buf = ""
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    if not can_save then reaper.ImGui_EndDisabled(ctx) end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Cancel##psave") then
      state.preset_name_buf = ""
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  end

  -- C16: Overwrite confirmation popup.
  if reaper.ImGui_BeginPopup(ctx, "overwrite_preset##popup") then
    local name = state.preset_overwrite_buf or "?"
    reaper.ImGui_Text(ctx, string.format('Overwrite preset "%s"?', name))
    reaper.ImGui_Spacing(ctx)
    if reaper.ImGui_Button(ctx, "Overwrite##do") then
      preset.save(name, state.rows, state)
      state.preset_overwrite_buf = nil
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Save as New##do") then
      state.preset_name_buf = ""
      state.preset_overwrite_buf = nil
      reaper.ImGui_CloseCurrentPopup(ctx)
      reaper.ImGui_OpenPopup(ctx, "save_preset##popup")
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Cancel##ow") then
      state.preset_overwrite_buf = nil
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  end

  -- Preset structure mismatch dialog.
  -- Opens when a loaded preset references tracks not present in the current folder.
  -- OpenPopup must be called from the main-window context (not from inside BeginCombo).
  if state._need_mismatch_popup then
    reaper.ImGui_OpenPopup(ctx, "preset_mismatch##popup")
    state._need_mismatch_popup = false
  end
  if reaper.ImGui_BeginPopup(ctx, "preset_mismatch##popup") then
    local missing = state.pending_missing or {}
    reaper.ImGui_TextColored(ctx, COL_AMBER, "Track structure mismatch")
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_TextDisabled(ctx, string.format(
      "%d track(s) in the preset are not in the current folder:", #missing))
    for _, mname in ipairs(missing) do
      reaper.ImGui_Text(ctx, "  \xe2\x80\xa2 " .. mname)
    end
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)
    -- Option A: apply only to tracks that exist.
    if reaper.ImGui_Button(ctx, "Apply to matching tracks") then
      if state.pending_preset_rows then
        preset.apply(state.pending_preset_rows, state, state.pending_preset_name)
        state.active_preset_name = state.pending_preset_name
      end
      state.pending_preset_name = nil
      state.pending_preset_rows = nil
      state.pending_missing     = nil
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, "Apply preset settings to tracks that exist;\nskip the missing ones.")
    end
    reaper.ImGui_SameLine(ctx)
    -- Option B: create missing tracks inside the folder, then apply.
    if reaper.ImGui_Button(ctx, "Create missing + Apply") then
      if state.pending_missing and state.pending_preset_rows then
        create_tracks_for_preset(state.pending_missing, state)
        sync_child_rows(state)
        if state.status == "ready" then
          preset.apply(state.pending_preset_rows, state, state.pending_preset_name)
          state.active_preset_name = state.pending_preset_name
        end
      end
      state.pending_preset_name = nil
      state.pending_preset_rows = nil
      state.pending_missing     = nil
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx,
        "Insert missing tracks into the current folder,\nthen apply the full preset.")
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Cancel") then
      state.pending_preset_name = nil
      state.pending_preset_rows = nil
      state.pending_missing     = nil
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  end
end

-- Header: two-row toolbar.
-- Row 1 (search): [parent input] [NOT input] | N: [n] x [x] [unit]
-- Row 2 (actions): [Rescan] [Color Tracks] [Roll All] [Variations] | [Save] [Load]
-- Trim to cue is a hidden background setting (CONFIG.trim_to_first_cue stays true).
-- C14: Settings gear button, pinned to the right of Row 2.
-- Call after the last Row 2 widget (Variations) with SameLine already set.
local function render_settings_button(ctx)
  local R   = reaper
  local w   = R.ImGui_GetWindowWidth(ctx)
  local btn = 28
  R.ImGui_SetCursorPosX(ctx, w - btn - 8)
  push_btn(ctx, SC.BTN_DARK, SC.BTN_DARK_HV, SC.BTN_DARK_AC)
  if R.ImGui_Button(ctx, "\xe2\x9a\x99##settings", btn, 0) then  -- ⚙ gear
    R.ImGui_OpenPopup(ctx, "##settings_popup")
  end
  R.ImGui_PopStyleColor(ctx, 3)
  if R.ImGui_IsItemHovered(ctx) then
    R.ImGui_SetTooltip(ctx, "Settings")
  end
end

-- C14/C15/RSG-115: Settings popup — Rescan + Color Tracks + Activate (trial only).
local function render_settings_popup(ctx, state, app)
  local R = reaper
  if not R.ImGui_BeginPopup(ctx, "##settings_popup") then return end
  local lic_status = app and app.lic_status

  R.ImGui_Text(ctx, "Settings")
  R.ImGui_Separator(ctx)
  R.ImGui_Spacing(ctx)

  -- RSG-115: Rescan moved here from Row 2.
  if R.ImGui_Button(ctx, "Rescan##settings") then
    if state.parse_fh then state.parse_fh:close(); state.parse_fh = nil end
    state.parse_cur       = nil
    state.parse_data_seen = false
    state.load_idx        = 0
    state.index           = {}
    state.from_cache      = false
    state.cache_skip_save = false
    state.file_lists      = db.find_file_lists()
    state.status          = "loading"
    for _, row in ipairs(state.rows) do
      row.current_idx = nil
    end
    R.ImGui_CloseCurrentPopup(ctx)
  end
  if R.ImGui_IsItemHovered(ctx) then
    R.ImGui_SetTooltip(ctx,
      "Re-scan REAPER's MediaDB from disk, bypassing the cache.\n" ..
      "Use after adding new files to your library.")
  end
  R.ImGui_Spacing(ctx)
  R.ImGui_Separator(ctx)
  R.ImGui_Spacing(ctx)

  -- C15: Color Tracks moved here from Row 2.
  if R.ImGui_Button(ctx, "Color Tracks##settings") then
    apply_track_colors(state)
    R.ImGui_CloseCurrentPopup(ctx)
  end
  if R.ImGui_IsItemHovered(ctx) then
    R.ImGui_SetTooltip(ctx,
      "Color REAPER tracks by hierarchy:\n" ..
      "  Parent         \xe2\x86\x92 near-black  (structural)\n" ..
      "  Sub-folder     \xe2\x86\x92 dark blue-grey  (structural)\n" ..
      "  Child active   \xe2\x86\x92 teal\n" ..
      "  Child inactive \xe2\x86\x92 grey\n" ..
      "  Grandchild active   \xe2\x86\x92 bright teal\n" ..
      "  Grandchild inactive \xe2\x86\x92 dark grey")
  end

  -- Activate button (trial mode only)
  if lic_status == "trial" then
    R.ImGui_Spacing(ctx)
    R.ImGui_Separator(ctx)
    R.ImGui_Spacing(ctx)
    if R.ImGui_Button(ctx, "Activate...##settings_lic") then
      lic.open_dialog(ctx)
      R.ImGui_CloseCurrentPopup(ctx)
    end
  end

  -- Close Vortex
  R.ImGui_Spacing(ctx)
  R.ImGui_Separator(ctx)
  R.ImGui_Spacing(ctx)
  if R.ImGui_Button(ctx, "Close Vortex##settings") then
    if app then app._close_requested = true end
    R.ImGui_CloseCurrentPopup(ctx)
  end

  R.ImGui_EndPopup(ctx)
end

-- render_header was removed in v2.1 layout (replaced by render_mini_panel + render_right_column).
-- Deleted in Phase 1 cleanup (2026-04-06 architectural review).
-- v2.0: Two-line track card — line 1: controls, line 2: filename.
-- Badge-style TRK/PAR/INH toggles per the approved mockup.
local function _render_badge(ctx, label, id, on, i)
  local C = reaper
  local bg  = on and SC.PANEL_TOP    or SC.PANEL
  local hv  = on and SC.HOVER_LIST   or SC.HOVER_INACTIVE
  local ac  = on and SC.ACTIVE_DARK  or SC.ACTIVE_DARKER
  local txt = on and SC.PRIMARY      or SC.TEXT_OFF
  C.ImGui_PushStyleColor(ctx, C.ImGui_Col_Button(),        bg)
  C.ImGui_PushStyleColor(ctx, C.ImGui_Col_ButtonHovered(), hv)
  C.ImGui_PushStyleColor(ctx, C.ImGui_Col_ButtonActive(),  ac)
  C.ImGui_PushStyleColor(ctx, C.ImGui_Col_Text(),          txt)
  local bw = C.ImGui_CalcTextSize(ctx, "UNIQ") + 8  -- match mode button width
  local bh = C.ImGui_GetTextLineHeight(ctx) + 2     -- match mode button height
  local clicked = C.ImGui_Button(ctx, label .. "##" .. id .. i, bw, bh)
  C.ImGui_PopStyleColor(ctx, 4)
  return clicked
end

-- ── render_row sub-functions ──────────────────────────────────────────────

local function _render_row_active_col(ctx, state, row, i)
  local C = reaper
  push_btn(ctx, 0x00000000, SC.HOVER_LIST, SC.ACTIVE_DARK)
  local act_bx, act_by = C.ImGui_GetCursorScreenPos(ctx)
  if C.ImGui_Button(ctx, "##act" .. i, 16, 16) then
    local new_active = not row.active
    row.active = new_active
    if row.selected then
      for _, r in ipairs(state.rows) do
        if r.selected then r.active = new_active end
      end
    end
  end
  C.ImGui_PopStyleColor(ctx, 3)
  local dl = C.ImGui_GetWindowDrawList(ctx)
  local cx, cy = act_bx + 8, act_by + 8
  if row.active then
    C.ImGui_DrawList_AddCircleFilled(dl, cx, cy, 5, SC.PRIMARY, 12)
  else
    C.ImGui_DrawList_AddCircle(dl, cx, cy, 5, SC.TEXT_OFF, 12, 1.5)
  end
end

local function _render_row_seek_col(ctx, state, row, i)
  local C = reaper
  C.ImGui_TableSetColumnIndex(ctx, 1)
  if row.group then C.ImGui_Indent(ctx, 16) end
  C.ImGui_PushStyleColor(ctx, C.ImGui_Col_FrameBg(), SC.WINDOW)
  C.ImGui_PushStyleColor(ctx, C.ImGui_Col_FrameBgHovered(), SC.HOVER_LIST)
  C.ImGui_PushStyleColor(ctx, C.ImGui_Col_FrameBgActive(), SC.WINDOW)
  C.ImGui_PushStyleColor(ctx, C.ImGui_Col_TextDisabled(), SC.PANEL_TOP)
  C.ImGui_SetNextItemWidth(ctx, -1)
  if state.font_bold then C.ImGui_PushFont(ctx, state.font_bold, 13) end
  local _seek_ax, _seek_ay = C.ImGui_GetCursorScreenPos(ctx)
  local _, new_name = C.ImGui_InputTextWithHint(ctx, "##nm" .. i, "Seek\xe2\x80\xa6", row.name)
  if state.font_bold then C.ImGui_PopFont(ctx) end
  C.ImGui_PopStyleColor(ctx, 4)
  -- History dropdown tracking
  local seek_item_h = select(2, C.ImGui_GetItemRectSize(ctx))
  local seek_item_w = select(1, C.ImGui_GetItemRectSize(ctx))
  local seek_was_active = state.hist_active_row == i
  local seek_is_active  = C.ImGui_IsItemActive(ctx)
  if seek_is_active and not seek_was_active then
    state.hist_active_row = i
    state.hist_filtered   = history_filter(state.query_history, row.name)
    state._dd_q_x = _seek_ax
    state._dd_q_y = _seek_ay + seek_item_h
    state._dd_q_w = seek_item_w
  end
  if seek_is_active and state.hist_active_row == i then
    if C.ImGui_IsKeyPressed(ctx, C.ImGui_Key_Escape()) then
      state.hist_active_row = nil
    end
  end
  if new_name ~= row.name then
    state.hist_filtered = history_filter(state.query_history, new_name)
    state._dd_q_x = _seek_ax
    state._dd_q_y = _seek_ay + seek_item_h
    state._dd_q_w = seek_item_w
    if state.hist_active_row ~= i then state.hist_active_row = i end
  end
  if C.ImGui_IsItemDeactivatedAfterEdit(ctx) and new_name ~= row.name then
    row.name = new_name
    C.GetSetMediaTrackInfo_String(row.track, "P_NAME", new_name, true)
    search_row(row, state.index, state)
  end
  if seek_is_active and state.hist_active_row == i
     and C.ImGui_IsKeyPressed(ctx, C.ImGui_Key_Enter()) then
    history_add(state.query_history, row.name, _HISTORY_KEY)
    state.hist_filtered   = history_filter(state.query_history, row.name)
    state.hist_active_row = nil
  end
  if row.group then C.ImGui_Unindent(ctx, 16) end
end

local function _render_row_omit_col(ctx, state, row, i)
  local C = reaper
  C.ImGui_TableSetColumnIndex(ctx, 2)
  local has_excl = row.exclude_text ~= ""
  C.ImGui_PushStyleColor(ctx, C.ImGui_Col_FrameBg(),        has_excl and SC.OMIT_BG or SC.WINDOW)
  C.ImGui_PushStyleColor(ctx, C.ImGui_Col_FrameBgHovered(), has_excl and SC.OMIT_BG or SC.HOVER_LIST)
  C.ImGui_PushStyleColor(ctx, C.ImGui_Col_FrameBgActive(),  has_excl and SC.OMIT_BG or SC.WINDOW)
  C.ImGui_PushStyleColor(ctx, C.ImGui_Col_TextDisabled(),   SC.PANEL_TOP)
  C.ImGui_SetNextItemWidth(ctx, -1)
  if state.font_bold then C.ImGui_PushFont(ctx, state.font_bold, 13) end
  local _omit_ax, _omit_ay = C.ImGui_GetCursorScreenPos(ctx)
  local excl_rv, new_excl = C.ImGui_InputTextWithHint(ctx, "##omit" .. i, "Omit\xe2\x80\xa6", row.exclude_text)
  if state.font_bold then C.ImGui_PopFont(ctx) end
  if excl_rv then row.exclude_text = new_excl end
  C.ImGui_PopStyleColor(ctx, 4)
  -- History dropdown tracking (omit)
  local omit_item_h = select(2, C.ImGui_GetItemRectSize(ctx))
  local omit_item_w = select(1, C.ImGui_GetItemRectSize(ctx))
  local omit_was_active = state.omit_active_row == i
  local omit_is_active  = C.ImGui_IsItemActive(ctx)
  if omit_is_active and not omit_was_active then
    state.omit_active_row = i
    state.omit_filtered   = history_filter(state.omit_history, row.exclude_text)
    state._dd_om_x = _omit_ax
    state._dd_om_y = _omit_ay + omit_item_h
    state._dd_om_w = omit_item_w
  end
  if omit_is_active and state.omit_active_row == i then
    if C.ImGui_IsKeyPressed(ctx, C.ImGui_Key_Escape()) then
      state.omit_active_row = nil
    end
  end
  if new_excl ~= row.exclude_text then
    state.omit_filtered = history_filter(state.omit_history, new_excl)
    state._dd_om_x = _omit_ax
    state._dd_om_y = _omit_ay + omit_item_h
    state._dd_om_w = omit_item_w
    if state.omit_active_row ~= i then state.omit_active_row = i end
  end
  if C.ImGui_IsItemDeactivatedAfterEdit(ctx) then
    row.exclude_tokens = db.tokenize(row.exclude_text, {})
    search_row(row, state.index, state)
  end
  if omit_is_active and state.omit_active_row == i
     and C.ImGui_IsKeyPressed(ctx, C.ImGui_Key_Enter()) then
    history_add(state.omit_history, row.exclude_text, _OMIT_HISTORY_KEY)
    state.omit_filtered   = history_filter(state.omit_history, row.exclude_text)
    state.omit_active_row = nil
  end
end

local function _render_row_badges_col(ctx, state, row, i)
  local C = reaper
  C.ImGui_TableSetColumnIndex(ctx, 3)
  local _badge_w = C.ImGui_CalcTextSize(ctx, "UNIQ") + 8
  local _badge_gap = math.max(2, math.floor((C.ImGui_GetContentRegionAvail(ctx) - _badge_w * 3) / 2))
  -- PAR badge
  if _render_badge(ctx, "PAR", "par", row.include_parent, i) then
    row.include_parent = not row.include_parent
    search_row(row, state.index, state)
    if row.selected then
      for _, r in ipairs(state.rows) do
        if r.selected and r ~= row then
          r.include_parent = row.include_parent
          search_row(r, state.index, state)
        end
      end
    end
  end
  C.ImGui_SameLine(ctx, 0, _badge_gap)
  -- INH badge
  local inh_on = row.inherit_props and state.inherit_global
  if _render_badge(ctx, "INH", "inh", inh_on, i) then
    row.inherit_props = not row.inherit_props
    if row.selected then
      for _, r in ipairs(state.rows) do
        if r.selected then r.inherit_props = row.inherit_props end
      end
    end
  end
  C.ImGui_SameLine(ctx, 0, _badge_gap)
  -- Mode cycle button (FREE → UNIQ → LOCK)
  local mode = row.mode or "free"
  local mc = MODE_COL[mode]
  C.ImGui_PushStyleColor(ctx, C.ImGui_Col_Button(),        mc[1])
  C.ImGui_PushStyleColor(ctx, C.ImGui_Col_ButtonHovered(), mc[2])
  C.ImGui_PushStyleColor(ctx, C.ImGui_Col_ButtonActive(),  mc[3])
  C.ImGui_PushStyleColor(ctx, C.ImGui_Col_Text(),          mc[4])
  local mode_w = C.ImGui_CalcTextSize(ctx, "UNIQ") + 8
  local mode_h = C.ImGui_GetTextLineHeight(ctx) + 2
  if C.ImGui_Button(ctx, MODE_LBL[mode] .. "##md" .. i, mode_w, mode_h) then
    local MODES = { "free", "unique", "lock" }
    local cur_i = 1
    for ii, m in ipairs(MODES) do if m == mode then cur_i = ii; break end end
    local new_mode = MODES[(cur_i % #MODES) + 1]
    if new_mode == "lock" then
      local le = row.current_idx and state.index[row.current_idx]
      row.lock_filepath = row.last_rolled_filepath or (le and le.filepath)
    elseif mode == "lock" then
      row.lock_filepath = nil
    end
    row.mode = new_mode
    if row.selected then
      for _, r in ipairs(state.rows) do
        if r.selected then
          if new_mode == "lock" then
            local rle = r.current_idx and state.index[r.current_idx]
            r.lock_filepath = r.last_rolled_filepath or (rle and rle.filepath)
          elseif mode == "lock" then
            r.lock_filepath = nil
          end
          r.mode = new_mode
        end
      end
    end
  end
  C.ImGui_PopStyleColor(ctx, 4)
  -- Draw padlock icon overlay when in LOCK mode
  if mode == "lock" then
    local dl_lk  = C.ImGui_GetWindowDrawList(ctx)
    local ibx, iby   = C.ImGui_GetItemRectMin(ctx)
    local ibmx, ibmy = C.ImGui_GetItemRectMax(ctx)
    local lk_cx = math.floor((ibx + ibmx) * 0.5)
    local lk_cy = math.floor((iby + ibmy) * 0.5)
    local bw2, bh, sr = 5, 7, 3
    local bt = lk_cy - 1
    C.ImGui_DrawList_AddCircle(dl_lk, lk_cx, bt, sr, SC.WINDOW, 0, 1.5)
    C.ImGui_DrawList_AddRectFilled(dl_lk, lk_cx - bw2, bt, lk_cx + bw2, bt + bh, SC.WINDOW, 1.0)
  end
end

-- ── render_row orchestrator ──────────────────────────────────────────────

local function render_row(ctx, state, row, i)
  local C = reaper

  -- Selection highlight
  if row.selected then
    C.ImGui_TableSetBgColor(ctx, C.ImGui_TableBgTarget_RowBg1(), COL_SEL_BG)
  end

  -- Row-spanning selectable for click-to-select
  C.ImGui_TableSetColumnIndex(ctx, 0)
  local _sel_flags = C.ImGui_SelectableFlags_SpanAllColumns() | _SEL_ALLOW_OVERLAP
  if C.ImGui_Selectable(ctx, "##selrow" .. i, row.selected, _sel_flags, 0, C.ImGui_GetFrameHeight(ctx)) then
    local ctrl  = C.ImGui_IsKeyDown(ctx, C.ImGui_Key_LeftCtrl())
                  or C.ImGui_IsKeyDown(ctx, C.ImGui_Key_RightCtrl())
    local shift = C.ImGui_IsKeyDown(ctx, C.ImGui_Key_LeftShift())
                  or C.ImGui_IsKeyDown(ctx, C.ImGui_Key_RightShift())
    if ctrl then
      row.selected       = not row.selected
      row._user_sel      = row.selected
      state.last_sel_idx = i
    elseif shift and state.last_sel_idx then
      local lo = math.min(state.last_sel_idx, i)
      local hi = math.max(state.last_sel_idx, i)
      for j, r in ipairs(state.rows) do
        local in_range = (j >= lo and j <= hi)
        r.selected  = in_range
        r._user_sel = in_range
      end
    else
      if row.selected then
        for _, r in ipairs(state.rows) do
          r.selected  = false
          r._user_sel = false
        end
        state.last_sel_idx = nil
      else
        for _, r in ipairs(state.rows) do
          r.selected  = false
          r._user_sel = false
        end
        row.selected       = true
        row._user_sel      = true
        state.last_sel_idx = i
      end
    end
    state._row_clicked_this_frame = true
  end
  if row.current_idx and state.index[row.current_idx] then
    if C.ImGui_IsItemHovered(ctx) then
      C.ImGui_SetTooltip(ctx, state.index[row.current_idx].filepath)
    end
  end
  C.ImGui_SameLine(ctx, 0, 0)

  _render_row_active_col(ctx, state, row, i)

  if not row.active then C.ImGui_BeginDisabled(ctx) end
  _render_row_seek_col(ctx, state, row, i)
  _render_row_omit_col(ctx, state, row, i)
  _render_row_badges_col(ctx, state, row, i)

  -- Col 4: Result count
  C.ImGui_TableSetColumnIndex(ctx, 4)
  local n = #row.results
  if n == 0 then
    C.ImGui_TextColored(ctx, COL_RED, "0")
  elseif row.fallback then
    C.ImGui_TextColored(ctx, COL_AMBER, tostring(n))
  else
    C.ImGui_Text(ctx, tostring(n))
  end

  if not row.active then C.ImGui_EndDisabled(ctx) end

end

-- Sub-folder group header row: On/Off toggle for the whole group + group name + NOT field.
-- @param ctx        ImGui context
-- @param state      App state
-- @param group_name string  Sub-folder name (row.group)
-- @param header_i   number  Unique index for widget IDs
local function render_group_header(ctx, state, group_name, header_i)
  local C = reaper
  local group_rows = {}
  for _, r in ipairs(state.rows) do
    if r.group == group_name then group_rows[#group_rows + 1] = r end
  end
  local any_active = false
  for _, r in ipairs(group_rows) do
    if r.active then any_active = true; break end
  end

  C.ImGui_TableNextRow(ctx)
  C.ImGui_TableSetBgColor(ctx, C.ImGui_TableBgTarget_RowBg0(), SC.GROUP_HDR_BG)

  C.ImGui_TableSetColumnIndex(ctx, 0)
  push_btn(ctx, 0x00000000, SC.HOVER_LIST, SC.ACTIVE_DARK)
  local ga_bx, ga_by = C.ImGui_GetCursorScreenPos(ctx)
  if C.ImGui_Button(ctx, "##grpact" .. header_i, 16, 16) then
    local new_state = not any_active
    for _, r in ipairs(group_rows) do r.active = new_state end
  end
  C.ImGui_PopStyleColor(ctx, 3)
  local gdl = C.ImGui_GetWindowDrawList(ctx)
  local gcx, gcy = ga_bx + 8, ga_by + 8
  if any_active then
    C.ImGui_DrawList_AddCircleFilled(gdl, gcx, gcy, 5, SC.PRIMARY, 12)
  else
    C.ImGui_DrawList_AddCircle(gdl, gcx, gcy, 5, SC.TEXT_OFF, 12, 1.5)
  end
  if C.ImGui_IsItemHovered(ctx) then
    C.ImGui_SetTooltip(ctx, any_active
      and "Group active \xe2\x80\x93 click to deactivate all tracks in this group"
      or  "Group inactive \xe2\x80\x93 click to activate all tracks in this group")
  end

  C.ImGui_TableSetColumnIndex(ctx, 1)
  C.ImGui_PushStyleColor(ctx, C.ImGui_Col_Text(), SC.PRIMARY)
  local grp_font = state and state.font_bold
  if grp_font then C.ImGui_PushFont(ctx, grp_font, 13) end
  C.ImGui_Text(ctx, group_name)
  if grp_font then C.ImGui_PopFont(ctx) end
  C.ImGui_PopStyleColor(ctx, 1)

  -- Omit field (col 2): group-level exclusion stored in state.group_not[group_name].
  -- Does NOT touch individual row.exclude_text — those stay per-row only.
  C.ImGui_TableSetColumnIndex(ctx, 2)
  state.group_not[group_name] = state.group_not[group_name] or {text = "", tokens = {}}
  local gn        = state.group_not[group_name]
  local g_has_not = gn.text ~= ""
  if g_has_not then
    C.ImGui_PushStyleColor(ctx, C.ImGui_Col_FrameBg(),        SC.OMIT_ACTIVE)
    C.ImGui_PushStyleColor(ctx, C.ImGui_Col_FrameBgHovered(), SC.OMIT_ACTIVE_HV)
    C.ImGui_PushStyleColor(ctx, C.ImGui_Col_FrameBgActive(),  SC.OMIT_ACTIVE_HV)
  end
  C.ImGui_PushStyleColor(ctx, C.ImGui_Col_TextDisabled(), SC.PRIMARY)
  C.ImGui_SetNextItemWidth(ctx, -1)
  local grv, g_new = C.ImGui_InputTextWithHint(ctx, "##gnot" .. header_i, "Omit\xe2\x80\xa6", gn.text)
  if grv then gn.text = g_new end
  C.ImGui_PopStyleColor(ctx, 1)
  if g_has_not then C.ImGui_PopStyleColor(ctx, 3) end
  if C.ImGui_IsItemDeactivatedAfterEdit(ctx) then
    gn.tokens = db.tokenize(gn.text, {})
    for _, r in ipairs(state.rows) do
      if r.group == group_name then search_row(r, state.index, state) end
    end
  end
  if C.ImGui_IsItemHovered(ctx) then
    C.ImGui_SetTooltip(ctx, g_has_not
      and ("Excluding from all in group: " .. gn.text .. "\nEdit and press Enter or click away to apply")
      or  "Type space-separated terms to exclude from ALL tracks in this group.")
  end
end

-- v2.0: Track card table — 5 columns, two rows per track (line 1: controls, line 2: filename).
local function render_rows_table(ctx, state)
  -- Reset per-frame click flag; set by render_row when a row Selectable fires (U4).
  state._row_clicked_this_frame = false
  local flags = reaper.ImGui_TableFlags_RowBg()
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Header(),        COL_SEL_BG)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderHovered(), SC.HOVER_LIST)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderActive(),  SC.ACTIVE_DARK)
  if not reaper.ImGui_BeginTable(ctx, "rows", 5, flags) then
    reaper.ImGui_PopStyleColor(ctx, 3)
    return
  end

  reaper.ImGui_TableSetupColumn(ctx, "",       reaper.ImGui_TableColumnFlags_WidthFixed(),   20)  -- dot
  reaper.ImGui_TableSetupColumn(ctx, "Track",  reaper.ImGui_TableColumnFlags_WidthFixed(), 210)  -- wider: absorbs 16px indent on grouped rows
  reaper.ImGui_TableSetupColumn(ctx, "Omit",   reaper.ImGui_TableColumnFlags_WidthFixed(), 182)
  reaper.ImGui_TableSetupColumn(ctx, "",        reaper.ImGui_TableColumnFlags_WidthFixed(), 120)  -- PAR+INH+mode
  reaper.ImGui_TableSetupColumn(ctx, "",        reaper.ImGui_TableColumnFlags_WidthFixed(),  44)  -- count
  if #state.rows == 0 then
    reaper.ImGui_TableNextRow(ctx)
    reaper.ImGui_TableSetColumnIndex(ctx, 0)
    reaper.ImGui_TextDisabled(ctx, "(no child tracks found)")
  else
    local last_group = false  -- sentinel: differs from nil and any string
    local header_idx = 0
    local function insert_divider()
      reaper.ImGui_TableNextRow(ctx)
      reaper.ImGui_TableSetBgColor(ctx, reaper.ImGui_TableBgTarget_RowBg0(), SC.PANEL)
      reaper.ImGui_TableSetColumnIndex(ctx, 0)
      reaper.ImGui_Dummy(ctx, 1, 1)
    end
    insert_divider()  -- leading divider above first row
    for i, row in ipairs(state.rows) do
      -- Thin separator between every section change (group→nil, nil→group, group→group)
      if last_group ~= false and row.group ~= last_group then
        insert_divider()
      end
      -- Group header when entering a new sub-folder section
      if row.group ~= nil and row.group ~= last_group then
        header_idx = header_idx + 1
        render_group_header(ctx, state, row.group, header_idx)
      end
      last_group = row.group
      reaper.ImGui_TableNextRow(ctx)
      render_row(ctx, state, row, i)
    end
    insert_divider()  -- trailing divider below last row
  end

  reaper.ImGui_EndTable(ctx)
  reaper.ImGui_PopStyleColor(ctx, 3)  -- Header + HeaderHovered + HeaderActive

  -- U4: clicking empty window space (not on any row or widget) clears GUI selection.
  if reaper.ImGui_IsMouseClicked(ctx, 0)
     and reaper.ImGui_IsWindowHovered(ctx, 0)
     and not state._row_clicked_this_frame
     and not reaper.ImGui_IsAnyItemHovered(ctx) then
    for _, r in ipairs(state.rows) do
      r.selected  = false
      r._user_sel = false
    end
    state.last_sel_idx = nil
  end
end

-- ============================================================
-- Group strip
-- ============================================================

-- ============================================================
-- U6: Live REAPER → GUI track selection sync
-- ============================================================

-- Mirror REAPER's track selection to GUI row selection when tracks within the
-- anchor folder are REAPER-selected.
-- Rules:
--   • Anchor folder itself selected → select all rows.
--   • Sub-folder (parent_track of a grandchild row) selected → select all rows in that group.
--   • Leaf track selected → select just that row.
--   • No anchor-scope tracks selected → leave GUI selection unchanged.
-- Called only when REAPER selection changes (polled via key hash in loop).
-- @param state table  App state (must be "ready")
local function _sync_reaper_selection_to_gui(state)
  if not state.rows or #state.rows == 0 then return end
  -- F3 hardening: guard against stale parent_track pointer.
  if not state.parent_track or not reaper.ValidatePtr(state.parent_track, "MediaTrack*") then
    return
  end
  local n_sel = reaper.CountSelectedTracks(0)
  if n_sel == 0 then return end

  -- Build string-key set of REAPER-selected track pointers (guard nil tracks).
  local sel_set = {}
  for i = 0, n_sel - 1 do
    local t = reaper.GetSelectedTrack(0, i)
    if t then sel_set[tostring(t)] = true end
  end

  -- Anchor folder itself selected → select all rows.
  if sel_set[tostring(state.parent_track)] then
    for _, row in ipairs(state.rows) do row.selected = true end
    return
  end

  -- Check if any anchor-scope track (leaf or sub-folder) appears in the selection.
  local any_in_anchor = false
  for _, row in ipairs(state.rows) do
    -- F3 hardening: skip rows with invalid track pointers.
    if not row.track or not reaper.ValidatePtr(row.track, "MediaTrack*") then
      goto check_parent
    end
    if sel_set[tostring(row.track)] then
      any_in_anchor = true; break
    end
    ::check_parent::
    if row.parent_track and row.parent_track ~= state.parent_track
       and reaper.ValidatePtr(row.parent_track, "MediaTrack*")
       and sel_set[tostring(row.parent_track)] then
      any_in_anchor = true; break
    end
  end
  if not any_in_anchor then return end

  -- Mirror per-row: leaf selected directly OR its sub-folder parent is selected.
  for _, row in ipairs(state.rows) do
    local is_sel = row.track and reaper.ValidatePtr(row.track, "MediaTrack*")
                  and sel_set[tostring(row.track)]
    if not is_sel and row.parent_track and row.parent_track ~= state.parent_track
       and reaper.ValidatePtr(row.parent_track, "MediaTrack*") then
      is_sel = sel_set[tostring(row.parent_track)]
    end
    row.selected = is_sel or false
  end
end

-- Register the last-touched REAPER track as an anchor group and switch to it.
-- No-op when no track is touched or the track is already the active group.
-- @param app table
local function _add_anchor_here(app)
  local t = reaper.GetLastTouchedTrack()
  if not t then
    reaper.ShowMessageBox("Touch a folder track first, then click + Anchor.", "Temper Vortex", 0)
    return
  end
  local depth = reaper.GetMediaTrackInfo_Value(t, "I_FOLDERDEPTH")
  if depth < 1 then
    local _, name = reaper.GetTrackName(t)
    reaper.ShowMessageBox(
      string.format('"%s" is not a folder track.\nTouch a folder track first, then click + Anchor.', name or "?"),
      "Temper Vortex", 0)
    return
  end
  local g = groups.add(t)
  if g and g ~= app.active_guid then _switch_to_group(app, g) end
end

-- Render the horizontal group selector strip above the toolbar.
-- Draws one colored chip per registered anchor; active chip has a white border.
-- Clicking a chip switches context; hovering reveals an [x] remove button.
-- A [+ Anchor] button at the end registers the last-touched folder track.
-- @param ctx  ImGui context
-- @param app  table  App wrapper (mutated via _switch_to_group / groups.remove)
local function render_group_strip(ctx, app)
  -- Prune anchors whose folder track no longer exists in the current project.
  -- Runs every frame but groups are few (1-5 typical), so cost is negligible.
  for _, guid in ipairs(groups.list()) do
    if not groups.find_track(guid) then
      groups.remove(guid)
      if app.active_guid == guid then app.active_guid = nil end
    end
  end

  local C    = reaper
  local list = groups.list()
  if #list == 0 then
    C.ImGui_TextDisabled(ctx, "No groups \xe2\x80\x94 touch a folder track, then:")
    C.ImGui_SameLine(ctx)
    if C.ImGui_SmallButton(ctx, "+ Anchor##ng") then _add_anchor_here(app) end
    C.ImGui_Separator(ctx)
    return
  end
  for i, guid in ipairs(list) do
    if i > 1 then C.ImGui_SameLine(ctx) end
    local key    = _guid_to_key(guid)
    local color  = groups.get_color(guid)
    local is_act = (guid == app.active_guid)
    local is_ctx = (guid == app.context_guid) and not is_act
    local bg     = is_act and color or ((color & 0x00FFFFFF) | 0x88000000)
    C.ImGui_PushStyleColor(ctx, C.ImGui_Col_Button(),        bg)
    C.ImGui_PushStyleColor(ctx, C.ImGui_Col_ButtonHovered(), color)
    C.ImGui_PushStyleColor(ctx, C.ImGui_Col_ButtonActive(),  color)
    local nc      = 3
    local has_var = false
    if is_act then
      C.ImGui_PushStyleColor(ctx, C.ImGui_Col_Border(), 0xFFFFFFFF)
      C.ImGui_PushStyleVar(ctx, C.ImGui_StyleVar_FrameBorderSize(), 1)
      nc = 4; has_var = true
    elseif is_ctx then
      C.ImGui_PushStyleColor(ctx, C.ImGui_Col_Border(), 0xFFAA00FF)  -- amber: "your track is here"
      C.ImGui_PushStyleVar(ctx, C.ImGui_StyleVar_FrameBorderSize(), 1)
      nc = 4; has_var = true
    end
    if C.ImGui_Button(ctx, groups.get_name(guid) .. "##chip_" .. key) then
      _switch_to_group(app, guid)
    end
    if C.ImGui_IsItemHovered(ctx) then
      if is_act then
        C.ImGui_SetTooltip(ctx, "Active group \xe2\x80\x94 currently loaded")
      elseif is_ctx then
        C.ImGui_SetTooltip(ctx, "Your active track is here \xe2\x80\x94 click to switch")
      end
    end
    C.ImGui_PopStyleColor(ctx, nc)
    if has_var then C.ImGui_PopStyleVar(ctx, 1) end
    C.ImGui_SameLine(ctx)
    if C.ImGui_SmallButton(ctx, "x##rm_" .. key) then
      groups.remove(guid)
      if app.active_guid == guid then app.active_guid = nil end
    end
  end
  C.ImGui_SameLine(ctx)
  if C.ImGui_SmallButton(ctx, "+ Anchor") then _add_anchor_here(app) end
  if C.ImGui_IsItemHovered(ctx) then
    C.ImGui_SetTooltip(ctx, "Touch a folder track in REAPER, then click to register it as an anchor group.")
  end
  C.ImGui_Separator(ctx)
end

-- v2.1: Inline group strip for the title bar — chips + "+ Anchor", no separator.
local function render_group_strip_inline(ctx, app)
  local C    = reaper
  local list = groups.list()
  if #list == 0 then
    C.ImGui_SameLine(ctx)
    C.ImGui_TextDisabled(ctx, "No groups \xe2\x80\x94 touch a folder track, then:")
    C.ImGui_SameLine(ctx)
    if C.ImGui_SmallButton(ctx, "+ Anchor##ng_tb") then _add_anchor_here(app) end
    return
  end
  for i, guid in ipairs(list) do
    C.ImGui_SameLine(ctx)
    local key    = _guid_to_key(guid)
    local color  = groups.get_color(guid)
    local is_act = (guid == app.active_guid)
    local is_ctx = (guid == app.context_guid) and not is_act
    local bg     = is_act and color or ((color & 0x00FFFFFF) | 0x88000000)
    C.ImGui_PushStyleColor(ctx, C.ImGui_Col_Button(),        bg)
    C.ImGui_PushStyleColor(ctx, C.ImGui_Col_ButtonHovered(), color)
    C.ImGui_PushStyleColor(ctx, C.ImGui_Col_ButtonActive(),  color)
    local nc      = 3
    local has_var = false
    if is_act then
      C.ImGui_PushStyleColor(ctx, C.ImGui_Col_Border(), 0xFFFFFFFF)
      C.ImGui_PushStyleVar(ctx, C.ImGui_StyleVar_FrameBorderSize(), 1)
      nc = 4; has_var = true
    elseif is_ctx then
      C.ImGui_PushStyleColor(ctx, C.ImGui_Col_Border(), 0xFFAA00FF)
      C.ImGui_PushStyleVar(ctx, C.ImGui_StyleVar_FrameBorderSize(), 1)
      nc = 4; has_var = true
    end
    if C.ImGui_SmallButton(ctx, groups.get_name(guid) .. "##chip_tb_" .. key) then
      _switch_to_group(app, guid)
    end
    if C.ImGui_IsItemHovered(ctx) then
      if is_act then
        C.ImGui_SetTooltip(ctx, "Active group \xe2\x80\x94 currently loaded")
      elseif is_ctx then
        C.ImGui_SetTooltip(ctx, "Your active track is here \xe2\x80\x94 click to switch")
      end
    end
    C.ImGui_PopStyleColor(ctx, nc)
    if has_var then C.ImGui_PopStyleVar(ctx, 1) end
    C.ImGui_SameLine(ctx)
    if C.ImGui_SmallButton(ctx, "x##rm_tb_" .. key) then
      groups.remove(guid)
      if app.active_guid == guid then app.active_guid = nil end
    end
  end
  C.ImGui_SameLine(ctx)
  if C.ImGui_SmallButton(ctx, "+ Anchor##tb") then _add_anchor_here(app) end
  if C.ImGui_IsItemHovered(ctx) then
    C.ImGui_SetTooltip(ctx, "Touch a folder track in REAPER, then click to register it as an anchor group.")
  end
end

-- Anchor-selection prompt: shown when no valid folder track was selected at launch.
-- The user selects their anchor track in REAPER then clicks Continue to retry init.
local function render_anchor_prompt(ctx, state, app)
  local C = reaper
  C.ImGui_Separator(ctx)
  C.ImGui_Spacing(ctx)
  C.ImGui_Spacing(ctx)
  C.ImGui_TextDisabled(ctx, "Select a Folder (anchor) track in REAPER,")
  C.ImGui_TextDisabled(ctx, "then click Continue.")
  C.ImGui_Spacing(ctx)
  push_btn(ctx, SC.BTN_CONFIRM, SC.BTN_CONFIRM_HV, SC.BTN_CONFIRM_AC)
  if C.ImGui_Button(ctx, "Continue", 120, 0) then
    state.status = "init"
  end
  C.ImGui_PopStyleColor(ctx, 3)
  C.ImGui_SameLine(ctx)
  if C.ImGui_Button(ctx, "Close", 120, 0) then
    app._close_requested = true
  end
end

-- v2.1: Right column — Seek/Omit, Preset, Batch controls, Stats.
-- Replaces render_panel_header; anchor strip moved to title bar.
-- ── render_right_column sub-functions ─────────────────────────────────────

local function _render_batch_toggles(ctx, state, btn_w, btn_h, font_b)
  local R = reaper

  -- Pre-compute toggle states
  local all_active = true
  local any_par    = false
  for _, r in ipairs(state.rows) do
    if not r.active         then all_active = false end
    if r.include_parent     then any_par    = true  end
  end

  -- ALL toggle
  local all_bg  = all_active and SC.PANEL_TOP or SC.PANEL
  local all_hv  = all_active and SC.HOVER_LIST or SC.HOVER_INACTIVE
  local all_ac  = all_active and SC.ACTIVE_DARK or SC.ACTIVE_DARKER
  local all_txt = all_active and SC.PRIMARY or SC.TEXT_OFF
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        all_bg)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), all_hv)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  all_ac)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          all_txt)
  if font_b then R.ImGui_PushFont(ctx, font_b, 13) end
  if R.ImGui_Button(ctx, "ALL##set_all", btn_w, btn_h) then
    vortex_actions.toggle_active(state)
  end
  if font_b then R.ImGui_PopFont(ctx) end
  R.ImGui_PopStyleColor(ctx, 4)
  if R.ImGui_IsItemHovered(ctx) then
    R.ImGui_SetTooltip(ctx, all_active
      and "All tracks active \xe2\x80\x94 click to deactivate all"
      or  "Click to activate all tracks")
  end

  -- PAR toggle (batch include_parent for all rows)
  R.ImGui_SameLine(ctx)
  local par_bg  = any_par and SC.PANEL_TOP or SC.PANEL
  local par_hv  = any_par and SC.HOVER_LIST or SC.HOVER_INACTIVE
  local par_ac  = any_par and SC.ACTIVE_DARK or SC.ACTIVE_DARKER
  local par_txt = any_par and SC.PRIMARY or SC.TEXT_OFF
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        par_bg)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), par_hv)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  par_ac)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          par_txt)
  if font_b then R.ImGui_PushFont(ctx, font_b, 13) end
  if R.ImGui_Button(ctx, "PAR##par_batch", btn_w, btn_h) then
    vortex_actions.toggle_par(state)
  end
  if font_b then R.ImGui_PopFont(ctx) end
  R.ImGui_PopStyleColor(ctx, 4)
  if R.ImGui_IsItemHovered(ctx) then
    R.ImGui_SetTooltip(ctx, any_par
      and "Parent search ON for all \xe2\x80\x94 click to disable"
      or  "Parent search OFF for all \xe2\x80\x94 click to enable")
  end

  -- INH toggle (batch inherit properties)
  R.ImGui_SameLine(ctx)
  local inh_on  = state.inherit_global
  local inh_bg  = inh_on and SC.PANEL_TOP or SC.PANEL
  local inh_hv  = inh_on and SC.HOVER_LIST or SC.HOVER_INACTIVE
  local inh_ac  = inh_on and SC.ACTIVE_DARK or SC.ACTIVE_DARKER
  local inh_txt = inh_on and SC.PRIMARY or SC.TEXT_OFF
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        inh_bg)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), inh_hv)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  inh_ac)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          inh_txt)
  if font_b then R.ImGui_PushFont(ctx, font_b, 13) end
  if R.ImGui_Button(ctx, "INH##inh_batch", btn_w, btn_h) then
    vortex_actions.toggle_inh_global(state)
  end
  if font_b then R.ImGui_PopFont(ctx) end
  R.ImGui_PopStyleColor(ctx, 4)
  if R.ImGui_IsItemHovered(ctx) then
    R.ImGui_SetTooltip(ctx, state.inherit_global
      and "Inherit Properties ON \xe2\x80\x94 items inherit captured snapshot"
      or  "Inherit Properties OFF")
  end

  -- Capture button (camera icon, same row)
  R.ImGui_SameLine(ctx)
  local has_pp  = R.GetExtState(_EXT_SEC, "src2_track_count") ~= ""
  local has_sel_items = _has_selection_in_rows(state)
  local cap_ok  = state.inherit_global and (has_pp or has_sel_items)
  local has_snap = state.prop_snapshot ~= nil
  local cap_bg = has_snap and SC.TERTIARY    or SC.PANEL
  local cap_hv = has_snap and SC.TERTIARY_HV or SC.HOVER_INACTIVE
  local cap_ac = has_snap and SC.TERTIARY_AC or SC.ACTIVE_DARKER
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        cap_bg)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), cap_hv)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  cap_ac)
  if not cap_ok then R.ImGui_BeginDisabled(ctx) end
  if R.ImGui_Button(ctx, "##cap_batch", btn_w, btn_h) then
    vortex_actions.do_capture(state)
  end
  if not cap_ok then R.ImGui_EndDisabled(ctx) end
  do
    local dl     = R.ImGui_GetWindowDrawList(ctx)
    local cbx, cby   = R.ImGui_GetItemRectMin(ctx)
    local cbmx, cbmy = R.ImGui_GetItemRectMax(ctx)
    local cx  = math.floor((cbx + cbmx) * 0.5)
    local cy  = math.floor((cby + cbmy) * 0.5)
    local col = has_snap and SC.WINDOW or SC.TEXT_OFF
    R.ImGui_DrawList_AddRect(dl,      cx-8, cy-3, cx+8, cy+6, col, 2.0, 0, 1.5)
    R.ImGui_DrawList_AddRectFilled(dl, cx-3, cy-7, cx+4, cy-3, col, 1.5)
    R.ImGui_DrawList_AddCircle(dl,    cx,   cy+2,  4,   col,   0,  1.5)
  end
  R.ImGui_PopStyleColor(ctx, 3)
  if R.ImGui_IsItemHovered(ctx) then
    R.ImGui_SetTooltip(ctx, has_snap
      and "Properties captured. Click to recapture.\nPlayrate applies to LOCK tracks only."
      or  "Capture properties from selection.\nPlayrate applies to LOCK tracks only.")
  end
end

local function _render_status_text(ctx, state)
  local R = reaper
  do
    local avail_y = select(2, R.ImGui_GetContentRegionAvail(ctx))
    local text_h  = R.ImGui_GetTextLineHeight(ctx)
    local pad     = 8
    if avail_y > text_h + pad then
      R.ImGui_SetCursorPosY(ctx, R.ImGui_GetCursorPosY(ctx) + avail_y - text_h - pad)
    end
  end
  local status_txt = ""
  if state.status == "ready" then
    status_txt = string.format("%d indexed  |  %d tracks", #state.index, #state.rows)
  elseif state.status == "loading" then
    status_txt = string.format("Loading... (%d/%d)", state.load_idx, #state.file_lists)
  elseif state.status == "searching" then
    status_txt = string.format("Searching... (%d/%d)", state.search_idx, #state.rows)
  end
  if status_txt ~= "" then
    R.ImGui_TextDisabled(ctx, status_txt)
  end
end

-- ── render_right_column orchestrator ─────────────────────────────────────

local function render_right_column(ctx, state, app)
  local R = reaper
  local font_b = rsg_theme and rsg_theme.font_bold
  local col_w  = select(1, R.ImGui_GetContentRegionAvail(ctx))

  -- ── Row 1: Preset combo + Save ──────────────────────────────────────
  render_preset_bar(ctx, state)
  R.ImGui_Spacing(ctx)

  -- ── Row 2: Seek input (full width) ──────────────────────────────────
  R.ImGui_PushStyleVar(ctx, R.ImGui_StyleVar_FramePadding(), 4, 4)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_FrameBg(),      SC.WINDOW)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_TextDisabled(), SC.PANEL_TOP)
  R.ImGui_SetNextItemWidth(ctx, col_w)
  if font_b then R.ImGui_PushFont(ctx, font_b, 13) end
  local _, new_par = R.ImGui_InputTextWithHint(ctx, "##seek_parent", "Seek\xe2\x80\xa6", state.parent_name)
  if font_b then R.ImGui_PopFont(ctx) end
  R.ImGui_PopStyleColor(ctx, 2)
  if R.ImGui_IsItemDeactivatedAfterEdit(ctx) and new_par ~= state.parent_name then
    state.parent_name = new_par
    R.GetSetMediaTrackInfo_String(state.parent_track, "P_NAME", new_par, true)
    for _, row in ipairs(state.rows) do
      if row.group == nil then row.parent_name = new_par
      else row.parent_name = new_par .. " " .. row.group end
      if row.include_parent then search_row(row, state.index, state) end
    end
  end
  R.ImGui_Spacing(ctx)

  -- ── Row 3: Omit input (full width) ─────────────────────────────────
  local gn = state.global_not
  local gn_active = gn.text ~= ""
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_FrameBg(),        gn_active and SC.OMIT_BG or SC.WINDOW)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_FrameBgHovered(), gn_active and SC.OMIT_HV or SC.HOVER_LIST)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_FrameBgActive(),  gn_active and SC.OMIT_HV or SC.WINDOW)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_TextDisabled(),   SC.PANEL_TOP)
  R.ImGui_SetNextItemWidth(ctx, col_w)
  if font_b then R.ImGui_PushFont(ctx, font_b, 13) end
  local gnrv, gn_new = R.ImGui_InputTextWithHint(ctx, "##omit_global", "Omit\xe2\x80\xa6", gn.text)
  if font_b then R.ImGui_PopFont(ctx) end
  R.ImGui_PopStyleColor(ctx, 4)
  if gnrv then gn.text = gn_new end
  if R.ImGui_IsItemDeactivatedAfterEdit(ctx) then
    gn.tokens = db.tokenize(gn.text, {})
    for _, r in ipairs(state.rows) do search_row(r, state.index, state) end
  end
  R.ImGui_PopStyleVar(ctx, 1)  -- FramePadding
  R.ImGui_Spacing(ctx)

  -- ── Row 4: ALL | PAR | INH | Capture ────────────────────────────────
  local avail_y  = select(2, R.ImGui_GetContentRegionAvail(ctx))
  local text_h   = R.ImGui_GetTextLineHeight(ctx)
  local gap      = 8
  local bot_pad  = 8
  local btn_h    = math.max(R.ImGui_GetFrameHeight(ctx), avail_y - text_h - gap - bot_pad)
  local btn_w    = math.floor((col_w - 6 * 3) / 4)
  _render_batch_toggles(ctx, state, btn_w, btn_h, font_b)

  -- ── Row 5: Status text (anchored to bottom) ────────────────────────
  _render_status_text(ctx, state)

  render_preset_popups(ctx, state)
end

-- v2.0: Left panel Mini module — Seek/Omit, ROLL hero, mode row, VARIATIONS.
-- Adapted from Temper_Vortex_Mini render_gui layout.
local function render_mini_panel(ctx, state, app)
  local R = reaper
  local font_b = rsg_theme and rsg_theme.font_bold
  local font_h = rsg_theme and rsg_theme.font_hero

  -- ── Enable flags ────────────────────────────────────────────────────
  local can_rnd = false
  for _, r in ipairs(state.rows) do
    if r.active and #r.results > 0 then can_rnd = true; break end
  end
  local can_sel = false
  for _, r in ipairs(state.rows) do
    if r.selected and r.active then
      if #r.results > 0 or (r.mode == "lock" and (r.lock_filepath or r.current_idx)) then
        can_sel = true; break
      end
    end
  end
  local any_sel, n_sel_rows = false, 0
  for _, r in ipairs(state.rows) do
    if r.selected then any_sel = true; n_sel_rows = n_sel_rows + 1 end
  end
  local all_sel    = (any_sel and n_sel_rows == #state.rows)
  local roll_as_sel = any_sel and not all_sel
  local roll_ok    = roll_as_sel and can_sel or ((not any_sel or all_sel) and can_rnd)
  local var_as_sel = roll_as_sel
  local var_ok     = var_as_sel and can_sel or ((not any_sel or all_sel) and can_rnd)
  local is_ready   = roll_ok

  -- ── Main: ROLL left + [mode+VARIATIONS] right (Mini v1.14.30 pattern) ──
  -- Seek/Omit moved to render_right_column (Column 3).
  local avail_w = select(1, R.ImGui_GetContentRegionAvail(ctx))
  local roll_w  = math.floor((avail_w - 8) * 1.2 / 2.2)
  local right_w = avail_w - roll_w - 8
  local col_w      = math.floor((right_w - 3 * 4) / 4)
  local last_col_w = right_w - 3 * col_w - 3 * 4  -- absorbs rounding remainder so SEC/BEATS is flush-right
  local main_h  = select(2, R.ImGui_GetContentRegionAvail(ctx))
  local sep_h   = 8

  -- LEFT: ROLL hero
  if R.ImGui_BeginChild(ctx, "##roll_col", roll_w, main_h, 0) then
    local roll_bx, roll_by = R.ImGui_GetCursorScreenPos(ctx)
    local btn_h = main_h
    if is_ready then
      local dl = R.ImGui_GetWindowDrawList(ctx)
      R.ImGui_DrawList_AddRectFilled(dl, roll_bx, roll_by, roll_bx + roll_w, roll_by + btn_h, SC.PRIMARY, 4)
      push_btn(ctx, 0x00000000, SC.HOVER_GHOST, SC.ACTIVE_GHOST)
    else
      push_btn(ctx, SC.PANEL, SC.PANEL_HIGH, SC.PANEL)
    end
    if not is_ready then R.ImGui_BeginDisabled(ctx) end
    if R.ImGui_Button(ctx, "##roll_hero", roll_w, btn_h) then
      vortex_actions.do_roll(state)
    end
    if not is_ready then R.ImGui_EndDisabled(ctx) end
    R.ImGui_PopStyleColor(ctx, 3)
    local dl_roll = R.ImGui_GetWindowDrawList(ctx)
    R.ImGui_DrawList_AddRect(dl_roll, roll_bx, roll_by, roll_bx + roll_w, roll_by + btn_h, SC.BORDER_SUBTLE, 4, 0, 1.0)
    -- Dice icon + ROLL text
    local dl  = R.ImGui_GetWindowDrawList(ctx)
    local rx  = roll_bx + roll_w * 0.5
    local ry  = roll_by + btn_h * 0.34
    local hw  = 13
    local ccol = is_ready and SC.WINDOW or SC.ICON_DISABLED
    R.ImGui_DrawList_AddRect(dl, rx - hw, ry - hw, rx + hw, ry + hw, ccol, 4.0, 0, 2.0)
    local dr, off = 2.5, hw * 0.42
    R.ImGui_DrawList_AddCircle(dl, rx - off, ry - off, dr, ccol, 0, 1.5)
    R.ImGui_DrawList_AddCircle(dl, rx,       ry,       dr, ccol, 0, 1.5)
    R.ImGui_DrawList_AddCircle(dl, rx + off, ry + off, dr, ccol, 0, 1.5)
    local roll_lbl = roll_as_sel and "ROLL SEL" or "ROLL"
    if font_h then R.ImGui_PushFont(ctx, font_h, 18) end
    local rtw = R.ImGui_CalcTextSize(ctx, roll_lbl)
    R.ImGui_SetCursorScreenPos(ctx, roll_bx + (roll_w - rtw) * 0.5, ry + hw + 8)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), ccol)
    R.ImGui_Text(ctx, roll_lbl)
    R.ImGui_PopStyleColor(ctx, 1)
    if font_h then R.ImGui_PopFont(ctx) end
    R.ImGui_EndChild(ctx)
  end

  R.ImGui_SameLine(ctx, 0, 8)

  -- RIGHT: mode row + VARIATIONS (Mini v1.14.30 exact pattern)
  local right_flags = R.ImGui_WindowFlags_NoScrollbar()
  R.ImGui_PushStyleVar(ctx, R.ImGui_StyleVar_WindowPadding(), 0, 0)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ChildBg(), SC.PANEL)
  if R.ImGui_BeginChild(ctx, "##mini_right_col", right_w, main_h, 0, right_flags) then
    -- Mode row: FramePadding y=7 + FrameBorderSize=1 (matches Mini)
    R.ImGui_PushStyleVar(ctx, R.ImGui_StyleVar_FramePadding(), 4, 7)
    R.ImGui_PushStyleVar(ctx, R.ImGui_StyleVar_FrameBorderSize(), 1.0)
    local mode_start_sx, mode_start_sy = R.ImGui_GetCursorScreenPos(ctx)
    local mode_h = R.ImGui_GetFrameHeight(ctx)

    -- Dominant mode across all rows (or selected)
    local dominant_mode = "free"
    local mode_counts = { free = 0, unique = 0, lock = 0 }
    for _, r in ipairs(state.rows) do
      local m = r.mode or "free"
      mode_counts[m] = (mode_counts[m] or 0) + 1
    end
    for m, c in pairs(mode_counts) do
      if c > (mode_counts[dominant_mode] or 0) then dominant_mode = m end
    end

    -- Mode cycle (synced with Mini v1.14.30)
    local MODE_DESCS  = {
      free   = "FREE: Pick a random file each Roll",
      unique = "UNIQ: Avoid repeating the same file",
      lock   = "LOCK: Stick to one source file (shift WAV cue)",
    }
    local mc   = MODE_COL[dominant_mode]
    local n_mc = mc[4] and 4 or 3
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        mc[1])
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), mc[2])
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  mc[3])
    if mc[4] then R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), mc[4]) end
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(), mc[1])  -- invisible border
    if R.ImGui_Button(ctx, MODE_LBL[dominant_mode] .. "##mc_batch", col_w, mode_h) then
      vortex_actions.cycle_mode(state)
    end
    -- Padlock icon overlay for LOCK (exact Mini pattern)
    if dominant_mode == "lock" then
      local dl_lk = R.ImGui_GetWindowDrawList(ctx)
      local ibx, iby   = R.ImGui_GetItemRectMin(ctx)
      local ibmx, ibmy = R.ImGui_GetItemRectMax(ctx)
      local lk_cx = math.floor((ibx + ibmx) * 0.5)
      local lk_cy = math.floor((iby + ibmy) * 0.5)
      local bw2, bh, sr = 6, 9, 4
      local bt = lk_cy - 2
      R.ImGui_DrawList_AddCircle(dl_lk, lk_cx, bt, sr, SC.WINDOW, 0, 2.0)
      R.ImGui_DrawList_AddRectFilled(dl_lk, lk_cx - bw2, bt, lk_cx + bw2, bt + bh, SC.WINDOW, 1.0)
    end
    R.ImGui_PopStyleColor(ctx, n_mc + 1)  -- mc colors + Border
    if R.ImGui_IsItemHovered(ctx) then
      R.ImGui_SetTooltip(ctx, MODE_DESCS[dominant_mode])
    end

    -- N field (centered text, visible border — synced with Mini v1.14.30)
    R.ImGui_SameLine(ctx, 0, 4)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_FrameBg(),        SC.WINDOW)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_FrameBgHovered(), SC.PANEL)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(),         SC.BORDER_INPUT)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),           SC.PRIMARY)
    local n_disp_w = R.ImGui_CalcTextSize(ctx, state.var_n_buf ~= "" and state.var_n_buf or "N")
    local n_pad_x  = math.max(4, math.floor((col_w - n_disp_w) * 0.5))
    R.ImGui_PushStyleVar(ctx, R.ImGui_StyleVar_FramePadding(), n_pad_x, 7)
    R.ImGui_SetNextItemWidth(ctx, col_w)
    local _, new_vn = R.ImGui_InputTextWithHint(ctx, "##varn_mini", "N", state.var_n_buf, 8)
    R.ImGui_PopStyleVar(ctx)
    state.var_n_buf = new_vn

    -- Spacing field (centered text, deactivate validation — synced with Mini v1.14.30)
    R.ImGui_SameLine(ctx, 0, 4)
    local x_disp_w = R.ImGui_CalcTextSize(ctx, state.var_x_buf ~= "" and state.var_x_buf or "0.0")
    local x_pad_x  = math.max(4, math.floor((col_w - x_disp_w) * 0.5))
    R.ImGui_PushStyleVar(ctx, R.ImGui_StyleVar_FramePadding(), x_pad_x, 7)
    R.ImGui_SetNextItemWidth(ctx, col_w)
    local x_changed, new_vx = R.ImGui_InputText(ctx, "##varx_mini", state.var_x_buf, 12)
    if R.ImGui_IsItemDeactivatedAfterEdit(ctx) then
      local parsed = tonumber(new_vx)
      state.var_x_buf = parsed and string.format("%.1f", math.max(0, parsed)) or new_vx
    elseif x_changed then
      state.var_x_buf = new_vx
    end
    R.ImGui_PopStyleVar(ctx)
    R.ImGui_PopStyleColor(ctx, 4)  -- FrameBg + FrameBgHovered + Border + Text

    -- SEC/BEATS toggle: icon button (clock/note) — synced with Mini v1.14.30
    R.ImGui_SameLine(ctx, 0, 4)
    push_btn(ctx, SC.PANEL_TOP, SC.HOVER_LIST, SC.ACTIVE_DARK)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(),        SC.PANEL_TOP)
    if R.ImGui_Button(ctx, " ##vu_mini", last_col_w, mode_h) then
      vortex_actions.toggle_time_unit(state)
    end
    -- Draw SEC (clock) or BEATS (note) icon centered in the button
    do
      local dl_vu      = R.ImGui_GetWindowDrawList(ctx)
      local vbx, vby   = R.ImGui_GetItemRectMin(ctx)
      local vbmx, vbmy = R.ImGui_GetItemRectMax(ctx)
      local vu_cx = math.floor((vbx + vbmx) * 0.5)
      local vu_cy = math.floor((vby + vbmy) * 0.5)
      local icol  = state.var_unit == 0 and SC.PRIMARY or SC.TERTIARY
      if state.var_unit == 0 then
        local cr = 7
        R.ImGui_DrawList_AddCircle(dl_vu, vu_cx, vu_cy, cr, icol, 0, 1.5)
        R.ImGui_DrawList_AddRectFilled(dl_vu, vu_cx - 1, vu_cy - cr + 2, vu_cx + 1, vu_cy, icol, 0)
        R.ImGui_DrawList_AddRectFilled(dl_vu, vu_cx, vu_cy - 1, vu_cx + cr - 1, vu_cy + 1, icol, 0)
      else
        local nr = 4
        local sx = vu_cx + 2
        R.ImGui_DrawList_AddCircleFilled(dl_vu, vu_cx - 1, vu_cy + 3, nr, icol)
        R.ImGui_DrawList_AddRectFilled(dl_vu, sx, vu_cy - 6, sx + 2, vu_cy + 4, icol, 0)
        R.ImGui_DrawList_AddRectFilled(dl_vu, sx, vu_cy - 6, sx + 6, vu_cy - 4, icol, 0)
      end
    end
    if R.ImGui_IsItemHovered(ctx) then
      local tt = state.var_unit == 0 and "Spacing in seconds" or "Spacing in beats (follows tempo map)"
      R.ImGui_SetTooltip(ctx, tt)
    end
    R.ImGui_PopStyleColor(ctx, 4)  -- Button + ButtonHovered + ButtonActive + Border
    R.ImGui_PopStyleVar(ctx, 2)  -- FramePadding + FrameBorderSize

    -- Reset cursor so VARIATIONS is flush-left and exactly sep_h below mode row (Mini pattern).
    R.ImGui_SetCursorScreenPos(ctx, mode_start_sx, mode_start_sy + mode_h + sep_h)

    -- VARIATIONS button (full width, remaining height)
    local vars_h = select(2, R.ImGui_GetContentRegionAvail(ctx))
    local var_bx, var_by = R.ImGui_GetCursorScreenPos(ctx)
    push_btn(ctx, SC.PANEL_TOP, SC.HOVER_LIST, SC.PANEL_HIGH)
    if not var_ok then R.ImGui_BeginDisabled(ctx) end
    if font_b then R.ImGui_PushFont(ctx, font_b, 13) end
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.PRIMARY)
    local var_lbl = var_as_sel and "VAR SEL##vars" or "VARIATIONS##vars"
    if R.ImGui_Button(ctx, var_lbl, right_w, vars_h) then
      vortex_actions.do_variations(state)
    end
    R.ImGui_PopStyleColor(ctx, 1)  -- Col_Text
    if font_b then R.ImGui_PopFont(ctx) end
    if not var_ok then R.ImGui_EndDisabled(ctx) end
    R.ImGui_PopStyleColor(ctx, 3)
    -- 3-stripe layers icon
    local dl_var = R.ImGui_GetWindowDrawList(ctx)
    local ialp   = var_ok and 0xFF or 0x44
    local vx     = var_bx + right_w * 0.5
    local vy     = var_by + vars_h * 0.28
    local v_hw   = 9
    local lcol   = (var_ok and 0x26A69A00 or 0x60606000) | ialp
    for k = 0, 2 do
      local sy_k = vy + (k - 1) * 6 - 1.5
      R.ImGui_DrawList_AddRectFilled(dl_var, vx - v_hw, sy_k, vx + v_hw, sy_k + 3, lcol, 1.0)
    end

    R.ImGui_EndChild(ctx)
  end
  R.ImGui_PopStyleVar(ctx, 1)   -- WindowPadding 0
  R.ImGui_PopStyleColor(ctx, 1) -- ChildBg
end

-- Top-level GUI render for one ImGui frame.
-- v2.0: Two-panel layout — left Mini module (48%) + right track panel (52%).
local function render_gui(ctx, app)
  local state = app.state
  local R = reaper

  -- Non-ready states: full-window display (no two-panel split).
  if state.status == "error" then
    render_status_bar(ctx, state)
    return
  end
  if state.status == "select_anchor" then
    render_group_strip(ctx, app)
    render_status_bar(ctx, state)
    render_anchor_prompt(ctx, state, app)
    return
  end
  if state.status ~= "ready" then
    render_group_strip(ctx, app)
    render_status_bar(ctx, state)
    render_loading_body(ctx, state)
    return
  end

  -- ── Title bar ───────────────────────────────────────────────────────
  local font_b = rsg_theme and rsg_theme.font_bold
  local dl_tb  = R.ImGui_GetWindowDrawList(ctx)
  local win_x, win_y = R.ImGui_GetWindowPos(ctx)
  local full_w = select(1, R.ImGui_GetWindowSize(ctx))
  local tbx, tby = R.ImGui_GetCursorScreenPos(ctx)
  R.ImGui_DrawList_AddRectFilled(dl_tb, win_x, win_y, win_x + full_w, tby + 24, SC.TITLE_BAR)
  if font_b then R.ImGui_PushFont(ctx, font_b, 13) end
  R.ImGui_SetCursorPosX(ctx, 8)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.PRIMARY)
  R.ImGui_Text(ctx, "TEMPER - VORTEX")
  R.ImGui_PopStyleColor(ctx, 1)
  if font_b then R.ImGui_PopFont(ctx) end
  -- Breathing room between title and anchor chips
  R.ImGui_SameLine(ctx, 0, 14)
  R.ImGui_Dummy(ctx, 0, 1)
  -- Inline anchor strip (chips + "+ Anchor") between title and gear
  render_group_strip_inline(ctx, app)
  -- Gear button right-aligned on title bar
  R.ImGui_SameLine(ctx)
  push_btn(ctx, SC.PANEL, SC.HOVER_LIST, SC.ACTIVE_DARK)
  R.ImGui_SetCursorPosX(ctx, full_w - 30)
  if R.ImGui_Button(ctx, "\xe2\x9a\x99##settings_v2", 22, 0) then
    R.ImGui_OpenPopup(ctx, "##settings_popup")
  end
  R.ImGui_PopStyleColor(ctx, 3)
  if R.ImGui_IsItemHovered(ctx) then R.ImGui_SetTooltip(ctx, "Settings") end
  render_settings_popup(ctx, state, app)
  R.ImGui_SetCursorPosY(ctx, R.ImGui_GetCursorPosY(ctx) + 8)

  -- ── Top bar: three-column layout (v2.1) ─────────────────────────────
  local win_w  = R.ImGui_GetContentRegionAvail(ctx)
  local _GAP   = 8
  local top_h  = 160
  local mini_w = 384   -- exact Mini content-area width (transplanted dimensions)
  local col3_w = win_w - mini_w - _GAP

  -- Columns 1+2: Mini module (ROLL hero + mode row + VARIATIONS)
  if R.ImGui_BeginChild(ctx, "##mini_panel", mini_w, top_h, 0) then
    render_mini_panel(ctx, state, app)
    R.ImGui_EndChild(ctx)
  end

  R.ImGui_SameLine(ctx, 0, _GAP)

  -- Column 3: Seek/Omit + Preset + Batch controls + Stats
  if R.ImGui_BeginChild(ctx, "##ctrl_panel", col3_w, top_h, 0) then
    render_right_column(ctx, state, app)
    R.ImGui_EndChild(ctx)
  end

  -- ── Track list (full width, scrollable) ────────────────────────────
  R.ImGui_Separator(ctx)
  render_rows_table(ctx, state)

  -- Snapshot content height before dropdown overlays (they corrupt CursorPosY)
  state._content_h = R.ImGui_GetCursorPosY(ctx)

  -- ── History dropdown overlays (rendered last for z-order) ─────────
  local _DD_ITEM_H = 20
  local _DD_MAX    = 5
  -- Clamp dropdowns to window bottom so they don't overflow and break scroll
  local _win_sx, _win_sy = R.ImGui_GetWindowPos(ctx)
  local _, _win_h = R.ImGui_GetWindowSize(ctx)
  local _win_bottom = _win_sy + _win_h

  -- Seek history dropdown
  if state.hist_active_row and #state.hist_filtered > 0 and state._dd_q_y then
    local DD_H = math.min(#state.hist_filtered, _DD_MAX) * _DD_ITEM_H + 4
    local avail = _win_bottom - state._dd_q_y
    if avail < _DD_ITEM_H + 4 then avail = _DD_ITEM_H + 4 end  -- at least 1 item
    if DD_H > avail then DD_H = avail end
    R.ImGui_SetCursorScreenPos(ctx, state._dd_q_x, state._dd_q_y)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ChildBg(),       SC.PANEL)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_HeaderHovered(), SC.TERTIARY)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_HeaderActive(),  SC.TERTIARY_AC)
    if R.ImGui_BeginChild(ctx, "##qhist", state._dd_q_w, DD_H, 0) then
      local qbx, qby = R.ImGui_GetWindowPos(ctx)
      R.ImGui_DrawList_AddRectFilled(R.ImGui_GetWindowDrawList(ctx),
        qbx, qby, qbx + state._dd_q_w, qby + DD_H, SC.PANEL)
      local qi = 1
      while qi <= #state.hist_filtered do
        local e = state.hist_filtered[qi]
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        SC.DEL_BTN)
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), SC.DEL_HV)
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  SC.DEL_AC)
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          SC.TEXT_MUTED)
        local del = R.ImGui_SmallButton(ctx, "x##qhx" .. qi)
        R.ImGui_PopStyleColor(ctx, 4)
        if del then
          table.remove(state.query_history, e.orig_idx)
          history_save(state.query_history, _HISTORY_KEY)
          local act_row = state.rows[state.hist_active_row]
          state.hist_filtered = history_filter(state.query_history, act_row and act_row.name or "")
          break
        end
        R.ImGui_SameLine(ctx)
        local sel_sx, sel_sy = R.ImGui_GetCursorScreenPos(ctx)
        local is_hov = R.ImGui_IsMouseHoveringRect(ctx, sel_sx, sel_sy, sel_sx + state._dd_q_w, sel_sy + _DD_ITEM_H)
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), is_hov and SC.WINDOW or SC.TEXT_ON)
        if R.ImGui_Selectable(ctx, e.text .. "##qhi" .. qi) then
          local ri = state.hist_active_row
          local r  = state.rows[ri]
          if r then
            r.name = e.text
            R.GetSetMediaTrackInfo_String(r.track, "P_NAME", e.text, true)
            search_row(r, state.index, state)
          end
          state.hist_active_row = nil
        end
        R.ImGui_PopStyleColor(ctx, 1)
        qi = qi + 1
      end
    end
    R.ImGui_EndChild(ctx)
    local q_child_hv = R.ImGui_IsItemHovered(ctx,
      R.ImGui_HoveredFlags_AllowWhenBlockedByActiveItem())
    R.ImGui_PopStyleColor(ctx, 3)
    -- Close when neither the input field nor the dropdown is hovered
    local seek_field_active = state.hist_active_row
        and R.ImGui_IsAnyItemActive(ctx)
    if not seek_field_active and not q_child_hv then state.hist_active_row = nil end
  end

  -- Omit history dropdown
  if state.omit_active_row and #state.omit_filtered > 0 and state._dd_om_y then
    local DD_H = math.min(#state.omit_filtered, _DD_MAX) * _DD_ITEM_H + 4
    local avail_om = _win_bottom - state._dd_om_y
    if avail_om < _DD_ITEM_H + 4 then avail_om = _DD_ITEM_H + 4 end
    if DD_H > avail_om then DD_H = avail_om end
    R.ImGui_SetCursorScreenPos(ctx, state._dd_om_x, state._dd_om_y)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ChildBg(),       SC.PANEL)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_HeaderHovered(), SC.TERTIARY)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_HeaderActive(),  SC.TERTIARY_AC)
    if R.ImGui_BeginChild(ctx, "##ohist", state._dd_om_w, DD_H, 0) then
      local qi = 1
      while qi <= #state.omit_filtered do
        local e = state.omit_filtered[qi]
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        SC.DEL_BTN)
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), SC.DEL_HV)
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  SC.DEL_AC)
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          SC.TEXT_MUTED)
        local del = R.ImGui_SmallButton(ctx, "x##ohx" .. qi)
        R.ImGui_PopStyleColor(ctx, 4)
        if del then
          table.remove(state.omit_history, e.orig_idx)
          history_save(state.omit_history, _OMIT_HISTORY_KEY)
          local act_row = state.rows[state.omit_active_row]
          state.omit_filtered = history_filter(state.omit_history, act_row and act_row.exclude_text or "")
          break
        end
        R.ImGui_SameLine(ctx)
        local sel_sx, sel_sy = R.ImGui_GetCursorScreenPos(ctx)
        local is_hov = R.ImGui_IsMouseHoveringRect(ctx, sel_sx, sel_sy, sel_sx + state._dd_om_w, sel_sy + _DD_ITEM_H)
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), is_hov and SC.WINDOW or SC.TEXT_ON)
        if R.ImGui_Selectable(ctx, e.text .. "##ohi" .. qi) then
          local ri = state.omit_active_row
          local r  = state.rows[ri]
          if r then
            r.exclude_text   = e.text
            r.exclude_tokens = db.tokenize(r.exclude_text, {})
            search_row(r, state.index, state)
          end
          state.omit_active_row = nil
        end
        R.ImGui_PopStyleColor(ctx, 1)
        qi = qi + 1
      end
    end
    R.ImGui_EndChild(ctx)
    local om_child_hv = R.ImGui_IsItemHovered(ctx,
      R.ImGui_HoveredFlags_AllowWhenBlockedByActiveItem())
    R.ImGui_PopStyleColor(ctx, 3)
    local omit_field_active = state.omit_active_row
        and R.ImGui_IsAnyItemActive(ctx)
    if not omit_field_active and not om_child_hv then state.omit_active_row = nil end
  end
end

-- ============================================================
-- MAIN
-- ============================================================

-- Test harness API — populated only when an external test script sets
-- _RSG_TEST_MODE = true before dofile()-ing this script.
if _RSG_TEST_MODE then
  _RSG_VORTEX_TEST_API = {
    do_roll_and_import = do_roll_and_import,
    do_variations      = do_variations,
    import_mod         = import_mod,
  }
end

local _TEST_MODE = false

if _TEST_MODE then
  -- ── Minimal test framework ──────────────────────────────────
  local pass_n, fail_n = 0, 0

  local function report(label, ok, detail)
    if ok then
      pass_n = pass_n + 1
      reaper.ShowConsoleMsg(string.format("[PASS] %s\n", label))
    else
      fail_n = fail_n + 1
      reaper.ShowConsoleMsg(string.format("[FAIL] %s -- %s\n", label, detail or ""))
    end
  end

  local function eq(label, got, expected)
    report(label, got == expected,
      string.format("got=%s exp=%s", tostring(got), tostring(expected)))
  end

  local function list_eq(label, got, expected)
    local same = (#got == #expected)
    if same then
      for i = 1, #got do
        if got[i] ~= expected[i] then same = false; break end
      end
    end
    local gs = "{" .. table.concat(got,      ",") .. "}"
    local es = "{" .. table.concat(expected, ",") .. "}"
    report(label, same, string.format("got=%s exp=%s", gs, es))
  end

  reaper.ShowConsoleMsg("\n=== Temper Vortex — Phase 1 Tests ===\n\n")

  -- ── Unit: db.parse_value ────────────────────────────────────
  eq("T-12  quoted multi-word value",  db.parse_value('"multi word value" 0'),    "multi word value")
  eq("T-13  unquoted single-word",     db.parse_value("SingleWord 0"),             "SingleWord")
  eq("T-12b empty quoted string",      db.parse_value('"" 0'),                     "")
  eq("T-12c quoted with inner spaces", db.parse_value('"AIRBrst Tahiti Blow " 0'), "AIRBrst Tahiti Blow ")

  -- ── Unit: db.parse_title_from_data ─────────────────────────
  eq("T-14  title found",   db.parse_title_from_data('DATA "t:Birds Forest" "a:Artist"'), "Birds Forest")
  eq("T-15  no title line", db.parse_title_from_data('DATA g:AMBIENCE "c:comment" s:96000'), nil)
  eq("T-15b data n: line",  db.parse_title_from_data("DATA n:2 r:45:22 l:0:34 i:24"), nil)

  -- ── Unit: db.parse_user_field ──────────────────────────────
  local f1, v1 = db.parse_user_field('USER IXML:USER:Keywords "AIRBrst Tahiti" 0')
  eq("T-UF1 field name",  f1, "Keywords")
  eq("T-UF2 quoted value", v1, "AIRBrst Tahiti")

  local f2, v2 = db.parse_user_field("USER IXML:USER:Category AIR 0")
  eq("T-UF3 field name",    f2, "Category")
  eq("T-UF4 unquoted value", v2, "AIR")

  local f3, v3 = db.parse_user_field("NOT A USER LINE")
  eq("T-UF5 bad line -> nil field", f3, nil)
  eq("T-UF6 bad line -> nil value", v3, nil)

  -- ── Unit: db.tokenize ──────────────────────────────────────
  list_eq("T-6  compound separators",    db.tokenize("Gun_Shot-Close_01", CONFIG.stop_words), {"gun","shot","close","01"})
  list_eq("T-7  stop words filtered",    db.tokenize("SFX_FX_Boom",       CONFIG.stop_words), {"boom"})
  list_eq("T-8  empty input",            db.tokenize("",                  CONFIG.stop_words), {})
  list_eq("T-7b mixed-case stop word",   db.tokenize("Sfx_Impact",        CONFIG.stop_words), {"impact"})
  list_eq("T-7c multiple stop words",    db.tokenize("AMB_BG_Wind",       CONFIG.stop_words), {"wind"})

  -- ── Unit: db.build_query ───────────────────────────────────
  list_eq("T-9  include parent",
    db.build_query("Gunshot", "Close Layer", true,  CONFIG.stop_words), {"gunshot","close","layer"})
  list_eq("T-10 exclude parent",
    db.build_query("Gunshot", "Close Layer", false, CONFIG.stop_words), {"close","layer"})
  list_eq("T-11 both empty names",
    db.build_query("", "",         true,  CONFIG.stop_words), {})
  list_eq("T-9b token deduplication",
    db.build_query("Gun", "Gun Shot", true, CONFIG.stop_words), {"gun","shot"})
  list_eq("T-9c empty parent skipped when exclude",
    db.build_query("", "Close", false, CONFIG.stop_words), {"close"})

  -- ── Unit: db.search (offline, no I/O) ──────────────────────
  local dummy = {
    { filepath = "a.wav", haystack = "bird forest ambience dawn chorus" },
    { filepath = "b.wav", haystack = "gunshot close mechanical body"   },
    { filepath = "c.wav", haystack = "bird mechanical impact"          },
  }
  eq("T-5  empty tokens -> no results",   #db.search(dummy, {}),                    0)
  eq("T-3u AND match both tokens",        #db.search(dummy, {"bird","forest"}),      1)
  eq("T-3v partial AND -> no results",    #db.search(dummy, {"bird","gunshot"}),     0)
  eq("T-3w single token multiple hits",   #db.search(dummy, {"bird"}),               2)
  eq("T-3x first result index",           db.search(dummy, {"bird","forest"})[1],   1)
  eq("T-4u guaranteed no-match offline",  #db.search(dummy, {"zzznomatch999"}),      0)

  -- ── Integration: db.load_index + db.search ─────────────────
  reaper.ShowConsoleMsg("\n[INFO] Loading live MediaDB index...\n")
  local t0 = reaper.time_precise()
  local index, err = db.load_index()
  local elapsed = reaper.time_precise() - t0

  eq("T-1  load_index no error",       err, nil)
  report("T-1b 70 000+ entries indexed", #index >= 70000,
    string.format("got %d entries", #index))
  reaper.ShowConsoleMsg(string.format("[INFO] Loaded %d entries in %.2fs\n", #index, elapsed))
  report("T-2  load time < 5 seconds", elapsed < 5.0,
    string.format("took %.2fs", elapsed))

  local birds  = db.search(index, db.tokenize("bird forest", CONFIG.stop_words))
  report("T-3  live bird+forest search", #birds > 0,
    string.format("got %d results", #birds))
  if #birds > 0 then
    reaper.ShowConsoleMsg(string.format("[INFO] Sample result: %s\n", index[birds[1]].filepath))
  end

  local nomatch = db.search(index, {"zzznomatch999"})
  eq("T-4  live no-match", #nomatch, 0)

  -- ── Unit: cold-start index race guard ──────────────────────
  do
    -- Simulate an app mid-load; clicking a chip must NOT switch the active group.
    local mock_app = {
      active_guid  = nil,
      context_guid = nil,
      pending_guid = nil,
      state        = { status = "loading", index = {}, rows = {}, font_bold = nil },
    }
    _switch_to_group(mock_app, "GUID-A")
    eq("T-R1 switch during load defers (pending_guid set)",   mock_app.pending_guid, "GUID-A")
    eq("T-R2 switch during load leaves active_guid unchanged", mock_app.active_guid,  nil)
    -- A second chip click overwrites the first pending target.
    _switch_to_group(mock_app, "GUID-B")
    eq("T-R3 second switch overwrites pending_guid",           mock_app.pending_guid, "GUID-B")
    -- Once loading completes, _switch_to_group should not defer.
    -- (groups.find_track will return nil for a fake GUID — _switch_to_group no-ops, which is fine.)
    mock_app.state.status = "searching"
    _switch_to_group(mock_app, "GUID-B")  -- exercises the non-deferred path
    -- pending_guid is unchanged: only the defer loop clears it, not _switch_to_group.
    eq("T-R4 non-loading status does not defer (pending_guid unchanged)", mock_app.pending_guid, "GUID-B")
    -- Switching to an already-active group while loading should still defer,
    -- then resolve silently on the active_guid early-return without error.
    mock_app.state.status = "loading"
    mock_app.active_guid  = "GUID-C"
    mock_app.pending_guid = nil
    _switch_to_group(mock_app, "GUID-C")  -- pending_guid == active_guid scenario
    eq("T-R5 same-as-active deferred correctly during load", mock_app.pending_guid, "GUID-C")
    -- Simulating the defer-loop resolution: status becomes ready, loop calls switch again.
    mock_app.state.status = "ready"
    _switch_to_group(mock_app, mock_app.pending_guid)  -- hits active_guid guard, returns cleanly
    eq("T-R5b same-as-active clears without crash (pending_guid not mutated by switch)", mock_app.pending_guid, "GUID-C")
  end

  -- ── Unit: track_preset (v1.3.0) ────────────────────────────
  do
    -- Save a template and round-trip it through load.
    local fake_row = { mode = "unique", include_parent = false,
                       exclude_text = "metal glass", inherit_props = true }
    track_preset.save("test_round_trip", fake_row)
    local loaded = track_preset.load("test_round_trip")
    report("TPL-1  load returns non-nil",  loaded ~= nil, "got nil")
    if loaded then
      eq("TPL-2  mode preserved",           loaded.mode,           "unique")
      eq("TPL-3  include_parent preserved", loaded.include_parent, false)
      eq("TPL-4  exclude_text preserved",   loaded.exclude_text,   "metal glass")
      eq("TPL-5  inherit_props preserved",  loaded.inherit_props,  true)
    end
    -- Verify it appears in the list.
    local tpls = track_preset.list()
    local found_tpl = false
    for _, n in ipairs(tpls) do if n == "test_round_trip" then found_tpl = true end end
    report("TPL-6  appears in list", found_tpl, "not found")
    -- Delete and confirm removal.
    track_preset.delete("test_round_trip")
    eq("TPL-7  load after delete returns nil", track_preset.load("test_round_trip"), nil)
    local tpls2 = track_preset.list()
    local gone = true
    for _, n in ipairs(tpls2) do if n == "test_round_trip" then gone = false end end
    report("TPL-8  absent from list after delete", gone, "still present")
  end

  -- ── Unit: preset_structure_check (v1.3.0) ──────────────────
  do
    local mock_rows = {
      { name = "Body",     results = {}, exclude_text = "" },
      { name = "Cloth",    results = {}, exclude_text = "" },
      { name = "Footstep", results = {}, exclude_text = "" },
    }
    local full_prows  = { {name="Body"}, {name="Cloth"}, {name="Footstep"} }
    local part_prows  = { {name="Body"}, {name="Cloth"}, {name="Missing1"} }
    local none_prows  = { {name="NoA"},  {name="NoB"} }
    local mock_state  = { rows = mock_rows }

    local miss1, mat1 = preset_structure_check(full_prows, mock_state)
    eq("PSC-1  full match: 0 missing", #miss1, 0)
    eq("PSC-2  full match: 3 matched", #mat1,  3)

    local miss2, mat2 = preset_structure_check(part_prows, mock_state)
    eq("PSC-3  partial: 1 missing", #miss2, 1)
    eq("PSC-4  partial: 2 matched", #mat2,  2)
    eq("PSC-5  partial: correct missing name", miss2[1], "Missing1")

    local miss3, _ = preset_structure_check(none_prows, mock_state)
    eq("PSC-6  no match: 2 missing", #miss3, 2)
  end

  -- ── Summary ────────────────────────────────────────────────
  reaper.ShowConsoleMsg(string.format(
    "\n=== %d passed, %d failed ===\n", pass_n, fail_n))

elseif not _RSG_TEST_MODE then
  -- ── Dependency check ─────────────────────────────────────────
  if not reaper.ImGui_CreateContext then
    reaper.ShowMessageBox(
      "ReaImGui is required. Install it via ReaPack:\n" ..
      "Extensions > ReaPack > Browse packages > search \"ReaImGui\"",
      "Temper Vortex — Missing Dependency", 0)
    return
  end

  -- ── Init ─────────────────────────────────────────────────────
  math.randomseed(os.time())
  _migrate_extstate()

  -- ── Instance guard ────────────────────────────────────────────
  -- Prevents a second GUI from opening when the script is re-launched while
  -- an instance is already running.  The defer loop keeps the timestamp
  -- alive; a stale timestamp (>= 1 s old) means REAPER crashed or the script
  -- exited, so a fresh launch is permitted.
  --
  -- RSG-106 fix: on clean exit we write "" (not delete) so the guard can
  -- distinguish "cleanly closed" (empty → allow reopen) from "still running"
  -- (recent numeric timestamp → block).  Deleting the key previously caused
  -- a race where REAPER's re-launch sequence started the new instance before
  -- cleanup finished, so the new instance saw no key and opened a duplicate.
  local _inst_ts = reaper.GetExtState(_EXT_SEC, "instance_ts")
  reaper.ShowConsoleMsg("[Temper Vortex] instance guard: ts='" .. _inst_ts .. "' now=" .. tostring(reaper.time_precise()) .. "\n")
  if _inst_ts ~= "" and tonumber(_inst_ts) and (reaper.time_precise() - tonumber(_inst_ts)) < 1.0 then
    reaper.ShowConsoleMsg("[Temper Vortex] instance guard: BLOCKED (duplicate detected)\n")
    reaper.ShowMessageBox(
      "Temper Vortex is already running.\nClose the existing window before opening a new instance.",
      "Temper Vortex", 0)
    return
  end
  reaper.ShowConsoleMsg("[Temper Vortex] instance guard: ALLOWED (starting fresh instance)\n")
  reaper.SetExtState(_EXT_SEC, "instance_ts", tostring(reaper.time_precise()), false)

  -- ReaImGui rate-limits CreateContext at the same call site to prevent
  -- runaway context churn. If a prior instance's defer loop was killed
  -- (script terminated, REAPER restart mid-defer, etc.), the GC window can
  -- still be open when the user relaunches. Surface a friendly message
  -- instead of a raw Lua error, and clear the instance_ts sentinel so
  -- the guard doesn't also block the next retry.
  local _ctx_ok, ctx = pcall(reaper.ImGui_CreateContext, "Temper Vortex")
  if not _ctx_ok or not ctx then
    reaper.SetExtState(_EXT_SEC, "instance_ts", "", false)
    reaper.ShowMessageBox(
      "Temper Vortex could not start because ReaImGui is still cleaning " ..
      "up from a previous instance.\n\n" ..
      "Close any existing Vortex window, wait ~15 seconds, then try again.\n" ..
      "If it keeps happening, restart REAPER.",
      "Temper Vortex", 0)
    return
  end
  local _WIN_W = 600
  local _MIN_WIN_H = 280
  local _MAX_WIN_H = 1200
  local _content_h = nil  -- measured after all rendering; applied next frame
  reaper.ImGui_SetNextWindowSize(ctx, _WIN_W, 500, reaper.ImGui_Cond_FirstUseEver())

  -- ── License setup ─────────────────────────────────────────────
  -- rsg_theme must be loaded and fonts attached before the activation dialog renders.
  pcall(dofile, _lib .. "rsg_theme.lua")
  if type(rsg_theme) == "table" then rsg_theme.attach_fonts(ctx) end
  local _lic_ok, lic = pcall(dofile, _lib .. "rsg_license.lua")
  if not _lic_ok then
    reaper.ShowMessageBox(
      "Could not load rsg_license.lua — reinstall Temper Vortex to fix this.\n\n" ..
      tostring(lic), "Temper Vortex — Missing Dependency", 0)
    return
  end
  lic.configure({
    namespace    = "TEMPER_Vortex",
    scope_id     = 0x1,
    display_name = "Vortex",
    buy_url      = "https://www.tempertools.com/scripts/vortex",
  })

  -- font_bold: reuse rsg_theme's handle (avoids duplicate font atlas entry).
  -- Fallback: create and attach a standalone bold font if rsg_theme failed to load.
  local font_bold
  if type(rsg_theme) == "table" and rsg_theme.font_bold then
    font_bold = rsg_theme.font_bold
  else
    font_bold = reaper.ImGui_CreateFont("Arial Bold", 13)
    reaper.ImGui_Attach(ctx, font_bold)
  end

  local state = {
    status          = "init",
    error_msg       = nil,
    index           = {},
    file_lists      = {},
    load_idx        = 0,
    parse_fh        = nil,   -- open file handle during chunked MediaDB parse
    parse_cur       = nil,   -- entry being built across ticks
    parse_data_seen = false, -- DATA line flag for current entry
    search_idx      = 0,
    parent_track    = nil,
    parent_name     = "",
    rows            = {},
    child_count     = 0,
    preset_name_buf      = "",
    active_preset_name   = nil,  -- nil = "Default"; string = name of loaded preset (C16)
    preset_overwrite_buf = nil,  -- set when overwrite confirmation is open (C16)
    global_not      = {text = "", tokens = {}},  -- top-level NOT; applies to all rows
    group_not       = {},  -- [group_name] = {text, tokens}; applies to rows in that group
    var_n_buf       = "1",    -- Variations: count field (string for InputText)
    var_x_buf       = "4.0", -- Variations: spacing magnitude
    var_unit        = 0,      -- Variations: 0 = seconds, 1 = beats
    font_bold       = font_bold,
    inherit_global  = true,   -- master toggle: inherit paste properties on Roll / Variations
    prop_snapshot   = nil,    -- in-memory only; populated by Capture button; cleared on script close
    -- Track template picker (v1.3.0)
    tpl_name_buf         = "",   -- shared name buffer for "save as template" input
    -- Pending global-preset load when track structure mismatches (v1.3.0)
    pending_preset_name  = nil,   -- preset name deferred to mismatch dialog
    pending_preset_rows  = nil,   -- deserialized preset rows
    pending_missing      = nil,   -- track names absent from current folder
    _need_mismatch_popup = false, -- D4: deferred OpenPopup flag (must open from main-window context)
    -- Row selection helpers (v1.5.0)
    last_sel_idx         = nil,   -- U2: anchor row index for shift+click range select
    _row_clicked_this_frame = false,  -- U4: set when a row Selectable fires this frame
    -- Seek/Omit history cache (v1.7.27)
    query_history   = history_load(_HISTORY_KEY),
    omit_history    = history_load(_OMIT_HISTORY_KEY),
    hist_filtered   = {},
    omit_filtered   = {},
    hist_active_row = nil,  -- row index whose seek dropdown is open (nil = none)
    omit_active_row = nil,  -- row index whose omit dropdown is open (nil = none)
    _dd_q_x  = 0, _dd_q_y  = 0, _dd_q_w = 0,  -- seek dropdown anchor
    _dd_om_x = 0, _dd_om_y = 0, _dd_om_w = 0,  -- omit dropdown anchor
  }

  local app = { state = state, active_guid = nil, context_guid = nil, pending_guid = nil,
                _prev_reaper_sel_key = "" }  -- U6: last-seen REAPER selection key for change detection

  -- ── Action dispatch (rsg_actions framework) ───────────────────
  -- Every key MUST correspond to a command in scripts/lua/actions/manifest.toml.
  -- Entries are thin pointers: they call through vortex_actions, which mirrors
  -- the GUI button callbacks 1:1 (subset-of-GUI invariant).
  -- `close` is a framework built-in dispatched by rsg_actions.toggle_window.
  local HANDLERS = {
    roll              = function() vortex_actions.do_roll(state) end,
    variations        = function() vortex_actions.do_variations(state) end,
    capture           = function() vortex_actions.do_capture(state) end,
    toggle_active     = function() vortex_actions.toggle_active(state) end,
    toggle_par        = function() vortex_actions.toggle_par(state) end,
    toggle_inh        = function() vortex_actions.toggle_inh(state) end,
    toggle_inh_global = function() vortex_actions.toggle_inh_global(state) end,
    cycle_mode        = function() vortex_actions.cycle_mode(state) end,
    toggle_time_unit  = function() vortex_actions.toggle_time_unit(state) end,
    close             = function() app._close_requested = true end,
  }
  rsg_actions.clear_pending_on_init(_EXT_SEC)

  -- ── Defer loop ────────────────────────────────────────────────
  local function loop()
    reaper.SetExtState(_EXT_SEC, "instance_ts", tostring(reaper.time_precise()), false)
    rsg_actions.heartbeat(_EXT_SEC)
    local _focus_requested = rsg_actions.poll(_EXT_SEC, HANDLERS)
    _check_context_switch(app)
    -- Auto-engage a registered anchor when no group is active (fresh load / reload).
    if not app.active_guid and app.context_guid and not app.pending_guid then
      if app.state.status == "select_anchor" then
        app.state.status = "init"
      end
      _switch_to_group(app, app.context_guid)
    end
    tick_state(app.state)
    -- U6: live REAPER-to-GUI track selection sync (F3: hardened).
    -- Guards:
    --  1. Only run when index is ready (no partial state).
    --  2. Only run when REAPER selection actually changed (key hash).
    --  3. Skip when the user just clicked a row in the GUI this frame to prevent
    --     the REAPER sync from overwriting a GUI-initiated deselect on the same tick.
    if app.state.status == "ready" and not app.state._row_clicked_this_frame then
      local n_sel = reaper.CountSelectedTracks(0)
      local sel_key = tostring(n_sel)
      for i = 0, n_sel - 1 do
        local t = reaper.GetSelectedTrack(0, i)
        if t then sel_key = sel_key .. "|" .. tostring(t) end
      end
      if sel_key ~= app._prev_reaper_sel_key then
        local first_ready = app._prev_reaper_sel_key == ""
        app._prev_reaper_sel_key = sel_key
        if not first_ready then
          _sync_reaper_selection_to_gui(app.state)
        end
      end
    end
    -- Resolve any group switch that was deferred during MediaDB load.
    -- Invariant: _switch_to_group must NOT mutate app.pending_guid; only this
    -- block clears it.  pending_guid is cleared unconditionally so stale or
    -- already-active GUIDs are not retried on subsequent ticks.
    if app.pending_guid then
      local s = app.state.status
      if s ~= "loading" and s ~= "init" then
        _switch_to_group(app, app.pending_guid)
        app.pending_guid = nil
      end
    end
    -- Auto-fit height to content; clamp to min/max
    if _content_h then
      local h = math.max(_MIN_WIN_H, math.min(_MAX_WIN_H, _content_h))
      reaper.ImGui_SetNextWindowSize(ctx, _WIN_W, h, reaper.ImGui_Cond_Always())
    end
    if _focus_requested then
      reaper.ImGui_SetNextWindowFocus(ctx)
      if reaper.APIExists and reaper.APIExists("JS_Window_SetForeground") then
        local hwnd = reaper.JS_Window_Find and reaper.JS_Window_Find("Temper Vortex", true)
        if hwnd then reaper.JS_Window_SetForeground(hwnd) end
      end
    end
    local n = rsg_theme and rsg_theme.push(ctx) or 0
    local win_flags = reaper.ImGui_WindowFlags_NoCollapse()
                    | reaper.ImGui_WindowFlags_NoTitleBar()
                    | reaper.ImGui_WindowFlags_NoResize()
                    | reaper.ImGui_WindowFlags_NoScrollbar()
                    | reaper.ImGui_WindowFlags_NoScrollWithMouse()  -- RSG-153: prevent dropdown scroll bleed
    local visible, open = reaper.ImGui_Begin(ctx, "Temper Vortex", true, win_flags)
    if visible then
      local lic_status = lic.check("VORTEX", ctx)
      app.lic_status = lic_status  -- C14: make available to render_settings_popup
      if lic_status == "expired" then
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_TextColored(ctx, SC.ERROR_RED, "  Your Vortex trial has expired.")
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_TextDisabled(ctx, "  Purchase a license at tempertools.com to continue.")
        if not lic.is_dialog_open() then lic.open_dialog(ctx) end
        lic.draw_dialog(ctx)
      else
        render_gui(ctx, app)
        -- Measure content height after all rendering for next-frame auto-fit
        _content_h = app.state._content_h or reaper.ImGui_GetCursorPosY(ctx)
        -- RSG-110: Activate moved to settings popup only; dialog always drawn so it
        -- renders when opened from the gear button regardless of license state.
        lic.draw_dialog(ctx)
      end
      reaper.ImGui_End(ctx)  -- F9: must only be called when visible=true (undock crash fix)
    end
    if rsg_theme then rsg_theme.pop(ctx, n) end
    if open and not app._close_requested then
      reaper.defer(loop)
    else
      -- RSG-106: write empty sentinel (not delete) so guard knows we exited cleanly.
      -- This allows immediate reopen without waiting for key staleness.
      reaper.SetExtState(_EXT_SEC, "instance_ts", "", false)
    end
    -- ImGui_DestroyContext removed in ReaImGui ≥0.8; context is GC'd automatically.
  end

  reaper.defer(loop)
end
