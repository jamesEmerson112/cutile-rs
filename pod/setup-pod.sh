#!/bin/bash
# cutile-rs RunPod bootstrap. Safe to re-run on every fresh pod or pod restart.
#
# RunPod wipes / (container disk) when a pod stops, and a brand-new pod starts
# from a stock image. /workspace persists only when it is a network volume
# attached to the pod. This script reinstalls the ephemeral parts (apt
# packages, CUDA toolkit, Claude Code, tmux, shell hook) and keeps Rust, the
# repo, git identity, and the Claude login on /workspace. Cargo's target dir
# stays on local disk because /workspace is a network filesystem.
#
# Usual way (from the Windows checkout, works with or without the volume):
#   scp pod/setup-pod.sh runpod:/workspace/setup-pod.sh
#   ssh runpod 'bash /workspace/setup-pod.sh 2>&1 | tee /workspace/setup-pod.log'
# Bare pod once pod/ is on the fork's main:
#   curl -fsSL https://raw.githubusercontent.com/jamesEmerson112/cutile-rs/main/pod/setup-pod.sh | bash
#
# Each "== step" line reports how long the previous step took and the running
# total; the last line reports the total. Timings so far are in pod/README.md.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
WS=/workspace

LAST_STEP=0
step() {
    local now=$SECONDS
    echo "== $* [previous step +$((now - LAST_STEP))s, ${now}s total]"
    LAST_STEP=$now
}
echo "bootstrap started $(date -u '+%Y-%m-%d %H:%M:%S UTC') on $(hostname)"

step "apt packages"
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    build-essential curl ca-certificates git cmake pkg-config \
    libclang-dev zlib1g-dev libzstd-dev wget gnupg tmux

step "CUDA toolkit (13.3 preferred, 13.2 fallback; toolkit only, never the driver)"
if [ ! -x /usr/local/cuda-13.3/bin/tileiras ] && [ ! -x /usr/local/cuda-13.2/bin/tileiras ]; then
    wget -q -O /tmp/cuda-keyring.deb \
        https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
    dpkg -i /tmp/cuda-keyring.deb
    apt-get update -qq
    if apt-cache show cuda-toolkit-13-3 >/dev/null 2>&1; then
        PKG=cuda-toolkit-13-3
    else
        PKG=cuda-toolkit-13-2
    fi
    echo "installing $PKG"
    apt-get install -y -qq --no-install-recommends "$PKG"
    apt-get clean
fi
CUDA_DIR=""
for d in /usr/local/cuda-13.3 /usr/local/cuda-13.2; do
    if [ -x "$d/bin/tileiras" ]; then CUDA_DIR=$d; break; fi
done
if [ -z "$CUDA_DIR" ]; then
    echo "ERROR: no CUDA 13.2+ toolkit with tileiras found" >&2
    exit 1
fi
echo "CUDA_DIR=$CUDA_DIR"
"$CUDA_DIR/bin/nvcc" --version | tail -1
"$CUDA_DIR/bin/tileiras" --help 2>&1 | grep -o 'sm_[0-9]*' | sort -u | tr '\n' ' '
echo

step "Rust (persistent under $WS)"
export RUSTUP_HOME=$WS/.rustup
export CARGO_HOME=$WS/.cargo
if [ ! -x "$CARGO_HOME/bin/cargo" ]; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --no-modify-path --default-toolchain stable
fi
"$CARGO_HOME/bin/rustc" --version

step "Claude Code (binary on local disk, config and login persistent on $WS)"
export CLAUDE_CONFIG_DIR=$WS/.claude
mkdir -p "$CLAUDE_CONFIG_DIR"
if [ ! -x /root/.local/bin/claude ]; then
    curl -fsSL https://claude.ai/install.sh | bash || echo "Claude Code install failed, skipping"
fi

step "env file and shell hook"
cat > "$WS/env.sh" <<EOF
export RUSTUP_HOME=$WS/.rustup
export CARGO_HOME=$WS/.cargo
export CUDA_TOOLKIT_PATH=$CUDA_DIR
export CARGO_TARGET_DIR=/root/target
export GIT_CONFIG_GLOBAL=$WS/.gitconfig
export CLAUDE_CONFIG_DIR=$WS/.claude
export PATH=$WS/.cargo/bin:$CUDA_DIR/bin:/root/.local/bin:\$PATH
EOF
grep -q 'workspace/env.sh' /root/.bashrc || echo 'source /workspace/env.sh' >> /root/.bashrc

step "git identity (persistent)"
export GIT_CONFIG_GLOBAL=$WS/.gitconfig
git config --global user.name "jamesEmerson112"
git config --global user.email "james.emerson.vo.2503@gmail.com"

step "repo"
if [ ! -d "$WS/cutile-rs/.git" ]; then
    # Seen on 2026-09-17: the clone came back as an empty directory after a pod
    # swap while its siblings survived. An empty dir is fine to clone into; a
    # non-empty one without .git is moved aside rather than deleted.
    if [ -d "$WS/cutile-rs" ] && [ -n "$(ls -A "$WS/cutile-rs")" ]; then
        mv "$WS/cutile-rs" "$WS/cutile-rs.broken.$(date +%s)"
    fi
    git clone https://github.com/jamesEmerson112/cutile-rs.git "$WS/cutile-rs"
    git -C "$WS/cutile-rs" remote add upstream https://github.com/NVlabs/cutile-rs.git
fi
git -C "$WS/cutile-rs" log --oneline -1

step "shared tmux session 'pod' (watch it with: ssh -t runpod tmux attach -t pod)"
if ! tmux has-session -t pod 2>/dev/null; then
    tmux new-session -d -s pod -c "$WS/cutile-rs"
    tmux set-option -g mouse on
    tmux set-option -g history-limit 50000
    tmux pipe-pane -t pod "cat >> $WS/pod-session.log"
    tmux send-keys -t pod "source $WS/env.sh && clear" Enter
fi

echo "== one-time login still needed if $WS is new: run 'claude' once (persists on $WS)"
echo "== the pod has no GitHub credentials on purpose: commit here, then on the"
echo "   local machine run 'git fetch pod' and push from there (see CLAUDE.md)"
echo "SETUP_DONE in ${SECONDS}s at $(date -u '+%H:%M:%S UTC')"
