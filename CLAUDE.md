# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

cuTile Rust (`cutile-rs`) lets you write memory-safe, data-race-free GPU kernels in idiomatic Rust. The `#[cutile::module]` proc macro captures each kernel's Rust AST into the host binary, and at first launch the JIT compiles that AST through CUDA Tile IR into a cubin. It is a Cargo workspace at version 0.4.0 whose intra-workspace dependencies are exact-pinned (`=0.4.0`) so the macro, compiler, and runtime always ship in lockstep.

This checkout is a personal fork of NVIDIA's research project, not the upstream repo. `origin` is `jamesEmerson112/cutile-rs` and `upstream` is `NVlabs/cutile-rs`. The fork's `main` is upstream's `main` plus a few fork-only files: this `CLAUDE.md` and the `pod/` directory. See "Fork workflow" below before committing, pushing, or relying on CI.

Requirements from the README: Rust stable 1.89+ (no nightly needed), CUDA 13.2+ for the Tile stack with 13.3 recommended, and an `sm_80`+ GPU. The shared host-side crates (`cuda-bindings`, `cuda-core`, `cuda-async`) support CUDA 13.0+. The toolkit is located via `CUDA_TOOLKIT_PATH`, then `CUDA_HOME`, then standard install paths.

## Commands

The CI `build` job in `.github/workflows/pr.yml` runs these in order, so run the same set before opening a PR:

```bash
cargo build
cargo fmt -- --check
cargo clippy --workspace --exclude cuda-tile-rs --all-targets --all-features
cargo test --no-run
./scripts/run_cpu_tests.sh
```

`clippy::all` is `deny` at the workspace level (allowlist in the root `Cargo.toml`), so warnings fail CI. Other CI lanes: `cargo deny check` (licenses and advisories, `deny.toml`), `cargo semver-checks --workspace --exclude cuda-tile-rs --exclude cutile-examples --exclude cutile-benchmarks` (a breaking public API change must ship with a version bump), and `cargo check -p cuda-bindings -p cuda-core -p cuda-async --all-targets` against CUDA 13.0.

Never run a bare `cargo build --workspace` or `cargo test --workspace`. `cuda-tile-rs` is excluded from `default-members` because its `build.rs` downloads and compiles LLVM (tens of minutes, several GB). Build it only on purpose with `cargo build --release -p cuda-tile-rs`, ideally with `CUDA_TILE_RS_CACHE=1` so the artifacts survive `cargo clean`.

### Tests

The CPU/GPU split is defined by the scripts, not by crate. `scripts/run_cpu_tests.sh` lists exactly which test targets are driver-free; `scripts/run_gpu_tests.sh` lists the rest. Three `cutile` targets are mixed and are split by test-name prefix: `compile_*` cases are CPU-only and `execute_*` cases need a GPU (`control_flow_ops`, `tensor_and_matrix_ops`, `type_conversion_ops`). CPU tests still need CUDA headers and, for the IR-to-cubin lowering tests, the `tileiras` binary.

```bash
# One integration test target, optionally filtered by name
cargo test -p cutile --test basics_and_inlining
cargo test -p cutile --test control_flow_ops compile_

# Targets that need the experimental-tune feature (lib tests, autotune, do_bench)
cargo test -p cutile --lib --features experimental-tune

# GPU aggregate target: modules under cutile/tests/gpu/ registered in tests/gpu.rs
cargo test -p cutile --test gpu

# Compile-fail (trybuild) tests; regenerate .stderr after an intentional diagnostic change
cargo test -p cutile --test ui
TRYBUILD=overwrite cargo test -p cutile --test ui

# Other crates
cargo test -p cutile-ir            # pure Rust; tileiras checks self-skip when it is absent
cargo test -p cutile-compiler
cargo test -p cuda-async           # unit tests, doctests, and error_handling are host-only

# Everything (CPU + GPU + examples + benchmark smoke), what CONTRIBUTING asks for before review
./scripts/run_all.sh
```

Reactor verification for `cuda-async` is opt-in and nightly-only: `RUSTFLAGS="--cfg loom" cargo test -p cuda-async --lib loom_` and `cargo miri test -p cuda-async --lib slot_table`. To force GPU tests through the reactor instead of the inline spin, set `CUDA_ASYNC_SPIN_BUDGET_US=0`; `CUDA_ASYNC_HOST_SYNC=spin|block` selects the host-callback fallback. `cuda-async/tests/device_fault.rs` deliberately faults the CUDA context, which is why it holds one test and runs as its own process.

### Examples, benchmarks, book

