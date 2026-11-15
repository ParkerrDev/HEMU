# HEMU machine

The machine source is HolyC: CPU instructions, devices, memory, drawing,
JIT generation, snapshots and the guest bridge. `Host.HC` declares the host
calls needed to run it; `Test.HC` is its instruction self-test.

The [HolyC-wasm HEMU host](https://github.com/ParkerrDev/HolyC-wasm/tree/master/Apps/HEMU)
owns WebAssembly compilation, browser APIs, the desktop launcher and their
integration tests. HEMU contains no JavaScript source or generated JavaScript.

From the HEMU checkout with the pinned compiler mounted at `holyc-wasm/`:

```sh
sh Misc/Build.sh
sh Misc/Test.sh
sh Misc/Serve.sh
```

`Linux/HEMU.CPP` is the independent native KVM host. See [the guide](../Doc/Guide.md)
for the machine contract, native setup and capture provenance.
