# New RunPod pod, by hand

A step-by-step for starting a fresh pod for cutile-rs without any help. Every
command below is typed on the Windows PC in Git Bash unless it says "on the
pod". Lines that start with `#` are comments, not commands.

## Before you start (already done once, listed so you can check)

- Your SSH public key (`~/.ssh/id_ed25519.pub`) is registered in RunPod under
  Settings, SSH Public Keys. RunPod copies it onto a pod when the pod starts.
- The local clone of the fork lives at `E:\GitHub\cutile-rs` and contains
  `pod/setup-pod.sh`, the bootstrap script.
- `C:\Users\voan2\.ssh\config` has a `Host runpod` block (step 3 shows it).

## 1. Create the pod

- GPU: anything with compute capability 8.0 or newer (RTX 30xx/40xx/50xx,
  A-series, H-series, RTX PRO Blackwell). Older cards will not run kernels.
- Network volume: attach the existing one (region `euro-3`, mounts at
  `/workspace`). It keeps Rust, the Claude Code login, and the clone across
  pods. Without it the script still works but everything is rebuilt.
- Template: any Ubuntu 22.04 CUDA image is fine; the script installs the
  CUDA 13.3 toolkit itself. The template must expose port 22 over TCP, which
  is what makes "SSH over exposed TCP" appear in the Connect panel.

Wait until the pod shows Ready.

## 2. Get the address

Click Connect on the pod. Copy the line under "SSH over exposed TCP". It looks
like:

```
ssh root@213.173.104.45 -p 20113 -i ~/.ssh/id_ed25519
```

The number after `@` is the address, the number after `-p` is the port. Both
change with every new pod.

## 3. Point the `runpod` alias at it

Open `C:\Users\voan2\.ssh\config` in any editor and update the two numbers:

```
Host runpod
    HostName 213.173.104.45
    Port 20113
    User root
    IdentityFile ~/.ssh/id_ed25519
```

Save it. From now on `ssh runpod` means "this pod".

## 4. First connection

```bash
ssh runpod
```

The first time it asks whether to trust the host fingerprint. Type `yes`. You
land on the pod as `root`. Type `exit` to come back.

If you instead see a big warning that says `REMOTE HOST IDENTIFICATION HAS
CHANGED`, a previous pod used the same address and port. Remove the old
entry and connect again:

```bash
ssh-keygen -R '[213.173.104.45]:20113'
ssh runpod
```

## 5. Copy the bootstrap script over

```bash
scp /e/GitHub/cutile-rs/pod/setup-pod.sh runpod:/workspace/setup-pod.sh
```

## 6. Run the bootstrap on the pod

```bash
ssh runpod
# on the pod:
bash /workspace/setup-pod.sh 2>&1 | tee /workspace/setup-pod.log
```

It takes about five minutes with the volume, mostly the CUDA download, and a
few more without it. It ends by printing `SETUP_DONE`. If the connection
drops partway, connect again and run the same command; the script skips
whatever is already done.

## 7. Check that kernels run

Still on the pod:

```bash
source /workspace/env.sh
cd /workspace/cutile-rs
cargo run -p cutile-examples --example hello_world
```

The first build takes a few minutes. Success ends with:

```
Hello, I am program <0, 0, 0> in a kernel with <1, 1, 1> programs.
```

## 8. Work

Pick either, or both:

- Shared terminal: `ssh -t runpod tmux attach -t pod` from Git Bash. It is a
  shell on the pod with the environment already loaded. Detach with Ctrl+B
  then D; the session keeps running.
- VS Code: F1, "Remote-SSH: Connect to Host...", pick `runpod`, then File,
  Open Folder, `/workspace/cutile-rs`. To use Claude Code there, run `claude`
  in that window's terminal; the login is stored on `/workspace`, so it is
  only asked for once per volume.

## 9. End of the day

On the pod, commit anything worth keeping:

```bash
cd /workspace/cutile-rs
git add -A && git commit -s -m "wip: what you did"
```

On Windows, pull it over and push it to GitHub (the pod has no GitHub login
on purpose):

```bash
cd /e/GitHub/cutile-rs
git fetch pod
git merge pod/main          # or: git checkout -b <name> pod/<name>
git push origin main
```

Then stop or terminate the pod. Do not rely on the pod's clone surviving;
on 2026-09-17 it came back empty after a pod swap even though the rest of
`/workspace` was intact.

## How long it takes

Measured runs, so you know whether a run is slow or stuck. The script prints
its own per-step and total timings in `/workspace/setup-pod.log`.

| Date | What | Conditions | Time |
|---|---|---|---|
| 2026-09-17 | bootstrap | volume attached (Rust and Claude config present), fresh container, CUDA 13.3 download from a slow mirror | 899 s (15 min), almost all of it the CUDA download |
| 2026-09-17 | first `hello_world` build and run | empty `/root/target`, 48 cores, debug profile | 56 s wall, 3 min CPU; `target/` ends up at 2.2 GB |

Not done yet, decided against nothing: the CUDA download could be avoided on
later pods by keeping apt's downloaded `.deb` files on the volume
(`/workspace/apt-cache`, via `-o Dir::Cache::archives=` and no `apt-get
clean`), which should cut the bootstrap to roughly 3 minutes. Alternatives are
installing the toolkit itself onto the volume, or a pod template that already
ships CUDA 13.3.

## If something goes wrong

- `Permission denied (publickey)`: the pod does not have your key. Check
  RunPod Settings, SSH Public Keys, then stop and start the pod.
- `Connection refused` or `Connection timed out`: wrong port in the config,
  or the pod is not Ready yet.
- `cargo: command not found` or `tileiras` missing when running a one-off
  `ssh runpod '<command>'`: those do not load `.bashrc`. Prefix the command
  with `source /workspace/env.sh &&`, or rerun the bootstrap if `tileiras`
  is truly absent.
- Build errors mentioning CUDA below 13.2: the bootstrap did not finish.
  Rerun step 6 and read its output.
- `tmux attach` says no session: rerun the bootstrap; it recreates the
  session.
