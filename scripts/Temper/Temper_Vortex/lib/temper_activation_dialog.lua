-- @description Temper — Activation Dialog (Design Engineer deliverable, RSG-61)
-- @version 1.2.0
-- @author RSG Design Engineer
-- @about
--   Visual component for the Temper license activation dialog.
--   Renders a BeginPopupModal with trial status, key input, and action buttons.
--
--   Integration:
--     The FE wires this into temper_license.lua's draw_dialog() function.
--     This file is the DE's complete visual handoff — do not add business logic here.
--
--   Depends on:
--     temper_theme  — must be dofile'd before this module so temper_theme is a global.
--                  temper_theme.apply(ctx) and temper_theme.attach_fonts(ctx) must be
--                  called before the first frame. If temper_theme is missing, an error
--                  is raised at load time with an actionable message.
--
--   Public API:
--     temper_activation_dialog.open(ctx, trial_days)
--       Call once when you want to show the dialog. Idempotent.
--       trial_days: integer (days remaining), or 0 if expired.
--
--     temper_activation_dialog.draw(ctx, trial_days) → string|nil
--       Call every frame during the deferred loop.
--       Returns: "activate_requested" (key available in .last_key),
--                "buy_requested", "dismissed" (trial only), or nil (still open).
--
--     temper_activation_dialog.last_key  → string  (raw input on activate_requested)
--     temper_activation_dialog.set_error(msg)       (call when FE rejects the key)

-- ── Guard: require temper_theme to be loaded before this module ─────────────────
assert(type(temper_theme) == "table" and temper_theme.font_bold ~= nil,
  "[temper_activation_dialog] temper_theme not loaded. " ..
  "Call dofile(temper_theme_path) and temper_theme.attach_fonts(ctx) before using this module.")

-- ── Color aliases — source from temper_theme tokens ─────────────────────────────
local C_TEAL = temper_theme.TEXT_TEAL  -- active/positive status
local C_RED  = temper_theme.TEXT_RED   -- error / expired

-- ── Module ────────────────────────────────────────────────────────────────────
local M = {}

-- Internal state — reset by open()
local _open         = false
local _first_frame  = true
local _input        = ""
local _error_msg    = nil
local _display_name = "Temper"
local _buy_url_tip  = "tempertools.com"
local _popup_id     = "Activate Temper##temper_lic"

M.last_key = ""

-- Configure per-product display name and buy URL tooltip.
-- Call once before the first open(). Idempotent.
function M.configure(opts)
  if opts.display_name then
    _display_name = opts.display_name
    _popup_id     = "Activate " .. _display_name .. "##temper_lic"
  end
  if opts.buy_url then
    _buy_url_tip = opts.buy_url:gsub("^https?://www%.", ""):gsub("^https?://", "")
  end
end

-- Call once when the dialog should appear. Idempotent.
function M.open(ctx)
  if not _open then
    _open        = true
    _first_frame = true
    _input       = ""
    _error_msg   = nil
    reaper.ImGui_OpenPopup(ctx, _popup_id)
  end
end

-- Call from FE after validate_key() rejects the key.
function M.set_error(msg)
  _error_msg = msg or "Invalid key — check your email."
end

