# Raw dumps behind "hello_world, Annotated"

Everything the note `../2026-09-17-hello-world-terminology.html` quotes as
"real" came from these files. They were produced on the RunPod pod
`8de3dwrfg299ot` (RTX PRO 4000 Blackwell, compute capability 12.0, CUDA
13.3, Rust stable) on 2026-09-17 and 2026-09-18 UTC, with the repo at commit
`b028b5f` on branch `test/hello-world-grid` (the example's grid set to
`(2, 2, 1)`). The pod was stopped on 2026-09-18, so the originals under its
`/root` disk are gone; these copies are the record.

| File | What it is | Produced by |
|---|---|---|
| `tile-ir-and-bytecode.txt` | stderr of one run: setup diagnostics, JIT log, the Tile IR dump, the decoded bytecode dump, and the timing line | `CUTILE_DUMP=all CUTILE_JIT_LOG=1 CUTILE_JIT_TIMING=1 CUTILE_SETUP_DIAGNOSTICS=1 cargo run -p cutile-examples --example hello_world` |
| `run-output.txt` | stdout of the same run: the generated entry wrapper and IR that `print_ir = true` prints, then the four hello lines in the order the GPU produced them | same command |
| `generated-launcher.txt` | the complete Rust the `#[cutile::module]` macro generated for the entry (launcher struct, builder methods, `DeviceOp` impl) | `DUMP_KERNEL_LAUNCHER_DIR=/root/launchers cargo build -p cutile-examples --example hello_world` |
| `main.mir.txt` | rustc's MIR for `fn main` only, cut from the 108 KB whole-crate dump | `cargo rustc -p cutile-examples --example hello_world -- --emit=mir` then `awk '/^fn main/,/^}/'` |
| `main.llvm-ir.txt` | the LLVM IR for `main` only, cut from the 1.8 MB whole-crate dump | `--emit=llvm-ir` then `awk '/^define .*hello_world4main/,/^}/'` |
| `embedded-source-string.txt` | the first 240 characters after `cutile::entry` in the LLVM IR file: the module's source text as a string constant in the binary | `grep -oE 'cutile::entry.{0,240}' hello_world-*.ll` |
| `sass-excerpt.txt` | the head of `cuobjdump -sass` on the cached cubin, mnemonics only, plus the register-read lines for `program_id` | see `collect-sass.sh`; retyped from the terminal log because the pod was stopped before the file was copied |
| `disk-cache-runs.txt` | JIT log and timing lines from two separate processes with the disk cache enabled: a miss (tileiras) and a hit (disk), plus the cache entry's location and layout | `collect-sass.sh` |
| `collection-log.txt` | the full terminal log of `collect-excerpts.sh`, including the launcher listing and `tileiras --help` | `collect-excerpts.sh` |
| `collect-excerpts.sh`, `collect-sass.sh` | the two scripts that produced all of the above; runnable on any bootstrapped pod from `/workspace/cutile-rs` on the same branch | |

`collect-sass.sh` temporarily inserts
`cutile::jit_cache::enable_default().expect("enable jit cache");` as the
first line of `main`, runs the example twice, and restores the file. The
cache entry it reads is not a bare cubin: 312 bytes of header (magic, format
version, SHA-256 of the payload, GPU name, `tileiras` fingerprint) precede
the ELF, which is why the script searches for the ELF magic before handing
the bytes to `cuobjdump`.
