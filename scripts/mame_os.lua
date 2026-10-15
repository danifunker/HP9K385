-- MAME autoboot script for scripts/mame_os.sh: a snapshot every
-- HP385_SNAP_EVERY emulated seconds, and one at the end.
local every = tonumber(os.getenv("HP385_SNAP_EVERY") or "60")
local nextt = every
local function now() return manager.machine.time:as_double() end
frame_sub = emu.add_machine_frame_notifier(function()
  if now() >= nextt then
    nextt = nextt + every
    manager.machine.video:snapshot()
  end
end)
stop_sub = emu.add_machine_stop_notifier(function() manager.machine.video:snapshot() end)
