#!/usr/bin/env bash
set -euo pipefail

# run_win11_qemu.sh
# Downloads Windows 11 22H2 ISO (if needed) and boots it in QEMU with UEFI, virtio
# optional: KVM acceleration and TPM (via swtpm).
#
# Usage:
#   ./run_win11_qemu.sh [--iso URL] [--name vmname] [--disk-size SIZE] [--mem SIZE]
# Example:
#   ./run_win11_qemu.sh --name win11-22h2 --mem 8G --disk-size 64G

ISO_URL_DEFAULT="https://archive.org/download/windows11_20220930/Win11_22H2_English_x64v1.iso"
VIRTIO_URL_DEFAULT="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
USE_VIRTIO=1
VIRTIO_FIRST=0
INSTALL_SERVICE=0
VM_NAME="win11-22h2"
ISO_DIR="./iso"
WORK_DIR="./vm"
ISO_FILE=""
ISO_LOCAL=""
DISK_SIZE="64G"
MEM="8G"
CPUS=4
USE_TPM=1
USE_KVM=1
USE_GUI=0
NO_DOWNLOAD=0

print_help(){
  sed -n '1,120p' "$0" | sed -n '1,120p'
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --iso) ISO_URL="$2"; shift 2;;
    --virtio-url) VIRTIO_URL="$2"; shift 2;;
    --no-virtio) USE_VIRTIO=0; shift;;
    --virtio-first) VIRTIO_FIRST=1; shift;;
    --iso-local) ISO_LOCAL="$2"; shift 2;;
    --virtio-local) VIRTIO_LOCAL="$2"; shift 2;;
    --ovmf-code) OVMF_CODE="$2"; shift 2;;
    --ovmf-vars) OVMF_VARS="$2"; shift 2;;
    --name) VM_NAME="$2"; shift 2;;
    --disk-size) DISK_SIZE="$2"; shift 2;;
    --mem) MEM="$2"; shift 2;;
    --cpus) CPUS="$2"; shift 2;;
    --no-tpm) USE_TPM=0; shift;;
    --no-kvm) USE_KVM=0; shift;;
    --install-service) INSTALL_SERVICE=1; shift;;
    --gui) USE_GUI=1; shift;;
    --no-gui) USE_GUI=0; shift;;
    --no-download) NO_DOWNLOAD=1; shift;;
    -h|--help) print_help; exit 0;;
    *) echo "Unknown arg: $1"; print_help; exit 1;;
  esac
done

ISO_URL="${ISO_URL:-$ISO_URL_DEFAULT}"

mkdir -p "$ISO_DIR" "$WORK_DIR"

# Ensure the script file is executable (idempotent)
chmod +x "$0" || true

VIRTIO_URL="${VIRTIO_URL:-$VIRTIO_URL_DEFAULT}"

detect_bin(){
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required binary: $1" >&2; return 1; }
}

echo "Checking dependencies..."
for b in qemu-system-x86_64 qemu-img; do
  if ! detect_bin "$b"; then
    echo "Please install $b and re-run." >&2
    exit 1
  fi
done

if [[ $USE_TPM -eq 1 ]]; then
  if ! detect_bin swtpm; then
    echo "swtpm not found; install 'swtpm' to enable TPM, or run with --no-tpm." >&2
    exit 1
  fi
fi

# Find OVMF firmware files
# Allow environment or CLI override by leaving OVMF_CODE/OVMF_VARS if already set
OVMF_CODE="${OVMF_CODE:-}"
OVMF_VARS="${OVMF_VARS:-}"
if [[ -z "$OVMF_CODE" || -z "$OVMF_VARS" ]]; then
  search_dirs=( "/usr/share/OVMF" "/usr/share/ovmf" "/usr/share/edk2-ovmf/x64" "/usr/share/qemu" "/usr/share/qemu/firmware" )
  for d in "${search_dirs[@]}"; do
    if [[ ! -d "$d" ]]; then
      continue
    fi
    # look for code files
    for pat in OVMF_CODE*.fd OVMF*.fd OVMF_CODE_*.fd OVMF.fd; do
      candidate="$d/$pat"
      for f in $candidate; do
        if [[ -f "$f" ]]; then
          if [[ -z "$OVMF_CODE" ]]; then
            OVMF_CODE="$f"
          fi
        fi
      done
    done
    # look for vars files (prefer 4M vars if present)
    for pat in OVMF_VARS*.fd OVMF_VARS_*.fd OVMF_VARS*.ms.fd OVMF_VARS*.snakeoil.fd; do
      candidate="$d/$pat"
      for f in $candidate; do
        if [[ -f "$f" ]]; then
          if [[ -z "$OVMF_VARS" ]]; then
            OVMF_VARS="$f"
          fi
        fi
      done
    done
  done
