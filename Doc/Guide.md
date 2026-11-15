# HEMU: TempleOS V5.03 from a capture

HEMU resumes a captured, already booted TempleOS V5.03 desktop. The stock
capture includes native document-clipping and autocomplete display corrections,
a Welcome card and the OS's Take Tour question. It does not execute the DVD's
16-bit BIOS loader or install from disk. Two backends run the capture:

- `Linux/`: on x86-64 Linux, KVM runs TempleOS on the host processor. A C host
  supplies the rest of the PC and a Wayland window. See [Linux](#linux).
- `Kernel/`: a HolyC x86-64 CPU/device emulator with a JavaScript browser host,
  workers and x86-to-WASM block JIT.
  [HolyC-wasm](https://github.com/ParkerrDev/HolyC-wasm) compiles the emulator;
  HEMU pins that compiler in `Siblings.txt` and mounts it at `holyc-wasm/`.
  [TempleOS-Web](https://github.com/ParkerrDev/TempleOS-Web) and HEMU's standalone
  desktop use this runtime. HEMU owns its build, tests and capture recipes.

The small `Boot.HC` framebuffer kernel is an instruction and device fixture, not a TempleOS cold-boot
test. The HolyC test adapter that runs under original V5.03 is headless.

## Layout

| Path | What |
|---|---|
| `Kernel/Cpu.HC` | the CPU: fetch, decode and execute for the integer, x87 and SSE instructions TempleOS uses |
| `Kernel/Dev.HC`, `Kernel/Time.HC`, `Kernel/Kbd.HC` | device state, port I/O, interrupt selection, elapsed clocks and PS/2 keyboard behavior |
| `Kernel/Mem.HC` | unaligned RAM reads/writes, the guest RAM alias, and saved-guest MMIO/IPI routing |
| `Kernel/Fpu.HC`, `Kernel/Alu.HC`, `Kernel/MulDiv.HC`, `Kernel/Shift.HC`, `Kernel/Atom.HC` | scalar floating-point, integer arithmetic, full multiply/divide, shifts and supported atomic operations |
| `Kernel/Except.HC` | bounded long-mode divide exception delivery to the current ring-zero code segment and stack |
| `Kernel/CpuId.HC` | the explicit virtual CPU identification and capability contract, independent of the host machine |
| `Kernel/Video.HC` | completed planar-screen capture for host presentation |
| `Kernel/Host.HC` | **the host contract**: every function the emulator imports from its host, and the two compiler intrinsics it needs |
| `Kernel/Core.HC` | per-core CPU state (`CCpuState g_cpu_st[]` behind the `reg` / `rip` / `rfl` accessors) and the SMP and guest-call scaffolding every entry shares |
| `Kernel/GuestCall.HC` | host-injected guest calls, the backend execution primitive (below) |
| `Kernel/Snapshot.HC` | the TempleOS entry: resume from the RAM snapshot, completed-frame observation and wall-clock pacing. `HemuInit` once, then `Frame` per display frame |
| `Kernel/SnapRegs.HC`, `Kernel/SnapRegsSmp.HC` | generated: the register state captured together with the RAM snapshot (single-core / four-core) |
| `Kernel/Boot.HC`, `Kernel/Anim.HC` | small demo entries that run a clang-compiled kernel inside the emulator |
| `Kernel/Test.HC` | the self-checking instruction battery (`#include "Cpu.HC"`; prints pass / fail counts) |
| `stock.json`, `stock.disk`, `stock-smp.disk` | validated capture identities and exact paired disk sector overlays |
| `capture.txt`, `capture-smp.txt` | original stopped native CPU register dumps, including FPU/XMM state |
| `live.bin.gz`, `live-smp.bin.gz` | lossless sparse RAM captures: gzipped nonzero 64-byte ranges reconstructing 384 MiB |
| `templeos-hd.qcow2.gz` | immutable base disk for both captures; `stock.json` binds its hashes and each overlay |
| `Kernel/*.js`, `Kernel/Test/`, `Kernel/Desktop/` | browser runtime, machine tests and standalone desktop; see [Kernel](../Kernel/README.md) |
| `Kernel/Build.mjs`, `Misc/Server.mjs`, `Siblings.txt` | engine build, standalone server and compiler pin |
| `Misc/Capture/`, `Misc/Pack.py`, `Misc/Ram.py` | native preparation/capture, packaging and sparse RAM format |
| `Linux/HEMU.CPP`, `Linux/make_hemu` | the KVM machine and the script that builds and installs it |

## Linux

`Linux/HEMU.CPP` runs the capture on the processor it was made for. It maps the captured RAM, loads
each captured processor's registers from the same `capture-smp.txt` dump into a KVM virtual CPU, and
answers the ports TempleOS uses: the PS/2 keyboard, the ATA disk, the CMOS clock, the VGA palette and
map mask, and the HPET's counter. The PIC, the PIT, the APICs and the speaker's gate are Linux's own.
It finds TempleOS's mouse, screen and clock variables by name in the guest's hash table, as `Kernel/Sym.HC`
does. It uses no toolkit: KVM by ioctl, the window by the Wayland wire protocol on its socket, and ALSA
for the speaker's square wave. There is no compiler, emulator or script engine between TempleOS and
the processor.

```sh
Linux/make_hemu
```

This needs `cc`, `python3`, alsa-lib's headers and access to `/dev/kvm`, all of which a stock Omarchy
has. It puts the program, the four-core capture's RAM and registers and its disk in
`~/.local/share/HEMU`, adds TempleOS to the launcher, and under Hyprland binds SUPER+ALT+T to it
(`~/.config/hypr/hemu.lua`, loaded by one line added to `hyprland.lua`). To remove it, delete those
two, that line and `~/.local/share/applications/HEMU.desktop`.

- The screen is 640x480 at the largest whole zoom that fits the window, in the monitor's own pixels.
- The frame is taken when TempleOS writes the VGA map mask for a frame's first plane, the moment it
  has finished one, so a frame is never shown half drawn. It runs at TempleOS's own 30 frames a second.
- The pointer is TempleOS's mouse, and keys are sent as the set 1 scan codes of the same physical
  keys, with the keyboard's own typematic repeat. Keys with SUPER held stay Hyprland's.
- `Reboot` and a triple fault start the capture again in the same window. Closing the window ends
  the machine.
- The capture's CD drive T: has no device here, so HEMU takes its signature away and `Dir("T:/")`
  throws `Drv` as for a drive that is not there.
- `make_hemu` may run while HEMU is open: it moves new files over the old ones, and the running
  machine keeps the ones it mapped until it ends or reboots.
- RAM and disk are private copies of the capture: writes are gone when this Linux host ends.
  The browser runtime separately supports persistent C: storage in IndexedDB.
- With `capture.txt`, `live.bin.gz` and `stock.disk` in place of the four-core files, the same program
  runs the one-core capture: it makes one processor for each block of the register dump.
- It is for x86-64 with KVM and Wayland only. Another CPU, macOS or a host without KVM uses the HolyC
  emulator in `Kernel/`.

Earlier measurements on an i9-14900HX under Hyprland, before the prepared Welcome
captures: the first frame was committed 7 to 10 ms after the program started; TempleOS's `CPURep` reports "004 Cores 2.418GHz"; `Demo/MultiCore/MPPrint` prints from all four
cores; `Demo/Games/CastleFrankenstein` holds FPS:30 with one host core about 5 percent busy; `Snd(60)`
and `Beep` come out at 437 and 491 Hz.

## Stock capture identity

`stock.json`, `capture.txt` and `capture-smp.txt` bind each RAM image to its
native stopped CPU register set and disk. `stock.disk` and `stock-smp.disk`
contain only changed 512-byte sectors against the recorded original base disk.
A host must validate that pairing before execution; a RAM-only image contains
no CPU state of its own. The browser runtime enforces this through the generated
module's `hemu.stock` metadata and refuses unknown or mismatched RAM imports.
Full saved-machine images retain their separate self-contained restore path.

These captures preserve FCW, FSW, TOP, all sixteen XMM registers and HLT.
They require all live x87 stacks to be empty because HEMU does not represent
architectural 80-bit x87 values or tags. The raw native register dumps remain
available for audit. Initial PIC/PIT/RTC state is still synthesized by the
existing startup policy, not captured from QEMU; all CPUs being halted does
not establish device-state equivalence. See
[the capture recipe](../Misc/Capture/README.md) for independent capture and validation commands.

## The host contract

`Kernel/Host.HC` is the whole interface. Required: load the snapshot into guest RAM, present a frame, VGA
palette writes, ATA sector reads and writes, mouse and keyboard state, wall-clock pacing, a speaker tone.
Speaker updates use the required `__host_snd(F64 hz,U64 ns)` import. Zero Hz
means silence; `ns` is the observed emulated TSC in nanoseconds, including on
saved-machine resume. Hosts must retain unsigned 64-bit timestamps rather than
rounding them through a floating-point number. `TscRead` is also exported by
the web build for an end-of-batch audio watermark. Earlier embedded modules
use the generic one-argument `__snd`; their untimed behavior remains supported
by the new host. New modules require the new import and older hosts reject
them at instantiation. Release the engine and host adapter together.

Timestamped playback is qualified only for the one-core native host. The BSP
advances device time; APs only observe that shared clock. This addition does not
make ordinary shared TSC reads or speaker port updates globally ordered across
cores, and supplies no cross-worker audio ordering guarantee. Instruction-batch
clock granularity and the existing frequency-only PIT model remain unchanged;
this is not physical PIT phase or cycle-accurate speaker emulation.
Optional: the `__jit_*` / `__ap_run` hooks a host may implement to run hot guest code natively - a host that
returns 0 from `__jit_state` gets a pure interpreter. Two compiler intrinsics complete it: `MyCore` (this
core's index) and the `__a_<op><bits>` atomics, both documented in the header. Everything else the source
calls is standard HolyC. `MyCore` is a host intrinsic; a native adapter uses
TempleOS's `Gs->num`. Bare intrinsic reads require HolyC-wasm A27 (52f06fb) or later.
The complete interpreter compiles under original V5.03 with an explicit test
host and passes the same 31 instruction cases plus 707 sampled hardware multiply/divide
assertions and 861 split-field atomic assertions as WASM. The memory and device
modules also have 324 and 519 independent native output comparisons. The test
host supplies serialized atomics and headless callbacks; it is not a native
desktop, disk or JIT implementation.
Original QEMU/KVM supplies 200 raster reference cases for the original guest's
line/triangle instructions: pixels, depth, collision counts, extents, nearest
distance and final random seeds agree. Another 30 cases cover pixel/depth storage
overlapping the task seed, dither probability and each other. Another 640 native
triangle/fan cases compare both graphics modes, including custom transforms and
mirroring. A guest-code test changes drawing entry points, including GrFillTri0
and GrFillPoly3, checks interpreted and translated results, then changes their bytes again and rejects stale compiled
code before any instruction executes. These are bounded checks, not complete
x86 or graphics coverage. Divide faults enter the guest's #DE handler for valid ring-zero,
long-mode, IST-zero interrupt/trap gates targeting the current code segment.
Original QEMU/KVM supplies 1,536 raw entry frames and native `DivZero` catch
behavior; interpreter/JIT checks preserve the faulting prefix RIP, operands,
stack alignment and saved flags. Unsupported gates, privilege/stack switches
and addresses outside direct guest RAM retain a visible stopped state. General exception
cascades, paging faults and double-fault delivery remain unsupported.
Wide drawing contexts use original guest drawing code.

The host drives one `Main` call per display frame. `Main` runs `HemuInit` the first time and `Frame` every
time; `Frame` pulls input, runs the instruction budget the host asked for, and presents. A host that runs
`Main` only once can call `HemuInit` and then loop `Frame` itself.

## Building and running

`Kernel/Compile.js` compiles `Kernel/Snapshot.HC` in strict mode, making the
`Host.HC` declarations WebAssembly imports and exporting the functions the host
calls. `Kernel/Host.js` implements that contract using HolyC-wasm's `createHost()`;
`Kernel/JitCore.HC` supplies the x86-to-WASM compiler; `Kernel/Jit.js` installs
its output through the browser WebAssembly API. From this repository, with the pinned
compiler at `holyc-wasm/`:

```sh
node Kernel/Build.mjs                         # build/hemu*.wasm and SMP metadata
node Kernel/Test/Measure.mjs                  # self-checking instruction battery
node Kernel/Test/BootTest.mjs                 # demo kernel framebuffer
```

See [Kernel/README.md](../Kernel/README.md) for compiler setup, the standalone
browser window, complete machine checks and startup/storage behavior. Tests
live with HEMU; website shell and catalog integration tests stay with the site.

## Backend guest execution

`Kernel/GuestCall.HC` lets the host call one validated guest function with up to eight stack arguments exactly
the way a hardware interrupt enters a handler: at an instruction boundary with IF=1, a frame is pushed on
the current task's stack, the callee runs with IF=0, and when it returns to the sentinel address the
interrupted CPU state is restored bit-exactly. The callee's side effects on guest memory persist; nothing
else does. This is the discipline TempleOS itself uses for IRQ1, so the JobQue family (TaskExe, JobResScan,
PopUp) is safe by construction. Only core 0 injects; a callee that faults or exceeds its budget is reported
as failed and the interrupted state is still restored. `Kernel/GuestExec.js` is the host-side
API over it (`exec`, `include`, `mkdir`, `writeFile`, `launch`).

## Devices and performance

The CPU implements the integer, x87 and SSE instructions used by this TempleOS image. FTST and FNSTSW are
covered in both interpreter and JIT tests, including negative values, signed zeros, NaN and infinities; the
missing FTST previously made native Sign return +1 for every input. The x87 register-destination subtraction
and division encodings preserve Intel operand order in both engines; 432 arithmetic cases cover both signs,
destination registers and wrapped stack tops. Reversing those operands produced negative game collision
coordinates. ATA transfers support both 16-bit and 32-bit I/O, including REP INSD/OUTSD. VGA DAC reads and
writes preserve the 16-color palette and notify the host when colors change. A host must implement both
`__host_disk` and `__host_disk_wr`.

The interpreter and block JIT execute guest x86 instructions. Fast graphics is
on by default: `Kernel/Render.HC` accelerates four stock compositor/video routines
and triangle filling plus horizontal/vertical depth spans. Polygon assembly,
transforms and callbacks remain guest code.
`RenderFastSet(0)` selects original drawing instructions; `RenderFastSet(1)`
enables acceleration and `RenderFastSet(-1)` queries it. The browser setting uses
the existing SMP barrier so all CPUs switch together without invalidating compiled
blocks. Generic XLAT and immediate ROL/ROR translation benefits both modes.

The initial validated stock load records complete eligible function/helper bytes.
Each accelerated call compares them before replacing execution; edited code and
unsupported contexts execute normally. These baselines and the selected mode
survive a full machine save. Fast graphics changes instruction counts and timing;
original mode removes these drawing replacements but is not cycle-accurate.
The JIT separately validates compiled code bytes to reject stale translations.

Full machine saves embed their engine and graphics mode. Older embedded engines
without `RenderFastSet` cannot switch modes; the host reports that limitation.
Restart uses the current engine and retains saved C: files, while reloading the
stock desktop instead of preserving old running RAM.

The host still understands some TempleOS internals: it observes completed
screen-update returns and decodes the guest's planar screen image, writes mouse
state into guest globals, and injects requested commands as guest function calls.
Explicit refresh settings patch guest pacing code. Stock images resume a prepared
desktop with documented native corrections. These integrations remain separate
from the graphics mode; neither mode makes HEMU a hardware-complete or
cycle-accurate PC. The SMP build (`SMP_SNAP`) runs one core per
host thread over shared memory with worker/barrier regressions. Browser networking
for TOOM multiplayer is not implemented.

Accesses past RAM are devices only on their own page: the LAPIC at 0xFEE00000
(ID, version and the ICR that sends IPIs) and the HPET at 0xFED00000 (its main
counter), in the low 4GB or through TempleOS's uncached alias. TempleOS draws
the VGA planes through that same alias, at alias+0xA0000. Decoding by page
offset alone once made pixel stores at offset 0x300 send IPIs whose vector
was pixel data; an exception vector crashed an AP, and the BSP, left in
single-user mode, ran only the window manager. Those stores are now ignored
(`Kernel/Test/MmioAlias.test.mjs`).

`Kernel/Atom.HC` owns memory read/modify/write operations, including implicit-lock
XCHG, LOCK arithmetic, unary operations, XADD, CMPXCHG/8B/16B and bit changes.
Aligned operands up to eight bytes, including the TempleOS RAM alias, use
sequentially consistent host atomics.
An unaligned 16/32-bit field contained within one 64-bit word uses masked CAS,
preserving simultaneous writes to neighboring fields. With exactly one guest
core, valid cross-word RAM operands complete within one synchronous instruction,
without IRQ delivery or a host callback between reading and writing. Original
TempleOS provides 516 split-field witnesses, including cache-line crossings;
387 also match a separate physical-host probe. Multi-core cross-word operands
require the host's opt-in shared-RAM ownership protocol; uncoordinated hosts,
MMIO and invalid LOCK forms retain a fault without writes. Architectural
delivery of these unsupported-operand faults remains unimplemented. Four-worker
contention tests and an independent x86-64 hardware oracle cover arithmetic,
defined flags and register writeback; logical operations set undefined AF to
zero consistently in both interpreter and JIT.

Unlocked CMPXCHG and CMPXCHG8B write the old memory operand back when the
comparison fails. This write cycle is observable at device endpoints even when
RAM bytes stay equal. Failed register-destination CMPXCHG preserves the upper
register bits, including a 32-bit destination; it must not take that memory
writeback path. Physical read-only-page faults and an original QEMU/KVM APIC
resend witness establish the distinction independently of HEMU. The device
checks retain the existing saved-guest MMIO model rather than claiming full
hardware APIC behavior or newly implemented memory-protection faults.

CMPXCHG16B supports complete, 16-byte-aligned RAM operands and the RAM alias.
It compares RDX:RAX, stores RCX:RBX on success, loads the old pair on failure,
and changes only ZF. Both halves receive a write cycle even on failure. A
locked multi-core operation requires the same exclusive shared-RAM protocol
even though its address is aligned; unregistered hosts refuse before the read.
Unlocked operations do not promise atomicity. Misaligned, out-of-range, MMIO
and invalid register forms retain a stopped diagnostic without operand writes;
architectural #GP/#UD/#PF delivery and guest page protection remain open.
Physical and original TempleOS vectors, a forced half-write overlap and actual
four-core guest counter loops cover this bounded path. CPUID keeps CX16 clear
because this is not the complete protected-memory/fault-delivery contract.

`CpuId.HC` defines a conservative virtual CPU instead of copying the host's
capabilities. Leaf 0 reports `GenuineIntel` and basic maximum 1. Leaf 1 retains
model 0x6FB, puts a 64-byte line size and configured logical-processor count in
EBX, and puts the current core's APIC ID in its high byte. Its named EDX bits
identify the implemented FPU, TSC, MSR, CMPXCHG8B, APIC, CMOV and FXSAVE/FXRSTOR
families; HTT marks multiple configured cores. ECX is zero. The extended maximum
is 0x80000001, whose EDX reports long mode. Other leaves return zero, and these
leaves do not vary with the input subleaf. There is no advertised CMPXCHG16B,
MMX/SSE/SSE2/SSE3/SSSE3, XSAVE/AVX, SYSCALL, NX, RDTSCP or address-width leaf.
Some unadvertised instructions still execute as documented subsets. Family bits
do not remove the existing x87 precision, paging and exception-delivery limits.

The CPUID gates check output register order, upper halves, untouched registers
and flags, subleaf inputs, one/four-core restored topology, the stock CPUId
wrapper and SysGlblsInit cache-line expression. They execute BootDVD's capability
decision using 32-bit registers in the long-mode interpreter; they do not boot
its BIOS loader. Independent physical and original-TempleOS probes establish
the architectural register placement and the native consumer's layout.

The x87 comparison contract follows Intel SDM revision 089: FCOMI/FUCOMI
clear OF/SF/AF, preserve ZF/PF/CF and TOP on unmasked invalid operands, and
record IE/ES/B. Measurements from Intel i9-14900HX and QEMU/TCG differ in
this edge case; the host's comparison tests preserve those measurements and
identify the discrepancy explicitly. Registers currently use binary64, and
80-bit precision, the complete tag model and pending #MF delivery remain
unsupported. Unsupported sub-encodings stop with both opcode bytes instead
of silently succeeding; 80-bit memory operands are explicitly rejected.
Transcendental results use host math and can differ from native
x87 near integer pixel/texture boundaries.

The emulator classifies binary64 NaNs and both signed zeros from their bits.
Native HolyC equality compares representations and its floating truth test
regards negative zero as nonzero, so those language operators cannot implement
CPU numeric equality or unordered detection. Integer-store range checks also
use sign and magnitude bits before conversion. The FPU module is compiled by
original V5.03 and both old/new WASM comparison implementations in the source
fixture. Physical COMISD/UCOMISD witnesses cover operand preservation and
ZF/PF/CF plus clearing OF/SF/AF; complete MXCSR exception handling is not
implemented by that comparison path.

These checks cover observed workloads and regressions, not complete x86 hardware conformance or complete
game playthroughs.

## Snapshots

The RAM images are captured from TempleOS booted under QEMU with the machine paused, together with the
register state that becomes `Kernel/SnapRegs*.HC`; the two must match, so re-bake the registers after every
capture. HEMU owns the disk, RAM, registers, overlays and their `stock.json`
manifest. `Misc/Regs.mjs` parses the captured registers, and the same generator
handles either CPU count:

```sh
node Misc/RegsMk.mjs capture.txt
node Misc/RegsMk.mjs capture-smp.txt
```

`Misc/Pack.py` packages verified native captures with their base disk and
generated sources under `Kernel/`. [Misc/Capture/README.md](../Misc/Capture/README.md)
documents source preparation, native capture and the Welcome bitmap's historical
provenance. The site reads the resulting files from its HEMU mount. Both stock
captures already show the Welcome card and TempleOS's own "Take Tour(y or n)?"
question, ready for a visitor's answer. Display corrections are compiled before
capture rather than installed while the browser loads.

The RAM payload stores adjacent nonzero 64-byte blocks as sparse ranges before
gzip compression. `Misc/Ram.py` packs or expands it; `Kernel/Ram.js` validates and
restores it in the browser. Zero-filled guest memory supplies omitted ranges.
The native Linux installer expands the same capture into its flat RAM file.

The web host can also save and restore a complete live machine. Its versioned
container includes the exact compiled engine, every core and device's state,
guest memory, host input/settings, and the full current disk. SnapshotResume
reconnects the host JIT and displays the saved frame without resetting the CPU.
See [Kernel/Test/README.md](../Kernel/Test/README.md#full-machine-snapshots) for the format and round-trip tests.
