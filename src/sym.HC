//HEMU finds what it needs in the guest by name, the way TempleOS does:
//HashStr and HashFind (Kernel/KHashA.HC) over Adam's chain of hash tables,
//and class members from the metadata TempleOS's compiler keeps at run time.
//Only the records of the table itself are known in advance, and they are
//checked against the guest's own classes before anything is used.

//The records, from V5.03 Kernel/KernelA.HH.
#define HTT_EXPORT_SYS_SYM	1
#define HTT_GLBL_VAR	8
#define HTT_CLASS	0x10
#define HTT_FUN		0x40
#define TASK_SIGNATURE_VAL	0x536B7354
#define TASKf_SUSPENDED		2
#define TASKf_AWAITING_MSG	9
#define TASKf_NONTIMER_RAND	14

#define HASH_NEXT	0
#define HASH_STR	8
#define HASH_TYPE	16
#define TBL_NEXT	0
#define TBL_MASK	8
#define TBL_BODY	24
#define CLASS_MEMBERS	88
#define ML_NEXT		0
#define ML_STR		40

//Adam's table. Its next is the assembler's (Compiler/AsmInit.HC).
U64 sym_tbl;
I64 sym_ml_offset,sym_class_base,sym_fun_exe,sym_fun_args,sym_var_data,
      sym_export_val;

U64 GuestU64(U64 a)
{//Eight bytes of guest RAM, 0 outside it. mem_size is unsigned, so a
//negative a is outside too.
  if (a<mem_size-8)
    return *(mem+a)(U64*);
  return 0;
}

U64 GuestU32(U64 a)
{
  if (a<mem_size-4)
    return *(mem+a)(U32*);
  return 0;
}

Bool GuestStrIs(U64 a,U8 *st)
{//Whether the guest's string at a is st.
  I64 i;
  for (i=0;i<256;i++) {
    if (a+i>=mem_size || mem[a+i]!=st[i])
      return FALSE;
    if (!st[i])
      return TRUE;
  }
  return FALSE;
}

U64 GuestHashStr(U8 *st)
{//SYS_HASH_STR: shift left through the carry and add each byte.
  U64 res=0;
  I64 i;
  for (i=0;st[i];i++)
    res=(res<<1)+(res>>63)+st[i];
  return res+(res>>16)+((res>>15)&1);
}

U64 GuestTblFind(U64 tbl,U8 *st,I64 mask)
{//SYS_HASH_SINGLE_TABLE_FIND, without counting the use.
  I64 n;
  U64 e=GuestU64(GuestU64(tbl+TBL_BODY)+
	(GuestHashStr(st)&GuestU64(tbl+TBL_MASK))*8);
  for (n=0;e && n<0x100000;n++) {
    if (GuestU32(e+HASH_TYPE)&mask && GuestStrIs(GuestU64(e+HASH_STR),st))
      return e;
    e=GuestU64(e+HASH_NEXT);
  }
  return 0;
}

U64 GuestHashFind(U8 *st,I64 mask)
{//HashFind from Adam's table, which holds the kernel's and Adam's symbols.
  I64 n;
  U64 res,t=sym_tbl;
  for (n=0;t && n<16;n++) {
    if (res=GuestTblFind(t,st,mask))
      return res;
    t=GuestU64(t+TBL_NEXT);
  }
  return 0;
}

U64 GuestMemberLst(U8 *cls,U8 *member)
{//MemberFind: the CMemberLst record of a member of a class or its bases.
  I64 i,n;
  U64 m,c=GuestHashFind(cls,HTT_CLASS);
  for (i=0;c && i<16;i++) {
    m=GuestU64(c+CLASS_MEMBERS);
    for (n=0;m && n<4096;n++) {
      if (GuestStrIs(GuestU64(m+ML_STR),member))
	return m;
      m=GuestU64(m+ML_NEXT);
    }
    if (sym_class_base<=0)
      break;
    c=GuestU64(c+sym_class_base);
  }
  return 0;
}

I64 GuestMember(U8 *cls,U8 *member)
{//Offset of a member in the guest's class, -1 if it has none.
  U64 m=GuestMemberLst(cls,member);
  if (!m || !sym_ml_offset)
    return -1;
  return GuestU64(m+sym_ml_offset);
}

U64 GuestFun(U8 *st)
{//Where a function's code starts: its exe_addr, else its exported label.
  U64 e=GuestHashFind(st,HTT_FUN);
  if (e)
    return GuestU64(e+sym_fun_exe);
  e=GuestHashFind(st,HTT_EXPORT_SYS_SYM);
  if (e)
    return GuestU64(e+sym_export_val);
  return 0;
}

I64 GuestArgCnt(U8 *st)
{//How many arguments the guest's function takes, -1 if it is no function.
  U64 e=GuestHashFind(st,HTT_FUN);
  if (!e)
    return -1;
  return GuestU32(e+sym_fun_args);
}

