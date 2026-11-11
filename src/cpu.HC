#include "host.HC"                  // the host contract: every import hemu makes (see host.HC)
#include "core.HC"                  // per-core CPU state + SMP/guest-call scaffolding shared by every entry

U8 *mem;                            // guest RAM (MAlloc'd so the snapshot can use 100s of MB)
U64 mem_size;                       // bytes of guest RAM; anything >= this is MMIO (LAPIC/HPET/IOAPIC)
U8 g_pfx[256];                       // prefix-byte lookup (1 = legacy prefix) - skips an 11-way compare per instr
#include "sym.HC" //HEMU finds what it needs in the guest by name.

// PER-CORE state (reg/rip/rfl/halted/irq_stall/fpu/seg/decode/icount) lives in CCpuState g_cpu_st[] - defined
// in core.HC (included above), accessed through #define reg CST.f_reg etc. (CST = this instance's MyCore
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
U64 g_badop;
// system state: control regs, descriptor tables, MSRs, TSC, code/stack segments
U64 cr0, cr2, cr3, cr4, cr8, g_cs, g_ss; U64 idtr_base, idtr_limit, gdtr_base, gdtr_limit;
U64 msr_efer, msr_star, msr_lstar, msr_sfmask, msr_kgsbase, msr_apic;   // msr_fsbase/msr_gsbase moved into CCpuState (per-core)
U64 g_xmm_lo[NCORES][16], g_xmm_hi[NCORES][16];   // SSE XMM registers - PER-CORE (xmm_lo/xmm_hi #defines in core.HC): an AP suspended mid-XMM must not be clobbered by another core
I64 g_lockf[NCORES];                  // PER-CORE: 1 = the current instruction had a 0xF0 LOCK prefix (lockf #define in core.HC) - makes the RMW atomic on shared memory
#include "Dev"

#define F_CF 0x0001
#define F_PF 0x0004
#define F_AF 0x0010
#define F_ZF 0x0040
#define F_SF 0x0080
#define F_IF 0x0200
#define F_DF 0x0400
#define F_OF 0x0800

U0 InitMem(U64 sz)
{//Boundary-spanning reads use padding beyond the guest's RAM limit.
  I64 i;
  mem=MAlloc(sz+16);
  mem_size=sz;
  for (i=0;i<256;i++)
    g_pfx[i]=0;
  g_pfx[0x66]=1;g_pfx[0x67]=1;g_pfx[0xF0]=1;
  g_pfx[0xF2]=1;g_pfx[0xF3]=1;g_pfx[0x2E]=1;
  g_pfx[0x36]=1;g_pfx[0x3E]=1;g_pfx[0x26]=1;
  g_pfx[0x64]=1;g_pfx[0x65]=1;
  g_desk=MAlloc(640*480);
  DevInit;
}

#include "Mem"

