//HEMU on an x86-64 Linux: the processor runs TempleOS itself, through KVM,
//from the capture beside this program (RAM.BIN, Regs.TXT, Disk.BIN). Linux
//has the PIC, the PIT and the APICs. This file is the rest of the PC that
//TempleOS uses, in a Wayland window. See make_hemu.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <poll.h>
#include <pthread.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/eventfd.h>
#include <sys/un.h>
#include <linux/kvm.h>
#include <alsa/asoundlib.h>

typedef void U0;
typedef unsigned char U8;
typedef unsigned short U16;
typedef unsigned int U32;
typedef int I32;
typedef unsigned long U64;
typedef long I64;
typedef double F64;
typedef bool Bool;

#define TRUE		1
#define FALSE		0
#define NS_SEC		1000000000
#define SCRN_W		640
#define SCRN_H		480
#define PLANE_SIZE	(SCRN_W*SCRN_H/8)
#define BLK_SIZE	512
#define CORES_NUM	16
#define PIT_FREQ	1193182 //Hz
#define SND_RATE	48000 //Hz
#define SND_VOL		24

//V5.03's records (Kernel/KernelA.HH): CTask.hash_table, CHashTable.mask
//and body, CHash.str and type, CHashGlblVar.data_addr,
//CHashClass.member_lst_and_root, CMemberLst.str and offset.
#define HTT_GLBL_VAR	8
#define HTT_CLASS	0x10
#define TASK_HASH_TABLE	976
#define TBL_MASK	8
#define TBL_BODY	24
#define HASH_STR	8
#define HASH_TYPE	16
#define VAR_DATA_ADDR	120
#define CLASS_MEMBERS	88
#define ML_STR		40
#define ML_OFFSET	80

char **args;
U8 *mem,*dsk; //The guest's RAM and its disk C.
I64 mem_size,dsk_size;
I32 kvm,vm,core_fd[CORES_NUM];
struct kvm_run *core_run[CORES_NUM];
pthread_mutex_t dev_lock=PTHREAD_MUTEX_INITIALIZER;

U64 hash_tbl, //The captured task's table. Its chain ends at Adam's.
	ms_pos,ms_pos_text,ms_lb,ms_rb,gr_dc1,gr_zoomed_dc,gr_scrn_zoom;
I64 dc_body,hpet0,hpet_freq,ns0;

I32 wl,scrn_evt; //The compositor's socket. A finished frame wakes scrn_evt.
U32 wl_id=2, //The next object's id. The display is 1.
	wl_reg,wl_cb,wl_comp,wl_shm,wl_seat,wl_base,wl_view,wl_frac,
	wl_surf,wl_xsurf,wl_top,wl_port,wl_scale,wl_ptr,wl_kbd,wl_pool,wl_buf,
	*buf,pal[16];
I64 win_w=SCRN_W,win_h=SCRN_H,win_scale=120, //The compositor's units.
	buf_w,buf_h,zoom,off_x,off_y,ms_z;
U64 scrn[SCRN_W*SCRN_H/8],spread[256]; //The last frame, a color a byte.

U8 kbd_q[64],vga_dac[768],*ata_ptr,
	//evdev's keys 96 to 111, each sent after 0xE0.
	kbd_ext[16]={0x1C,0x1D,0x35,0x37,0x38,0,0x47,0x48,
	0x49,0x4B,0x4D,0x4F,0x50,0x51,0x52,0x53};
U16 ata_reg[8];
U64 kbd_down[2]; //A bit a key that is held.
I64 kbd_head,kbd_tail,kbd_cmd,kbd_type,kbd_rpt_key,kbd_rpt_ns,
	ps2_q[16],ps2_head,ps2_tail,rtc_idx,vga_idx,vga_rd,vga_wr,ata_len;
Bool ps2_ms,ps2_cfg,ata_wr;

class CWlGlbl
{public:
  const char *name;
  U32 ver,*id;
} wl_glbls[6]={{"wl_compositor",4,&wl_comp},{"wl_shm",1,&wl_shm},
	{"wl_seat",1,&wl_seat},{"xdg_wm_base",1,&wl_base},
	{"wp_viewporter",1,&wl_view},
	{"wp_fractional_scale_manager_v1",1,&wl_frac}};

U0 Die(const char *st)
{
  perror(st);
  exit(1);
}

I64 Ns()
{//Nanoseconds on a clock that never steps.
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC,&ts);
  return ts.tv_sec*NS_SEC+ts.tv_nsec;
}

U0 Rst()
{//A reset is the capture again.
  execv("/proc/self/exe",args);
  Die("HEMU");
}

U8 *FileMap(const char *name,I64 *_size)
{//A private copy of a file: what the guest writes ends with HEMU. The
//page's zeros after a text end it.
  struct stat st;
  I32 fd=open(name,O_RDONLY);
  U8 *res;
  if (fd<0 || fstat(fd,&st)<0)
    Die(name);
  res=(U8 *)mmap(NULL,st.st_size,PROT_READ|PROT_WRITE,
	MAP_PRIVATE|MAP_NORESERVE,fd,0);
  if (res==MAP_FAILED)
    Die(name);
  close(fd);
  *_size=st.st_size;
  return res;
}

