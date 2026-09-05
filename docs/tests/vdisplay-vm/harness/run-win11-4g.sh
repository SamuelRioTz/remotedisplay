#!/bin/bash
# VM Windows 11 ARM64 (QEMU+HVF) para probar el cliente RemoteDesk.
# SSH: ssh -p 2222 user@127.0.0.1 (pass user)  |  QMP: qmp.sock (screenshots/input via qmp.py)
# El guest llega al Mac host como 10.0.2.2 (puente al server de Tart: puerto 21119).
#
# WIN11_INSTALL=1 ./run-win11.sh  -> instalar (monta ISOs, GPU=ramfb: WinPE NO
#   tiene driver virtio-gpu y se cuelga con él). Sin la var -> uso normal
#   (virtio-gpu, ventana grande; el driver lo trae el guest-tools).
D=/Volumes/sam-ex/windows-qemu

# GPU segun modo (ver comentario). ramfb = framebuffer basico que WinPE soporta.
if [ -n "$WIN11_INSTALL" ]; then
  GPU=(-device ramfb)
  INSTALL_MEDIA=(
    -device usb-storage,drive=cd0 -drive if=none,id=cd0,media=cdrom,file="$D/win11arm64.iso"
    -device usb-storage,drive=cd1 -drive if=none,id=cd1,media=cdrom,file="$D/unattend.iso"
  )
else
  GPU=(-device virtio-gpu-pci,edid=on,xres=1920,yres=1080)
  INSTALL_MEDIA=()
fi

exec /opt/homebrew/bin/qemu-system-aarch64 \
  -M virt,highmem=on -accel hvf -cpu host -smp 4 -m 4096 \
  -drive if=pflash,format=raw,readonly=on,file=/opt/homebrew/share/qemu/edk2-aarch64-code.fd \
  -drive if=pflash,format=raw,file="$D/edk2-vars.fd" \
  -device nvme,drive=hd0,serial=nvme0 -drive if=none,id=hd0,file="$D/win11.qcow2",format=qcow2 \
  -device qemu-xhci,id=xhci -device usb-kbd -device usb-tablet \
  "${INSTALL_MEDIA[@]}" \
  -device usb-storage,drive=cd2 -drive if=none,id=cd2,media=cdrom,file="$D/utm-guest-tools.iso" \
  -device virtio-net-pci,netdev=n0 -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 \
  "${GPU[@]}" \
  -qmp unix:"$D/qmp.sock",server,nowait \
  -display cocoa,show-cursor=on,zoom-to-fit=on
