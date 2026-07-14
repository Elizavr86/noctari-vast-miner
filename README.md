# Noctari Vast Miner

One-command Noctari `$NCTI` Quark mining for Vast.ai RTX 4090 instances.

## Supported

- Ubuntu 22.04 and 24.04
- Vast NVIDIA templates with current drivers
- CUDA 12.x or CUDA 13.x host templates
- One or multiple RTX 4090 GPUs

The rented host does not need CUDA Toolkit 11.8 or `nvcc`. The GitHub release is built once for native Ada `sm_89`, and its CUDA runtime is statically linked. The installer does not replace the NVIDIA driver.

## Install and start

```bash
curl -fsSL https://raw.githubusercontent.com/Elizavr86/noctari-vast-miner/main/install.sh | bash
```

Defaults:

```text
Pool:      stratum+tcp://pool.noctari.xyz:3333
Algorithm: quark
Wallet:    NZbkGbh6P1LRxoeCGKggdspnUfhsFhygH6
Intensity: 24 per RTX 4090
Max temp:  75 C
```

## Management

```bash
noctari-status
noctari-logs
noctari-restart
noctari-stop
tmux attach -t noctari
```

Detach without stopping: `Ctrl+B`, then `D`.

## Optional settings

Environment variables can override defaults:

```bash
WORKER=vast-4090-01 INTENSITY=24 MAX_TEMP=75 \
curl -fsSL https://raw.githubusercontent.com/Elizavr86/noctari-vast-miner/main/install.sh | bash
```

## Reproducible build

The workflow builds pinned upstream source commit:

```text
6ff4e50987e59a70056324a94ed8667cc0bf598d
```

Published release assets include the binary archive, SHA256 checksum, complete patched source, patch, linked-library report, and `cuobjdump` architecture reports.
