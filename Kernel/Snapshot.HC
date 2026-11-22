#include "Cpu"
#ifdef SMP_SNAP
#include "SnapRegsSmp"
#else
#include "SnapRegs"
#endif

Bool g_names_ok;
U64 g_inited,g_budget,g_clock_line;

U0 Present()
{//Startup never exposes an incomplete draw buffer.
  if (g_clock_line) {
    if (!g_desk_ready || !mem[g_clock_line]) return;
    g_clock_line=0;
    g_present_seq=g_desk_seq; //The completed buffer can precede WallPaper.
  }
  if (g_desk_ready && g_desk_seq!=g_present_seq) {
    __present(g_desk,640,480);
    g_present_seq=g_desk_seq;
  }
}

U0 Frame()
{
  I64 mx=__host_msx,my=__host_msy,mz=__host_wheel,mb=__host_msb,sc,
	ns=__host_ns,budget=__host_budget;
  mx=ClampI64(mx,0,639);
  my=ClampI64(my,0,479);
  if (g_names_ok) {//WinQueIPMsgs detects mouse movement by comparing presnap.
    *(mem+guest.ms_pos+of_d3.x)(I64 *)=mx;
    *(mem+guest.ms_pos+of_d3.y)(I64 *)=my;
    *(mem+guest.ms_pos+of_d3.z)(I64 *)=mz;
    *(mem+guest.ms_presnap+of_d3.x)(I64 *)=mx;
    *(mem+guest.ms_presnap+of_d3.y)(I64 *)=my;
    *(mem+guest.ms_presnap+of_d3.z)(I64 *)=mz;
    *(mem+guest.ms_pos_text+of_d3.x)(I64 *)=mx/8;
    *(mem+guest.ms_pos_text+of_d3.y)(I64 *)=my/8;
    mem[guest.ms_lb]=mb&1;
    mem[guest.ms_rb]=mb>>1&1;
    mem[guest.ms_hard_installed]=1;
  }
  //IRQ1 owns the consumer. Excess events stay queued in the host.
  while (kbd_qt-kbd_qh<64) {
    sc=__host_key;
    if (sc<0)
      break;
    InjectKey(sc);
  }
  ns=ClampI64(ns,0,100000000);
  budget=MaxI64(budget,1);
  TimeFrame(ns,budget);
  g_budget=icount+budget;
  Run(g_budget);
  Present;
}

U0 CaptureInit()
{//Observe GrUpdateScrn after its VGA/text update returns. These addresses
//do not replace instructions; Step executes the instruction after capture.
  g_capture_rip=GuestCallRet(GuestFun("GrUpdateScrn"),
	GuestFun("GrUpdateVGAGraphics"),1024);
  g_capture_text=GuestCallRet(GuestFun("GrUpdateScrn"),
	GuestFun("GrUpdateTextModeText"),1024);
  if (g_capture_rip)
    g_capture_gate[g_capture_rip&0xFFFF]=1;
  if (g_capture_text)
    g_capture_gate[g_capture_text&0xFFFF]=1;
  video_image=GuestVarMember("gr","CGrGlbls","scrn_image");
}

#include "Display"

U0 HemuInit()
{
  F64 resume_tS;
  I64 resume_ns,resume_ticks,wall_line;
  U64 wall;
  InitMem(RAM_SIZE+SCR_SIZE);
  __snap_load(mem);
  g_gc_sentinel=RAM_SIZE+SCR_SIZE-16;
  mem[g_gc_sentinel]=0xF4;
  DevRst;
  SetSnapRegs;
  if (g_names_ok=GuestNamesFind(g_cpu_st[0].f_msr_fsbase)) {
    hpet_freq=GuestU64(GuestVarMember("cnts","CCntsGlbls","HPET_freq"));
    //RAM-only captures omit device registers. Resume their display epoch
    //so outstanding tS deadlines remain meaningful.
    resume_tS=*(mem+guest.winmgr_last_refresh_tS)(F64 *);
    resume_ns=resume_tS*NS_SEC;
    resume_ticks=resume_tS*hpet_freq;
    tsc=resume_ns;
    hpet_ctr=GuestU64(GuestVarMember("cnts","CCntsGlbls","HPET_initial"))+
	  resume_ticks;
    wall=GuestU64(GuestVar("wall"));
    wall_line=GuestMember("CWallPaperGlbls","top_line");
    if (wall && wall_line>=0 && wall+wall_line<RAM_SIZE) {
      g_clock_line=wall+wall_line;
      mem[g_clock_line]=0; //Wait for a fresh WallPaper clock before display.
    }
    CaptureInit;
    RenderInit;
  } else
    "HEMU: this guest lacks a name HEMU needs; emulating only.\n";
  g_jit_on=CoreAttach;
  g_inited=1;
}

U0 SnapshotResume()
{//A full machine image already has its CPU and devices.
  I64 i;
  MemSet(g_jit_rip,0,sizeof(g_jit_rip));
  MemSet(g_jit_n,0,sizeof(g_jit_n));
  MemSet(g_jit_hot,0,sizeof(g_jit_hot));
  g_jit_on=CoreAttach;
  for (i=0;i<16;i++)
    VgaPaletteSend(i);
  UpdateSpk;
  g_present_seq=g_desk_seq-1;
  Present;
}

U0 Main()
{
  if (!g_inited)
    HemuInit;
  Frame;
}

Main;
