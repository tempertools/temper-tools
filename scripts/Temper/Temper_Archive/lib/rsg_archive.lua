-- rsg_archive.lua -- Cross-platform folder -> .zip compression wrapper.
--
-- Pure Lua (no REAPER UI dependencies beyond reaper.GetOS / reaper.ExecProcess),
-- so it can be unit-tested headless with a stubbed `reaper` global.
--
-- Public API (see tests/test_rsg_archive.lua for coverage):
--   M.detect_os()                      -> "win" | "mac" | nil
--   M.shell_quote(s)                   -> OS-aware quoted string
--   M.is_valid_project(dir)            -> bool, true if ≥1 .rpp/.ptx/.pts in tree
--   M.archive_name_exists(out, name)   -> bool, case-insensitive <name>.zip check
--   M.next_collision_suffix(out, name) -> "" | "_2" | "_3" | ...
--   M.compress(src, dest_final)        -> ok, err, bytes
--
-- The compress() call uses the OS-native zip tool via reaper.ExecProcess:
--   Windows -> powershell Compress-Archive -LiteralPath ... -DestinationPath ... -Force
--   macOS   -> cd <parent> && zip -r -q <dest> <leaf>
-- Both write to <dest>.part first; on success the .part is verified (zip header
-- sniff) and renamed to the final path atomically. On any failure the .part
-- is unconditionally removed.

local M = {}

-- ── OS detection ────────────────────────────────────────────────

function M.detect_os()
  local os_str = (reaper and reaper.GetOS and reaper.GetOS()) or ""
  if os_str:find("Win", 1, true) then return "win" end
  if os_str:find("OSX", 1, true) or os_str:find("macOS", 1, true) then return "mac" end
  return nil
end

-- ── Shell quoting ───────────────────────────────────────────────

-- Windows: wrap in double quotes, escape embedded " as `" (PowerShell safe).
-- macOS:   wrap in single quotes; embedded ' becomes the POSIX idiom '\''.
function M.shell_quote(s)
  s = tostring(s or "")
  if M.detect_os() == "win" then
    -- PowerShell-safe: embedded double quote escaped with backtick-quote.
    local escaped = s:gsub('"', '`"')
    return '"' .. escaped .. '"'
  else
    local escaped = s:gsub("'", "'\\''")
    return "'" .. escaped .. "'"
  end
end

-- ── Filesystem helpers ──────────────────────────────────────────

local function _file_exists(path)
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return false
end

local function _is_dir(path)
  -- Treat any path that Lua can stat as either a dir (via opendir-proxy)
  -- or a non-openable file as existing. We use a lightweight heuristic:
  -- try io.open, and if that fails, try appending "/." and checking again.
  if _file_exists(path) then
    -- A file, not a dir. But io.open on a directory fails on some platforms,
    -- so absence of a successful open does NOT imply not-a-dir. Fall through.
  end
  -- Try listing via os.rename(path, path): a no-op rename succeeds for any
  -- existing FS entry (file or dir). This is the cheapest portable test.
  local ok = os.rename(path, path)
  return ok ~= nil
end

