-- @description Temper Vortex Mini -- Single-Item Layer Randomizer
-- @version 1.14.35
-- @author Temper Tools
-- @provides
--   [main] Temper_Vortex_Mini.lua
--   [nomain] lib/temper_sha256.lua
--   [nomain] lib/temper_license.lua
--   [nomain] lib/temper_theme.lua
--   [nomain] lib/temper_activation_dialog.lua
--   [nomain] lib/temper_mediadb.lua
--   [nomain] lib/temper_track_utils.lua
--   [nomain] lib/temper_import.lua
--   [nomain] lib/temper_pp_apply.lua
--   [nomain] lib/temper_actions.lua
-- @about
--   Temper Vortex Mini is a lightweight companion to Temper Vortex for single-item
--   ad hoc workflows. Select any item, launch Mini, and roll variations on
--   that item's track without a folder/anchor structure.
--
--   Features:
--   - Single-item context: query auto-derived from track and folder ancestry
--   - Inline editable query + NOT exclusion filter; Trk auto-detect toggle
--   - FREE / UNIQUE / LOCK modes (cue-shift for LOCK)
--   - Property capture from selected item at launch
--   - Variations: N sequential slots on the same target track
--   - Non-blocking MediaDB load with live progress indicator
--
--   Requires: ReaImGui (install via ReaPack -- Extensions)

-- ============================================================
-- Dependency checks
-- ============================================================

if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox(
    "Temper Vortex Mini requires ReaImGui.\nInstall via ReaPack: Extensions > ReaImGui",
    "Missing Dependency", 0)
  return
end

-- ============================================================
-- CONFIG
-- ============================================================

local CONFIG = {
  -- Tokens stripped during query construction (case-insensitive).
  stop_words = {
    SFX  = true, FX   = true, BG   = true,
    AMB  = true, MUS  = true, ROOM = true,
    EXT  = true, INT  = true,
  },
  -- When true, imported items are trimmed to end at their first take marker
  -- (cue point). Useful for multi-cue SFX library files.
  trim_to_first_cue = true,
}

-- ============================================================
-- lib/ module loading
-- ============================================================

-- Resolve lib/ as a sibling of this script (works for both dev layout and
-- per-package ReaPack layout — see Temper_Vortex.lua for context).
local _script_path = debug.getinfo(1, "S").source:sub(2)
local _lib         = (_script_path:match("^(.*)[\\/]") or ".") .. "/lib/"
local _pp_desc   = dofile(_lib .. "temper_pp_descriptors.lua")
local _PP_TAKE_PROPS = _pp_desc.take
local _PP_ITEM_PROPS = _pp_desc.item
local db         = dofile(_lib .. "temper_mediadb.lua")
local track      = dofile(_lib .. "temper_track_utils.lua")
local import_mod = (dofile(_lib .. "temper_import.lua"))(CONFIG)
local _pp_mod    = dofile(_lib .. "temper_pp_apply.lua")
local _pp        = _pp_mod.create(_PP_TAKE_PROPS, _PP_ITEM_PROPS, import_mod.trim_item_to_max)
local rsg_actions = dofile(_lib .. "temper_actions.lua")

-- ============================================================
-- ExtState namespace + query history
-- ============================================================

local _SLIM_NS     = "TEMPER_Vortex_Mini"
local _HISTORY_KEY      = "query_history"
local _OMIT_HISTORY_KEY = "omit_history"
local _HISTORY_SEP = "\x1e"   -- ASCII Record Separator (safe; queries never contain this char)
local _HISTORY_MAX = 200

