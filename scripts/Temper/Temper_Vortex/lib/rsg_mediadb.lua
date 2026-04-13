-- rsg_mediadb.lua — MediaDB index loader, cache system, and AND-token search
-- Shared library for Temper scripts (Vortex, Vortex Mini, etc.)
-- Returns the `db` table with cache helpers included.
--
-- Usage:
--   local db = dofile(reaper.GetResourcePath() .. "/Scripts/Temper/lib/rsg_mediadb.lua")

-- ============================================================
-- Cache — persist the parsed MediaDB index between sessions
-- ============================================================
-- Cache file lives next to the script so it is tied to this REAPER installation.
-- Invalidated by comparing the combined byte size of all .ReaperFileList files.
-- Format:
--   Line 1: version sentinel
--   Line 2: "<combined_bytes>_<file_count>"
--   Lines 3+: "<filepath>\t<haystack>"
-- ============================================================

local _CACHE_VERSION = "TEMPER_IDX_V1"
local _CACHE_FILE    = reaper.GetResourcePath() .. "/Scripts/Temper/.mediadb_cache"

-- Return a lightweight hash string from the combined size of all list files.
local function _cache_hash(file_lists)
  local total = 0
  for _, f in ipairs(file_lists) do
    local fh = io.open(f, "rb")
    if fh then total = total + fh:seek("end"); fh:close() end
  end
  return tostring(total) .. "_" .. tostring(#file_lists)
end

-- Try to load a previously saved index from disk.
-- Returns the index table on cache hit, or nil on miss/stale/corrupt.
local function _load_cache(file_lists)
  local fh = io.open(_CACHE_FILE, "r")
  if not fh then return nil end
  local ver  = fh:read("*l")
  local hash = fh:read("*l")
  if ver ~= _CACHE_VERSION or hash ~= _cache_hash(file_lists) then
    fh:close(); return nil
  end
  local content = fh:read("*a")
  fh:close()
  local index = {}
  for line in content:gmatch("[^\n]+") do
    local fp, hs = line:match("^([^\t]+)\t(.+)$")
    if fp and hs then
      index[#index + 1] = { filepath = fp, haystack = hs }
    end
  end
  return #index > 0 and index or nil
end

-- Persist the current index to disk for the next session.
local function _save_cache(file_lists, index)
  local fh = io.open(_CACHE_FILE, "w")
  if not fh then return end
  fh:write(_CACHE_VERSION .. "\n")
  fh:write(_cache_hash(file_lists) .. "\n")
  for _, entry in ipairs(index) do
    local fp = entry.filepath:gsub("[\t\n]", " ")
    local hs = entry.haystack:gsub("[\t\n]", " ")
    fh:write(fp .. "\t" .. hs .. "\n")
  end
  fh:close()
end

-- ============================================================
-- db — MediaDB index loader and AND-token search
-- ============================================================

local db = {}

-- Expose cache helpers on the module table so callers can use them directly.
db.cache_hash  = _cache_hash
db.load_cache  = _load_cache
db.save_cache  = _save_cache

-- Extract the value from the trailing portion of a USER line after the field name.
-- Handles quoted ("multi word value" 0) and unquoted (SingleWord 0) forms.
-- @param rest string  Everything on the line after "USER IXML:USER:FieldName "
-- @return string      Extracted value, or "" on parse failure
function db.parse_value(rest)
  rest = rest:match("^%s*(.-)%s*$")
  if rest:sub(1, 1) == '"' then
    return rest:match('^"([^"]*)"') or ""
  end
  return rest:match("^(%S+)") or ""
end

-- Extract title from a DATA line. Only the first DATA line has the "t:..." form.
-- @param line string   Raw DATA line
-- @return string|nil  Title text, or nil if not present
function db.parse_title_from_data(line)
  return line:match('"t:([^"]+)"')
end

-- Extract field name and value from a USER IXML:USER:* line.
-- @param line string              Raw USER line
-- @return string|nil, string|nil  field_name, value — or nil, nil if no match
function db.parse_user_field(line)
  local field, rest = line:match("^USER IXML:USER:(%S+)%s+(.+)$")
  if not field then return nil, nil end
  return field, db.parse_value(rest)
end

-- Concatenate searchable fields into a single lowercase haystack string.
-- Field order: keywords, category, subcategory, catid, title, description, filename stem.
-- @param fields table  {keywords, category, subcategory, catid, title, description, filepath}
-- @return string       Lowercase concatenated haystack
function db.build_haystack(fields)
  local parts = {}
  local function add(s)
    if s and s ~= "" then parts[#parts + 1] = s end
  end
  add(fields.keywords)
  add(fields.category)
  add(fields.subcategory)
  add(fields.catid)
  add(fields.title)
  add(fields.description)
  if fields.filepath then
    local stem = fields.filepath:match("([^/\\]+)%.[^%.]*$")
    if stem then add(stem) end
  end
  return table.concat(parts, " "):lower()
end

-- USER IXML fields to extract from ReaperFileList entries.
local _WANTED = { Keywords = true, Category = true, SubCategory = true, CatID = true }

-- Parse one ReaperFileList file, appending {filepath, haystack} entries to index.
-- @param filepath string  Absolute path to a *.ReaperFileList file
-- @param index    table   Mutable list; entries appended here
-- @return number          Count of entries appended
function db.parse_file_list(filepath, index)
  local f = io.open(filepath, "r")
  if not f then return 0 end

  local count     = 0
  local cur       = nil
  local data_seen = false

  local function finalize()
    if not cur then return end
    local haystack = db.build_haystack(cur)
    if haystack ~= "" then
      index[#index + 1] = { filepath = cur.filepath, haystack = haystack }
      count = count + 1
    end
    cur       = nil
    data_seen = false
  end

  for line in f:lines() do
    if line:sub(1, 5) == "FILE " then
      finalize()
      local p = line:match('^FILE "([^"]+)"') or line:match("^FILE (%S+)")
      if p then
        cur = { filepath = p, keywords = "", category = "", subcategory = "", catid = "", title = "", description = "" }
      end
    elseif cur and line:sub(1, 5) == "DATA " then
      if not data_seen then
        cur.title = db.parse_title_from_data(line) or ""
        data_seen = true
      end
      local d = line:match('"d:([^"]*)"')
      if d and d ~= "" then cur.description = d end
    elseif cur and line:sub(1, 15) == "USER IXML:USER:" then
      local field, value = db.parse_user_field(line)
      if field and _WANTED[field] then
        cur[field:lower()] = value
      end
    end
  end

  f:close()
  finalize()
  return count
end

-- Enumerate all *.ReaperFileList files in the REAPER MediaDB directory.
-- @return table  List of absolute paths (empty if directory missing or empty)
function db.find_file_lists()
  local dir   = reaper.GetResourcePath() .. "/MediaDB/"
  local paths = {}
  local i     = 0
  while true do
    local name = reaper.EnumerateFiles(dir, i)
    if not name then break end
    if name:match("%.ReaperFileList$") then
      paths[#paths + 1] = dir .. name
    end
    i = i + 1
  end
  return paths
end

-- Load all ReaperFileList files and build the combined search index.
-- @return table, string|nil  index table + error string (nil on success)
function db.load_index()
  local file_lists = db.find_file_lists()
  if #file_lists == 0 then
    return {}, "No MediaDB files found. Run Media Explorer scan first."
  end
  local index = {}
  for _, path in ipairs(file_lists) do
    db.parse_file_list(path, index)
  end
  return index, nil
end

-- Split text into lowercase alphanumeric tokens, filtering stop words.
-- @param text       string  Input text
-- @param stop_words table   Set of UPPERCASE stop words to discard
-- @return table             Ordered list of lowercase tokens
function db.tokenize(text, stop_words)
  local tokens = {}
  for word in text:gmatch("[%a%d]+") do
    if not stop_words[word:upper()] then
      tokens[#tokens + 1] = word:lower()
    end
  end
  return tokens
end

-- Build a deduplicated token list for a child track's search query.
-- @param parent_name    string   Parent folder track name
-- @param child_name     string   Child track name
-- @param include_parent boolean  When true, prepend parent tokens
-- @param stop_words     table    Stop word set (uppercase keys)
-- @return table                  Ordered deduplicated lowercase token list
function db.build_query(parent_name, child_name, include_parent, stop_words)
  local seen   = {}
  local tokens = {}
  local function add(src)
    for _, t in ipairs(db.tokenize(src, stop_words)) do
      if not seen[t] then
        seen[t]             = true
        tokens[#tokens + 1] = t
      end
    end
  end
  if include_parent and parent_name ~= "" then add(parent_name) end
  if child_name ~= "" then add(child_name) end
  return tokens
end

-- AND-token search over the loaded index.
-- @param index  table  Loaded index from db.load_index()
-- @param tokens table  Lowercase tokens from db.build_query() or db.tokenize()
-- @return table        List of matching 1-based positions into index
function db.search(index, tokens)
  local results = {}
  if #tokens == 0 then return results end
  for i, entry in ipairs(index) do
    local match = true
    for _, token in ipairs(tokens) do
      if not entry.haystack:find(token, 1, true) then
        match = false
        break
      end
    end
    if match then results[#results + 1] = i end
  end
  return results
end

-- Remove results whose haystack contains any exclusion token (NOT filter).
-- @param index          table  Loaded index from db.load_index()
-- @param results        table  Position list from db.search()
-- @param exclude_tokens table  Lowercase tokens to reject
-- @return table                Filtered position list
function db.filter_exclusions(index, results, exclude_tokens)
  if #exclude_tokens == 0 then return results end
  local filtered = {}
  for _, idx in ipairs(results) do
    local hay      = index[idx].haystack
    local excluded = false
    for _, tok in ipairs(exclude_tokens) do
      if hay:find(tok, 1, true) then
        excluded = true
        break
      end
    end
    if not excluded then filtered[#filtered + 1] = idx end
  end
  return filtered
end

-- ============================================================
-- Incremental reader — non-blocking line parsing across ticks
-- ============================================================

-- Open a ReaperFileList file for incremental parsing across multiple ticks.
-- Returns a reader table, or nil if the file cannot be opened.
-- reader.size  = total byte size (for progress calculation)
-- reader.pos   = bytes consumed so far (updated after each read_chunk call)
-- @param filepath string  Absolute path to a *.ReaperFileList file
-- @return table|nil       Reader table, or nil on failure
function db.open_reader(filepath)
  local f = io.open(filepath, "r")
  if not f then return nil end
  local size = f:seek("end") or 0
  f:seek("set", 0)
  return { f = f, size = math.max(size, 1), pos = 0, cur = nil, data_seen = false }
end

-- Process up to max_lines from a reader, appending entries to index.
-- Returns true when the file is fully parsed (reader is then closed automatically).
-- @param reader    table   Reader from db.open_reader()
-- @param index     table   Mutable list; entries appended here
-- @param max_lines number  Maximum lines to process this call
-- @return boolean          true when file is fully consumed
function db.read_chunk(reader, index, max_lines)
  local f = reader.f
  local cur       = reader.cur
  local data_seen = reader.data_seen
  local n = 0

  local function finalize()
    if not cur then return end
    local haystack = db.build_haystack(cur)
    if haystack ~= "" then
      index[#index + 1] = { filepath = cur.filepath, haystack = haystack }
    end
    cur       = nil
    data_seen = false
  end

  for line in f:lines() do
    n = n + 1
    if line:sub(1, 5) == "FILE " then
      finalize()
      local p = line:match('^FILE "([^"]+)"') or line:match("^FILE (%S+)")
      if p then
        cur = { filepath = p, keywords = "", category = "", subcategory = "", catid = "", title = "", description = "" }
      end
    elseif cur and line:sub(1, 5) == "DATA " then
      if not data_seen then
        cur.title = db.parse_title_from_data(line) or ""
        data_seen = true
      end
      local d = line:match('"d:([^"]*)"')
      if d and d ~= "" then cur.description = d end
    elseif cur and line:sub(1, 15) == "USER IXML:USER:" then
      local field, value = db.parse_user_field(line)
      if field and _WANTED[field] then
        cur[field:lower()] = value
      end
    end
    if n >= max_lines then break end
  end

  reader.pos      = f:seek() or reader.size
  reader.cur      = cur
  reader.data_seen = data_seen

  -- Check if we hit EOF (read fewer lines than requested)
  if n < max_lines then
    finalize()
    f:close()
    reader.pos = reader.size
    reader.f   = nil
    return true
  end
  return false
end

return db
