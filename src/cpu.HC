#include "host.HC"                  // the host contract: every import hemu makes (see host.HC)
#include "core.HC"                  // per-core CPU state + SMP/guest-call scaffolding shared by every entry

U8 *mem;                            // guest RAM (MAlloc'd so the snapshot can use 100s of MB)
U64 mem_size;                       // bytes of guest RAM; anything >= this is MMIO (LAPIC/HPET/IOAPIC)
U8 g_pfx[256];                       // prefix-byte lookup (1 = legacy prefix) - skips an 11-way compare per instr
U0 InitMem(U64 sz)
{
  I64 i;
  mem = MAlloc(sz + 16); mem_size = sz;                       // +16 pad absorbs boundary-spanning reads
  for (i = 0; i < 256; i++) g_pfx[i] = 0; g_pfx[0x66] = 1; g_pfx[0x67] = 1; g_pfx[0xF0] = 1; g_pfx[0xF2] = 1; g_pfx[0xF3] = 1; g_pfx[0x2E] = 1; g_pfx[0x36] = 1; g_pfx[0x3E] = 1; g_pfx[0x26] = 1; g_pfx[0x64] = 1; g_pfx[0x65] = 1; g_desk = MAlloc(307200);
  ata_buf = MAlloc(131072);                                  // 256 sectors * 512 B: ATA PIO read staging
}
#include "sym.HC" //HEMU finds what it needs in the guest by name.

// PER-CORE state (reg/rip/rfl/halted/irq_stall/fpu/seg/decode/icount) lives in CCpuState g_cpu_st[] - defined
// in core.HC (included above), accessed through #define reg CST.f_reg etc. (CST = this instance's MyCore()
// slot). SHARED state (mem, devices, JIT cache, clocks, cr*, idtr/gdtr) stays below.
U64 g_hle_blit;                      // entry addr of the transparent compositor blit to run natively (0=off)
U8 *g_desk;                          // last COMPLETE frame (desktop + the OS's own cursor), captured tear-free
I64 g_desk_ready,g_desk_seq,g_present_seq; U64 g_capture_rip,g_capture_text;
U64 g_jit_on;                        // 0 = pure interpreter (zero-init; a JIT host sets it 1 after wiring __jit_*).
U64 g_jit_rip[65536];                // direct-mapped block cache: the rip occupying slot ((rip^(rip>>16)) & 0xFFFF)
                                     // (hash, not plain low bits: game code copies sit 0x40000/0xA0000 apart ->
                                     // same low 16 bits for EVERY corresponding block -> permanent slot ping-pong)
I64 g_jit_n[65536];                  // that block's instr count (>0 = JIT'd), 0 = tried+unjittable, -1 = still counting
I64 g_jit_hot[65536];                // per-slot hotness counter until the compile threshold (64)
U8 g_hooktbl[65536];                 // rip&0xFFFF -> "maybe a special address" gate: lets Step() skip the four
                                     // 64-bit hook compares for the ~98% of instructions that aren't at one.
                                     // 16-bit (was 8-bit): an 8-bit gate forced every hot fn sharing a hook's
                                     // low byte to stay interp'd -> never JIT'd (was 48% of all chain-breaks).
U64 ata_words, ata_seccnt, ata_pos, ata_r3, ata_r4, ata_r5;   // ATA PIO read - serve C: sectors (disk == live.bin)
U64 ata_wr, ata_wlba, ata_wcnt;                              // ATA PIO write in progress (lba, count) -> __host_disk_wr
U8 *ata_buf;
U64 g_badop;
// system state: control regs, descriptor tables, MSRs, TSC, code/stack segments
U64 cr0, cr2, cr3, cr4, cr8, g_cs, g_ss; U64 idtr_base, idtr_limit, gdtr_base, gdtr_limit;
U64 msr_efer, msr_star, msr_lstar, msr_sfmask, msr_kgsbase, msr_apic;   // msr_fsbase/msr_gsbase moved into CCpuState (per-core)
U64 g_xmm_lo[NCORES][16], g_xmm_hi[NCORES][16];   // SSE XMM registers - PER-CORE (xmm_lo/xmm_hi #defines in core.HC): an AP suspended mid-XMM must not be clobbered by another core
I64 g_lockf[NCORES];                  // PER-CORE: 1 = the current instruction had a 0xF0 LOCK prefix (lockf #define in core.HC) - makes the RMW atomic on shared memory
// devices: dual 8259 PICs + 8254 PIT (channel 0 -> IRQ0 = the scheduler tick)
I64 pic1_base, pic1_mask, pic1_irr, pic1_isr, pic1_initstep; I64 pic2_base, pic2_mask, pic2_irr, pic2_isr, pic2_initstep;
#include "time.HC"
I64 irq_count;                       // # of hardware IRQs delivered (instrumentation)
// CMOS RTC (ports 0x70/0x71): TempleOS reads wall-clock time here; tS/Now() and
// many task timeouts derive from it, so it must ADVANCE or the desktop never wakes.
I64 rtc_idx;                         // selected CMOS register (last OUT 0x70)
U64 rtc_base_sec;                    // seconds-of-day at snapshot; + elapsed below
I64 rtc_dow, rtc_day, rtc_mon, rtc_year;
// PS/2 keyboard (IRQ1, port 0x60) + mouse (IRQ12). Host pushes scancodes/packets here.
#include "keyboard.HC"
I64 ms_byte0, ms_byte1, ms_byte2, ms_has, ms_phase;   // pending PS/2 mouse 3-byte packet
// PS/2 controller command-response FIFO (polled by KbdCmdRead during mouse/kbd install + config).
// Without this the mouse install (MsHardRst) never gets its 0xFA ACKs, ms_hard.install_in_progress
// stays TRUE, and IRQKbd bails on every keystroke (Mouse.HC) -> keyboard is dead.
I64 ps2q[16], ps2q_ms[16], ps2qh, ps2qt, ms_next, cfg_next;
U0 Ps2Resp(I64 b, I64 isms) { ps2q[ps2qt & 15] = b; ps2q_ms[ps2qt & 15] = isms; ps2qt++; }
// PC speaker: PIT channel 2 (ports 0x42/0x43) sets the tone; port 0x61 bits0,1 gate it.
I64 pit2_reload, pit2_div, pit2_wlo, spk_on;
U0 UpdateSpk()
{ if (spk_on && pit2_div) __snd(1193182.0 / pit2_div); else __snd(0.0); }
// MMIO: any guest access at/above mem_size goes here. LAPIC/HPET/IOAPIC live high
// in the physical map and are NOT in the RAM snapshot, so we emulate the few
// registers TempleOS reads and swallow the rest (instead of trapping out-of-bounds).

#define F_CF 0x0001
#define F_PF 0x0004
#define F_ZF 0x0040
#define F_SF 0x0080
#define F_IF 0x0200
#define F_DF 0x0400
#define F_OF 0x0800

//---------------------------------------------------------------- MMIO (LAPIC / HPET)
// TempleOS reaches the LAPIC and HPET through an "uncached alias" whose base we
// don't know a priori, so we identify a device by the low 12 bits of the address
// (the register offset within its 4 KiB page). The pairs that matter for a live
// single-CPU desktop: LAPIC EOI (0xB0, write -> ignore), LAPIC ID (0x20),
// SVR (0xF0), and a monotonic HPET main counter (offset 0xF0/0xF8 on its page).
U64 MmioRd(U64 a, I64 sz)
{
  U64 off; off = a & 0xFFF;
  if (off == 0x20)  return MyCore() << 24;    // LAPIC APIC_ID register (id in bits 24-31) -> THIS core
  if (off == 0x30)  return 0x50014;           // LAPIC version
  if (off == 0xF0)  return hpet_ctr;          // HPET main counter (lo) - also LAPIC SVR read
  if (off == 0xF4 || off == 0xF8) return hpet_ctr >> 32;  // HPET main counter (hi)
  return 0; }
U0 MmioWr(U64 a, I64 sz, U64 v)
{
  // SMP: the runtime inter-processor wakeup. TempleOS's MPInt writes ICR_HIGH (dest apic_id<<24)
  // then ICR_LOW (delivery mode + vector) to send a directed fixed IPI (I_WAKE) to an idle AP.
  U64 off; off = a & 0xFFF;
  if (off == 0x310) { g_icr_high[MyCore()] = v; return; }   // ICR_HIGH: destination
  if (off == 0x300) {                                        // ICR_LOW: fire
    I64 dest = g_icr_high[MyCore()] >> 24;                   // dest apic_id (== core slot)
    I64 dm = (v >> 8) & 7;                                   // delivery mode (0=fixed)
    if (dm == 0 && dest >= 0 && dest < g_ncore && dest != MyCore())
      __a_xchg64(&g_ipi_pending[dest], (v & 0xFF) | 0x100); // mark this AP's pending wake-vector (|0x100). ATOMIC (seq-cst): publishes the sender's prior task-state writes to the woken AP (x86-TSO ordering across real cores)
    return; }
  // other LAPIC EOI / config writes: acknowledged, no state to keep.
}

//---------------------------------------------------------------- guest memory
// WASM loads/stores are little-endian + unaligned-safe, matching x86 - so a
// pointer-cast deref is one host load instead of a byte loop. Accesses at/above
// mem_size are device MMIO, routed away from the RAM buffer so they never trap.
// TempleOS also maps an UNCACHED ALIAS of all RAM at virtual 2^40 + phys (for
// cache-bypassing access to shared structures like task message queues); strip
// that bit so aliased RAM access hits real RAM instead of being dropped as MMIO.
U64 RdMem(U64 a, I64 sz)
{
  if (a >= mem_size) { a &= 0xFFFFFFFFFF; if (a >= mem_size) return MmioRd(a, sz); }
  if (sz == 8) return *(U64 *)(mem + a); if (sz == 4) return *(U32 *)(mem + a); if (sz == 2) return *(U16 *)(mem + a);
  return mem[a]; }
U0 WrMem(U64 a, I64 sz, U64 v)
{
  if (a >= mem_size) { a &= 0xFFFFFFFFFF; if (a >= mem_size) { MmioWr(a, sz, v); return; } }
  if (sz == 8) { *(U64 *)(mem + a) = v; return; }
  if (sz == 4) { *(U32 *)(mem + a) = v; return; }
  if (sz == 2) { *(U16 *)(mem + a) = v; return; }
  mem[a] = v; }

//---------------------------------------------------------------- fetch / imm
U64 Fetch8()  { U64 b = mem[rip]; rip++; return b; }
U64 Fetch32() { U64 v = *(U32 *)(mem + rip); rip += 4; return v; }   // rip is always code in RAM - skip RdMem's MMIO check
U64 Fetch64() { U64 v = RdMem(rip, 8); rip += 8; return v; }
I64 SignExt8(U64 b)  { b &= 0xFF;       if (b & 0x80)       return b - 0x100;       return b; }
I64 SignExt32(U64 v) { v &= 0xFFFFFFFF; if (v & 0x80000000) return v - 0x100000000; return v; }
U64 SizeMask(I64 sz)
{ if (sz == 8) return 0xFFFFFFFFFFFFFFFF; if (sz == 4) return 0xFFFFFFFF; if (sz == 2) return 0xFFFF; return 0xFF; }
I64 SignExtTo64(U64 v, I64 sz)
{ U64 m, sb; if (sz == 8) return v; m = SizeMask(sz); sb = 1 << (sz * 8 - 1); v &= m; if (v & sb) return v | ~m; return v; }
I64 FetchImm(I64 sz)
{ U64 v; if (sz == 1) return SignExt8(Fetch8()); if (sz == 2) { v = RdMem(rip, 2); rip += 2; return v; } return SignExt32(Fetch32()); }

//---------------------------------------------------------------- registers
U64 RdReg(I64 i, I64 sz)
{ if (sz == 8) return reg[i]; if (sz == 4) return reg[i] & 0xFFFFFFFF; if (sz == 2) return reg[i] & 0xFFFF; if (!hasRex && i >= 4 && i < 8) return (reg[i - 4] >> 8) & 0xFF; return reg[i] & 0xFF; }
U0 WrReg(I64 i, I64 sz, U64 v)
{
  if (sz == 8) { reg[i] = v; return; }
  if (sz == 4) { reg[i] = v & 0xFFFFFFFF; return; }                 // 32-bit zero-extends
  if (sz == 2) { reg[i] = (reg[i] & ~0xFFFF) | (v & 0xFFFF); return; }
  if (!hasRex && i >= 4 && i < 8) { reg[i - 4] = (reg[i - 4] & ~0xFF00) | ((v & 0xFF) << 8); return; }
  reg[i] = (reg[i] & ~0xFF) | (v & 0xFF); }

#include "Alu.HC"

//---------------------------------------------------------------- ModRM + SIB
// immlen = number of immediate bytes that follow this instruction's disp. It only
// matters for RIP-relative operands: x86 measures RIP-relative from the END of the
// WHOLE instruction (past the immediate), so callers with a trailing imm must pass
// its size or the EA lands `immlen` bytes short (this silently corrupted neighbours).
U0 DecodeModRM(I64 immlen = 0)
{
  U64 b, sib, addr = 0; I64 base_rm, ss, idxf, idx, bs;
  b = mem[rip]; rip++;                  // inline Fetch8 (no inlining in the compiler; this is per-modrm hot)
  md = (b >> 6) & 3; rg = ((b >> 3) & 7) | (rexR << 3); base_rm = b & 7;
  if (md == 3) { isMem = 0; rm = base_rm | (rexB << 3); return; }
  isMem = 1;
  if (base_rm == 4) {
    sib = Fetch8(); ss = (sib >> 6) & 3; idxf = (sib >> 3) & 7; idx = idxf | (rexX << 3); bs = (sib & 7) | (rexB << 3); if (!(idxf == 4 && !rexX)) addr += reg[idx] << ss; if ((sib & 7) == 5 && md == 0) addr += SignExt32(Fetch32()); else addr += reg[bs];
  } else if (base_rm == 5 && md == 0) {
    addr = SignExt32(Fetch32());     // RIP-relative: read disp FIRST (advances rip past it),
    addr += rip + immlen;            // THEN add END-of-instruction rip (past any trailing immediate)
  } else {
    addr = reg[base_rm | (rexB << 3)]; }
  if (md == 1) addr += SignExt8(Fetch8()); else if (md == 2) addr += SignExt32(Fetch32()); ea = addr + g_segbase; }
U64 RdRM(I64 sz) { if (isMem) return RdMem(ea, sz); return RdReg(rm, sz); }
U0  WrRM(I64 sz, U64 v) { if (isMem) WrMem(ea, sz, v); else WrReg(rm, sz, v); }

#include "Shift.HC"

