-- tx6rec: record every TX-6 input as its own track
--
-- SYSTEM > MODS > TX6REC. Home: E2 picks REC / SETUP / TAKES, K3 acts,
-- K2 back to MODS. Inside SETUP and TAKES: E2 scroll, E3 change, K3 act, K2 back.
--
-- lib/tx6d.py reads the TX-6 while this page is open (meters) or a take runs,
-- lib/rec.sh splits a finished take into files. Both run outside matron, so a
-- take keeps going while scripts load and never touches the clock or audio engine.

local mod = require 'core/mods'
local textentry = require 'textentry'

local NAME = mod.this_name or "tx6rec"
local D = require(NAME .. "/lib/draw")

local LIB = _path.code .. NAME .. "/lib/"
local STATE = _path.data .. NAME .. "/"
local TAKES = _path.audio .. "tx6/"
local SHM = "/dev/shm/" .. NAME .. "/"
local MODES = {"stereo", "mono", "2xmono", "off"}
local MODE_LABEL = {stereo = "stereo", mono = "mono", ["2xmono"] = "2x mono", off = "off"}
local HN = 110                 -- tape columns (one per 80 ms level window)
local now = util.time

--
-- settings (read by rec.sh when a take is split)
--

local S = {name = "tx6", modes = {"stereo", "stereo", "stereo", "stereo", "stereo", "stereo"}, skip = true}

local function read_kv(path)
  local t = {}
  local f = io.open(path, "r")
  if f then
    for line in f:lines() do
      local k, v = line:match("^(%w+)=(.*)$")
      if k then t[k] = v end
    end
    f:close()
  end
  return t
end

local function load_settings()
  local t = read_kv(STATE .. "settings")
  if t.name and t.name ~= "" then S.name = t.name end
  for i = 1, 6 do
    local m = t["mode" .. i]
    if MODE_LABEL[m] then S.modes[i] = m end
  end
  if t.skip then S.skip = t.skip == "1" end
end

local function save_settings()
  local f = io.open(STATE .. "settings", "w")
  if not f then return end
  f:write("name=" .. S.name .. "\n")
  for i = 1, 6 do f:write("mode" .. i .. "=" .. S.modes[i] .. "\n") end
  f:write("skip=" .. (S.skip and "1" or "0") .. "\n")
  f:close()
end

--
-- engine (tx6d.py) and files
--

local function run(cmd) norns.system_cmd(cmd, function() end) end

local function alive()
  local f = io.open(SHM .. "pid", "r")
  if not f then return false end
  local pid = f:read("l")
  f:close()
  local c = pid and io.open("/proc/" .. pid .. "/cmdline", "r")
  if not c then return false end
  local s = c:read("a")
  c:close()
  return s:find("tx6d.py", 1, true) ~= nil
end

local function tx6_present()
  local f = io.open("/proc/asound/cards", "r")
  if not f then return false end
  local s = f:read("a")
  f:close()
  return s:find("%[TX6%s*%]") ~= nil
end

local function touch(path)
  local f = io.open(path, "w")
  if f then f:close() end
end

local function exists(path)
  local f = io.open(path, "r")
  if f then f:close() return true end
  return false
end

-- level byte (0-127, top byte of the sample) -> 0..1 on a 42 dB scale
local A = {[0] = 0}
for p = 1, 127 do A[p] = util.clamp((20 * math.log(p / 127, 10) + 42) / 42, 0, 1) end

--
-- runtime state
--

local st = {
  page = "home", sel = 0, srow = 1, trow = 1,
  present = false, alive = false, status = {}, split = {},
  lv = {}, clip = {}, seq = nil, recording = false,
  hist = {}, hpos = 0, hcount = 0,
  starting = nil, stopping = nil, last_launch = -10, last_hb = -10, last_probe = -10,
  free = nil, takes = {}, msg = nil, msg_t = -10, typing = false, recovering = false,
}
for ch = 1, 12 do
  st.lv[ch] = 0
  st.hist[ch] = {}
  for k = 1, HN do st.hist[ch][k] = 0 end
end
for i = 1, 6 do st.clip[i] = -10 end

_tx6rec = {st = st, S = S} -- for poking from the REPL

local function flash(s) st.msg, st.msg_t = s, now() end

