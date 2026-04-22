#!/bin/bash
# cvm-runtime-init.sh
#
# Generic TDX + NVIDIA Confidential Computing runtime initialisation.
#
# Runs once at boot via cvm-runtime-init.service. Performs every step
# that has to happen INSIDE the TDX guest before any platform service
# (containerd, manager) can start a GPU container:
#
#   1. PAM fix (pam_systemd does not work in CVM, swap to pam_permit).
#   2. Unload the unpatched system NVIDIA modules (loaded by udev/modprobe
#      from initrd; they are not CC-capable).
#   3. PCI Function Level Reset on the GPU to clear FSP state.
#   4. Load the patched (CC-capable) nvidia + nvidia-uvm modules from
#      /data/nvidia-cc-bundle/modules/ if present.
#   5. Create /dev/nvidia* device nodes (no devtmpfs/udev for this).
#   6. nvidia-smi: persistence mode + CC ready state.
#   7. Generate /var/run/cdi/nvidia.yaml so containerd can inject the
#      GPU into containers via CDI.
#
# Intentionally NOT here:
#   - Disk mounting (image-*, model-*) - that is the disk-mounter service
#     in enclave-os-virtual.
#   - Hostname, SSH keys, manager.env - those are VM-specific glue done
#     by the GCE startup script.
#
# Exits 0 even on partial failure (e.g. no nvidia-cc-bundle yet) so the
# unit doesn't block boot. The systemd unit also has a soft failure
# mode (Type=oneshot, no Required dependents).

set -uo pipefail
exec > /run/cvm-runtime-init.log 2>&1
echo "=== cvm-runtime-init started at $(date) ==="

# ── 1. PAM fix ───────────────────────────────────────────────────────────
# pam_systemd.so fails in TDX guests (cgroup setup unavailable to the
# logind session); replace with pam_permit so SSH login works.
echo ">>> PAM fix"
for f in common-session common-session-noninteractive; do
  if [ -f "/etc/pam.d/$f" ]; then
    cp "/etc/pam.d/$f" "/run/pam-$f"
    sed -i 's/.*pam_systemd.so.*/session optional pam_permit.so/' "/run/pam-$f"
    mount --bind "/run/pam-$f" "/etc/pam.d/$f"
  fi
done

# ── 2. Unload system NVIDIA modules ─────────────────────────────────────
echo ">>> Unloading system nvidia modules"
systemctl stop nvidia-cdi-refresh.service 2>/dev/null || true
systemctl stop nvidia-persistenced.service 2>/dev/null || true
pkill -f nvidia-persistenced 2>/dev/null || true
pkill -f nvidia-cdi 2>/dev/null || true
sleep 1
for mod in nvidia_drm nvidia_modeset nvidia_uvm nvidia; do
  rmmod "$mod" 2>/dev/null || true
done
echo "Modules after unload: $(lsmod | grep nvidia || echo 'none')"

# Mask system module directory to prevent accidental reload.
KVER=$(uname -r)
SYSMOD="/lib/modules/${KVER}/kernel/drivers/video"
[ -d "$SYSMOD" ] && mount -t tmpfs tmpfs "$SYSMOD" 2>/dev/null || true