//---------------------------------------------------------------- SHLD / SHRD
U0 DoShld(I64 isLeft, U64 src, I64 cnt, I64 sz)
{
  U64 dest, res, m; I64 bits, last; m = SizeMask(sz); bits = sz * 8; if (sz == 8) cnt &= 63; else cnt &= 31; if (cnt == 0) return; dest = RdRM(sz) & m; src &= m;
  if (isLeft) { res = ((dest << cnt) | (src >> (bits - cnt))) & m; last = (dest >> (bits - cnt)) & 1; }
  else        { res = ((dest >> cnt) | (src << (bits - cnt))) & m; last = (dest >> (cnt - 1)) & 1; }
  WrRM(sz, res); if (last) rfl |= F_CF; else rfl &= ~F_CF; SetZSP(res, sz); }

//---------------------------------------------------------------- grp3 (F6/F7): TEST/NOT/NEG/MUL/IMUL/DIV/IDIV
U0 Grp3(I64 sz)
{
  I64 d, bit, sa, sl, sdd; U64 a, r, imm, hi, lo, b, q, rem, bv, al, ah, bl, bh, ll, lh, hl, hh, mid; d = rg & 7; a = RdRM(sz);
  if (d <= 1) { imm = FetchImm(sz); SetLogic((a & imm) & SizeMask(sz), sz); return; }   // TEST
  if (d == 2) { WrRM(sz, ~a); return; }                                                 // NOT
  if (d == 3) { r = 0 - a; WrRM(sz, r); SetSub(0, a, r, sz); return; }                  // NEG
  if (d == 4 || d == 5) {                                                               // MUL / IMUL
    b = RdReg(0, sz);
    if (sz == 8) {
      al = a & 0xFFFFFFFF; ah = a >> 32; bl = b & 0xFFFFFFFF; bh = b >> 32; ll = al * bl; lh = al * bh; hl = ah * bl; hh = ah * bh; mid = (ll >> 32) + (lh & 0xFFFFFFFF) + (hl & 0xFFFFFFFF); lo = (ll & 0xFFFFFFFF) | (mid << 32); hi = hh + (lh >> 32) + (hl >> 32) + (mid >> 32);
      if (d == 5) { if (a >> 63) hi -= b; if (b >> 63) hi -= a; }
      reg[0] = lo; reg[2] = hi;
    } else {
      a &= SizeMask(sz); b &= SizeMask(sz); if (d == 5) r = SignExtTo64(a, sz) * SignExtTo64(b, sz); else        r = a * b; WrReg(0, sz, r & SizeMask(sz)); WrReg(2, sz, (r >> (sz * 8)) & SizeMask(sz)); }
    return; }
  // DIV / IDIV
  if (a == 0) { halted = 3; return; }
  if (sz == 8) {
    hi = reg[2]; lo = reg[0];
    if (d == 6 && hi == 0) { reg[0] = lo / a; reg[2] = lo % a; return; }
    if (d == 7) { sl = lo; sa = a; reg[0] = sl / sa; reg[2] = sl % sa; return; }  // IDIV (64-bit-fits)
    q = 0; rem = 0;
    for (bit = 127; bit >= 0; bit--) { rem = rem << 1; if (bit >= 64) bv = (hi >> (bit - 64)) & 1; else bv = (lo >> bit) & 1; rem |= bv; if (rem >= a) { rem -= a; q |= (U64)1 << bit; } }
    reg[0] = q; reg[2] = rem;
  } else {
    hi = RdReg(2, sz); lo = RdReg(0, sz);
    if (d == 6) { r = (hi << (sz * 8)) | lo; WrReg(0, sz, r / a); WrReg(2, sz, r % a); }
    else { sdd = (SignExtTo64(hi, sz) << (sz * 8)) | (lo & SizeMask(sz)); sa = SignExtTo64(a, sz);
           WrReg(0, sz, sdd / sa); WrReg(2, sz, sdd % sa); } } }

//---------------------------------------------------------------- string ops (+REP)
U0 StrStep(I64 op, I64 sz)
{
  I64 d; U64 a, b; if (rfl & F_DF) d = -sz; else d = sz;
  if      (op == 0xA4 || op == 0xA5) { WrMem(reg[7], sz, RdMem(reg[6], sz)); reg[6] += d; reg[7] += d; }  // MOVS
  else if (op == 0xAA || op == 0xAB) { WrMem(reg[7], sz, RdReg(0, sz)); reg[7] += d; }                    // STOS
  else if (op == 0xAC || op == 0xAD) { WrReg(0, sz, RdMem(reg[6], sz)); reg[6] += d; }                    // LODS
  else if (op == 0xA6 || op == 0xA7) { a = RdMem(reg[6], sz); b = RdMem(reg[7], sz); SetSub(a, b, a - b, sz); reg[6] += d; reg[7] += d; }  // CMPS
  else if (op == 0xAE || op == 0xAF) { a = RdReg(0, sz); b = RdMem(reg[7], sz); SetSub(a, b, a - b, sz); reg[7] += d; }                    // SCAS
}
U0 DoStr(I64 op, I64 sz)
{
  I64 cmpkind; U64 n, total, i;
  cmpkind = (op == 0xA6 || op == 0xA7 || op == 0xAE || op == 0xAF);   // SCAS/CMPS terminate on ZF
  if (!repf) { StrStep(op, sz); return; }
  // Bulk fast path for REP MOVS/STOS (forward, flat) - TempleOS's MemCpy/MemSet are REP MOVSQ/STOSQ
  // over large buffers; emulating them element-by-element through StrStep was the single biggest
  // interpreter cost. Do them as one native copy/fill. (DF=0, no segment override, in-RAM only.)
  if (g_segbase == 0 && !(rfl & F_DF) && reg[1] > 0) {
    n = reg[1]; total = n * sz;
    if (op == 0xA4 || op == 0xA5) {                                   // REP MOVS: copy RSI -> RDI
      U64 s = reg[6], dt = reg[7];
      if (s + total <= mem_size && dt + total <= mem_size) { if (sz == 8) for (i = 0; i < n; i++) *(U64 *)(mem + dt + i * 8) = *(U64 *)(mem + s + i * 8); else         for (i = 0; i < total; i++) mem[dt + i] = mem[s + i]; reg[6] = s + total; reg[7] = dt + total; reg[1] = 0; return; }
    } else if (op == 0xAA || op == 0xAB) {                            // REP STOS: fill RDI with AL/AX/EAX/RAX
      U64 dt = reg[7], val = RdReg(0, sz);
      if (dt + total <= mem_size) { if      (sz == 8) for (i = 0; i < n; i++) *(U64 *)(mem + dt + i * 8) = val; else if (sz == 1) for (i = 0; i < total; i++) mem[dt + i] = val; else              for (i = 0; i < n; i++) WrMem(dt + i * sz, sz, val); reg[7] = dt + total; reg[1] = 0; return; } } }
  while (reg[1] != 0) {
    StrStep(op, sz); reg[1]--;
    if (cmpkind) {                                    // REPE(repf=1): stop when ZF=0; REPNE(repf=2): stop when ZF=1
      if (repf == 1 && !(rfl & F_ZF)) break; if (repf == 2 &&  (rfl & F_ZF)) break; } } }

//---------------------------------------------------------------- system: MSR / CPUID / I/O / IDT
U64 RdMsr(U64 i)
{
  if (i == 0xC0000080) return msr_efer; if (i == 0xC0000100) return msr_fsbase; if (i == 0xC0000101) return msr_gsbase; if (i == 0xC0000102) return msr_kgsbase; if (i == 0xC0000081) return msr_star; if (i == 0xC0000082) return msr_lstar; if (i == 0xC0000084) return msr_sfmask;
  if (i == 0x1B) return msr_apic;
  return 0; }
U0 WrMsr(U64 i, U64 v)
{
  if      (i == 0xC0000080) msr_efer = v; else if (i == 0xC0000100) msr_fsbase = v; else if (i == 0xC0000101) msr_gsbase = v; else if (i == 0xC0000102) msr_kgsbase = v; else if (i == 0xC0000081) msr_star = v; else if (i == 0xC0000082) msr_lstar = v; else if (i == 0xC0000084) msr_sfmask = v;
  else if (i == 0x1B) msr_apic = v; }
U0 Cpuid()  // enough feature bits for TempleOS: FPU/TSC/MSR/PAE/APIC/MMX/FXSR/SSE/SSE2, long mode
{
  U64 a = reg[0] & 0xFFFFFFFF;
  if (a == 0)                 { reg[0] = 0x0000000D; reg[3] = 0x756E6547; reg[2] = 0x6C65746E; reg[1] = 0x49656E69; }
  else if (a == 1)            { reg[0] = 0x000006FB; reg[1] = 0; reg[2] = 0x00000201; reg[3] = 0x178BFBFF; }
  else if (a == 0x80000000)   { reg[0] = 0x80000008; reg[1] = 0; reg[2] = 0; reg[3] = 0; }
  else if (a == 0x80000001)   { reg[0] = 0; reg[1] = 0; reg[2] = 0x00000001; reg[3] = 0x28100800; }
  else                        { reg[0] = 0; reg[1] = 0; reg[2] = 0; reg[3] = 0; } }
// VGA DAC state. Palette reads are used by TOOM's 256-color to 16-color dithering.
U8 vga_dac[768];
I64 vga_read_pos,vga_write_pos;
U0 VgaPaletteSend(I64 i)
{//All hosts receive the same eight-bit RGB palette on boot and restore.
  I64 r=vga_dac[i*3]*255/63,g=vga_dac[i*3+1]*255/63,
	b=vga_dac[i*3+2]*255/63;
  __host_palette(i,r*0x10000+g*0x100+b);
}

U0 VgaPaletteInit()
{
  I64 i,r,g,b,bright;
  for(i=0;i<16;i++) {
    bright=(i&8)!=0;
    r=((i&4)!=0)*42+bright*21;g=((i&2)!=0)*42+bright*21;b=((i&1)!=0)*42+bright*21;
    if(i==6)g=21;
    vga_dac[i*3]=r;vga_dac[i*3+1]=g;vga_dac[i*3+2]=b;
    VgaPaletteSend(i);
  }
  vga_read_pos=0;vga_write_pos=0;
}
U64 RtcRead(I64 idx)                  // CMOS RTC register read (binary mode, host wall clock)
{ if (idx == 0x0A) return 0; if (idx == 0x0B) return 0x06; return __host_time(idx); }
U64 IoIn(U64 port)
{
  if(port==0x3C9){U64 value=vga_dac[vga_read_pos];vga_read_pos=(vga_read_pos+1)%768;return value;}
  if(port==0x3C8)return vga_write_pos/3;
  if(port==0x3C6)return 255;
  if (port == 0x21) return pic1_mask; if (port == 0xA1) return pic2_mask; if (port == 0x40) return PitRead; if (port == 0x71) return RtcRead(rtc_idx);
  if (port == 0x60) {                                  // PS/2 data: cmd-response, then mouse, then kbd
    if (ps2qh != ps2qt) { I64 b = ps2q[ps2qh & 15]; ps2qh++; return b; }  // command ACK/reset bytes
    if (ms_has) {
      I64 mb; if (ms_phase == 0) mb = ms_byte0; else if (ms_phase == 1) mb = ms_byte1; else mb = ms_byte2; ms_phase++;
      if (ms_phase >= 3) { ms_has = 0; ms_phase = 0; }  // packet drained
      else pic2_irr |= 0x10;                            // a real PS/2 mouse raises IRQ12 per BYTE:
      return mb;                                        // TempleOS reads 1 byte/IRQ (Mouse.HC), so
    }                                                   // re-assert IRQ12 until all 3 bytes are read
    if (kbd_qh != kbd_qt) { I64 sc = kbd_q[kbd_qh & 63]; kbd_qh++; if (kbd_qh != kbd_qt) pic1_irr |= 2; return sc; }
    return 0; }
  if (port == 0x64) {                                  // PS/2 status: bit0=OBF, bit2=sysflag, bit5=mouse-data
    I64 st = 0x1C, nextms = 0;
    if (ps2qh != ps2qt) { st |= 0x01; if (ps2q_ms[ps2qh & 15]) nextms = 1; }  // response pending
    else if (ms_has) { st |= 0x01; nextms = 1; }
    else if (kbd_qh != kbd_qt) st |= 0x01; if (nextms) st |= 0x20;
    return st; }
  if (port == 0x1F7 || port == 0x177) return ata_words > 0 ? 0x48 : 0x40;   // ATA status: DRDY (+DRQ while data left)
  if (port == 0x1F0 || port == 0x170) {                                     // ATA data: serve staged sector words
    if (ata_words > 0) { U64 w = *(U16 *)(ata_buf + ata_pos); ata_pos += 2; ata_words--; return w; }
    return 0; }
  return 0; }
