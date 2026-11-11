I64 kbd_q[64],kbd_qh,kbd_qt,kbd_cmd,kbd_type,kbd_prefix,kbd_pause,
      kbd_repeat_key,kbd_repeat_ns;
Bool kbd_repeat;

U0 KbdRst()
{//The stock snapshot's HomeLocalize selected KbdTypeMatic(0).
  kbd_qh=kbd_qt=0;
  kbd_cmd=kbd_type=kbd_prefix=kbd_pause=0;
  kbd_repeat_key=0;
  kbd_repeat_ns=0;
  kbd_repeat=FALSE;
}

U0 KeyPut(I64 sc)
{
  if (kbd_qt-kbd_qh<64) {
    kbd_q[kbd_qt&63]=sc&0xFF;
    kbd_qt++;
    pic1_irr|=2;
  }
}

I64 KbdDelay()
{
  I64 n=kbd_type>>5;
  n&=3;
  return (n+1)*250000000;
}

U0 KbdRptSet(Bool on)
{
  kbd_repeat=on;
  kbd_repeat_ns=tsc+KbdDelay;
}

U0 InjectKey(I64 sc)
{//Raw set-1 bytes. Physical key timing affects IRQs, never the clock.
  I64 key;
  sc&=0xFF;
  KeyPut(sc);
  if (kbd_pause)
    kbd_pause--;
  else if (sc==0xE1) {
    kbd_pause=5;
    kbd_prefix=0;
  } else if (sc==0xE0)
    kbd_prefix=0x100;
  else {
    key=sc&0x7F|kbd_prefix;
    kbd_prefix=0;
    if (sc&0x80) {
      if (key==kbd_repeat_key) kbd_repeat_key=0;
    } else if (key!=0x1D && key!=0x2A && key!=0x36 && key!=0x38 &&
	  key!=0x11D && key!=0x138 && key!=0x12A && key!=0x136 &&
	  key!=0x15B && key!=0x15C && key!=0x15D && key!=0x137 &&
	  key!=0x3A && key!=0x45 && key!=0x46) {
      kbd_repeat_key=key;
      kbd_repeat_ns=tsc+KbdDelay;
    }
  }
}

U0 KbdTick()
{//The last typematic key repeats at the guest's programmed PS/2 rate.
  I64 period;
  if (!kbd_repeat || !kbd_repeat_key)
    return;
  period=kbd_type&7;
  period+=8;
  period<<=kbd_type>>3&3;
  period=period*NS_SEC/240;
  while (tsc>=kbd_repeat_ns && kbd_qt-kbd_qh<62) {
    if (kbd_repeat_key&0x100) KeyPut(0xE0);
    KeyPut(kbd_repeat_key&0x7F);
    kbd_repeat_ns+=period;
  }
}
