# Prepared native captures

The stock desktop is prepared once in native TempleOS. Browser startup does
not compile corrections or construct the Welcome window. Run the commands below
from the HEMU root with its pinned compiler at `holyc-wasm/`.

```sh
python3 Misc/Capture/Capture.py --cores 1 --disk templeos-hd.qcow2.gz \
  --font holyc-wasm/src/runtime/font.js --out /tmp/stock-one
python3 Misc/Capture/Capture.py --cores 4 --disk templeos-hd.qcow2.gz \
  --font holyc-wasm/src/runtime/font.js --out /tmp/stock-four
python3 Misc/Pack.py --base templeos-hd.qcow2.gz \
  --one /tmp/stock-one --four /tmp/stock-four --out /tmp/stock-package
```

The output directories must not exist. Use a disk-backed TMPDIR when memory
is limited. The original base disk is never changed. Prepare.mjs verifies the
compressed native files and the corresponding source copies by SHA-256,
then changes only the private capture disk. Original contains exact V5.03
source, independently decoded from that disk using Terry's Linux/TOSZ.

DocClip.HC supplies document sprite bounds; ACDblBuf.HC keeps AutoComplete's
shown document intact while its next document is filled. Prepare.mjs changes
the native routines in place before the normal OS compiler runs. There are
no replacement entry jumps, runtime patch installers or patch-state flags.
The .HC.Z files use TempleOS's CT_NONE container; the outer disk compression
compresses their bytes. Native includes prefer .HC.Z, so an uncompressed
sibling would not replace the original.

Welcome.HC starts an independent native task after the normal HomeSys
startup and raises it above AutoComplete once, using the native on-top group.
It then returns to normal window priority so other apps can come forward.
The original terminal still asks Take Tour(y or n)?. Capture waits
until both the card and that question have been drawn, then stops all CPUs
with empty x87 stacks and records RAM, disk and registers. The strict register
parser also checks the supported CPU topology, flat long mode, interrupt
shadow, MXCSR and shared system registers. Preparation inputs, installed
source bytes and captured artifacts are hash-bound in evidence.json.

`Pack.py` passes each flat captured RAM image through `Misc/Ram.py` before
gzip compression. The `HMRAM001` payload stores adjacent nonzero 64-byte blocks
as offset/length ranges, followed by their bytes. Omitted blocks are all zero;
expansion reconstructs the original 384 MiB byte for byte. `stock.json` binds
both the compressed payload and full RAM hashes, and records `packedBytes`
for bounded decompression. `Kernel/Ram.js` validates and restores those ranges
in the browser. The native Linux installer uses `Misc/Ram.py` to expand the
same file into its flat `RAM.BIN`.

This packaging step reduces bytes inflated and copied on a first visit. It
uses one gzip stream over the sparse payload; there are no per-snapshot gzip
cut tables or parallel inflate workers to regenerate. Native capture evidence
continues to describe the full RAM image before packing.

This captures supported CPU state, not every QEMU device. HEMU initializes
PIC, PIT and RTC under its startup policy. Full .hemu saved machines use their
own CPU/device state and preserve their existing windows and code.

Welcome.DAT is Terry Davis's public-domain sword-and-scales bitmap from
Doc/Splash1.DAT in the 2014-07-15 archive:
https://github.com/Francesco149/TempleOSGit/tree/a843cc86431af8ef59a396e50cb7c314f65a2430

That archive labels its card V2.11; the graphic also appears in the supplied
V2.17 video. Its 19,456 pixels and terminating zero are unchanged. Only the
serialized header order changes from type,width,height,x,y to V5.03's
type,x,y,width,height. Welcome displays the running OS version.

Probe.py is the independent native XMM/x87 register-order witness. It boots
the unprepared original disk and injects Test/Xmm.HC in a private copy.
Use --occupied to verify rejection of an occupied x87 stack and --record to
refresh its source-bound fixtures. It does not alter the stock desktop.