U0 IoOut(U64 port, U64 v)
{
  I64 i;
  if(port==0x3C7){vga_read_pos=(v&255)*3;return;}
  if(port==0x3C8){vga_write_pos=(v&255)*3;return;}
  if(port==0x3C9){i=vga_write_pos/3;vga_dac[vga_write_pos]=v&63;vga_write_pos=(vga_write_pos+1)%768;
    if(vga_write_pos%3==0 && i<16)VgaPaletteSend(i);return;}
  if (port >= 0x3B0 && port <= 0x3DF) return;          // VGA registers - framebuffer is HLE'd, ignore (skip the chain)
  if (port == 0x1F0 || port == 0x170) {                // ATA data port WRITE (16-bit words during a WRITE command)
    if (ata_wr && ata_words > 0) { *(U16 *)(ata_buf + ata_pos) = v; ata_pos += 2; ata_words--;
      if (ata_words == 0) { __host_disk_wr(ata_wlba, ata_wcnt, ata_buf); ata_wr = 0; } }   // commit to the host overlay
    return; }
  v &= 0xFF;
  if (port == 0x1F2 || port == 0x172) { ata_seccnt = ((ata_seccnt << 8) | v) & 0xFFFF; return; }   // ATA sector count
  if (port == 0x1F3 || port == 0x173) { ata_r3 = ((ata_r3 << 8) | v) & 0xFFFF; return; }           // LBA48 reg (2 writes)
  if (port == 0x1F4 || port == 0x174) { ata_r4 = ((ata_r4 << 8) | v) & 0xFFFF; return; }
  if (port == 0x1F5 || port == 0x175) { ata_r5 = ((ata_r5 << 8) | v) & 0xFFFF; return; }
  if (port == 0x1F7 || port == 0x177) {                // ATA command (LBA48/28 read+write multiple/sectors)
    U64 lba = (ata_r3 & 0xFF) | ((ata_r4 & 0xFF) << 8) | ((ata_r5 & 0xFF) << 16)
            | (((ata_r3 >> 8) & 0xFF) << 24) | (((ata_r4 >> 8) & 0xFF) << 32) | (((ata_r5 >> 8) & 0xFF) << 40);
    U64 cnt = ata_seccnt & 0xFFFF; if (!cnt) cnt = 256; if (cnt > 256) cnt = 256;
    if (v == 0x20 || v == 0x21 || v == 0x24 || v == 0x29 || v == 0xC4) {              // READ
      __host_disk(lba, cnt, ata_buf); ata_words = cnt * 256; ata_pos = 0; ata_wr = 0;   // host stages real sectors
    } else if (v == 0x30 || v == 0x34 || v == 0x39 || v == 0xC5) {                    // WRITE: receive data, then commit
      ata_words = cnt * 256; ata_pos = 0; ata_wr = 1; ata_wlba = lba; ata_wcnt = cnt;   // DRQ asserted -> OS sends words
    } else { ata_words = 0; ata_wr = 0; }
    ata_r3 = 0; ata_r4 = 0; ata_r5 = 0; ata_seccnt = 0;
    return; }
  if (port == 0x64) {                                   // PS/2 controller command
    if (v == 0xD4) ms_next = 1;                          // next 0x60 byte -> mouse
    else if (v == 0x20) Ps2Resp(0x47, 0);               // read config (kbd+mouse IRQ + sys flag)
    else if (v == 0x60) cfg_next = 1;                   // next 0x60 byte = config (no response)
    else if (v == 0xA9 || v == 0xAB) Ps2Resp(0x00, 0); // interface/self-test -> 0x00 (pass)
    else if (v == 0xAA) Ps2Resp(0x55, 0);              // controller self-test -> 0x55
    return;                                             // 0xA7/0xA8/0xAD/0xAE (enable/disable): no reply
  }
  if (port == 0x60) {                                   // PS/2 data write
    if (cfg_next) { cfg_next = 0; return; }              // config byte write
    if (ms_next) {                                       // a mouse command (after 0xD4)
      ms_next = 0; Ps2Resp(0xFA, 1);                     // ACK
      if (v == 0xFF) { Ps2Resp(0xAA, 1); Ps2Resp(0x00, 1); }  // reset -> BAT ok + device id
      else if (v == 0xF2) Ps2Resp(0x00, 1);             // get-id -> standard mouse
      return; }
    Ps2Resp(0xFA, 0);                                   // keyboard command ACK
    if (kbd_cmd) {
      if (kbd_cmd==0xF3) {
        kbd_type=v&0x7F;
        kbd_repeat_ns=tsc+KbdDelay;
      }
      kbd_cmd=0;
    } else if (v==0xF3 || v==0xED)
      kbd_cmd=v;
    else if (v==0xFF) {
      kbd_repeat_key=0;kbd_type=0x2B;
      Ps2Resp(0xAA,0);
    }
    return; }
  if (port == 0x70) { rtc_idx = v & 0x7F; return; }     // CMOS register select (bit7 = NMI disable)
  if (port == 0x43) {                                   // PIT command: bits 6 and 7 pick the channel
    if ((v & 0xC0) == 0x80) pit2_wlo = 1;
    else if (!(v & 0xC0)) PitCmd(v);
    return; }
  if (port == 0x42) {                                   // PIT ch2 reload (lo then hi) = speaker tone
    if (pit2_wlo) { pit2_reload = v; pit2_wlo = 0; }
    else { pit2_reload |= v << 8; pit2_div = pit2_reload; pit2_wlo = 1; UpdateSpk(); }
    return; }
  if (port == 0x61) { spk_on = (v & 3) == 3; UpdateSpk(); return; }     // speaker gate (bits 0+1)
  if (port == 0x20) {                                    // PIC1 command (ICW1 / EOI)
    if (v & 0x10) pic1_initstep = 1;
    else if (v == 0x20) { for (i = 0; i < 8; i++) if (pic1_isr & (1 << i)) { pic1_isr &= ~(1 << i); break; } }
  } else if (port == 0x21) {                             // PIC1 data (ICW2 base / ICW3 / ICW4 / OCW1 mask)
    if (pic1_initstep == 1) { pic1_base = v; pic1_initstep = 2; }
    else if (pic1_initstep == 2) pic1_initstep = 3; else if (pic1_initstep == 3) pic1_initstep = 0; else pic1_mask = v;
  } else if (port == 0xA0) {
    if (v & 0x10) pic2_initstep = 1;
    else if (v == 0x20) { for (i = 0; i < 8; i++) if (pic2_isr & (1 << i)) { pic2_isr &= ~(1 << i); break; } }
  } else if (port == 0xA1) {
    if (pic2_initstep == 1) { pic2_base = v; pic2_initstep = 2; }
    else if (pic2_initstep == 2) pic2_initstep = 3; else if (pic2_initstep == 3) pic2_initstep = 0; else pic2_mask = v;
  } else if (port == 0x40) {                             // PIT ch0 reload
    if (pit_wlo) { pit_reload = v; pit_wlo = 0; }
    else { pit_reload |= (v << 8); pit_div = pit_reload; if (!pit_div) pit_div = 65536; pit_counter = pit_div; pit_wlo = 1; } } }
// The ATA data port transfers 16-bit words. An x86 IN/OUT dword transfers two
// words, including REP INSD/OUTSD used by the V5.03 disk driver.
U64 IoInWidth(U64 port,I64 width)
{
  U64 value=IoIn(port);
  if ((port==0x1F0 || port==0x170) && width==4) value|=IoIn(port)<<16;
  return value;
}
U0 IoOutWidth(U64 port,U64 value,I64 width)
{
  IoOut(port,value);
  if ((port==0x1F0 || port==0x170) && width==4) IoOut(port,value>>16);
}
// String I/O (INS/OUTS, +REP). The ATA PIO data port (0x1F0) flows through these for REP INSW disk
// reads - IoIn returns blank-disk zeros, so the read completes instead of deadlocking the poller.
U0 DoIns(I64 sz)                                          // INS: [RDI] <- port DX
{ I64 d; if (rfl & F_DF) d = -sz; else d = sz; if (!repf) { WrMem(reg[7], sz, IoInWidth(reg[2] & 0xFFFF, sz)); reg[7] += d; return; } while (reg[1] != 0) { WrMem(reg[7], sz, IoInWidth(reg[2] & 0xFFFF, sz)); reg[7] += d; reg[1]--; } }
U0 DoOuts(I64 sz)                                         // OUTS: port DX <- [RSI]
{ I64 d; if (rfl & F_DF) d = -sz; else d = sz; if (!repf) { IoOutWidth(reg[2] & 0xFFFF, RdMem(reg[6], sz), sz); reg[6] += d; return; } while (reg[1] != 0) { IoOutWidth(reg[2] & 0xFFFF, RdMem(reg[6], sz), sz); reg[6] += d; reg[1]--; } }
U0 CheckIrq()                                            // deliver one pending, unmasked IRQ
{
  I64 irq, b; b = pic1_irr & ~pic1_mask;
  for (irq = 0; irq < 8; irq++)                          // PIC1 (IRQ0..7); IRQ2 = cascade from PIC2
    if (b & (1 << irq)) { if (irq == 2) break; pic1_irr &= ~(1 << irq); pic1_isr |= (1 << irq); irq_count++; DoInt(pic1_base + irq, 0, 0); return; }
  b = pic2_irr & ~pic2_mask;                             // PIC2 (IRQ8..15), e.g. IRQ12 = mouse
  for (irq = 0; irq < 8; irq++)
    if (b & (1 << irq)) { pic2_irr &= ~(1 << irq); pic2_isr |= (1 << irq); irq_count++; DoInt(pic2_base + irq, 0, 0); return; } }
U0 Grp7()                                         // 0F 01 /digit: LGDT/LIDT/SGDT/SIDT
{
  I64 d = rg & 7; if (!isMem) return;
  if      (d == 2) { gdtr_limit = RdMem(ea, 2); gdtr_base = RdMem(ea + 2, 8); }
  else if (d == 3) { idtr_limit = RdMem(ea, 2); idtr_base = RdMem(ea + 2, 8); }
  else if (d == 0) { WrMem(ea, 2, gdtr_limit); WrMem(ea + 2, 8, gdtr_base); }
  else if (d == 1) { WrMem(ea, 2, idtr_limit); WrMem(ea + 2, 8, idtr_base); } }
U0 DoInt(I64 vec, I64 hasErr, U64 err)            // long-mode interrupt: push frame, vector via IDT
{
  U64 gate, off, sel, oldsp; gate = idtr_base + vec * 16; off = RdMem(gate, 2) | (RdMem(gate + 6, 2) << 16) | (RdMem(gate + 8, 4) << 32); sel = RdMem(gate + 2, 2); oldsp = reg[4]; reg[4] -= 8; WrMem(reg[4], 8, g_ss); reg[4] -= 8; WrMem(reg[4], 8, oldsp); reg[4] -= 8; WrMem(reg[4], 8, rfl);
  reg[4] -= 8; WrMem(reg[4], 8, g_cs); reg[4] -= 8; WrMem(reg[4], 8, rip);
  if (hasErr) { reg[4] -= 8; WrMem(reg[4], 8, err); }
  rfl &= ~F_IF; g_cs = sel; rip = off; }
U0 DoIret()                                       // IRETQ: pop RIP, CS, RFLAGS, RSP, SS
{ U64 newsp; rip   = RdMem(reg[4] + 0, 8); g_cs  = RdMem(reg[4] + 8, 8); rfl   = RdMem(reg[4] + 16, 8); newsp = RdMem(reg[4] + 24, 8); g_ss  = RdMem(reg[4] + 32, 8); reg[4] = newsp; }

//---------------------------------------------------------------- SSE2 (F64) helpers
F64 BitsToF64(U64 b) { *(U64 *)fsc = b; return *(F64 *)fsc; }   // reinterpret bits
U64 F64ToBits(F64 d) { *(F64 *)fsc = d; return *(U64 *)fsc; }
F64 IntToF64(I64 v)  { F64 d; d = v; return d; }                // signed int -> double
I64 F64ToInt(F64 d)
{//An invalid signed conversion returns integer indefinite.
  I64 res;
  if (!(d>=-BitsToF64(0x43E0000000000000) && d<BitsToF64(0x43E0000000000000)))
    return -I64_MAX-1;
  res=d;
  return res;
}

F64 FIntRound(F64 d,I64 rc)
{//x87 rounding: nearest even, down, up or truncate.
  I64 i;
  F64 res,part;
  if (d!=d || d>=4503599627370496.0 || d<=-4503599627370496.0 || !d)
    return d;
  i=d;res=i;
  if (!rc) {
    part=d-res;
    if (part>0.5 || (part==0.5 && i&1))
      res++;
    else if (part< -0.5 || (part== -0.5 && i&1))
      res--;
  } else if (rc==1 && res>d)
    res--;
  else if (rc==2 && res<d)
    res++;
  if (!res) return BitsToF64(F64ToBits(d)&0x8000000000000000);
  return res;
}

I64 RoundCW(F64 d)
{
  return F64ToInt(FIntRound(d,(x87_cw>>10)&3));
}

U0 FIntStore(I64 size,Bool trunc,Bool pop)
{//FIST(P)/FISTTP with the destination's range and masked exception flags.
  I64 rc=(x87_cw>>10)&3,lim=1<<(size*8-1),res;
  F64 d=FStv(0),r,bound;
  if (trunc) rc=3;
  r=FIntRound(d,rc);
  bound=32768.0;
  if (size==4) bound=2147483648.0;
  else if (size==8) bound=BitsToF64(0x43E0000000000000);
  x87_sw&=~0x200;
  if (!(r>=-bound && r<bound)) {
    x87_sw|=1;
    if (!(x87_cw&1)) {
      x87_sw|=0x8080;
      return;
    }
    res=lim;
  } else {
    res=r;
    if (r!=d) {
      x87_sw|=0x20;
      if (!trunc && Abs(r)>Abs(d)) x87_sw|=0x200;
    }
  }
  WrMem(ea,size,res);
  if (pop) FPopv;
}

//---------------------------------------------------------------- x87 FPU (the subset TempleOS's JIT emits)
// HolyC is F64-based; the compiler uses x87 mainly for int<->double conversion
// (FILD/FSTP) and some scalar math. We keep the stack at 64-bit precision.
F64 F32ToF64(U64 b)                          // reinterpret 32-bit IEEE-754 as double
{
  U64 s, e, f, db; s = (b >> 31) & 1; e = (b >> 23) & 0xFF; f = b & 0x7FFFFF;
  if (e == 0) db = s << 63;                                   // zero / (subnormal approximated to 0)
  else if (e == 0xFF) db = (s << 63) | (0x7FF << 52) | (f << 29); else db = (s << 63) | ((e - 127 + 1023) << 52) | (f << 29);
  return BitsToF64(db); }
U64 F64ToF32b(F64 d)                          // double -> 32-bit IEEE-754 bits
{
  U64 b, s, f; I64 e, ne; b = F64ToBits(d); s = (b >> 63) & 1; e = (b >> 52) & 0x7FF; f = b & 0xFFFFFFFFFFFFF; if (e == 0) return s << 31; if (e == 0x7FF) return (s << 31) | (0xFF << 23) | (f >> 29); ne = e - 1023 + 127; if (ne <= 0) return s << 31; if (ne >= 0xFF) return (s << 31) | (0xFF << 23);
  return (s << 31) | (ne << 23) | (f >> 29); }
U0  FPush(F64 v)            { fsp = (fsp - 1) & 7; fpr[fsp] = v; }
F64 FPopv()                 { F64 v = fpr[fsp]; fsp = (fsp + 1) & 7; return v; }
F64 FStv(I64 i)             { return fpr[(fsp + i) & 7]; }
U0  FStset(I64 i, F64 v)    { fpr[(fsp + i) & 7] = v; }
U0  FCmpSW(F64 a, F64 b)    {                 // FCOM: set x87 status word C3/C2/C0
  x87_sw &= ~0x4500; if (a != a || b != b) x87_sw |= 0x4500; else if (a < b) x87_sw |= 0x0100; else if (a == b) x87_sw |= 0x4000; }
U0  FCmpFL(F64 a, F64 b)    {                 // FCOMI/FUCOMI: set EFLAGS ZF/PF/CF
  rfl &= ~(F_ZF | F_PF | F_CF); if (a != a || b != b) rfl |= (F_ZF | F_PF | F_CF); else if (a == b) rfl |= F_ZF; else if (a < b) rfl |= F_CF; }
