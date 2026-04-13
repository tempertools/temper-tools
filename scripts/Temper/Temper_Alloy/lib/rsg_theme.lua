-- ============================================================
-- rsg_theme.lua -- Temper shared GUI theme (Spectral Core)
-- ============================================================
-- Usage: dofile(reaper.GetResourcePath() .. "/Scripts/Temper/lib/rsg_theme.lua")
--   rsg_theme.attach_fonts(ctx)   -- call once after CreateContext, before first Begin
--   local n = rsg_theme.push(ctx) -- call at top of each defer frame
--   rsg_theme.pop(ctx, n)         -- call at bottom of each defer frame
--
-- This module sets the global `rsg_theme` table so dofile()-based loading works.
-- ============================================================

-- Spectral Core full palette -- exported as rsg_theme.SC for component-level use.
-- No 1px borders; grouping via background color shifts only (no-line rule).
local SC = {
  -- Surfaces
  WINDOW       = 0x0E0E10FF,  -- surface_container_lowest (main bg)
  PANEL        = 0x1E1E20FF,  -- surface_container (child regions, inputs)
  PANEL_HIGH   = 0x282828FF,  -- surface_container_high (title bar, row headers)
  PANEL_TOP    = 0x323232FF,  -- surface_container_highest (inactive toggles, pills)
  HOVER_LIST   = 0x39393BFF,  -- surface_bright (hover states, dropdowns)
  -- Primary (teal)
  PRIMARY      = 0x26A69AFF,
  PRIMARY_LT   = 0x66D9CCFF,  -- gradient highlight (top of ROLL button)
  PRIMARY_HV   = 0x30B8ACFF,
  PRIMARY_AC   = 0x1A8A7EFF,
  -- Tertiary (coral -- UNIQ mode, accent)
  TERTIARY     = 0xDA7C5AFF,
  TERTIARY_HV  = 0xE08A6AFF,
  TERTIARY_AC  = 0xC46A4AFF,
  -- Manual markers (warm gold -- distinct from teal/coral)
  MANUAL_MARK  = 0xF2C94CFF,
  -- Text
  TEXT_ON      = 0xDEDEDEFF,  -- on_surface (body text)
  TEXT_MUTED   = 0xBCC9C6FF,  -- on_surface_variant (disabled, labels)
  -- Semantic
  OMIT_BG      = 0x380D00FF,  -- OMIT field background (orange-dark, board correction RSG-137)
  OMIT_HV      = 0x4A1200FF,
  ERROR_RED    = 0xC0392BFF,
  FRESHLY_EMBEDDED = 0x4CAF50FF,  -- bright green for this-session embeds
  DEL_BTN      = 0x8B2020FF,  -- delete button (visible red on dark panels)
  DEL_HV       = 0xC0392BFF,  -- delete hover (bright red)
  DEL_AC       = 0x601515FF,  -- delete active (pressed)

  -- Interactive state (promoted from ad-hoc hex in Vortex Mini)
  TEXT_OFF        = 0x505050FF,  -- toggle OFF text (muted grey)
  HOVER_INACTIVE  = 0x2A2A2CFF,  -- inactive toggle hover
  ACTIVE_DARK     = 0x141416FF,  -- button active/pressed (very dark)
  ACTIVE_DARKER   = 0x161618FF,  -- inactive toggle active (near-black)
  TITLE_BAR       = 0x1A1A1CFF,  -- custom title bar background
  BORDER_INPUT    = 0x505055FF,  -- visible input field border
  BORDER_SUBTLE   = 0x50505066,  -- semi-transparent button outline
  ICON_DISABLED   = 0x606060FF,  -- disabled icon grey
  HOVER_GHOST     = 0xFFFFFF1A,  -- disabled button hover (white ghost)
  ACTIVE_GHOST    = 0x0000001F,  -- disabled button active (black ghost)
}

