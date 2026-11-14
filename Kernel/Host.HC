//============================================================================
// Host.HC - hemu's host contract: everything the emulator needs from whatever runs it.
//
// hemu is plain HolyC. It touches the outside world only through the functions declared here, so a
// host (a compiler's runtime + the program that drives the frame loop) supplies these and nothing
// else. Under holyc-wasm they become WebAssembly imports from "env" (strict mode turns `import`
// prototypes into real imports) and HolyC-wasm/hemu/host.js implements them; another compiler links
// them to its own implementations. Addresses cross this boundary as guest-linear pointers.
//
// Everything else hemu calls is standard HolyC that any runtime provides (MAlloc, Pow/Sin/Ln,
// printing) plus two compiler intrinsics, listed at the end.
//
// (Parameter names here deliberately avoid Snapshot.HC's #define'd register names - reg, rip, rfl,
// fpr, fsp, x87_cw, xmm_lo... - which would otherwise expand inside these prototypes.)
//
// The frame model: the host calls Main once per display frame (holyc-wasm exports it as __main;
// Snapshot.HC keeps its state in globals between calls). A host that runs Main only once should call
// HemuInit once and then call Frame per display frame itself.
//============================================================================

// ---- required ---------------------------------------------------------------------------------
import U0  __snap_load(U8 *ram);                      // copy the booted-RAM snapshot (live.bin) into guest RAM at mem
import U0  __present(U8 *fb, I64 w, I64 h);           // show w*h 8-bit palette-index pixels (the composited desktop)
import Bool __capture_lock(); //Pause other cores before reading the display.
import U0 __capture_unlock(); //Release them after the completed frame is copied.
import U0  __host_palette(I64 index, I64 rgb24);      // VGA DAC write: palette entry index (0..15) -> 0xRRGGBB
import U0  __host_disk(I64 lba, I64 count, U8 *buf);     // ATA read: stage count 512-byte sectors of C: into buf
import U0  __host_disk_wr(I64 lba, I64 count, U8 *buf);  // ATA write: persist count sectors from buf (host overlay)
import I64 __host_msx();                              // absolute mouse x (0..639), host-owned cursor
import I64 __host_msy();                              // absolute mouse y (0..479)
import I64 __host_msb();                              // mouse buttons: bit0 left, bit1 right
import I64 __host_wheel();                            // cumulative mouse-wheel position (-> ms.pos.z)
import I64 __host_key();                              // next raw set-1 byte, <0 when drained
import I64 __host_ns();                               //nanoseconds since the last frame
import I64 __host_dt();                               // real milliseconds since the last frame (wall-clock pacing)
import I64 __host_budget();                           // guest instructions to run this frame
import I64 __host_time(I64 cmos_reg);                 // host wall clock for the CMOS RTC register the guest selected
import U0 __host_snd(F64 hz,U64 ns); //Speaker frequency (0 off) and observed TSC nanoseconds.

// ---- optional: native block JIT / per-core dispatch ------------------------------------------
// A host without a JIT returns 0 from __jit_state and 0 from __ap_run; hemu then runs as a pure
// interpreter and never calls the rest. HolyC-wasm/hemu/jit.js implements them (x86-64 -> WASM).
import I64 __jit_state(U64 *regs, U64 *flags, U64 *pc); // hand over the CPU-state addresses; return 1 to enable the JIT
import U0  __jit_x87(F64 *x87regs, I64 *x87top, U64 *x87sw);    // x87 register stack, top, status word (float blocks)
import U0  __jit_seg(U64 *fsb, U64 *gsb, U64 *tscp, U64 *x87cw, U64 *xlo, U64 *xhi);  // segment bases, TSC, control word, XMM halves (FXSAVE/FXRSTOR)
import U0  __jit_chain(U64 *blocks, I64 *counts);     // per-slot compiled-block tables, so the host can chain blocks natively
import I64 __jit_compile(U64 at);                    // compile the block at rip: its instruction count, or 0 if it cannot
import I64 __jit_run(U64 at);                        // run the compiled block at rip: instructions executed (bit 30: IF window)
import I64 __jit_dispatch(I64 budget);                // run a chain of compiled blocks up to budget: instructions executed
import I64 __ap_run(U64 at, I64 budget);             // SMP application cores: their per-core chain (0 = not compiled)

//Optional coordinated RAM ownership. An uncoordinated host refuses wide SMP.
import Bool __bus_poll(); //TRUE to continue; FALSE unwinds at an instruction boundary.
import Bool __bus_lock(); //All participants must have registered guarded,polled access.
import U0 __bus_unlock(); //After the operand,registers and flags are complete.

// ---- compiler intrinsics (not imports) --------------------------------------------------------
//   I64 MyCore;                          this core's index; 0 on a single-core build. holyc-wasm: a per-instance
//                                          WASM global the host sets per worker. TempleOS's compiler: Gs->num.
//   U64 __a_<op><bits>(U8 *addr, U64 v[, U64 nv]);   op = add|and|or|xor|xchg|cmpxchg, bits = 8|16|32|64:
//                                          sequentially-consistent atomic RMW on shared memory, returning the old
//                                          value (cmpxchg: v is the expected value, nv the replacement).
//                                          These names are custom host intrinsics, not V5.03 symbols.
//                                          A native host must supply equivalent atomic operations.
