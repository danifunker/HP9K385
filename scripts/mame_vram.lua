-- MAME autoboot script: log the 98550A's register accesses ($560000-$56FFFF)
-- and frame-buffer accesses ($200000-$3FFFFF) from HP385_TRACE_FROM seconds
-- of emulated time on, at most HP385_TRACE_MAX lines, and save a snapshot
-- when the run ends.  Driven by scripts/mame_vram.sh.
local dir   = os.getenv("HP385_TRACE_DIR") or "."
local from  = tonumber(os.getenv("HP385_TRACE_FROM") or "0")
local limit = tonumber(os.getenv("HP385_TRACE_MAX") or "2000000")
local cpu = manager.machine.devices[":maincpu"]
local sp = cpu.spaces["program"]
local out = io.open(dir .. "/mame_vram.txt", "w")
local n = 0
local function now() return manager.machine.time:as_double() end
local function pc() return cpu.state["PC"].value end
local function log(kind, offset, data, mask, name)
  if n >= limit or now() < from then return end
  n = n + 1
  out:write(string.format("%.6f %s %08X mask=%08X data=%08X pc=%08X %s\n", now(), kind, offset, mask, data, pc(), name))
end
local function tap(lo, hi, name)
  local r = sp:install_read_tap(lo, hi, name .. "_r", function(offset, data, mask) log("R", offset, data, mask, name) end)
  local w = sp:install_write_tap(lo, hi, name .. "_w", function(offset, data, mask) log("W", offset, data, mask, name) end)
  return {r, w}
end
taps = {}   -- global: taps are removed when their handles are collected
table.insert(taps, tap(0x00200000, 0x003fffff, "vram"))
table.insert(taps, tap(0x00560000, 0x0056ffff, "98550"))
emu.add_machine_stop_notifier(function()
  out:close()
  manager.machine.video:snapshot()
end)