-- Global color slots pushed by push() -- maps semantic ImGui slots to Spectral Core.
local COLORS = {
  -- Surfaces
  SURFACE_WINDOW   = SC.PANEL,   -- gap lines match panel grey (not black)
  SURFACE_CHILD    = SC.PANEL,
  SURFACE_POPUP    = SC.PANEL,
  SURFACE_FRAME    = SC.WINDOW,  -- input fields stay dark for contrast
  SURFACE_FRAME_HV = SC.HOVER_LIST,
  -- No-line rule: borders match window bg so they are invisible
  BORDER           = SC.PANEL,
  BORDER_STRONG    = SC.PANEL,

  -- Text
  TEXT_PRIMARY  = SC.TEXT_ON,
  TEXT_DISABLED = SC.TEXT_MUTED,

  -- Selection / header
  HEADER         = SC.PANEL_HIGH,   -- selected item bg (subtle lift)
  HEADER_HOVERED = SC.HOVER_LIST,

  -- Check mark
  CHECKMARK = SC.PRIMARY,

  -- Table rows
  TABLE_ROW     = SC.PANEL,
  TABLE_ROW_ALT = SC.PANEL_HIGH,

  -- Title bar (ImGui native title bar; Mini uses NoTitleBar so this is fallback only)
  TITLE           = SC.PANEL_HIGH,
  TITLE_ACTIVE    = SC.PANEL_HIGH,
  TITLE_COLLAPSED = SC.WINDOW,

  -- Default Button (neutral grey -- teal applied per-widget for active actions)
  BUTTON         = SC.PANEL,
  BUTTON_HOVERED = SC.HOVER_LIST,
  BUTTON_ACTIVE  = SC.ACTIVE_DARK,

  -- Semantic / status (kept for legacy references)
  COL_RED   = SC.ERROR_RED,
  COL_AMBER = SC.TERTIARY,   -- was amber; now tertiary coral per Spectral Core
  COL_TEAL  = SC.PRIMARY,
}

-- Number of ImGui_Col slots pushed by push(). Used by pop().
local THEME_COLOR_COUNT = 31
-- Number of ImGui_StyleVar slots pushed by push(). Always popped inside pop().
local THEME_VAR_COUNT   = 5

local function push(ctx)
  local R = reaper
  -- Style colors (21)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_WindowBg(),          COLORS.SURFACE_WINDOW)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ChildBg(),           COLORS.SURFACE_CHILD)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_PopupBg(),           COLORS.SURFACE_POPUP)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Border(),            COLORS.BORDER)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Text(),              COLORS.TEXT_PRIMARY)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_TextDisabled(),      COLORS.TEXT_DISABLED)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_FrameBg(),           COLORS.SURFACE_FRAME)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_FrameBgHovered(),    COLORS.SURFACE_FRAME_HV)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_FrameBgActive(),     COLORS.SURFACE_FRAME)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Button(),            COLORS.BUTTON)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonHovered(),     COLORS.BUTTON_HOVERED)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ButtonActive(),      COLORS.BUTTON_ACTIVE)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_Header(),            COLORS.HEADER)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_HeaderHovered(),     COLORS.HEADER_HOVERED)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_HeaderActive(),      COLORS.HEADER)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_CheckMark(),         COLORS.CHECKMARK)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_SliderGrab(),        SC.PRIMARY)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_SliderGrabActive(),  SC.PRIMARY_LT)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_TableBorderLight(),  COLORS.BORDER)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_TableBorderStrong(), COLORS.BORDER_STRONG)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_TableRowBg(),        COLORS.TABLE_ROW)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_TableRowBgAlt(),     COLORS.TABLE_ROW_ALT)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_TitleBg(),           COLORS.TITLE)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_TitleBgActive(),     COLORS.TITLE_ACTIVE)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_TitleBgCollapsed(),  COLORS.TITLE_COLLAPSED)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ResizeGrip(),        SC.PRIMARY_AC)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ResizeGripHovered(),  SC.PRIMARY)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_ResizeGripActive(),   SC.PRIMARY_LT)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_SeparatorHovered(),   SC.PRIMARY)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_SeparatorActive(),    SC.PRIMARY_LT)
  R.ImGui_PushStyleColor(ctx, R.ImGui_Col_TextSelectedBg(),    0x26A69A80) -- teal at 50% alpha
  -- Style vars (5)
  R.ImGui_PushStyleVar(ctx, R.ImGui_StyleVar_WindowPadding(),  8, 8)
  R.ImGui_PushStyleVar(ctx, R.ImGui_StyleVar_ItemSpacing(),    6, 4)
  R.ImGui_PushStyleVar(ctx, R.ImGui_StyleVar_WindowRounding(), 6)
  R.ImGui_PushStyleVar(ctx, R.ImGui_StyleVar_FrameRounding(),  4)
  R.ImGui_PushStyleVar(ctx, R.ImGui_StyleVar_GrabRounding(),   4)
  return THEME_COLOR_COUNT