```bash
cargo run -p cutile-examples --example hello_world      # toolchain check
cargo run -p cutile-examples --example saxpy
cargo run -p cutile-examples --example autotune --features experimental-tune
./scripts/run_examples.sh                                # every example, GPU

cargo bench -p cutile-benchmarks                         # criterion, saves baselines
cargo bench -p cutile-benchmarks -- softmax
./scripts/test_benchmarks.sh                             # smoke-test feature, results discarded
./cutile-benchmarks/scripts/setclock.sh                  # lock GPU clocks first for reproducible numbers

scripts/run_book.sh serve|build|setup                    # Sphinx book in cutile-book/, Python venv
scripts/build_versioned_book.sh                          # the GitHub Pages build, output in _site/
cargo doc --open
```

### Debugging knobs

- `CUTILE_DUMP=ir`, `bytecode`, or `all` prints the compiler output to stderr once per module; `CUTILE_DUMP_FILTER` narrows it and `CUTILE_DBG_DUMP_DIR` writes to files.
- `CUTILE_JIT_LOG=1` logs JIT cache decisions; `CUTILE_JIT_TIMING` prints compile timing and bounds-check placement counts.
- `CUTILE_SETUP_DIAGNOSTICS=1` prints toolkit and `tileiras` discovery. `CUTILE_TILEIRAS_PATH` forces a binary; `CUTILE_BYTECODE_VERSION` (`13.2` or `13.3`) forces the emitted bytecode version.
- `CUTILE_FORCE_DEVICE_CHECKS` and `CUTILE_DISABLE_CHECK_HOISTING` alter where bounds checks land.
- Macro side: `DUMP_KERNEL_LAUNCHER_DIR=temp` dumps generated launchers; `cargo expand -p cutile --lib` shows rustc-facing expansion (which the JIT never sees, see below).

## Architecture

### Crate layering

Bottom-up: `cuda-bindings` (bindgen FFI generated at build time, dynamic `libcuda` loading) → `cuda-core` (safe wrapper: contexts, streams, modules, VMM, `simt/` subtree carried over from cuda-oxide; `cuda-core-derive` provides `DeviceCopy`) → `cuda-async` (lazy `DeviceOp` DAGs, `SchedulingPolicy` stream mapping, completion reactor, CUDA graph capture) → `cutile-compiler` (the JIT) → `cutile-macro` (proc macro) → `cutile` (user-facing crate) → `cutile-kernels`, `cutile-examples`, `cutile-benchmarks`. `cutile-ir` stands alone: a pure-Rust Tile IR builder and bytecode writer that replaced the old melior/MLIR dependency, consumed by `cutile-compiler`.

### The two-track design of `#[cutile::module]`

This is the single most important thing to understand before touching the macro or the compiler.

1. The macro emits Rust that only rustc consumes: per-rank specializations of const-generic-array (CGA) items (`Tile<E, const D: [i32; N]>` becomes `Tile_0..Tile_6` with `D_0, D_1, ...`), shadow traits for `#[cuda_tile::variadic_op]` functions so user code calls the unsuffixed name and resolves through trait dispatch, and host-side launchers for `#[cutile::entry]` functions. This exists to type-check kernel bodies and give good errors.
2. Separately, the macro captures the pre-expansion source text via `Span::source_text()` into a generated `__module_ast_self()` and registers it in the `CUTILE_MODULES` `linkme` distributed slice. At runtime the JIT re-parses that original generic source and does its own rank instantiation.

Consequences: `cargo expand` output is irrelevant to JIT behaviour, so reason from the user's source. New DSL language features (user structs, methods, control flow) belong in `cutile-compiler`, not the macro; the macro only has to handle the Rust patterns that appear in op signatures in `cutile/src/_core.rs`. The registry matches string module paths and cannot follow `pub use` re-exports, so every re-exported cuTile module needs a hand-written alias entry (see the `cutile::core` and `cutile::tileir` entries in `cutile/src/lib.rs`).

### JIT pipeline (`cutile-compiler`)

`CUDATileModules::from_kernel` walks the kernel's `use` statements against the registry to gather dependency modules. Then `passes/` runs name resolution once per module and proof analysis, node IDs, DSL-narrow type inference, and typed dispatch lowering per `#[entry]` body (documented in `passes/mod.rs`). `compiler/compile_*.rs` emits a `cutile_ir::Module`; call dispatch is: a `#[cuda_tile::op]` function emits a Tile IR op, a `#[cuda_tile::compiler_op]` function goes to `compile_intrinsic.rs`, and any other function is inlined. The module is serialized to bytecode (version negotiated per toolkit between 13.2 and 13.3), handed to the `tileiras` subprocess, and the cubin is loaded with `cuModuleLoadData`.

