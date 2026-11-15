#define JIT_CODE_SIZE 8192
#define JIT_PART_NUM 400

class CJitFlags
{
  I64 kind,size,first,cnt;
};

class CJitPart
{
  I64 base,offset,len;
};

class CJitDecode
{
  I64 rip,i,j,n,op,ext,size,rex,rex_w,rex_r,rex_x,rex_b,rep;
  I64 loop_cc,loop_fall,top_at,top_target,top_count;
  Bool two,term,if_break,compare_head,top_loop,side_exit;
  Bool no_fpr_cache,no_top_loop,no_loop,no_rep,retry_fpr;
};

CJitDecode jit_decode;
CJitFlags jit_flags;
CJitPart jit_parts[JIT_PART_NUM];
CWasmBuf jit_part_buf,jit_part;
I64 jit_part_next,jit_local_next;
U8 jit_code[JIT_CODE_SIZE];
I64 jit_code_start,jit_code_cnt;
Bool jit_bad_code;

I64 JitCodeByte(I64 addr)
{
  addr-=jit_code_start;
  if (0<=addr<jit_code_cnt)
    return jit_code[addr];
  jit_bad_code=TRUE;
  return 0;
}

I64 JitImm(I64 addr,I64 size)
{
  I64 i,value=0;
  if (size>4) size=4;
  for (i=0;i<size;i++)
    value|=JitCodeByte(addr+i)<<(i*8);
  switch (size) {
    case 1: return value<<56>>56;
    case 2: return value<<48>>48;
  }
  return value<<32>>32;
}

I64 JitImm64(I64 addr)
{
  I64 i,value=0;
  for (i=0;i<8;i++)
    value|=JitCodeByte(addr+i)<<(i*8);
  return value;
}

I64 JitImmLen(I64 size)
{
  if (size<4) return size;
  return 4;
}

U0 JitModRm(CJitOperand *m,I64 addr,I64 rex_r,I64 rex_x,I64 rex_b)
{
  I64 byte=JitCodeByte(addr++),mod=byte>>6,rm=byte&7,sib,index,base;
  m->reg_num=byte>>3&7|rex_r<<3;
  m->rm=rm|rex_b<<3;m->is_mem=mod!=3;
  m->base=-1;m->index=-1;m->scale=1;m->disp=0;
  m->rip_rel=FALSE;m->known_ram=FALSE;
  if (mod!=3) {
    if (rm==4) {
      sib=JitCodeByte(addr++);m->scale=1<<(sib>>6);
      index=sib>>3&7|rex_x<<3;
      if (index!=4) m->index=index;
      base=sib&7;
      if (base==5 && !mod) {
	m->disp=JitImm(addr,4);addr+=4;
      } else m->base=base|rex_b<<3;
    } else if (rm==5 && !mod) {
      m->disp=JitImm(addr,4);addr+=4;m->rip_rel=TRUE;
    } else m->base=rm|rex_b<<3;
    if (mod==1) {
      m->disp+=JitImm(addr,1);addr++;
    } else if (mod==2) {
      m->disp+=JitImm(addr,4);addr+=4;
    }
  }
  m->j=addr;
}

U0 JitDefer(CWasmBuf *f,I64 kind,I64 size)
{
  I64 i;
  for (i=0;i<3;i++) {
    WasmArg(f,W_LOCAL_GET,i);WasmArg(f,W_LOCAL_SET,16+i);
  }
  jit_flags.kind=kind;jit_flags.size=size;
  jit_flags.first=jit_part_next;jit_flags.cnt=0;
}

U0 JitPartial(CWasmBuf *f,CWasmBuf *part)
{
  I64 i;
  CJitPart *entry;
  if (jit_part_next>=JIT_PART_NUM) {
    f->overflow=TRUE;
    return;
  }
  entry=&jit_parts[jit_part_next++];
  entry->base=jit_local_next;jit_local_next+=3;
  entry->offset=jit_part_buf.cnt;entry->len=part->cnt;
  WasmCopy(&jit_part_buf,part->data,part->cnt);
  for (i=0;i<3;i++) {
    WasmArg(f,W_LOCAL_GET,i);WasmArg(f,W_LOCAL_SET,entry->base+i);
  }
  jit_flags.cnt++;
}