U0 OpX87(U64 op)
{
  I64 sub, sti, bcd_i, bcd_d, bcd_ng; F64 a, b, r; DecodeModRM(); sub = rg & 7; sti = rm & 7;
  if (isMem) {
    if (op == 0xD9) {
      if (sub == 0) FPush(F32ToF64(RdMem(ea, 4)));                     // FLD  m32
      else if (sub == 2) WrMem(ea, 4, F64ToF32b(FStv(0)));            // FST  m32
      else if (sub == 3) { WrMem(ea, 4, F64ToF32b(FStv(0))); FPopv(); } // FSTP m32
      else if (sub == 5) x87_cw = RdMem(ea, 2);                       // FLDCW
      else if (sub == 7) WrMem(ea, 2, x87_cw);                        // FNSTCW
    } else if (op == 0xDB) {
      if (sub == 0) FPush(IntToF64(SignExtTo64(RdMem(ea, 4), 4)));    // FILD  m32int
      else if (sub == 1) { FIntStore(4,TRUE,TRUE); } // FISTTP m32int (trunc + pop)
      else if (sub == 2) FIntStore(4,FALSE,FALSE);              // FIST  m32int
      else if (sub == 3) { FIntStore(4,FALSE,TRUE); } // FISTP m32int
      else if (sub == 5) FPush(BitsToF64(RdMem(ea, 8)));            // FLD   m80 (approx: low 64b)
      else if (sub == 7) { WrMem(ea, 8, F64ToBits(FStv(0))); FPopv(); } // FSTP m80 (approx)
    } else if (op == 0xDD) {
      if (sub == 0) FPush(BitsToF64(RdMem(ea, 8)));                  // FLD  m64
      else if (sub == 1) { FIntStore(8,TRUE,TRUE); } // FISTTP m64int (trunc + pop)
      else if (sub == 2) WrMem(ea, 8, F64ToBits(FStv(0)));          // FST  m64
      else if (sub == 3) { WrMem(ea, 8, F64ToBits(FStv(0))); FPopv(); } // FSTP m64
    } else if (op == 0xDF) {
      if (sub == 0) FPush(IntToF64(SignExtTo64(RdMem(ea, 2), 2)));   // FILD  m16int
      else if (sub == 1) { FIntStore(2,TRUE,TRUE); } // FISTTP m16int (trunc + pop)
      else if (sub == 2) FIntStore(2,FALSE,FALSE);            // FIST  m16int
      else if (sub == 3) { FIntStore(2,FALSE,TRUE); } // FISTP m16int
      else if (sub == 5) FPush(IntToF64(RdMem(ea, 8)));            // FILD  m64int
      else if (sub == 4) {                                          // FBLD m80 - packed-BCD load (18 digits + sign)
        bcd_i = 0; for (bcd_d = 8; bcd_d >= 0; bcd_d--) { bcd_ng = RdMem(ea + bcd_d, 1); bcd_i = bcd_i * 100 + (bcd_ng >> 4) * 10 + (bcd_ng & 15); }
        if (RdMem(ea + 9, 1) & 0x80) bcd_i = -bcd_i; FPush(IntToF64(bcd_i)); }
      else if (sub == 6) {                                          // FBSTP m80 - packed-BCD store + pop (x87 float->decimal)
        bcd_i = RoundCW(FStv(0)); bcd_ng = 0; if (bcd_i < 0) { bcd_ng = 1; bcd_i = -bcd_i; }
        for (bcd_d = 0; bcd_d < 9; bcd_d++) { WrMem(ea + bcd_d, 1, (bcd_i % 10) | ((bcd_i / 10 % 10) << 4)); bcd_i /= 100; }
        WrMem(ea + 9, 1, bcd_ng ? 0x80 : 0); FPopv(); }
      else if (sub == 7) { FIntStore(8,FALSE,TRUE); } // FISTP m64int
    } else if (op == 0xD8 || op == 0xDC) {                           // real arith (m32 / m64)
      if (op == 0xD8) b = F32ToF64(RdMem(ea, 4)); else b = BitsToF64(RdMem(ea, 8)); a = FStv(0);
      if (sub == 2 || sub == 3) { FCmpSW(a, b); if (sub == 3) FPopv(); return; }   // FCOM/FCOMP
      if (sub == 0) r = a + b; else if (sub == 1) r = a * b; else if (sub == 4) r = a - b; else if (sub == 5) r = b - a; else if (sub == 6) r = a / b; else r = b / a; FStset(0, r);
    } else if (op == 0xDA || op == 0xDE) {                           // int arith (m32int / m16int)
      if (op == 0xDA) b = IntToF64(SignExtTo64(RdMem(ea, 4), 4)); else b = IntToF64(SignExtTo64(RdMem(ea, 2), 2)); a = FStv(0); if (sub == 0) r = a + b; else if (sub == 1) r = a * b; else if (sub == 4) r = a - b; else if (sub == 5) r = b - a; else if (sub == 6) r = a / b; else r = b / a; FStset(0, r);
    }
    return; }
  // ---- register forms (ST(i)); dispatch on opcode + sub(/digit) + sti ----
  if (op == 0xD9) {
    if (sub == 0) FPush(FStv(sti));                                  // FLD  st(i)
    else if (sub == 1) { a = FStv(0); FStset(0, FStv(sti)); FStset(sti, a); }  // FXCH
    else if (sub == 4) { if (sti == 0) FStset(0, -FStv(0)); else if (sti == 1) { a = FStv(0); if (a < 0) FStset(0, -a); } else if (sti == 4) { x87_sw &= ~0x0200; FCmpSW(FStv(0), 0.0); } }  // FCHS/FABS/FTST (Sign uses FTST + FNSTSW)
    else if (sub == 5) {                                             // FLD1/FLDL2T/FLDL2E/FLDPI/FLDLG2/FLDLN2/FLDZ
      if (sti == 0) FPush(1.0); else if (sti == 1) FPush(BitsToF64(0x400A934F0979A371)); else if (sti == 2) FPush(BitsToF64(0x3FF71547652B82FE)); else if (sti == 3) FPush(BitsToF64(0x400921FB54442D18)); else if (sti == 4) FPush(BitsToF64(0x3FD34413509F79FF)); else if (sti == 5) FPush(BitsToF64(0x3FE62E42FEFA39EF)); else if (sti == 6) FPush(0.0); }
    else if (sub == 6) {                                             // F2XM1/FYL2X/FPTAN/FPATAN/FXTRACT/FDECSTP/FINCSTP
      if (sti == 0) FStset(0, Pow(2.0, FStv(0)) - 1.0);                                      // F2XM1: 2^ST0 - 1
      else if (sti == 1) { r = FStv(1) * Ln(FStv(0)) * BitsToF64(0x3FF71547652B82FE); FPopv(); FStset(0, r); }  // FYL2X: ST1*=log2(ST0), pop
      else if (sti == 2) { FStset(0, Tan(FStv(0))); FPush(1.0); }                            // FPTAN: ST0=tan, push 1.0
      else if (sti == 3) { r = ATan2(FStv(1), FStv(0)); FPopv(); FStset(0, r); }             // FPATAN: ST1=atan2(ST1,ST0), pop
      else if (sti == 4) { a = FStv(0); if (a == 0.0) { FStset(0, 0.0); FPush(0.0); } else { b = a; if (b < 0) b = -b; bcd_i = F64ToInt(Ln(b) * BitsToF64(0x3FF71547652B82FE)); if (IntToF64(bcd_i) > Ln(b) * BitsToF64(0x3FF71547652B82FE)) bcd_i--; FStset(0, IntToF64(bcd_i)); FPush(a / Pow(2.0, IntToF64(bcd_i))); } }  // FXTRACT
      else if (sti == 6) fsp = (fsp - 1) & 7;                                                  // FDECSTP
      else if (sti == 7) fsp = (fsp + 1) & 7;                                                  // FINCSTP
    }
    else if (sub == 7) {                                            // FPREM/FYL2XP1/FSQRT/FSINCOS/FRNDINT/FSCALE/FSIN/FCOS
      if (sti == 0) { a = FStv(0); b = FStv(1); FStset(0, a - IntToF64(F64ToInt(a / b)) * b); }  // FPREM: ST0 %= ST1
      else if (sti == 1) { r = FStv(1) * Ln(FStv(0) + 1.0) * BitsToF64(0x3FF71547652B82FE); FPopv(); FStset(0, r); }  // FYL2XP1
      else if (sti == 2) FStset(0, SqrtF64(FStv(0)));                                          // FSQRT
      else if (sti == 3) { a = FStv(0); FStset(0, Sin(a)); FPush(Cos(a)); }                // FSINCOS
      else if (sti == 4) FStset(0,FIntRound(FStv(0),(x87_cw>>10)&3));                                 // FRNDINT
      else if (sti == 5) FStset(0, FStv(0) * Pow(2.0, IntToF64(F64ToInt(FStv(1)))));         // FSCALE
      else if (sti == 6) FStset(0, Sin(FStv(0)));                                            // FSIN
      else if (sti == 7) FStset(0, Cos(FStv(0)));                                            // FCOS
    }
  } else if (op == 0xD8) {
    a = FStv(0); b = FStv(sti);
    if (sub == 2 || sub == 3) { FCmpSW(a, b); if (sub == 3) FPopv(); }
    else if (sub == 0) FStset(0, a + b); else if (sub == 1) FStset(0, a * b); else if (sub == 4) FStset(0, a - b); else if (sub == 5) FStset(0, b - a); else if (sub == 6) FStset(0, a / b); else FStset(0, b / a);
  } else if (op == 0xDC) {
    // Register-destination encodings reverse /4 vs /5 and /6 vs /7.
    a = FStv(sti); b = FStv(0); if (sub == 0) FStset(sti, a + b); else if (sub == 1) FStset(sti, a * b); else if (sub == 4) FStset(sti, b - a); else if (sub == 5) FStset(sti, a - b); else if (sub == 6) FStset(sti, b / a); else if (sub == 7) FStset(sti, a / b);
  } else if (op == 0xDD) {
    if (sub == 2) FStset(sti, FStv(0));                             // FST  st(i)
    else if (sub == 3) { FStset(sti, FStv(0)); FPopv(); }          // FSTP st(i)
    else if (sub == 4 || sub == 5) { FCmpSW(FStv(0), FStv(sti)); if (sub == 5) FPopv(); }  // FUCOM/FUCOMP
  } else if (op == 0xDE) {
    a = FStv(sti); b = FStv(0);
    if (sub == 3) { FCmpSW(FStv(0), FStv(1)); FPopv(); FPopv(); }   // FCOMPP
    else { if (sub == 0) FStset(sti, a + b); else if (sub == 1) FStset(sti, a * b);
           else if (sub == 4) FStset(sti, b - a); else if (sub == 5) FStset(sti, a - b);
           else if (sub == 6) FStset(sti, b / a); else FStset(sti, a / b); FPopv(); }      // ...P
  } else if (op == 0xDB) {
    if (sub == 4) { if (sti == 3) { fsp = 0; x87_cw = 0x37F; x87_sw = 0; } }  // FNINIT (also FNCLEX etc -> reset-ish)
    else if (sub == 6) { FCmpFL(FStv(0), FStv(sti)); }                        // FCOMI st0,st(i)
    else if (sub == 7) { FCmpFL(FStv(0), FStv(sti)); }                        // FUCOMI
  } else if (op == 0xDF) {
    if (sub == 4 && sti == 0) reg[0] = (reg[0] & ~0xFFFF) | (x87_sw & 0xFFFF);  // FNSTSW AX
    else if (sub == 6) { FCmpFL(FStv(0), FStv(sti)); FPopv(); }               // FCOMIP
    else if (sub == 7) { FCmpFL(FStv(0), FStv(sti)); FPopv(); }               // FUCOMIP
  } }
F64 SqrtF64(F64 d)   { return Sqrt(d); }
U64 RdXmm64()        { if (isMem) return RdMem(ea, 8); return xmm_lo[rm]; }  // low 64 of xmm/m64

//---------------------------------------------------------------- two-byte (0F) opcodes
//---------------------------------------------------------------- LOCK atomics (SMP)
// Atomic RMW on guest address `a` (host linear addr = mem + a). Native WASM atomics (0xFE family
// via the holyc-wasm __a_* intrinsics) -> real cross-core atomicity over shared memory. Each
// returns the OLD value. Caller guards alignment (atomics trap on misaligned >1-byte access).
U64 AtomOr(U64 a, U64 v, I64 sz)   { if (sz==1) return __a_or8(mem+a,v);   if (sz==2) return __a_or16(mem+a,v);   if (sz==4) return __a_or32(mem+a,v);   return __a_or64(mem+a,v); }
U64 AtomAnd(U64 a, U64 v, I64 sz)  { if (sz==1) return __a_and8(mem+a,v);  if (sz==2) return __a_and16(mem+a,v);  if (sz==4) return __a_and32(mem+a,v);  return __a_and64(mem+a,v); }
U64 AtomXor(U64 a, U64 v, I64 sz)  { if (sz==1) return __a_xor8(mem+a,v);  if (sz==2) return __a_xor16(mem+a,v);  if (sz==4) return __a_xor32(mem+a,v);  return __a_xor64(mem+a,v); }
U64 AtomAdd(U64 a, U64 v, I64 sz)  { if (sz==1) return __a_add8(mem+a,v);  if (sz==2) return __a_add16(mem+a,v);  if (sz==4) return __a_add32(mem+a,v);  return __a_add64(mem+a,v); }
U64 AtomXchg(U64 a, U64 v, I64 sz) { if (sz==1) return __a_xchg8(mem+a,v); if (sz==2) return __a_xchg16(mem+a,v); if (sz==4) return __a_xchg32(mem+a,v); return __a_xchg64(mem+a,v); }
U64 AtomCas(U64 a, U64 e, U64 v, I64 sz) { if (sz==1) return __a_cmpxchg8(mem+a,e,v); if (sz==2) return __a_cmpxchg16(mem+a,e,v); if (sz==4) return __a_cmpxchg32(mem+a,e,v); return __a_cmpxchg64(mem+a,e,v); }

//---------------------------------------------------------------- bit ops (BT/BTS/BTR/BTC)
// which: 0=BT (test only), 1=BTS (set), 2=BTR (reset), 3=BTC (complement).
// CF := old bit. For a memory operand the bit index selects the byte (ea+bit/8),
// so the bit string can exceed the operand width - which is how TempleOS's
// LOCK BTS/BTR lock primitives address bits in a shared word.
U0 DoBit(I64 which, U64 bit, I64 sz)
{ U64 v, m, old; I64 asz; asz = sz; if (isMem) { ea += bit >> 3; bit &= 7; asz = 1; } else bit &= (sz * 8 - 1); m = 1; m <<= bit;
  if (lockf && isMem && which && ea < mem_size) {                  // LOCK BTS/BTR/BTC -> atomic byte RMW (the TempleOS spinlock + mp_not_done_flags primitive)
    if (which == 1)      old = AtomOr(ea, m, asz);
    else if (which == 2) old = AtomAnd(ea, ~m, asz);
    else                 old = AtomXor(ea, m, asz);
    if (old & m) rfl |= F_CF; else rfl &= ~F_CF; return;
  }
  v = RdRM(asz); if (v & m) rfl |= F_CF; else rfl &= ~F_CF; if (which == 1)      WrRM(asz, v | m); else if (which == 2) WrRM(asz, v & ~m); else if (which == 3) WrRM(asz, v ^ m);
}

