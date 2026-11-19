-- tx6rec: record every TX-6 input as its own stereo track
--
-- SYSTEM > MODS > TX6REC: K3 record / stop, K2 back.
-- Takes land in dust/audio/tx6/<date_time>/<date_time>_inN.wav.
-- The recording itself runs in lib/rec.sh, outside matron, so it keeps going
-- while scripts load and never touches the norns clock or audio engine.

local mod = require 'core/mods'

local NAME = mod.this_name or "tx6rec"
local SCRIPT = _path.code .. NAME .. "/lib/rec.sh"
local STATE = _path.data .. NAME .. "/"
local TAKES = _path.audio .. "tx6/"
local BPS = 12 * 3 * 48000 -- raw bytes per second of a take

local status = {} -- STATE/status, written by rec.sh
local disk = {}   -- STATE/disk, written by rec.sh while recording
local idle_free   -- free bytes when not recording (from df)
local present = false
local pending     -- "start"/"stop" pressed, waiting for rec.sh to react
local pending_t = 0
local poll

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

local function tx6_present()
  local f = io.open("/proc/asound/cards", "r")
  if not f then return false end
  local s = f:read("a")
  f:close()
  return s:find("%[TX6%s*%]") ~= nil
end

-- run rec.sh in the background; system_cmd uses its own thread, so matron never waits
local function run(args)
  norns.system_cmd(string.format("setsid bash '%s' %s >/dev/null 2>&1 </dev/null &", SCRIPT, args),
    function() end)
end

local function refresh_free()
  norns.system_cmd("df -B1 --output=avail '" .. _path.audio .. "' | tail -1", function(out)
    idle_free = tonumber(out and out:match("%d+"))
  end)
end

-- is rec.sh still alive? (it dies with matron, leaving a stale status behind)
local function alive()
  local f = io.open(STATE .. "pid", "r")
  if not f then return false end
  local pid = f:read("l")
  f:close()
  if not pid or pid == "" then return false end
  local c = io.open("/proc/" .. pid .. "/cmdline", "r")
  if not c then return false end
  local s = c:read("a")
  c:close()
  return s:find("rec.sh", 1, true) ~= nil
end

local function update()
  status = read_kv(STATE .. "status")
  disk = read_kv(STATE .. "disk")
  present = tx6_present()
  if (status.state == "recording" or status.state == "processing") and not alive()
    and not pending then
    -- split whatever the dead recorder left behind
    pending = "recover"; pending_t = util.time()
    run(string.format("recover '%s' '%s'", STATE, TAKES))
  end
  if pending == "recover" then
    status.state = "processing"
    status.prog = "recovering interrupted take"
  end
  local st = status.state or "idle"
  if pending == "start" and st == "recording" then pending = nil end
  if pending == "stop" and st ~= "recording" then pending = nil end
  if pending and util.time() - pending_t > 5 then pending = nil end
end

local function recording() return status.state == "recording" end

local function hms(s)
  s = math.max(0, math.floor(s))
  return string.format("%d:%02d:%02d", s // 3600, (s // 60) % 60, s % 60)
end

local function hm(s)
  s = math.max(0, math.floor(s))
  if s >= 3600 then return string.format("%dh %02dm", s // 3600, (s // 60) % 60) end
  return string.format("%dm", s // 60)
end

local function gb(b)
  if b < 1e9 then return string.format("%d MB", b // 1e6) end
  return string.format("%.1f GB", b / 1e9)
end

--
-- menu page
--

local m = {}

m.key = function(n, z)
  if z ~= 1 then return end
  if n == 2 then
    mod.menu.exit()
  elseif n == 3 and not pending then
    if recording() then
      pending = "stop"; pending_t = util.time()
      run(string.format("stop '%s'", STATE))
    elseif status.state ~= "processing" and present then
      pending = "start"; pending_t = util.time()
      run(string.format("start '%s' '%s'", STATE, TAKES))
    end
    mod.menu.redraw()
  end
end

m.enc = function(n, d) end

m.redraw = function()
  local st = status.state or "idle"
  screen.clear()
  screen.font_face(1)
  screen.font_size(8)

  screen.level(4)
  screen.move(0, 8)
  screen.text("TX-6 RECORDER")
  screen.move(128, 8)
  screen.text_right(present and "connected" or "no TX-6")

  -- main line
  screen.font_size(16)
  screen.move(0, 30)
  if pending == "start" then
    screen.level(8); screen.text("starting")
  elseif pending == "stop" then
    screen.level(8); screen.text("stopping")
  elseif st == "recording" then
    screen.level(15)
    if util.time() % 1 < 0.5 then screen.circle(122, 25, 4); screen.fill() end
    screen.move(0, 30)
    screen.text(hms(os.time() - (tonumber(status.start) or os.time())))
  elseif st == "processing" then
    screen.level(8); screen.text("saving")
  elseif present then
    screen.level(15); screen.text("ready")
  else
    screen.level(4); screen.text("plug in TX-6")
  end
  screen.font_size(8)

  -- detail line
  screen.level(8)
  screen.move(0, 43)
  if st == "processing" then
    screen.text(status.prog or "")
  elseif st == "recording" then
    local g = tonumber(status.glitches) or 0
    if g > 0 then screen.text(g .. (g == 1 and " dropout" or " dropouts")) end
  elseif status.msg and status.msg ~= "" then
    screen.text(status.msg)
  end

  -- disk line: time left, keeping room for the split afterwards
  screen.level(4)
  screen.move(0, 53)
  local free = tonumber(disk.free)
  if st == "recording" and free then
    local bytes = tonumber(disk.bytes) or 0
    screen.text(gb(bytes) .. ", " .. hm((free - bytes) / (2 * BPS)) .. " left")
  elseif idle_free then
    screen.text(gb(idle_free) .. " free, " .. hm(idle_free / (2 * BPS)))
  end

  screen.level(st == "processing" and 2 or 15)
  screen.move(128, 63)
  if st == "recording" or pending == "start" then
    screen.text_right("K3 stop")
  elseif present then
    screen.text_right("K3 record")
  end
  screen.update()
end

m.init = function()
  update()
  refresh_free()
  if poll then metro.free(poll.id) end
  poll = metro.init(function(c)
    update()
    if c % 20 == 0 and not recording() then refresh_free() end
    if _menu.mode then mod.menu.redraw() end
  end, 0.25)
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

-- split takes left behind by a crash, power cut or restart mid-take
mod.hook.register("system_post_startup", NAME, function()
  run(string.format("recover '%s' '%s'", STATE, TAKES))
end)

-- going to sleep: stop cleanly so the take is split on the next boot at the latest
mod.hook.register("system_pre_shutdown", NAME, function()
  os.execute(string.format("bash '%s' stop '%s'", SCRIPT, STATE))
end)
