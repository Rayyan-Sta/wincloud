#!/bin/bash
set -e

WORKDIR="/workspaces/$(basename $(pwd))/win11"
ISO_URL="https://software-download.microsoft.com/pr/Win11_22H2_English_x64v1.iso"
ISO_FILE="$WORKDIR/Win11_22H2.iso"
DISK_FILE="$WORKDIR/win11.qcow2"
AUTOUN_FILE="$WORKDIR/autounattend.iso"

mkdir -p "$WORKDIR"
cd "$WORKDIR"

install_deps() {
  echo "=== Installing dependencies ==="
  sudo apt update
  sudo apt install -y qemu qemu-system-x86 qemu-utils novnc websockify genisoimage curl unzip
}

create_autounattend() {
  echo "=== Creating unattended setup file ==="
  cat > autounattend.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <UserData>
        <ProductKey>
          <Key>VK7JG-NPHTM-C97JM-9MPGT-3V66T</Key>
          <WillShowUI>Never</WillShowUI>
        </ProductKey>
        <AcceptEula>true</AcceptEula>
        <FullName>Codespace</FullName>
        <Organization>GitHub</Organization>
      </UserData>
      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add">
              <Key>/IMAGE/INDEX</Key>
              <Value>6</Value>
            </MetaData>
          </InstallFrom>
          <InstallTo>
            <DiskID>0</DiskID>
            <PartitionID>1</PartitionID>
          </InstallTo>
        </OSImage>
      </ImageInstall>
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add">
              <Order>1</Order>
              <Type>Primary</Type>
              <Size>30000</Size>
            </CreatePartition>
          </CreatePartitions>
        </Disk>
      </DiskConfiguration>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <SkipUserOOBE>true</SkipUserOOBE>
        <SkipMachineOOBE>true</SkipMachineOOBE>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>codespace</Name>
            <Group>Administrators</Group>
            <Password>
              <Value>1234</Value>
              <PlainText>true</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Password>
          <Value>1234</Value>
          <PlainText>true</PlainText>
        </Password>
        <Enabled>true</Enabled>
        <Username>codespace</Username>
      </AutoLogon>
    </component>
  </settings>
</unattend>
EOF

  genisoimage -o "$AUTOUN_FILE" -J -r autounattend.xml
}

download_iso() {
  if [ ! -f "$ISO_FILE" ]; then
    echo "Downloading Windows 11 ISO..."
    curl -L -o "$ISO_FILE" "$ISO_URL"
  else
    echo "ISO already exists, skipping download."
  fi
}

create_disk() {
  if [ ! -f "$DISK_FILE" ]; then
    echo "Creating new Windows disk (30G)..."
    qemu-img create -f qcow2 "$DISK_FILE" 30G
  else
    echo "Found existing disk — resuming previous installation."
  fi
}

start_vm() {
  echo "=== Launching Windows 11 VM ==="
  if pgrep -x "qemu-system-x86_64" > /dev/null; then
    echo "VM already running."
  else
    nohup qemu-system-x86_64 \
      -m 6G \
      -smp 4 \
      -machine accel=tcg \
      -cpu qemu64,+aes,+xsave,+avx \
      -device qxl-vga \
      -display vnc=:0 \
      -boot d \
      -cdrom "$ISO_FILE" \
      -drive file="$DISK_FILE",format=qcow2 \
      -drive file="$AUTOUN_FILE",media=cdrom \
      -net nic -net user \
      -rtc base=localtime \
      -no-reboot &
    sleep 5
  fi

  if ! pgrep -x "websockify" > /dev/null; then
    echo "=== Starting noVNC ==="
    websockify --web /usr/share/novnc/ 6080 localhost:5900 &
  fi

  echo "✅ Windows 11 is running."
  echo "👉 Open forwarded port 6080 in your browser to access it."
  echo "Username: codespace | Password: 1234"
}

stop_vm() {
  echo "=== Stopping Windows 11 VM ==="
  pkill -f qemu-system-x86_64 || true
  pkill -f websockify || true
  echo "VM stopped. Disk persisted in $DISK_FILE"
}

case "$1" in
  start)
    install_deps
    download_iso
    create_autounattend
    create_disk
    start_vm
    ;;
  stop)
    stop_vm
    ;;
  *)
    echo "Usage: $0 {start|stop}"
    ;;
esac