//---------------------------------------------------------------- FXSAVE / FXRSTOR
// The scheduler saves/restores FPU+SSE state across task switches with these. The
// XMM half MUST be exact (HolyC F64 math lives in SSE2 - a task resumed with stale
// XMM computes garbage, e.g. the WinMgr's refresh timing). x87 regs round-trip as
// F64 bits in the low 8 bytes of each 16-byte slot (they're empty at task start).
U0 DoFxsave(U64 a)
{
  I64 i;
  WrMem(a + 0, 2, x87_cw); WrMem(a + 2, 2, x87_sw); WrMem(a + 24, 4, 0x1F80);  // FCW/FSW/MXCSR
  for (i = 0; i < 8; i++)  WrMem(a + 32 + i * 16, 8, F64ToBits(fpr[i]));        // x87 ST(i)
  for (i = 0; i < 16; i++) { WrMem(a + 160 + i * 16, 8, xmm_lo[i]); WrMem(a + 160 + i * 16 + 8, 8, xmm_hi[i]); }  // XMM
}
U0 DoFxrstor(U64 a)
{ I64 i; x87_cw = RdMem(a + 0, 2); x87_sw = RdMem(a + 2, 2); for (i = 0; i < 8; i++)  fpr[i] = BitsToF64(RdMem(a + 32 + i * 16, 8)); for (i = 0; i < 16; i++) { xmm_lo[i] = RdMem(a + 160 + i * 16, 8); xmm_hi[i] = RdMem(a + 160 + i * 16 + 8, 8); } }

U0 Op0F()
{
  U64 op2, a, b, r, lo, hi, se, al, ah, bl, bh, ll, lh, hl, mid, v; I64 sz, cc, d, isz; F64 fx, fy; op2 = Fetch8(); if (rexW) sz = 8; else if (pfx66) sz = 2; else sz = 4;
  if (op2 >= 0x80 && op2 <= 0x8F) { cc = op2 - 0x80; d = SignExt32(Fetch32()); if (Cond(cc)) rip += d; return; }
  if (op2 >= 0x90 && op2 <= 0x9F) { cc = op2 - 0x90; DecodeModRM(); if (Cond(cc)) WrRM(1, 1); else WrRM(1, 0); return; }
  if (op2 >= 0x40 && op2 <= 0x4F) { cc = op2 - 0x40; DecodeModRM(); a = RdRM(sz); if (Cond(cc)) WrReg(rg, sz, a); else if (sz==4) WrReg(rg,4,RdReg(rg,4)); return; }  // CMOVcc
  switch (op2) {
    case 0x1F: DecodeModRM(); break;                                              // multi-byte NOP
    case 0xB6: DecodeModRM(); WrReg(rg, sz, RdRM(1) & 0xFF); break;               // MOVZX r, r/m8
    case 0xB7: DecodeModRM(); WrReg(rg, sz, RdRM(2) & 0xFFFF); break;             // MOVZX r, r/m16
    case 0xBE: DecodeModRM(); WrReg(rg, sz, SignExtTo64(RdRM(1), 1)); break;      // MOVSX r, r/m8
    case 0xBF: DecodeModRM(); WrReg(rg, sz, SignExtTo64(RdRM(2), 2)); break;      // MOVSX r, r/m16
    case 0xBC: DecodeModRM(); a = RdRM(sz);                                       // BSF r, r/m
      if (!a) rfl |= F_ZF; else { rfl &= ~F_ZF; b = 0; while (!((a >> b) & 1)) b++; WrReg(rg, sz, b); } break;
    case 0xBD: DecodeModRM(); a = RdRM(sz);                                       // BSR r, r/m
      if (!a) rfl |= F_ZF; else { rfl &= ~F_ZF; b = sz * 8 - 1; while (!((a >> b) & 1)) b--; WrReg(rg, sz, b); } break;
    case 0xAF:                                                                    // IMUL r, r/m
      DecodeModRM(); a = RdReg(rg, sz); b = RdRM(sz);
      if (sz == 8) {
        al = a & 0xFFFFFFFF; ah = a >> 32; bl = b & 0xFFFFFFFF; bh = b >> 32; ll = al * bl; lh = al * bh; hl = ah * bl; mid = (ll >> 32) + (lh & 0xFFFFFFFF) + (hl & 0xFFFFFFFF); lo = (ll & 0xFFFFFFFF) | (mid << 32); hi = (ah * bh) + (lh >> 32) + (hl >> 32) + (mid >> 32);
        if (a >> 63) hi -= b; if (b >> 63) hi -= a; r = lo; WrReg(rg, 8, r); rfl &= ~(F_CF | F_OF); se = 0; if (r >> 63) se = 0xFFFFFFFFFFFFFFFF; if (hi != se) rfl |= (F_CF | F_OF);
      } else {
        r = SignExtTo64(a, sz) * SignExtTo64(b, sz); WrReg(rg, sz, r & SizeMask(sz)); rfl &= ~(F_CF | F_OF); if (SignExtTo64(r & SizeMask(sz), sz) != r) rfl |= (F_CF | F_OF); }
      break;
    // ---- SSE / SSE2: scalar double + data movement (the F64 TempleOS uses) ----
    case 0x10: DecodeModRM();                                              // MOVUPS/MOVUPD/MOVSS/MOVSD load
      if (repf == 2) { xmm_lo[rg] = RdXmm64(); if (isMem) xmm_hi[rg] = 0; }
      else if (repf == 1) { xmm_lo[rg] = (xmm_lo[rg] & ~0xFFFFFFFF) | (RdXmm64() & 0xFFFFFFFF); }
      else if (isMem) { xmm_lo[rg] = RdMem(ea, 8); xmm_hi[rg] = RdMem(ea + 8, 8); } else { xmm_lo[rg] = xmm_lo[rm]; xmm_hi[rg] = xmm_hi[rm]; }
      break;
    case 0x11: DecodeModRM();                                             // MOVUPS/MOVSD store
      if (repf == 2) { if (isMem) WrMem(ea, 8, xmm_lo[rg]); else xmm_lo[rm] = xmm_lo[rg]; }
      else if (repf == 1) { if (isMem) WrMem(ea, 4, xmm_lo[rg] & 0xFFFFFFFF); else xmm_lo[rm] = (xmm_lo[rm] & ~0xFFFFFFFF) | (xmm_lo[rg] & 0xFFFFFFFF); }
      else if (isMem) { WrMem(ea, 8, xmm_lo[rg]); WrMem(ea + 8, 8, xmm_hi[rg]); } else { xmm_lo[rm] = xmm_lo[rg]; xmm_hi[rm] = xmm_hi[rg]; }
      break;
    case 0x28: case 0x6F: DecodeModRM();                                  // MOVAPS/MOVDQA/MOVDQU load (128)
      if (isMem) { xmm_lo[rg] = RdMem(ea, 8); xmm_hi[rg] = RdMem(ea + 8, 8); } else { xmm_lo[rg] = xmm_lo[rm]; xmm_hi[rg] = xmm_hi[rm]; }
      break;
    case 0x29: case 0x7F: DecodeModRM();                                  // MOVAPS/MOVDQA store (128)
      if (isMem) { WrMem(ea, 8, xmm_lo[rg]); WrMem(ea + 8, 8, xmm_hi[rg]); } else { xmm_lo[rm] = xmm_lo[rg]; xmm_hi[rm] = xmm_hi[rg]; }
      break;
    case 0x6E: DecodeModRM(); if (rexW) xmm_lo[rg] = RdRM(8); else xmm_lo[rg] = RdRM(4) & 0xFFFFFFFF; xmm_hi[rg] = 0; break;  // MOVD/MOVQ xmm,r/m
    case 0x7E: DecodeModRM();                                             // MOVQ xmm,xmm/m64 (F3) | MOVD/MOVQ r/m,xmm (66)
      if (repf == 1) { xmm_lo[rg] = RdXmm64(); xmm_hi[rg] = 0; }
      else if (rexW) WrRM(8, xmm_lo[rg]); else WrRM(4, xmm_lo[rg] & 0xFFFFFFFF);
      break;
    case 0xD6: DecodeModRM(); if (isMem) WrMem(ea, 8, xmm_lo[rg]); else { xmm_lo[rm] = xmm_lo[rg]; xmm_hi[rm] = 0; } break;  // MOVQ xmm/m64,xmm
    case 0x2A: DecodeModRM(); if (rexW) isz = 8; else isz = 4; xmm_lo[rg] = F64ToBits(IntToF64(SignExtTo64(RdRM(isz), isz))); break;  // CVTSI2SD
    case 0x2C: case 0x2D: DecodeModRM(); if (rexW) isz = 8; else isz = 4; WrReg(rg, isz, F64ToInt(BitsToF64(RdXmm64()))); break;       // CVT(T)SD2SI
    case 0x51: DecodeModRM(); xmm_lo[rg] = F64ToBits(SqrtF64(BitsToF64(RdXmm64()))); break;                                           // SQRTSD
    case 0x58: DecodeModRM(); xmm_lo[rg] = F64ToBits(BitsToF64(xmm_lo[rg]) + BitsToF64(RdXmm64())); break;                            // ADDSD
    case 0x59: DecodeModRM(); xmm_lo[rg] = F64ToBits(BitsToF64(xmm_lo[rg]) * BitsToF64(RdXmm64())); break;                            // MULSD
    case 0x5C: DecodeModRM(); xmm_lo[rg] = F64ToBits(BitsToF64(xmm_lo[rg]) - BitsToF64(RdXmm64())); break;                            // SUBSD
    case 0x5E: DecodeModRM(); xmm_lo[rg] = F64ToBits(BitsToF64(xmm_lo[rg]) / BitsToF64(RdXmm64())); break;                            // DIVSD
    case 0x5D: DecodeModRM(); fx = BitsToF64(xmm_lo[rg]); fy = BitsToF64(RdXmm64()); if (fy < fx) xmm_lo[rg] = F64ToBits(fy); break;  // MINSD
    case 0x5F: DecodeModRM(); fx = BitsToF64(xmm_lo[rg]); fy = BitsToF64(RdXmm64()); if (fy > fx) xmm_lo[rg] = F64ToBits(fy); break;  // MAXSD
    case 0x2E: case 0x2F: DecodeModRM();                                  // UCOMISD/COMISD -> EFLAGS
      fx = BitsToF64(xmm_lo[rg]); fy = BitsToF64(RdXmm64()); rfl &= ~(F_ZF | F_PF | F_CF | F_SF | F_OF); if (fx != fx || fy != fy) rfl |= (F_ZF | F_PF | F_CF); else if (fx == fy) rfl |= F_ZF; else if (fx < fy) rfl |= F_CF;
      break;
    case 0x57: case 0xEF: DecodeModRM();                                  // XORPS/XORPD / PXOR (128)
      if (isMem) { xmm_lo[rg] ^= RdMem(ea, 8); xmm_hi[rg] ^= RdMem(ea + 8, 8); } else { xmm_lo[rg] ^= xmm_lo[rm]; xmm_hi[rg] ^= xmm_hi[rm]; }
      break;

    case 0x20: DecodeModRM(); if (rg==0) reg[rm]=cr0; else if (rg==2) reg[rm]=cr2; else if (rg==3) reg[rm]=cr3; else if (rg==4) reg[rm]=cr4; else if (rg==8) reg[rm]=cr8; else reg[rm]=0; break; // MOV r,CR
    case 0x22: DecodeModRM(); if (rg==0) cr0=reg[rm]; else if (rg==2) cr2=reg[rm]; else if (rg==3) cr3=reg[rm]; else if (rg==4) cr4=reg[rm]; else if (rg==8) cr8=reg[rm]; break;             // MOV CR,r
    case 0x21: DecodeModRM(); reg[rm]=0; break;                          // MOV r,DR (stub: debug regs read 0)
    case 0x23: DecodeModRM(); break;                                     // MOV DR,r (stub)
    case 0x31: TscRead; reg[0]=tsc & 0xFFFFFFFF; reg[2]=(tsc>>32)&0xFFFFFFFF; break;                        // RDTSC
    case 0x30: WrMsr(reg[1]&0xFFFFFFFF, ((reg[2]&0xFFFFFFFF)<<32)|(reg[0]&0xFFFFFFFF)); break;                // WRMSR
    case 0x32: v=RdMsr(reg[1]&0xFFFFFFFF); reg[0]=v&0xFFFFFFFF; reg[2]=(v>>32)&0xFFFFFFFF; break;             // RDMSR
    case 0xA2: Cpuid(); break;                                           // CPUID
    case 0x01: DecodeModRM(); Grp7(); break;                            // LGDT/LIDT/SGDT/SIDT
    case 0x05: break;                                                    // SYSCALL (stub)
    case 0x09: break;                                                    // WBINVD
    case 0x0B: g_badop=0x0F0B; halted=2; break;                          // UD2
    case 0x18: DecodeModRM(); break;                                     // PREFETCH
    case 0xAE: DecodeModRM();                                            // FXSAVE/FXRSTOR/{L,S}DMXCSR/fences
      if (isMem) { if      ((rg & 7) == 0) DoFxsave(ea); else if ((rg & 7) == 1) DoFxrstor(ea); else if ((rg & 7) == 3) WrMem(ea, 4, 0x1F80);
      }                                                                 // register form = {L,M,S}FENCE: no-op
      break;
    case 0xA3: DecodeModRM(); DoBit(0, RdReg(rg, sz), sz); break;                // BT  r/m, r
    case 0xAB: DecodeModRM(); DoBit(1, RdReg(rg, sz), sz); break;                // BTS r/m, r
    case 0xB3: DecodeModRM(); DoBit(2, RdReg(rg, sz), sz); break;                // BTR r/m, r
    case 0xBB: DecodeModRM(); DoBit(3, RdReg(rg, sz), sz); break;                // BTC r/m, r
    case 0xBA: DecodeModRM(1); d = (rg & 7) - 4; b = Fetch8(); DoBit(d, b, sz); break;  // grp8 BT/S/R/C r/m,imm8
    case 0xB0: DecodeModRM(); a = RdReg(0, 1);                                    // CMPXCHG r/m8,r8
               if (lockf && isMem && ea < mem_size) b = AtomCas(ea, a, RdReg(rg, 1), 1);
               else { b = RdRM(1); if (a == b) WrRM(1, RdReg(rg, 1)); }
               r = a - b; SetSub(a, b, r, 1); if (a != b) WrReg(0, 1, b); break;
    case 0xB1: DecodeModRM(); a = RdReg(0, sz);                                   // CMPXCHG r/m,r
               if (lockf && isMem && ea < mem_size && !(ea & (sz - 1))) b = AtomCas(ea, a, RdReg(rg, sz), sz);
               else { b = RdRM(sz); if (a == b) WrRM(sz, RdReg(rg, sz)); }
               r = a - b; SetSub(a, b, r, sz); if (a != b) WrReg(0, sz, b); break;
    case 0xC0: DecodeModRM(); a = RdReg(rg, 1);                                   // XADD r/m8,r8
               if (lockf && isMem && ea < mem_size) { b = AtomAdd(ea, a, 1); WrReg(rg, 1, b); }
               else { b = RdRM(1); WrReg(rg, 1, b); WrRM(1, a + b); }
               r = a + b; SetAdd(a, b, r, 1); break;
    case 0xC1: DecodeModRM(); a = RdReg(rg, sz);                                  // XADD r/m,r
               if (lockf && isMem && ea < mem_size && !(ea & (sz - 1))) { b = AtomAdd(ea, a, sz); WrReg(rg, sz, b); }
               else { b = RdRM(sz); WrReg(rg, sz, b); WrRM(sz, a + b); }
               r = a + b; SetAdd(a, b, r, sz); break;
    case 0xC3: DecodeModRM(); WrRM(sz, RdReg(rg, sz)); break;                    // MOVNTI r/m,r
    case 0xA4: DecodeModRM(); DoShld(1, RdReg(rg, sz), Fetch8(), sz); break;     // SHLD r/m,r,imm8
    case 0xA5: DecodeModRM(); DoShld(1, RdReg(rg, sz), RdReg(1, 1), sz); break;  // SHLD r/m,r,CL
    case 0xAC: DecodeModRM(); DoShld(0, RdReg(rg, sz), Fetch8(), sz); break;     // SHRD r/m,r,imm8
    case 0xAD: DecodeModRM(); DoShld(0, RdReg(rg, sz), RdReg(1, 1), sz); break;  // SHRD r/m,r,CL
    default: g_badop = 0x0F00 | op2; halted = 2; "BADOP0F op2=%X rip=%X\n", op2, rip; break; } }