U64 GuestVar(U8 *st)
{//Where a global variable lives: its data_addr, else its exported label.
  U64 e=GuestHashFind(st,HTT_GLBL_VAR);
  if (e)
    return GuestU64(e+sym_var_data);
  e=GuestHashFind(st,HTT_EXPORT_SYS_SYM);
  if (e)
    return GuestU64(e+sym_export_val);
  return 0;
}

Bool GuestMlFind()
{//CMemberLst.offset: 80 on V5.03, more on forks that add members before it.
//It is where CMemberLst's own members offset and size say they are.
  I64 o;
  U64 m_offset=GuestMemberLst("CMemberLst","offset"),
	m_size=GuestMemberLst("CMemberLst","size");
  sym_ml_offset=0;
  if (!m_offset || !m_size)
    return FALSE;
  for (o=48;o<=160;o+=2)
    if (GuestU64(m_offset+o)==o && GuestU64(m_size+o)==o+8) {
      sym_ml_offset=o;
      return TRUE;
    }
  return FALSE;
}

Bool GuestRecordsOk()
{//Whether the guest's classes agree with the records above.
  return GuestMember("CHash","next")==HASH_NEXT &&
	GuestMember("CHash","str")==HASH_STR &&
	GuestMember("CHash","type")==HASH_TYPE &&
	GuestMember("CHashTable","next")==TBL_NEXT &&
	GuestMember("CHashTable","mask")==TBL_MASK &&
	GuestMember("CHashTable","body")==TBL_BODY &&
	GuestMember("CHashClass","member_lst_and_root")==CLASS_MEMBERS &&
	GuestMember("CMemberLst","next")==ML_NEXT &&
	GuestMember("CMemberLst","str")==ML_STR;
}

Bool GuestTblOk(U64 t)
{//Whether t can be a CHashTable: a mask of 2^n-1 and a body in RAM.
  U64 mask=GuestU64(t+TBL_MASK),body=GuestU64(t+TBL_BODY);
  return t && 0<mask<0x400000 && !(mask&(mask+1)) &&
	0<body<mem_size-(mask+1)*8;
}

Bool GuestTblChainOk(U64 t)
{//Whether t starts a chain of tables that ends.
  I64 n;
  for (n=0;n<16;n++) {
    if (!GuestTblOk(t))
      return FALSE;
    if (!GuestU64(t+TBL_NEXT))
      return TRUE;
    t=GuestU64(t+TBL_NEXT);
  }
  return FALSE;
}

I64 GuestTaskTbl(U64 task)
{//Takes a CTask's chain of tables: the member whose chain holds a class
//CTask that says that member is hash_table. Returns its offset, else 0.
  I64 off;
  for (off=8;off<4096;off+=8) {
    sym_tbl=GuestU64(task+off);
    if (GuestTblChainOk(sym_tbl) && GuestMlFind && GuestRecordsOk &&
	  GuestMember("CTask","hash_table")==off)
      return off;
  }
  sym_tbl=0;
  return 0;
}

Bool GuestSymInit(U64 task)
{//Finds Adam's table from task, else from any CTask in RAM.
  I64 off;
  U64 a;
  sym_class_base=0;
  if (!(off=GuestTaskTbl(task)))
    for (a=0;a<RAM_SIZE-16;a+=8)
      if (GuestU32(a+8)==TASK_SIGNATURE_VAL && GuestU64(a)==a &&
	    (off=GuestTaskTbl(a)))
	break;
  if (!off)
    return FALSE;
  sym_fun_exe=GuestMember("CHashFun","exe_addr");
  sym_fun_args=GuestMember("CHashFun","arg_cnt");
  sym_var_data=GuestMember("CHashGlblVar","data_addr");
  sym_export_val=GuestMember("CHashExport","val");
  if (sym_fun_exe<=0 || sym_fun_args<=0 || sym_var_data<=0 ||
	sym_export_val<=0)
    return FALSE;
  sym_class_base=GuestMember("CHashClass","base_class");
  a=GuestU64(GuestU64(GuestVar("adam_task"))+off);
  if (GuestTblChainOk(a))
    sym_tbl=a;
  return TRUE;
}

U64 GuestCallRet(U64 fun,U64 callee,I64 len)
{//Where fun goes on after its first direct call to callee, 0 if within len
//bytes it makes none.
  I64 i;
  U64 a;
  if (!fun || !callee)
    return 0;
  for (i=0;i<len;i++) {
    a=fun+i;
    if (a+5<mem_size && mem[a]==0xE8 &&
	  ((a+5+*(mem+a+1)(I32*))&0xFFFFFFFF)==callee)
      return a+5;
  }
  return 0;
}

#define DC_MEMBERS_NUM	23
#define TASK_MEMBERS_NUM	17

