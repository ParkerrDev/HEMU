# Prepared native captures

The stock desktop is prepared once in native TempleOS. Browser startup does
not compile corrections or add startup windows. Run the commands below
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

The original terminals and AutoComplete start normally. The first terminal
still asks Take Tour(y or n)?. Capture waits until that question and the
native tip of the day have been drawn, then stops all CPUs
with empty x87 stacks and records RAM, disk and registers. The strict register
parser also checks the supported CPU topology, flat long mode, interrupt
shadow, MXCSR and shared system registers. Preparation inputs, installed
source bytes and captured artifacts are hash-bound in evidence.json.

`Pack.py` passes each flat captured RAM image through `Misc/Ram.py` before
gzip compression. The `HMRAM001` payload stores adjacent nonzero 64-byte blocks
as offset/length ranges, followed by their bytes. Omitted blocks are all zero;
expansion reconstructs the original 384 MiB byte for byte. `stock.json` binds
both the compressed payload and full RAM hashes, and records `packedBytes`
for bounded decompression. `holyc-wasm/Apps/HEMU/Kernel/Ram.js` validates and restores those ranges
in the browser. The native Linux installer uses `Misc/Ram.py` to expand the
same file into its flat `RAM.BIN`.

This packaging step reduces bytes inflated and copied on a first visit. It
uses one gzip stream over the sparse payload; there are no per-snapshot gzip
cut tables or parallel inflate workers to regenerate. Native capture evidence
continues to describe the full RAM image before packing.

This captures supported CPU state, not every QEMU device. HEMU initializes
PIC, PIT and RTC under its startup policy. Full .hemu saved machines use their
own CPU/device state and preserve their existing windows and code.

Probe.py is the independent native XMM/x87 register-order witness. It boots
the unprepared original disk and injects Test/Xmm.HC in a private copy.
Use --occupied to verify rejection of an occupied x87 stack and --record to
refresh its source-bound fixtures. It does not alter the stock desktop.