fi

if [[ -z "$OVMF_CODE" || -z "$OVMF_VARS" ]]; then
  echo "OVMF firmware not found. Searched common locations. You can pass --ovmf-code / --ovmf-vars or set OVMF_CODE and OVMF_VARS environment variables to point to the firmware files." >&2
  echo "Common locations found on this host (examples):" >&2
  find /usr -maxdepth 3 -type f -iname 'ovmf*.fd' -o -iname 'ovmf_vars*.fd' 2>/dev/null | sed -n '1,20p' >&2 || true
  exit 1
fi

if [[ -n "${ISO_LOCAL:-}" ]]; then
  # Use the exact local ISO path provided by the user
  ISO_FILE="$ISO_LOCAL"
  if [[ ! -f "$ISO_FILE" ]]; then
    echo "Local ISO not found at $ISO_FILE" >&2
    exit 1
  fi
  echo "Using local ISO: $ISO_FILE"
else
  ISO_FILE="$ISO_DIR/$(basename "$ISO_URL")"
  if [[ ! -f "$ISO_FILE" ]]; then
    if [[ $NO_DOWNLOAD -eq 1 ]]; then
      echo "ISO not found at $ISO_FILE and --no-download specified. Aborting." >&2
      exit 1
    fi
    echo "Downloading ISO to $ISO_FILE ..."
    if command -v aria2c >/dev/null 2>&1; then
      aria2c -x4 -s4 -o "$ISO_FILE" "$ISO_URL"
    elif command -v wget >/dev/null 2>&1; then
      wget -O "$ISO_FILE" "$ISO_URL"
    elif command -v curl >/dev/null 2>&1; then
      curl -L -o "$ISO_FILE" "$ISO_URL"
    else
      echo "No downloader found (aria2c/wget/curl). Install one and re-run." >&2
      exit 1
    fi
  else
    echo "Using existing ISO: $ISO_FILE"
  fi
fi

DISK_IMG="$WORK_DIR/${VM_NAME}.qcow2"
if [[ ! -f "$DISK_IMG" ]]; then
  echo "Creating disk $DISK_IMG ($DISK_SIZE)..."
  qemu-img create -f qcow2 "$DISK_IMG" "$DISK_SIZE"
fi

# Prepare OVMF variables copy (writable)
VARS_COPY="$WORK_DIR/${VM_NAME}_OVMF_VARS.fd"
if [[ ! -f "$VARS_COPY" ]]; then
  echo "Creating writable OVMF vars copy: $VARS_COPY"
  cp "$OVMF_VARS" "$VARS_COPY"
fi

# Setup TPM if requested
TPM_SOCKET_PREF="$WORK_DIR/${VM_NAME}_swtpm_sock"
TPM_SOCKET_FALLBACK="/tmp/${VM_NAME}_swtpm_sock"
TPM_STATE_DIR_PREF="$WORK_DIR/${VM_NAME}_tpmstate"
TPM_STATE_DIR_FALLBACK="/tmp/${VM_NAME}_tpmstate"
TPM_PID_FILE="$WORK_DIR/${VM_NAME}_swtpm.pid"
TPM_LOG="$WORK_DIR/swtpm.log"