U64 GuestU64(U64 a)
{//Eight bytes of guest RAM, 0 outside it.
  if (a<mem_size-8)
    return *(U64 *)(mem+a);
  return 0;
}

U64 SymFind(const char *st,I64 type)
{//TempleOS's record of a name: HashFind, Kernel/KHashA.HC.
  U64 h=0,tbl,tmph;
  const char *ptr;
  for (ptr=st;*ptr;ptr++)
    h=(h<<1)+(h>>63)+*ptr;
  h+=(h>>16)+(h>>15&1);
  for (tbl=hash_tbl;tbl;tbl=GuestU64(tbl))
    for (tmph=GuestU64(GuestU64(tbl+TBL_BODY)+(h&GuestU64(tbl+TBL_MASK))*8);
	  tmph;tmph=GuestU64(tmph))
      if (GuestU64(tmph+HASH_TYPE)&type &&
	    !strcmp((char *)mem+GuestU64(tmph+HASH_STR),st))
	return tmph;
  fprintf(stderr,"HEMU: this TempleOS has no %s\n",st);
  exit(1);
}

I64 Member(const char *cls,const char *st)
{//Offset of a member in the guest's class.
  U64 tmpm=GuestU64(SymFind(cls,HTT_CLASS)+CLASS_MEMBERS);
  while (tmpm && strcmp((char *)mem+GuestU64(tmpm+ML_STR),st))
    tmpm=GuestU64(tmpm);
  if (!tmpm)
    SymFind(st,0);
  return GuestU64(tmpm+ML_OFFSET);
}

U64 Var(const char *st,const char *cls,const char *member)
{//Where a member of the guest's global variable lives.
  return GuestU64(SymFind(st,HTT_GLBL_VAR)+VAR_DATA_ADDR)+Member(cls,member);
}

U0 SymInit(U64 task)
{//What HEMU reads and writes in TempleOS, by its own names.
  I64 i,j;
  hash_tbl=GuestU64(task+TASK_HASH_TABLE);
  ms_pos=Var("ms","CMsStateGlbls","pos");
  ms_pos_text=Var("ms","CMsStateGlbls","pos_text");
  ms_lb=Var("ms","CMsStateGlbls","lb");
  ms_rb=Var("ms","CMsStateGlbls","rb");
  mem[Var("ms_hard","CMsHardStateGlbls","installed")]=TRUE;
  gr_dc1=Var("gr","CGrGlbls","dc1");
  gr_zoomed_dc=Var("gr","CGrGlbls","zoomed_dc");
  gr_scrn_zoom=Var("gr","CGrGlbls","scrn_zoom");
  dc_body=Member("CDC","body");
  //The capture has no HPET count. Its clock goes on from the last time
  //it drew the screen, so what waits on tS wakes in the same epoch.
  hpet_freq=GuestU64(Var("cnts","CCntsGlbls","HPET_freq"));
  hpet0=GuestU64(Var("cnts","CCntsGlbls","HPET_initial"))+hpet_freq*
	*(F64 *)(mem+Var("winmgr","CWinMgrGlbls","last_refresh_tS"));
  ns0=Ns();
  for (i=0;i<256;i++)
    for (j=0;j<8;j++)
      spread[i]|=(U64)(i>>j&1)<<j*8;
}

U64 Hpet()
{//The HPET's main counter.
  I64 d=Ns()-ns0;
  return hpet0+d/NS_SEC*hpet_freq+d%NS_SEC*hpet_freq/NS_SEC;
}

U0 Irq(I64 num)
{//One edge on a line of the PIC.
  struct kvm_irq_level l;
  l.irq=num;
  l.level=1;
  ioctl(vm,KVM_IRQ_LINE,&l);
  l.level=0;
  ioctl(vm,KVM_IRQ_LINE,&l);
}

U0 Wl(U32 obj,U32 op,const char *fmt,...)
{//A request to the compositor: u is 32 bits, s a string, f a file.
  U32 msg[32],n=2,len;
  I32 fd=-1;
  char *st,ctl[CMSG_SPACE(sizeof(I32))];
  struct iovec io;
  struct msghdr hdr;
  struct cmsghdr *c;
  va_list ap;
  va_start(ap,fmt);
  for (;*fmt;fmt++)
    if (*fmt=='u')
      msg[n++]=va_arg(ap,U32);
    else if (*fmt=='s') {
      st=va_arg(ap,char *);
      len=strlen(st)+1;
      msg[n++]=len;
      msg[n+(len-1)/4]=0;
      memcpy(msg+n,st,len);
      n+=(len+3)/4;
    } else
      fd=va_arg(ap,I32);
  va_end(ap);
  msg[0]=obj;
  msg[1]=n*4<<16|op;
  memset(&hdr,0,sizeof(hdr));
  io.iov_base=msg;
  io.iov_len=n*4;
  hdr.msg_iov=&io;
  hdr.msg_iovlen=1;
  if (fd>=0) {
    hdr.msg_control=ctl;
    hdr.msg_controllen=sizeof(ctl);
    c=CMSG_FIRSTHDR(&hdr);
    c->cmsg_level=SOL_SOCKET;
    c->cmsg_type=SCM_RIGHTS;
    c->cmsg_len=CMSG_LEN(sizeof(I32));
    memcpy(CMSG_DATA(c),&fd,sizeof(I32));
  }
  if (sendmsg(wl,&hdr,MSG_NOSIGNAL)<0)
    exit(0);
}

