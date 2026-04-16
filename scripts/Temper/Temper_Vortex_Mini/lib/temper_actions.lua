-- temper_actions.lua
-- Shared framework for exposing Temper script capabilities as REAPER actions.
--
-- See docs/superpowers/specs/2026-04-11-script-specific-actions-design.md for
-- the full design. All IPC between action stubs and running GUI scripts flows
-- through this module via ExtState. Main scripts call poll() once per defer
-- tick; generated stub scripts call dispatch() / toggle_window() / notify.
--
-- Public API:
--   heartbeat(script_id)                         — GUI side, call every tick
--   clear_pending_on_init(script_id)             — GUI side, call once at init
--   poll(script_id, handlers) -> focus_requested — GUI side, call every tick
--   gui_is_running(script_id) -> bool            — stub side
--   dispatch(script_id, cmd[, opts])             — stub side
--   notify_gui_required(script_name)             — stub side
--   toggle_window(script_id, script_name, main)  — stub side, toggle-window action only

local M = {}

local STALENESS_WINDOW_SEC = 2.0

local _KEY_ALIVE = "alive"
local _KEY_CMD   = "cmd"
local _KEY_FOCUS = "focus_requested"

-- ── GUI-side API ──────────────────────────────────────────────────

function M.heartbeat(script_id)
  reaper.SetExtState(script_id, _KEY_ALIVE, tostring(reaper.time_precise()), false)
end

function M.clear_pending_on_init(script_id)
  reaper.DeleteExtState(script_id, _KEY_CMD, false)
  reaper.DeleteExtState(script_id, _KEY_FOCUS, false)
end

--- Consume a pending command, invoke its handler, return whether focus was requested.
---@return boolean focus_requested
function M.poll(script_id, handlers)
  local cmd = reaper.GetExtState(script_id, _KEY_CMD)
  if cmd == nil or cmd == "" then return false end

  reaper.DeleteExtState(script_id, _KEY_CMD, false)
  local focus_requested = reaper.GetExtState(script_id, _KEY_FOCUS) == "1"
  reaper.DeleteExtState(script_id, _KEY_FOCUS, false)

  local handler = handlers and handlers[cmd]
  if handler then
    -- Silent fail on handler error: never crash the defer loop over an action.
    pcall(handler)
  end
  return focus_requested
end

-- ── Stub-side API ─────────────────────────────────────────────────

function M.gui_is_running(script_id)
  local raw = reaper.GetExtState(script_id, _KEY_ALIVE)
  if raw == nil or raw == "" then return false end
  local ts = tonumber(raw)
  if ts == nil then return false end
  return (reaper.time_precise() - ts) <= STALENESS_WINDOW_SEC
end

function M.dispatch(script_id, cmd, opts)
  reaper.SetExtState(script_id, _KEY_CMD, cmd, false)
  if opts and opts.focus then
    reaper.SetExtState(script_id, _KEY_FOCUS, "1", false)
  end
end

function M.notify_gui_required(script_name)
  local msg = string.format("Open %s to use this action", script_name)
  reaper.TrackCtl_SetToolTip(msg, 0, 0, true)
end

function M.toggle_window(script_id, script_name, main_script)
  if M.gui_is_running(script_id) then
    M.dispatch(script_id, "close")
  else
    local sep = package.config:sub(1, 1)
    local path = reaper.GetResourcePath() .. sep .. "Scripts" .. sep .. "Temper" .. sep .. main_script
    local ok, err = pcall(dofile, path)
    if not ok then
      reaper.TrackCtl_SetToolTip("Could not open " .. script_name .. ": " .. tostring(err), 0, 0, true)
    end
  end
end

return M