Kernel caching has two layers. The in-memory cache in `cutile/src/tile_kernel.rs` is keyed per specialization (generics, strides, specialization bits, target) and is process-global, which is why cache-state tests hold `common::cache_test_lock()`. The on-disk cache in `cutile-compiler/src/jit_cache.rs` is content-addressed (SHA-256 of bytecode plus target, opt level, and the `tileiras` fingerprint), off by default, and has no env-var switch: callers opt in with `cutile::jit_cache::enable_default()`. `compile_api::KernelCompiler` compiles a kernel to IR and bytecode with no GPU or driver, which is what the CPU test suite uses.

### The DSL surface (`cutile/src/_core.rs`)

Every op the kernel DSL exposes is declared here with `#[cuda_tile::ty]`, `#[cuda_tile::op]`, or `#[cuda_tile::compiler_op]` annotations; `op` and `compiler_op` bodies are `unreachable!()` because the JIT reads their signatures rather than executing them. Parameter names are load-bearing: the annotations reference them by name (`params=`, `output_type_params=`), so renaming a parameter silently breaks codegen. Marker zero-sized-type modules (`ftz`, `rounding`, `padding`, `dim_map`, and so on) live outside the macro-processed module because the macro cannot nest `mod` items. `cutile/ARCHITECTURE.md` is the full reference for how type params, constructor ops, and intrinsics connect.

### Ownership across the launch boundary

`&mut Tensor` kernel parameters take a `Partition` (owned `Partition<Tensor<T>>` or borrowed `Partition<&mut Tensor<T>>`), and each thread block gets a disjoint tile. `&Tensor` parameters accept `Tensor`, `Arc<Tensor>`, or `&Tensor` and return the same form. Launchers return every argument in parameter order. Everything is a lazy `DeviceOp` until `.sync()`, `.sync_on(&stream)`, or `.await`. A `.then()` closure runs under a per-thread execution lock and may not itself sync or await another op. The launch grid is the ceiling division of shape by partition shape per axis; partial edge tiles are bounds-checked or padded, not rejected. Dropping an in-flight future waits for its stream to drain rather than freeing memory under a running kernel.

### Test layout conventions

- Each file in `cutile/tests/*.rs` is its own target. When adding a target, add it to the right script (`run_cpu_tests.sh` or `run_gpu_tests.sh`) or CI will not run it.
- GPU smoke tests for kernel patterns live as modules under `cutile/tests/gpu/` and are registered with `#[path]` in `tests/gpu.rs`.
- `cutile/tests/ui/` holds trybuild compile-fail cases paired with `.stderr` files; `tests/ui.rs` lists them.
- `cutile/tests/common/mod.rs` provides `with_test_stack` (8 MB stack, the compiler recurses deeply) and `compile_to_ir` helpers.

## Conventions

- Every source file starts with the NVIDIA SPDX copyright and `Apache-2.0` header.
- Every crate uses `[lints] workspace = true`; add lint exceptions to the root `Cargo.toml` with a comment explaining why, as the existing ones do.
- Bump all `=0.4.0` pins together; the crate family is lockstep by design (a floating pin broke downstream candle CI in 0.3.x).
- `CHANGELOG.md` follows Keep a Changelog with an `[Unreleased]` section; breaking changes are called out explicitly.
- Upstream's rules, worth following on the fork so work stays upstreamable: branches are `type/short-desc` and PR titles are `type: lowercase desc` with types `feat`, `fix`, `doc`, `refactor`, `perf`, `test`, `ci`, `chore`. Upstream requires DCO sign-off on every commit (`git commit -s`), so sign off anything that might become an upstream PR.
- `cutile-kernels`, `cutile-examples`, and `cutile-benchmarks` are `publish = false`.

## Fork workflow

