//============================================================================
// GuestCall.HC: host-injected guest calls, the backend execution primitive.
//
// The host (guestexec.js) asks hemu to call ONE validated guest function with up to 8 stack args,
// exactly the way a hardware interrupt would enter a handler: at an instruction boundary with IF=1
// (so the guest is not inside a CLI critical section), a frame is pushed on the CURRENT task's
// stack, the callee runs with IF=0 (atomic w.r.t. the scheduler, like an ISR), and when it RETs to
// the sentinel address the interrupted CPU state is restored bit-exactly (all GPRs, rip, rflags,
// x87, XMM, decode scratch, halted). The callee's side effects on guest memory persist; nothing
// else does. This is the same discipline TempleOS uses for IRQ1: KbdMsgsQue calls TaskMsg (a
// JobQue wrapper) from interrupt context, so the JobQue family (TaskExe, JobResScan, PopUp) is
// safe by construction here. No scancodes, no MSG_KEY_DOWN injection, no typed bootstrap.
//
// Safe points: GuestCallPost tries immediately (host calls it between __main frames); if the guest
// is in a CLI section right then, the call stays PENDING and Run() takes it at the first IF=1
// point of the next frame (the same spot where it would deliver an IRQ), including while HLT idle.
//
// Only core 0 injects (MyCore==0); APs never run this code. A callee that faults or exceeds the
// budget is reported as FAILED and the interrupted state is still restored (its frame below RSP is
// dead space by the x86 convention, so abandoning it is harmless).
//============================================================================
// GC_* state/error codes are #defined in Core.HC (Cpu.HC's Run() tests GC_PENDING too).
U64 g_gc_fn, g_gc_args[8], g_gc_sentinel, g_gc_res;
I64 g_gc_argc, g_gc_state, g_gc_err, g_gc_budget, g_gc_steps, g_gc_calls, g_gc_savlock, g_gc_savbad;
CCpuState g_gc_save;	//The interrupted core's state, put back after the call.
U64 g_gc_xmm_lo[16],g_gc_xmm_hi[16];

U0 GuestCallRun()		     // precondition: state PENDING, (rfl & F_IF), halted <= 1, core 0
{
  I64 i;
  MemCpy(&g_gc_save,&g_cpu_st[MyCore],sizeof(CCpuState));
  MemCpy(g_gc_xmm_lo,xmm_lo,sizeof(g_gc_xmm_lo));
  MemCpy(g_gc_xmm_hi,xmm_hi,sizeof(g_gc_xmm_hi));
  g_gc_savlock = lockf; g_gc_savbad = g_badop;
  g_gc_state = GC_RUNNING; g_gc_steps = 0;
  for (i = g_gc_argc - 1; i >= 0; i--) { reg[4] -= 8; WrMem(reg[4], 8, g_gc_args[i]); }   // HolyC: args pushed right to left, callee pops
  reg[4] -= 8; WrMem(reg[4], 8, g_gc_sentinel); 					   // return address = sentinel (HLT byte in scratch)
  rip = g_gc_fn; rfl &= ~F_IF; halted = 0;
  while (rip != g_gc_sentinel && g_gc_steps < g_gc_budget && halted == 0) { Step(); g_gc_steps++; }
  if (rip == g_gc_sentinel) { g_gc_res = reg[0]; g_gc_err = 0; g_gc_state = GC_DONE; }
  else { g_gc_res = 0; if (halted) g_gc_err = GC_ERR_FAULT; else g_gc_err = GC_ERR_BUDGET; g_gc_state = GC_FAILED; }
  MemCpy(&g_cpu_st[MyCore],&g_gc_save,sizeof(CCpuState));
  MemCpy(xmm_lo,g_gc_xmm_lo,sizeof(g_gc_xmm_lo));
  MemCpy(xmm_hi,g_gc_xmm_hi,sizeof(g_gc_xmm_hi));
  lockf = g_gc_savlock; g_badop = g_gc_savbad;
  icount+=g_gc_steps;
  TimeRun(g_gc_steps);
  g_gc_calls++;
}

I64 GuestCallTry()		     // run the pending call now if this is a safe point; returns the state
{
  if (g_gc_state != GC_PENDING || MyCore) return g_gc_state;
  if (halted >= 2 || !(rfl & F_IF)) return g_gc_state;
  GuestCallRun();
  return g_gc_state;
}

// Host entry: queue a call to guest function fn with argc args read from guest address argaddr
// (8 bytes each, in the scratch window). Returns the resulting state (DONE/FAILED if it ran at once,
// PENDING if deferred to the next safe point), -1 if a call is already in flight, -2 on bad args.
I64 GuestCallPost(U64 fn, I64 argc, U64 argaddr, I64 budget)
{
  I64 i;
  if (g_gc_state == GC_PENDING || g_gc_state == GC_RUNNING) return -1;
  if (!fn || fn >= mem_size || argc < 0 || argc > 8 || argaddr + argc * 8 > mem_size) return -2;
  for (i = 0; i < argc; i++) g_gc_args[i] = RdMem(argaddr + i * 8, 8);
  g_gc_fn = fn; g_gc_argc = argc; g_gc_budget = budget; if (g_gc_budget < 1000) g_gc_budget = 1000;
  g_gc_res = 0; g_gc_err = 0; g_gc_state = GC_PENDING;
  return GuestCallTry();
}
I64 GuestCallState() { return g_gc_state; }
U64 GuestCallRes()   { return g_gc_res; }
I64 GuestCallAck()   { if (g_gc_state == GC_DONE || g_gc_state == GC_FAILED) g_gc_state = GC_IDLE; return g_gc_state; }   // host consumed the result
U64 GuestInfo(I64 which)	     // read-only probes for the host (no globals map needed for a prebuilt .wasm)
{
  switch (which) {
    case 0:  return mem_size;
    case 1:  return RAM_SIZE;	     // scratch window base = first byte above the OS's RAM
    case 2:  return SCR_SIZE;
    case 3:  return msr_fsbase;      // Fs = current task
    case 4:  return msr_gsbase;      // Gs = CCPU
    case 5:  return rip;
    case 6:  return rfl;
    case 7:  return halted;
    case 8:  return icount;
    case 9:  return 0; //Reserved: removed the popup-size game guess.
    case 10: return g_gc_sentinel;
    case 11: return g_gc_err;
    case 12: return g_gc_steps;
    case 13: return g_gc_calls;
    case 14: return g_jit_on;
    case 15: return g_ncore;
    case 16: return GuestU64(guest.jiffies);
  }
  return 0;
}

I64 GuestPatchJump(U64 addr,U64 target)
{//Keep PUSH RBP/MOV RBP,RSP intact for suspended task entry contexts.
//The host holds the all-core barrier; replace one 7-byte SUB RSP only.
  I64 i;
  if (!addr || addr+11>RAM_SIZE || addr+11>mem_size || !target ||
	target+11>RAM_SIZE || target+11>mem_size ||
	GuestU32(addr)!=0xEC8B4855 || GuestU32(target)!=0xEC8B4855 ||
	GuestU32(addr+4)&0xFFFFFF!=0xEC8148 ||
	GuestU32(target+4)&0xFFFFFF!=0xEC8148)
    return -1;
  for (i=0;i<MaxI64(g_ncore,1);i++)
    if (addr+4<=g_cpu_st[i].f_rip<addr+11) return 0;
  mem[addr+4]=0xE9;
  WrMem(addr+5,4,target-addr-5);
  return 1;
}