local function _file_size(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local ok, size = pcall(f.seek, f, "end")
  f:close()
  if not ok then return nil end
  return size
end

local function _remove_silent(path)
  pcall(os.remove, path)
end

local function _parent_and_leaf(path)
  local norm = path:gsub("\\", "/"):gsub("/+$", "")
  local parent, leaf = norm:match("^(.*)/([^/]+)$")
  if not parent then
    return ".", norm
  end
  if parent == "" then parent = "/" end
  return parent, leaf
end

-- Recursively walk a directory tree with a breadth-first budget, stopping
-- at the first hit of any extension in `exts` (set of lowercase strings
-- without leading dot). Returns true/false. The traversal is kept cheap
-- by early-returning as soon as a match is found.
local function _find_any_ext(root, exts, max_entries)
  max_entries = max_entries or 5000
  local stack  = { root }
  local checked = 0
  while #stack > 0 and checked < max_entries do
    local dir = table.remove(stack)
    local fi = 0
    while true do
      local fname
      if reaper and reaper.EnumerateFiles then
        fname = reaper.EnumerateFiles(dir, fi)
      else
        fname = nil  -- headless test env: fall through to io-based walk below
      end
      if not fname then break end
      checked = checked + 1
      local lower = fname:lower()
      local ext = lower:match("^.+%.([^%.]+)$")
      if ext and exts[ext] then return true end
      if checked >= max_entries then return false end
      fi = fi + 1
    end
    local si = 0
    while true do
      local sub
      if reaper and reaper.EnumerateSubdirectories then
        sub = reaper.EnumerateSubdirectories(dir, si)
      else
        sub = nil
      end
      if not sub then break end
      stack[#stack + 1] = dir .. "/" .. sub
      si = si + 1
    end
    -- Headless fallback: if REAPER enumeration is unavailable, fall back
    -- to a shell-assisted walk. This path is used only by unit tests.
    if not (reaper and reaper.EnumerateFiles) then
      return _shell_walk_find_any_ext(root, exts)
    end
  end
  return false
end

-- Headless fallback: use `dir /s /b` (Windows) or `find` (POSIX). Bash on
-- Windows in this project runs under Git Bash, so `find` is also available
-- — prefer it for portability.
function _shell_walk_find_any_ext(root, exts)
  if not _is_dir(root) then return false end
  local cmd
  if package.config:sub(1, 1) == "\\" then
    cmd = string.format('dir /s /b /a-d "%s" 2>nul', (root:gsub("/", "\\")))
  else
    cmd = string.format('find "%s" -type f 2>/dev/null', root)
  end
  local p = io.popen(cmd)
  if not p then return false end
  for line in p:lines() do
    local lower = line:lower()
    local ext = lower:match("^.+%.([^%.]+)$")
    if ext and exts[ext] then p:close(); return true end
  end
  p:close()
  return false
end

-- ── Project validity ────────────────────────────────────────────

local _PROJECT_EXTS = { rpp = true, ptx = true, pts = true }

function M.is_valid_project(dir)
  if not dir or dir == "" then return false end
  if not _is_dir(dir) then return false end
  return _find_any_ext(dir, _PROJECT_EXTS, 5000)
end

-- ── Archive identity (case-insensitive <name>.zip lookup) ───────

-- List top-level files in `out_dir`. Uses REAPER's EnumerateFiles when
-- available; falls back to a shell listing for headless tests.
local function _list_files(out_dir)
  local files = {}
  if reaper and reaper.EnumerateFiles then
    local fi = 0
    while true do
      local fname = reaper.EnumerateFiles(out_dir, fi)
      if not fname then break end
      files[#files + 1] = fname
      fi = fi + 1
    end
    return files
  end
  local cmd
  if package.config:sub(1, 1) == "\\" then
    cmd = string.format('dir /b /a-d "%s" 2>nul', (out_dir:gsub("/", "\\")))
  else
    cmd = string.format('ls -1 "%s" 2>/dev/null', out_dir)
  end
  local p = io.popen(cmd)
  if not p then return files end
  for line in p:lines() do
    if line ~= "" then files[#files + 1] = line end
  end
  p:close()
  return files
end

function M.archive_name_exists(out_dir, folder_name)
  if not out_dir or out_dir == "" then return false end
  if not folder_name or folder_name == "" then return false end
  local target = (folder_name .. ".zip"):lower()
  for _, fname in ipairs(_list_files(out_dir)) do
    if fname:lower() == target then return true end
  end
  return false
end

function M.next_collision_suffix(out_dir, folder_name)
  if not M.archive_name_exists(out_dir, folder_name) then return "" end
  local n = 2
  while true do
    local candidate = folder_name .. "_" .. n
    if not M.archive_name_exists(out_dir, candidate) then
      return "_" .. n
    end
    n = n + 1
    if n > 9999 then return "_" .. n end  -- runaway guard
  end
end

-- ── ExecProcess result parsing ──────────────────────────────────

-- Extract the first non-empty line from a (possibly multi-line) string.
-- PowerShell errors are verbose; the first line is usually the meaningful one.
local function _first_line(s)
  if not s or s == "" then return s end
  for line in s:gmatch("[^\r\n]+") do
    local stripped = line:gsub("^%s+", ""):gsub("%s+$", "")
    if stripped ~= "" then return stripped end
  end
  return s
end

-- reaper.ExecProcess returns "<exit_code>\n<stdout+stderr>" (SWS format).
-- Parse into (exit_code, output).
local function _parse_exec_result(raw)
  if not raw or raw == "" then return nil, "ExecProcess returned empty" end
  local exit_str, rest = raw:match("^(%-?%d+)\n(.*)$")
  if not exit_str then
    return nil, "malformed ExecProcess result"
  end
  return tonumber(exit_str), rest or ""
end

-- ── Compress ────────────────────────────────────────────────────

-- Verify a .part file looks like a real zip: non-empty and starts with "PK".
local function _verify_zip(path)
  local f = io.open(path, "rb")
  if not f then return false, "part file missing after compress" end
  local sig = f:read(2)
  f:seek("end")
  local size = f:seek()
  f:close()
  if not sig or #sig < 2 then return false, "part file too short" end
  if sig:sub(1, 2) ~= "PK" then return false, "part file not a zip (bad signature)" end
  if size < 22 then return false, "part file smaller than zip EOCD" end
  return true, nil, size
end

-- PowerShell single-quote: literal strings inside -Command "...".
-- Embedded single quotes are escaped by doubling ('').
local function _ps_quote(s)
  return "'" .. s:gsub("'", "''") .. "'"
end

local function _build_win_cmd(src_abs, dest_part)
  -- Use single quotes for paths INSIDE the -Command "..." string so they
  -- don't collide with the outer double quotes.
  -- -LiteralPath avoids glob expansion on folders whose names contain
  -- PowerShell glob metacharacters ([, ], *, ?).
  return string.format(
    'powershell -NoProfile -NonInteractive -Command "Compress-Archive -LiteralPath %s -DestinationPath %s -Force"',
    _ps_quote(src_abs), _ps_quote(dest_part)
  )
end

local function _build_mac_cmd(src_abs, dest_part)
  local parent, leaf = _parent_and_leaf(src_abs)
  return string.format(
    'cd %s && zip -r -q %s %s',
    M.shell_quote(parent), M.shell_quote(dest_part), M.shell_quote(leaf)
  )
end

function M.compress(src_dir, dest_final)
  if not src_dir or src_dir == "" then
    return false, "source path is empty"
  end
  if not dest_final or dest_final == "" then
    return false, "destination path is empty"
  end
  if not _is_dir(src_dir) then
    return false, "source directory does not exist: " .. src_dir
  end
  local platform = M.detect_os()
  if platform ~= "win" and platform ~= "mac" then
    return false, "unsupported platform"
  end
  if not (reaper and reaper.ExecProcess) then
    return false, "reaper.ExecProcess unavailable (SWS required)"
  end

  -- PowerShell Compress-Archive requires the destination to end in .zip;
  -- it rejects .zip.part. Use _tmp.zip suffix instead.
  local dest_part = dest_final:gsub("%.zip$", "_tmp.zip")
  _remove_silent(dest_part)

  local cmd
  if platform == "win" then
    cmd = _build_win_cmd(src_dir, dest_part)
  else
    cmd = _build_mac_cmd(src_dir, dest_part)
  end

  local raw = reaper.ExecProcess(cmd, 0)
  local exit_code, output = _parse_exec_result(raw)
  if not exit_code then
    _remove_silent(dest_part)
    return false, "compress: " .. tostring(output)
  end
  if exit_code ~= 0 then
    _remove_silent(dest_part)
    local trimmed = (output or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local short = string.format("compress exit %d: %s", exit_code, _first_line(trimmed))
    local full  = string.format("compress exit %d: %s", exit_code, trimmed)
    return false, short, nil, full
  end

  local ok, verr, bytes = _verify_zip(dest_part)
  if not ok then
    _remove_silent(dest_part)
    return false, "compress: " .. (verr or "verification failed")
  end

  -- Atomic-ish rename: Windows os.rename cannot overwrite, so remove first.
  _remove_silent(dest_final)
  local renamed, rerr = os.rename(dest_part, dest_final)
  if not renamed then
    _remove_silent(dest_part)
    return false, "rename .part -> .zip failed: " .. tostring(rerr)
  end
  return true, nil, bytes
end

-- ── Async compress (non-blocking) ──────────────────────────────
-- compress_start launches the OS zip tool as a background process and
-- returns immediately. compress_poll checks for completion each frame.
-- compress_cancel cleans up tracking files on user cancel.

-- Write a temp script that compresses and writes a sentinel file on exit.
-- The sentinel contains "0" on success or the error message on failure.
local function _write_win_job(src_abs, dest_part, sentinel, script_path)
  local f = io.open(script_path, "w")
  if not f then return false end
  f:write(string.format(
    "try { Compress-Archive -LiteralPath %s -DestinationPath %s -Force; Set-Content -Path %s -Value '0' -NoNewline } catch { Set-Content -Path %s -Value $_.Exception.Message -NoNewline }\n",
    _ps_quote(src_abs), _ps_quote(dest_part), _ps_quote(sentinel), _ps_quote(sentinel)
  ))
  f:close()
  return true
end

local function _write_mac_job(src_abs, dest_part, sentinel, script_path)
  local parent, leaf = _parent_and_leaf(src_abs)
  local f = io.open(script_path, "w")
  if not f then return false end
  f:write(string.format(
    "#!/bin/sh\ncd %s && zip -r -q %s %s 2>/dev/null\necho $? > %s\n",
    M.shell_quote(parent), M.shell_quote(dest_part),
    M.shell_quote(leaf), M.shell_quote(sentinel)
  ))
  f:close()
  return true
end

--- Launch async compress. Returns sentinel_path, dest_part, script_path on
--- success, or nil, error_message on validation failure.
function M.compress_start(src_dir, dest_final)
  if not src_dir or src_dir == "" then return nil, "source path is empty" end
  if not dest_final or dest_final == "" then return nil, "destination path is empty" end
  if not _is_dir(src_dir) then return nil, "source directory does not exist: " .. src_dir end
  local platform = M.detect_os()
  if platform ~= "win" and platform ~= "mac" then return nil, "unsupported platform" end

  local dest_part   = dest_final:gsub("%.zip$", "_tmp.zip")
  local sentinel    = dest_final:gsub("%.zip$", "_done.txt")
  local script_path = dest_final:gsub("%.zip$", (platform == "win") and "_job.ps1" or "_job.sh")
  _remove_silent(dest_part)
  _remove_silent(sentinel)

  local ok
  if platform == "win" then
    ok = _write_win_job(src_dir, dest_part, sentinel, script_path)
    if ok then
      -- io.popen returns immediately; the child runs in the background.
      -- Handle is intentionally not closed so it doesn't block; GC cleans up.
      io.popen(string.format(
        'powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%s"',
        script_path
      ))
    end
  else
    ok = _write_mac_job(src_dir, dest_part, sentinel, script_path)
    if ok then
      os.execute(string.format('chmod +x %s && %s &',
        M.shell_quote(script_path), M.shell_quote(script_path)))
    end
  end
  if not ok then return nil, "failed to write job script" end
  return sentinel, dest_part, script_path
end

--- Poll for async compress completion. Returns nil while still running.
--- On completion returns (ok, err, bytes, full_err) matching compress().
function M.compress_poll(sentinel, dest_part, dest_final, script_path)
  local f = io.open(sentinel, "r")
  if not f then return nil end  -- still running
  local content = f:read("*a")
  f:close()
  _remove_silent(sentinel)
  _remove_silent(script_path)

  local trimmed = (content or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if trimmed ~= "0" then
    _remove_silent(dest_part)
    local short = "compress failed: " .. _first_line(trimmed)
    local full  = "compress failed: " .. trimmed
    return false, short, nil, full
  end

  local ok, verr, bytes = _verify_zip(dest_part)
  if not ok then
    _remove_silent(dest_part)
    return false, "compress: " .. (verr or "verification failed")
  end

  _remove_silent(dest_final)
  local renamed, rerr = os.rename(dest_part, dest_final)
  if not renamed then
    _remove_silent(dest_part)
    return false, "rename .part -> .zip failed: " .. tostring(rerr)
  end
  return true, nil, bytes
end

--- Return the current byte size of the in-progress _tmp.zip file, or nil.
function M.compress_progress(dest_part)
  return _file_size(dest_part)
end

--- Clean up tracking files when user cancels mid-compress.
--- The background process may still complete; its orphaned _tmp.zip
--- will be cleaned up by the next compress_start for the same dest.
function M.compress_cancel(sentinel, dest_part, script_path)
  _remove_silent(sentinel)
  _remove_silent(script_path)
  _remove_silent(dest_part)
end

return M