-- Normalize query for deduplication: lowercase + trim whitespace.
local function _hist_normalize(q)
  return (q:lower():gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Tokenize query: split on whitespace, strip the exact ALL-CAPS token "NOT" only.
-- "not" / "Not" / "nothing" etc. are preserved per spec.
local function _hist_tokenize(q)
  local tokens = {}
  for w in (q or ""):gmatch("%S+") do
    if w ~= "NOT" then
      tokens[#tokens + 1] = w:lower()
    end
  end
  return tokens
end

-- Load history from ExtState. Returns list of {text, norm, tokens} (most-recent first).
local function history_load(key)
  local raw = reaper.GetExtState(_SLIM_NS, key)
  local h   = {}
  if raw == "" then return h end
  for entry in (raw .. _HISTORY_SEP):gmatch("(.-)\x1e") do
    if entry ~= "" then
      h[#h + 1] = { text = entry, norm = _hist_normalize(entry), tokens = _hist_tokenize(entry) }
    end
  end
  return h
end

-- Persist history to ExtState (survive REAPER restart via persist=true).
local function history_save(h, key)
  local parts = {}
  for _, e in ipairs(h) do parts[#parts + 1] = e.text end
  reaper.SetExtState(_SLIM_NS, key, table.concat(parts, _HISTORY_SEP), true)
end

-- Add a query to history: dedup by normalized form, prepend (most-recent first),
-- then enforce _HISTORY_MAX cap. Persists immediately.
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

-- Filter history with order-independent token matching (AND: all input tokens must
-- appear in the entry). Strips ALL-CAPS "NOT" from input before matching.
-- Empty input returns all entries. Returns list of {text, score, orig_idx} desc.
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

-- ============================================================
-- Property capture — from selected item at launch
-- ============================================================

-- Capture a property snapshot from a single item. Returns a table compatible
-- with _pp.apply_to_item(snapshot, item, track_guid).
-- All captured fields are marked enabled; uncaptured fields are disabled.
-- @param item       MediaItem*
-- @param track_guid string  GUID of the item's parent track
-- @return table|nil  snapshot, or nil if item is invalid
local function _pp_capture_from_item(item, track_guid)
  if not item or not reaper.ValidatePtr(item, "MediaItem*") then return nil end
  local take = reaper.GetActiveTake(item)
  local slot  = { props = {}, fx_chunk = "" }
  local enabled = {}

  -- Take scalar properties
  for _, p in ipairs(_PP_TAKE_PROPS) do
    if not p.is_envelope and take then
      if p.is_string then
        local _, v = reaper.GetSetMediaItemTakeInfo_String(take, p.parmname, "", false)
        if v and v ~= "" then
          slot.props[p.key] = v
          enabled[p.key]    = true
        end
      else
        local v = reaper.GetMediaItemTakeInfo_Value(take, p.parmname)
        slot.props[p.key] = tostring(v)
        enabled[p.key]    = true
      end
    end
  end

  -- Take envelope chunks: read from the SOURCE item only.
  -- Nil-checked before use; not writing to a destination take.
  if take then
    for _, p in ipairs(_PP_TAKE_PROPS) do
      if p.is_envelope then
        local env = reaper.GetTakeEnvelopeByName(take, p.env_name)
        if env and reaper.CountEnvelopePoints(env) > 0 then
          local _, chunk = reaper.GetEnvelopeStateChunk(env, "", false)
          if chunk and chunk ~= "" then
            slot.props[p.key] = chunk
            enabled[p.key]    = true
          end
        end
      end
    end
  end

  -- Item scalar properties
  for _, p in ipairs(_PP_ITEM_PROPS) do
    local v = reaper.GetMediaItemInfo_Value(item, p.parmname)
    slot.props[p.key] = tostring(v)
    enabled[p.key]    = true
  end

  -- Capture item length for use as a max-cap on rolled items
  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  if item_len > 0 then
    slot.props["i_len"] = tostring(item_len)
    enabled["i_len"]    = true
  end

  -- FX chain: extract <TAKEFX> block from item state chunk.
  -- If the item has no FX chain the block is absent and fx_chunk stays "".
  local ok_chunk, item_chunk = reaper.GetItemStateChunk(item, "", false)
  if ok_chunk and item_chunk ~= "" then
    local s = item_chunk:find("<TAKEFX", 1, true)
    if s and item_chunk:sub(s + 7, s + 7):match("[%s>]") then
      local depth, j = 1, s + 1
      while j <= #item_chunk and depth > 0 do
        local c = item_chunk:sub(j, j)
        if c == "<" then depth = depth + 1 elseif c == ">" then depth = depth - 1 end
        j = j + 1
      end
      local fx_block = item_chunk:sub(s, j - 1)
      if fx_block ~= "" then
        slot.fx_chunk   = fx_block
        enabled["i_fx"] = true
      end
    end
  end
  if enabled["i_fx"] == nil then enabled["i_fx"] = false end

  -- Use a fixed key so properties apply regardless of which track Roll targets (F1: cross-track).
  return { tracks = { ["__default__"] = slot }, enabled = enabled, count = 1 }
end

-- Apply property snapshot to item, gating playrate on LOCK mode.
local function _pp_apply(state, item)
  local snap = state.prop_snapshot
  local prev_rate = snap.enabled["t_rate"]
  local prev_name = snap.enabled["t_name"]
  snap.enabled["t_rate"] = prev_rate and (state.mode == "lock")
  snap.enabled["t_name"] = false  -- take name belongs to the imported file, not the snapshot
  _pp.apply_to_item(snap, item, "__default__")
  snap.enabled["t_rate"] = prev_rate
  snap.enabled["t_name"] = prev_name
end

-- ============================================================
-- Helpers
-- ============================================================

-- Format an integer with comma thousands separators.
local function _format_count(n)
  local s      = tostring(math.floor(n))
  local result = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return result:match("^,?(.+)$") or s
end

-- ============================================================
-- Search
-- ============================================================

-- Build the effective search query from user input + optional Trk auto-detect.
-- The Query box only shows state.user_query; Trk flag appends the auto-detected
-- child track name (state.child_name) implicitly — no editable text field.
-- @param state table
-- @return string  Combined query string for tokenization
local function _effective_query(state)
  local parts = {}
  if state.user_query ~= "" then
    parts[#parts + 1] = state.user_query
  end
  if state.include_track and state.child_name ~= "" then
    parts[#parts + 1] = state.child_name
  end
  return table.concat(parts, " ")
end

-- Run AND-token search for the current slim state. Updates results.
-- Empty query with Trk off (or unnamed track) returns the full library.
-- @param state table  App state (mutated in place)
local function search_slim(state)
  local tokens = db.tokenize(_effective_query(state), CONFIG.stop_words)
  local raw

  if #tokens == 0 then
    -- No query, Trk off (or unnamed track): return full library.
    raw = {}
    for i = 1, #state.index do raw[#raw + 1] = i end
  else
    raw = db.search(state.index, tokens)
  end

  local not_tok            = db.tokenize(state.not_text, CONFIG.stop_words)
  state.raw_result_count   = #raw
  state.results            = db.filter_exclusions(state.index, raw, not_tok)
  state.current_idx        = nil
end

-- ============================================================
-- Roll / Import
-- ============================================================

-- Pick a random result for slim state, honouring mode.
-- "free"   → pure random pick
-- "unique" → avoid repeating previous pick when >1 result
-- "lock"   → no-op (cue-shift path handles it)
-- @param state table
local function do_roll_slim(state)
  if #state.results == 0 then return end
  if state.mode == "lock" and state.current_idx then return end
  if state.mode == "unique" and #state.results > 1 then
    local prev, attempts = state.current_idx, 0
    repeat
      state.current_idx = state.results[math.random(1, #state.results)]
      attempts = attempts + 1
    until state.current_idx ~= prev or attempts >= 20
  else
    state.current_idx = state.results[math.random(1, #state.results)]
  end
end

-- Shift the cue offset of an existing item to a random WAV cue boundary.
-- Checks REAPER take markers first, falls back to reading the WAV cue chunk.
-- Does NOT import a new item — for use when an item is already in place.
-- @param item     MediaItem*
-- @param filepath string  Source file path (for WAV cue fallback)
-- @return boolean  true on success
local function _shift_cue_on_item(item, filepath)
  if not item or not reaper.ValidatePtr(item, "MediaItem*") then return false end
  local take = reaper.GetActiveTake(item)
  if not take then return false end

  local bounds = { 0.0 }
  local n_tm   = reaper.GetNumTakeMarkers(take)
  for i = 0, n_tm - 1 do
    local mpos = reaper.GetTakeMarker(take, i)
    if mpos > 0.001 then bounds[#bounds + 1] = mpos end
  end
  if #bounds < 2 then
    local cues = import_mod.read_wav_cue_list_sec(filepath)
    for _, c in ipairs(cues) do bounds[#bounds + 1] = c end
  end
  if #bounds < 2 then return true end  -- no usable cues; nothing to shift

  local src       = reaper.GetMediaItemTake_Source(take)
  local total_len = reaper.GetMediaSourceLength(src, false)
  local chosen    = math.random(1, #bounds - 1)
  local start_sec = bounds[chosen]
  local next_cue  = bounds[chosen + 1]
  local item_len  = (CONFIG.trim_to_first_cue and next_cue)
                    and (next_cue - start_sec) or (total_len - start_sec)

  reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", start_sec)
  reaper.SetMediaItemLength(item, math.max(0.01, item_len), false)
  reaper.UpdateItemInProject(item)
  return true
end

-- Locate or import the locked file at pos, then shift to a random WAV cue boundary.
-- F8: reuse an existing item at pos only when its source file matches filepath.
-- If the item at pos is from a different file (stale prior-session item), it is
-- replaced so LOCK always operates on the correct source.
-- Checks REAPER take markers first, falls back to reading the WAV cue chunk.
-- @param state table
-- @param pos   number  Project time in seconds
-- @param filepath string  The locked source file to operate on
-- @return boolean  true on success
local function apply_random_cue_slim(state, pos, filepath)
  if not filepath then return false end
  local item = import_mod.find_item_at_cursor(state.target_track, pos)
  -- RSG-113: only reuse existing item when its source matches the locked file.
  -- A stale prior-session item at pos must be replaced, not cue-shifted in place.
  if item then
    local take      = reaper.GetActiveTake(item)
    local existing  = take and reaper.GetMediaSourceFileName(
                        reaper.GetMediaItemTake_Source(take), "") or ""
    if existing ~= filepath then
      reaper.DeleteTrackMediaItem(state.target_track, item)
      item = nil
    end
  end
  if not item then
    if not import_mod.import_file(state.target_track, filepath, pos) then return false end
    item = import_mod.find_item_at_cursor(state.target_track, pos)
  end
  if not item then return true end
  _shift_cue_on_item(item, filepath)
  return true
end

-- Re-read REAPER selection before each Roll/Variations (B2: track targeting fix).
-- Sets state.target_track, target_guid, child_name, roll_pos, and had_selection.
-- Also refreshes child_name (B6: keeps Trk filter in sync when track changes after launch).
-- @param state table
local function refresh_context(state)
  local item_count = reaper.CountSelectedMediaItems(0)
  if item_count >= 1 then
    local item      = reaper.GetSelectedMediaItem(0, 0)
    local new_track = reaper.GetMediaItem_Track(item)
    state.target_track  = new_track
    state.target_guid   = reaper.GetTrackGUID(new_track)
    state.roll_pos      = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    state.had_selection = true
  else
    -- No item selected: prefer explicitly selected track, then last-touched, then preserve.
    -- RSG-109: when items are deleted and user selects a new track, GetSelectedTrack
    -- reflects that intent; the old state.target_track would otherwise persist.
    local sel_track = reaper.GetSelectedTrack(0, 0)
    if track.is_valid(sel_track) then
      state.target_track = sel_track
      state.target_guid  = reaper.GetTrackGUID(sel_track)
    elseif not track.is_valid(state.target_track) then
      local lt = reaper.GetLastTouchedTrack()
      if track.is_valid(lt) then
        state.target_track = lt
        state.target_guid  = reaper.GetTrackGUID(lt)
      end
    end
    -- F2: when a time selection exists, anchor to its start so the item lands within it.
    local ts_s, ts_e = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    state.roll_pos      = (ts_e > ts_s) and ts_s or reaper.GetCursorPosition()
    state.had_selection = false
  end
  -- B6: sync child_name with target_track so Trk filter is never stale after track changes.
  if track.is_valid(state.target_track) then
    local _, pname = reaper.GetSetMediaTrackInfo_String(state.target_track, "P_NAME", "", false)
    state.child_name   = (pname ~= nil and pname ~= "") and pname or ""
  end
end

-- Roll + import a single variation on the target track. Owns its own undo block.
-- LOCK with existing file → cue-shift.  FREE/UNIQUE → pick new file and import.
-- @param state table
local function do_roll_and_import_slim(state)
  refresh_context(state)  -- B2: re-read selection before each roll
  if not track.is_valid(state.target_track) then
    reaper.ShowConsoleMsg("[Temper Vortex Mini] Roll: no valid track found — select a track or item first.\n")
    return
  end
  local eff_pos = state.roll_pos  -- B1: use selected item position, not cursor

  -- LOCK path: shift cue of the item already at eff_pos (F8: don't replace it).
  if state.mode == "lock" and state.lock_filepath then
    reaper.Undo_BeginBlock()
    -- F8: find existing item first; only import if the slot is empty.
    local lock_item = import_mod.find_item_at_cursor(state.target_track, eff_pos)
    if not lock_item then
      import_mod.import_file(state.target_track, state.lock_filepath, eff_pos)
      lock_item = import_mod.find_item_at_cursor(state.target_track, eff_pos)
    end
    if lock_item then
      _shift_cue_on_item(lock_item, state.lock_filepath)
      if state.inherit_props and state.prop_snapshot then
        _pp_apply(state, lock_item)
      end
      reaper.SetMediaItemSelected(lock_item, true)
    end
    reaper.UpdateArrange()
    reaper.Main_OnCommand(40047, 0)
    reaper.Undo_EndBlock("Temper Vortex Mini: random cue", -1)
    if reaper.JS_Window_SetFocus then reaper.JS_Window_SetFocus(reaper.GetMainHwnd()) end
    return
  end

  if #state.results == 0 then return end
  do_roll_slim(state)
  reaper.Undo_BeginBlock()
  local filepath = state.index[state.current_idx].filepath
  if not import_mod.import_file(state.target_track, filepath, eff_pos) then
    state.error_flash_msg   = "Import failed \xe2\x80\x94 file may be missing"
    state.error_flash_until = reaper.time_precise() + 2.0
    reaper.Undo_EndBlock("Temper Vortex Mini: Roll (failed)", -1)
    return
  end
  state.last_rolled_filepath = filepath  -- F9: track for LOCK capture
  local placed = import_mod.find_item_at_cursor(state.target_track, eff_pos)
  if placed and state.inherit_props and state.prop_snapshot then
    _pp_apply(state, placed)
  end
  -- F6: when TS is active, trim placed item to TS length regardless of selection or props.
  -- Apply AFTER props so TS always wins over any captured i_len.
  if placed then
    local ts_s, ts_e = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    if ts_e > ts_s then import_mod.trim_item_to_max(placed, ts_e - ts_s) end
  end
  if placed then reaper.SetMediaItemSelected(placed, true) end  -- F1: keep placed item selected
  reaper.UpdateArrange()
  reaper.Main_OnCommand(40047, 0)
  reaper.Undo_EndBlock("Temper Vortex Mini: Roll", -1)
  if reaper.JS_Window_SetFocus then reaper.JS_Window_SetFocus(reaper.GetMainHwnd()) end
end

-- ============================================================
-- Variations
-- ============================================================

-- Return the project time for variation slot i (1-based).
-- unit 0 = seconds (linear), unit 1 = beats (respects tempo map).
local function _var_pos(cursor_pos, i, x_val, unit)
  if unit == 0 then return cursor_pos + i * x_val end
  -- TimeMap2_timeToBeats returns: retval, measures, cBeat, fullbeats, cdenom.
  -- Must use fullbeats (4th return) for linear beat arithmetic. B5 fix.
  local _, _, _, start_q = reaper.TimeMap2_timeToBeats(0, cursor_pos)
  return reaper.TimeMap2_beatsToTime(0, start_q + i * x_val)
end

-- Place N randomized variation slots on state.target_track, spaced X sec/beats apart.
-- Batch always re-rolls per slot regardless of mode (LOCK treated as FREE for variety).
-- Edit cursor and time-selection advance to start of slot N+1 when done.
-- @param state table
local function do_variations_slim(state)
  refresh_context(state)  -- B2: refresh track context before variations
  if not track.is_valid(state.target_track) then
    reaper.ShowConsoleMsg("[Temper Vortex Mini] Variations: no valid track found — select a track or item first.\n")
    return
  end
  if #state.results == 0 then return end

  local n     = math.max(1, math.floor(tonumber(state.var_n_buf) or 1))
  local x_val = tonumber(state.var_x_buf) or 4.0
  if x_val <= 0 then x_val = 4.0 end

  local cursor_pos = reaper.GetCursorPosition()
  local ts_start, ts_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  local use_ts = ts_end > ts_start

  -- F7: when TS active, pin base_pos to ts_start (not cursor) and derive X from TS length.
  -- start_si=0 -> first slot lands AT ts_start. When no TS, start_si=1 -> cursor+x (original).
  local base_pos, start_si
  if use_ts then
    if state.var_unit == 0 then
      x_val = ts_end - ts_start
    else
      -- Use fullbeats (4th return) for linear beat-distance computation. B5 fix.
      local _, _, _, q_s = reaper.TimeMap2_timeToBeats(0, ts_start)
      local _, _, _, q_e = reaper.TimeMap2_timeToBeats(0, ts_end)
      x_val = q_e - q_s
    end
    if x_val <= 0 then x_val = 4.0 end
    -- RSG-125: do NOT overwrite var_x_buf with TS-derived spacing; preserve user's typed value.
    base_pos  = ts_start
    start_si  = 0   -- slot 0 = ts_start itself
    -- RSG-124: if an item already exists at ts_start, shift first slot forward to avoid overwrite.
    if import_mod.find_item_at_cursor(state.target_track, ts_start) then
      start_si = 1
    end
  else
    base_pos  = cursor_pos
    start_si  = 1   -- slot 1 = cursor+x (preserves original behaviour)
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  for i = 1, n do
    local si      = start_si + (i - 1)
    local pos     = _var_pos(base_pos, si,     x_val, state.var_unit)
    local next_p  = _var_pos(base_pos, si + 1, x_val, state.var_unit)
    local max_sec = next_p - pos

    -- Split any item straddling the slot start to clear space.
    local n_items = reaper.CountTrackMediaItems(state.target_track)
    for j = n_items - 1, 0, -1 do
      local it   = reaper.GetTrackMediaItem(state.target_track, j)
      local ipos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
      local ilen = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
      if ipos < pos and ipos + ilen > pos then
        local right = reaper.SplitMediaItem(it, pos)
        if right then reaper.DeleteTrackMediaItem(state.target_track, right) end
      end
    end

    local placed
    if state.mode == "lock" and state.lock_filepath then
      -- F3: LOCK mode honours locked file during Variations (cue-shift only, no re-roll).
      apply_random_cue_slim(state, pos, state.lock_filepath)
      placed = import_mod.find_item_at_cursor(state.target_track, pos)
    else
      -- FREE/UNIQUE: re-roll per slot for variety (UNIQUE avoids same-slot repeat).
      if state.mode == "unique" and #state.results > 1 then
        local prev, attempts = state.current_idx, 0
        repeat
          state.current_idx = state.results[math.random(1, #state.results)]
          attempts = attempts + 1
        until state.current_idx ~= prev or attempts >= 20
      else
        state.current_idx = state.results[math.random(1, #state.results)]
      end
      import_mod.import_file(state.target_track, state.index[state.current_idx].filepath, pos)
      placed = import_mod.find_item_at_cursor(state.target_track, pos)
    end
    if placed then
      import_mod.trim_item_to_max(placed, max_sec)
      if state.inherit_props and state.prop_snapshot then
        _pp_apply(state, placed)
      end
    end
  end

  -- Advance cursor and time selection to the slot after the last placed variation.
  local next_si = start_si + n
  local next_s  = _var_pos(base_pos, next_si,     x_val, state.var_unit)
  local next_e  = _var_pos(base_pos, next_si + 1, x_val, state.var_unit)
  reaper.PreventUIRefresh(-1)
  reaper.GetSet_LoopTimeRange(true, false, next_s, next_e, false)
  reaper.SetEditCurPos(next_s, true, false)
  reaper.UpdateArrange()
  reaper.Main_OnCommand(40047, 0)
  reaper.Undo_EndBlock("Temper Vortex Mini: Variations (" .. n .. ")", -1)
  if reaper.JS_Window_SetFocus then reaper.JS_Window_SetFocus(reaper.GetMainHwnd()) end
end

-- ============================================================
-- State machine
-- ============================================================

-- Detect launch context from selected item or last-touched track.
-- Sets state.target_track, target_guid, child_name, parent_name, prop_snapshot.
-- Returns true on success; false with state.error_msg set on failure.
-- @param state table
local function init_context(state)
  -- RSG-157: belt-and-suspenders -- prop_snapshot must always start nil at every init.
  state.prop_snapshot = nil
  local item_count = reaper.CountSelectedMediaItems(0)
  local target_track

  if item_count >= 1 then
    -- Use the first selected item as the roll target.
    local item       = reaper.GetSelectedMediaItem(0, 0)
    target_track     = reaper.GetMediaItem_Track(item)
    state.launch_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    -- RSG-139: do not auto-capture at launch; CAPTURE must default to grey (no snapshot).
    local guid          = reaper.GetTrackGUID(target_track)
    state.target_guid   = guid
    state.prop_snapshot = nil
  else
    -- Fallback: last touched track (no item → no property capture).
    target_track = reaper.GetLastTouchedTrack()
    if not track.is_valid(target_track) then
      state.status    = "error"
      state.error_msg = "Select an item or touch a track to begin."
      return false
    end
    state.launch_pos    = reaper.GetCursorPosition()
    state.target_guid   = reaper.GetTrackGUID(target_track)
    state.prop_snapshot = nil
  end

  state.target_track = target_track
  -- RSG-105: use P_NAME so REAPER's auto "Track N" labels are treated as blank.
  local _, slim_pname = reaper.GetSetMediaTrackInfo_String(target_track, "P_NAME", "", false)
  state.child_name   = (slim_pname ~= nil and slim_pname ~= "") and slim_pname or ""

  -- Auto-derive parent portion from the nearest folder ancestor (P_NAME only, not auto-label).
  -- Bug 2 fix: track.get_name returns "Track N" for unnamed folders, polluting search.
  local ancestor = track.find_folder_ancestor(target_track)
  if ancestor then
    local _, par_pname = reaper.GetSetMediaTrackInfo_String(ancestor, "P_NAME", "", false)
    state.parent_name  = (par_pname ~= nil and par_pname ~= "") and par_pname or ""
  else
    state.parent_name = ""
  end

  -- user_query stays empty; Trk flag uses child_name for implicit filtering.
  return true
end

-- Advance the state machine one tick (called every defer frame).
-- init → loading → searching → ready
-- @param state table
local function tick_state(state)
  if state.status == "init" then
    if not init_context(state) then return end
    state.file_lists = db.find_file_lists()
    if #state.file_lists == 0 then
      state.status    = "error"
      state.error_msg = "No MediaDB files found. Run Media Explorer scan first."
      return
    end
    local cached = db.load_cache(state.file_lists)
    if cached then
      state.index  = cached
      state.status = "searching"
      return
    end
    state.index    = {}
    state.load_idx = 1
    state.status   = "loading"

  elseif state.status == "loading" then
    -- Incremental load: one chunk of lines per tick so the UI stays responsive
    -- and the progress percentage visibly advances.
    if state.file_reader then
      local done = db.read_chunk(state.file_reader, state.index, 5000)
      if done then
        state.file_reader = nil
        state.load_idx    = state.load_idx + 1
      end
    else
      if state.load_idx > #state.file_lists then
        db.save_cache(state.file_lists, state.index)
        state.status = "searching"
        return
      end
      state.file_reader = db.open_reader(state.file_lists[state.load_idx])
      if not state.file_reader then
        state.load_idx = state.load_idx + 1  -- skip unreadable file
      end
    end

  elseif state.status == "searching" then
    search_slim(state)
    state.status = "ready"

  elseif state.status == "ready" then
    -- RSG-137: debounce search -- trigger only after 150ms of input idle.
    -- search_pending_ts is set by SEEK/OMIT text changes in render_gui.
    if state.search_pending_ts and (reaper.time_precise() - state.search_pending_ts) >= 0.15 then
      state.search_pending_ts = nil
      state.status = "searching"
      return
    end
    -- RSG-112 B7: follow track selection in real time so Trk filter stays current.
    -- When the user selects a different track in REAPER, update target_track and
    -- child_name immediately; if Trk is active and child_name changed, re-run search.
    local sel = reaper.GetSelectedTrack(0, 0)
    if sel and sel ~= state.target_track and track.is_valid(sel) then
      local old_child    = state.child_name
      state.target_track = sel
      state.target_guid  = reaper.GetTrackGUID(sel)
      local _, pname     = reaper.GetSetMediaTrackInfo_String(sel, "P_NAME", "", false)
      state.child_name   = (pname ~= nil and pname ~= "") and pname or ""
      if state.include_track and state.child_name ~= old_child then
        state.status = "searching"
      end
    end

  elseif state.status == "error" then
    -- RSG-132: auto-recover from "no track/item" error when context becomes available.
    -- MediaDB-missing errors require explicit Rescan and must not auto-retry.
    local no_track_msg = "Select an item or touch a track to begin."
    if state.error_msg == no_track_msg then
      local has_context = reaper.CountSelectedMediaItems(0) > 0
                       or track.is_valid(reaper.GetSelectedTrack(0, 0))
                       or track.is_valid(reaper.GetLastTouchedTrack())
      if has_context then
        state.status = "init"
      end
    end
  end
end

-- ============================================================
-- Spectral Core palette (RSG-118) -- constants for all GUI components.
-- Mirrors temper_theme.SC; defined here for direct access without indirection.
-- ============================================================
local SC = {
  WINDOW       = 0x0E0E10FF,  -- surface_container_lowest
  PANEL        = 0x1E1E20FF,  -- surface_container
  PANEL_HIGH   = 0x282828FF,  -- surface_container_high
  PANEL_TOP    = 0x323232FF,  -- surface_container_highest (inactive toggles)
  HOVER_LIST   = 0x39393BFF,  -- surface_bright
  PRIMARY      = 0x26A69AFF,
  PRIMARY_LT   = 0x66D9CCFF,  -- gradient highlight (ROLL button top)
  PRIMARY_HV   = 0x30B8ACFF,
  PRIMARY_AC   = 0x1A8A7EFF,
  TERTIARY     = 0xDA7C5AFF,  -- UNIQ mode coral
  TERTIARY_HV  = 0xE08A6AFF,
  TERTIARY_AC  = 0xC46A4AFF,
  TEXT_ON      = 0xDEDEDEFF,
  TEXT_MUTED   = 0xBCC9C6FF,
  OMIT_BG      = 0x380D00FF,  -- OMIT field orange-dark (board correction #9)
  OMIT_HV      = 0x4A1200FF,
  ERROR_RED    = 0xC0392BFF,
  DEL_BTN      = 0x282828FF,  -- PANEL_HIGH: neutral, palette-fit
  DEL_HV       = 0x39393BFF,  -- HOVER_LIST
  DEL_AC       = 0x1E1E20FF,  -- PANEL
}

-- ============================================================
-- GUI render helpers (RSG-118 North Star 5-row layout, 400x260px)
-- ============================================================

-- Footer status pill: context-sensitive text + color.
-- Footer status: result count with semantic color (North Star spec).
-- Transient states show load/search progress. Ready state shows count or zero.
local function _pill_content(state)
  if state.error_flash_msg and reaper.time_precise() < state.error_flash_until then
    return state.error_flash_msg, SC.ERROR_RED
  end
  if state.status == "loading" then
    local n      = math.max(1, #state.file_lists)
    local done_f = math.min(state.load_idx - 1, n)
    local within = (state.file_reader and state.file_reader.size > 0)
                   and (state.file_reader.pos / state.file_reader.size) or 0
    local pct    = math.floor((done_f + within) / n * 100)
    return string.format("LOADING %d%%", pct), SC.TEXT_MUTED
  elseif state.status == "searching" then
    -- Hold old results count during re-search so the display doesn't flash.
    -- Only show "SEARCHING" on the very first search (no results yet).
    if #state.results > 0 then
      return _format_count(#state.results) .. " results", SC.PRIMARY
    end
    return "SEARCHING", SC.TEXT_MUTED
  elseif state.status == "ready" then
    if #state.results == 0 then
      return "0 results", SC.ERROR_RED
    else
      return _format_count(#state.results) .. " results", SC.PRIMARY
    end
  else
    return "--", SC.TEXT_MUTED
  end
end

-- Forward declaration: render_settings_popup is defined later.
-- Lua resolves upvalues at call time, so render_title_bar can safely call it.
local render_settings_popup

-- Row 1: Custom title bar -- bold teal branding + gear icon right-aligned.
-- ============================================================
-- Actions framework handler module
-- ============================================================
--
-- Each entry mirrors one Vortex Mini button callback 1:1. The GUI buttons
-- and the rsg_actions keyboard dispatch both call through here so they
-- stay bit-identical (subset-of-GUI invariant).
--
-- IMPORTANT: This module MUST be declared before any render_* function that
-- references it. Lua resolves identifier scope at parse time, so a later
-- `local vortex_mini_actions` would make earlier references compile as
-- globals and crash at runtime (indexing nil global 'vortex_mini_actions').
local vortex_mini_actions = {}

local _VM_MODES = { "free", "unique", "lock" }

function vortex_mini_actions.do_roll(state)
  history_add(state.query_history, state.user_query, _HISTORY_KEY)
  state.hist_filtered = history_filter(state.query_history, state.user_query)
  history_add(state.omit_history, state.not_text, _OMIT_HISTORY_KEY)
  state.omit_filtered = history_filter(state.omit_history, state.not_text)
  do_roll_and_import_slim(state)
end

function vortex_mini_actions.do_variations(state)
  history_add(state.query_history, state.user_query, _HISTORY_KEY)
  state.hist_filtered = history_filter(state.query_history, state.user_query)
  history_add(state.omit_history, state.not_text, _OMIT_HISTORY_KEY)
  state.omit_filtered = history_filter(state.omit_history, state.not_text)
  do_variations_slim(state)
end

function vortex_mini_actions.do_capture(state)
  if reaper.CountSelectedMediaItems(0) <= 0 then return end
  local was_captured = state.prop_snapshot ~= nil
  local cap_item  = reaper.GetSelectedMediaItem(0, 0)
  local cap_track = reaper.GetMediaItem_Track(cap_item)
  local cap_guid  = reaper.GetTrackGUID(cap_track)
  state.prop_snapshot = _pp_capture_from_item(cap_item, cap_guid)
  if was_captured then state.cap_flash_until = reaper.time_precise() + 1.2 end
  local cap_take = reaper.GetActiveTake(cap_item)
  if cap_take then
    local src = reaper.GetMediaItemTake_Source(cap_take)
    local fp  = reaper.GetMediaSourceFileName(src, "")
    if fp and fp ~= "" then state.lock_filepath = fp end
  end
end

function vortex_mini_actions.cycle_mode(state)
  local cur_i = 1
  for ii, m in ipairs(_VM_MODES) do if m == state.mode then cur_i = ii; break end end
  local next_m = _VM_MODES[(cur_i % #_VM_MODES) + 1]
  -- F9: capture/clear lock_filepath on LOCK enter/exit.
  if next_m == "lock" then
    state.lock_filepath = state.last_rolled_filepath
                       or (state.current_idx and state.index[state.current_idx].filepath)
  elseif state.mode == "lock" then
    state.lock_filepath = nil
  end
  state.mode = next_m
end

function vortex_mini_actions.toggle_track_auto(state)
  state.include_track = not state.include_track
  state.status        = "searching"
end

function vortex_mini_actions.toggle_inh(state)
  state.inherit_props = not state.inherit_props
end

function vortex_mini_actions.toggle_time_unit(state)
  state.var_unit = 1 - state.var_unit
end


local function render_title_bar(ctx, state, lic, lic_status)
  local R     = reaper
  local w     = R.ImGui_GetWindowWidth(ctx)
  local btn_w = 22
  local font_b = temper_theme and temper_theme.font_bold
  if font_b then R.ImGui_PushFont(ctx, font_b, 13) end
  R.ImGui_SetCursorPosX(ctx, 8)  -- symmetric indent matching gear icon's 8px right inset
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.PRIMARY)
  R.ImGui_Text(ctx, "TEMPER - VORTEX MINI")
  R.ImGui_PopStyleColor(ctx, 1)
  if font_b then R.ImGui_PopFont(ctx) end
  R.ImGui_SameLine(ctx)
  R.ImGui_SetCursorPosX(ctx, w - btn_w - 8)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        SC.PANEL)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), SC.HOVER_LIST)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  0x141416FF)
  if R.ImGui_Button(ctx, "\xe2\x9a\x99##settings_slim", btn_w, 0) then
    R.ImGui_OpenPopup(ctx, "##settings_popup_slim")
  end
  R.ImGui_PopStyleColor(ctx, 3)
  if R.ImGui_IsItemHovered(ctx) then R.ImGui_SetTooltip(ctx, "Settings") end
  render_settings_popup(ctx, state, lic, lic_status)
end

-- Custom pill-shaped toggle switch (RSG-137 North Star spec: iOS-style on/off).
-- Draws pill track + sliding circle thumb using DrawList; InvisibleButton for clicks.
-- ON:  thumb right, teal pill, teal label. OFF: thumb left, dark pill, muted label.
-- Returns true if clicked this frame.
-- Row 5: Footer -- TRACK | INHERIT | CAPTURE | status count.
-- All items are toggle buttons. Alignment via SetCursorScreenPos + absolute X tracking.
local function render_footer_row(ctx, state)
  local R      = reaper
  local font_b = temper_theme and temper_theme.font_bold
  local btn_h  = R.ImGui_GetFrameHeight(ctx)
  local font_sz   = R.ImGui_GetFontSize(ctx)
  local text_off  = math.floor((btn_h - font_sz) * 0.5)

  -- Single Y anchor. All items share this baseline.
  local anchor_x, anchor_y = R.ImGui_GetCursorScreenPos(ctx)
  local cur_x = anchor_x

  -- TRACK toggle button (on=teal, bold 13px, dark text; off=grey, regular font, light text)
  R.ImGui_SetCursorScreenPos(ctx, cur_x, anchor_y)
  local trk_on = state.include_track
  local trk_bg  = trk_on and SC.PANEL_TOP   or SC.PANEL
  local trk_hv  = trk_on and SC.HOVER_LIST  or 0x2A2A2CFF
  local trk_ac  = trk_on and 0x141416FF     or 0x161618FF
  local trk_txt = trk_on and SC.PRIMARY       or 0x505050FF
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        trk_bg)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), trk_hv)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  trk_ac)
  local n_trk_col = 3
  if trk_txt then R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), trk_txt); n_trk_col = 4 end
  if R.ImGui_Button(ctx, "TRACK##trk", 0, btn_h) then
    vortex_mini_actions.toggle_track_auto(state)
    if reaper.JS_Window_SetFocus then reaper.JS_Window_SetFocus(reaper.GetMainHwnd()) end
  end
  R.ImGui_PopStyleColor(ctx, n_trk_col)
  if R.ImGui_IsItemHovered(ctx) then
    R.ImGui_SetTooltip(ctx, "Include auto-detected track name in search query")
  end
  cur_x = select(1, R.ImGui_GetItemRectMax(ctx)) + 6

  -- INHERIT toggle button (on=grey visible, off=receded into background -- same pattern as TRACK)
  R.ImGui_SetCursorScreenPos(ctx, cur_x, anchor_y)
  local inh_on  = state.inherit_props
  local inh_bg  = inh_on and SC.PANEL_TOP   or SC.PANEL
  local inh_hv  = inh_on and SC.HOVER_LIST  or 0x2A2A2CFF
  local inh_ac  = inh_on and 0x141416FF     or 0x161618FF
  local inh_txt = inh_on and SC.PRIMARY       or 0x505050FF
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        inh_bg)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), inh_hv)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  inh_ac)
  local n_inh_col = 3
  if inh_txt then R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), inh_txt); n_inh_col = 4 end
  if R.ImGui_Button(ctx, "INHERIT##inh", 0, btn_h) then
    vortex_mini_actions.toggle_inh(state)
    if reaper.JS_Window_SetFocus then reaper.JS_Window_SetFocus(reaper.GetMainHwnd()) end
  end
  R.ImGui_PopStyleColor(ctx, n_inh_col)
  if R.ImGui_IsItemHovered(ctx) then
    R.ImGui_SetTooltip(ctx, "Inherit item properties (pitch, rate, fades) from captured snapshot")
  end
  cur_x = select(1, R.ImGui_GetItemRectMax(ctx)) + 6

  -- CAPTURE button (camera icon, fixed square width -- no layout shift on state change)
  R.ImGui_SetCursorScreenPos(ctx, cur_x, anchor_y)
  local n_cap    = reaper.CountSelectedMediaItems(0)
  local has_snap = state.prop_snapshot ~= nil
  local cap_bg   = has_snap and SC.TERTIARY    or SC.PANEL
  local cap_hv   = has_snap and SC.TERTIARY_HV or 0x2A2A2CFF
  local cap_ac   = has_snap and SC.TERTIARY_AC or 0x161618FF
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        cap_bg)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), cap_hv)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  cap_ac)
  if R.ImGui_Button(ctx, "##cap", btn_h, btn_h) then
    vortex_mini_actions.do_capture(state)
    if reaper.JS_Window_SetFocus then reaper.JS_Window_SetFocus(reaper.GetMainHwnd()) end
  end
  -- Camera icon: body outline + shutter bump + lens circle
  do
    local dl_cam     = R.ImGui_GetWindowDrawList(ctx)
    local cbx, cby   = R.ImGui_GetItemRectMin(ctx)
    local cbmx, cbmy = R.ImGui_GetItemRectMax(ctx)
    local cx  = math.floor((cbx + cbmx) * 0.5)
    local cy  = math.floor((cby + cbmy) * 0.5)
    local col = has_snap and SC.WINDOW or 0x505050FF
    R.ImGui_DrawList_AddRect(dl_cam,      cx-8, cy-3, cx+8, cy+6, col, 2.0, 0, 1.5)  -- body
    R.ImGui_DrawList_AddRectFilled(dl_cam, cx-3, cy-7, cx+4, cy-3, col, 1.5)           -- shutter bump
    R.ImGui_DrawList_AddCircle(dl_cam,    cx,   cy+2,  4,   col,   0,  1.5)            -- lens
  end
  -- Capture right edge BEFORE style pops
  cur_x = select(1, R.ImGui_GetItemRectMax(ctx)) + 6
  R.ImGui_PopStyleColor(ctx, 3)
  if reaper.time_precise() < state.cap_flash_until then
    R.ImGui_BeginTooltip(ctx)
    R.ImGui_Text(ctx, "Re-captured.")
    R.ImGui_EndTooltip(ctx)
  elseif R.ImGui_IsItemHovered(ctx) then
    local tip = n_cap == 0
      and "Select an item first to capture properties.\nPlayrate applies to LOCK mode only."
      or (has_snap
        and "Properties captured. Click to recapture.\nPlayrate applies to LOCK mode only."
        or "Snapshot properties + source file from selected item.\nPlayrate applies to LOCK mode only.")
    R.ImGui_SetTooltip(ctx, tip)
  end

  -- RESULTS text (right-aligned, vertically centered on anchor_y)
  local pill_txt, pill_col = _pill_content(state)
  local txt_w  = R.ImGui_CalcTextSize(ctx, pill_txt)
  local win_x  = select(1, R.ImGui_GetWindowPos(ctx))
  local res_x  = win_x + 400 - txt_w - 8  -- 8px from right inner edge (WindowPadding)
  R.ImGui_SetCursorScreenPos(ctx, res_x, anchor_y + text_off)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), pill_col)
  R.ImGui_Text(ctx, pill_txt)
  R.ImGui_PopStyleColor(ctx, 1)
  if state.current_idx and state.index[state.current_idx] and R.ImGui_IsItemHovered(ctx) then
    local fp = state.index[state.current_idx].filepath
    R.ImGui_SetTooltip(ctx, fp)
    if R.ImGui_IsItemClicked(ctx, 1) then R.ImGui_SetClipboardText(ctx, fp) end
  end
end


-- ============================================================
-- GUI render — main frame
-- ============================================================

-- RSG-115: Settings popup -- Rescan + Activate (trial only).
-- Assigned to forward-declared local so render_title_bar can call it.
render_settings_popup = function(ctx, state, lic, lic_status)
  local R = reaper
  if not R.ImGui_BeginPopup(ctx, "##settings_popup_slim") then return end

  -- Header
  R.ImGui_TextDisabled(ctx, "Settings")
  R.ImGui_Separator(ctx)
  R.ImGui_Spacing(ctx)

  -- CLOSE: terminates the script via defer loop exit flag (RSG-118 board amendment)
  if R.ImGui_Button(ctx, "Close##settings_slim_close") then
    state.should_close = true
    R.ImGui_CloseCurrentPopup(ctx)
  end

  -- ACTIVATE (trial only)
  if lic_status == "trial" and lic then
    R.ImGui_Spacing(ctx)
    R.ImGui_Separator(ctx)
    R.ImGui_Spacing(ctx)
    if R.ImGui_Button(ctx, "Activate\xE2\x80\xA6##settings_slim_lic") then
      lic.open_dialog(ctx)
      R.ImGui_CloseCurrentPopup(ctx)
    end
  end

  -- RESCAN
  R.ImGui_Spacing(ctx)
  R.ImGui_Separator(ctx)
  R.ImGui_Spacing(ctx)
  if R.ImGui_Button(ctx, "Rescan##settings_slim") then
    state.index       = {}
    state.load_idx    = 1
    state.file_reader = nil
    state.status      = "loading"
    db.save_cache({}, {})  -- invalidate disk cache
    state.file_lists = db.find_file_lists()
    if reaper.JS_Window_SetFocus then reaper.JS_Window_SetFocus(reaper.GetMainHwnd()) end
    R.ImGui_CloseCurrentPopup(ctx)
  end
  if R.ImGui_IsItemHovered(ctx) then
    R.ImGui_SetTooltip(ctx,
      "Re-scan REAPER's MediaDB from disk, bypassing the cache.\n" ..
      "Use after adding new files to your library.")
  end

  R.ImGui_EndPopup(ctx)
end

-- Render the main Vortex Mini GUI (RSG-137 layout: 400x260px, 2-column main area).
-- Row 1: Title bar | Row 2: Query (50/50) | Main: ROLL left + [mode+VARIATIONS] right | Row 5: Footer
-- RSG-137 board corrections: no separate mode row; mode cycle + var params live in right
-- column top; ROLL occupies full left column height parallel to both.
-- @param ctx        ImGuiContext*
-- @param state      table
-- @param lic        license module (may be nil)
-- @param lic_status "licensed" | "trial" | "expired" | nil
local function render_gui(ctx, state, lic, lic_status)
  local R      = reaper
  local font_b = temper_theme and temper_theme.font_bold  -- RSG-158: consistent bold coverage
  -- Dropdown anchor data: set during seek/omit row, consumed at end of render_gui
  -- so dropdowns are drawn last (on top of all content, no layout shift).
  local _dd_q_x, _dd_q_y, _dd_om_x, _dd_om_y, _dd_seek_w, _dd_omit_w

  -- Row 1: Title bar -- distinct bg #1A1A1C painted via DrawList before content (P6).
  -- No BeginChild: avoids the ~20px vertical overhead that caused the overflow scrollbar.
  -- Background rect covers full window width (including WindowPadding) from top down.
  local title_w      = select(1, R.ImGui_GetContentRegionAvail(ctx))
  local dl_tb        = R.ImGui_GetWindowDrawList(ctx)
  local win_x, win_y = R.ImGui_GetWindowPos(ctx)
  local tbx, tby     = R.ImGui_GetCursorScreenPos(ctx)
  R.ImGui_DrawList_AddRectFilled(dl_tb, win_x, win_y, win_x + 400, tby + 24, 0x1A1A1CFF)
  render_title_bar(ctx, state, lic, lic_status)
  -- RSG-159: exact 8px visual gap below title bar (cursor has 4px ItemSpacing from title bar, +4 = 8px).
  -- Dummy(0,6) was producing 14px visual gap (4 ItemSpacing baked in + 6 Dummy + 4 ItemSpacing after).
  R.ImGui_SetCursorPosY(ctx, R.ImGui_GetCursorPosY(ctx) + 4)

  -- Row 2: Query -- Seek + Omit at 50/50 width (RSG-137 correction #1).
  local content_w = select(1, R.ImGui_GetContentRegionAvail(ctx))
  local _GAP      = 8
  local _SEEK_W   = math.floor((content_w - _GAP) * 0.5)
  local _OMIT_W   = content_w - _SEEK_W - _GAP
  local _ITEM_H   = 20
  local _MAX_DD   = 5
  _dd_seek_w = _SEEK_W
  _dd_omit_w = _OMIT_W

  -- RSG-151: FramePadding y=4 -- slightly shorter inputs give symmetric padding above/below.
  R.ImGui_PushStyleVar(ctx, R.ImGui_StyleVar_FramePadding(), 4, 4)
  local q_drop_x, q_drop_y = R.ImGui_GetCursorScreenPos(ctx)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_FrameBg(),      SC.WINDOW)    -- match N/spacing field bg (North Star P3)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_TextDisabled(), SC.PANEL_TOP) -- placeholder "Seek..." color
  R.ImGui_SetNextItemWidth(ctx, _SEEK_W)
  if font_b then R.ImGui_PushFont(ctx, font_b, 13) end
  local _, new_q = R.ImGui_InputTextWithHint(ctx, "##query", "Seek...", state.user_query)
  if font_b then R.ImGui_PopFont(ctx) end
  R.ImGui_PopStyleColor(ctx, 2)
  local q_item_h = select(2, R.ImGui_GetItemRectSize(ctx))
  _dd_q_x = q_drop_x
  _dd_q_y = q_drop_y + q_item_h
  local hist_was_active   = state.hist_input_active
  state.hist_input_active = R.ImGui_IsItemActive(ctx)
  if state.hist_input_active and not hist_was_active then state.hist_open = true end
  if R.ImGui_IsKeyPressed(ctx, R.ImGui_Key_Escape()) and state.hist_open then
    state.hist_open = false
  end
  local q_changed = new_q ~= state.user_query
  if q_changed then
    state.user_query        = new_q
    -- RSG-137 correction #5: debounce -- do NOT set status="searching" immediately.
    -- tick_state fires the search after 150ms of idle (search_pending_ts check).
    state.search_pending_ts = reaper.time_precise()
    state.hist_filtered     = history_filter(state.query_history, new_q)
    state.hist_open         = true
  end
  if state.hist_input_active and R.ImGui_IsKeyPressed(ctx, R.ImGui_Key_Enter()) then
    history_add(state.query_history, state.user_query, _HISTORY_KEY)
    state.hist_filtered = history_filter(state.query_history, state.user_query)
    state.hist_open     = false
  end

  R.ImGui_SameLine(ctx, 0, _GAP)
  local omit_drop_x, omit_drop_y = R.ImGui_GetCursorScreenPos(ctx)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_FrameBg(),        SC.WINDOW)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_FrameBgHovered(), SC.HOVER_LIST)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_TextDisabled(),   SC.PANEL_TOP)
  R.ImGui_SetNextItemWidth(ctx, _OMIT_W)
  if font_b then R.ImGui_PushFont(ctx, font_b, 13) end
  local _, new_not = R.ImGui_InputTextWithHint(ctx, "##not", "Omit...", state.not_text)
  if font_b then R.ImGui_PopFont(ctx) end
  R.ImGui_PopStyleColor(ctx, 3)
  local omit_item_h = select(2, R.ImGui_GetItemRectSize(ctx))
  _dd_om_x = omit_drop_x
  _dd_om_y = omit_drop_y + omit_item_h
  R.ImGui_PopStyleVar(ctx, 1)  -- FramePadding for query row
  local omit_was_active   = state.omit_input_active
  state.omit_input_active = R.ImGui_IsItemActive(ctx)
  if state.omit_input_active and not omit_was_active then state.omit_open = true end
  if R.ImGui_IsKeyPressed(ctx, R.ImGui_Key_Escape()) and state.omit_open then
    state.omit_open = false
  end
  local not_changed = new_not ~= state.not_text
  if not_changed then
    state.not_text          = new_not
    -- RSG-137 correction #5: debounce for omit field too.
    state.search_pending_ts = reaper.time_precise()
    state.omit_filtered     = history_filter(state.omit_history, new_not)
    state.omit_open         = true
  end
  if state.omit_input_active and R.ImGui_IsKeyPressed(ctx, R.ImGui_Key_Enter()) then
    history_add(state.omit_history, state.not_text, _OMIT_HISTORY_KEY)
    state.omit_filtered = history_filter(state.omit_history, state.not_text)
    state.omit_open     = false
  end

  -- ----------------------------------------------------------------
  -- Main two-column area (RSG-137 correction #2):
  -- LEFT:  ROLL hero panel (full height).
  -- RIGHT: top = mode cycle + N + spacing + SEC/BEATS (compact row).
  --        bot = VARIATIONS (full right-column width, remaining height).
  -- No separate "Mode row" -- mode controls live inside right column.
  -- ----------------------------------------------------------------
  -- RSG-159: exact 8px visual gap from SEEK/OMIT bottom to two-column top.
  -- Dummy(0,6) was 14px visual gap (4 ItemSpacing baked in + 6 Dummy + 4 ItemSpacing after = 14px).
  -- SetCursorPosY +4 gives 4 (ItemSpacing already in cursor) + 4 = 8px, fixing footer cutoff too.
  R.ImGui_SetCursorPosY(ctx, R.ImGui_GetCursorPosY(ctx) + 4)

  -- Allow "searching" through is_ready when old results exist: prevents the one-frame
  -- flicker where the debounce fires, status becomes "searching" for one render tick,
  -- and both buttons go grey before the search completes and status returns to "ready".
  local is_ready = (state.status == "ready" or state.status == "searching")
                   and track.is_valid(state.target_track or false)
                   and #state.results > 0

  local function _disabled_reason()
    if state.status ~= "ready" and state.status ~= "searching" then return "Loading or searching..." end
    if not track.is_valid(state.target_track or false) then
      return "Select an item or track first"
    end
    if #state.results == 0 then return "No results for current query" end
    return nil
  end

  local avail_w  = select(1, R.ImGui_GetContentRegionAvail(ctx))
  -- North Star P1: flex-[1.2] : flex-[1] ratio => ~54.5% ROLL : ~45.5% right (8px gap).
  local roll_w   = math.floor((avail_w - 8) * 1.2 / 2.2)
  local right_w  = avail_w - roll_w - 8
  -- North Star P2: 4 equal columns in mode row: [FREE][N field][spacing][SEC/BEATS], each col_w wide.
  local col_w    = math.floor((right_w - 3 * 4) / 4)
  local last_col_w = right_w - 3 * col_w - 3 * 4  -- absorbs rounding remainder so SEC/BTS is flush-right
  local main_h   = 157                           -- two-column block height (fills to 8px gap above footer)
  local sep_h    = 8                             -- exact gap between mode row and VARIATIONS (set via SetCursorScreenPos)
  local font_h   = temper_theme and temper_theme.font_hero  -- Arial Black 18px (correction #5)

  -- LEFT COLUMN: ROLL (full height, teal gradient + circle logo mark)
  if R.ImGui_BeginChild(ctx, "##roll_col", roll_w, main_h, 0) then
    local roll_bx, roll_by = R.ImGui_GetCursorScreenPos(ctx)
    local btn_h = main_h
    if is_ready then
      local dl = R.ImGui_GetWindowDrawList(ctx)
      R.ImGui_DrawList_AddRectFilled(dl, roll_bx, roll_by, roll_bx + roll_w, roll_by + btn_h,
        SC.PRIMARY, 4)
      R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        0x00000000)
      R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), 0xFFFFFF1A)
      R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  0x0000001F)
    else
      R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        SC.PANEL)
      R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), SC.PANEL_HIGH)
      R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  SC.PANEL)
    end
    if not is_ready then R.ImGui_BeginDisabled(ctx) end
    -- Label "##roll" (empty): icon + ROLL text drawn via DrawList for precise centering (correction #2).
    if R.ImGui_Button(ctx, "##roll", roll_w, btn_h) then
      vortex_mini_actions.do_roll(state)
    end
    if not is_ready then
      local hf = R.ImGui_HoveredFlags_AllowWhenDisabled and R.ImGui_HoveredFlags_AllowWhenDisabled() or 0
      if R.ImGui_IsItemHovered(ctx, hf) then
        local reason = _disabled_reason()
        if reason then R.ImGui_SetTooltip(ctx, reason) end
      end
      R.ImGui_EndDisabled(ctx)
    end
    R.ImGui_PopStyleColor(ctx, 3)
    -- Border via DrawList (avoids FrameBorderSize corner triangle artifacts on transparent button bg)
    local dl_roll = R.ImGui_GetWindowDrawList(ctx)
    R.ImGui_DrawList_AddRect(dl_roll, roll_bx, roll_by, roll_bx + roll_w, roll_by + btn_h, 0x50505066, 4, 0, 1.0)

    -- ROLL dice icon + "ROLL" text: drawn via DrawList for precise centering.
    -- Icon center at 34% of button height. Text top = icon_bottom + 8px gap.
    local dl   = R.ImGui_GetWindowDrawList(ctx)
    local rx   = roll_bx + roll_w * 0.5
    local ry   = roll_by + btn_h * 0.34  -- icon center Y (raised, clears gap above ROLL text)
    local hw   = 13  -- die half-width (same footprint as old circle)
    local ccol = is_ready and SC.WINDOW or 0x606060FF
    -- Body: rounded square outline
    R.ImGui_DrawList_AddRect(dl, rx - hw, ry - hw, rx + hw, ry + hw, ccol, 4.0, 0, 2.0)
    -- Three diagonal dots: top-left, centre, bottom-right (outlines only)
    local dr  = 2.5
    local off = hw * 0.42
    R.ImGui_DrawList_AddCircle(dl, rx - off, ry - off, dr, ccol, 0, 1.5)
    R.ImGui_DrawList_AddCircle(dl, rx,       ry,       dr, ccol, 0, 1.5)
    R.ImGui_DrawList_AddCircle(dl, rx + off, ry + off, dr, ccol, 0, 1.5)
    -- "ROLL" text: SetCursorScreenPos + ImGui_Text so PushFont applies reliably.
    if font_h then R.ImGui_PushFont(ctx, font_h, 18) end
    local rtw = R.ImGui_CalcTextSize(ctx, "ROLL")
    R.ImGui_SetCursorScreenPos(ctx, roll_bx + (roll_w - rtw) * 0.5, ry + hw + 8)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), is_ready and SC.WINDOW or 0x606060FF)
    R.ImGui_Text(ctx, "ROLL")
    R.ImGui_PopStyleColor(ctx, 1)
    if font_h then R.ImGui_PopFont(ctx) end

    R.ImGui_EndChild(ctx)
  end

  R.ImGui_SameLine(ctx, 0, 8)

  -- RIGHT COLUMN: mode controls (top) + VARIATIONS (bottom)
  -- NoScrollbar prevents overflow scrollbar from appearing.
  -- ChildBg=SC.PANEL so dead space matches outer window bg (RSG-154: not SC.WINDOW which was too dark).
  local right_flags = reaper.ImGui_WindowFlags_NoScrollbar()
  R.ImGui_PushStyleVar(ctx, R.ImGui_StyleVar_WindowPadding(), 0, 0)  -- RSG-142: no padding strips in right col
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ChildBg(), SC.PANEL)
  if R.ImGui_BeginChild(ctx, "##right_col", right_w, main_h, 0, right_flags) then

    -- TOP: mode cycle button + N input + spacing input + SEC/BEATS toggle
    -- RSG-137 correction #3: single cycle toggle FREE->UNIQ->LOCK->FREE.
    local MODES       = { "free", "unique", "lock" }
    local MODE_LABELS = { free = "FREE", unique = "UNIQ", lock = " " }
    local MODE_DESCS  = {
      free   = "FREE: Pick a random file each Roll",
      unique = "UNIQ: Avoid repeating the same file",
      lock   = "LOCK: Stick to one source file (shift WAV cue)",
    }
    -- FramePadding y=7 + FrameBorderSize=1 for all 4 items: consistent height across buttons + inputs.
    -- Buttons use invisible border (border = button bg). Inputs use visible border (0x505055FF).
    R.ImGui_PushStyleVar(ctx, R.ImGui_StyleVar_FramePadding(), 4, 7)
    R.ImGui_PushStyleVar(ctx, R.ImGui_StyleVar_FrameBorderSize(), 1.0)
    local mode_start_sx, mode_start_sy = R.ImGui_GetCursorScreenPos(ctx)  -- screen coords before mode row
    local mode_h = R.ImGui_GetFrameHeight(ctx)  -- dynamic: FontSize + 2*FramePadding.y
    -- RSG-155: bright bg states (UNIQ teal, LOCK coral) need near-black text to remain readable.
    local MODE_COL = {
      free   = { SC.PANEL_TOP, SC.HOVER_LIST,  0x141416FF,    SC.PRIMARY },  -- grey bg, teal text
      unique = { SC.PRIMARY,   SC.PRIMARY_HV,  SC.PRIMARY_AC, SC.WINDOW },  -- teal, dark text
      lock   = { SC.TERTIARY,  SC.TERTIARY_HV, SC.TERTIARY_AC, SC.WINDOW},  -- coral, dark text
    }
    local mc    = MODE_COL[state.mode]
    local n_mc  = mc[4] and 4 or 3
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        mc[1])
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), mc[2])
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  mc[3])
    if mc[4] then R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), mc[4]) end
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(), mc[1])  -- border = button bg = invisible
    if R.ImGui_Button(ctx, MODE_LABELS[state.mode] .. "##mc", col_w, mode_h) then  -- North Star P2: col_w (equal 4-column grid)
      vortex_mini_actions.cycle_mode(state)
      if reaper.JS_Window_SetFocus then reaper.JS_Window_SetFocus(reaper.GetMainHwnd()) end
    end
    -- Draw padlock icon overlay when in LOCK mode
    if state.mode == "lock" then
      local dl_lk  = R.ImGui_GetWindowDrawList(ctx)
      local ibx, iby   = R.ImGui_GetItemRectMin(ctx)
      local ibmx, ibmy = R.ImGui_GetItemRectMax(ctx)
      local lk_cx = math.floor((ibx + ibmx) * 0.5)
      local lk_cy = math.floor((iby + ibmy) * 0.5)
      local bw2 = 6   -- body half-width
      local bh  = 9   -- body height
      local sr  = 4   -- shackle arch radius
      local bt  = lk_cy - 2  -- body top (centers full icon: arch sr=4 + body bh=9)
      -- Shackle: circle outline; body rect covers lower half, leaving only the arch visible
      R.ImGui_DrawList_AddCircle(dl_lk, lk_cx, bt, sr, SC.WINDOW, 0, 2.0)
      R.ImGui_DrawList_AddRectFilled(dl_lk, lk_cx - bw2, bt, lk_cx + bw2, bt + bh, SC.WINDOW, 1.0)
    end
    R.ImGui_PopStyleColor(ctx, n_mc + 1)  -- mc colors + Border
    if R.ImGui_IsItemHovered(ctx) then
      R.ImGui_SetTooltip(ctx, MODE_DESCS[state.mode])
    end

    -- North Star P2: N field with hint "N" (no standalone label), col_w width, 4px gap.
    R.ImGui_SameLine(ctx, 0, 4)
    -- Styled input fields: window-bg fill + teal text + thin border + col_w width (P2).
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_FrameBg(),        SC.WINDOW)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_FrameBgHovered(), 0x1E1E20FF)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(),         0x505055FF)  -- visible border (overrides row-level invisible border)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),           SC.PRIMARY)
    local n_disp_w = R.ImGui_CalcTextSize(ctx, state.var_n_buf ~= "" and state.var_n_buf or "N")
    local n_pad_x  = math.max(4, math.floor((col_w - n_disp_w) * 0.5))
    R.ImGui_PushStyleVar(ctx, R.ImGui_StyleVar_FramePadding(), n_pad_x, 7)
    R.ImGui_SetNextItemWidth(ctx, col_w)
    local _, new_n = R.ImGui_InputTextWithHint(ctx, "##varn", "N", state.var_n_buf, 8)
    R.ImGui_PopStyleVar(ctx)
    state.var_n_buf = new_n

    R.ImGui_SameLine(ctx, 0, 4)
    local x_disp_w = R.ImGui_CalcTextSize(ctx, state.var_x_buf ~= "" and state.var_x_buf or "0.0")
    local x_pad_x  = math.max(4, math.floor((col_w - x_disp_w) * 0.5))
    R.ImGui_PushStyleVar(ctx, R.ImGui_StyleVar_FramePadding(), x_pad_x, 7)
    R.ImGui_SetNextItemWidth(ctx, col_w)
    local x_changed, new_x = R.ImGui_InputText(ctx, "##varx", state.var_x_buf, 12)
    if R.ImGui_IsItemDeactivatedAfterEdit(ctx) then
      local parsed = tonumber(new_x)
      state.var_x_buf = parsed and string.format("%.1f", math.max(0, parsed)) or new_x
    elseif x_changed then
      state.var_x_buf = new_x
    end
    R.ImGui_PopStyleVar(ctx)
    R.ImGui_PopStyleColor(ctx, 4)  -- FrameBg + FrameBgHovered + Border + Text

    -- SEC/BEATS: 4th column, col_w width (North Star P2 equal grid, no right-anchor needed).
    R.ImGui_SameLine(ctx, 0, 4)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        SC.PANEL_TOP)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), SC.HOVER_LIST)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  0x141416FF)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(),        SC.PANEL_TOP)  -- border = button bg = invisible
    if R.ImGui_Button(ctx, " ##vu", last_col_w, mode_h) then
      vortex_mini_actions.toggle_time_unit(state)
      if reaper.JS_Window_SetFocus then reaper.JS_Window_SetFocus(reaper.GetMainHwnd()) end
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
        -- Clock icon for SEC: circle face + hour hand (up) + minute hand (right)
        local cr = 7
        R.ImGui_DrawList_AddCircle(dl_vu, vu_cx, vu_cy, cr, icol, 0, 1.5)
        -- hour hand: short, pointing toward ~12 (up)
        R.ImGui_DrawList_AddRectFilled(dl_vu, vu_cx - 1, vu_cy - cr + 2, vu_cx + 1, vu_cy, icol, 0)
        -- minute hand: longer, pointing toward ~3 (right)
        R.ImGui_DrawList_AddRectFilled(dl_vu, vu_cx, vu_cy - 1, vu_cx + cr - 1, vu_cy + 1, icol, 0)
      else
        -- Musical note icon for BEATS: filled oval head + vertical stem
        local nr = 4   -- note head radius
        local sx = vu_cx + 2  -- stem x (right edge of head)
        R.ImGui_DrawList_AddCircleFilled(dl_vu, vu_cx - 1, vu_cy + 3, nr, icol)
        R.ImGui_DrawList_AddRectFilled(dl_vu, sx, vu_cy - 6, sx + 2, vu_cy + 4, icol, 0)
        -- flag at top of stem
        R.ImGui_DrawList_AddRectFilled(dl_vu, sx, vu_cy - 6, sx + 6, vu_cy - 4, icol, 0)
      end
    end
    -- tooltip
    if R.ImGui_IsItemHovered(ctx) then
      local tt = state.var_unit == 0 and "Spacing in seconds" or "Spacing in beats (follows tempo map)"
      R.ImGui_SetTooltip(ctx, tt)
    end
    R.ImGui_PopStyleColor(ctx, 4)  -- Button + ButtonHovered + ButtonActive + Border
    R.ImGui_PopStyleVar(ctx, 2)  -- FramePadding + FrameBorderSize

    -- Reset both X and Y so VARIATIONS is flush-left and exactly sep_h below mode row.
    -- SetCursorPosY alone leaves cursor X after SEC, causing an unwanted wrap + extra spacing.
    R.ImGui_SetCursorScreenPos(ctx, mode_start_sx, mode_start_sy + mode_h + sep_h)

    -- BOTTOM: VARIATIONS button (full right-column width, exact remaining height).
    -- vars_h from GetContentRegionAvail ensures no pixel gap at bottom of ##right_col.
    local vars_h = select(2, R.ImGui_GetContentRegionAvail(ctx))
    local var_bx, var_by = R.ImGui_GetCursorScreenPos(ctx)  -- capture before button for P5 icon
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        SC.PANEL_TOP)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), SC.HOVER_LIST)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  SC.PANEL_HIGH)
    if not is_ready then R.ImGui_BeginDisabled(ctx) end
    if font_b then R.ImGui_PushFont(ctx, font_b, 13) end
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), SC.PRIMARY)
    if R.ImGui_Button(ctx, "VARIATIONS##vars", right_w, vars_h) then
      vortex_mini_actions.do_variations(state)
    end
    R.ImGui_PopStyleColor(ctx, 1)  -- Col_Text
    if font_b then R.ImGui_PopFont(ctx) end
    if not is_ready then
      local hf = R.ImGui_HoveredFlags_AllowWhenDisabled and R.ImGui_HoveredFlags_AllowWhenDisabled() or 0
      if R.ImGui_IsItemHovered(ctx, hf) then
        local reason = _disabled_reason()
        if reason then R.ImGui_SetTooltip(ctx, reason) end
      end
      R.ImGui_EndDisabled(ctx)
    end
    R.ImGui_PopStyleColor(ctx, 3)

    -- North Star P5: 3-stripe layers icon above VARIATIONS label, centered in button.
    local dl_var  = R.ImGui_GetWindowDrawList(ctx)
    local ialp    = is_ready and 0xFF or 0x44
    local vx      = var_bx + right_w * 0.5
    local vy      = var_by + vars_h * 0.28  -- icon center Y (upper third, above text)
    local hw      = 9                        -- half-width of each stripe
    local lcol    = (is_ready and 0x26A69A00 or 0x60606000) | ialp
    for k = 0, 2 do
      local sy_k = vy + (k - 1) * 6 - 1.5  -- 3 stripes spaced 6px apart
      R.ImGui_DrawList_AddRectFilled(dl_var, vx - hw, sy_k, vx + hw, sy_k + 3, lcol, 1.0)
    end

    R.ImGui_EndChild(ctx)
  end
  R.ImGui_PopStyleVar(ctx, 1)    -- WindowPadding 0 for ##right_col (RSG-142)
  R.ImGui_PopStyleColor(ctx, 1)  -- ChildBg SC.WINDOW for ##right_col

  -- Row 5: Footer anchored to content region bottom.
  -- GetContentRegionMax returns window-relative Y of content bottom (= WindowHeight - WindowPadding.y = 252).
  -- SetCursorPosY(content_bottom - btn_h) lands footer bottom exactly at content bottom;
  -- WindowPadding.y=8 below provides the visible 8px bottom gap matching left/right wall padding.
  local btn_h          = R.ImGui_GetFrameHeight(ctx)
  local content_bottom = 252  -- window=260, NoTitleBar, WindowPadding.y=8: content bottom = 260-8 = 252 (window-relative)
  R.ImGui_SetCursorPosY(ctx, content_bottom - btn_h)
  render_footer_row(ctx, state)

  -- History dropdowns: rendered last so they overlay all content with correct z-order.
  -- Anchor positions (_dd_*) captured during seek/omit row above.
  local _DD_ITEM_H = 20
  local _DD_MAX    = 5
  if state.hist_open and #state.hist_filtered > 0 then
    local DD_H = math.min(#state.hist_filtered, _DD_MAX) * _DD_ITEM_H + 4
    R.ImGui_SetCursorScreenPos(ctx, _dd_q_x, _dd_q_y)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ChildBg(),       SC.PANEL)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_HeaderHovered(), SC.TERTIARY)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_HeaderActive(),  SC.TERTIARY_AC)
    if R.ImGui_BeginChild(ctx, "##qhist", _dd_seek_w, DD_H, 0) then
      -- ChildBg is in the background draw-list layer and is hidden behind ##roll_col's
      -- teal gradient (foreground layer). Paint explicitly in the child's own draw list.
      local qbx, qby = R.ImGui_GetWindowPos(ctx)
      R.ImGui_DrawList_AddRectFilled(R.ImGui_GetWindowDrawList(ctx),
        qbx, qby, qbx + _dd_seek_w, qby + DD_H, SC.PANEL)
      local i = 1
      while i <= #state.hist_filtered do
        local e = state.hist_filtered[i]
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        SC.DEL_BTN)
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), SC.DEL_HV)
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  SC.DEL_AC)
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          SC.TEXT_MUTED)
        local del = R.ImGui_SmallButton(ctx, "x##qhx" .. i)
        R.ImGui_PopStyleColor(ctx, 4)
        if del then
          table.remove(state.query_history, e.orig_idx)
          history_save(state.query_history, _HISTORY_KEY)
          state.hist_filtered = history_filter(state.query_history, state.user_query)
          break
        end
        R.ImGui_SameLine(ctx)
        local sel_sx, sel_sy = R.ImGui_GetCursorScreenPos(ctx)
        local is_hov = R.ImGui_IsMouseHoveringRect(ctx, sel_sx, sel_sy, sel_sx + _dd_seek_w, sel_sy + _DD_ITEM_H)
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), is_hov and SC.WINDOW or SC.TEXT_ON)
        if R.ImGui_Selectable(ctx, e.text .. "##qhi" .. i) then
          state.user_query    = e.text
          state.status        = "searching"
          state.hist_filtered = history_filter(state.query_history, state.user_query)
          state.hist_open     = false
        end
        R.ImGui_PopStyleColor(ctx, 1)
        i = i + 1
      end
    end
    R.ImGui_EndChild(ctx)
    local q_child_hv = R.ImGui_IsItemHovered(ctx,
      R.ImGui_HoveredFlags_AllowWhenBlockedByActiveItem())
    R.ImGui_PopStyleColor(ctx, 3)
    if not state.hist_input_active and not q_child_hv then state.hist_open = false end
  end

  if state.omit_open and #state.omit_filtered > 0 then
    local DD_H = math.min(#state.omit_filtered, _DD_MAX) * _DD_ITEM_H + 4
    R.ImGui_SetCursorScreenPos(ctx, _dd_om_x, _dd_om_y)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ChildBg(),       SC.PANEL)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_HeaderHovered(), SC.TERTIARY)
    R.ImGui_PushStyleColor(ctx, R.ImGui_Col_HeaderActive(),  SC.TERTIARY_AC)
    if R.ImGui_BeginChild(ctx, "##ohist", _dd_omit_w, DD_H, 0) then
      local i = 1
      while i <= #state.omit_filtered do
        local e = state.omit_filtered[i]
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),        SC.DEL_BTN)
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(), SC.DEL_HV)
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),  SC.DEL_AC)
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),          SC.TEXT_MUTED)
        local del = R.ImGui_SmallButton(ctx, "x##ohx" .. i)
        R.ImGui_PopStyleColor(ctx, 4)
        if del then
          table.remove(state.omit_history, e.orig_idx)
          history_save(state.omit_history, _OMIT_HISTORY_KEY)
          state.omit_filtered = history_filter(state.omit_history, state.not_text)
          break
        end
        R.ImGui_SameLine(ctx)
        local sel_sx, sel_sy = R.ImGui_GetCursorScreenPos(ctx)
        local is_hov = R.ImGui_IsMouseHoveringRect(ctx, sel_sx, sel_sy, sel_sx + _dd_omit_w, sel_sy + _DD_ITEM_H)
        R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(), is_hov and SC.WINDOW or SC.TEXT_ON)
        if R.ImGui_Selectable(ctx, e.text .. "##ohi" .. i) then
          state.not_text      = e.text
          state.status        = "searching"
          state.omit_filtered = history_filter(state.omit_history, state.not_text)
          state.omit_open     = false
        end
        R.ImGui_PopStyleColor(ctx, 1)
        i = i + 1
      end
    end
    R.ImGui_EndChild(ctx)
    local omit_child_hv = R.ImGui_IsItemHovered(ctx,
      R.ImGui_HoveredFlags_AllowWhenBlockedByActiveItem())
    R.ImGui_PopStyleColor(ctx, 3)
    if not state.omit_input_active and not omit_child_hv then state.omit_open = false end
  end