U0 ScrnDraw()
{//The last frame to the window, each pixel a zoom by zoom square.
  I64 x,y,i;
  U32 *dst,c;
  U8 *src=(U8 *)scrn;
  if (!buf)
    return;
  for (y=0;y<SCRN_H;y++) {
    dst=buf+(off_y+y*zoom)*buf_w+off_x;
    for (x=0;x<SCRN_W;x++) {
      c=pal[*src++];
      for (i=0;i<zoom;i++)
	*dst++=c;
    }
    dst-=SCRN_W*zoom;
    for (i=1;i<zoom;i++)
      memcpy(dst+i*buf_w,dst,SCRN_W*zoom*4);
  }
  Wl(wl_surf,1,"uuu",wl_buf,0,0); //attach
  Wl(wl_surf,9,"uuuu",0,0,buf_w,buf_h); //damage_buffer
  Wl(wl_surf,6,""); //commit
}

U0 WinSize()
{//A buffer of the window's size in the monitor's own pixels, the screen
//in its middle at the largest whole zoom that fits. A window too small
//for one gets the screen alone, and the compositor shrinks it.
  I64 w=(win_w*win_scale+60)/120,h=(win_h*win_scale+60)/120;
  I32 fd;
  if (w<SCRN_W || h<SCRN_H) {
    w=SCRN_W;
    h=SCRN_H;
  }
  if (w!=buf_w || h!=buf_h) {
    if (buf) {
      Wl(wl_buf,0,""); //destroy
      Wl(wl_pool,1,""); //destroy
      munmap(buf,buf_w*buf_h*4);
    }
    buf_w=w;
    buf_h=h;
    fd=memfd_create("HEMU",0);
    if (fd<0 || ftruncate(fd,w*h*4)<0)
      Die("memfd");
    buf=(U32 *)mmap(NULL,w*h*4,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
    Wl(wl_shm,0,"ufu",wl_pool=wl_id++,fd,w*h*4); //create_pool
    close(fd);
    //create_buffer, XRGB8888
    Wl(wl_pool,0,"uuuuuu",wl_buf=wl_id++,0,w,h,w*4,1);
    zoom=w/SCRN_W;
    if (h/SCRN_H<zoom)
      zoom=h/SCRN_H;
    off_x=(w-SCRN_W*zoom)/2;
    off_y=(h-SCRN_H*zoom)/2;
  }
  if (wl_port)
    Wl(wl_port,2,"uu",win_w,win_h); //set_destination
  ScrnDraw();
}

U0 WinNew()
{//The window, once the compositor has named what it offers.
  if (!wl_comp || !wl_shm || !wl_base) {
    fprintf(stderr,"HEMU: the compositor has no xdg-shell\n");
    exit(1);
  }
  Wl(wl_comp,0,"u",wl_surf=wl_id++); //create_surface
  Wl(wl_base,2,"uu",wl_xsurf=wl_id++,wl_surf); //get_xdg_surface
  Wl(wl_xsurf,1,"u",wl_top=wl_id++); //get_toplevel
  Wl(wl_top,2,"s","TempleOS"); //set_title
  Wl(wl_top,3,"s","HEMU"); //set_app_id
  if (wl_view)
    Wl(wl_view,1,"uu",wl_port=wl_id++,wl_surf); //get_viewport
  if (wl_view && wl_frac) //get_fractional_scale
    Wl(wl_frac,1,"uu",wl_scale=wl_id++,wl_surf);
  Wl(wl_surf,6,""); //commit
}

U0 KbdPut(I64 b)
{//A byte from the keyboard, and its IRQ 1.
  if (kbd_tail-kbd_head<64) {
    kbd_q[kbd_tail++&63]=b;
    Irq(1);
  }
}

U0 ScPut(I64 sc)
{//A set 1 scan code: 0x100 more if 0xE0 comes before it.
  if (sc&0x100)
    KbdPut(0xE0);
  KbdPut(sc&0xFF);
}

U0 KbdRpt()
{//The held key again, at the rate TempleOS set with command 0xF3.
  while (kbd_rpt_key && Ns()>=kbd_rpt_ns) {
    ScPut(kbd_rpt_key);
    kbd_rpt_ns+=((kbd_type&7)+8<<(kbd_type>>3&3))*(NS_SEC/240);
  }
}

I64 KbdWait()
{//Milliseconds until the held key repeats, -1 with no key held.
  I64 res=-1;
  if (kbd_rpt_key) {
    res=(kbd_rpt_ns-Ns())/1000000+1;
    if (res<0)
      res=0;
  }
  return res;
}

U0 KeySet(I64 key,Bool down)
{//An evdev key goes down or up. Up to F12 its number is its scan code.
//Shift, Ctrl, Alt and the locks do not repeat.
  I64 sc=key;
  if (96<=key && key<112)
    sc=0x100|kbd_ext[key-96];
  else if (key>88)
    return;
  if (!(sc&0xFF))
    return;
  if (down) {
    kbd_down[key>>6]|=1UL<<(key&63);
    if (!strchr("\x1D\x2A\x36\x38\x3A\x45\x46",sc&0xFF)) {
      kbd_rpt_key=sc;
      kbd_rpt_ns=Ns()+((kbd_type>>5&3)+1)*(NS_SEC/4);
    }
  } else {
    if (!(kbd_down[key>>6]>>(key&63)&1))
      return;
    kbd_down[key>>6]&=~(1UL<<(key&63));
    if (sc==kbd_rpt_key)
      kbd_rpt_key=0;
    sc|=0x80;
  }
  ScPut(sc);
}

U0 MsSet(I32 x,I32 y)
{//The pointer, in 256ths of the compositor's units, is TempleOS's mouse.
  x=((I64)x*buf_w/win_w/256-off_x)/zoom;
  y=((I64)y*buf_h/win_h/256-off_y)/zoom;
  if (x<0)
    x=0;
  if (x>=SCRN_W)
    x=SCRN_W-1;
  if (y<0)
    y=0;
  if (y>=SCRN_H)
    y=SCRN_H-1;
  *(I64 *)(mem+ms_pos)=x;
  *(I64 *)(mem+ms_pos+8)=y;
  *(I64 *)(mem+ms_pos_text)=x/8;
  *(I64 *)(mem+ms_pos_text+8)=y/8;
}

U0 WlEvt(U32 *m)
{//One event from the compositor.
  U32 obj=m[0],op=m[1]&0xFFFF;
  I64 i;
  if (obj==1 && !op) {//error
    fprintf(stderr,"HEMU: Wayland: %s\n",(char *)(m+5));
    exit(1);
  } else if (obj==wl_reg && !op) {//global: name,interface,version
    for (i=0;i<6;i++)
      if (!strcmp((char *)(m+4),wl_glbls[i].name)) //bind
	Wl(wl_reg,0,"usuu",m[2],wl_glbls[i].name,wl_glbls[i].ver,
	      *wl_glbls[i].id=wl_id++);
  } else if (obj==wl_cb)
    WinNew();
  else if (obj==wl_base)
    Wl(wl_base,3,"u",m[2]); //ping: pong
  else if (obj==wl_seat && !op) {//capabilities
    if (m[2]&1 && !wl_ptr)
      Wl(wl_seat,0,"u",wl_ptr=wl_id++); //get_pointer
    if (m[2]&2 && !wl_kbd)
      Wl(wl_seat,1,"u",wl_kbd=wl_id++); //get_keyboard
  } else if (obj==wl_top) {
    if (op==1) //close
      exit(0);
    if (!op && m[2] && m[3]) {//configure: width,height
      win_w=m[2];
      win_h=m[3];
    }
  } else if (obj==wl_xsurf) {//configure: serial
    Wl(wl_xsurf,4,"u",m[2]); //ack_configure
    WinSize();
  } else if (obj==wl_scale) {//preferred_scale, in 120ths
    win_scale=m[2];
    if (buf)
      WinSize();
  } else if (obj==wl_ptr) {
    if (!op) {//enter: serial,surface,x,y
      Wl(wl_ptr,0,"uuuu",m[2],0,0,0); //set_cursor: TempleOS draws its own
      MsSet(m[4],m[5]);
    } else if (op==2) //motion: time,x,y
      MsSet(m[3],m[4]);
    else if (op==3) {//button: serial,time,button,state
      if (m[4]==0x110)
	mem[ms_lb]=m[5];
      else if (m[4]==0x111)
	mem[ms_rb]=m[5];
    } else if (op==4 && !m[3]) {//axis: time,axis,value
      if ((I32)m[4]>0)
	ms_z++;
      else
	ms_z--;
      *(I64 *)(mem+ms_pos+16)=ms_z;
    }
  } else if (obj==wl_kbd) {
    if (op==3) //key: serial,time,key,state
      KeySet(m[4],m[5]);
    else if (op==2) //leave: no key is held in a window without the keys
      for (i=1;i<112;i++)
	if (kbd_down[i>>6]>>(i&63)&1)
	  KeySet(i,FALSE);
  }
}

U0 WinTask()
{//The window: the compositor's events, TempleOS's finished frames and the
//held key's repeats.
  U32 in[1024];
  I64 n=0,i,len;
  U64 cnt;
  struct pollfd pfd[2];
  pfd[0].fd=wl;
  pfd[1].fd=scrn_evt;
  pfd[0].events=pfd[1].events=POLLIN;
  while (TRUE) {
    poll(pfd,2,KbdWait());
    pthread_mutex_lock(&dev_lock);
    KbdRpt();
    if (pfd[0].revents) {
      if ((len=read(wl,(U8 *)in+n,sizeof(in)-n))<=0)
	exit(0);
      n+=len;
      for (i=0;i+8<=n && i+(in[i/4+1]>>16)<=n;i+=in[i/4+1]>>16)
	WlEvt(in+i/4);
      memmove(in,(U8 *)in+i,n-=i);
    }
    pthread_mutex_unlock(&dev_lock);
    if (pfd[1].revents && read(scrn_evt,&cnt,8)>0)
      ScrnDraw();
  }
}

U0 ScrnGet()
{//TempleOS is about to write the frame it finished to the VGA's planes
//(GrUpdateVGAGraphics, Adam/Gr/GrScrn.HC). The frame is four planes of a
//bit a pixel, the leftmost lowest.
  U64 dc=GuestU64(gr_dc1),body,v,cnt=0;
  U8 *src;
  I64 i;
  if (GuestU64(gr_scrn_zoom)!=1)
    dc=GuestU64(gr_zoomed_dc);
  body=GuestU64(dc+dc_body);
  if (body+4*PLANE_SIZE>mem_size)
    return;
  src=mem+body;
  for (i=0;i<PLANE_SIZE;i++) {
    v=spread[src[i]]|spread[src[PLANE_SIZE+i]]<<1|
	  spread[src[2*PLANE_SIZE+i]]<<2|spread[src[3*PLANE_SIZE+i]]<<3;
    if (v!=scrn[i]) {
      scrn[i]=v;
      cnt=1;
    }
  }
  if (cnt)
    write(scrn_evt,&cnt,8);
}

U0 PalSet(I64 i)
{//A VGA color's six bits a gun, as the window's eight.
  U8 *c=vga_dac+i*3;
  U64 cnt=1;
  pal[i]=c[0]*255/63<<16|c[1]*255/63<<8|c[2]*255/63;
  write(scrn_evt,&cnt,8);
}

U0 PalInit()
{//The 16 colors a VGA powers on with.
  I64 i,j;
  for (i=0;i<16;i++) {
    for (j=0;j<3;j++)
      vga_dac[i*3+j]=(i>>(2-j)&1)*42+(i>>3)*21;
    if (i==6)
      vga_dac[i*3+1]=21;
    PalSet(i);
  }
}

U0 Ps2Put(I64 b)
{//An answer to a command: TempleOS polls for it. 0x100 more from the mouse.
  ps2_q[ps2_tail++&15]=b;
}

U0 AtaCmd(I64 cmd)
{//Sectors to read or write. TempleOS sends a 48 bit address high bytes
//first, so each register keeps its last two bytes.
  I64 cnt=ata_reg[2],
	blk=ata_reg[3]&0xFF|(ata_reg[4]&0xFF)<<8|(ata_reg[5]&0xFF)<<16|
	(I64)(ata_reg[3]>>8)<<24|(I64)(ata_reg[4]>>8)<<32|
	(I64)(ata_reg[5]>>8)<<40;
  if (!cnt || cnt>256)
    cnt=256;
  ata_len=0;
  ata_wr=FALSE;
  switch (cmd) {
    case 0x30:
    case 0x34:
    case 0x39:
    case 0xC5:
      ata_wr=TRUE;
    case 0x20:
    case 0x21:
    case 0x24:
    case 0x29:
    case 0xC4:
      if ((blk+cnt)*BLK_SIZE<=dsk_size) {
	ata_ptr=dsk+blk*BLK_SIZE;
	ata_len=cnt*BLK_SIZE;
      }
  }
  memset(ata_reg,0,sizeof(ata_reg));
}

I64 Rtc(I64 idx)
{//The CMOS clock: the host's time, binary and 24 hour.
  time_t t=time(NULL);
  struct tm *tm=localtime(&t);
  switch (idx) {
    case 0:
      return tm->tm_sec;
    case 2:
      return tm->tm_min;
    case 4:
      return tm->tm_hour;
    case 6:
      return tm->tm_wday+1;
    case 7:
      return tm->tm_mday;
    case 8:
      return tm->tm_mon+1;
    case 9:
      return tm->tm_year%100;
    case 0x0B:
      return 6;
  }
  return 0;
}

U0 IoIn(I64 port,U8 *data,I64 size)
{//IN. A port nothing is at reads 0.
  I64 v=0;
  if (((port|0x80)&~7)==0x1F0) {
    if ((port&7)==7)
      v=0x40|(ata_len!=0)<<3; //DRDY, and DRQ while sectors are left.
    else if (!(port&7) && !ata_wr && ata_len>=size) {
      memcpy(data,ata_ptr,size);
      ata_ptr+=size;
      ata_len-=size;
      return;
    }
  } else
    switch (port) {
      case 0x60:
	if (ps2_head!=ps2_tail)
	  v=ps2_q[ps2_head++&15]&0xFF;
	else if (kbd_head!=kbd_tail) {
	  v=kbd_q[kbd_head++&63];
	  if (kbd_head!=kbd_tail)
	    Irq(1);
	}
	break;
      case 0x64:
	v=0x1C;
	if (ps2_head!=ps2_tail)
	  v|=1|ps2_q[ps2_head&15]>>3&0x20;
	else if (kbd_head!=kbd_tail)
	  v|=1;
	break;
      case 0x71:
	v=Rtc(rtc_idx);
	break;
      case 0x92:
	v=2;
	break;
      case 0x3C6:
	v=0xFF;
	break;
      case 0x3C8:
	v=vga_wr/3;
	break;
      case 0x3C9:
	v=vga_dac[vga_rd];
	vga_rd=(vga_rd+1)%768;
    }
  memcpy(data,&v,size);
}

U0 IoOut(I64 port,U8 *data,I64 size)
{//OUT.
  I64 v=0;
  memcpy(&v,data,size);
  if (((port|0x80)&~7)==0x1F0) {
    if ((port&7)==7)
      AtaCmd(v);
    else if (port&7)
      ata_reg[port&7]=ata_reg[port&7]<<8|v&0xFF;
    else if (ata_wr && ata_len>=size) {
      memcpy(ata_ptr,data,size);
      ata_ptr+=size;
      ata_len-=size;
    }
    return;
  }
  v&=0xFF;
  switch (port) {
    case 0x60:
      if (ps2_cfg)
	ps2_cfg=FALSE;
      else if (ps2_ms) {
	ps2_ms=FALSE;
	Ps2Put(0x1FA);
	if (v==0xFF) {
	  Ps2Put(0x1AA);
	  Ps2Put(0x100);
	} else if (v==0xF2)
	  Ps2Put(0x100);
      } else {
	Ps2Put(0xFA);
	if (kbd_cmd) {
	  if (kbd_cmd==0xF3)
	    kbd_type=v&0x7F;
	  kbd_cmd=0;
	} else if (v==0xF3 || v==0xED)
	  kbd_cmd=v;
	else if (v==0xFF) {
	  kbd_rpt_key=0;
	  kbd_type=0x2B;
	  Ps2Put(0xAA);
	}
      }
      break;
    case 0x64:
      if (v==0xD4)
	ps2_ms=TRUE;
      else if (v==0x60)
	ps2_cfg=TRUE;
      else if (v==0x20)
	Ps2Put(0x47);
      else if (v==0xA9 || v==0xAB)
	Ps2Put(0);
      else if (v==0xAA)
	Ps2Put(0x55);
      break;
    case 0x70:
      rtc_idx=v&0x7F;
      break;
    case 0x92:
      if (v&1)
	Rst();
      break;
    case 0x3C4:
      vga_idx=v;
      break;
    case 0x3C5:
      if (vga_idx==2 && v==1) //Map mask: the first plane of a frame.
	ScrnGet();
      break;
    case 0x3C7:
      vga_rd=v*3;
      break;
    case 0x3C8:
      vga_wr=v*3;
      break;
    case 0x3C9:
      vga_dac[vga_wr]=v&63;
      vga_wr=(vga_wr+1)%768;
      if (!(vga_wr%3) && 0<vga_wr && vga_wr<=48)
	PalSet(vga_wr/3-1);
  }
}

U0 *CoreTask(U0 *arg)
{//One of the guest's processors. It runs TempleOS until a port or the
//HPET needs an answer.
  I64 i=(I64)arg,n;
  struct kvm_run *run=core_run[i];
  U8 *data;
  U64 v;
  while (TRUE) {
    if (ioctl(core_fd[i],KVM_RUN,0)<0) {
      if (errno!=EINTR)
	Die("KVM_RUN");
      run->exit_reason=KVM_EXIT_INTR;
    }
    pthread_mutex_lock(&dev_lock);
    if (run->exit_reason==KVM_EXIT_IO) {
      data=(U8 *)run+run->io.data_offset;
      for (n=run->io.count;n--;data+=run->io.size)
	if (run->io.direction==KVM_EXIT_IO_OUT)
	  IoOut(run->io.port,data,run->io.size);
	else
	  IoIn(run->io.port,data,run->io.size);
    } else if (run->exit_reason==KVM_EXIT_MMIO) {
      v=0;
      if (run->mmio.phys_addr==0xFED000F0)
	v=Hpet();
      else if (run->mmio.phys_addr==0xFED000F4)
	v=Hpet()>>32;
      if (!run->mmio.is_write)
	memcpy(run->mmio.data,&v,8);
    } else if (run->exit_reason==KVM_EXIT_SHUTDOWN)
      Rst();
    else if (run->exit_reason!=KVM_EXIT_INTR) {
      fprintf(stderr,"HEMU: KVM exit %d\n",run->exit_reason);
      exit(1);
    }
    pthread_mutex_unlock(&dev_lock);
  }
}

U0 *SndTask(U0 *)
{//The PC speaker: a square wave at the rate of PIT channel 2 while port
//0x61 holds its gate and the speaker's bit. The kernel's PIT has both.
  snd_pcm_t *pcm;
  struct kvm_pit_state2 pit;
  U8 smp[SND_RATE/200];
  F64 phase=0;
  U64 i;
  if (snd_pcm_open(&pcm,"default",SND_PCM_STREAM_PLAYBACK,0)<0 ||
	snd_pcm_set_params(pcm,SND_PCM_FORMAT_U8,SND_PCM_ACCESS_RW_INTERLEAVED,
	1,SND_RATE,1,20000)<0)
    return NULL;
  while (TRUE) {
    ioctl(vm,KVM_GET_PIT2,&pit);
    for (i=0;i<sizeof(smp);i++) {
      smp[i]=128;
      if (pit.channels[2].gate && pit.channels[2].count &&
	    pit.flags&KVM_PIT_FLAGS_SPEAKER_DATA_ON) {
	phase+=(F64)PIT_FREQ/pit.channels[2].count/SND_RATE;
	phase-=(I64)phase;
	if (phase<0.5)
	  smp[i]+=SND_VOL;
	else
	  smp[i]-=SND_VOL;
      }
    }
    if (snd_pcm_writei(pcm,smp,sizeof(smp))<0)
      snd_pcm_prepare(pcm);
  }
}

U64 Reg(char *blk,const char *name,I64 n=0)
{//The nth hex number after name in a processor's part of the dump.
  char *ptr=strstr(blk,name);
  U64 res;
  if (!ptr) {
    fprintf(stderr,"HEMU: Regs.TXT has no %s\n",name);
    exit(1);
  }
  ptr+=strlen(name);
  do res=strtoul(ptr,&ptr,16);
  while (n--);
  return res;
}

U0 CoreNew(I64 i,char *blk,struct kvm_cpuid2 *id)
{//A processor as QEMU's "info registers" printed it when it was stopped.
  static const char *gprs[18]={"RAX=","RBX=","RCX=","RDX=","RSI=","RDI=",
	"RSP=","RBP=","R8 =","R9 =","R10=","R11=","R12=","R13=","R14=","R15=",
	"RIP=","RFL="},
	*segs[8]={"CS =","DS =","ES =","FS =","GS =","SS =","TR =","LDT="};
  struct kvm_regs regs;
  struct kvm_sregs sregs;
  struct kvm_segment *seg=&sregs.cs;
  struct kvm_fpu fpu;
  struct kvm_lapic_state lapic;
  struct kvm_mp_state mp;
  char name[8];
  I64 j;
  U64 f;
  if ((core_fd[i]=ioctl(vm,KVM_CREATE_VCPU,i))<0)
    Die("KVM_CREATE_VCPU");
  core_run[i]=(struct kvm_run *)mmap(NULL,
	ioctl(kvm,KVM_GET_VCPU_MMAP_SIZE,0),
	PROT_READ|PROT_WRITE,MAP_SHARED,core_fd[i],0);
  ioctl(core_fd[i],KVM_SET_CPUID2,id);
  for (j=0;j<18;j++)
    ((U64 *)&regs)[j]=Reg(blk,gprs[j]);
  ioctl(core_fd[i],KVM_SET_REGS,&regs);
  ioctl(core_fd[i],KVM_GET_SREGS,&sregs);
  for (j=0;j<8;j++) {//Selector, base, limit and the descriptor's flags.
    f=Reg(blk,segs[j],3);
    seg[j].selector=Reg(blk,segs[j]);
    seg[j].base=Reg(blk,segs[j],1);
    seg[j].limit=Reg(blk,segs[j],2);
    seg[j].type=f>>8&15;
    seg[j].s=f>>12&1;
    seg[j].dpl=f>>13&3;
    seg[j].present=f>>15&1;
    seg[j].avl=f>>20&1;
    seg[j].l=f>>21&1;
    seg[j].db=f>>22&1;
    seg[j].g=f>>23&1;
    seg[j].unusable=!seg[j].present;
  }
  sregs.gdt.base=Reg(blk,"GDT=");
  sregs.gdt.limit=Reg(blk,"GDT=",1);
  sregs.idt.base=Reg(blk,"IDT=");
  sregs.idt.limit=Reg(blk,"IDT=",1);
  sregs.cr0=Reg(blk,"CR0=");
  sregs.cr2=Reg(blk,"CR2=");
  sregs.cr3=Reg(blk,"CR3=");
  sregs.cr4=Reg(blk,"CR4=");
  sregs.efer=Reg(blk,"EFER=");
  if (ioctl(core_fd[i],KVM_SET_SREGS,&sregs)<0)
    Die("KVM_SET_SREGS");
  memset(&fpu,0,sizeof(fpu));
  fpu.fcw=Reg(blk,"FCW=");
  fpu.fsw=Reg(blk,"FSW=");
  fpu.ftwx=Reg(blk,"FTW=");
  fpu.mxcsr=Reg(blk,"MXCSR=");
  for (j=0;j<8;j++) {
    sprintf(name,"FPR%ld=",j);
    *(U64 *)fpu.fpr[j]=Reg(blk,name);
    *(U16 *)(fpu.fpr[j]+8)=Reg(blk,name,1);
  }
  for (j=0;j<16;j++) {
    sprintf(name,"XMM%02ld=",j);
    *(U64 *)(fpu.xmm[j]+8)=Reg(blk,name);
    *(U64 *)fpu.xmm[j]=Reg(blk,name,1);
  }
  ioctl(core_fd[i],KVM_SET_FPU,&fpu);
  //The APIC as MPAPICInit left it (Kernel/MultiProc.HC), and the PIC's
  //interrupts to core 0 through LINT0, as the BIOS wires them.
  ioctl(core_fd[i],KVM_GET_LAPIC,&lapic);
  *(U32 *)(lapic.regs+0xF0)=0x1FF;
  *(U32 *)(lapic.regs+0xD0)=i<<24;
  *(U32 *)(lapic.regs+0xE0)=0xFFFFFFFF;
  *(U32 *)(lapic.regs+0x350)=0x10000;
  if (!i)
    *(U32 *)(lapic.regs+0x350)=0x700;
  ioctl(core_fd[i],KVM_SET_LAPIC,&lapic);
  mp.mp_state=KVM_MP_STATE_RUNNABLE;
  if (Reg(blk,"HLT="))
    mp.mp_state=KVM_MP_STATE_HALTED;
  ioctl(core_fd[i],KVM_SET_MP_STATE,&mp);
}

U0 PcInit()
{//The PC: its RAM, and the PIC and PIT as TempleOS set them when it
//booted (IntInit1 in Kernel/KInts.HC, the keyboard's and the mouse's
//IRQs, SYS_TIMER0_PERIOD).
  struct kvm_userspace_memory_region rgn;
  struct kvm_pit_config pit_cfg;
  struct kvm_pit_state2 pit;
  struct kvm_irqchip pic;
  I64 i;
  kvm=open("/dev/kvm",O_RDWR);
  if ((vm=ioctl(kvm,KVM_CREATE_VM,0))<0)
    Die("/dev/kvm");
  ioctl(vm,KVM_SET_TSS_ADDR,0xFFFBD000);
  pit_cfg.flags=KVM_PIT_SPEAKER_DUMMY; //Port 0x61 is the kernel's too.
  if (ioctl(vm,KVM_CREATE_IRQCHIP,0)<0 || ioctl(vm,KVM_CREATE_PIT2,&pit_cfg)<0)
    Die("KVM_CREATE_IRQCHIP");
  memset(&rgn,0,sizeof(rgn));
  rgn.memory_size=mem_size;
  rgn.userspace_addr=(U64)mem;
  if (ioctl(vm,KVM_SET_USER_MEMORY_REGION,&rgn)<0)
    Die("KVM_SET_USER_MEMORY_REGION");
  for (i=0;i<2;i++) {
    pic.chip_id=i;
    ioctl(vm,KVM_GET_IRQCHIP,&pic);
    pic.chip.pic.irq_base=0x20+i*8;
    pic.chip.pic.imr=0xF8;
    if (i)
      pic.chip.pic.imr=0xEF;
    pic.chip.pic.init4=1;
    ioctl(vm,KVM_SET_IRQCHIP,&pic);
  }
  ioctl(vm,KVM_GET_PIT2,&pit);
  pit.channels[0].count=65536*182/10/1000;
  pit.channels[0].mode=2;
  pit.channels[0].rw_mode=pit.channels[0].read_state=
	pit.channels[0].write_state=3;
  pit.channels[0].gate=1;
  ioctl(vm,KVM_SET_PIT2,&pit);
}

int main(int,char **argv)
{
  char path[4096],*regs,*blk;
  struct sockaddr_un addr;
  struct kvm_cpuid2 *id;
  pthread_t task;
  I64 i,n=0,size;
  args=argv;
  if ((i=readlink("/proc/self/exe",path,sizeof(path)-1))>0) {
    path[i]=0;
    *strrchr(path,'/')=0;
    chdir(path);
  }
  mem=FileMap("RAM.BIN",&mem_size);
  dsk=FileMap("Disk.BIN",&dsk_size);
  regs=(char *)FileMap("Regs.TXT",&size);
  PcInit();
  id=(struct kvm_cpuid2 *)calloc(1,sizeof(*id)+
	128*sizeof(struct kvm_cpuid_entry2));
  id->nent=128;
  ioctl(kvm,KVM_GET_SUPPORTED_CPUID,id);
  for (blk=regs;(blk=strstr(blk,"CPU#")) && n<CORES_NUM;blk++)
    CoreNew(n++,blk,id);
  scrn_evt=eventfd(0,0);
  SymInit(Reg(regs,"FS =",1));
  PalInit();
  ScrnGet();
  addr.sun_family=AF_UNIX;
  snprintf(addr.sun_path,sizeof(addr.sun_path),"%s/%s",
	getenv("XDG_RUNTIME_DIR"),getenv("WAYLAND_DISPLAY"));
  wl=socket(AF_UNIX,SOCK_STREAM,0);
  if (connect(wl,(struct sockaddr *)&addr,sizeof(addr))<0)
    Die("Wayland");
  Wl(1,1,"u",wl_reg=wl_id++); //get_registry
  Wl(1,0,"u",wl_cb=wl_id++); //sync
  for (i=0;i<n;i++)
    pthread_create(&task,NULL,&CoreTask,(U0 *)i);
  pthread_create(&task,NULL,&SndTask,NULL);
  WinTask();
}