//---------------------------------------------------------------- one instruction
U0 HleBlit()
{//DCBlotColor8(dc,img) natively: img's width_internal*height bytes onto dc,
//leaving TRANSPARENT (0xFF) ones. Pops its return and 2 args as it does.
  U64 ret=RdMem(reg[4],8),dst_dc=RdMem(reg[4]+8,8),src_dc=RdMem(reg[4]+16,8),
	sb=RdMem(src_dc+of_dc.body,8),db=RdMem(dst_dc+of_dc.body,8);
  I64 w=RdMem(src_dc+of_dc.width_internal,4)&0xFFFF,
	h=RdMem(src_dc+of_dc.height,4)&0xFFFF,n=w*h,i;
  U8 v;
  if (sb && db && sb<mem_size && db<mem_size && n>0 && sb+n<=mem_size &&
	  db+n<=mem_size)
    for (i=0;i<n;i++) {
      v=mem[sb+i];
      if (v!=0xFF)
	mem[db+i]=v;
    }
  reg[0]=n;
  reg[4]+=24;
  rip=ret;
}

U0 CaptureFrom(U64 bd)
{//The finished 640x480 frame at bd into g_desk.
  I64 k;
  if (bd && bd+307200<=mem_size && __capture_lock) {
    for (k=0;k<307200;k++)
      g_desk[k]=mem[bd+k];
    g_desk_ready=1;
    g_desk_seq++;
    __capture_unlock;
  }
}

#include "video.HC"

U0 CaptureDesk()
{//Capture after GrUpdateVGAGraphics has committed the OS screen image.
  VideoCapture;
}

U64 g_raster_hle[2],g_poly3_hle,g_dc_transform;
I64 g_raster_n,g_raster_calls,g_poly3_calls;
//See $LK,"::/Doc/Credits.DD"$.
#define LIN_CONGRUE_A	6364136223846793005
#define LIN_CONGRUE_C	1442695040888963407

U16 RasterRand(U64 fsb)
{//RandU16 for the dither, on the task at fsb (Kernel/KMathB.HC).
  U64 seed=*(U64 *)(mem+fsb+of_task.rand_seed);
  seed=LIN_CONGRUE_A*seed^(seed&0xFFFFFFFF0000)>>16;
  seed+=LIN_CONGRUE_C;
  if (!(*(U32 *)(mem+fsb+of_task.task_flags)>>TASKf_NONTIMER_RAND&1))
    seed^=TscRead;
  *(U64 *)(mem+fsb+of_task.rand_seed)=seed;
  return seed&0xFFFF;
}
I64 RasterDone(I64 cnt)                              // RAX=cnt, pop ret + 6 args (callee-pop), return to caller
{ reg[0] = cnt; rip = RdMem(reg[4], 8); reg[4] += 8 + 6 * 8; return 1; }

I64 SpanFill(U64 dc,I64 vert,I64 x1,I64 x2,I64 y,I64 z1,I64 z2)
{//GrHLine and GrVLine: one clipping, depth and raster-operation path.
  U32 flags = *(U32 *)(mem + dc + of_dc.flags);
  U64 zbuf = *(U64 *)(mem + dc + of_dc.depth_buf), win = *(U64 *)(mem + dc + of_dc.win_task);
  U64 body = *(U64 *)(mem + dc + of_dc.body), fsb = msr_fsbase;
  I64 stride = *(I32 *)(mem + dc + of_dc.width_internal), width = *(I32 *)(mem + dc + of_dc.width), height = *(I32 *)(mem + dc + of_dc.height);
  U32 col_w = *(U32 *)(mem + dc + of_dc.color); 	    // packed: b0=color, b1=draw-mode, b2=color2, b3=dither flags
  I64 bg = *(U32 *)(mem + dc + of_dc.bkcolor) & 0xFF;
  I64 clip_lo = 0, clip_hi = 0, plotcnt = 0, i, idx, zptr, zslope = 0, zacc, cur_z; I64 dith_en = 0, dith_rand = 0, mode, color, w1, w2, cw;
  if (!zbuf) return -1;                                                            // no-z fast-fill path -> emulate
  I64 dimA = width, dimC = height, step = 1;        // moving-axis limit / fixed-axis limit / pixel stride
  I64 sA = of_task.scroll_x, sC = of_task.scroll_y, eA = of_dc.min_x, eAh = of_dc.max_x, eC = of_dc.min_y, eCh = of_dc.max_y, pA = of_task.pix_left, pAl = of_task.pix_right, pC = of_task.pix_top, pCl = of_task.pix_bottom, nA = of_dc.cur_x, nC = of_dc.cur_y;
  if (vert) { dimA = height; dimC = width; step = stride; sA = of_task.scroll_y; sC = of_task.scroll_x; eA = of_dc.min_y; eAh = of_dc.max_y; eC = of_dc.min_x; eCh = of_dc.max_x; pA = of_task.pix_top; pAl = of_task.pix_bottom; pC = of_task.pix_left; pCl = of_task.pix_right; nA = of_dc.cur_y; nC = of_dc.cur_x; }
  // ---- DC offset (flag bit 0xe) ----
  if ((flags >> 0xe) & 1) { x1 += *(I64 *)(mem + win + sA); x2 += *(I64 *)(mem + win + sA); y  += *(I64 *)(mem + win + sC); z1 += *(I64 *)(mem + win + of_task.scroll_z); z2 += *(I64 *)(mem + win + of_task.scroll_z); }
  // ---- bbox update (flag bit 0x10) ----
  if ((flags >> 0x10) & 1) {
    if (x1 < *(I64 *)(mem + dc + eA)) *(I64 *)(mem + dc + eA) = x1; if (x1 > *(I64 *)(mem + dc + eAh)) *(I64 *)(mem + dc + eAh) = x1; if (x2 < *(I64 *)(mem + dc + eA)) *(I64 *)(mem + dc + eA) = x2; if (x2 > *(I64 *)(mem + dc + eAh)) *(I64 *)(mem + dc + eAh) = x2;
    if (y  < *(I64 *)(mem + dc + eC)) *(I64 *)(mem + dc + eC) = y; if (y  > *(I64 *)(mem + dc + eCh)) *(I64 *)(mem + dc + eCh) = y; }
  if (y < 0) return 0;
  if (x2 < x1) { i = x1; x1 = x2; x2 = i; i = z1; z1 = z2; z2 = i; }
  if (x2 < 0) return 0;
  if (x1 < 0) { clip_lo = -x1; x1 = 0; }
  // ---- win clip (flag bit 0xe) ----
  if ((flags >> 0xe) & 1) {
    x1 += *(I64 *)(mem + win + pA); x2 += *(I64 *)(mem + win + pA); if (x1 > *(I64 *)(mem + win + pAl)) return 0;
    if (x2 > *(I64 *)(mem + win + pAl)) { clip_hi = x2 - *(I64 *)(mem + win + pAl); x2 = *(I64 *)(mem + win + pAl); }
    y += *(I64 *)(mem + win + pC); if (y < 0) return 0; if (y > *(I64 *)(mem + win + pCl)) return 0; if (x2 < 0) return 0; }
  if (x1 >= dimA) return 0; if (y >= dimC) return 0;
  // ---- z-slope + accumulator (z interpolates z1..z2 over the ORIGINAL span; clip-adjusted start) ----
  I64 count = (x2 + clip_hi) - (x1 - clip_lo);
  if (vert) idx = x1 * stride + y; else idx = y * stride + x1;
  zptr = zbuf + idx * 4; if (count) zslope = ((z2 - z1) << 32) / count; zacc = z1 << 32; zacc += clip_lo * zslope; if (x2 >= dimA) x2 = dimA - 1;
  // ---- collision distance metric (flag bit 0xb): nearest squared dist from (cur) over the span ----
  if ((flags >> 0xb) & 1) {
    I64 cx = *(I32 *)(mem + dc + nA), cy = *(I32 *)(mem + dc + nC), r13, dx;
    if (cx >= x1 && cx <= x2) r13 = 0;
    else if (cx < x1) { dx = x1 - cx; r13 = dx * dx; }
    else { dx = cx - x2; r13 = dx * dx; }
    I64 dy = y - cy; r13 += dy * dy; if (r13 < *(I64 *)(mem + dc + of_dc.nearest_dist)) *(I64 *)(mem + dc + of_dc.nearest_dist) = r13; }
  if ((flags >> 0xc) & 1) return 0;
  // ---- dither setup from the packed color word (b3 bits 0x80=random / 0x40=ordered) ----
  // matches GrHLine exactly (source recovered from the in-RAM kernel text + the compiled jump table):
  // c1.rop is overwritten with c0.rop, probability dither rolls ONCE before pixel 0, ordered dither
  // swaps the WORDS (so the per-pixel swap alternates correctly from an odd (x1^y) start).
  color = col_w & 0xFF; mode = (col_w >> 8) & 0xFF;
  w1 = col_w & 0xFFFF;                                 // color word (b0=color,b1=rop)
  w2 = (col_w >> 16) & 0xFFFF;                         // second dither color word
  cw = w1;                                             // active (color,rop) word
  if ((col_w >> 24) & 0xC0) { dith_en = 1; w2 = (w2 & 0xFF) | (w1 & 0xFF00);   // c1.rop = c0.rop
    if ((col_w >> 24) & 0x80) { dith_rand = 1; if (RasterRand(fsb) < *(U64 *)(mem + dc + of_dc.dither_probability_u16)) cw = w2; }   // initial roll picks pixel 0's word
    else { if ((x1 ^ y) & 1) { i = w1; w1 = w2; w2 = i; } cw = w1; } }
  // ---- occlusion (char_clear): GrHLine recomputes IsPixCovered0 every 8 px and skips covered ones. covered =
  //   win->win_z_num(@+0x30c) < gr.win_z_buf[(y>>3)*80 + (x>>3)]. Only when screen-bitmap, not-on-top, not winmgr.
  I64 need_cov = ((flags >> 0xe) & 1) && !((flags >> 0x11) & 1) && win && *(U64 *)(mem + win + of_task.next_task) != *(U64 *)(mem + guest.sys_winmgr_task);
  U64 wzbuf = 0; I64 wzn = 0, cov_row = 0, covM = 1, cc = 1;   // cell = cov_row + (moving>>3)*covM: H walks columns, V walks rows (*80)
  if (vert) covM = 80;
  if (need_cov) { wzbuf = *(U64 *)(mem + guest.gr_win_z_buf); if (wzbuf && wzbuf < mem_size) { wzn = *(U16 *)(mem + win + of_task.win_z_num); if (vert) cov_row = y >> 3; else cov_row = (y >> 3) * 80; cc = wzn >= *(U16 *)(mem + wzbuf + (cov_row + (x1 >> 3) * covM) * 2); } else need_cov = 0; }
  //Malformed drawing contexts fall back to guest code.
  if (idx < 0 || x2 < x1 || (x2 - x1 + 1) > 4096 || !body || body + idx + (x2 - x1 + 1) * step >= mem_size ||
      zbuf + (idx + (x2 - x1 + 1) * step) * 4 >= mem_size) return -1;
  // ---- per-pixel span (r14 draw-enable is always 1 in the handled case) ----
  for (i = x1; i <= x2; i++) {
    if (cc) { cur_z = zacc >> 32;                      // signed 32-bit current z (z-test+draw gated by char_clear)
      I64 draw = 1; if (cur_z < 0) draw = 0; else if (cur_z > *(I32 *)(mem + zptr)) draw = 0; else *(I32 *)(mem + zptr) = cur_z;
      if (draw) { color = cw & 0xFF; mode = (cw >> 8) & 0xFF;   // rop dispatch per the REAL jump table: 1=XOR, 2=COLLISION(count, no write), all others=WRITE
	if (mode == 1) mem[body + idx] ^= color; else if (mode == 2) { I64 v = mem[body + idx]; if (v != 0xFF && v != bg) (*(U64 *)(mem + dc + of_dc.collision_cnt))++; } else mem[body + idx] = color; plotcnt++; } }
    if (dith_en) { if (dith_rand) { if (RasterRand(fsb) < (*(U64 *)(mem + dc + of_dc.dither_probability_u16))) cw = w2; else cw = w1; } else { I64 t = w1; w1 = w2; w2 = t; cw = w1; } }
    if (need_cov && ((i + 1) & 7) == 0 && i + 1 <= x2) cc = wzn >= *(U16 *)(mem + wzbuf + (cov_row + ((i + 1) >> 3) * covM) * 2);   // recompute char_clear at the next 8-px boundary
    idx += step; zptr += step * 4; zacc += zslope; }
  g_raster_calls++;
  return plotcnt;
}
#include "poly.HC"