end

-- ============================================================
-- Instance guard
-- ============================================================
-- Prevents a second GUI from opening when the script is re-launched while
-- an instance is already running.  The defer loop keeps the timestamp
-- alive; a stale timestamp (>= 1 s old) means REAPER crashed, so a fresh
-- launch is permitted.

-- Test harness API — populated only when an external test script sets
-- _RSG_TEST_MODE = true before dofile()-ing this script.
if _RSG_TEST_MODE then
  _RSG_MINI_TEST_API = {
    do_roll_and_import = do_roll_and_import_slim,
    do_variations      = do_variations_slim,
    import_mod         = import_mod,
  }
end

if not _RSG_TEST_MODE then
  do
    -- RSG-106: same fix as Vortex. "" sentinel = cleanly closed; numeric ts = running.
    local _inst_ts = reaper.GetExtState(_SLIM_NS, "instance_ts")
    if _inst_ts ~= "" and tonumber(_inst_ts) and (reaper.time_precise() - tonumber(_inst_ts)) < 1.0 then
      reaper.ShowMessageBox(
        "Temper Vortex Mini is already running.\nClose the existing window before opening a new instance.",
        "Temper Vortex Mini", 0)
      return
    end
  end
  reaper.SetExtState(_SLIM_NS, "instance_ts", tostring(reaper.time_precise()), false)
