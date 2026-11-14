#!/bin/bash
set -eu
cd "$(dirname "$0")/.."
node Kernel/Test/Chk.mjs "$@"