I64 PolyDone(I64 cnt) { reg[0] = cnt; rip = RdMem(reg[4], 8); reg[4] += 8 + 3 * 8; return 1; }   // GrFillPoly3 has 3 args (callee-pop)

I64 GrPoly3HLE()        // fires at GrFillPoly3's prologue: fan-triangulate the convex poly + raster each tri natively
{
  U64 dc, poly, body, zbuf, rmat; I64 n, i, S = 12, ax, ay, az, bx, by, bz, cx, cy, cz,res=0;   // CD3I32 = {I32 x,y,z} = 12 bytes
  dc = RdMem(reg[4] + 8, 8); n = RdMem(reg[4] + 0x10, 8); poly = RdMem(reg[4] + 0x18, 8);
  body = *(U64 *)(mem + dc + of_dc.body); zbuf = *(U64 *)(mem + dc + of_dc.depth_buf);
  U32 flags=*(U32 *)(mem+dc+of_dc.flags);
  if (flags&0x600) return 0;
  if ((flags&0x100) &&
        RdMem(dc+of_dc.transform,8)!=g_dc_transform) return 0;
  if (n < 3 || n > 64 || !body || !zbuf) return 0;                            // no z-buffer / odd n -> let the OS emulate
  if (poly + n * S >= mem_size) return 0;
  // We rasterize poly points as SCREEN coords. The real GrFillPoly3 first runs dc->transform on every
  // point (Mat4x4 by dc->r + dc->x/y/z offset, or a custom projection). Only the identity case is truly
  // screen-space (e.g. HolyCraft, which pre-projects and passes screen polys). If the DC carries a real
  // transform (Castle Frankenstein's 3D walls set dc->transform=CFTransform + a rotation dc->r), fall
  // back to the OS's GrFillPoly3 so it transforms first. CDC offsets are stable across builds:
  // dc->x/y/z @0xD8/0xDC/0xE0 (I32), dc->r @0xC8 (-> 4x4 matrix; identity = 0x100000000 on the diagonal).
  if (*(I32 *)(mem + dc + of_dc.x) || *(I32 *)(mem + dc + of_dc.y) || *(I32 *)(mem + dc + of_dc.z)) return 0;
  rmat = *(U64 *)(mem + dc + of_dc.r); if (!rmat) return 0;
  for (i = 0; i < 16; i++) {
    if (i == 0 || i == 5 || i == 10 || i == 15) { if (*(I64 *)(mem + rmat + i * 8) != 0x100000000) return 0; }
    else if (*(I64 *)(mem + rmat + i * 8)) return 0;
  }
  ax = *(I32 *)(mem + poly); ay = *(I32 *)(mem + poly + 4); az = *(I32 *)(mem + poly + 8);   // fan from poly[0]
  for (i=1;i<n-1;i++) {
    bx = *(I32 *)(mem + poly + i * S);     by = *(I32 *)(mem + poly + i * S + 4);     bz = *(I32 *)(mem + poly + i * S + 8);
    cx = *(I32 *)(mem + poly + (i + 1) * S); cy = *(I32 *)(mem + poly + (i + 1) * S + 4); cz = *(I32 *)(mem + poly + (i + 1) * S + 8);
    res+=PolyTri(dc,ax,ay,az,bx,by,bz,cx,cy,cz);
  }
  g_poly3_calls++;
  return PolyDone(res);
}

I64 RasterHLE()
{//The named guest primitives share one span filler.
  U64 dc;
  I64 vert,x1,x2,y,z1,z2,res;
  if (VideoHLE) return 1;
  if (g_poly3_hle && rip==g_poly3_hle)
    return GrPoly3HLE;
  if (g_raster_n!=2)
    return 0;
  if (rip==g_raster_hle[0])
    vert=FALSE;
  else if (rip==g_raster_hle[1])
    vert=TRUE;
  else
    return 0;
  dc=RdMem(reg[4]+8,8);
  if (vert) {
    y=RdMem(reg[4]+0x10,8);
    x1=RdMem(reg[4]+0x18,8);
    x2=RdMem(reg[4]+0x20,8);
  } else {
    x1=RdMem(reg[4]+0x10,8);
    x2=RdMem(reg[4]+0x18,8);
    y=RdMem(reg[4]+0x20,8);
  }
  z1=RdMem(reg[4]+0x28,8);
  z2=RdMem(reg[4]+0x30,8);
  res=SpanFill(dc,vert,x1,x2,y,z1,z2);
  if (res<0)
    return 0;
  return RasterDone(res);
}

U0 Step()
{
  U64 op, a, b, r, cf; I64 sz, d, opn, r2, imm;

  if (g_hooktbl[rip & 0xFFFF]) {                   // gate: only ~1.5% of rips need the four hook compares
    if (RasterHLE) return;
    if (rip == g_hle_blit) { HleBlit(); return; }   // native fast-path for the dominant compositor blit
    if (rip==g_capture_text)
      CaptureFrom(GuestU64(GuestU64(guest.gr_dc2)+of_dc.body));
    if (rip == g_capture_rip) CaptureDesk();        // grab the finished frame (incl. native cursor) tear-free

  }
  pfx66 = 0; repf = 0; hasRex = 0; rexW = 0; rexR = 0; rexX = 0; rexB = 0; g_segbase = 0; lockf = 0; op = mem[rip]; rip++;
  while (g_pfx[op]) {                                  // legacy prefixes (one table lookup, not 11 compares)
    if (op == 0x66) pfx66 = 1; else if (op == 0xF3) repf = 1; else if (op == 0xF2) repf = 2;
    else if (op == 0x64) g_segbase = msr_fsbase;   // FS:
    else if (op == 0x65) g_segbase = msr_gsbase;   // GS:
    else if (op == 0xF0) lockf = 1;                // LOCK: make this instruction's mem RMW atomic (SMP)
    op = mem[rip]; rip++;
  }
  if (op >= 0x40 && op <= 0x4F) { hasRex = 1; rexW = (op >> 3) & 1; rexR = (op >> 2) & 1; rexX = (op >> 1) & 1; rexB = op & 1; op = mem[rip]; rip++; }
  if (rexW) sz = 8; else if (pfx66) sz = 2; else sz = 4;

  // ---- patterned ALU encodings (00..3F) ----
  if (op < 0x40 && (op & 7) == 0) { opn = (op >> 3) & 7; DecodeModRM(); a = RdRM(1);     b = RdReg(rg, 1);  r = Arith(opn, a, b, 1);  if (opn != 7) WrRM(1, r);       return; }
  if (op < 0x40 && (op & 7) == 1) { opn = (op >> 3) & 7; DecodeModRM(); a = RdRM(sz);    b = RdReg(rg, sz); r = Arith(opn, a, b, sz); if (opn != 7) WrRM(sz, r);      return; }
  if (op < 0x40 && (op & 7) == 2) { opn = (op >> 3) & 7; DecodeModRM(); a = RdReg(rg, 1);  b = RdRM(1);     r = Arith(opn, a, b, 1);  if (opn != 7) WrReg(rg, 1, r);  return; }
  if (op < 0x40 && (op & 7) == 3) { opn = (op >> 3) & 7; DecodeModRM(); a = RdReg(rg, sz); b = RdRM(sz);    r = Arith(opn, a, b, sz); if (opn != 7) WrReg(rg, sz, r); return; }
  if (op < 0x40 && (op & 7) == 4) { opn = (op >> 3) & 7; b = Fetch8();        a = RdReg(0, 1);  r = Arith(opn, a, b, 1);  if (opn != 7) WrReg(0, 1, r);  return; }  // ALU AL, imm8
  if (op < 0x40 && (op & 7) == 5) { opn = (op >> 3) & 7; b = FetchImm(sz);    a = RdReg(0, sz); r = Arith(opn, a, b, sz); if (opn != 7) WrReg(0, sz, r); return; }  // ALU eAX, imm

  // hot-path: MOV dominates render/blit loops - handle before the long opcode switch (RdRM/WrRM inlined)
  if (op == 0x89) { DecodeModRM(); if (isMem) WrMem(ea, sz, RdReg(rg, sz)); else WrReg(rm, sz, RdReg(rg, sz)); return; }  // MOV r/m, r
  if (op == 0x8B) { DecodeModRM(); WrReg(rg, sz, isMem ? RdMem(ea, sz) : RdReg(rm, sz)); return; }                        // MOV r, r/m
  if (op == 0x88) { DecodeModRM(); if (isMem) WrMem(ea, 1, RdReg(rg, 1)); else WrReg(rm, 1, RdReg(rg, 1)); return; }      // MOV r/m8, r8
  if (op == 0x8A) { DecodeModRM(); WrReg(rg, 1, isMem ? RdMem(ea, 1) : RdReg(rm, 1)); return; }                          // MOV r8, r/m8

  switch (op) {
    case 0x90: break;
    case 0xF4: halted = 1; break;
    case 0xD8: case 0xD9: case 0xDA: case 0xDB:                     // x87 FPU escapes
    case 0xDC: case 0xDD: case 0xDE: case 0xDF: OpX87(op); break;
    case 0xFC: rfl &= ~F_DF; break;                      // CLD
    case 0xFD: rfl |= F_DF; break;                       // STD
    case 0x0F: Op0F(); break;

    case 0x80: DecodeModRM(1); opn = rg & 7; a = RdRM(1);  b = Fetch8();          r = Arith(opn, a, b, 1);  if (opn != 7) WrRM(1, r);  break; // grp1 r/m8, imm8
    case 0x83: DecodeModRM(1); opn = rg & 7; a = RdRM(sz); b = SignExt8(Fetch8());r = Arith(opn, a, b, sz); if (opn != 7) WrRM(sz, r); break; // grp1 r/m, imm8
    case 0x81: d = 4; if (pfx66) d = 2; DecodeModRM(d); opn = rg & 7; a = RdRM(sz); b = FetchImm(sz); r = Arith(opn, a, b, sz); if (opn != 7) WrRM(sz, r); break; // grp1 r/m, imm

    case 0x84: DecodeModRM(); SetLogic((RdRM(1) & RdReg(rg, 1)) & 0xFF, 1); break;   // TEST r/m8, r8
    case 0x85: DecodeModRM(); SetLogic((RdRM(sz) & RdReg(rg, sz)) & SizeMask(sz), sz); break; // TEST r/m, r
    case 0xA0: a = Fetch64(); WrReg(0, 1, RdMem(a, 1)); break;     // MOV AL, [moffs64]
    case 0xA1: a = Fetch64(); WrReg(0, sz, RdMem(a, sz)); break;   // MOV [r/e/]AX, [moffs64]
    case 0xA2: a = Fetch64(); WrMem(a, 1, RdReg(0, 1)); break;     // MOV [moffs64], AL
    case 0xA3: a = Fetch64(); WrMem(a, sz, RdReg(0, sz)); break;   // MOV [moffs64], [r/e/]AX
    case 0xA8: b = Fetch8();     SetLogic((RdReg(0, 1) & b) & 0xFF, 1); break;       // TEST AL, imm8
    case 0xA9: b = FetchImm(sz); SetLogic((RdReg(0, sz) & b) & SizeMask(sz), sz); break; // TEST eAX, imm

    case 0x88: DecodeModRM(); WrRM(1, RdReg(rg, 1)); break;       // MOV r/m8, r8
    case 0x8A: DecodeModRM(); WrReg(rg, 1, RdRM(1)); break;       // MOV r8, r/m8
    case 0x89: DecodeModRM(); WrRM(sz, RdReg(rg, sz)); break;     // MOV r/m, r
    case 0x8B: DecodeModRM(); WrReg(rg, sz, RdRM(sz)); break;     // MOV r, r/m
    case 0x86: DecodeModRM();                                                                       // XCHG r/m8, r8 (mem form is implicitly LOCKed)
               if (isMem && ea < mem_size) imm = AtomXchg(ea, RdReg(rg, 1), 1);
               else { imm = RdRM(1); WrRM(1, RdReg(rg, 1)); } WrReg(rg, 1, imm); break;
    case 0x87: DecodeModRM();                                                                       // XCHG r/m, r (mem form is implicitly LOCKed)
               if (isMem && ea < mem_size && !(ea & (sz - 1))) imm = AtomXchg(ea, RdReg(rg, sz), sz);
               else { imm = RdRM(sz); WrRM(sz, RdReg(rg, sz)); } WrReg(rg, sz, imm); break;
    case 0x8E: DecodeModRM(); g_seg[rg & 7] = RdRM(2); break;     // MOV Sreg, r/m16 - selector stored, ignored (flat)
    case 0x8C: DecodeModRM(); WrRM(2, g_seg[rg & 7]); break;      // MOV r/m16, Sreg
    case 0xC6: DecodeModRM(1); WrRM(1, Fetch8()); break;          // MOV r/m8, imm8
    case 0xC7: DecodeModRM(sz == 2 ? 2 : 4); imm = FetchImm(sz); WrRM(sz, imm); break;  // MOV r/m, imm (imm16 w/ 0x66, else imm32)
    case 0x8D: DecodeModRM(); WrReg(rg, sz, ea); break;          // LEA
    case 0x63: DecodeModRM(); WrReg(rg, sz, SignExtTo64(RdRM(4), 4)); break;     // MOVSXD r64, r/m32
    case 0x87: DecodeModRM(); a = RdRM(sz); WrRM(sz, RdReg(rg, sz)); WrReg(rg, sz, a); break;  // XCHG r/m, r
    case 0x91: case 0x92: case 0x93: case 0x94: case 0x95: case 0x96: case 0x97:  // XCHG eAX, r
      r2 = (op - 0x90) | (rexB << 3); a = reg[0]; b = RdReg(r2, sz); WrReg(0, sz, b); WrReg(r2, sz, a); break;
    case 0x98:                                                                    // CBW / CWDE / CDQE
      if (rexW) reg[0] = SignExtTo64(reg[0] & 0xFFFFFFFF, 4); else if (pfx66) WrReg(0, 2, SignExtTo64(reg[0] & 0xFF, 1)); else WrReg(0, 4, SignExtTo64(reg[0] & 0xFFFF, 2));
      break;
    case 0x9C: reg[4] -= 8; WrMem(reg[4], 8, rfl); break;                          // PUSHFQ
    case 0x9D: rfl = (RdMem(reg[4], 8) & ~0x10000) | 2; reg[4] += 8; break;        // POPFQ (bit1 always 1)
    case 0x8F: DecodeModRM(); a = RdMem(reg[4], 8); reg[4] += 8; WrRM(8, a); break;  // POP r/m64
    case 0x69: d = 4; if (pfx66) d = 2; DecodeModRM(d); a = RdRM(sz); imm = FetchImm(sz);       WrReg(rg, sz, (SignExtTo64(a, sz) * imm) & SizeMask(sz)); break;  // IMUL r,r/m,imm
    case 0x6B: DecodeModRM(1); a = RdRM(sz); imm = SignExt8(Fetch8()); WrReg(rg, sz, (SignExtTo64(a, sz) * imm) & SizeMask(sz)); break;  // IMUL r,r/m,imm8

    case 0xB0: case 0xB1: case 0xB2: case 0xB3: case 0xB4: case 0xB5: case 0xB6: case 0xB7:  // MOV r8, imm8
      r2 = (op - 0xB0) | (rexB << 3); WrReg(r2, 1, Fetch8()); break;
    case 0xB8: case 0xB9: case 0xBA: case 0xBB: case 0xBC: case 0xBD: case 0xBE: case 0xBF:  // MOV r, imm (imm size follows operand size)
      r2 = (op - 0xB8) | (rexB << 3); if (rexW) reg[r2] = Fetch64();
      else if (sz == 2) { WrReg(r2, 2, RdMem(rip, 2)); rip += 2; }   // 0x66 prefix -> MOV r16, imm16 (don't over-read imm32)
      else reg[r2] = Fetch32();
      break;

    case 0xC0: DecodeModRM(1); d = Fetch8();        DoShift(rg & 7, d, 1);  break;  // grp2 r/m8, imm8
    case 0xC1: DecodeModRM(1); d = Fetch8();        DoShift(rg & 7, d, sz); break;  // grp2 r/m, imm8
    case 0xD0: DecodeModRM();                      DoShift(rg & 7, 1, 1);  break;  // grp2 r/m8, 1
    case 0xD1: DecodeModRM();                      DoShift(rg & 7, 1, sz); break;  // grp2 r/m, 1
    case 0xD2: DecodeModRM(); d = RdReg(1, 1);     DoShift(rg & 7, d, 1);  break;  // grp2 r/m8, CL
    case 0xD3: DecodeModRM(); d = RdReg(1, 1);     DoShift(rg & 7, d, sz); break;  // grp2 r/m, CL
    case 0xD7: reg[0] = (reg[0] & 0xFFFFFFFFFFFFFF00) |                             // XLAT: AL = DS:[RBX+AL]
               RdMem(reg[3] + (reg[0] & 0xFF) + g_segbase, 1); break;

    // grp3: only TEST (reg field 0/1) has a trailing immediate, so RIP-relative EA must skip it.
    // Peek the ModRM reg field before decoding to pass the right immlen (else EA lands short).
    case 0xF6: DecodeModRM(((mem[rip] >> 3) & 7) <= 1 ? 1 : 0); Grp3(1);  break;
    case 0xF7: DecodeModRM(((mem[rip] >> 3) & 7) <= 1 ? (sz == 2 ? 2 : 4) : 0); Grp3(sz); break;

    case 0xFE: DecodeModRM();                                                       // grp4: INC/DEC r/m8
      if ((rg & 7) == 0) { cf = rfl & F_CF; a = RdRM(1); r = a + 1; WrRM(1, r); SetAdd(a, 1, r, 1); rfl = (rfl & ~F_CF) | cf; }
      else               { cf = rfl & F_CF; a = RdRM(1); r = a - 1; WrRM(1, r); SetSub(a, 1, r, 1); rfl = (rfl & ~F_CF) | cf; }
      break;
    case 0xFF: DecodeModRM();                                                       // grp5
      if      ((rg & 7) == 0) { cf = rfl & F_CF; a = RdRM(sz); r = a + 1; WrRM(sz, r); SetAdd(a, 1, r, sz); rfl = (rfl & ~F_CF) | cf; }
      else if ((rg & 7) == 1) { cf = rfl & F_CF; a = RdRM(sz); r = a - 1; WrRM(sz, r); SetSub(a, 1, r, sz); rfl = (rfl & ~F_CF) | cf; }
      else if ((rg & 7) == 2) { reg[4] -= 8; WrMem(reg[4], 8, rip); rip = RdRM(8); }
      else if ((rg & 7) == 4) { rip = RdRM(8); }
      else if ((rg & 7) == 6) { reg[4] -= 8; WrMem(reg[4], 8, RdRM(8)); }
      break;

    case 0x50: case 0x51: case 0x52: case 0x53: case 0x54: case 0x55: case 0x56: case 0x57:
      r2 = (op - 0x50) | (rexB << 3); reg[4] -= 8; WrMem(reg[4], 8, reg[r2]); break;
    case 0x58: case 0x59: case 0x5A: case 0x5B: case 0x5C: case 0x5D: case 0x5E: case 0x5F:
      r2 = (op - 0x58) | (rexB << 3); reg[r2] = RdMem(reg[4], 8); reg[4] += 8; break;
    case 0x68: reg[4] -= 8; WrMem(reg[4], 8, SignExt32(Fetch32())); break;   // PUSH imm32
    case 0x6A: reg[4] -= 8; WrMem(reg[4], 8, SignExt8(Fetch8()));   break;   // PUSH imm8
    case 0xC9: reg[4] = reg[5]; reg[5] = RdMem(reg[4], 8); reg[4] += 8; break; // LEAVE
    case 0x99: if (rexW) { if (reg[0] >> 63) reg[2] = 0xFFFFFFFFFFFFFFFF; else reg[2] = 0; }  // CQO
               else { if (reg[0] & 0x80000000) WrReg(2, 4, 0xFFFFFFFF); else WrReg(2, 4, 0); } break; // CDQ

    case 0x6C: DoIns(1); break;                   // INSB  [RDI] <- DX
    case 0x6D: DoIns(sz == 2 ? 2 : 4); break;     // INSW/INSD (ATA PIO sector reads land here)
    case 0x6E: DoOuts(1); break;                  // OUTSB DX <- [RSI]
    case 0x6F: DoOuts(sz == 2 ? 2 : 4); break;    // OUTSW/OUTSD
    case 0xA4: DoStr(0xA4, 1);  break;
    case 0xA5: DoStr(0xA5, sz); break;
    case 0xAA: DoStr(0xAA, 1);  break;
    case 0xAB: DoStr(0xAB, sz); break;
    case 0xAC: DoStr(0xAC, 1);  break;
    case 0xAD: DoStr(0xAD, sz); break;
    case 0xA6: DoStr(0xA6, 1);  break;            // CMPSB
    case 0xA7: DoStr(0xA7, sz); break;            // CMPS
    case 0xAE: DoStr(0xAE, 1);  break;            // SCASB
    case 0xAF: DoStr(0xAF, sz); break;            // SCAS

    case 0x70: case 0x71: case 0x72: case 0x73: case 0x74: case 0x75: case 0x76: case 0x77:  // Jcc rel8
    case 0x78: case 0x79: case 0x7A: case 0x7B: case 0x7C: case 0x7D: case 0x7E: case 0x7F:
      d = SignExt8(Fetch8()); if (Cond(op - 0x70)) rip += d; break;
    case 0xEB: d = SignExt8(Fetch8()); rip += d; break;
    case 0xE0: d = SignExt8(Fetch8()); reg[1]--; if (reg[1] != 0 && !(rfl & F_ZF)) rip += d; break;  // LOOPNE
    case 0xE1: d = SignExt8(Fetch8()); reg[1]--; if (reg[1] != 0 &&  (rfl & F_ZF)) rip += d; break;  // LOOPE
    case 0xE2: d = SignExt8(Fetch8()); reg[1]--; if (reg[1] != 0) rip += d; break;                   // LOOP
    case 0xE3: d = SignExt8(Fetch8()); if (reg[1] == 0) rip += d; break;                             // JRCXZ
    case 0xE9: d = SignExt32(Fetch32()); rip += d; break;
    case 0xE8: d = SignExt32(Fetch32()); reg[4] -= 8; WrMem(reg[4], 8, rip); rip += d; break;
    case 0xC2: d = RdMem(rip, 2); rip = RdMem(reg[4], 8); reg[4] += 8 + d; break;  // RET imm16 (HolyC callee-pops)
    case 0xC3: rip = RdMem(reg[4], 8); reg[4] += 8; break;

    case 0xFA: rfl &= ~F_IF; break;                                 // CLI
    case 0xFB: rfl |= F_IF; break;                                  // STI
    case 0xE4: d = Fetch8(); WrReg(0, 1, IoIn(d)); break;           // IN AL, imm8
    case 0xE5: d = Fetch8(); WrReg(0, sz, IoInWidth(d, sz)); break;          // IN eAX, imm8
    case 0xE6: d = Fetch8(); IoOut(d, RdReg(0, 1)); break;          // OUT imm8, AL
    case 0xE7: d = Fetch8(); IoOutWidth(d, RdReg(0, sz), sz); break;         // OUT imm8, eAX
    case 0xEC: WrReg(0, 1, IoIn(reg[2] & 0xFFFF)); break;           // IN AL, DX
    case 0xED: WrReg(0, sz, IoInWidth(reg[2] & 0xFFFF, sz)); break;          // IN eAX, DX
    case 0xEE: IoOut(reg[2] & 0xFFFF, RdReg(0, 1)); break;          // OUT DX, AL
    case 0xEF: IoOutWidth(reg[2] & 0xFFFF, RdReg(0, sz), sz); break;         // OUT DX, eAX
    case 0xCC: DoInt(3, 0, 0); break;                               // INT3
    case 0xCD: d = Fetch8(); DoInt(d, 0, 0); break;                 // INT n
    case 0xCF: DoIret(); break;                                     // IRETQ

    default: g_badop = op; halted = 2; "BADOP op=%X rip=%X b=%X %X %X %X\n", op, rip, mem[rip-2], mem[rip-1], mem[rip], mem[rip+1]; break; } }

