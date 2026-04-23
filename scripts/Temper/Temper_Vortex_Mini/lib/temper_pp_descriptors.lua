-- temper_pp_descriptors.lua — Shared property descriptors for Paste Properties inheritance.
-- Used by Temper Vortex and Temper Vortex Mini.
--
-- Take descriptors: D_STARTOFFS intentionally omitted — source-material-specific.
-- D_PLAYRATE is captured but only applied in LOCK mode (same WAV, rate is valid).
-- Envelope entries are injected via state-chunk surgery (is_envelope = true).
--
-- Item descriptors: D_POSITION and D_LENGTH deliberately omitted — variant
-- placement must not be overridden by the captured source position/length.

local M = {}

M.take = {
  { key = "t_vol",       parmname = "D_VOL"      },
  { key = "t_pan",       parmname = "D_PAN"      },
  { key = "t_pitch",     parmname = "D_PITCH"    },
  { key = "t_rate",      parmname = "D_PLAYRATE", lock_only = true },
  { key = "t_chan",       parmname = "I_CHANMODE" },
  { key = "t_plaw",      parmname = "I_PANLAW"   },
  { key = "t_name",      parmname = "P_NAME",   is_string   = true },
  { key = "t_env_vol",   env_name  = "Volume",  is_envelope = true },
  { key = "t_env_pan",   env_name  = "Pan",     is_envelope = true },
  { key = "t_env_pitch", env_name  = "Pitch",   is_envelope = true },
}

M.item = {
  { key = "i_vol",  parmname = "D_VOL"          },
  { key = "i_mute", parmname = "B_MUTE"         },
  { key = "i_lock", parmname = "C_LOCK"         },
  { key = "i_loop", parmname = "B_LOOPSRC"      },
  { key = "i_fis",  parmname = "C_FADEINSHAPE"  },
  { key = "i_fos",  parmname = "C_FADEOUTSHAPE" },
  { key = "i_fil",  parmname = "D_FADEINLEN"    },
  { key = "i_fol",  parmname = "D_FADEOUTLEN"   },
  { key = "i_lpf",  parmname = "I_FADELPF"      },
  { key = "i_snap", parmname = "D_SNAPOFFSET"   },
  -- i_fx handled separately via state-chunk surgery
}

return M
