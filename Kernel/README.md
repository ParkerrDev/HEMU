# HEMU browser runtime

This directory holds HEMU's HolyC CPU and devices together with their
WebAssembly build, host, workers, x86-to-WASM JIT and machine lifecycle.
`Host.HC` defines the emulator's host contract. HolyC-wasm supplies the compiler
and language runtime from the `holyc-wasm/` mount pinned in HEMU's `Siblings.txt`.
TempleOS-Web imports this machine; its `Adam/Os.js` connects it to the site's
windows and controls. HEMU's standalone `Desktop/` uses the same runtime.

| File | What |
|---|---|
| `Compile.js` | `compileHemu()`: strict compilation of HEMU with the exports the host calls |
| `Build.mjs` | writes both engines, SMP metadata and lazy `disk.wasm`; checks generated HolyC modules |
| `Host.js` | `createHemuHost()`: HolyC-wasm's `createHost()` plus the imports declared in `Host.HC` |
| `Render.HC` | optional fast graphics with complete stock-code guards; `RenderFastSet` selects original drawing instructions |
| `JitCore.HC`, `Jit*.HC` | decode x86 instructions and emit WASM blocks with cached registers, deferred flags and native dispatch |
| `Jit.js`, `JitCode.js` | attach CPU memory, install generated modules and manage browser function tables; `JitCode.js` contains compiled HolyC bytes |
| `GuestExec.js` | resolves guest symbols and exposes queued execution, inclusion, file writing and task launches over `GuestCall.HC` |
| `GuestInput.js`, `KeyQueue.js` | guest mouse metadata, relative motion and IRQ1 keyboard delivery |
| `GuestWin.HC`, `GuestWindows.js` | optional native document surfaces, task identities and browser tool actions |
| `Disk.HC`, `DiskHost.HC` | qcow2 and FAT32 algorithms, shared by browser storage and offline capture tools |
| `QCow2.js`, `DiskStore.js` | lazy disk-module loading, sector buffers and IndexedDB C: persistence |
| `Stock.js`, `Ram.js` | captured CPU/RAM/disk identity and sparse RAM reconstruction |
| `StockDiskWorker.js` | background stock disk download, validation and inflation |
| `Machine.js` | shared worker startup, request lifetimes, cancellation, fault handling and restart for the site and standalone desktop |
| `HemuWorker.js` | single-core engine worker and the SMP bootstrap processor |
| `HemuSmpWorker.js` | application processors over shared WebAssembly memory |
| `Snapshot.js` | full saved-machine format and validation of correction metadata in historical saves |

## Build and check

From the HEMU root:

```sh
while read dir url sha; do git clone -q $url $dir && git -C $dir checkout -q $sha; done <Siblings.txt
npm install
node Kernel/Build.mjs
node Kernel/Test/Chk.mjs             # build and CPU/JIT/device/clock/input checks
node Kernel/Test/Chk.mjs --full      # also guest and production-worker checks
node Kernel/Test/Chk.mjs --desktop   # installed Chromium, one and four cores
node Misc/Server.mjs                # standalone machine window
```

The runner stops on failed assertions or timeouts and prints the compiler path.
Guest checks read the paired compressed RAM and disk fixtures; `LIVE` and `RAW`
can override them. See [the check list](Test/README.md) for coverage and limits.
Each guest can need several hundred MiB. `GuestHarness.mjs` provides source/call
access; `WorkerHost.mjs` exercises production workers, including clocks,
presentation, execution and snapshot events.

TempleOS-Web owns its shell integration checks in `Adam/` and `Apps/`, and its
game catalog and renderer/input harnesses. A successful launch alone does not
prove a playthrough or hardware-equivalent performance.

## What GuestExec.js and GuestInput.js guarantee

Games start in a fresh Servant task through a short Adam job calling PopUp. No command typing or
character-by-character TaskMsg injection is involved. FileWrite receives raw bytes staged above the guest
allocator's RAM, preserving embedded DolDoc sprites. Already-compressed .Z uploads use FOpen/FBlkWrite so
FileWrite cannot recompress them. Launches reject a second active game, report compile and runtime
exceptions, and release their slot when the task ends. A running event means the task started; compilation
can still fail afterwards. `GuestChk.mjs` exercises execution, failure reporting, directory creation, binary
upload, independent persisted-sector readback, disk inclusion, launch cleanup, animation and busy refusal.
`JitRecycle.mjs` checks repeated compilation into reused guest addresses; each cached JIT block validates its
decoded bytes at entry, including native dispatch-table calls, before executing.

`jitState` attaches one CPU owner to this module. Attachment discards compiled
blocks, the dispatch module and optional CPU bindings from the previous owner;
the caller then supplies its own `jitX87`, `jitSeg` and `jitChain` bindings when
available. Omitted bindings use unconfigured defaults instead of earlier
addresses. An unregistered FS/GS base ends the compiled prefix so the
interpreter owns the instruction; a registered base whose value is zero remains
a valid compiled operand. `jitReset` alone
clears code caches while retaining the current owner. Only the BSP binds its
WASM dispatch table to the engine's block metadata; APs retain private code
caches and consult the same graphics mode before executing a cached block. `JitOwner.test.mjs`
checks that missing handlers and setup cannot access a previous owner's memory.

