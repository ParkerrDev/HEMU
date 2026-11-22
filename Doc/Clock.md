# Clock synchronization

The host RTC reads local computer time. TempleOS NowDateTimeStruct reads CMOS
seconds, minutes, hours and date separately; Now subtracts local_time_offset,
and WallPaper adds that offset back when displaying the clock.

Fix the clock at its two real boundaries:

- Sample the host clock once when the RTC seconds register is read. Independent
  Date objects for each field can combine two dates across midnight. The
  guest serializes calendar reads with SEMA_SYS_DATE. A new seconds read starts
  a new sample, including after pause and saved-session restore. Store the
  packed calendar in HolyC device memory, shared by all CPUs and included in
  full snapshots, so restoring halfway through a read preserves its fields.
- Display the timestamp already decoded from the completed guest frame in the
  website toolbar. WallPaper caches its top line for 32 updates; a separate
  one-second page timer inevitably differs. Keep host time only before a guest
  clock has been observed or while a fullscreen program hides it. Pausing
  retains the displayed guest time with the paused frame.
- Invalidate the captured WallPaper clock text at stock initialization so the
  original WallPaper routine formats the current RTC before the first frame.
  Do not replace Now, change elapsed timers, or rewrite guest timezone settings.

Historical-release work is separately stashed and is outside this change.
Checks target calendar rollovers, first rendered clock, pause/resume and saved
sessions. No game-wide suite is needed for this change.

Verification: browser tests passed with one/four CPUs at 30 FPS and with a paused
full-session restore. The native worker's PIT/TSC test conserved a 450 ms active
stall; after recovery it differed from observed wall time by about 2 ms in this
run. Paused time was deliberately excluded. This is bounded verification, not
a claim of zero timing error under every workload. The toolbar mirrors guest
presentation and is not itself evidence of hardware timer accuracy.

Direct guest checks of Date2Struct(Now+local_time_offset) agreed with host local
time within one second on one and four CPUs. The RTC regression restores device
RAM into a fresh host midway through the midnight read. The native TempleOS
oracle and WASM engine agree on all 519 device probe outputs.
