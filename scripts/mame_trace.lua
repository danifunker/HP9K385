-- MAME autoboot script: log every CPU access outside boot ROM / main RAM / PTM
-- (LED latch, DIO space, system registers, probes) plus a debugger
-- instruction trace.  Driven by scripts/mame_trace.sh; output paths come
-- from the HP385_TRACE_DIR environment variable.
local dir = os.getenv("HP385_TRACE_DIR") or "."
local cpu = manager.machine.devices[":maincpu"]
local sp = cpu.spaces["program"]
local out = io.open(dir .. "/mame_events.txt", "w")
local function pc() return cpu.state["PC"].value end
local function tap(lo, hi, name)
  local r = sp:install_read_tap(lo, hi, name .. "_r", function(offset, data, mask)
    out:write(string.format("R %08X mask=%08X data=%08X pc=%08X %s\n", offset, mask, data, pc(), name)) end)
  local w = sp:install_write_tap(lo, hi, name .. "_w", function(offset, data, mask)
    out:write(string.format("W %08X mask=%08X data=%08X pc=%08X %s\n", offset, mask, data, pc(), name)) end)
  return {r, w}
end
taps = {}   -- global: taps are removed when their handles are collected
table.insert(taps, tap(0x0001fffc, 0x0001ffff, "led"))
table.insert(taps, tap(0x00020000, 0x005f7fff, "io"))
table.insert(taps, tap(0x005f8000, 0x005f800f, "ptm"))
table.insert(taps, tap(0x005f8010, 0xff7fffff, "hi"))
if manager.machine.debugger then
  manager.machine.debugger:command("trace " .. dir .. "/mame_trace.log,maincpu,noloop")
  manager.machine.debugger:command("trace " .. dir .. "/mame_8042.log,:sl0:human_interface:iocpu,noloop")
end