//---------------------------------------------------------------- fetch / imm
U64 Fetch8()  { U64 b = mem[rip]; rip++; return b; }
U64 Fetch32() { U64 v = *(mem + rip)(U32*); rip += 4; return v; }   // rip is always code in RAM - skip RdMem's MMIO check
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
    for (bit = 127; bit >= 0; bit--) { rem = rem << 1; if (bit >= 64) bv = (hi >> (bit - 64)) & 1; else bv = (lo >> bit) & 1; rem |= bv; if (rem >= a) { rem -= a; q |= 1(U64)<<bit; } }
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
  I64 cmpkind; U64 n,total,i,s,dt,val;
  cmpkind = (op == 0xA6 || op == 0xA7 || op == 0xAE || op == 0xAF);   // SCAS/CMPS terminate on ZF
  if (!repf) { StrStep(op, sz); return; }
  // Bulk fast path for REP MOVS/STOS (forward, flat) - TempleOS's MemCpy/MemSet are REP MOVSQ/STOSQ
  // over large buffers; emulating them element-by-element through StrStep was the single biggest
  // interpreter cost. Do them as one native copy/fill. (DF=0, no segment override, in-RAM only.)
  if (g_segbase == 0 && !(rfl & F_DF) && reg[1] > 0) {
    n = reg[1]; total = n * sz;
    if (op == 0xA4 || op == 0xA5) {                                   // REP MOVS: copy RSI -> RDI
      s=reg[6];dt=reg[7];
      if (s + total <= mem_size && dt + total <= mem_size) { if (sz == 8) for (i = 0; i < n; i++) *(mem + dt + i * 8)(U64*) = *(mem + s + i * 8)(U64*); else         for (i = 0; i < total; i++) mem[dt + i] = mem[s + i]; reg[6] = s + total; reg[7] = dt + total; reg[1] = 0; return; }
    } else if (op == 0xAA || op == 0xAB) {                            // REP STOS: fill RDI with AL/AX/EAX/RAX
      dt=reg[7];val=RdReg(0,sz);
      if (dt + total <= mem_size) { if      (sz == 8) for (i = 0; i < n; i++) *(mem + dt + i * 8)(U64*) = val; else if (sz == 1) for (i = 0; i < total; i++) mem[dt + i] = val; else              for (i = 0; i < n; i++) WrMem(dt + i * sz, sz, val); reg[7] = dt + total; reg[1] = 0; return; } } }
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
// String I/O (INS/OUTS, +REP). The ATA PIO data port (0x1F0) flows through these for REP INSW disk
// reads - IoIn returns blank-disk zeros, so the read completes instead of deadlocking the poller.
U0 DoIns(I64 sz)                                          // INS: [RDI] <- port DX
{ I64 d; if (rfl & F_DF) d = -sz; else d = sz; if (!repf) { WrMem(reg[7], sz, IoInWidth(reg[2] & 0xFFFF, sz)); reg[7] += d; return; } while (reg[1] != 0) { WrMem(reg[7], sz, IoInWidth(reg[2] & 0xFFFF, sz)); reg[7] += d; reg[1]--; } }
U0 DoOuts(I64 sz)                                         // OUTS: port DX <- [RSI]
{ I64 d; if (rfl & F_DF) d = -sz; else d = sz; if (!repf) { IoOutWidth(reg[2] & 0xFFFF, RdMem(reg[6], sz), sz); reg[6] += d; return; } while (reg[1] != 0) { IoOutWidth(reg[2] & 0xFFFF, RdMem(reg[6], sz), sz); reg[6] += d; reg[1]--; } }
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
U0 CheckIrq()
{
  I64 vec=PicNext;
  if (vec>=0) DoInt(vec,0,0);
}

U0 DoIret()                                       // IRETQ: pop RIP, CS, RFLAGS, RSP, SS
{ U64 newsp; rip   = RdMem(reg[4] + 0, 8); g_cs  = RdMem(reg[4] + 8, 8); rfl   = RdMem(reg[4] + 16, 8); newsp = RdMem(reg[4] + 24, 8); g_ss  = RdMem(reg[4] + 32, 8); reg[4] = newsp; }

#include "Fpu"

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
    case 0x51: DecodeModRM(); xmm_lo[rg] = F64ToBits(Sqrt(BitsToF64(RdXmm64()))); break;                                           // SQRTSD
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
	h=RdMem(src_dc+of_dc.height,4)&0xFFFF,n=w*h,i,v;
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
  U64 seed=*(mem+fsb+of_task.rand_seed)(U64*);
  seed=LIN_CONGRUE_A*seed^(seed&0xFFFFFFFF0000)>>16;
  seed+=LIN_CONGRUE_C;
  if (!(*(mem+fsb+of_task.task_flags)(U32*)>>TASKf_NONTIMER_RAND&1))
    seed^=TscRead;
  *(mem+fsb+of_task.rand_seed)(U64*)=seed;
  return seed&0xFFFF;
}
I64 RasterDone(I64 cnt)                              // RAX=cnt, pop ret + 6 args (callee-pop), return to caller
{ reg[0] = cnt; rip = RdMem(reg[4], 8); reg[4] += 8 + 6 * 8; return 1; }

