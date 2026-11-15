#include "JitWasm"

I64 jit_rfl;
CWasmBuf jit_buf;

#include "JitFlags"
#include "JitRegs"
#include "JitDecode"
#include "JitModule"
#include "JitBlock"
#include "JitFpu"
#include "JitInt"
#include "JitTwo"
#include "JitDispatch"

I64 jit_config[24];

I64 *JitConfig()
{
  return jit_config;
}

U8 *JitInput()
{
  return jit_code;
}

U8 *JitOutput()
{
  return jit_module.data;
}

U0 JitSetup()
{
  jit_reg=jit_config[0];jit_rfl=jit_config[1];
  jit_rip_addr=jit_config[2];jit_gbase=jit_config[3];
  jit_fs=jit_config[4];jit_gs=jit_config[5];jit_tsc=jit_config[6];
  jit_cw=jit_config[7];jit_xmm_lo=jit_config[8];jit_xmm_hi=jit_config[9];
  jit_fpr=jit_config[10];jit_fsp=jit_config[11];jit_sw=jit_config[12];
  jit_shared=jit_config[13];jit_rip_table=jit_config[14];
  jit_count_table=jit_config[15];jit_fast=jit_config[16];
  jit_gate=jit_config[17];
}

I64 JitDispatch()
{
  JitSetup;
  JitDispatchBuild(&jit_buf,jit_config[18]);
  if (jit_module.overflow) return 0;
  return jit_module.cnt;
}

I64 JitBuild(I64 rip,I64 cnt,Bool no_fpr_cache=FALSE,
      Bool no_top_loop=FALSE,Bool no_loop=FALSE,Bool no_rep=FALSE)
{
  I64 attempt,byte,prefix;
  Bool locked,pfx66,handled;
  CJitDecode *d=&jit_decode;
  CWasmBuf *f=&jit_buf;
  JitSetup;
  jit_code_start=jit_gbase+rip;jit_code_cnt=cnt;
  jit_config[20]=16;jit_config[21]=0;jit_config[22]=-1;
  if (cnt<0 || cnt>JIT_CODE_SIZE) return 0;
  for (attempt=0;attempt<3;attempt++) {
    jit_bad_code=FALSE;
    jit_flags.kind=-1;jit_flags.cnt=0;jit_flags.first=0;
    jit_part_next=0;jit_local_next=45;
    jit_part_buf.cnt=0;jit_part_buf.overflow=FALSE;
    jit_reg_used=0;jit_reg_dirty=0;jit_x87=FALSE;
    jit_fcache=!no_fpr_cache;jit_fstack=0;jit_fused=0;
    jit_fdirty=0;jit_fx=FALSE;
    d->rip=rip;d->i=jit_code_start;d->n=0;d->term=FALSE;
    d->loop_cc=-1;d->loop_fall=0;d->if_break=FALSE;
    d->top_at=-1;d->top_target=0;d->top_count=0;d->top_loop=FALSE;
    d->compare_head=FALSE;d->side_exit=FALSE;d->retry_fpr=FALSE;
    d->no_fpr_cache=no_fpr_cache;d->no_top_loop=no_top_loop;
    d->no_loop=no_loop;d->no_rep=no_rep;
    jit_segment_cnt=1;jit_segments[0].start=rip;
    f->cnt=0;f->overflow=FALSE;
    while (d->n<400) {
      d->j=d->i;d->rex_w=0;d->rex_r=0;d->rex_x=0;d->rex_b=0;
      d->rex=0;d->two=FALSE;d->rep=0;locked=FALSE;pfx66=FALSE;
      jit_seg=0;prefix=0;
      while (prefix++<16) {
	byte=JitCodeByte(d->j);
	if (byte==0x66) pfx66=TRUE;
	else if (byte==0x64) jit_seg=1;
	else if (byte==0x65) jit_seg=2;
	else if (byte==0xF3 && !no_rep) d->rep=1;
	else if (byte==0xF2 && !no_rep) d->rep=2;
	else if (byte==0xF0) locked=TRUE;
	else if (byte==0x2E || byte==0x36 || byte==0x3E || byte==0x26) {}
	else if (0x40<=byte<=0x4F) {
	  d->rex=1;d->rex_w=byte>>3&1;d->rex_r=byte>>2&1;
	  d->rex_x=byte>>1&1;d->rex_b=byte&1;d->j++;
	  break;
	} else break;
	d->j++;
      }
      if (prefix>15 || jit_bad_code || locked ||
	    jit_seg==1 && !jit_fs || jit_seg==2 && !jit_gs) break;
      d->op=JitCodeByte(d->j++);
      if (d->op==0x0F) {
	d->two=TRUE;d->op=JitCodeByte(d->j++);
      }
      d->ext=JitCodeByte(d->j)>>3&7;
      if (d->top_at>=0 && !JitIntegerLoopOp(d->op,d->two,d->ext)) {
	no_top_loop=TRUE;
	goto jit_retry;
      }
      if (!d->n)
	d->compare_head=!d->two && (0x38<=d->op<=0x3D ||
	      d->op==0x84 || d->op==0x85 || d->op==0xA8 || d->op==0xA9 ||
	      (d->op==0x80 || d->op==0x81 || d->op==0x83) && d->ext==7 ||
	      (d->op==0xF6 || d->op==0xF7) && d->ext<=1);
      d->size=4;
      if (d->rex_w) d->size=8;
      else if (pfx66) d->size=2;
      if (d->two)
	handled=JitTwoOp(f);
      else if (0xD8<=d->op<=0xDF) {
	if (jit_fcache && jit_fx) {
	  no_fpr_cache=TRUE;
	  goto jit_retry;
	}
	handled=JitFpuOp(f);
      } else handled=JitIntOp(f);
      if (d->retry_fpr) {
	no_fpr_cache=TRUE;
	goto jit_retry;
      }
      if (!handled || jit_bad_code) {
	jit_config[22]=d->op;
	if (d->two) jit_config[22]|=0x100;
	break;
      }
      d->i=d->j;d->n++;
      if (d->term) break;
    }
    if (d->top_at>=0 && !d->top_loop) {
      no_top_loop=TRUE;
      goto jit_retry;
    }
    if (!d->n || jit_bad_code) return 0;
    if (d->loop_cc>=0 && d->side_exit) {
      WasmI64(f,rip);WasmI64(f,d->loop_fall);JitCond(f,d->loop_cc);
      WasmByte(f,W_SELECT);d->loop_cc=-1;
    }
    if (d->loop_cc>=0 && jit_fcache && jit_fstack) {
      no_fpr_cache=TRUE;
      goto jit_retry;
    }
    JitFinish(f);JitModule(f);
    if (jit_module.overflow) return 0;
    jit_config[20]=d->i-jit_code_start;jit_config[21]=d->n;
    return jit_module.cnt;
jit_retry:
    ;
  }
  return 0;
}
