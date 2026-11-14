#define MMIO_HPET	0xFED00000
#define MMIO_LAPIC	0xFEE00000

U64 MmioRd(U64 a,I64)
{//Saved guests use uncached device aliases; match the device's page.
//The VGA window shares the alias, so its pixels are not registers.
  U64 page=a&0xFFFFF000,off=a&0xFFF;
  if (page==MMIO_LAPIC) {
    if (off==0x20)
      return MyCore<<24;
    if (off==0x30)
      return 0x50014;
  } else if (page==MMIO_HPET) {
    if (off==0xF0)
      return hpet_ctr;
    if (off==0xF4 || off==0xF8)
      return hpet_ctr>>32;
  }
  return 0;
}

U0 MmioWr(U64 a,I64,U64 v)
{//Publish the sender's prior writes before waking the destination core.
//Only the LAPIC's ICR sends an IPI. Stores past RAM elsewhere, such as
//the VGA planes through the uncached alias, are not device writes.
  U64 page=a&0xFFFFF000,off=a&0xFFF;
  I64 dest,dm;
  if (page!=MMIO_LAPIC) return;
  if (off==0x310) {
    g_icr_high[MyCore]=v;
    return;
  }
  if (off==0x300) {
    dest=g_icr_high[MyCore]>>24;
    dm=v>>8&7;
    if (!dm && 0<=dest<g_ncore && dest!=MyCore)
      __a_xchg64(&g_ipi_pending[dest],v&0xFF|0x100);
  }
}

U64 RdMem(U64 a,I64 sz)
{//TempleOS aliases RAM at 2^40; devices outside it retain MMIO routing.
  if (a>=mem_size) {
    a&=0xFFFFFFFFFF;
    if (a>=mem_size)
      return MmioRd(a,sz);
  }
  if (sz==8)
    return *(mem+a)(U64*);
  if (sz==4)
    return *(mem+a)(U32*);
  if (sz==2)
    return *(mem+a)(U16*);
  return mem[a];
}

U0 WrMem(U64 a,I64 sz,U64 v)
{//Unaligned little-endian RAM accesses match x86 and WASM loads/stores.
  if (a>=mem_size) {
    a&=0xFFFFFFFFFF;
    if (a>=mem_size) {
      MmioWr(a,sz,v);
      return;
    }
  }
  if (sz==8)
    *(mem+a)(U64*)=v;
  else if (sz==4)
    *(mem+a)(U32*)=v;
  else if (sz==2)
    *(mem+a)(U16*)=v;
  else
    mem[a]=v;
}
