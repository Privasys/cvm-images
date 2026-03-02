# tdx-image-base

A minimal, read-only, fully measured VM image for [Intel TDX](https://www.intel.com/content/www/us/en/developer/tools/trust-domain-extensions/overview.html) confidential computing. Built with [mkosi](https://github.com/systemd/mkosi).

The image is cloud-agnostic at its core — a standard GPT disk with a UKI, erofs root, and dm-verity hash tree. It can run on any TDX-capable hypervisor (GCP, Azure, bare-metal QEMU/KVM). This repository includes a deployment guide for **Google Cloud Platform**; guides for other platforms will follow.

This is the base OS image. Application-specific layers (services, binaries) are built on top of it in separate repositories.

## Trust chain

```
Silicon (TDX hardware)
  └─ MRTD — measures the TD firmware (OVMF/TDVF) loaded by the hypervisor
      └─ RTMR[0] — measures the firmware configuration
          └─ RTMR[1] — measures the UKI (kernel + initrd + cmdline with dm-verity root hash)
              └─ dm-verity — every block of the rootfs verified against the hash tree
                  └─ All userland binaries — any modification = I/O error + kernel panic
```

Every byte of code that executes on the machine is either measured by TDX hardware or verified by dm-verity. No gaps.

## What's in the image

| Component | Details |
|-----------|---------|
| Guest OS | Ubuntu 24.04 LTS (Noble Numbat) |
| Kernel | `linux-image-generic` (6.8+) |
| Root filesystem | erofs (read-only) |
| Integrity | dm-verity hash tree |
| Boot | Unsigned [Unified Kernel Image](https://uapi-group.org/specifications/specs/unified_kernel_image/) via systemd-boot |
| Partitions | ESP (512 MB) + root erofs (~940 MB) + verity hash (~63 MB) |
| Networking | systemd-networkd with DHCP |
| SSH | openssh-server (password auth disabled) |
| Attestation support | tpm2-tools, clevis, cryptsetup |
| Cloud integration | google-compute-engine, google-guest-agent (GCP; removable for other platforms) |

## Pre-built images

Download the latest `.tar.gz` from [Releases](https://github.com/Privasys/tdx-image-base/releases). Each release contains a raw disk image (`disk.raw` inside the archive) that can be imported into any TDX-capable platform.

## Building from source

### Prerequisites

A Linux build machine running Ubuntu 24.04 (a GCP VM, WSL2, or any Linux box).

```bash
sudo apt update && sudo apt upgrade -y

# mkosi v27+ from GitHub main (Ubuntu's packaged version is too old)
sudo pip3 install git+https://github.com/systemd/mkosi.git --break-system-packages

# Build tools
sudo apt install -y \
    systemd-ukify systemd-boot-efi systemd-repart \
    mtools dosfstools e2fsprogs squashfs-tools \
    veritysetup cryptsetup erofs-utils \
    pesign sbsigntools debootstrap

# systemd-boot provides bootctl, needed by mkosi for ESP population
sudo apt install -y systemd-boot
```

### Build

```bash
git clone https://github.com/Privasys/tdx-image-base.git
cd tdx-image-base
sudo mkosi build
```

Output: `privasys-tdx-base_0.1.0.raw` (~1.5 GB)

Verify the partition layout:

```bash
sudo fdisk -l privasys-tdx-base_0.1.0.raw
# Expected:
#   1. EFI System Partition (~512 MB, FAT32, contains the UKI)
#   2. Root partition (erofs, dm-verity data, ~940 MB)
#   3. Root verity partition (dm-verity hash tree, ~63 MB)
```

### Test locally with QEMU

```bash
sudo apt install -y qemu-system-x86 swtpm ovmf

mkdir -p /tmp/vtpm
swtpm socket \
    --tpmstate dir=/tmp/vtpm \
    --ctrl type=unixio,path=/tmp/vtpm/swtpm.sock \
    --tpm2 --log level=5 &

qemu-system-x86_64 \
    -machine type=q35,accel=kvm -cpu host -m 2048 \
    -bios /usr/share/OVMF/OVMF_CODE.fd \
    -drive file=privasys-tdx-base_0.1.0.raw,format=raw,if=virtio \
    -chardev socket,id=chrtpm,path=/tmp/vtpm/swtpm.sock \
    -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device tpm-tis,tpmdev=tpm0 \
    -netdev user,id=net0,hostfwd=tcp::2222-:22 \
    -device virtio-net-pci,netdev=net0 \
    -nographic
```

Once booted:

```bash
mount | grep verity        # dm-verity active on root
touch /test 2>&1           # "Read-only file system"
tpm2_pcrread sha256:0,1,2,3,4,5,7,11
```

Exit QEMU: `Ctrl-A X`

## Deploying to Google Cloud Platform

### Package and upload

```bash
# GCP expects disk.raw inside a tar.gz
cp privasys-tdx-base_0.1.0.raw disk.raw
tar -czf privasys-tdx-base-0.1.0.tar.gz disk.raw
rm disk.raw

# Upload to your GCS bucket
gcloud storage cp privasys-tdx-base-0.1.0.tar.gz gs://YOUR_BUCKET/
```

### Create a GCP image

```bash
gcloud compute images create privasys-tdx-base-0-1-0 \
    --source-uri=gs://YOUR_BUCKET/privasys-tdx-base-0.1.0.tar.gz \
    --guest-os-features=TDX_CAPABLE,UEFI_COMPATIBLE,GVNIC,VIRTIO_SCSI_MULTIQUEUE \
    --family=privasys-tdx \
    --description="Privasys TDX base image v0.1.0 - Ubuntu 24.04, erofs root, dm-verity, unsigned UKI"
```

### Launch a TDX VM

```bash
gcloud compute instances create my-tdx-vm \
    --zone=europe-west9-a \
    --machine-type=c3-standard-4 \
    --network-interface=nic-type=GVNIC \
    --maintenance-policy=TERMINATE \
    --create-disk=auto-delete=yes,boot=yes,image=projects/YOUR_PROJECT/global/images/family/privasys-tdx,size=10,type=pd-balanced \
    --shielded-secure-boot \
    --shielded-vtpm \
    --shielded-integrity-monitoring \
    --confidential-compute-type=TDX
```

### Verify

```bash
gcloud compute ssh my-tdx-vm

ls -l /dev/tdx_guest          # TDX device present
mount | grep verity            # dm-verity on root
touch /test 2>&1               # Read-only file system
tpm2_pcrread sha256:0,1,2,3,4,5,7,11
```

## Deploying to OVHcloud bare metal (Scale-i1 / Xeon Gold 6426Y)

OVHcloud Scale-i1 servers ship Intel Xeon Gold 6426Y (Sapphire Rapids), which has hardware TDX support. On bare metal you control both the **host** and the **guest**, so you need to set up the TDX host stack before launching VMs with this image.

### 1. Prepare the host

Install Ubuntu 24.04 on the bare-metal server, then set up the TDX host stack using [canonical/tdx](https://github.com/canonical/tdx):

```bash
# On the OVHcloud bare-metal host
git clone https://github.com/canonical/tdx.git
cd tdx
sudo ./setup-host.sh

# Reboot into the TDX-enabled kernel
sudo reboot
```

After reboot, verify TDX is active:

```bash
dmesg | grep -i tdx
# Expected: "TDX module initialized"

ls /dev/tdx_host
# Should exist
```

### 2. Install guest tooling

```bash
sudo apt install -y qemu-system-x86 libvirt-daemon-system virtinst swtpm
```

### 3. Launch the image as a TDX VM

Using QEMU directly:

```bash
# Copy the raw image to the host
cp privasys-tdx-base_0.1.0.raw /var/lib/libvirt/images/

qemu-system-x86_64 \
    -accel kvm \
    -cpu host \
    -machine q35,kernel-irqchip=split,confidential-guest-support=tdx0,memory-backend=ram1 \
    -object tdx-guest,id=tdx0 \
    -object memory-backend-memfd,id=ram1,size=4G,share=true \
    -m 4G \
    -smp 4 \
    -bios /usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive file=/var/lib/libvirt/images/privasys-tdx-base_0.1.0.raw,format=raw,if=virtio \
    -chardev socket,id=chrtpm,path=/tmp/vtpm/swtpm.sock \
    -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device tpm-crb,tpmdev=tpm0 \
    -netdev bridge,id=net0,br=virbr0 \
    -device virtio-net-pci,netdev=net0 \
    -nographic
```

Or using libvirt (recommended for production):

```bash
virt-install \
    --name privasys-tdx \
    --ram 4096 --vcpus 4 \
    --cpu host \
    --machine q35 \
    --boot uefi \
    --disk /var/lib/libvirt/images/privasys-tdx-base_0.1.0.raw,format=raw \
    --network bridge=virbr0 \
    --tpm model=tpm-crb,type=emulator,version=2.0 \
    --launchSecurity type=tdx \
    --import --noautoconsole

virsh console privasys-tdx
```

### 4. Verify inside the VM

```bash
ls -l /dev/tdx_guest          # TDX device present
dmesg | grep -i tdx           # TDX guest messages
mount | grep verity            # dm-verity on root
touch /test 2>&1               # Read-only file system
tpm2_pcrread sha256:0,1,2,3,4,5,7,11
```

### Notes on bare-metal TDX

- **BIOS settings:** Ensure TDX, TME-MK (Total Memory Encryption Multi-Key), and SGX are enabled in the UEFI/BIOS. OVHcloud may require a support ticket to enable these on Scale-i1.
- **Kernel version:** The host needs kernel 6.7+ for TDX host support. The canonical/tdx setup script handles this.
- **Multiple VMs:** You can run many TDX VMs on a single host. Each gets its own isolated Trust Domain with independent measurements.
- **Attestation:** On bare metal, attestation goes through the Intel PCS (Provisioning Certification Service) or your own PCCS. This differs from GCP, which wraps attestation in its Confidential Computing API.
- **Networking:** The example uses libvirt's default bridge (`virbr0`). For production, configure a dedicated bridge on the OVHcloud public/private network interface.

## Repository structure

```
mkosi.conf                  # Main build configuration
mkosi.conf.d/
  uki.conf                  # Unified Kernel Image settings
mkosi.repart/
  00-esp.conf               # EFI System Partition
  10-root.conf              # Root filesystem (erofs + dm-verity)
  11-root-verity.conf       # Verity hash partition
mkosi.extra/                # Files overlaid onto the image
  etc/
    resolv.conf             # → /run/systemd/resolve/stub-resolv.conf
    systemd/
      network/
        10-gcp.network      # DHCP configuration (works on any platform)
      system/
        multi-user.target.wants/
          systemd-networkd.service
        sockets.target.wants/
          systemd-networkd.socket
        sysinit.target.wants/
          systemd-networkd-wait-online.service
    ssh/sshd_config.d/
      50-hardened.conf      # Hardened SSH config
    tmpfiles.d/
      readwrite.conf        # Writable directories on read-only rootfs
```

## How updates work

The rootfs is read-only — `apt install` on a running VM is impossible. To update:

1. Edit configs in this repo (add/update packages, bump `ImageVersion`)
2. `sudo mkosi build`
3. Test locally with QEMU
4. Upload and register the new image on your cloud platform
5. Create new VM, attach existing data disk, delete old VM

The data partition (LUKS-encrypted, separate persistent disk) survives image updates.

## Building application layers

To add services (e.g. a reverse proxy, database) on top of this base image:

1. Add packages to `Packages=` in `mkosi.conf`, or drop static binaries into `mkosi.extra/usr/local/bin/`
2. Add systemd unit files in `mkosi.extra/etc/systemd/system/`
3. Point data directories to `/data/` (the LUKS-encrypted persistent disk mount)
4. Rebuild and redeploy

All added binaries remain **fully measured by dm-verity** — the trust chain is preserved.

## Design notes

- **Why erofs?** Read-only by design, smaller than ext4, ideal for dm-verity. No accidental writes possible.
- **Why unsigned UKI?** TDX measures the UKI into RTMR[1] regardless of Secure Boot signature status. On platforms using TDVF (e.g. GCP), signing adds complexity without security benefit. For platforms that enforce Secure Boot, set `UnifiedKernelImages=signed` and provide signing keys.
- **Why mkosi.extra symlinks instead of mkosi.postinst?** With erofs, the filesystem is already read-only when postinst runs. `systemctl enable` writes symlinks to `/etc`, which fails on a read-only filesystem.
- **Why `Repositories=universe`?** Required for packages like `clevis` that aren't in Ubuntu's `main` repository.
- **Why `CopyFiles=/:/` in the root partition config?** erofs requires explicit file population — without this directive, the root partition is empty.

## License

[GNU Affero General Public License v3.0](LICENSE)

## Security

See [SECURITY.md](SECURITY.md) for vulnerability reporting.