end

local function pop(ctx, n)
  reaper.ImGui_PopStyleVar(ctx, THEME_VAR_COUNT)
  reaper.ImGui_PopStyleColor(ctx, n or THEME_COLOR_COUNT)
end

-- attach_fonts: create and attach fonts used for primary-action labels.
-- Must be called once after ImGui_CreateContext and before the first Begin().
-- After this call, rsg_theme.font_regular, font_bold, and font_hero are valid.
local font_regular_handle = nil
local font_bold_handle = nil
local font_hero_handle = nil

local function attach_fonts(ctx)
  -- ImGui_CreateFont(family, flags) -- size is NOT set here; it is passed to PushFont at render time.
  -- ImGui_FontFlags_Bold() requests the bold variant from the platform font system.
  font_regular_handle = reaper.ImGui_CreateFont("sans-serif", reaper.ImGui_FontFlags_None())
  reaper.ImGui_Attach(ctx, font_regular_handle)
  font_bold_handle = reaper.ImGui_CreateFont("sans-serif", reaper.ImGui_FontFlags_Bold())
  reaper.ImGui_Attach(ctx, font_bold_handle)
  -- Hero font: same bold flag at larger render size (18px passed in PushFont calls).
  font_hero_handle = reaper.ImGui_CreateFont("sans-serif", reaper.ImGui_FontFlags_Bold())
  reaper.ImGui_Attach(ctx, font_hero_handle)
end

-- ============================================================
-- Public API
-- ============================================================

-- Expose as global `rsg_theme` so dofile()-based loading works.
rsg_theme = {
  -- Theme push/pop (call every defer frame)
  push   = push,
  pop    = pop,
  -- Alias used by Section 8 of docs/DESIGN_SYSTEM.md
  apply  = push,

  -- Font setup (call once after CreateContext, before first Begin)
  attach_fonts = attach_fonts,

  -- Color constants (re-exported for scripts that need semantic references)
  colors = COLORS,

  -- Spectral Core full palette (for component-level use in scripts)
  SC = SC,

  -- Semantic text color aliases (for activation dialog and similar)
  TEXT_TEAL = SC.PRIMARY,
  TEXT_RED  = SC.ERROR_RED,

  -- Button color helpers (push_teal_btn: 4 colors; push_neutral_btn: 3 colors)
  push_teal_btn = function(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        SC.PRIMARY)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), SC.PRIMARY_HV)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  SC.PRIMARY_AC)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          0x0A0A0AFF)  -- dark text on teal
  end,
  push_neutral_btn = function(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        SC.PANEL_TOP)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), SC.HOVER_LIST)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  SC.ACTIVE_DARK)
  end,

  -- Font handles (valid after attach_fonts has been called)
  -- Usage: if rsg_theme.font_regular then reaper.ImGui_PushFont(ctx, rsg_theme.font_regular, 13) end
  -- Usage: if rsg_theme.font_bold then reaper.ImGui_PushFont(ctx, rsg_theme.font_bold, 13) end
  -- Usage: if rsg_theme.font_hero then reaper.ImGui_PushFont(ctx, rsg_theme.font_hero, 18) end
  font_regular = nil,  -- populated lazily; read via metatable below
  font_bold = nil,  -- populated lazily; read via metatable below
  font_hero = nil,  -- Arial Black 18px; populated lazily via metatable
}

-- Expose font handles through a metatable so they reflect lazy-initialized values.
setmetatable(rsg_theme, {
  __index = function(t, k)
    if k == "font_regular" then return font_regular_handle end
    if k == "font_bold" then return font_bold_handle end
    if k == "font_hero" then return font_hero_handle end
  end
})

return rsg_theme