- `main` carries the fork-only files on top of upstream, so sync it with `git fetch upstream && git merge upstream/main && git push origin main`. Do experiments on branches off `main`. For anything meant to go upstream, branch from `upstream/main` instead so `CLAUDE.md` and `pod/` never end up in the PR.
- Upstream's main CI job (`pr.yml`) never runs on this fork: it triggers only on `pull-request/N` branches that NVIDIA's copy-pr-bot creates in the upstream repo, and its jobs need NVIDIA's self-hosted `linux-amd64-cpu16` runners. Only `cargo-deny`, `codeql`, and `pages` trigger on pushes to the fork's `main` (on `ubuntu-latest`), and `pages` will try to deploy GitHub Pages on every such push. No workflow had run on the fork as of 2026-09-16. Treat the command list under "Commands" as the CI substitute and run it on a GPU host.
- To contribute upstream, push a branch to `origin` and open the PR against `NVlabs/cutile-rs:main`; copy-pr-bot then mirrors it into a `pull-request/N` branch where the real CI runs.
- Do not edit the CI workflows, `copy-pr-bot.yaml`, or `dependabot.yml` for the fork's convenience; those files are upstream's and changing them creates merge noise on every sync.

## Environments

### This Windows checkout (editing and CPU-only checks)

This machine has CUDA 13.0 at `C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.0`, no `tileiras`, and a GeForce GTX 1070 Ti (`sm_61`, below the `sm_80` floor). The Tile stack therefore cannot JIT or run kernels here, and every GPU test, example, and benchmark will fail. What does work locally: the full default workspace should compile (the compiler's `build.rs` only warns below 13.2), `cargo check -p cuda-bindings -p cuda-core -p cuda-async --all-targets` (the CI CUDA 13.0 lane), `cargo test -p cutile-ir`, and the driver-free CPU test targets that do not lower to a cubin. Because the default Windows search only probes the v13.3 and v13.2 install directories, set `CUDA_TOOLKIT_PATH` to the v13.0 directory (for example in a gitignored `.cargo/config.toml`). `ssh` is available from Git Bash; `rsync` is not.

### RunPod GPU pod (all GPU work)

The user runs a RunPod pod for exploring and learning this project. Everything that needs a GPU or `tileiras` (examples, `run_gpu_tests.sh`, benchmarks, `run_all.sh`) runs there. The user is new to SSH; explain commands rather than assuming familiarity.

Pod facts (second pod, 2026-09-17, ID `8de3dwrfg299ot`; the first was `y2qncqk1awx1ri` the day before with the same specs): NVIDIA RTX PRO 4000 Blackwell, compute capability 12.0 (`sm_120`), driver 580.x, Ubuntu 22.04, 48 cores, 125 GB RAM. The stock image ships only CUDA 12.4 with no `tileiras`, so the CUDA 13.3 toolkit is installed by the setup script below. `/` is a 20 GB container disk that RunPod wipes whenever the pod stops; `/workspace` is a persistent network volume (`euro-3`) that must be attached at pod creation. On the first pod swap the volume kept Rust, the env file, logs, and the Claude config, but `/workspace/cutile-rs` came back as an empty directory; cause unknown, and the bootstrap reclones it, so treat the pod clone as disposable and keep anything valuable committed and fetched to this checkout.

Reach it with `ssh runpod`, or run one command with `ssh runpod '<command>'`. The `Host runpod` entry in `~/.ssh/config` holds the "SSH over exposed TCP" address and port from the pod's Connect panel (`User root`, `IdentityFile ~/.ssh/id_ed25519`); those change when the pod is recreated, so update that entry rather than these docs. Copy files with `scp <file> runpod:<path>`; piping a file over `ssh` stdin from the Bash tool does not work, and there is no `rsync` on the Windows side. The proxy form `ssh <pod-id>-<n>@ssh.runpod.io` also works but cannot copy files.

The user works on the pod through VS Code Remote-SSH (the `runpod` host appears in its picker because it reads the same config file) with the folder `/workspace/cutile-rs` open, and runs Claude Code inside that remote window as well. This local session can still run pod commands over `ssh runpod`. Edits made on the pod are not visible to this local checkout until they are pushed and pulled.

Bootstrap and persistent layout:

- `pod/setup-pod.sh` in this repo is the source of truth for pod setup, and the copy at `/workspace/setup-pod.sh` is just a copy. It is idempotent: it reinstalls apt packages and the CUDA 13.3 toolkit (toolkit only, never the driver, 13.2 as fallback), installs Rust into `/workspace/.rustup` and `/workspace/.cargo` only if missing, installs Claude Code, writes `/workspace/env.sh`, hooks it into `/root/.bashrc`, sets the git identity in `/workspace/.gitconfig`, and clones the fork to `/workspace/cutile-rs` with the `upstream` remote. Its log ends with `SETUP_DONE`. Never overwrite it on the pod while a run is in progress.
- `env.sh` exports `CUDA_TOOLKIT_PATH`, `RUSTUP_HOME`, `CARGO_HOME`, `GIT_CONFIG_GLOBAL`, `CLAUDE_CONFIG_DIR` (all on `/workspace` so the Claude login survives), and `CARGO_TARGET_DIR=/root/target`. The target dir is deliberately on the ephemeral local disk because `/workspace` is a network filesystem and builds there are slow; expect a full rebuild after each restart. Non-interactive `ssh runpod '<command>'` does not read `.bashrc`, so prefix commands with `source /workspace/env.sh &&`.
- Live feedback goes through a shared `tmux` session named `pod`, created by the bootstrap with `/workspace/env.sh` already sourced and `/workspace/cutile-rs` as its directory. The user watches it from any local terminal with `ssh -t runpod tmux attach -t pod` and detaches with Ctrl+B then D (closing the window also just detaches; the session keeps running). Run anything the user should see, or anything long, inside it: `ssh runpod "tmux send-keys -t pod '<command>' Enter"`. Everything the session prints is also appended to `/workspace/pod-session.log`, so to collect a result, send `<command>; echo DONE_<tag>` and poll that log for the marker, or read `tmux capture-pane -t pod -p` for the current screen. The log also contains the echoed command line itself, so a naive `grep DONE_<tag>` matches immediately; filter with `grep -v 'echo DONE'` (or check that no `cargo` process is left) before treating the marker as completion. Mouse-wheel scrolling is enabled. If the session is missing (pod restart), re-run the bootstrap.
- One-time login, needed only when `/workspace` is new: run `claude` once on the pod and follow the URL flow. It persists on `/workspace`.
- The pod has no GitHub credentials on purpose. The local checkout has the pod's clone registered as a git remote named `pod` (`ssh://runpod/workspace/cutile-rs`, which rides on the same SSH alias, so it survives pod recreation unchanged). To get work off the pod: commit there, then locally run `git fetch pod`, merge or check out `pod/<branch>`, and push to `origin` from here. To get work onto the pod: push to `origin` from here, then `git pull` on the pod (the fork is public, so pulling needs no login). Never push into `pod` directly; pushing into a checked-out branch of a non-bare repo is refused.

`pod/README.md` is the same procedure written for the user to follow alone, without Claude; keep the two in sync when either changes.

New pod checklist (a new pod is likely on most days):

1. When creating the pod, attach the same network volume so `/workspace` comes back with Rust, the clone, and the Claude login. Without it, everything is rebuilt from scratch and the Claude login is needed again.
2. Copy the "SSH over exposed TCP" address and port from the pod's Connect panel into the `Host runpod` entry in `~/.ssh/config`. If the user pastes the panel, Claude does this.
3. First connection prompts for the host fingerprint; from this session use `ssh -o StrictHostKeyChecking=accept-new runpod true` to accept it.
4. Bootstrap: `scp pod/setup-pod.sh runpod:/workspace/setup-pod.sh`, then `ssh runpod '(nohup bash /workspace/setup-pod.sh > /workspace/setup-pod.log 2>&1 < /dev/null &)'` and poll the log for `SETUP_DONE`. Copying from this checkout works whether or not the volume came back and whether or not `pod/` has been pushed. Once `pod/` is on the fork's `main`, a bare pod can also fetch it directly: `curl -fsSL https://raw.githubusercontent.com/jamesEmerson112/cutile-rs/main/pod/setup-pod.sh | bash`. Expect about five minutes with the volume, mostly the CUDA download, and a few more without it.
5. Reconnect VS Code Remote-SSH to `runpod`; it reinstalls its server on the pod automatically.
6. Run `hello_world` (below) to confirm, then the first full build.

First run after bootstrap, from `/workspace/cutile-rs`:

```bash
source /workspace/env.sh
cargo run -p cutile-examples --example hello_world
```

Success prints the kernel's Tile IR followed by `Hello, I am program <0, 0, 0> in a kernel with <1, 1, 1> programs.` (the README's wording is out of date). Verified on the pod on 2026-09-16 and again on 2026-09-17; from an empty `target/` the build plus run takes about a minute of wall time on 48 cores (3 CPU-minutes) and leaves a 2.2 GB debug `target/`. The bootstrap itself took 15 minutes on 2026-09-17, nearly all CUDA download; `pod/README.md` keeps the timing table. After that, `./scripts/run_cpu_tests.sh` then `./scripts/run_gpu_tests.sh` confirm the full stack, and `CUTILE_DUMP=ir cargo run -p cutile-examples --example saxpy` is the quickest way to see what the JIT emits for a kernel. The `cuda-tile-rs` submodule is only needed to build that crate; skip `--recurse-submodules` unless you intend to build LLVM.
