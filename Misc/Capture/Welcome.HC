U8 *welcome_logo=FileRead("::/Home/Welcome.DAT");

U0 Welcome()
{
  WinHorz(22,59);
  WinVert(5,57);
  DocClear;
  StrCpy(Fs->task_name,"Welcome");
  "$$WW,1$$$$TX+CX,\"TempleOS\",D=\"DD_OS_NAME_VERSION\"$$\n\n"
	"$$TX+CX,\"Public Domain Operating System\"$$\n\n\n\n\n\n\n\n\n\n\n\n";
  Sprite(welcome_logo,"$$SP+CX,\"\",BI=%d$$");
  "\n\n\n\n\n\n\n\n\n\n\n$$TX+CX,\"God on Tap!\"$$\n\n"
	"      $$GREEN$$<F7>$$FG$$ Word\n"
	"$$GREEN$$<SHIFT-F7>$$FG$$ Passage\n"
	"      $$GREEN$$<F6>$$FG$$ Song\n"
	"$$GREEN$$<SHIFT-F6>$$FG$$ Doodle\n\n"
	"$$RED$$$$TX+CX,\"Trivial Solutions\"$$$$FG$$\n\n"
	"$$GREEN$$Tip of day$$FG$$\n";
  TipOfDay;
  "\n$$GREEN$$<SHIFT-ESC>$$FG$$ to exit.\n";
  LBts(&Fs->display_flags,DISPLAYf_WIN_ON_TOP);
  WinToTop;
  LBtr(&Fs->display_flags,DISPLAYf_WIN_ON_TOP);
  View;
}

CTask *welcome_task=Spawn(&SrvCmdLine,NULL,"Welcome",,Fs);
TaskExe(welcome_task,NULL,"WinFocus;Welcome;",
      1<<JOBf_EXIT_ON_COMPLETE|1<<JOBf_FREE_ON_COMPLETE);
