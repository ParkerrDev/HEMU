U64 ata_words,ata_seccnt,ata_pos,ata_r3,ata_r4,ata_r5,
      ata_wr,ata_wlba,ata_wcnt;
U8 *ata_buf;
I64 pic1_base,pic1_mask,pic1_irr,pic1_isr,pic1_initstep,
      pic2_base,pic2_mask,pic2_irr,pic2_isr,pic2_initstep,irq_count;
extern U0 KbdTick();
#include "time"
#include "keyboard"

I64 rtc_idx,ms_byte0,ms_byte1,ms_byte2,ms_has,ms_phase,
      ps2q[16],ps2q_ms[16],ps2qh,ps2qt,ms_next,cfg_next,
      pit2_reload,pit2_div,pit2_wlo,spk_on;
U8 vga_dac[768];
I64 vga_read_pos,vga_write_pos;

U0 Ps2Resp(I64 b,I64 is_ms)
{//TempleOS polls command replies during keyboard and mouse installation.
  ps2q[ps2qt&15]=b;
  ps2q_ms[ps2qt&15]=is_ms;
  ps2qt++;
}

U0 UpdateSpk()
{//PIT channel 2 drives the speaker while both port 0x61 gates are set.
  if (spk_on && pit2_div)
    __snd(1193182.0/pit2_div);
  else
    __snd(0.0);
}

U0 VgaPaletteSend(I64 i)
{//All hosts receive eight-bit RGB on DAC writes and saved-machine resume.
  I64 r=vga_dac[i*3]*255/63,g=vga_dac[i*3+1]*255/63,
	b=vga_dac[i*3+2]*255/63;
  __host_palette(i,r*0x10000+g*0x100+b);
}

U0 VgaPaletteInit()
{
  I64 i,r,g,b,bright;
  for (i=0;i<16;i++) {
    bright=i&8!=0;
    r=(i&4!=0)*42+bright*21;
    g=(i&2!=0)*42+bright*21;
    b=(i&1!=0)*42+bright*21;
    if (i==6) g=21;
    vga_dac[i*3]=r;
    vga_dac[i*3+1]=g;
    vga_dac[i*3+2]=b;
    VgaPaletteSend(i);
  }
  vga_read_pos=vga_write_pos=0;
}

U0 DevInit()
{//The ATA PIO staging buffer belongs to the device, not guest RAM.
  ata_buf=MAlloc(256*512);
}

U0 DevRst()
{//A machine reset abandons incomplete transfers and pending replies.
  TimeRst;
  KbdRst;
  ata_words=ata_seccnt=ata_pos=ata_r3=ata_r4=ata_r5=0;
  ata_wr=ata_wlba=ata_wcnt=0;
  pic1_base=pic1_irr=pic1_isr=pic1_initstep=0;
  pic2_base=pic2_irr=pic2_isr=pic2_initstep=0;
  pic1_mask=pic2_mask=0xFF;
  irq_count=rtc_idx=0;
  ms_byte0=ms_byte1=ms_byte2=ms_has=ms_phase=0;
  ps2qh=ps2qt=ms_next=cfg_next=0;
  pit2_reload=pit2_div=spk_on=0;
  pit2_wlo=TRUE;
  MemSet(vga_dac,0,sizeof(vga_dac));
  VgaPaletteInit;
  UpdateSpk;
}

Bool PicPending()
{
  return pic1_irr&~pic1_mask || pic2_irr&~pic2_mask;
}

I64 PicNext()
{//Claim one vector; the CPU owns delivery through its IDT.
  I64 irq,b=pic1_irr&~pic1_mask;
  for (irq=0;irq<8;irq++)
    if (b&1<<irq) {
      if (irq==2) break;
      pic1_irr&=~(1<<irq);
      pic1_isr|=1<<irq;
      irq_count++;
      return pic1_base+irq;
    }
  b=pic2_irr&~pic2_mask;
  for (irq=0;irq<8;irq++)
    if (b&1<<irq) {
      pic2_irr&=~(1<<irq);
      pic2_isr|=1<<irq;
      irq_count++;
      return pic2_base+irq;
    }
  return -1;
}

U64 RtcRead(I64 idx)
{//CMOS is binary, 24-hour time supplied by the host.
  if (idx==0x0A) return 0;
  if (idx==0x0B) return 0x06;
  return __host_time(idx);
}

