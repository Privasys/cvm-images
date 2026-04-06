# Privasys Confidential VM Images

Minimal, read-only, fully measured VM images for confidential computing. Supports [Intel TDX](https://www.intel.com/content/www/us/en/developer/tools/trust-domain-extensions/overview.html) and [AMD SEV-SNP](https://www.amd.com/en/developer/sev.html). Built with [mkosi](https://github.com/systemd/mkosi).

These images are the base OS layer used by [Enclave OS Virtual](https://docs.privasys.org/solutions/enclave-os/presentation/). They are published here for transparency and reproducibility. To deploy confidential workloads, use [Enclave OS Virtual](https://docs.privasys.org/solutions/enclave-os/presentation/) which builds on these images and provides [RA-TLS](https://docs.privasys.org/technology/attestation/attested-connections/), container orchestration, and attestation out of the box.

## Images

| Image | Directory | TEE | Description |
|-------|-----------|-----|-------------|
| **tdx-base** | `images/tdx-base/` | Intel TDX | Base image for TDX confidential VMs |
| **sev-snp-base** | `images/sev-snp-base/` | AMD SEV-SNP | Base image for SEV-SNP confidential VMs |
| **sev-snp-gpu** | `images/sev-snp-gpu/` | AMD SEV-SNP + NVIDIA H100 | Confidential AI inference with GPU CC mode |

All images share the same security architecture: erofs root, dm-verity, Secure Boot, kernel lockdown. Shared overlay files (network, SSH, tmpfiles) live in `common/mkosi.extra/`.

The images are cloud-agnostic at their core, a standard GPT disk with a GRUB-booted kernel, erofs root, and dm-verity hash tree. They can run on any capable hypervisor (GCP, Azure, bare-metal QEMU/KVM). See [Deployment guides](#deployment-guides) for platform-specific instructions.

This is the base OS image used by [Enclave OS Virtual](https://docs.privasys.org/solutions/enclave-os/presentation/). Application-specific layers (containers, services) are deployed through the platform, not built directly on top of these images.

## Trust chain

The images use the same trust chain architecture regardless of the TEE platform (TDX or SEV-SNP):

```
Silicon (TEE hardware root of trust)
  └─ Firmware measurement - measures the VM firmware loaded by the hypervisor
      └─ Secure Boot - UEFI verifies each bootloader stage cryptographically
          └─ Boot measurement - measures kernel, initrd, and command line into TEE registers
              └─ dm-verity - every block of the rootfs verified against a Merkle hash tree
                  └─ All userland binaries - any modification = I/O error + kernel panic
```

Every byte of code that executes on the machine is either measured by TEE hardware or verified by dm-verity. No gaps. For platform-specific measurement details, see [TDX](docs/tdx.md).

## Security documentation

| Document | Description |
|----------|-------------|
| [Security overview](docs/security.md) | Threat model, attack surfaces, and guarantees |
| [Hardening guide](docs/hardening.md) | Security architecture and design decisions |
| [Encrypted storage](docs/encrypted-storage.md) | LUKS-encrypted persistent volumes with TEE-bound keys |
| [Image integrity](docs/image-integrity.md) | Supply chain security, dm-verity, reproducible builds |
| [GCP comparison](docs/gcp-comparison.md) | Why we build our own images instead of using Google's |
| [Intel TDX](docs/tdx.md) | TDX trust chain, measurement registers, stack diagram |

## What's in the image

| Component | Details |
|-----------|---------|
| Guest OS | Ubuntu 24.04 LTS (Noble Numbat) |
| Kernel | `linux-image-generic-hwe-24.04` (6.19, HWE; auto-tracks latest; TDX + SEV guest support since 6.7) + [CVM Guard patch](patches/) |
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

Download the latest `.tar.gz` from [Releases](https://github.com/Privasys/cvm-images/releases). Releases are tagged per image: `tdx-base-v*`, `sev-snp-base-v*`, `sev-snp-gpu-v*`. Each release contains a raw disk image (`disk.raw` inside the archive) that can be imported into any capable platform.

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
git clone https://github.com/Privasys/cvm-images.git
cd cvm-images

# Build a specific image:
cd images/tdx-base && sudo mkosi build
# or: cd images/sev-snp-base && sudo mkosi build
# or: cd images/sev-snp-gpu && sudo mkosi build
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

| Platform | TEE | Guide |
|----------|-----|-------|
| Google Cloud Platform | TDX | [docs/deploy-gcp.md](docs/deploy-gcp.md) |
| OVHcloud bare metal (Scale-i1) | TDX | [docs/deploy-ovhcloud.md](docs/deploy-ovhcloud.md) |

## Where this fits

These images are the **guest OS** layer. They run inside the TEE hardware (TDX Trust Domain or SEV-SNP VM), on top of the host/hypervisor managed by the cloud provider (or your own bare-metal stack), and below the application containers deployed via [Enclave OS Virtual](https://docs.privasys.org/solutions/enclave-os/presentation/).

For TDX-specific stack diagrams and measurement register details, see [docs/tdx.md](docs/tdx.md).

## Repository structure

```
images/
  tdx-base/                   # Intel TDX base image
    mkosi.conf                # Image-specific configuration
    mkosi.conf.d/boot.conf    # TDX kernel command line
    mkosi.repart/             # Partition layout
  sev-snp-base/               # AMD SEV-SNP base image
    mkosi.conf
    mkosi.conf.d/boot.conf    # SEV kernel command line (mem_encrypt=on)
    mkosi.repart/
  sev-snp-gpu/                # AMD SEV-SNP + NVIDIA H100
    mkosi.conf                # Adds NVIDIA driver, CUDA, container toolkit
    mkosi.conf.d/boot.conf    # GPU CC mode (iommu=nopt, NVreg_ConfidentialComputing)
    mkosi.extra/              # NVIDIA service enables
    mkosi.prepare             # Adds NVIDIA apt repos
    mkosi.repart/             # Includes 500G data partition for models
common/
  mkosi.extra/                # Shared overlay files
    etc/
      resolv.conf
      systemd/
        network/10-gcp.network
        system/ (service enables)
      ssh/sshd_config.d/50-hardened.conf
      tmpfiles.d/readwrite.conf
build-kernel.sh               # Patched CVM guard kernel build script
patches/                      # Kernel patches (BadAML CVM guard)
docs/
  security.md                 # Security overview and threat model
  hardening.md                # Security architecture and design decisions
  encrypted-storage.md        # LUKS-encrypted persistent volumes
  image-integrity.md          # Supply chain security and reproducible builds
  gcp-comparison.md           # Comparison with Google's Confidential VM images
  tdx.md                      # Intel TDX trust chain and stack diagram
  deploy-gcp.md               # Google Cloud Platform deployment guide
  deploy-ovhcloud.md          # OVHcloud bare-metal deployment guide
```

## How updates work

The rootfs is read-only — `apt install` on a running VM is impossible. To update:

1. Edit configs in this repo (add/update packages, bump `ImageVersion`)
2. `cd images/<name> && sudo mkosi build`
3. Test locally with QEMU
4. Upload and register the new image on your cloud platform
5. Create new VM, attach existing data disk, delete old VM

The data partition (LUKS-encrypted, separate persistent disk) survives image updates.

## Deploying workloads

These images provide the hardened base OS. To deploy applications (containers, services, AI models), use [Enclave OS Virtual](https://docs.privasys.org/solutions/enclave-os/presentation/) which handles container orchestration, [RA-TLS](https://docs.privasys.org/technology/attestation/attested-connections/) certificate management, and attestation automatically.

All application code deployed through Enclave OS Virtual is measured into the RA-TLS certificate's X.509 extensions, extending the trust chain from the base OS all the way to the application layer.

## Vulnerability response

A key advantage of maintaining our own CVM images is the ability to patch vulnerabilities immediately, without waiting for upstream vendors or cloud providers to act.

**Example: BadAML (ACPI firmware injection).** When the BadAML vulnerability was disclosed, demonstrating that a hypervisor could inject malicious ACPI bytecode to access TEE-private memory, we developed and shipped a kernel patch within days. The CVM Guard patch (in [patches/](patches/)) blocks AML bytecode from accessing pages marked as private/encrypted. This was possible because we control the full image pipeline: kernel, rootfs, and boot chain. An adopter relying on a vendor-provided CVM image would have had to wait for the vendor to acknowledge, triage, patch, and release an updated image.

This pattern applies to any future vulnerability in the TEE software stack:

1. **We monitor** TEE vendor advisories, academic research, and upstream kernel security lists.
2. **We patch** the affected component (kernel, firmware config, boot chain, systemd units) directly in this repository.
3. **We rebuild** the image with the fix included and publish a new release with updated measurement values.
4. **Adopters update** through [Enclave OS Virtual](https://docs.privasys.org/solutions/enclave-os/presentation/), which handles image rollout and attestation policy updates.

The entire pipeline from patch to deployment runs through code we own and CI we control. There are no external gatekeepers.

## Design notes

- **Why erofs?** Read-only by design, smaller than ext4, ideal for dm-verity. No accidental writes possible.
- **Why GRUB instead of UKI?** Cloud TDX firmware (TDVF) enforces Secure Boot, which silently rejects unsigned EFI binaries including systemd-boot and unsigned UKIs. GRUB is the proven boot chain for TDX and SEV-SNP on cloud platforms. The TEE hardware still measures the full boot chain regardless of the bootloader used.
- **Why `linux-image-generic-hwe-24.04`?** The HWE (Hardware Enablement) kernel tracks the latest LTS-backported kernel on Noble, currently 6.19. TDX and SEV guest support has been upstream since 6.7.
- **Why mkosi.extra symlinks instead of mkosi.postinst?** With erofs, the filesystem is already read-only when postinst runs. `systemctl enable` writes symlinks to `/etc`, which fails on a read-only filesystem.
- **Why `Repositories=universe`?** Required for packages like `clevis` that aren't in Ubuntu's `main` repository.
- **Why `CopyFiles=/:/` in the root partition config?** erofs requires explicit file population - without this directive, the root partition is empty.

## License

[GNU Affero General Public License v3.0](LICENSE)

## Security

See [SECURITY.md](SECURITY.md) for vulnerability reporting.
