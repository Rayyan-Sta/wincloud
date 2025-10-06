This project is not actually too hard so these are the command you need to run. Be careful! Don't put all the command at once 




sudo apt update
sudo apt install qemu-kvm qemu-system-x86 openbox firefox tigervnc-standalone-server
git clone https://www.github.com/novnc/noVNC
cd noVNC
sudo vncserver -SecurityType none -xstartup "openbox" -rfbport 5080
sudo ./utils/novnc_proxy --vnc 127.0.0.1:5080 --listen localhost:3820

And then download a Windows 11 23H2 Version
Or run this 
wget https://archive.org/download/2024-08-13-20-50-59/Windows%2011%2023H2%20Build%2022631.4037.iso

An here's the rest of the command 

cd downloads
ls
df -h
qemu-img create disk.img 10G
qemu-system-x86_64 --enable-kvm -m 4G -smp 2 -pflash /usr/share/OVMF/OVMF_CODE.fd -hdd disk.img -cdrom Win11_22H2_English_x64v1.iso







