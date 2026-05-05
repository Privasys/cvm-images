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
#      /usr/lib/nvidia-cc/$(uname -r)/ (baked into the image).
#   5. Create /dev/nvidia* device nodes (no devtmpfs/udev for this).
#   6. nvidia-smi: persistence mode + CC ready state.
#   7. Generate /var/run/cdi/nvidia.yaml so containerd can inject the
#      GPU into containers via CDI.
#   8. Install nvidia-container-runtime legacy-mode wrapper and config
#      via tmpfs bind-mounts (config files are baked in the image at
#      /usr/lib/nvidia-cc/runtime/, not on /data).
#
# Intentionally NOT here:
#   - Disk mounting (image-*, model-*) - that is the disk-mounter service
#     in enclave-os-virtual.
#   - Hostname, SSH keys, manager.env - those are VM-specific glue done
#     by the GCE startup script.
#
# Failure semantics:
#   - patched module missing for $(uname -r) -> exit 1 (image bug, must
#     be a kernel-v* / nvidia-cc-v* version mismatch in the image build)
#   - insmod RC!=0 -> exit 1 (vermagic mismatch / signature rejected)
#   - nvidia-smi conf-compute -srs fails -> exit 1
#
# A status marker is written to /run/cvm-runtime-init.status with one of:
#   ok          -- patched bundle loaded, GPU ready
#   no-bundle   -- /usr/lib/nvidia-cc/$(uname -r)/nvidia.ko missing (image bug)
#   insmod-fail -- bundle present, insmod returned non-zero (vermagic / sig)
#   smi-fail    -- module loaded but nvidia-smi conf-compute -srs failed

set -uo pipefail
exec > /run/cvm-runtime-init.log 2>&1
echo "=== cvm-runtime-init started at $(date) ==="
STATUS_FILE=/run/cvm-runtime-init.status
write_status() { echo "$1" > "$STATUS_FILE"; }
write_status starting

# ── 1. PAM fix ───────────────────────────────────────────────────────────
# pam_systemd.so fails in TDX guests (cgroup setup unavailable to the
# logind session); replace with pam_permit so SSH login works.
echo ">>> PAM fix"
for f in common-session common-session-noninteractive; do
  if [ -f "/etc/pam.d/$f" ] && ! mountpoint -q "/etc/pam.d/$f"; then
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
# The patched modules are baked into the image at
#   /usr/lib/nvidia-cc/$(uname -r)/{nvidia.ko,nvidia-uvm.ko}
# alongside the matching GSP firmware at
#   /usr/lib/nvidia-cc/$(uname -r)/firmware/nvidia/<NV_VER>/.
# The cvm-images CI tags kernel-v* + nvidia-cc-v* together so the bundle
# ABI always matches the running kernel; if it does not the image build
# itself is broken (no /data dependency, no operator scp).
KVER=$(uname -r)
BUNDLE_DIR=/usr/lib/nvidia-cc/${KVER}/modules
FW_ROOT=/usr/lib/nvidia-cc/${KVER}/firmware
INSMOD_RC=1
if [ ! -f "$BUNDLE_DIR/nvidia.ko" ]; then
  echo "ERROR: $BUNDLE_DIR/nvidia.ko not found."
  echo "  The image is missing patched NVIDIA modules for kernel $KVER."
  echo "  The cvm-images kernel-v* and nvidia-cc-v* bundle baked into this"
  echo "  image are out of sync. Rebuild the image with matching tags."
  write_status no-bundle
  exit 1
fi
echo ">>> Loading patched nvidia module from $BUNDLE_DIR"
if [ -d "$FW_ROOT" ]; then
  echo "$FW_ROOT" > /sys/module/firmware_class/parameters/path
fi

insmod "$BUNDLE_DIR/nvidia.ko" \
  NVreg_OpenRmEnableUnsupportedGpus=1 \
  NVreg_RegistryDwords="RmConfidentialCompute=1"
INSMOD_RC=$?
echo "insmod RC=$INSMOD_RC"

if [ "$INSMOD_RC" -ne 0 ]; then
  echo "ERROR: insmod of patched nvidia.ko failed (RC=$INSMOD_RC)."
  echo "  Likely vermagic mismatch (bundle built for a different kernel ABI)"
  echo "  or signature rejected. Bundle modinfo:"
  /sbin/modinfo "$BUNDLE_DIR/nvidia.ko" 2>&1 | grep -E '^(vermagic|version|sig_id)' || true
  echo "  Running kernel: $KVER"
  echo "  Re-tag cvm-images nvidia-cc-v* against the matching kernel-v* release."
  write_status insmod-fail
  exit 1
fi

# Wait for GPU FSP initialisation.
for i in $(seq 1 30); do
  if grep -q nvidia-frontend /proc/devices 2>/dev/null; then
    echo "GPU ready after ${i}s"
    break
  fi
  sleep 1
done

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
  if ! nvidia-smi conf-compute -srs 1; then
    echo "ERROR: nvidia-smi conf-compute -srs failed -- GPU not in CC ready state"
    write_status smi-fail
    exit 1
  fi
  nvidia-smi --query-gpu=name,uuid,memory.total --format=csv,noheader || true
  write_status ok
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

# ── 8. nvidia-container-runtime mode=legacy ─────────────────────────────
# nvidia-container-runtime v1.19.0 in default mode=auto silently rewrites
# NVIDIA_VISIBLE_DEVICES=all to "void" when CDI lookup fails, hiding the
# GPU from every container. Force mode=legacy. The config and the runc
# delegation wrappers live on /data so an operator can roll them back
# without rebuilding the image.
#
# The 3-step delegation:
#   containerd  ->  /usr/sbin/runc  (bind-mounted to runc-nvidia wrapper)
#                ->  /usr/bin/nvidia-container-runtime
#                ->  /usr/sbin/runc.real (the real runc, baked into the
#                                          image at build time)
# Both the wrapper and the toml config live in /usr/lib/nvidia-cc/runtime/
# (read-only erofs) and are bind-mounted over /usr/sbin/runc and
# /etc/nvidia-container-runtime/config.toml from there. /data carries no
# code or runtime configuration.
NVCONFIG=/usr/lib/nvidia-cc/runtime/nvidia-config.toml
RUNC_NVIDIA=/usr/lib/nvidia-cc/runtime/runc-nvidia

echo ">>> Bind-mounting nvidia runtime overrides"
mountpoint -q /usr/sbin/runc 2>/dev/null \
  || mount --bind "$RUNC_NVIDIA" /usr/sbin/runc \
  || echo "WARNING: failed to bind-mount runc wrapper"
mountpoint -q /etc/nvidia-container-runtime/config.toml 2>/dev/null \
  || mount --bind "$NVCONFIG" /etc/nvidia-container-runtime/config.toml \
  || echo "WARNING: failed to bind-mount nvidia config"

echo "=== cvm-runtime-init finished at $(date) ==="
exit 0
