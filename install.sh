#!/usr/bin/env bash
set -Eeuo pipefail

REPO="Elizavr86/noctari-vast-miner"
TAG="${TAG:-latest}"
POOL="${POOL:-stratum+tcp://pool.noctari.xyz:3333}"
WALLET="${WALLET:-NZbkGbh6P1LRxoeCGKggdspnUfhsFhygH6}"
INTENSITY="${INTENSITY:-24}"
MAX_TEMP="${MAX_TEMP:-75}"
SESSION="${SESSION:-noctari}"
INSTALL_DIR="${INSTALL_DIR:-/opt/noctari-miner}"

log() { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Linux" ]] || die "Linux is required."
command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi not found. Use a Vast.ai NVIDIA template."

SUDO=""
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "Run as root or install sudo."
  SUDO="sudo"
fi

if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  case "${ID:-}:${VERSION_ID:-}" in
    ubuntu:22.04|ubuntu:24.04) ;;
    *) log "Warning: tested on Ubuntu 22.04/24.04; detected ${PRETTY_NAME:-unknown Linux}." ;;
  esac
fi

mapfile -t GPU_ROWS < <(nvidia-smi --query-gpu=index,name --format=csv,noheader)
GPU_IDS=()
for row in "${GPU_ROWS[@]}"; do
  idx="$(awk -F',' '{gsub(/[[:space:]]/,"",$1); print $1}' <<<"$row")"
  name="$(cut -d',' -f2- <<<"$row" | xargs)"
  if grep -qi 'RTX 4090' <<<"$name"; then GPU_IDS+=("$idx"); fi
done

((${#GPU_IDS[@]} > 0)) || {
  printf '%s\n' "${GPU_ROWS[@]}" >&2
  die "No RTX 4090 detected. This release targets Ada sm_89."
}

GPU_CSV="$(IFS=,; echo "${GPU_IDS[*]}")"
INTENSITY_CSV=""
for _ in "${GPU_IDS[@]}"; do INTENSITY_CSV+="${INTENSITY},"; done
INTENSITY_CSV="${INTENSITY_CSV%,}"

HOST_LABEL="$(hostname 2>/dev/null | tr -cd 'A-Za-z0-9_-' | cut -c1-32)"
WORKER="${WORKER:-vast-${HOST_LABEL:-rig}-4090}"

if pgrep -af '[c]cminer' >/dev/null 2>&1; then
  pgrep -af '[c]cminer' || true
  die "Another ccminer process is already running. Stop it manually first."
fi

log "Installing runtime libraries only. NVIDIA driver and CUDA Toolkit will not be changed."
$SUDO apt-get update -y
DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y --no-install-recommends \
  ca-certificates curl tmux libjansson4 libssl3 libgomp1

if ! DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y --no-install-recommends libcurl4; then
  DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y --no-install-recommends libcurl4t64
fi

[[ "$(uname -m)" == "x86_64" ]] || die "Only x86_64 hosts are supported."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ASSET="noctari-ccminer-linux-sm89.tar.gz"
URL="https://github.com/${REPO}/releases/download/${TAG}"

log "Downloading the verified RTX 4090 release"
curl -fL --retry 5 --retry-delay 2 -o "$TMP/$ASSET" "$URL/$ASSET"
curl -fL --retry 5 --retry-delay 2 -o "$TMP/$ASSET.sha256" "$URL/$ASSET.sha256"
(
  cd "$TMP"
  sha256sum -c "$ASSET.sha256"
)

$SUDO rm -rf "$INSTALL_DIR"
$SUDO mkdir -p "$INSTALL_DIR"
$SUDO tar -xzf "$TMP/$ASSET" -C "$INSTALL_DIR"
$SUDO chmod 0755 "$INSTALL_DIR/bin/ccminer"
$SUDO mkdir -p "$INSTALL_DIR/logs"

MISSING="$(ldd "$INSTALL_DIR/bin/ccminer" | awk '/not found/{print $1}' || true)"
[[ -z "$MISSING" ]] || die "Missing runtime libraries: $MISSING"

cat > "$TMP/noctari-start" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
SESSION="${SESSION}"
BIN="${INSTALL_DIR}/bin/ccminer"
LOG="${INSTALL_DIR}/logs/miner.log"
POOL="${POOL}"
USERPASS="${WALLET}.${WORKER}"
GPU_IDS="${GPU_CSV}"
INTENSITIES="${INTENSITY_CSV}"
MAX_TEMP="${MAX_TEMP}"

if tmux has-session -t "\$SESSION" 2>/dev/null; then
  echo "Session \$SESSION is already running."
  tmux capture-pane -pt "\$SESSION" -S -40 || true
  exit 0
fi
if pgrep -af '[c]cminer' >/dev/null 2>&1; then
  pgrep -af '[c]cminer'
  echo "Another ccminer process is running; refusing a duplicate start." >&2
  exit 1
fi

mkdir -p "\$(dirname "\$LOG")"
tmux new-session -d -s "\$SESSION" \
  "exec \\"\$BIN\\" -a quark -o \\"\$POOL\\" -u \\"\$USERPASS\\" -p x -d \\"\$GPU_IDS\\" -i \\"\$INTENSITIES\\" --max-temp=\\"\$MAX_TEMP\\" 2>&1 | tee -a \\"\$LOG\\""
sleep 8
tmux capture-pane -pt "\$SESSION" -S -50 || true
EOF

cat > "$TMP/noctari-status" <<EOF
#!/usr/bin/env bash
set -u
echo "=== MINER ==="
if tmux has-session -t "${SESSION}" 2>/dev/null; then
  echo "RUNNING: tmux ${SESSION}"
  tmux capture-pane -pt "${SESSION}" -S -50 || true
else
  echo "STOPPED"
fi
echo
echo "=== GPU ==="
nvidia-smi --query-gpu=index,name,utilization.gpu,temperature.gpu,power.draw,clocks.sm,fan.speed --format=csv,noheader
EOF

cat > "$TMP/noctari-logs" <<EOF
#!/usr/bin/env bash
exec tail -n 120 -f "${INSTALL_DIR}/logs/miner.log"
EOF

cat > "$TMP/noctari-stop" <<EOF
#!/usr/bin/env bash
set -u
if tmux has-session -t "${SESSION}" 2>/dev/null; then
  tmux send-keys -t "${SESSION}" C-c
  sleep 3
  tmux kill-session -t "${SESSION}" 2>/dev/null || true
fi
pgrep -af '[c]cminer' || true
EOF

cat > "$TMP/noctari-restart" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
noctari-stop
sleep 2
exec noctari-start
EOF

for command_name in noctari-start noctari-status noctari-logs noctari-stop noctari-restart; do
  $SUDO install -m 0755 "$TMP/$command_name" "/usr/local/bin/$command_name"
done

cat <<EOF | $SUDO tee "$INSTALL_DIR/INSTALL_INFO.txt" >/dev/null
Installed: $(date -Is)
Repository: https://github.com/${REPO}
Release: ${TAG}
Pool: ${POOL}
Worker: ${WALLET}.${WORKER}
GPU IDs: ${GPU_CSV}
Intensity: ${INTENSITY_CSV}
Maximum temperature: ${MAX_TEMP} C
Driver: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1)
EOF

log "Starting Noctari miner"
noctari-start

cat <<EOF

READY
Status:   noctari-status
Live log: noctari-logs
Console:  tmux attach -t ${SESSION}
Detach:   Ctrl+B, then D
Restart:  noctari-restart
Stop:     noctari-stop
EOF