`GuestInput.js` applies relative mouse deltas once from the guest's current position, respecting games that
call MsSet to recenter. Keyboard state reaches TempleOS only through set-1 make/break bytes and IRQ1.
The optional BIOS repeat follows the guest PS/2 typematic configuration. Capture hints follow the foreground task's mouse visibility and input
ownership; hosts forward them to the UI, and pointer lock still requires a user gesture. Frame input polling
stops when the 64-entry keyboard FIFO fills, leaving the remaining events in the host queue. `InputChk.mjs`
checks HolyCraft's neutral spawn, idle camera, relative look, held movement, release and a 200-event burst in
the live guest.

## Optional window surfaces

`windows` worker requests enable or disable passthrough, detach or attach an
existing task, or create/update/close a browser-owned native DolDoc task.
`GuestWin.HC` is compiled by TempleOS only when enabled. `GuestWindows.js`
transports indexed pixels, geometry and queued native button actions; it does
not draw documents. Slot operations carry both task address and task number so
closed or reused slots cannot redirect input or kill a replacement task.

Surfaces support bordered native documents, sprites and standard scrollbars.
Custom DrawIt and control callbacks, custom document tag callbacks, songs,
fullscreen/captured-pointer programs and persistent graphics stay on the main
desktop. A window that becomes incompatible returns there. Browser-owned tasks
use ordinary native document buttons and dispatch actions to their original host
handlers. Disable restores guest windows and closes only browser-owned tasks.

The renderer uses a bounded virtual I/O transaction at port `0x5047`. Acquisition
requires core zero in ordinary Run with interrupts disabled, and stops the other
cores through the existing capture barrier. Run completes the transaction before
returning, even past its normal frame budget. It rejects injected-call and nested
capture use. A reopened IF, CPU fault, HLT or 32-million-instruction limit retains
the stopped machine with fault reason 4; resume and snapshot export require a
restart. Native code checks document and allocator locks before drawing, restores
shared drawing buffers, then releases the other cores before ending its try scope.

`Test/GuestWindows.mjs` checks native pixels, input ownership, task lifecycle and
fallback. `Test/WinSurface.test.mjs` checks port admission, budget draining,
capture nesting and retained faults. TempleOS-Web supplies the real browser drag
and native button tests. Saved older engines without `WinSurfaceActive` cannot
enable passthrough until restarted with a current engine.

## Stock startup

Stock startup resumes a paired RAM/register/disk capture. The
[native capture recipe](../Misc/Capture/README.md) prepares the document-clipping
and autocomplete display fixes in native source before the OS compiles them.
It then opens the Welcome card alongside the native Take Tour question and
captures the stopped machine. There is no guest correction compilation or
Welcome construction on the browser's startup path.

`stock.json` binds the RAM, stopped register dump, generated register source,
base disk and changed sectors. Each built engine embeds matching `hemu.stock`
metadata. Loaders reject RAM-only imports whose identity or topology does not
match. The native captures preserve supported CPU state; PIC/PIT/RTC state is
initialized by HEMU's startup policy, not restored from QEMU. See the
[CPU and device limits](../README.md#devices-and-performance).

`live.bin.gz` and `live-smp.bin.gz` contain the gzipped `HMRAM001` representation.
`Misc/Ram.py` groups adjacent nonzero 64-byte blocks into ranges. A header records
the full RAM size and range count, followed by offset/length pairs and range
bytes. The format is lossless: omitted blocks are all zero. `Ram.js` validates
alignment, bounds, ordering and payload length before restoring the ranges into
zeroed 384 MiB guest memory. The compressed and full RAM hashes remain in the
manifest; `packedBytes` bounds decompression. Startup inflates the packed ranges,
not a flat 384 MiB stream, and needs no inflate-worker pool or gzip cut table.

The host can overlap RAM download, engine compilation and worker startup.
The disk has a separate worker so its decompression does not stall execution.
The site's build generates page module preloads with `Misc/Preload.mjs`; those
network and UI choices belong to TempleOS-Web. Normal HTTP caching applies to
the capture assets, and its CDN serves immutable commit-qualified paths.

C: persistence stores a base image and changed sectors in IndexedDB. A Web Lock
selects one writer; other tabs report that they are not saving. Restart flushes
pending writes before closing the machine. Importing a disk or full snapshot
replaces the saved drive. The browser may still evict site storage; portable
exports are independent backups.

## Saved machines and build identity

Full `.hemu` saves embed their exact engine, RAM, disk, CPU/device state and
host settings. They resume their saved windows and code. Historical correction
metadata is validated when those saves load; this is separate from stock
startup. See [the saved-machine format](Test/README.md#full-machine-snapshots).

The JIT generator has its own small WASM memory. It accepts guest instruction
bytes and CPU addresses, then returns a compiled block. Disk-format code also
uses separate memory. Neither helper enlarges guest RAM or saved snapshots, and
both can serve older embedded engines. Disk code loads only when a disk is needed.

After changing JIT HolyC, run `node Kernel/JitBuild.mjs`. Normal builds reject
stale generated JIT and allocator bytes. `JitNative.mjs` compares the generated
modules with the same source compiled by the original TempleOS compiler.

`Jit.js` learns CPU-state addresses through `__jit_state` and `__jit_seg`, rather
than hard-coded structure offsets. The host, JIT, compiler runtime and engine
must still come from a compatible build. Build both engines with HEMU's pinned
compiler and deploy their matching runtime. The small framebuffer `Boot.HC`
fixture does not boot TempleOS through its DVD/BIOS loader. The original-HolyC
adapter is a headless test host; the Linux KVM desktop is a separate backend.
