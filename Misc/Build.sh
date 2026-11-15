#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
export HEMU_ROOT="$PWD"
exec node holyc-wasm/Apps/HEMU/Kernel/Build.mjs "$@"
