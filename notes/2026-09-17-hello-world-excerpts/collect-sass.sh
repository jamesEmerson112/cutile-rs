#!/bin/bash
# Temporarily enable the on-disk JIT cache in hello_world, run it twice, and
# disassemble the cached cubin. The example file is restored afterwards.
set -u
source /workspace/env.sh
cd /workspace/cutile-rs
SRC=cutile-examples/examples/hello_world.rs
cp "$SRC" /root/hello_world.rs.bak
restore() { cp /root/hello_world.rs.bak "$SRC"; }
patch() { sed -i 's|    let device = Device::new(0)?;|    cutile::jit_cache::enable_default().expect("enable jit cache");\n    let device = Device::new(0)?;|' "$SRC"; }

patch
grep -n "enable_default" "$SRC"
rm -rf /root/.cache/cutile
echo "===== run 1 (disk cache miss) ====="
CUTILE_JIT_LOG=1 CUTILE_JIT_TIMING=1 cargo run -q -p cutile-examples --example hello_world > /root/run2.stdout 2> /root/run2.stderr
echo "exit=$?"
grep -iE 'jit|cache|setup' /root/run2.stderr | head -20
echo "===== run 2 (disk cache hit, new process) ====="
CUTILE_JIT_LOG=1 CUTILE_JIT_TIMING=1 cargo run -q -p cutile-examples --example hello_world > /root/run3.stdout 2> /root/run3.stderr
echo "exit=$?"
grep -iE 'jit|cache|setup' /root/run3.stderr | head -20
grep Hello /root/run3.stdout
restore
git status --short

echo "===== cache files ====="
find /root/.cache -type f 2>/dev/null | head
f=$(find /root/.cache /tmp /workspace -name '*.cubin' -mmin -10 2>/dev/null | head -1)
echo "entry file: $f ($(stat -c %s "$f") bytes)"
off=$(grep -abo $'\x7fELF' "$f" | head -1 | cut -d: -f1)
echo "ELF offset in entry: $off"
tail -c +$((off+1)) "$f" > /root/hello_world.cubin
file /root/hello_world.cubin
ls -la /root/hello_world.cubin
echo "===== cuobjdump -sass ====="
cuobjdump -sass /root/hello_world.cubin > /root/hello_world.sass 2>&1
wc -l /root/hello_world.sass
head -140 /root/hello_world.sass
echo "===== cuobjdump -elf symbols ====="
cuobjdump -elf /root/hello_world.cubin 2>&1 | grep -iE 'arch|sm_|hello' | head -10
echo SASS_DONE