# ── 3. PCI Function Level Reset ─────────────────────────────────────────
# Clear GPU FSP state from the brief system-module init that may have
# happened before we unloaded above. This is the well-known recipe from
# NVIDIA's CC bring-up guide.
echo ">>> PCI Function Level Reset"
for gpu in /sys/bus/pci/devices/*/; do
  vendor=$(cat "$gpu/vendor" 2>/dev/null || echo "")
  class=$(cat "$gpu/class" 2>/dev/null || echo "")
  # 0x10de = NVIDIA, 0x030200 = 3D controller, 0x030000 = VGA
  if [ "$vendor" = "0x10de" ] && { [ "$class" = "0x030200" ] || [ "$class" = "0x030000" ]; }; then
    if [ -w "$gpu/reset" ]; then
      echo "  resetting $(basename "$gpu")"
      echo 1 > "$gpu/reset" 2>/dev/null || true
    fi
  fi
done
sleep 2

# ── 4. Load patched NVIDIA CC modules ───────────────────────────────────
# The modules ship as a tarball on /data/nvidia-cc-bundle/. They are
# built per-kernel-version and signed with the cvm-images Secure Boot
# key. Until the bundle is baked into the image (TODO), this depends
# on the operator placing the bundle on /data.
BUNDLE_DIR=/data/nvidia-cc-bundle/modules
INSMOD_RC=1
if [ -f "$BUNDLE_DIR/nvidia.ko" ]; then
  echo ">>> Loading patched nvidia module"
  # Set firmware path so the module finds gsp_ga10x.bin.
  mkdir -p /run/nvidia-firmware/nvidia/590.48.01
  if [ -f /lib/firmware/nvidia/590.48.01/gsp_ga10x.bin ]; then
    cp /lib/firmware/nvidia/590.48.01/gsp_ga10x.bin \
       /run/nvidia-firmware/nvidia/590.48.01/ 2>/dev/null || true
  fi
  echo /run/nvidia-firmware > /sys/module/firmware_class/parameters/path

  insmod "$BUNDLE_DIR/nvidia.ko" \
    NVreg_OpenRmEnableUnsupportedGpus=1 \
    NVreg_RegistryDwords="RmConfidentialCompute=1"
  INSMOD_RC=$?
  echo "insmod RC=$INSMOD_RC"

  # Wait for GPU FSP initialisation.
  for i in $(seq 1 30); do
    if grep -q nvidia-frontend /proc/devices 2>/dev/null; then
      echo "GPU ready after ${i}s"
      break
    fi
    sleep 1
  done
else
  echo "WARNING: $BUNDLE_DIR/nvidia.ko not found, skipping NVIDIA CC bring-up"
fi

# ── 5. Device nodes + UVM ───────────────────────────────────────────────
if [ "$INSMOD_RC" -eq 0 ]; then
  echo ">>> Creating device nodes"
  MAJOR=$(grep nvidia-frontend /proc/devices 2>/dev/null | awk '{print $1}')
  if [ -n "$MAJOR" ]; then
    mknod /dev/nvidia0    c "$MAJOR" 0   2>/dev/null || true
    mknod /dev/nvidiactl  c "$MAJOR" 255 2>/dev/null || true
    chmod 666 /dev/nvidia0 /dev/nvidiactl 2>/dev/null || true
  fi

  if [ -f "$BUNDLE_DIR/nvidia-uvm.ko" ]; then
    insmod "$BUNDLE_DIR/nvidia-uvm.ko"
    UVM=$(grep nvidia-uvm /proc/devices | head -1 | awk '{print $1}')
    if [ -n "$UVM" ]; then
      mknod /dev/nvidia-uvm       c "$UVM" 0 2>/dev/null || true
      mknod /dev/nvidia-uvm-tools c "$UVM" 1 2>/dev/null || true
      chmod 666 /dev/nvidia-uvm /dev/nvidia-uvm-tools 2>/dev/null || true
    fi
  fi

  # ── 6. nvidia-smi setup ────────────────────────────────────────────────
  echo ">>> nvidia-smi setup"
  nvidia-smi -pm 1                        || echo "WARNING: persistence mode failed"
  nvidia-smi conf-compute -srs 1          || echo "WARNING: CC ready state failed"
  nvidia-smi --query-gpu=name,uuid,memory.total --format=csv,noheader || true
fi

# ── 7. CDI generation ───────────────────────────────────────────────────
# /etc is read-only erofs; containerd is configured to also scan
# /var/run/cdi (writable tmpfs).
mkdir -p /var/run/cdi
if command -v nvidia-ctk >/dev/null 2>&1; then
  echo ">>> Generating CDI spec"
  nvidia-ctk cdi generate --output=/var/run/cdi/nvidia.yaml 2>&1 \
    | tail -10 || true
  echo "CDI spec lines: $(wc -l < /var/run/cdi/nvidia.yaml 2>/dev/null || echo 0)"
else
  echo "WARNING: nvidia-ctk not found, skipping CDI generation"
fi

echo "=== cvm-runtime-init finished at $(date) ==="
exit 0