U0 JitMaterialize(CWasmBuf *f)
{
  I64 i,k;
  CJitPart *part;
  if (jit_flags.kind>=0) {
    for (i=0;i<3;i++) {
      WasmArg(f,W_LOCAL_GET,16+i);WasmArg(f,W_LOCAL_SET,i);
    }
    JitFlags(f,jit_flags.kind,jit_flags.size);
  }
  for (i=0;i<jit_flags.cnt;i++) {
    part=&jit_parts[jit_flags.first+i];
    for (k=0;k<3;k++) {
      WasmArg(f,W_LOCAL_GET,part->base+k);WasmArg(f,W_LOCAL_SET,k);
    }
    WasmCopy(f,jit_part_buf.data+part->offset,part->len);
  }
  jit_flags.kind=-1;jit_flags.first=jit_part_next;jit_flags.cnt=0;
}

U0 JitOperandValue(CWasmBuf *f,I64 local,Bool is_signed)
{
  WasmArg(f,W_LOCAL_GET,local);
  if (jit_flags.size!=8) {
    if (is_signed) {
      switch (jit_flags.size) {
	case 1: WasmByte(f,W_I64_EXTEND8_S);break;
	case 2: WasmByte(f,W_I64_EXTEND16_S);break;
	case 4: WasmByte(f,W_I64_EXTEND32_S);break;
      }
    } else {
      WasmI64(f,1<<(jit_flags.size*8)-1);WasmByte(f,W_I64_AND);
    }
  }
}

U0 JitPendingCond(CWasmBuf *f,I64 cc)
{
  I64 op=0;
  if (jit_flags.kind>=0 && !jit_flags.cnt) {
    if (jit_flags.kind==1) {
      switch (cc) {
	case 2: op=W_I64_LT_U;break;
	case 3: op=W_I64_GE_U;break;
	case 4: op=W_I64_EQ;break;
	case 5: op=W_I64_NE;break;
	case 6: op=W_I64_LE_U;break;
	case 7: op=W_I64_GT_U;break;
	case 12: op=W_I64_LT_S;break;
	case 13: op=W_I64_GE_S;break;
	case 14: op=W_I64_LE_S;break;
	case 15: op=W_I64_GT_S;break;
      }
      if (op) {
	JitOperandValue(f,16,cc>=12);JitOperandValue(f,17,cc>=12);
	WasmByte(f,op);
	return;
      }
    }
    if (cc==4 || cc==5) {
      JitOperandValue(f,18,FALSE);WasmByte(f,W_I64_EQZ);
      if (cc==5) WasmByte(f,W_I32_EQZ);
      return;
    }
  }
  JitMaterialize(f);JitCond(f,cc);
}

U0 JitRamOperand(CWasmBuf *f,I64 span=1)
{
  CJitFlags pending;
  JitCopy(&pending,&jit_flags,sizeof(CJitFlags));
  WasmArg(f,W_LOCAL_GET,3);WasmI64(f,JIT_MEM_SIZE-span);
  WasmByte(f,W_I64_GT_U);WasmIf(f);
  JitMaterialize(f);WasmI32(f,jit_rip_addr);
  WasmI64(f,jit_decode.i-jit_gbase);WasmSt64(f);JitWriteBack(f);
  WasmI32(f,jit_decode.n);WasmByte(f,W_RETURN);WasmByte(f,W_END);
  JitCopy(&jit_flags,&pending,sizeof(CJitFlags));jit_decode.side_exit=TRUE;
}

U0 JitStackOperand(CWasmBuf *f,I64 delta=0,I64 reg_num=4,I64 span=1)
{
  JitRegRd(f,reg_num,8,TRUE);
  if (delta) {
    WasmI64(f,delta);WasmByte(f,W_I64_ADD);
  }
  WasmArg(f,W_LOCAL_SET,3);JitRamOperand(f,span);
}