if [[ $USE_TPM -eq 1 ]]; then

  start_swtpm() {
    local sockpath="$1"; local pidfile="$2"; local logpath="$3"
    # kill any previous background swtpm started by script
    if [[ -f "$pidfile" ]]; then
      oldpid=$(cat "$pidfile" 2>/dev/null || true)
      if [[ -n "$oldpid" ]]; then
        kill "$oldpid" 2>/dev/null || true
        rm -f "$pidfile" || true
      fi
    fi
    rm -f "$sockpath" || true
    echo "Starting swtpm for TPM2 (socket: $sockpath, log: $logpath)"
    swtpm socket --tpm2 --tpmstate dir="$TPM_STATE_DIR" --ctrl type=unixio,path="$sockpath" --log level=1 >"$logpath" 2>&1 &
    local pid=$!
    # if swtpm exited immediately, $pid may be set but process gone
    sleep 0.1
    if ! kill -0 "$pid" 2>/dev/null; then
      return 2
    fi
    echo "$pid" > "$pidfile"
    # wait for socket
    local max_wait=20; local waited=0
    while [[ ! -S "$sockpath" && $waited -lt $max_wait ]]; do
      sleep 0.5
      waited=$((waited+1))
    done
    if [[ -S "$sockpath" ]]; then
      return 0
    fi
    return 1
  }

  # Choose a writable TPM state directory: prefer workspace, fallback to /tmp
  mkdir -p "$TPM_STATE_DIR_PREF" 2>/dev/null || true
  if touch "$TPM_STATE_DIR_PREF"/.writable_test 2>/dev/null; then
    TPM_STATE_DIR="$TPM_STATE_DIR_PREF"
    rm -f "$TPM_STATE_DIR_PREF"/.writable_test
  else
    echo "TPM state dir '$TPM_STATE_DIR_PREF' not writable; using fallback state dir: $TPM_STATE_DIR_FALLBACK"
    mkdir -p "$TPM_STATE_DIR_FALLBACK" 2>/dev/null || true
    TPM_STATE_DIR="$TPM_STATE_DIR_FALLBACK"
  fi

  # Try preferred socket in workspace, then fallback to /tmp if needed
  if start_swtpm "$TPM_SOCKET_PREF" "$TPM_PID_FILE" "$TPM_LOG"; then
    TPM_SOCKET="$TPM_SOCKET_PREF"
  else
    # check log for permission denied
    if grep -qi "permission denied" "$TPM_LOG" 2>/dev/null; then
      echo "swtpm couldn't create socket in workspace (permission denied). Trying fallback socket: $TPM_SOCKET_FALLBACK"
    else
      echo "swtpm didn't create socket at $TPM_SOCKET_PREF; trying fallback: $TPM_SOCKET_FALLBACK"
    fi
    # cleanup and try fallback (ensure PID file removed)
    if [[ -f "$TPM_PID_FILE" ]]; then
      kill "$(cat "$TPM_PID_FILE")" 2>/dev/null || true
      rm -f "$TPM_PID_FILE" || true
    fi
    rm -f "$TPM_SOCKET_PREF" 2>/dev/null || true
    if start_swtpm "$TPM_SOCKET_FALLBACK" "$TPM_PID_FILE" "$TPM_LOG"; then
      TPM_SOCKET="$TPM_SOCKET_FALLBACK"
    else
      echo "swtpm failed to create a control socket in both workspace and /tmp." >&2
      echo "Check swtpm log: $TPM_LOG" >&2
      sed -n '1,200p' "$TPM_LOG" >&2 || true
      rm -f "$TPM_PID_FILE" || true
      exit 1
    fi
  fi
fi

# Download virtio drivers ISO and attach if requested
VIRTIO_ISO="$ISO_DIR/$(basename "$VIRTIO_URL")"
if [[ $USE_VIRTIO -eq 1 ]]; then
  if [[ -n "${VIRTIO_LOCAL:-}" ]]; then
    VIRTIO_ISO="$VIRTIO_LOCAL"
    if [[ ! -f "$VIRTIO_ISO" ]]; then
      echo "Local VirtIO ISO not found at $VIRTIO_ISO" >&2
      exit 1
    fi
    echo "Using local VirtIO ISO: $VIRTIO_ISO"
  else
    if [[ ! -f "$VIRTIO_ISO" ]]; then
      if [[ $NO_DOWNLOAD -eq 1 ]]; then
        echo "VirtIO ISO not found at $VIRTIO_ISO and --no-download specified. Aborting." >&2
        exit 1
      fi
      echo "Downloading VirtIO drivers ISO to $VIRTIO_ISO ..."
      if command -v aria2c >/dev/null 2>&1; then
        aria2c -x4 -s4 -o "$VIRTIO_ISO" "$VIRTIO_URL"
      elif command -v wget >/dev/null 2>&1; then
        wget -O "$VIRTIO_ISO" "$VIRTIO_URL"
      elif command -v curl >/dev/null 2>&1; then
        curl -L -o "$VIRTIO_ISO" "$VIRTIO_URL"
      else
        echo "No downloader found for virtio ISO (aria2c/wget/curl). Install one or run with --no-virtio." >&2
        exit 1
      fi
    else
      echo "Using existing VirtIO ISO: $VIRTIO_ISO"
    fi
  fi
fi

QEMU_CMD=(qemu-system-x86_64)
# Check KVM availability and permissions before enabling
if [[ $USE_KVM -eq 1 ]]; then
  if [[ -c /dev/kvm ]]; then
    if [[ -r /dev/kvm && -w /dev/kvm ]]; then
      QEMU_CMD+=( -enable-kvm )
    else
      echo "Warning: /dev/kvm exists but is not accessible by this user. Falling back to TCG (no KVM)."
      echo "To enable KVM, run on a host with KVM enabled and ensure your user has access to /dev/kvm (add to 'kvm' group or run with sufficient privileges)." >&2
      USE_KVM=0
    fi
  else
    echo "Warning: /dev/kvm not found. KVM unavailable — running without KVM (TCG)." >&2
    USE_KVM=0
  fi
