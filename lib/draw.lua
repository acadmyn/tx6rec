-- drawing into a 128x64 Lua framebuffer, sent with one screen.poke per frame.
-- Each screen.* call takes a lock shared with the screen thread, so a frame of
-- hundreds of calls could disturb a running script's timing (lagom measured
-- 10-25 ms). Same 3x5 font as lagom.

local D = {}

local FB = {}
for k = 1, 128 * 64 do FB[k] = 0 end

-- rows top to bottom, 3 bits each, 4 px advance
local GLYPHS = {
  A = "010101111101101", B = "110101110101110", C = "011100100100011", D = "110101101101110",
  E = "111100110100111", F = "111100110100100", G = "011100101101011", H = "101101111101101",
  I = "111010010010111", J = "001001001101010", K = "101101110101101", L = "100100100100111",
  M = "101111111101101", N = "110101101101101", O = "010101101101010", P = "110101110100100",
  Q = "010101101110011", R = "110101110101101", S = "011100010001110", T = "111010010010010",
  U = "101101101101111", V = "101101101101010", W = "101101111111101", X = "101101010101101",
  Y = "101101010010010", Z = "111001010100111",
  ["0"] = "111101101101111", ["1"] = "010110010010111", ["2"] = "110001010100111",
  ["3"] = "110001010001110", ["4"] = "101101111001001", ["5"] = "111100110001110",
  ["6"] = "011100111101111", ["7"] = "111001010010010", ["8"] = "111101111101111",
  ["9"] = "111101111001110",
  [" "] = "000000000000000", ["."] = "000000000000010", [":"] = "000010000010000",
  ["-"] = "000000111000000", ["+"] = "000010111010000", ["/"] = "001001010100100",
  ["?"] = "110001010000010", ["_"] = "000000000000111", ["!"] = "010010010000010",
  [","] = "000000000010100", ["'"] = "010010000000000", ["("] = "010100100100010",
  [")"] = "010001001001010", [">"] = "100010001010100", ["<"] = "001010100010001",
}
local GLYPH_PX = {}
for ch, bits in pairs(GLYPHS) do
  local list = {}
  for r = 0, 4 do
    for c = 0, 2 do
      if bits:sub(r * 3 + c + 1, r * 3 + c + 1) == "1" then list[#list + 1] = {c, r} end
    end
  end
  GLYPH_PX[ch] = list
end

function D.clear()
  for k = 1, 128 * 64 do FB[k] = 0 end
end

function D.rect(x, y, w, h, lvl)
  x, y = math.floor(x), math.floor(y)
  local x0, x1 = math.max(0, x), math.min(127, x + w - 1)
  for j = math.max(0, y), math.min(63, y + h - 1) do
    local row = j * 128 + 1
    for i = x0, x1 do FB[row + i] = lvl end
  end
end

function D.px(x, y, lvl)
  if x >= 0 and x < 128 and y >= 0 and y < 64 then FB[y * 128 + x + 1] = lvl end
end

function D.width(s, scale)
  scale = scale or 1
  local n = #tostring(s)
  return n > 0 and (n * 4 - 1) * scale or 0
end

-- glyph top-left at (x, y); align "l" (default), "c" or "r"
function D.text(x, y, s, lvl, align, scale)
  s = string.upper(tostring(s))
  scale = scale or 1
  if align == "r" then x = x - D.width(s, scale)
  elseif align == "c" then x = x - D.width(s, scale) // 2 end
  x, y = math.floor(x), math.floor(y)
  for k = 1, #s do
    local g = GLYPH_PX[s:sub(k, k)] or GLYPH_PX["?"]
    for n = 1, #g do
      if scale == 1 then D.px(x + g[n][1], y + g[n][2], lvl)
      else D.rect(x + g[n][1] * scale, y + g[n][2] * scale, scale, scale, lvl) end
    end
    x = x + 4 * scale
  end
end

function D.flush()
  screen.poke(0, 0, 128, 64, string.char(table.unpack(FB)))
  screen.update()
end

return D
