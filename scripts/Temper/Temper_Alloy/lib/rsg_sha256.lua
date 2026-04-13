-- rsg_sha256.lua
-- Pure Lua 5.3 SHA-256 and HMAC-SHA256 implementation.
-- No external dependencies. Compatible with vanilla REAPER Lua 5.3+.
--
-- Public API:
--   sha256.hash(msg)          -> lowercase hex string (64 chars)
--   sha256.hmac(key, msg)     -> lowercase hex string (64 chars)
--
-- MIT License. Adapted from public-domain SHA-256 references.

local M = {}

-- SHA-256 constants: first 32 bits of the fractional parts of cube roots of primes 2..311
local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

-- Initial hash values: first 32 bits of fractional parts of square roots of primes 2..19
local H0 = {
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
  0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
}

local MASK32 = 0xffffffff

local function rrot(x, n)
  return ((x >> n) | (x << (32 - n))) & MASK32
end

local function u32(x)
  return x & MASK32
end

-- Process a single 64-byte block. h is an 8-element array of uint32.
local function compress(h, block)
  local w = {}
  for i = 1, 16 do
    local o = (i - 1) * 4
    w[i] = (block:byte(o + 1) << 24) |
            (block:byte(o + 2) << 16) |
            (block:byte(o + 3) <<  8) |
             block:byte(o + 4)
    w[i] = u32(w[i])
  end
  for i = 17, 64 do
    local s0 = rrot(w[i - 15], 7) ~ rrot(w[i - 15], 18) ~ (w[i - 15] >> 3)
    local s1 = rrot(w[i -  2], 17) ~ rrot(w[i -  2], 19) ~ (w[i -  2] >> 10)
    w[i] = u32(w[i - 16] + s0 + w[i - 7] + s1)
  end

  local a, b, c, d, e, f, g, hh =
    h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]

  for i = 1, 64 do
    local S1  = rrot(e, 6) ~ rrot(e, 11) ~ rrot(e, 25)
    local ch  = (e & f) ~ ((~e) & g)
    local tmp1 = u32(hh + S1 + ch + K[i] + w[i])
    local S0  = rrot(a, 2) ~ rrot(a, 13) ~ rrot(a, 22)
    local maj = (a & b) ~ (a & c) ~ (b & c)
    local tmp2 = u32(S0 + maj)

    hh = g; g = f; f = e
    e  = u32(d + tmp1)
    d  = c; c = b; b = a
    a  = u32(tmp1 + tmp2)
  end

  h[1] = u32(h[1] + a); h[2] = u32(h[2] + b)
  h[3] = u32(h[3] + c); h[4] = u32(h[4] + d)
  h[5] = u32(h[5] + e); h[6] = u32(h[6] + f)
  h[7] = u32(h[7] + g); h[8] = u32(h[8] + hh)
end

-- Pad message per SHA-256 spec and return array of 64-byte block strings.
local function pad(msg)
  local len = #msg
  local bit_len = len * 8
  -- Append 0x80 byte, then zeros, then 64-bit big-endian bit length.
  -- Total padded length must be congruent to 0 mod 64.
  local pad_len = 64 - ((len + 9) % 64)
  if pad_len == 64 then pad_len = 0 end
  msg = msg .. "\x80" .. string.rep("\0", pad_len)
       .. string.char(
            0, 0, 0, 0,  -- upper 32 bits of bit_len (fits in lower 32 for practical messages)
            (bit_len >> 24) & 0xff,
            (bit_len >> 16) & 0xff,
            (bit_len >>  8) & 0xff,
             bit_len        & 0xff
          )
  local blocks = {}
  for i = 1, #msg, 64 do
    blocks[#blocks + 1] = msg:sub(i, i + 63)
  end
  return blocks
end

local function digest(msg)
  local h = {}
  for i = 1, 8 do h[i] = H0[i] end

  for _, block in ipairs(pad(msg)) do
    compress(h, block)
  end

  return string.format(
    "%08x%08x%08x%08x%08x%08x%08x%08x",
    h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
  )
end

-- hash(msg: string) -> hex string
function M.hash(msg)
  assert(type(msg) == "string", "sha256.hash: msg must be a string")
  return digest(msg)
end

-- hmac(key: string, msg: string) -> hex string
-- HMAC-SHA256 per RFC 2104.
function M.hmac(key, msg)
  assert(type(key) == "string", "sha256.hmac: key must be a string")
  assert(type(msg) == "string", "sha256.hmac: msg must be a string")

  local block = 64
  -- Keys longer than block size are hashed first.
  if #key > block then
    -- Convert hex digest back to binary for use as key.
    local hex = digest(key)
    key = (hex:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
  end
  -- Keys shorter than block size are zero-padded.
  if #key < block then
    key = key .. string.rep("\0", block - #key)
  end

  local o_pad = key:gsub(".", function(c) return string.char(string.byte(c) ~ 0x5c) end)
  local i_pad = key:gsub(".", function(c) return string.char(string.byte(c) ~ 0x36) end)

  -- Inner hash: convert hex back to binary for outer hash input.
  local inner_hex = digest(i_pad .. msg)
  local inner_bin = inner_hex:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end)
  return digest(o_pad .. inner_bin)
end

return M