fi
QEMU_CMD+=( -m "$MEM" -smp "$CPUS" -machine q35 )
# Use -cpu host only when KVM (or equivalent) is available; otherwise use a safe emulated CPU
if [[ $USE_KVM -eq 1 ]]; then
  QEMU_CMD+=( -cpu host )
else
  QEMU_CMD+=( -cpu qemu64 )
fi

# OVMF pflash configuration
QEMU_CMD+=( -drive if=pflash,format=raw,readonly,file="$OVMF_CODE" -drive if=pflash,format=raw,file="$VARS_COPY" )

# Drives and devices
QEMU_CMD+=( -device virtio-scsi-pci -drive file="$DISK_IMG",if=virtio,format=qcow2 )
if [[ $USE_VIRTIO -eq 1 && $VIRTIO_FIRST -eq 1 ]]; then
  # Mount VirtIO ISO as primary CD (easier to find in Windows installer)
  QEMU_CMD+=( -drive id=cdrom,if=none,file="$VIRTIO_ISO",media=cdrom -device scsi-cd,drive=cdrom )
  QEMU_CMD+=( -drive id=win11_cd,if=none,file="$ISO_FILE",media=cdrom -device scsi-cd,drive=win11_cd )
else
  # Mount Windows ISO as primary CD (default)
  QEMU_CMD+=( -drive id=cdrom,if=none,file="$ISO_FILE",media=cdrom -device scsi-cd,drive=cdrom )
  if [[ $USE_VIRTIO -eq 1 ]]; then
    QEMU_CMD+=( -drive id=virtio_cd,if=none,file="$VIRTIO_ISO",media=cdrom -device scsi-cd,drive=virtio_cd )
  fi
fi

# Networking: user-mode with RDP host forwarding as example (host 3389 -> guest 3389)
QEMU_CMD+=( -netdev user,id=net0,hostfwd=tcp::3389-:3389 -device virtio-net-pci,netdev=net0 )

if [[ $USE_TPM -eq 1 ]]; then
  QEMU_CMD+=( -chardev socket,id=chrtpm,path="$TPM_SOCKET" -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0 )
fi

# Display handling: default to headless VNC unless --gui is passed.
if [[ $USE_GUI -eq 1 ]]; then
  # Only attempt GTK display when user explicitly requested GUI
  if [[ -n "${DISPLAY:-}" ]]; then
    QEMU_CMD+=( -display gtk )
  else
    echo "Warning: DISPLAY not set. GTK display may fail. Use --no-gui to run headless or enable DISPLAY." >&2
    QEMU_CMD+=( -display none -vnc 127.0.0.1:1 )
  fi
else
  # Headless: expose VNC on localhost:5901 (display :1)
  QEMU_CMD+=( -display none -vnc 127.0.0.1:1 )
fi

echo "Starting QEMU for VM '$VM_NAME'..."
echo
if [[ $USE_VIRTIO -eq 1 ]]; then
  echo "VirtIO drivers mounted. During Windows setup, when asked for storage drivers:"
  if [[ $VIRTIO_FIRST -eq 1 ]]; then
    echo "  1. The VirtIO CD is the PRIMARY (first CD); open it directly or mount it."
  else
    echo "  1. Click 'Load driver' or 'Have disk'."
    echo "  2. Browse to the second CD-ROM (VirtIO ISO)."
  fi
  echo "  3. Navigate to: amd64/w11 or viostor/w11/amd64"
  echo "  4. Select the .INF file and install the virtio storage driver."
  echo
fi
printf ' %s' "${QEMU_CMD[@]}"
echo

"${QEMU_CMD[@]}"

EXIT_CODE=$?
if [[ $USE_TPM -eq 1 ]]; then
  if [[ -f "$TPM_PID_FILE" ]]; then
    PKILL_PID=$(cat "$TPM_PID_FILE" || true)
    if [[ -n "$PKILL_PID" ]]; then
      echo "Stopping swtpm (pid $PKILL_PID)"
      kill "$PKILL_PID" 2>/dev/null || true
      rm -f "$TPM_PID_FILE"
    fi
  fi
fi

exit $EXIT_CODE

if [[ $INSTALL_SERVICE -eq 1 ]]; then
  SERVICE_PATH="$WORK_DIR/${VM_NAME}.service"
  echo "Creating a systemd service file at $SERVICE_PATH"
  cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=QEMU Windows 11 VM - ${VM_NAME}
After=network.target

[Service]
Type=simple
ExecStart=$(readlink -f "$0") --name ${VM_NAME} --mem ${MEM} --disk-size ${DISK_SIZE}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  echo "To install: sudo mv '$SERVICE_PATH' /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable --now ${VM_NAME}.service"
fi