U64 IoIn(U64 port)
{
  I64 b,st=0x1C,next_ms=FALSE;
  U64 value;
  if (port==0x3C9) {
    value=vga_dac[vga_read_pos];
    vga_read_pos=(vga_read_pos+1)%768;
    return value;
  }
  if (port==0x3C8) return vga_write_pos/3;
  if (port==0x3C6) return 255;
  if (port==0x21) return pic1_mask;
  if (port==0xA1) return pic2_mask;
  if (port==0x40) return PitRead;
  if (port==0x71) return RtcRead(rtc_idx);
  if (port==0x60) {
    if (ps2qh!=ps2qt) {
      b=ps2q[ps2qh&15];
      ps2qh++;
      return b;
    }
    if (ms_has) {
      if (!ms_phase) b=ms_byte0;
      else if (ms_phase==1) b=ms_byte1;
      else b=ms_byte2;
      if (++ms_phase>=3) {
	ms_has=FALSE;
	ms_phase=0;
      } else
	pic2_irr|=0x10; //TempleOS reads one mouse byte per IRQ12.
      return b;
    }
    if (kbd_qh!=kbd_qt) {
      b=kbd_q[kbd_qh&63];
      kbd_qh++;
      if (kbd_qh!=kbd_qt) pic1_irr|=2;
      return b;
    }
    return 0;
  }
  if (port==0x64) {
    if (ps2qh!=ps2qt) {
      st|=1;
      if (ps2q_ms[ps2qh&15]) next_ms=TRUE;
    } else if (ms_has) {
      st|=1;
      next_ms=TRUE;
    } else if (kbd_qh!=kbd_qt)
      st|=1;
    if (next_ms) st|=0x20;
    return st;
  }
  if (port==0x1F7 || port==0x177) {
    if (ata_words) return 0x48;
    return 0x40;
  }
  if (port==0x1F0 || port==0x170) {
    if (ata_words) {
      value=*(ata_buf+ata_pos)(U16 *);
      ata_pos+=2;
      ata_words--;
      return value;
    }
    return 0;
  }
  return 0;
}

