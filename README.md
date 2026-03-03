# tdx-image-base

A minimal, read-only, fully measured VM image for [Intel TDX](https://www.intel.com/content/www/us/en/developer/tools/trust-domain-extensions/overview.html) confidential computing. Built with [mkosi](https://github.com/systemd/mkosi).

The image is cloud-agnostic at its core — a standard GPT disk with a GRUB-booted kernel, erofs root, and dm-verity hash tree. It can run on any TDX-capable hypervisor (GCP, Azure, bare-metal QEMU/KVM). See [Deployment guides](#deployment-guides) for platform-specific instructions.

This is the base OS image. Application-specific layers (services, binaries) are built on top of it in separate repositories.

## Trust chain

```
Silicon (TDX hardware)
  └─ MRTD — measures the TD firmware (OVMF/TDVF) loaded by the hypervisor
      └─ RTMR[0] — measures the firmware configuration
          └─ Secure Boot — UEFI verifies shimx64.efi (Microsoft) → grubx64.efi (Canonical) → kernel
              └─ RTMR[1] — measures the bootloader, kernel, initrd, and cmdline (with dm-verity root hash)
                  └─ dm-verity — every block of the rootfs verified against the hash tree
                      └─ All userland binaries — any modification = I/O error + kernel panic
```

Every byte of code that executes on the machine is either measured by TDX hardware or verified by dm-verity. No gaps.

## Why not use Google's Confidential VM image?

Google provides ready-made Confidential VM images such as **"Confidential image (Ubuntu 24.04 LTS NVIDIA version: 580)"**. They boot on TDX, they come pre-installed with NVIDIA drivers, and they require zero mkosi knowledge. So why build our own?

The answer is the trust chain above. A confidential VM is only as trustworthy as the code running inside it. Google's images are **general-purpose** — they are designed to run any workload — and that generality is fundamentally at odds with verifiability.

| | Google Confidential VM image | tdx-image-base |
|---|---|---|
| **Root filesystem** | ext4 (read-write) | erofs (read-only) |
| **dm-verity** | Not enabled | Enabled — every block verified |
| **Installed packages** | ~2000+ (full Ubuntu Desktop/Server stack, NVIDIA drivers, CUDA, cloud agents, snap, apt) | ~40 (minimal: kernel, systemd, openssh, attestation tools) |
| **Image size** | ~30 GB | ~1.5 GB |
| **Can modify rootfs at runtime** | Yes (`apt install`, write anywhere) | No (I/O error → kernel panic) |
| **Kernel modules** | All Ubuntu modules, unsigned third-party NVIDIA `.ko` | Ubuntu-signed modules only (`module.sig_enforce=1`) |
| **Kernel lockdown** | Not enforced | `lockdown=integrity` — no unsigned code in ring 0 |
| **Attack surface** | Large: writable FS, NVIDIA blob drivers, snap daemon, update services, package managers | Minimal: read-only FS, no package manager at runtime, no writable paths except tmpfs and data partition |
| **Reproducibility** | Opaque — Google builds the image, you trust their pipeline | Source-available — `mkosi build` produces the image from this repo |
| **What TDX actually attests** | "Some Ubuntu 24.04 image that Google built, with an unknown set of packages and configs" | "This exact erofs image, with this exact dm-verity root hash, bit-for-bit" |

### The core problem

TDX measures the initial memory contents of the VM (MRTD) and the boot chain (RTMRs). But measurements are only useful if you know **what was measured**. With a general-purpose image:

1. The rootfs is writable — software can be installed, patched, or replaced after boot. The TDX measurement covers the initial state, but the running state can drift arbitrarily.
2. There is no dm-verity — nothing prevents a compromised process from modifying binaries on disk. A rootkit that replaces `/usr/bin/sshd` would survive reboot.
3. The package set is enormous — thousands of packages means thousands of potential CVEs. Even if today's image is secure, the attack surface is orders of magnitude larger.
4. Unsigned kernel modules (e.g. NVIDIA blobs) can be loaded — any code running in ring 0 has full access to the guest's memory, which TDX is supposed to protect.

With tdx-image-base, the dm-verity root hash is baked into the kernel command line and measured by TDX. A remote verifier can check the RTMR values against the expected hash and know, cryptographically, that the VM is running **exactly** the code in this repository — not a modified version, not a version with extra packages, not a version where someone ran `apt install backdoor`.

### When to use Google's image

Google's Confidential VM images are fine when:
- You need NVIDIA GPU passthrough (CUDA, ML inference)
- You trust Google's image pipeline and don't need remote attestation of the OS
- Your threat model only requires memory encryption (TDX protects RAM from the host), not full-stack verifiability

### When to use this image

Use tdx-image-base when:
- You need **end-to-end verifiability** from silicon to application
- A remote party must cryptographically verify what code is running
- You want the smallest possible attack surface
- You treat the cloud provider as an adversary (the whole point of confidential computing)

## What's in the image

| Component | Details |
|-----------|---------|
| Guest OS | Ubuntu 24.04 LTS (Noble Numbat) |
| Kernel | `linux-image-gcp` (6.17+, auto-tracks latest; first Noble kernel with TDX guest support) |
| Root filesystem | erofs (read-only) |
| Integrity | dm-verity hash tree |
| Boot | Signed shim (Microsoft) → signed GRUB (Canonical) → kernel + initrd + dm-verity roothash in cmdline |
| Secure Boot | Enabled — full chain from UEFI firmware through bootloader to kernel |
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

# mkosi v26 (Ubuntu's packaged version is too old)
sudo pip3 install mkosi==26 --break-system-packages

# Build tools
sudo apt install -y \
    systemd-repart grub-efi-amd64-bin \
    mtools dosfstools e2fsprogs squashfs-tools \
    veritysetup cryptsetup erofs-utils \
    debootstrap
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
#   1. EFI System Partition (~512 MB, FAT32, GRUB + kernel + initrd)
#   2. Root partition (erofs, dm-verity data)
#   3. Root verity partition (dm-verity hash tree)
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

## Deployment guides

| Platform | Guide | TDX host managed by |
|----------|-------|---------------------|
| Google Cloud Platform | [docs/deploy-gcp.md](docs/deploy-gcp.md) | Google |
| OVHcloud bare metal (Scale-i1) | [docs/deploy-ovhcloud.md](docs/deploy-ovhcloud.md) | Operator (via [canonical/tdx](https://github.com/canonical/tdx)) |

## Where this fits in the TDX stack

This image is the **guest OS** layer. It sits on top of the host stack and below your application:

```
┌─────────────────────────────────────────────────────────────┐
│  intel/tdx-module                         Silicon firmware  │
│  TDX SEAM module running inside the CPU                     │
│  Creates & isolates Trust Domains, manages memory keys      │
│  Ships in CPU microcode — not user-serviceable              │
└──────────────────────────┬──────────────────────────────────┘
                           │ creates / measures
┌──────────────────────────▼──────────────────────────────────┐
│  canonical/tdx                          Host OS / hypervisor│
│  Modified kernel, QEMU, OVMF/TDVF, libvirt patches          │
│  Enables the host to launch TDX guests                      │
│  Only needed on bare metal (cloud providers handle this)    │
└──────────────────────────┬──────────────────────────────────┘
                           │ launches
┌──────────────────────────▼──────────────────────────────────┐
│  tdx-image-base (this repo)                 Guest OS image  │
│  GRUB boot, erofs root, dm-verity, attestation tools        │
│  The workload runs here                                     │
└──────────────────────────┬──────────────────────────────────┘
                           │ services go here
┌──────────────────────────▼──────────────────────────────────┐
│  Application layer                                          │
│  Reverse proxies, databases, application binaries           │
│  Built as a separate image on top of this base              │
└─────────────────────────────────────────────────────────────┘
```

| | [intel/tdx-module](https://github.com/intel/tdx-module) | [canonical/tdx](https://github.com/canonical/tdx) | tdx-image-base |
|---|---|---|---|
| **What** | CPU firmware (SEAM module) | Host-side Linux + QEMU patches | Guest VM disk image |
| **Runs where** | Inside the CPU | On the bare-metal host OS | Inside the Trust Domain |
| **On managed cloud** | Managed by provider | Managed by provider | **This repo** |
| **On bare metal** | In the CPU | **Operator installs** | **This repo** |
| **Licence** | Intel proprietary | GPL-2.0 (Ubuntu/kernel) | AGPL-3.0 |

## Repository structure

```
mkosi.conf                  # Main build configuration
mkosi.conf.d/
  boot.conf                 # Bootloader and kernel command line settings
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
docs/
  deploy-gcp.md             # Google Cloud Platform deployment guide
  deploy-ovhcloud.md        # OVHcloud bare-metal deployment guide
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
- **Why GRUB instead of UKI?** GCP's TDX firmware (TDVF) enforces Secure Boot, which silently rejects unsigned EFI binaries including systemd-boot and unsigned UKIs. GRUB is the proven boot chain for TDX on GCP and other cloud platforms. TDX still measures the full boot chain (kernel, initrd, cmdline) into RTMR registers regardless of the bootloader used.
- **Why mkosi.extra symlinks instead of mkosi.postinst?** With erofs, the filesystem is already read-only when postinst runs. `systemctl enable` writes symlinks to `/etc`, which fails on a read-only filesystem.
- **Why `Repositories=universe`?** Required for packages like `clevis` that aren't in Ubuntu's `main` repository.
- **Why `CopyFiles=/:/` in the root partition config?** erofs requires explicit file population — without this directive, the root partition is empty.

## License

[GNU Affero General Public License v3.0](LICENSE)

## Security

See [SECURITY.md](SECURITY.md) for vulnerability reporting.