end

-- ============================================================
-- Entry point
-- ============================================================

do
  math.randomseed(os.time())

  -- Guard ReaImGui's short-lived-resource rate limit (see Temper_Vortex.lua).
  local _ctx_ok, ctx = pcall(reaper.ImGui_CreateContext, "Temper Vortex Mini##vmini")
  if not _ctx_ok or not ctx then
    reaper.ShowMessageBox(
      "Temper Vortex Mini could not start because ReaImGui is still " ..
      "cleaning up from a previous instance.\n\n" ..
      "Close any existing Vortex Mini window, wait ~15 seconds, then try again.\n" ..
      "If it keeps happening, restart REAPER.",
      "Temper Vortex Mini", 0)
    return
  end
  -- RSG-118: 400x260 hard constraint (board-approved). Enforced every frame in loop().

  -- Load theme and attach fonts before any draw call.
  pcall(dofile, _lib .. "temper_theme.lua")
  if type(temper_theme) == "table" then temper_theme.attach_fonts(ctx) end

  local _lic_ok, lic = pcall(dofile, _lib .. "temper_license.lua")
  if not _lic_ok then lic = nil end
  if lic then lic.configure({
    namespace    = "TEMPER_Vortex_Mini",
    scope_id     = 0x2,
    display_name = "Vortex Mini",
    buy_url      = "https://www.tempertools.com/scripts/vortex-mini",
  }) end

  local state = {
    status           = "init",
    error_msg        = nil,
    index            = {},
    file_lists       = {},
    load_idx         = 1,
    file_reader      = nil,   -- incremental loader: open reader across ticks
    target_track     = nil,
    target_guid      = nil,
    child_name       = "",
    parent_name      = "",
    include_track    = false,  -- Trk toggle: add auto-detected child_name to search
    user_query       = "",     -- user-typed search terms; Trk appends child_name implicitly
    not_text         = "",
    mode             = "free",
    results          = {},
    raw_result_count = 0,
    current_idx      = nil,
    lock_filepath         = nil,    -- B4: file frozen when LOCK mode is active
    last_rolled_filepath  = nil,    -- F9: filepath of last placed file; used as LOCK capture source
    inherit_props    = false,
    prop_snapshot    = nil,
    cap_flash_until  = 0,        -- transient re-capture confirmation flash
    launch_pos       = nil,
    roll_pos         = nil,    -- B1: effective import position (item pos or cursor)
    had_selection    = false,  -- B3: whether an item was selected on last roll
    var_n_buf        = "1",
    var_x_buf        = "4.0",
    var_unit         = 0,
    -- RSG-126: query history autocomplete
    query_history     = {},     -- list of {text, norm, tokens}; most-recent first
    hist_filtered     = {},     -- filtered view used by the dropdown
    hist_open         = false,  -- whether the dropdown is currently visible
    hist_input_active = false,  -- whether query InputText is active/focused this frame
    -- RSG-126: omit history autocomplete (parallel to query history)
    omit_history      = {},
    omit_filtered     = {},
    omit_open         = false,
    omit_input_active = false,
    should_close      = false,  -- RSG-118: set by CLOSE in Settings popup to exit defer loop
    search_pending_ts = nil,    -- RSG-137: debounce timer for SEEK/OMIT text input
    error_flash_until = 0,      -- transient import-failure feedback (epoch)
    error_flash_msg   = nil,    -- message shown in footer pill during flash
  }

  -- RSG-126: load persistent query + omit history and build initial filtered lists.
  state.query_history = history_load(_HISTORY_KEY)
  state.hist_filtered = history_filter(state.query_history, "")
  state.omit_history  = history_load(_OMIT_HISTORY_KEY)
  state.omit_filtered = history_filter(state.omit_history, "")

  -- RSG-115: Activate moved to Settings popup; trial badge shows countdown text only.
  local function _render_trial_badge(ctx_arg, days_left)
    local R      = reaper
    local plural = days_left == 1 and "day" or "days"
    R.ImGui_Separator(ctx_arg)
    R.ImGui_Spacing(ctx_arg)
    R.ImGui_TextColored(ctx_arg, 0x4DB6ACFF,
      string.format("  Trial \xE2\x80\x94 %d %s remaining  (Activate via \xe2\x9a\x99\xef\xb8\x8f Settings)",
        days_left, plural))
  end

  -- ── Action dispatch (rsg_actions framework) ───────────────────
  -- Every key MUST correspond to a command in scripts/lua/actions/manifest.toml.
  -- Entries are thin pointers: they call through vortex_mini_actions, which
  -- mirrors the GUI button callbacks 1:1 (subset-of-GUI invariant).
  -- `close` is a framework built-in dispatched by rsg_actions.toggle_window.
  local HANDLERS = {
    roll              = function() vortex_mini_actions.do_roll(state) end,
    variations        = function() vortex_mini_actions.do_variations(state) end,
    capture           = function() vortex_mini_actions.do_capture(state) end,
    cycle_mode        = function() vortex_mini_actions.cycle_mode(state) end,
    toggle_track_auto = function() vortex_mini_actions.toggle_track_auto(state) end,
    toggle_inh        = function() vortex_mini_actions.toggle_inh(state) end,
    toggle_time_unit  = function() vortex_mini_actions.toggle_time_unit(state) end,
    close             = function() state.should_close = true end,
  }
  rsg_actions.clear_pending_on_init(_SLIM_NS)

  local _first_loop = true
  local function loop()
    reaper.SetExtState(_SLIM_NS, "instance_ts", tostring(reaper.time_precise()), false)
    rsg_actions.heartbeat(_SLIM_NS)
    local _focus_requested = rsg_actions.poll(_SLIM_NS, HANDLERS)
    tick_state(state)

    -- Enforce 400x260 hard constraint every frame (RSG-118).
    -- Skip first frame: platform monitors list isn't populated until after the first render,
    -- and SetNextWindowSize asserts on g.PlatformIO.Monitors.Size > 0 if called too early.
    if not _first_loop then
      reaper.ImGui_SetNextWindowSize(ctx, 400, 260, reaper.ImGui_Cond_Always())
    end
    _first_loop = false
    if _focus_requested then
      reaper.ImGui_SetNextWindowFocus(ctx)
      if reaper.APIExists and reaper.APIExists("JS_Window_SetForeground") then
        local hwnd = reaper.JS_Window_Find and reaper.JS_Window_Find("Temper Vortex Mini", true)
        if hwnd then reaper.JS_Window_SetForeground(hwnd) end
      end
    end
    local n_theme   = temper_theme and temper_theme.push(ctx) or 0
    -- Window bg slightly lighter than input fields (SC.PANEL vs SC.WINDOW) so dark inputs
    -- have visible contrast against the panel surface, matching the North Star depth model.
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), SC.PANEL)
    local win_flags = reaper.ImGui_WindowFlags_NoCollapse()
                    | reaper.ImGui_WindowFlags_NoTitleBar()
                    | reaper.ImGui_WindowFlags_NoResize()
                    | reaper.ImGui_WindowFlags_NoScrollbar()       -- RSG-153: never show scrollbar
                    | reaper.ImGui_WindowFlags_NoScrollWithMouse() -- RSG-153: prevent accidental scroll
    local visible, open = reaper.ImGui_Begin(ctx, "Temper Vortex Mini##vmini", true, win_flags)

    if visible then
      local lic_status = lic and lic.check("VORTEX_MINI", ctx)

      if lic_status == "expired" then
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_TextColored(ctx, 0xC0392BFF, "  Your Vortex Mini trial has expired.")
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_TextDisabled(ctx, "  Purchase a license at temper.tools to continue.")
        if not lic.is_dialog_open() then lic.open_dialog(ctx) end
        lic.draw_dialog(ctx)
      else
        render_gui(ctx, state, lic, lic_status)
        if lic_status == "trial" then
          local days_left = lic.days_remaining and lic.days_remaining("VORTEX_MINI")
          if days_left then _render_trial_badge(ctx, days_left) end
        end
        if lic and lic.is_dialog_open() then lic.draw_dialog(ctx) end
      end

      reaper.ImGui_End(ctx)  -- F9: must only be called when visible=true (undock crash fix)
    end

    if temper_theme then temper_theme.pop(ctx, n_theme) end
    reaper.ImGui_PopStyleColor(ctx, 1)  -- SC.PANEL WindowBg (pushed before ImGui_Begin)
    if open and not state.should_close then
      reaper.defer(loop)
    else
      -- RSG-106: write "" sentinel (not delete) so guard allows immediate reopen.
      reaper.SetExtState(_SLIM_NS, "instance_ts", "", false)
    end
    -- Context is GC'd automatically in ReaImGui >=0.8; no explicit destroy needed.
  end

  if not _RSG_TEST_MODE then reaper.defer(loop) end
end
