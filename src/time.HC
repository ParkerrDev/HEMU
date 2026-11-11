//The guest's clocks. A frame's time, the host's time since the last frame,
//is spread over the instructions the frame runs, so the guest's time keeps
//to the host's at any speed. The PIT counts at its crystal's rate from the
//reload the guest programmed, the HPET at the rate the guest found at boot
//(cnts.HPET_freq) and the TSC in nanoseconds.

#define NS_SEC		1000000000
#define PIT_FREQ	1193182 //The PIT's crystal, in Hz.

U64 tsc,hpet_ctr;
I64 hpet_freq,hpet_frac,
      pit_reload,pit_div,pit_counter,pit_frac,pit_wlo,pit_rlo,pit_latch,
      pit_latched;
I64 time_frame_ns,time_frame_i, //The frame's time, over its instructions.
      time_i,time_ns,	//How many of those ran, and the time they got.
      time_idle;	//How many of them the CPU spent in HLT.

U64 TscRead()
{//All cores read one clock. Reading it does not change time.
  return tsc;
}

U0 TimeRst()
{//Reset devices before loading a machine's saved clocks and registers.
  tsc=0;
  hpet_ctr=0;
  hpet_freq=100000000;
  hpet_frac=0;
  pit_reload=0;
  pit_div=0;
  pit_counter=0;
  pit_frac=0;
  pit_wlo=TRUE;
  pit_rlo=TRUE;
  pit_latch=0;
  pit_latched=FALSE;
  time_frame_ns=0;
  time_frame_i=0;
  time_i=0;
  time_ns=0;
  time_idle=0;
}

U0 TimeAdd(I64 ns)
{//ns nanoseconds pass for the TSC, the HPET and the PIT.
  I64 n;
  tsc+=ns;
  hpet_frac+=ns*hpet_freq;
  hpet_ctr+=hpet_frac/NS_SEC;
  hpet_frac%=NS_SEC;
  if (pit_div) {
    pit_frac+=ns*PIT_FREQ;
    n=pit_frac/NS_SEC;
    pit_frac-=n*NS_SEC;
    pit_counter-=n;
    if (pit_counter<=0) {
      pit_counter=pit_counter%pit_div+pit_div;
      pic1_irr|=1;
    }
  }
}

U0 TimeFrame(I64 ns,I64 n)
{//A frame of ns nanoseconds and n instructions starts.
  time_frame_ns=ns;
  time_frame_i=n;
  time_i=0;
  time_ns=0;
  time_idle=0;
}

U0 TimeRun(I64 n)
{//n more of the frame's instructions ran: they get their share of its
//time. Past the frame's count, the frame's time is all used.
  I64 ns=time_frame_ns;
  time_i+=n;
  if (time_frame_i>0 && time_i<time_frame_i)
    ns=time_frame_ns*time_i/time_frame_i;
  if (ns>time_ns) {
    TimeAdd(ns-time_ns);
    time_ns=ns;
  }
}

I64 TimeTickWait()
{//Instructions until the PIT raises IRQ0, at least one. The rest of the
//frame if IRQ0 comes later, I64_MAX if no more time passes in it.
  I64 ns;
  if (!pit_div || !time_frame_ns || time_i>=time_frame_i)
    return I64_MAX;
  ns=time_ns+(pit_counter*NS_SEC-pit_frac+PIT_FREQ-1)/PIT_FREQ;
  if (ns>=time_frame_ns)
    return time_frame_i-time_i;
  return MaxI64((ns*time_frame_i+time_frame_ns-1)/time_frame_ns-time_i,1);
}

U0 PitCmd(I64 v)
{//OUT 0x43 for channel 0: 0 in bits 4 and 5 latches its count, else the
//next two writes to port 0x40 are the reload, low byte first.
  if (v&0x30)
    pit_wlo=TRUE;
  else {
    pit_latch=pit_counter;
    pit_latched=TRUE;
    pit_rlo=TRUE;
  }
}

U64 PitRead()
{//IN 0x40: the latched count, else the count, low byte first.
  I64 c=pit_counter;
  if (pit_latched)
    c=pit_latch;
  if (pit_rlo) {
    pit_rlo=FALSE;
    return c&0xFF;
  }
  pit_rlo=TRUE;
  pit_latched=FALSE;
  return c>>8&0xFF;
}