class CGuestDC
{//Offsets of the guest's CDC members HEMU reads, in dc_members's order.
  I64 width,width_internal,height,flags,color,bkcolor,dither_probability_u16,
	r,x,y,z,cur_x,cur_y,collision_cnt,nearest_dist,min_x,max_x,min_y,max_y,
	win_task,body,depth_buf,transform;
} of_dc;
U8 *dc_members[DC_MEMBERS_NUM]={"width","width_internal","height",
	"flags","color","bkcolor","dither_probability_u16","r","x","y","z",
	"cur_x","cur_y","collision_cnt","nearest_dist","min_x","max_x","min_y",
	"max_y","win_task","body","depth_buf","transform"};

class CGuestTask
{//Offsets of the guest's CTask members HEMU reads, in task_members's order.
  I64 wake_jiffy,task_flags,win_left,win_right,win_top,win_bottom,next_task,
	pix_left,pix_right,pix_top,pix_bottom,scroll_x,scroll_y,scroll_z,
	win_z_num,rand_seed,popup_task;
} of_task;
U8 *task_members[TASK_MEMBERS_NUM]={"wake_jiffy","task_flags",
	"win_left","win_right","win_top","win_bottom","next_task","pix_left",
	"pix_right","pix_top","pix_bottom","scroll_x","scroll_y","scroll_z",
	"win_z_num","rand_seed","popup_task"};

class CGuestAddr
{//Addresses of the guest's globals HEMU reads and writes.
  U64 ms_pos,ms_pos_text,ms_lb,ms_rb,ms_hard_installed,jiffies,
	winmgr_fps,winmgr_ideal_refresh_tS,winmgr_last_refresh_tS,
	gr_dc2,gr_win_z_buf,sys_winmgr_task,seth_task;
} guest;

#define D3_MEMBERS_NUM	3

class CGuestD3
{//Offsets in the guest's CD3I64, the mouse's pos and pos_text.
  I64 x,y,z;
} of_d3;
U8 *d3_members[D3_MEMBERS_NUM]={"x","y","z"};

Bool GuestMembersGet(U8 *cls,U8 **names,I64 cnt,I64 *_res)
{//Offsets of cnt members of cls into _res. FALSE if the class lacks one.
  I64 i;
  Bool res=TRUE;
  for (i=0;i<cnt;i++)
    if ((_res[i]=GuestMember(cls,names[i]))<0)
      res=FALSE;
  return res;
}

U64 GuestVarMember(U8 *var,U8 *cls,U8 *member)
{//Address of a member of a global, 0 if either is missing.
  U64 res=GuestVar(var);
  I64 off=GuestMember(cls,member);
  if (!res || off<0)
    return 0;
  return res+off;
}

Bool GuestNamesFind(U64 task)
{//Everything HEMU reads in the guest, from task's tables. FALSE if one
//is missing, and then HEMU only emulates.
  I64 seth;
  if (!GuestSymInit(task) ||
	!GuestMembersGet("CDC",dc_members,DC_MEMBERS_NUM,&of_dc.width) ||
	!GuestMembersGet("CTask",task_members,TASK_MEMBERS_NUM,
	&of_task.wake_jiffy) ||
	!GuestMembersGet("CD3I64",d3_members,D3_MEMBERS_NUM,&of_d3.x) ||
	(seth=GuestMember("CCPU","seth_task"))<0)
    return FALSE;
  guest.ms_pos=GuestVarMember("ms","CMsStateGlbls","pos");
  guest.ms_pos_text=GuestVarMember("ms","CMsStateGlbls","pos_text");
  guest.ms_lb=GuestVarMember("ms","CMsStateGlbls","lb");
  guest.ms_rb=GuestVarMember("ms","CMsStateGlbls","rb");
  guest.ms_hard_installed=
	GuestVarMember("ms_hard","CMsHardStateGlbls","installed");
  guest.jiffies=GuestVarMember("cnts","CCntsGlbls","jiffies");
  guest.winmgr_fps=GuestVarMember("winmgr","CWinMgrGlbls","fps");
  guest.winmgr_ideal_refresh_tS=
	GuestVarMember("winmgr","CWinMgrGlbls","ideal_refresh_tS");
  guest.winmgr_last_refresh_tS=
	GuestVarMember("winmgr","CWinMgrGlbls","last_refresh_tS");
  guest.gr_dc2=GuestVarMember("gr","CGrGlbls","dc2");
  guest.gr_win_z_buf=GuestVarMember("gr","CGrGlbls","win_z_buf");
  guest.sys_winmgr_task=GuestVar("sys_winmgr_task");
  guest.seth_task=g_cpu_st[0].f_msr_gsbase+seth;
  return guest.ms_pos && guest.ms_pos_text && guest.ms_lb && guest.ms_rb &&
	guest.ms_hard_installed && guest.jiffies && guest.winmgr_fps &&
	guest.winmgr_ideal_refresh_tS && guest.winmgr_last_refresh_tS &&
	guest.gr_dc2 && guest.gr_win_z_buf && guest.sys_winmgr_task;
}
