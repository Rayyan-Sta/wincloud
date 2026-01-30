# A Windows 10 On Github Codespaces

This project runs a Windows 10 VM (Tiny10) in QEMU with UEFI, TPM 2.0 support, and VirtIO drivers.

## Prerequisites

Install required dependencies:

```bash
sudo apt update
sudo apt install -y qemu-system-x86 qemu-utils ovmf swtpm
```

## Running the VM

### Step 1: Make the script executable

```bash
chmod +x run_win11_qemu.sh
```

### Step 2: Boot the VM

Basic command (downloads ISOs on first run):

```bash
./run_win11_qemu.sh --name tiny10 --mem 8G --disk-size 12G
```

Or, use a local ISO with VirtIO drivers pre-baked:

```bash
./run_win11_qemu.sh --name tiny10 --mem 8G --disk-size 12G --iso-local "./iso/Tiny10(VirtioBaked).iso"
```

**Options:**
- `--name`: VM name (affects disk/TPM file names)
- `--mem`: RAM allocation (e.g., `8G`, `4G`)
- `--disk-size`: VM disk size (e.g., `64G`, `32G`)
- `--iso-local`: Path to local ISO file
- `--no-kvm`: Disable KVM acceleration (falls back to TCG emulation)
- `--gui`: Enable graphical display (requires `DISPLAY` set)
- `--help`: Show all available options

### Step 3: Access the VM via VNC

The VM runs headless by default with VNC on `127.0.0.1:5901`.

**Option A: Use noVNC (web-based)**

1. Start the noVNC server:
   ```bash
   cd noVNC && python3 -m http.server 6080
   ```

2. Open in your browser: `http://localhost:6080/vnc.html`

3. In the noVNC interface, connect to: `127.0.0.1:5901`

**Option B: Use a VNC client**

Use Remmina, TigerVNC, or any VNC client to connect to `127.0.0.1:5901`.

### Step 4: Complete Windows Setup

- Boot from the Tiny10 ISO
- Follow the Windows setup wizard
- Once installed, you can connect via RDP to `localhost:3389` (if using standard Windows)

## File Structure

- `run_win11_qemu.sh` - Main script to boot the Windows 11 VM
- `iso/` - Directory for ISO files (downloaded or local)
- `vm/` - Directory for VM files (disk image, OVMF vars, TPM state)
- `noVNC/` - Web-based VNC client for remote access

## Stopping the VM

Press `Ctrl+C` in the terminal, or:

```bash
pkill qemu
```

The swtpm process (TPM emulator) will be stopped automatically.

## Notes

- First boot downloads ~1.7GB of ISOs (Tiny10 and VirtIO drivers)
- KVM acceleration requires `/dev/kvm` access; falls back to TCG if unavailable
- TPM 2.0 is enabled by default for Windows 11 compatibility
- RDP forwarding is enabled on host port 3389 for remote desktop access 