local function launch()
  st.last_launch = now()
  run(string.format("mkdir -p '%s' && setsid python3 '%stx6d.py' '%s' '%s' '%srec.sh' >/dev/null 2>&1 </dev/null &",
    SHM, LIB, SHM, STATE, LIB))
end

local function refresh_free()
  norns.system_cmd("df -B1 --output=avail '" .. _path.audio .. "' | tail -1", function(out)
    st.free = tonumber(out and out:match("%d+"))
  end)
end

--
-- takes on disk
--

local function wav_info(path)
  local f = io.open(path, "rb")
  if not f then return 0, 2 end
  local h = f:read(24)
  local size = f:seek("end")
  f:close()
  local ch = (h and #h >= 24) and (h:byte(23) + h:byte(24) * 256) or 2
  return size, ch
end

local function scan_takes()
  local list, by = {}, {}
  for _, path in ipairs(norns.system_glob(TAKES .. "*/*_in*.wav") or {}) do
    local dir, file = path:match("^(.*/)([^/]+)$")
    local base, n = file:match("^(.*)_in(%d)[LR]?%.wav$")
    if base then
      local key = dir .. base
      local t = by[key]
      if not t then
        local name, y, mo, d, h, mi, rest = base:match("^(.*)_(%d%d%d%d)%-(%d%d)%-(%d%d)_(%d%d)(%d%d)(.*)$")
        t = {base = base, dir = dir, files = {}, ins = {}, bytes = 0, len = 0,
             name = name or base, when = name and (mo .. "-" .. d .. " " .. h .. ":" .. mi) or "",
             sort = name and (y .. mo .. d .. h .. mi .. rest) or base}
        by[key] = t
        list[#list + 1] = t
      end
      local size, ch = wav_info(path)
      t.files[#t.files + 1] = path
      t.ins[tonumber(n)] = true
      t.bytes = t.bytes + size
      t.len = math.max(t.len, (size - 44) / (48000 * 3 * math.max(1, ch)))
    end
  end
  table.sort(list, function(a, b) return a.sort > b.sort end)
  st.takes = list
  st.trow = util.clamp(st.trow, 1, math.max(1, #list))
end

local function delete_take(t)
  for _, path in ipairs(t.files) do os.remove(path) end
  os.remove(t.dir) -- only succeeds once the folder is empty
end

--
-- recording
--

local function new_base()
  local base = S.name .. "_" .. os.date("%Y-%m-%d_%H%M")
  local dir = TAKES .. S.name .. "/"
  local b, k = base, 1
  while #(norns.system_glob(dir .. b .. "*") or {}) > 0 do
    k = k + 1
    b = base .. "-" .. k
  end
  return dir .. b .. ".raw"
end

local function start_take()
  if not st.present then flash("plug in the tx-6") return end
  -- the engine may still be starting (python takes a few seconds on a busy
  -- norns); it picks the request up once it runs, or update() cancels it
  if not exists(SHM) then util.make_dir(SHM) end
  local f = io.open(SHM .. "rec", "w")
  if not f then flash("can't start") return end
  f:write(new_base())
  f:close()
  st.starting = now()
end

local function stop_take()
  os.remove(SHM .. "rec")
  st.stopping = now()
end

--
-- update (15 fps while the page is open)
--

local function update()
  local t = now()
  if t - st.last_probe > 0.5 then
    st.last_probe = t
    st.present = tx6_present()
    st.alive = alive()
    -- a second launch is harmless (tx6d.py holds a lock), just wasteful
    if st.present and not st.alive and t - st.last_launch > 8 then launch() end
  end
  if st.alive and t - st.last_hb > 2 then st.last_hb = t; touch(SHM .. "hb") end

  st.status = st.alive and read_kv(SHM .. "status") or {}
  st.split = read_kv(SHM .. "split")
  local was = st.recording
  st.recording = st.status.state == "recording"
  if st.recording and not was then st.hpos, st.hcount = 0, 0 end
  if st.recording then
    st.starting = nil
  elseif st.starting and t - st.starting > 8 then
    -- never started (TX-6 gone, engine failing): don't leave a request behind
    -- that would start a take by surprise later
    st.starting = nil
    os.remove(SHM .. "rec")
    flash("could not start")
  end
  if not st.recording or (st.stopping and t - st.stopping > 3) then st.stopping = nil end

  -- meters and tape
  for ch = 1, 12 do st.lv[ch] = st.lv[ch] * 0.75 end
  local f = st.alive and io.open(SHM .. "levels", "r")
  if f then
    local line = f:read("l")
    f:close()
    local seq = line and line:match("^(%d+)")
    if seq and seq ~= st.seq then
      st.seq = seq
      local ch, push = 0, st.recording
      if push then
        st.hpos = st.hpos % HN + 1
        st.hcount = math.min(HN, st.hcount + 1)
      end
      for p in line:gmatch("%s(%d+)") do
        ch = ch + 1
        if ch > 12 then break end
        local v = tonumber(p)
        local a = A[math.min(127, v)]
        if a > st.lv[ch] then st.lv[ch] = a end
        if v >= 127 then st.clip[(ch + 1) // 2] = t end
        if push then st.hist[ch][st.hpos] = a end
      end
    end
  end
  if not st.alive then for ch = 1, 12 do st.lv[ch] = 0 end end

  -- a recorder that died mid-take (matron restart) leaves raw audio: split it
  if st.status.state == "recording" and not st.alive and not st.recovering then
    st.recovering = true
    run(string.format("setsid bash '%srec.sh' recover '%s' '%s' '%s' >/dev/null 2>&1 </dev/null &",
      LIB, STATE, SHM, TAKES))
  end
end

--
-- drawing
--

local function hms(s)
  s = math.max(0, math.floor(s))
  return string.format("%d:%02d:%02d", s // 3600, (s // 60) % 60, s % 60)
end

local function ms(s)
  s = math.max(0, math.floor(s))
  if s >= 3600 then return hms(s) end
  return string.format("%d:%02d", s // 60, s % 60)
end

local function size_str(b)
  if b >= 1e9 then return string.format("%.1f gb", b / 1e9) end
  return string.format("%d mb", math.max(1, b // 1e6))
end

local function blink() return now() % 1 < 0.5 end

local function header(title)
  local t = now()
  D.text(0, 1, title, 8)
  local sp = st.split
  if not st.present then
    D.text(127, 1, "no tx-6", 4, "r")
  elseif st.starting then
    D.text(127, 1, "starting", 8, "r")
  elseif st.stopping then
    D.text(127, 1, "stopping", 8, "r")
  elseif st.recording then
    local s = hms(os.time() - (tonumber(st.status.start) or os.time()))
    D.text(127, 1, s, 15, "r")
    if blink() then D.rect(127 - D.width(s) - 5, 2, 3, 3, 15) end
  elseif sp.state == "processing" then
    D.text(127, 1, sp.prog ~= "" and ("saving " .. sp.prog) or "saving", 8, "r")
  elseif sp.state == "done" and os.time() - (tonumber(sp.t) or 0) < 6 then
    D.text(127, 1, sp.msg or "", 8, "r")
  elseif t - st.msg_t < 3 then
    D.text(127, 1, st.msg, 8, "r")
  elseif not st.alive then
    D.text(127, 1, "starting", 4, "r")
  else
    D.text(127, 1, "ready", 4, "r")
  end
end

local function footer()
  local items = {st.recording and "stop" or "rec", "setup", "takes"}
  for k = 0, 2 do
    local s = items[k + 1]
    local w = D.width(s)
    local x = k == 0 and 1 or (k == 1 and 64 - w // 2 or 126 - w)
    if st.sel == k then
      D.rect(x - 2, 57, w + 4, 7, 15)
      D.text(x, 58, s, 0)
    else
      D.text(x, 58, s, 5)
    end
  end
end

local function draw_tape()
  local t = now()
  for i = 1, 6 do
    local y0, mode = 9 + (i - 1) * 7, S.modes[i]
    local yc, off = y0 + 3, mode == "off"
    local L, R = st.hist[2 * i - 1], st.hist[2 * i]
    if t - st.clip[i] < 1.2 then
      D.rect(0, y0, 5, 7, 15)
      D.text(1, y0 + 1, i, 0)
    else
      D.text(1, y0 + 1, i, off and 3 or 8)
    end
    local n = st.hcount
    if st.recording and not off then
      for x = 6, 116 - n do D.px(x, yc, 2) end
      for k = 1, n do
        local idx = (st.hpos - n + k - 1) % HN + 1
        local x = 117 - n + k - 1
        local a, b = L[idx], R[idx]
        if mode == "mono" then
          local d = math.floor(a * 3 + 0.5)
          D.rect(x, yc - d, 1, d * 2 + 1, 4 + math.floor(a * 11))
        else
          local dl, dr = math.floor(a * 3 + 0.5), math.floor(b * 3 + 0.5)
          D.rect(x, yc - dl, 1, dl + 1, 4 + math.floor(a * 11))
          D.rect(x, yc, 1, dr + 1, 4 + math.floor(b * 11))
        end
      end
    else
      for x = 6, 116, off and 3 or 1 do D.px(x, yc, off and 1 or 2) end
    end
    D.rect(118, y0, 1, 6, st.recording and 6 or 3) -- tape head
    local bl = off and 3 or 13
    local a, b = st.lv[2 * i - 1], st.lv[2 * i]
    if mode == "mono" then
      local h = math.floor(a * 6 + 0.5)
      D.rect(121, y0 + 6 - h, 6, h, bl)
    else
      local ha, hb = math.floor(a * 6 + 0.5), math.floor(b * 6 + 0.5)
      D.rect(121, y0 + 6 - ha, 2, ha, bl)
      D.rect(125, y0 + 6 - hb, 2, hb, bl)
    end
  end
end

local function setup_rows()
  local rows = {{k = "name"}}
  for i = 1, 6 do rows[#rows + 1] = {k = "in", i = i} end
  rows[#rows + 1] = {k = "skip"}
  return rows
end

local function draw_setup()
  D.text(0, 1, "setup", 8)
  if st.recording then D.text(127, 1, "applies at stop", 4, "r") end
  local rows, vis = setup_rows(), 6
  local start = math.max(0, math.min(st.srow - 3, #rows - vis))
  for v = 1, vis do
    local r = rows[start + v]
    if not r then break end
    local y, sel = 10 + (v - 1) * 9, start + v == st.srow
    local l = sel and 15 or 5
    if sel then D.rect(0, y, 2, 5, 15) end
    if r.k == "name" then
      D.text(5, y, "name", l)
      D.text(127, y, S.name, l, "r")
    elseif r.k == "skip" then
      D.text(5, y, "skip silent", l)
      D.text(127, y, S.skip and "yes" or "no", l, "r")
    else
      local m = S.modes[r.i]
      D.text(5, y, "input " .. r.i, l)
      local bl = m == "off" and 3 or (sel and 13 or 8)
      local a, b = st.lv[2 * r.i - 1], st.lv[2 * r.i]
      if m == "mono" then
        D.rect(40, y + 1, math.floor(a * 40), 3, bl)
      else
        D.rect(40, y, math.floor(a * 40), 2, bl)
        D.rect(40, y + 3, math.floor(b * 40), 2, bl)
      end
      D.px(40, y + 2, 2)
      D.text(127, y, MODE_LABEL[m], l, "r")
    end
  end
  if start + vis < #rows then D.rect(63, 63, 3, 1, 4) end
end

local function draw_takes()
  D.text(0, 1, "takes", 8)
  local free = st.recording and tonumber(st.status.free) or st.free
  if free then D.text(127, 1, size_str(free) .. " free", 4, "r") end
  if #st.takes == 0 then D.text(64, 28, "no takes yet", 5, "c") return end
  local vis = 5
  local start = math.max(0, math.min(st.trow - 3, #st.takes - vis))
  for v = 1, vis do
    local k = start + v
    local tk = st.takes[k]
    if not tk then break end
    local y, sel = 10 + (v - 1) * 9, k == st.trow
    local l = sel and 15 or 5
    if sel then D.rect(0, y, 2, 5, 15) end
    D.text(5, y, tk.name:sub(1, 8), l)
    D.text(42, y, tk.when, l)
    D.text(127, y, ms(tk.len), l, "r")
  end
  local tk = st.takes[st.trow]
  if tk then
    local ins = {}
    for n = 1, 6 do if tk.ins[n] then ins[#ins + 1] = n end end
    D.text(0, 58, "in " .. table.concat(ins, " ") .. "   " .. size_str(tk.bytes), 8)
  end
  D.text(127, 58, "k3 delete", 3, "r")
end

local function draw_confirm()
  local tk = st.takes[st.trow]
  if not tk then st.page = "takes" return end
  local ins = {}
  for n = 1, 6 do if tk.ins[n] then ins[#ins + 1] = n end end
  D.text(64, 12, "delete take?", 15, "c")
  D.text(64, 24, tk.name .. " " .. tk.when, 8, "c")
  D.text(64, 32, ms(tk.len) .. "   in " .. table.concat(ins, " "), 5, "c")
  D.text(1, 58, "k2 keep", 6)
  D.text(126, 58, "k3 delete", 15, "r")
end

local function redraw()
  D.clear()
  if st.page == "home" then
    header(S.name)
    draw_tape()
    footer()
  elseif st.page == "setup" then
    draw_setup()
  elseif st.page == "takes" then
    draw_takes()
  elseif st.page == "confirm" then
    draw_confirm()
  end
  D.flush()
end

--
-- menu page
--

local m = {}
local poll

local function clean_name(s)
  s = string.lower(s or ""):gsub("[^%w%-_]", "-")
  return s:sub(1, 12)
end

m.key = function(n, z)
  if z ~= 1 then return end
  local p = st.page
  if p == "home" then
    if n == 2 then mod.menu.exit()
    elseif n == 3 then
      if st.sel == 0 then
        if st.recording then stop_take() elseif not st.starting then start_take() end
      elseif st.sel == 1 then st.page = "setup"
      else scan_takes(); refresh_free(); st.page = "takes" end
    end
  elseif p == "setup" then
    if n == 2 then st.page = "home"
    elseif n == 3 and st.srow == 1 then
      st.typing = true
      textentry.enter(function(txt)
        st.typing = false
        if txt and clean_name(txt) ~= "" then S.name = clean_name(txt); save_settings() end
      end, S.name, "take name")
    end
  elseif p == "takes" then
    if n == 2 then st.page = "home"
    elseif n == 3 and #st.takes > 0 then st.page = "confirm" end
  elseif p == "confirm" then
    if n == 2 then st.page = "takes"
    elseif n == 3 then
      local tk = st.takes[st.trow]
      if tk then delete_take(tk) end
      scan_takes(); refresh_free()
      st.page = "takes"
    end
  end
  if not st.typing then redraw() end
end

m.enc = function(n, d)
  local p = st.page
  d = d > 0 and 1 or -1
  if p == "home" and n == 2 then
    st.sel = util.clamp(st.sel + d, 0, 2)
  elseif p == "setup" then
    local rows = setup_rows()
    if n == 2 then
      st.srow = util.clamp(st.srow + d, 1, #rows)
    elseif n == 3 then
      local r = rows[st.srow]
      if r.k == "in" then
        local k = tab.key(MODES, S.modes[r.i]) or 1
        S.modes[r.i] = MODES[(k - 1 + d) % #MODES + 1]
        save_settings()
      elseif r.k == "skip" then
        S.skip = not S.skip
        save_settings()
      end
    end
  elseif p == "takes" and n == 2 then
    st.trow = util.clamp(st.trow + d, 1, math.max(1, #st.takes))
  end
  redraw()
end

m.redraw = function()
  if not st.typing then redraw() end
end

m.init = function()
  load_settings()
  if st.page == "confirm" then st.page = "takes" end
  st.last_probe = -10
  update()
  refresh_free()
  if st.page == "takes" then scan_takes() end
  local split_t = nil
  if poll then metro.free(poll.id) end
  poll = metro.init(function()
    update()
    -- a take just finished splitting: refresh the list and free space
    if st.split.state == "done" and st.split.t ~= split_t then
      split_t = st.split.t
      if st.page == "takes" then scan_takes() end
      refresh_free()
    end
    if _menu.mode and not st.typing then redraw() end
  end, 1 / 15)
  if poll then poll:start() end
end

m.deinit = function()
  if poll then poll:stop(); metro.free(poll.id); poll = nil end
end

m.refresh = function() end

mod.menu.register(NAME, m)

--
-- hooks
--

mod.hook.register("system_post_startup", NAME, function()
  util.make_dir(STATE)
  run(string.format("setsid bash '%srec.sh' recover '%s' '%s' '%s' >/dev/null 2>&1 </dev/null &",
    LIB, STATE, SHM, TAKES))
end)

-- going to sleep: stop the take; whatever isn't split by then is split at the next boot
mod.hook.register("system_pre_shutdown", NAME, function()
  os.remove(SHM .. "rec")
end)