U0 IoOut(U64 port,U64 v)
{
  I64 i;
  U64 lba,cnt;
  if (port==0x3C7) {
    vga_read_pos=(v&255)*3;
    return;
  }
  if (port==0x3C8) {
    vga_write_pos=(v&255)*3;
    return;
  }
  if (port==0x3C9) {
    i=vga_write_pos/3;
    vga_dac[vga_write_pos]=v&63;
    vga_write_pos=(vga_write_pos+1)%768;
    if (!(vga_write_pos%3) && i<16) VgaPaletteSend(i);
    return;
  }
  if (0x3B0<=port<=0x3DF) return; //Planar framebuffer writes use video.HC.
  if (port==0x1F0 || port==0x170) {
    if (ata_wr && ata_words) {
      *(ata_buf+ata_pos)(U16 *)=v;
      ata_pos+=2;
      if (!--ata_words) {
	__host_disk_wr(ata_wlba,ata_wcnt,ata_buf);
	ata_wr=0;
      }
    }
    return;
  }
  v&=0xFF;
  if (port==0x1F2 || port==0x172) {
    ata_seccnt=(ata_seccnt<<8|v)&0xFFFF;
    return;
  }
  if (port==0x1F3 || port==0x173) {
    ata_r3=(ata_r3<<8|v)&0xFFFF;
    return;
  }
  if (port==0x1F4 || port==0x174) {
    ata_r4=(ata_r4<<8|v)&0xFFFF;
    return;
  }
  if (port==0x1F5 || port==0x175) {
    ata_r5=(ata_r5<<8|v)&0xFFFF;
    return;
  }
  if (port==0x1F7 || port==0x177) {
    lba=ata_r3&0xFF|(ata_r4&0xFF)<<8|(ata_r5&0xFF)<<16|
	  (ata_r3>>8&0xFF)<<24|(ata_r4>>8&0xFF)<<32|
	  (ata_r5>>8&0xFF)<<40;
    cnt=ata_seccnt&0xFFFF;
    if (!cnt || cnt>256) cnt=256;
    if (v==0x20 || v==0x21 || v==0x24 || v==0x29 || v==0xC4) {
      __host_disk(lba,cnt,ata_buf);
      ata_words=cnt*256;
      ata_pos=ata_wr=0;
    } else if (v==0x30 || v==0x34 || v==0x39 || v==0xC5) {
      ata_words=cnt*256;
      ata_pos=0;
      ata_wr=TRUE;
      ata_wlba=lba;
      ata_wcnt=cnt;
    } else
      ata_words=ata_wr=0;
    ata_r3=ata_r4=ata_r5=ata_seccnt=0;
    return;
  }
  if (port==0x64) {
    if (v==0xD4) ms_next=TRUE;
    else if (v==0x20) Ps2Resp(0x47,FALSE);
    else if (v==0x60) cfg_next=TRUE;
    else if (v==0xA9 || v==0xAB) Ps2Resp(0,FALSE);
    else if (v==0xAA) Ps2Resp(0x55,FALSE);
    return;
  }
  if (port==0x60) {
    if (cfg_next) {
      cfg_next=FALSE;
      return;
    }
    if (ms_next) {
      ms_next=FALSE;
      Ps2Resp(0xFA,TRUE);
      if (v==0xFF) {
	Ps2Resp(0xAA,TRUE);
	Ps2Resp(0,TRUE);
      } else if (v==0xF2)
	Ps2Resp(0,TRUE);
      return;
    }
    Ps2Resp(0xFA,FALSE);
    if (kbd_cmd) {
      if (kbd_cmd==0xF3) {
	kbd_type=v&0x7F;
	kbd_repeat_ns=tsc+KbdDelay;
      }
      kbd_cmd=0;
    } else if (v==0xF3 || v==0xED)
      kbd_cmd=v;
    else if (v==0xFF) {
      kbd_repeat_key=0;
      kbd_type=0x2B;
      Ps2Resp(0xAA,FALSE);
    }
    return;
  }
  if (port==0x70) {
    rtc_idx=v&0x7F;
    return;
  }
  if (port==0x43) {
    if (v&0xC0==0x80) pit2_wlo=TRUE;
    else if (!(v&0xC0)) PitCmd(v);
    return;
  }
  if (port==0x42) {
    if (pit2_wlo) {
      pit2_reload=v;
      pit2_wlo=FALSE;
    } else {
      pit2_reload|=v<<8;
      pit2_div=pit2_reload;
      pit2_wlo=TRUE;
      UpdateSpk;
    }
    return;
  }
  if (port==0x61) {
    spk_on=v&3==3;
    UpdateSpk;
    return;
  }
  if (port==0x20) {
    if (v&0x10) pic1_initstep=1;
    else if (v==0x20)
      for (i=0;i<8;i++)
	if (pic1_isr&1<<i) {
	  pic1_isr&=~(1<<i);
	  break;
	}
  } else if (port==0x21) {
    if (pic1_initstep==1) {
      pic1_base=v;
      pic1_initstep=2;
    } else if (pic1_initstep==2) pic1_initstep=3;
    else if (pic1_initstep==3) pic1_initstep=0;
    else pic1_mask=v;
  } else if (port==0xA0) {
    if (v&0x10) pic2_initstep=1;
    else if (v==0x20)
      for (i=0;i<8;i++)
	if (pic2_isr&1<<i) {
	  pic2_isr&=~(1<<i);
	  break;
	}
  } else if (port==0xA1) {
    if (pic2_initstep==1) {
      pic2_base=v;
      pic2_initstep=2;
    } else if (pic2_initstep==2) pic2_initstep=3;
    else if (pic2_initstep==3) pic2_initstep=0;
    else pic2_mask=v;
  } else if (port==0x40) {
    if (pit_wlo) {
      pit_reload=v;
      pit_wlo=FALSE;
    } else {
      pit_reload|=v<<8;
      pit_div=pit_reload;
      if (!pit_div) pit_div=65536;
      pit_counter=pit_div;
      pit_wlo=TRUE;
    }
  }
}

U64 IoInWidth(U64 port,I64 width)
{//ATA dword I/O transfers two words, including V5.03's REP INSD.
  U64 value=IoIn(port);
  if ((port==0x1F0 || port==0x170) && width==4)
    value|=IoIn(port)<<16;
  return value;
}

U0 IoOutWidth(U64 port,U64 value,I64 width)
{
  IoOut(port,value);
  if ((port==0x1F0 || port==0x170) && width==4)
    IoOut(port,value>>16);
}