-- ── draw(ctx, trial_days) ─────────────────────────────────────────────────────
-- trial_days: integer ≥ 0. 0 or nil = expired. > 0 = trial active.
-- Returns: "activate_requested" | "buy_requested" | "dismissed" | nil
function M.draw(ctx, trial_days)
  if not _open then return nil end

  local R = reaper
  local trial_active = trial_days and trial_days > 0

  -- p_open controls the X close button:
  --   true  → show X button (TRIAL_ACTIVE — user may dismiss)
  --   nil   → no X button (TRIAL_EXPIRED — modal is blocking)
  -- Passing false would close the popup immediately; never do that.
  local p_open = trial_active and true or nil

  local visible, still_open = R.ImGui_BeginPopupModal(
    ctx, _popup_id, p_open,
    R.ImGui_WindowFlags_AlwaysAutoResize()
  )

  -- TRIAL_ACTIVE: user closed via X or Esc — treat as dismissed.
  if trial_active and not still_open then
    _open = false
    return "dismissed"
  end

  -- TRIAL_EXPIRED: Esc can still close a modal; reopen immediately to enforce blocking.
  if not trial_active and not visible then
    R.ImGui_OpenPopup(ctx, _popup_id)
    return nil
  end

  if not visible then return nil end

  -- ── Width anchor ─────────────────────────────────────────────────────────
  -- Dummy with explicit width forces the modal to at least 320px on all platforms.
  R.ImGui_Dummy(ctx, 320, 0)

  -- ── Trial / expired status banner ─────────────────────────────────────────
  if trial_active then
    local plural = trial_days == 1 and "day" or "days"
    R.ImGui_TextColored(ctx, C_TEAL,
      string.format("  %d %s remaining in your trial.", trial_days, plural))
  else
    R.ImGui_TextColored(ctx, C_RED, "  Your trial has expired.")
  end

  R.ImGui_Spacing(ctx)
  R.ImGui_Separator(ctx)
  R.ImGui_Spacing(ctx)

  -- ── Key input section ─────────────────────────────────────────────────────
  R.ImGui_Text(ctx, "Enter your license key:")
  R.ImGui_Spacing(ctx)

  -- Auto-focus on first frame so the user can type immediately.
  if _first_frame then
    R.ImGui_SetKeyboardFocusHere(ctx)
    _first_frame = false
  end

  local input_w = select(1, R.ImGui_GetContentRegionAvail(ctx))
  R.ImGui_SetNextItemWidth(ctx, input_w)

  -- InputTextWithHint shows the placeholder when the field is empty.
  -- buf_size = 19: XXXX-XXXX-XXXX-XXXX = 16 chars + 3 dashes (max valid key length).
  local changed, new_val = R.ImGui_InputTextWithHint(
    ctx, "##lic_key_input", "XXXX-XXXX-XXXX-XXXX", _input,
    R.ImGui_InputTextFlags_CharsUppercase()
  )
  if changed then
    _input    = new_val
    _error_msg = nil  -- clear error as user edits
  end

  -- Error feedback (only shown after a failed activation attempt)
  if _error_msg then
    R.ImGui_Spacing(ctx)
    R.ImGui_TextColored(ctx, C_RED, _error_msg)
  end

  R.ImGui_Spacing(ctx)

  -- ── Action buttons row ────────────────────────────────────────────────────
  local result = nil

  -- [Activate] — teal accent, bold font, primary CTA
  temper_theme.push_teal_btn(ctx)
  R.ImGui_PushFont(ctx, temper_theme.font_bold, 13)
  if R.ImGui_Button(ctx, "Activate##lic_act") then
    M.last_key = _input
    result     = "activate_requested"
    -- FE validates M.last_key; calls set_error() on failure or stops calling draw() on success.
  end
  R.ImGui_PopFont(ctx)
  R.ImGui_PopStyleColor(ctx, 4)  -- push_teal_btn: Button, ButtonHovered, ButtonActive, Text

  R.ImGui_SameLine(ctx)

  -- [Buy License] — neutral, fires event so FE can open browser
  temper_theme.push_neutral_btn(ctx)
  if R.ImGui_Button(ctx, "Buy License##lic_buy") then
    if result == nil then result = "buy_requested" end
  end
  if R.ImGui_IsItemHovered(ctx) then
    R.ImGui_SetTooltip(ctx, "Opens " .. _buy_url_tip .. " in your browser.")
  end
  R.ImGui_PopStyleColor(ctx, 3)  -- push_neutral_btn: Button, ButtonHovered, ButtonActive

  -- [Continue Trial] — only in TRIAL_ACTIVE, flush-fill width
  if trial_active then
    R.ImGui_Spacing(ctx)
    local btn_w = select(1, R.ImGui_GetContentRegionAvail(ctx))
    temper_theme.push_neutral_btn(ctx)
    if R.ImGui_Button(ctx, "Continue Trial##lic_cont", btn_w, 0) then
      _open = false
      R.ImGui_CloseCurrentPopup(ctx)
      -- Assign result only if no other button fired this frame.
      if result == nil then result = "dismissed" end
    end
    R.ImGui_PopStyleColor(ctx, 3)  -- push_neutral_btn: Button, ButtonHovered, ButtonActive
  end

  -- ── Footer hint ───────────────────────────────────────────────────────────
  R.ImGui_Spacing(ctx)
  R.ImGui_TextDisabled(ctx, "Keys are delivered to your purchase confirmation email.")

  R.ImGui_EndPopup(ctx)

  return result
end

return M
