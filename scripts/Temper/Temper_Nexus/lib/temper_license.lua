-- temper_license.lua
-- Temper license validation module.
-- Provides offline HMAC-SHA256 key validation, 7-day trial, and activation dialog.
--
-- Public API:
--   temper_license.check(product_code, ctx)    -> "licensed" | "trial" | "expired"
--   temper_license.configure(opts)             -> set namespace, scope_id, buy_url, display_name
--   temper_license.open_dialog(ctx)            -> call once inside Begin/End to show dialog
--   temper_license.draw_dialog(ctx)            -> call each frame while is_dialog_open() is true
--   temper_license.is_dialog_open()            -> bool
--   temper_license.trial_days_remaining()      -> int (0 when licensed or expired)
--
-- Dependencies (loaded lazily at first check()):
--   lib/temper_sha256.lua    -- pure Lua SHA-256 + HMAC-SHA256
--   lib/temper_activation_dialog.lua -- visual activation dialog
--   lib/temper_theme.lua     -- required by temper_activation_dialog
--
-- ExtState namespace: per-script (e.g. TEMPER_Vortex, persists to reaper.ini)

local M = {}

-- ── Internal constants ────────────────────────────────────────────────────────

local _NS  = "TEMPER_Unknown"
local _DAY = 86400
local _TRIAL_DAYS = 7

-- Scope IDs must match server-side product registry.
local _SCOPE_NAMES = {
  [0x1] = "Vortex",      [0x2] = "Vortex Mini",
  [0x3] = "Imprint",     [0x4] = "Mark",
  [0x5] = "Alloy",       [0x6] = "Slice Mini",
  [0x7] = "Slice",       [0x8] = "Nexus",
  [0x9] = "Archive",
  [0xF] = "Temper All-Access Bundle",
}

-- Reconstruct HMAC signing key at runtime (obfuscated storage).
local function _ks()
  local _p = {
    {0x6b,0x63,0x3f,0x6d,0x3f,0x6f,0x6b,0x38,0x3c,0x6b,0x68,0x39,0x6e,0x6e,0x6d,0x69},
    {0x08,0x0c,0x0b,0x5f,0x05,0x5e,0x5a,0x0f,0x08,0x0e,0x5e,0x05,0x08,0x5a,0x5d,0x59},
    {0x4b,0x18,0x48,0x4c,0x18,0x4b,0x4d,0x1b,0x48,0x4a,0x4a,0x47,0x1f,0x47,0x4e,0x1a},
    {0x7d,0x22,0x2a,0x28,0x7e,0x2d,0x78,0x79,0x78,0x28,0x2b,0x22,0x2c,0x7d,0x22,0x2f},
  }
  local _x = {0x5A,0x3C,0x7E,0x1B}
  local s = {}
  for i = 1, #_p do
    for j = 1, #_p[i] do s[#s+1] = string.char(_p[i][j] ~ _x[i]) end
  end
  return table.concat(s)
end

-- ── Lazy-loaded dependencies ──────────────────────────────────────────────────

local _sha, _dlg

-- Resolve sibling libs by deriving the directory of this lib file at load time.
-- Works whether temper_license.lua lives in the dev shared lib/ or in a per-package
-- ReaPack subfolder (Scripts/Temper/Temper/Temper_<Script>/lib/).
local _self_path = debug.getinfo(1, "S").source:sub(2)
local _self_dir  = (_self_path:match("^(.*)[\\/]") or ".")
local function _lib_path(name)
  return _self_dir .. "/" .. name
end

local function _require_sha()
  if _sha then return _sha end
  local ok, mod = pcall(dofile, _lib_path("temper_sha256.lua"))
  if not ok then
    error("[temper_license] Cannot load temper_sha256.lua: " .. tostring(mod), 2)
  end
  _sha = mod
  return _sha
end

-- ctx is passed so that if temper_theme must be loaded here as a fallback,
-- attach_fonts(ctx) can be called to satisfy temper_activation_dialog's font_bold assertion.
local function _require_dialog(ctx)
  if _dlg then return _dlg end
  -- temper_activation_dialog requires temper_theme to be a global.
  if type(temper_theme) ~= "table" then
    local theme_ok, theme_err = pcall(dofile, _lib_path("temper_theme.lua"))
    if not theme_ok then
      error("[temper_license] Cannot load temper_theme.lua: " .. tostring(theme_err), 2)
    end
  end
  -- temper_activation_dialog asserts temper_theme.font_bold ~= nil at load time.
  -- If fonts were not attached at startup (e.g. temper_theme.lua was missing then),
  -- attach them now using the ctx we received.
  if type(temper_theme) == "table" and temper_theme.font_bold == nil and ctx then
    temper_theme.attach_fonts(ctx)
  end
  local ok, mod = pcall(dofile, _lib_path("temper_activation_dialog.lua"))
  if not ok then
    error("[temper_license] Cannot load temper_activation_dialog.lua: " .. tostring(mod), 2)
  end
  _dlg = mod
  _dlg.configure({ display_name = _display_name, buy_url = _buy_url })
  return _dlg
end

-- ── Key validation ────────────────────────────────────────────────────────────

