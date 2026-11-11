# HEMU: a TempleOS x86-64 emulator in HolyC

HEMU runs the unmodified TempleOS V5.03 kernel from a saved RAM image. It is written entirely in HolyC and
reaches the outside world through one small host contract, so any HolyC compiler whose runtime implements
that contract can build and run it. [HolyC-wasm](https://github.com/ParkerrDev/HolyC-wasm) compiles it to
WebAssembly, and [TempleOS-Web](https://github.com/ParkerrDev/TempleOS-Web) is a complete host for that
build - its `engine/` implements the contract (with an x86→WASM block JIT), its `tools/hemu/` are the
harnesses, and its `tools/snapshot/` are the recipes that produce the boot snapshots kept here.

This repository is HolyC source and the snapshots it boots. Nothing else.

Startup resumes a captured, already booted 64-bit TempleOS desktop. It does not
execute the DVD's 16-bit BIOS loader or perform a fresh installation from disk.
The small `boot.HC` framebuffer kernel is an instruction/device fixture, not a
TempleOS cold-boot test. The current desktop host uses a browser window; the
native HolyC test adapter is headless, with no native desktop/JIT backend yet.

## Layout

| Path | What |
|---|---|
| `src/cpu.HC` | the CPU: fetch, decode and execute for the integer, x87 and SSE instructions TempleOS uses, and the HLE hooks |
| `src/Dev.HC`, `src/time.HC`, `src/keyboard.HC` | device state, port I/O, interrupt selection, elapsed clocks and PS/2 keyboard behavior |
| `src/Mem.HC` | unaligned RAM reads/writes, the guest RAM alias, and saved-guest MMIO/IPI routing |
| `src/Fpu.HC`, `src/Alu.HC`, `src/MulDiv.HC`, `src/Shift.HC`, `src/Atom.HC` | scalar floating-point, integer arithmetic, full multiply/divide, shifts and supported atomic operations |
| `src/Except.HC` | bounded long-mode divide exception delivery to the current ring-zero code segment and stack |
| `src/CpuId.HC` | the explicit virtual CPU identification and capability contract, independent of the host machine |
| `src/Raster.HC`, `src/poly.HC`, `src/video.HC` | source-derived drawing acceleration, integer triangle edge walks and VGA conversion |
| `src/host.HC` | **the host contract**: every function the emulator imports from its host, and the two compiler intrinsics it needs |
| `src/core.HC` | per-core CPU state (`CCpuState g_cpu_st[]` behind the `reg` / `rip` / `rfl` accessors) and the SMP and guest-call scaffolding every entry shares |
| `src/guestcall.HC` | host-injected guest calls, the backend execution primitive (below) |
| `src/snapshot.HC` | the TempleOS entry: resume from the RAM snapshot, HLE of the hot render routines, wall-clock pacing. `HemuInit` once, then `Frame` per display frame |
| `src/snapregs.HC`, `src/snapregs-smp.HC` | generated: the register state captured together with the RAM snapshot (single-core / four-core) |
| `src/boot.HC`, `src/anim.HC` | small demo entries that run a clang-compiled kernel inside the emulator |
| `src/test.HC` | the self-checking instruction battery (`#include "cpu.HC"`; prints pass / fail counts) |
| `live.bin.gz`, `live-smp.bin.gz` | the booted-desktop RAM snapshots the entries resume (384 MiB flat images, gzipped) |

## The host contract

`src/host.HC` is the whole interface. Required: load the snapshot into guest RAM, present a frame, VGA
palette writes, ATA sector reads and writes, mouse and keyboard state, wall-clock pacing, a speaker tone.
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
Original QEMU/KVM also supplies 200 raster cases: native and accelerated line/
triangle pixels, depth, collision counts, extents, nearest distance and final
random seeds agree. These are bounded checks, not complete x86 or graphics
coverage. Divide faults enter the guest's #DE handler for valid ring-zero,
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

With holyc-wasm, compile `src/snapshot.HC` in strict mode (every `import` prototype in `host.HC` becomes a
WebAssembly import) and export what your host calls back into; then implement the contract on top of
holyc-wasm's `createHost()`. TempleOS-Web does exactly this: `engine/compile.js` and `engine/build.mjs` are
the build, `engine/host.js` the host, `engine/jit.js` the optional JIT. From that checkout, with this one
cloned or symlinked beside it as `hemu`:

```sh
node engine/build.mjs build                    # hemu.wasm + hemu-smp.wasm + hemu-smp.json
node tools/hemu/measure.mjs                    # src/test.HC, the self-checking battery, headless
node tools/hemu/boot-test.mjs                  # src/boot.HC: the demo kernel draws its framebuffer
```

The guest harnesses - boot the desktop, run catalog games, compare the JIT against the interpreter,
exercise the guest-execution API - are in the same `tools/hemu/`, documented in `engine/README.md`.

## Backend guest execution

`src/guestcall.HC` lets the host call one validated guest function with up to eight stack arguments exactly
the way a hardware interrupt enters a handler: at an instruction boundary with IF=1, a frame is pushed on
the current task's stack, the callee runs with IF=0, and when it returns to the sentinel address the
interrupted CPU state is restored bit-exactly. The callee's side effects on guest memory persist; nothing
else does. This is the discipline TempleOS itself uses for IRQ1, so the JobQue family (TaskExe, JobResScan,
PopUp) is safe by construction. Only core 0 injects; a callee that faults or exceeds its budget is reported
as failed and the interrupted state is still restored. TempleOS-Web's `engine/guestexec.js` is the host-side
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

Interpreter, block JIT and graphics HLE are separate execution layers. Graphics
fast paths are resolved by the guest's symbol names and reject unsupported
transforms. Persistent checks compare their pixels, depth and collision results
against the original guest routines with HLE disabled. The SMP build (`SMP_SNAP`)
runs one core per host thread over shared memory and has separate worker/barrier
regressions. Browser networking for TOOM multiplayer is not implemented.

`src/Atom.HC` owns memory read/modify/write operations, including implicit-lock
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

These checks cover observed workloads and regressions, not complete x86 hardware conformance or complete
game playthroughs.

## Snapshots

The RAM images are captured from TempleOS booted under QEMU with the machine paused, together with the
register state that becomes `src/snapregs*.HC`; the two must match, so re-bake the registers after every
capture. The recipes live in TempleOS-Web's `tools/snapshot/`.

The web host can also save and restore a complete live machine. Its versioned
container includes the exact compiled engine, every core and device's state,
guest memory, host input/settings, and the full current disk. SnapshotResume
reconnects the host JIT and displays the saved frame without resetting the CPU.
See TempleOS-Web/tools/hemu/README.md for the format and round-trip tests.