I64 SpanFill(U64 dc,I64 vert,I64 x1,I64 x2,I64 y,I64 z1,I64 z2)
{//GrHLine and GrVLine: one clipping, depth and raster-operation path.
  U32 flags = *(mem + dc + of_dc.flags)(U32*);
  U64 zbuf = *(mem + dc + of_dc.depth_buf)(U64*), win = *(mem + dc + of_dc.win_task)(U64*);
  U64 body = *(mem + dc + of_dc.body)(U64*), fsb = msr_fsbase;
  I64 stride = *(mem + dc + of_dc.width_internal)(I32*), width = *(mem + dc + of_dc.width)(I32*), height = *(mem + dc + of_dc.height)(I32*);
  U32 col_w = *(mem + dc + of_dc.color)(U32*); 	    // packed: b0=color, b1=draw-mode, b2=color2, b3=dither flags
  I64 bg = *(mem + dc + of_dc.bkcolor)(U32*) & 0xFF;
  I64 clip_lo = 0, clip_hi = 0, plotcnt = 0, i, idx, zptr, zslope = 0, zacc, cur_z; I64 dith_en = 0, dith_rand = 0, mode, color, w1, w2, cw;
  if (!zbuf) return -1;                                                            // no-z fast-fill path -> emulate
  I64 dimA = width, dimC = height, step = 1;        // moving-axis limit / fixed-axis limit / pixel stride
  I64 sA = of_task.scroll_x, sC = of_task.scroll_y, eA = of_dc.min_x, eAh = of_dc.max_x, eC = of_dc.min_y, eCh = of_dc.max_y, pA = of_task.pix_left, pAl = of_task.pix_right, pC = of_task.pix_top, pCl = of_task.pix_bottom, nA = of_dc.cur_x, nC = of_dc.cur_y;
  if (vert) { dimA = height; dimC = width; step = stride; sA = of_task.scroll_y; sC = of_task.scroll_x; eA = of_dc.min_y; eAh = of_dc.max_y; eC = of_dc.min_x; eCh = of_dc.max_x; pA = of_task.pix_top; pAl = of_task.pix_bottom; pC = of_task.pix_left; pCl = of_task.pix_right; nA = of_dc.cur_y; nC = of_dc.cur_x; }
  // ---- DC offset (flag bit 0xe) ----
  if ((flags >> 0xe) & 1) { x1 += *(mem + win + sA)(I64*); x2 += *(mem + win + sA)(I64*); y  += *(mem + win + sC)(I64*); z1 += *(mem + win + of_task.scroll_z)(I64*); z2 += *(mem + win + of_task.scroll_z)(I64*); }
  // ---- bbox update (flag bit 0x10) ----
  if ((flags >> 0x10) & 1) {
    if (x1 < *(mem + dc + eA)(I64*)) *(mem + dc + eA)(I64*) = x1; if (x1 > *(mem + dc + eAh)(I64*)) *(mem + dc + eAh)(I64*) = x1; if (x2 < *(mem + dc + eA)(I64*)) *(mem + dc + eA)(I64*) = x2; if (x2 > *(mem + dc + eAh)(I64*)) *(mem + dc + eAh)(I64*) = x2;
    if (y  < *(mem + dc + eC)(I64*)) *(mem + dc + eC)(I64*) = y; if (y  > *(mem + dc + eCh)(I64*)) *(mem + dc + eCh)(I64*) = y; }
  if (y < 0) return 0;
  if (x2 < x1) { i = x1; x1 = x2; x2 = i; i = z1; z1 = z2; z2 = i; }
  if (x2 < 0) return 0;
  if (x1 < 0) { clip_lo = -x1; x1 = 0; }
  // ---- win clip (flag bit 0xe) ----
  if ((flags >> 0xe) & 1) {
    x1 += *(mem + win + pA)(I64*); x2 += *(mem + win + pA)(I64*); if (x1 > *(mem + win + pAl)(I64*)) return 0;
    if (x2 > *(mem + win + pAl)(I64*)) { clip_hi = x2 - *(mem + win + pAl)(I64*); x2 = *(mem + win + pAl)(I64*); }
    y += *(mem + win + pC)(I64*); if (y < 0) return 0; if (y > *(mem + win + pCl)(I64*)) return 0; if (x2 < 0) return 0; }
  if (x1 >= dimA) return 0; if (y >= dimC) return 0;
  // ---- z-slope + accumulator (z interpolates z1..z2 over the ORIGINAL span; clip-adjusted start) ----
  I64 count = (x2 + clip_hi) - (x1 - clip_lo);
  if (vert) idx = x1 * stride + y; else idx = y * stride + x1;
  zptr = zbuf + idx * 4; if (count) zslope = ((z2 - z1) << 32) / count; zacc = z1 << 32; zacc += clip_lo * zslope; if (x2 >= dimA) x2 = dimA - 1;
  // ---- collision distance metric (flag bit 0xb): nearest squared dist from (cur) over the span ----
  if ((flags >> 0xb) & 1) {
    I64 cx = *(mem + dc + nA)(I32*), cy = *(mem + dc + nC)(I32*), r13, dx;
    if (cx >= x1 && cx <= x2) r13 = 0;
    else if (cx < x1) { dx = x1 - cx; r13 = dx * dx; }
    else { dx = cx - x2; r13 = dx * dx; }
    I64 dy = y - cy; r13 += dy * dy; if (r13 < *(mem + dc + of_dc.nearest_dist)(I64*)) *(mem + dc + of_dc.nearest_dist)(I64*) = r13; }
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
    if ((col_w >> 24) & 0x80) { dith_rand = 1; if (RasterRand(fsb) < *(mem + dc + of_dc.dither_probability_u16)(U64*)) cw = w2; }   // initial roll picks pixel 0's word
    else { if ((x1 ^ y) & 1) { i = w1; w1 = w2; w2 = i; } cw = w1; } }
  // ---- occlusion (char_clear): GrHLine recomputes IsPixCovered0 every 8 px and skips covered ones. covered =
  //   win->win_z_num(@+0x30c) < gr.win_z_buf[(y>>3)*80 + (x>>3)]. Only when screen-bitmap, not-on-top, not winmgr.
  I64 need_cov = ((flags >> 0xe) & 1) && !((flags >> 0x11) & 1) && win && *(mem + win + of_task.next_task)(U64*) != *(mem + guest.sys_winmgr_task)(U64*);
  U64 wzbuf = 0; I64 wzn = 0, cov_row = 0, covM = 1, cc = 1;   // cell = cov_row + (moving>>3)*covM: H walks columns, V walks rows (*80)
  if (vert) covM = 80;
  if (need_cov) { wzbuf = *(mem + guest.gr_win_z_buf)(U64*); if (wzbuf && wzbuf < mem_size) { wzn = *(mem + win + of_task.win_z_num)(U16*); if (vert) cov_row = y >> 3; else cov_row = (y >> 3) * 80; cc = wzn >= *(mem + wzbuf + (cov_row + (x1 >> 3) * covM) * 2)(U16*); } else need_cov = 0; }
  //Malformed drawing contexts fall back to guest code.
  if (idx < 0 || x2 < x1 || (x2 - x1 + 1) > 4096 || !body || body + idx + (x2 - x1 + 1) * step >= mem_size ||
      zbuf + (idx + (x2 - x1 + 1) * step) * 4 >= mem_size) return -1;
  // ---- per-pixel span (r14 draw-enable is always 1 in the handled case) ----
  for (i = x1; i <= x2; i++) {
    if (cc) { cur_z = zacc >> 32;                      // signed 32-bit current z (z-test+draw gated by char_clear)
      I64 draw = 1; if (cur_z < 0) draw = 0; else if (cur_z > *(mem + zptr)(I32*)) draw = 0; else *(mem + zptr)(I32*) = cur_z;
      if (draw) { color = cw & 0xFF; mode = (cw >> 8) & 0xFF;   // rop dispatch per the REAL jump table: 1=XOR, 2=COLLISION(count, no write), all others=WRITE
	if (mode == 1) mem[body + idx] ^= color; else if (mode == 2) { I64 v = mem[body + idx]; if (v != 0xFF && v != bg) (*(mem + dc + of_dc.collision_cnt)(U64*))++; } else mem[body + idx] = color; plotcnt++; } }
    if (dith_en) { if (dith_rand) { if (RasterRand(fsb) < (*(mem + dc + of_dc.dither_probability_u16)(U64*))) cw = w2; else cw = w1; } else { I64 t = w1; w1 = w2; w2 = t; cw = w1; } }
    if (need_cov && ((i + 1) & 7) == 0 && i + 1 <= x2) cc = wzn >= *(mem + wzbuf + (cov_row + ((i + 1) >> 3) * covM) * 2)(U16*);   // recompute char_clear at the next 8-px boundary
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
  body = *(mem + dc + of_dc.body)(U64*); zbuf = *(mem + dc + of_dc.depth_buf)(U64*);
  U32 flags=*(mem+dc+of_dc.flags)(U32*);
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
  if (*(mem + dc + of_dc.x)(I32*) || *(mem + dc + of_dc.y)(I32*) || *(mem + dc + of_dc.z)(I32*)) return 0;
  rmat = *(mem + dc + of_dc.r)(U64*); if (!rmat) return 0;
  for (i = 0; i < 16; i++) {
    if (i == 0 || i == 5 || i == 10 || i == 15) { if (*(mem + rmat + i * 8)(I64*) != 0x100000000) return 0; }
    else if (*(mem + rmat + i * 8)(I64*)) return 0;
  }
  ax = *(mem + poly)(I32*); ay = *(mem + poly + 4)(I32*); az = *(mem + poly + 8)(I32*);   // fan from poly[0]
  for (i=1;i<n-1;i++) {
    bx = *(mem + poly + i * S)(I32*);     by = *(mem + poly + i * S + 4)(I32*);     bz = *(mem + poly + i * S + 8)(I32*);
    cx = *(mem + poly + (i + 1) * S)(I32*); cy = *(mem + poly + (i + 1) * S + 4)(I32*); cz = *(mem + poly + (i + 1) * S + 8)(I32*);
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
  if (op == 0x8B) { DecodeModRM(); if (isMem) a=RdMem(ea,sz); else a=RdReg(rm,sz); WrReg(rg,sz,a); return; }                        // MOV r, r/m
  if (op == 0x88) { DecodeModRM(); if (isMem) WrMem(ea, 1, RdReg(rg, 1)); else WrReg(rm, 1, RdReg(rg, 1)); return; }      // MOV r/m8, r8
  if (op == 0x8A) { DecodeModRM(); if (isMem) a=RdMem(ea,1); else a=RdReg(rm,1); WrReg(rg,1,a); return; }                          // MOV r8, r/m8

  switch (op) {
    case 0x90: break;
    case 0xF4: halted = 1; break;
    case 0xD8: case 0xD9: case 0xDA: case 0xDB:                     // x87 FPU escapes
    case 0xDC: case 0xDD: case 0xDE: case 0xDF:
      b=mem[rip];
      if (!OpX87(op)) {
	g_badop=op<<8|b;halted=2;
	"BADOPX87 op=%X rip=%X\n",g_badop,rip;
      }
      break;
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

    case 0x86: DecodeModRM();                                                                       // XCHG r/m8, r8 (mem form is implicitly LOCKed)
               if (isMem && ea < mem_size) imm = AtomXchg(ea, RdReg(rg, 1), 1);
               else { imm = RdRM(1); WrRM(1, RdReg(rg, 1)); } WrReg(rg, 1, imm); break;
    case 0x87: DecodeModRM();                                                                       // XCHG r/m, r (mem form is implicitly LOCKed)
               if (isMem && ea < mem_size && !(ea & (sz - 1))) imm = AtomXchg(ea, RdReg(rg, sz), sz);
               else { imm = RdRM(sz); WrRM(sz, RdReg(rg, sz)); } WrReg(rg, sz, imm); break;
    case 0x8E: DecodeModRM(); g_seg[rg & 7] = RdRM(2); break;     // MOV Sreg, r/m16 - selector stored, ignored (flat)
    case 0x8C: DecodeModRM(); WrRM(2, g_seg[rg & 7]); break;      // MOV r/m16, Sreg
    case 0xC6: DecodeModRM(1); WrRM(1, Fetch8()); break;          // MOV r/m8, imm8
    case 0xC7: d=4; if (sz==2) d=2; DecodeModRM(d); imm = FetchImm(sz); WrRM(sz, imm); break;  // MOV r/m, imm (imm16 w/ 0x66, else imm32)
    case 0x8D: DecodeModRM(); WrReg(rg, sz, ea); break;          // LEA
    case 0x63: DecodeModRM(); WrReg(rg, sz, SignExtTo64(RdRM(4), 4)); break;     // MOVSXD r64, r/m32
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
    case 0xF6: d=0; if (mem[rip]>>3&7<=1) d=1; DecodeModRM(d); Grp3(1);  break;
    case 0xF7: d=0; if (mem[rip]>>3&7<=1) {d=4; if (sz==2) d=2;} DecodeModRM(d); Grp3(sz); break;

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
    case 0x6D: d=4; if (sz==2) d=2; DoIns(d); break;     // INSW/INSD (ATA PIO sector reads land here)
    case 0x6E: DoOuts(1); break;                  // OUTSB DX <- [RSI]
    case 0x6F: d=4; if (sz==2) d=2; DoOuts(d); break;    // OUTSW/OUTSD
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
            PicPending) {
        halted=0;
        CheckIrq;
      }
    } else
      Step;
    icount++;
    TimeRun(1);
    if (rfl&F_IF &&
          PicPending)
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

U64 CpuFault(I64 which=0)
{//First stopped CPU: packed core/reason or its instruction pointer.
  I64 i;
  for (i=0;i<g_ncore;i++)
    if (g_cpu_st[i].f_halted>=2) {
      if (which) return g_cpu_st[i].f_rip;
      return i<<8|g_cpu_st[i].f_halted;
    }
  return 0;
}

I64 RunCore(I64 budget)
{//AP instruction budget without core zero's device ticks.
//A fault remains stopped until the machine is restored or restarted.
  I64 start=icount,lim=icount+budget,ip,b;
  while (icount<lim) {
    if (halted>=2)
      return -halted;
    //Atomic load: it acquires the sender's writes before the handler runs.
    ip=__a_or64(&g_ipi_pending[MyCore],0);
    if (ip && rfl&F_IF) {
      __a_and64(&g_ipi_pending[MyCore],0);
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
    pending=PicPending;
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
  I64 i; DevRst; for (i = 0; i < 16; i++) reg[i] = 0; rip = 0; rfl = 0; halted = 0; icount = 0; g_badop = 0; reg[4] = 0x100000; cr0 = 0; cr2 = 0; cr3 = 0; cr4 = 0; cr8 = 0; g_cs = 0x08; g_ss = 0x10; idtr_base = 0; idtr_limit = 0; gdtr_base = 0; gdtr_limit = 0; tsc = 0;
  for (i = 0; i < 16; i++) { xmm_lo[i] = 0; xmm_hi[i] = 0; }
}
U0 Load(U8 *p, I64 n, U64 at) { I64 i; for (i = 0; i < n; i++) mem[at + i] = p[i]; rip = at; }
