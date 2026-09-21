#!/bin/bash
# Collect real compiler artifacts for the hello_world learning note.
set -u
source /workspace/env.sh
cd /workspace/cutile-rs
rm -rf /root/dump /root/launchers
mkdir -p /root/dump /root/launchers

echo "===== JIT run with dumps ====="
CUTILE_DUMP=all CUTILE_DBG_DUMP_DIR=/root/dump CUTILE_JIT_LOG=1 CUTILE_JIT_TIMING=1 CUTILE_SETUP_DIAGNOSTICS=1 \
  cargo run -q -p cutile-examples --example hello_world > /root/run.stdout 2> /root/run.stderr
echo "exit=$?"
echo "----- stdout"
cat /root/run.stdout
echo "----- stderr line count: $(wc -l < /root/run.stderr)"
echo "----- stderr, lines that are not IR body"
grep -nvE '^\s+(%|assert|return|\})' /root/run.stderr | head -80
echo "----- dump dir"
ls -la /root/dump
for f in /root/dump/*; do
  echo "== $f ($(file -b "$f" | cut -c1-40))"
  if file -b "$f" | grep -qi text; then head -30 "$f"; else od -A x -t x1z -v "$f" | head -6; fi
done

echo "===== launcher dump ====="
touch cutile-examples/examples/hello_world.rs
DUMP_KERNEL_LAUNCHER_DIR=/root/launchers cargo build -q -p cutile-examples --example hello_world 2>&1 | tail -5
ls -la /root/launchers
for f in /root/launchers/*; do echo "== $f ($(wc -l < "$f") lines)"; head -150 "$f"; done

echo "===== MIR and LLVM IR ====="
cargo rustc -q -p cutile-examples --example hello_world -- --emit=mir,llvm-ir 2>&1 | tail -5
ls -la /root/target/debug/examples/ | grep -E 'hello_world.*\.(mir|ll)$'

echo "===== tileiras ====="
which tileiras
tileiras --help 2>&1 | head -60
echo "===== cuobjdump ====="
which cuobjdump nvdisasm
echo COLLECT_DONE