-- _validate_key(raw_key) -> scope_id (int) or nil, error_string
-- Returns the scope ID encoded in the key if HMAC is valid, else nil + reason.
local function _validate_key(raw)
  local _k = ((raw or ""):gsub("%-", "")):upper()
  if #_k ~= 16 or not _k:match("^%x+$") then return nil, "format" end

  local payload = _k:sub(1, 8)
  local sig     = _k:sub(9, 16)

  local sha = _require_sha()
  local expected = sha.hmac(_ks(), payload):sub(1, 8):upper()
  if sig ~= expected then return nil, "invalid" end

  local scope = tonumber(payload:sub(1, 1), 16)
  if scope == 0 then return nil, "invalid" end
  return scope, nil
end

-- _key_matches_product(scope, product_scope_id) -> bool
-- Bundle scope (0xF) matches any product.
local function _key_matches_product(scope, product_scope_id)
  return scope == 0xF or scope == product_scope_id
end

-- ── ExtState helpers ──────────────────────────────────────────────────────────

local function _get(key)
  return reaper.GetExtState(_NS, key)
end

local function _set(key, val)
  reaper.SetExtState(_NS, key, tostring(val), true)
end

-- ── Trial management ──────────────────────────────────────────────────────────

-- Returns days_remaining (int >= 0). 0 means trial has expired.
local function _trial_days_remaining()
  local ts = _get("install_ts")
  if ts == "" then
    ts = tostring(os.time())
    _set("install_ts", ts)
  end
  local elapsed_days = (os.time() - (tonumber(ts) or os.time())) / _DAY
  local remaining = math.floor(_TRIAL_DAYS - elapsed_days)
  return math.max(0, remaining)
end

-- ── Module state ──────────────────────────────────────────────────────────────

local _status         = nil  -- "licensed" | "trial" | "expired", cached per session
local _dlg_open       = false
local _buy_url        = "https://www.tempertools.com"
local _display_name   = "Temper"
local _scope_id       = nil  -- product scope ID for key validation; must be set via configure()

-- ── Public API ───────────────────────────────────────────────────────────────

-- Configure per-product settings. Call once after dofile, before first check().
-- opts: { namespace, scope_id, buy_url, display_name }
function M.configure(opts)
  if opts.namespace    then _NS           = opts.namespace end
  if opts.scope_id     then _scope_id     = opts.scope_id end
  if opts.buy_url      then _buy_url      = opts.buy_url end
  if opts.display_name then _display_name = opts.display_name end
end

-- check(product_code, ctx) -> "licensed" | "trial" | "expired"
-- product_code is reserved for future use. ctx is the ReaImGui context.
function M.check(product_code, ctx)  -- luacheck: ignore product_code ctx
  if _status == "licensed" then return "licensed" end


  -- Check stored key (HMAC validation + scope match)
  local stored = _get("license_key")
  if stored ~= "" then
    local scope = _validate_key(stored)
    if scope and _key_matches_product(scope, _scope_id) then
      _status = "licensed"
      return "licensed"
    end
  end

  -- Check trial window
  local days_left = _trial_days_remaining()
  if days_left > 0 then
    _status = "trial"
    return "trial"
  end

  _status = "expired"
  return "expired"
end

-- open_dialog(ctx) -> nil
-- Trigger the activation dialog. Must be called inside an ImGui Begin/End block.
-- Idempotent: no-op if the dialog is already open or if status == "licensed".
function M.open_dialog(ctx)
  if _status == "licensed" or _dlg_open then return end
  local dlg = _require_dialog(ctx)
  dlg.open(ctx)
  _dlg_open = true
end

-- is_dialog_open() -> bool
-- Returns true while the activation dialog is visible on screen.
function M.is_dialog_open()
  return _dlg_open
end

-- trial_days_remaining() -> int
-- Days left in the trial window. Returns 0 when licensed or expired.
function M.trial_days_remaining()
  if _status == "licensed" then return 0 end
  return _trial_days_remaining()
end

-- draw_dialog(ctx) -> nil
-- Advance the activation dialog state machine for one ImGui frame.
-- Call every frame while is_dialog_open() returns true (inside Begin/End).
-- For expired mode: call open_dialog(ctx) first (once), then draw_dialog(ctx) every frame.
function M.draw_dialog(ctx)
  if not _dlg_open then return end
  local dlg = _require_dialog(ctx)

  local days_left = (_status == "trial") and _trial_days_remaining() or 0
  local result = dlg.draw(ctx, days_left)

  if result == "activate_requested" then
    local raw = dlg.last_key or ""
    local scope, err = _validate_key(raw)
    if not scope then
      if err == "format" then
        dlg.set_error("Invalid key format.")
      else
        dlg.set_error("Invalid license key.")
      end
    elseif not _key_matches_product(scope, _scope_id) then
      local name = _SCOPE_NAMES[scope] or ("product " .. tostring(scope))
      dlg.set_error("This key is for " .. name .. ".")
    else
      _set("license_key", raw)
      _status   = "licensed"
      _dlg_open = false
    end

  elseif result == "buy_requested" then
    reaper.CF_ShellExecute(_buy_url)

  elseif result == "dismissed" then
    _dlg_open = false
  end
end

-- reset() -> nil  (test/debug use only; clears cached session state)
function M.reset()
  _status   = nil
  _dlg_open = false
  _sha      = nil
  _dlg      = nil
end

return M