#include "guestcall.HC"               // host-injected guest calls (backend execution API); needs Step(), hooks into Run() below

U0 RunTo(U64 target,I64 budget)
{//Interpret until target, a fault, or budget instructions have run.
  I64 lim=icount+budget;
  while (icount<lim && rip!=target && halted<2) {
    if (halted==1) {
      if (rfl&F_IF &&
            ((pic1_irr&~pic1_mask) || (pic2_irr&~pic2_mask))) {
        halted=0;
        CheckIrq;
      }
    } else
      Step;
    icount++;
    TimeRun(1);
    if (rfl&F_IF &&
          ((pic1_irr&~pic1_mask) || (pic2_irr&~pic2_mask)))
      CheckIrq;
  }
}

U64 RamBase()
{//Where guest RAM starts in this program's memory.
  return mem;
}

Bool CoreAttach()
{//Hands this core's state to the host's JIT. TRUE if the host has one.
  Bool res=__jit_state(&reg[0],&rfl,&rip);
  __jit_x87(&fpr[0],&fsp,&x87_sw);
  __jit_seg(&msr_fsbase,&msr_gsbase,&tsc,&x87_cw,&xmm_lo[0],&xmm_hi[0]);
  return res;
}

I64 g_core_faults[NCORES];	//Faults each core has stopped on.

I64 RunCore(I64 budget)
{//An application core's turn: up to budget instructions, with no device
//ticks (those are core 0's). Takes a pending IPI at IF=1 and comes back
//early when the core idles in HLT. Returns how many instructions ran, or
//-halted when a fault stopped the core. The first fault is cleared, so
//the core goes on serving jobs.
  I64 start=icount,lim=icount+budget,ip,b,res;
  while (icount<lim) {
    if (halted>=2) {
      res=-halted;
      if (!g_core_faults[MyCore()]++)
	halted=0;
      return res;
    }
    //Atomic load: it acquires the sender's writes before the handler runs.
    ip=__a_or64(&g_ipi_pending[MyCore()],0);
    if (ip && rfl&F_IF) {
      __a_and64(&g_ipi_pending[MyCore()],0);
      halted=0;
      DoInt(ip&0xFF,0,0);
    }
    if (halted==1)
      break;
    b=0;
    if (!g_hooktbl[rip&0xFFFF])
      b=__ap_run(rip,lim-icount);
    if (!b) {
      Step;
      b=1;
    }
    icount+=b;
  }
  return icount-start;
}

U0 Run(I64 maxi)
{//Core zero runs the devices. Other cores cannot spend its budget.
  I64 b,batch,cap,slot;
  Bool pending;
  while (icount<maxi && halted<2) {
    pending=(pic1_irr&~pic1_mask) || (pic2_irr&~pic2_mask);
    if (pending && rfl&F_IF) {
      halted=0;
      CheckIrq;
    }
    if (g_gc_state==GC_PENDING && rfl&F_IF)
      GuestCallRun;
    cap=MinI64(maxi-icount,TimeTickWait);
    if (cap<=0)
      break;
    if (halted==1) {
      time_idle+=cap;
      icount+=cap;
      TimeRun(cap);
    } else {
      b=0;
      if (g_jit_on && !g_hooktbl[rip&0xFFFF]) {
        slot=(rip^(rip>>16))&0xFFFF;
        if (g_jit_rip[slot]==rip && g_jit_n[slot]>0) {
          if (pending && !(rfl&F_IF))
            cap=-cap;
          b=__jit_dispatch(cap);
        } else {
          if (g_jit_rip[slot]!=rip) {
            g_jit_rip[slot]=rip;
            g_jit_hot[slot]=0;
            g_jit_n[slot]=-1;
          }
          if (g_jit_n[slot]<0 && ++g_jit_hot[slot]>64)
            g_jit_n[slot]=__jit_compile(rip);
        }
      }
      if (!b) {
        batch=MinI64(64,MinI64(maxi-icount,TimeTickWait));
        while (b<batch) {
          Step;
          b++;
          if (halted || (pending && rfl&F_IF))
            break;
          slot=(rip^(rip>>16))&0xFFFF;
          if (g_jit_on && g_jit_rip[slot]==rip && g_jit_n[slot]>0)
            break;
        }
      }
      icount+=b;
      TimeRun(b);
    }
  }
}

U0 Reset()
{
  I64 i; TimeRst; KbdRst; for (i = 0; i < 16; i++) reg[i] = 0; rip = 0; rfl = 0; halted = 0; icount = 0; g_badop = 0; reg[4] = 0x100000; cr0 = 0; cr2 = 0; cr3 = 0; cr4 = 0; cr8 = 0; g_cs = 0x08; g_ss = 0x10; idtr_base = 0; idtr_limit = 0; gdtr_base = 0; gdtr_limit = 0; tsc = 0;
  for (i = 0; i < 16; i++) { xmm_lo[i] = 0; xmm_hi[i] = 0; }
  pic1_base = 0; pic1_mask = 0xFF; pic1_irr = 0; pic1_isr = 0; pic1_initstep = 0; pic2_base = 0; pic2_mask = 0xFF; pic2_irr = 0; pic2_isr = 0; pic2_initstep = 0; pit_reload = 0; pit_div = 0; pit_counter = 0; pit_wlo = 1; }
U0 Load(U8 *p, I64 n, U64 at) { I64 i; for (i = 0; i < n; i++) mem[at + i] = p[i]; rip = at; }
