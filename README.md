# Privasys Confidential VM Images

Minimal, read-only, fully measured VM images for confidential computing. Supports [Intel TDX](https://www.intel.com/content/www/us/en/developer/tools/trust-domain-extensions/overview.html) and [AMD SEV-SNP](https://www.amd.com/en/developer/sev.html). Built with [mkosi](https://github.com/systemd/mkosi).

These images are the base OS layer used by [Enclave OS Virtual](https://docs.privasys.org/solutions/enclave-os/presentation/). They are published here for transparency and reproducibility. To deploy confidential workloads, use [Enclave OS Virtual](https://docs.privasys.org/solutions/enclave-os/presentation/) which builds on these images and provides [RA-TLS](https://docs.privasys.org/technology/attestation/attested-connections/), container orchestration, and attestation out of the box.

## Images

| Image | Directory | TEE | Description |
|-------|-----------|-----|-------------|
| **tdx-base** | `images/tdx-base/` | Intel TDX | Base image for TDX confidential VMs |
| **tdx-gpu** | `images/tdx-gpu/` | Intel TDX + NVIDIA H100 | Confidential AI inference with GPU CC mode (GCP A3) |
| **sev-snp-base** | `images/sev-snp-base/` | AMD SEV-SNP | Base image for SEV-SNP confidential VMs |
| **sev-snp-gpu** | `images/sev-snp-gpu/` | AMD SEV-SNP + NVIDIA H100 | Confidential AI inference with GPU CC mode |

All images share the same security architecture: erofs root, dm-verity, TEE measured boot, kernel lockdown (`lockdown=integrity`, `module.sig_enforce=1`). On `tdx-gpu` the runtime-loaded patched NVIDIA CC modules satisfy module signature enforcement because they are signed with the kernel build's ephemeral key, whose certificate lives in the kernel's builtin trusted keyring — kernel and module bundle always come from the same `kernel-v*` release.

Shared overlay files live in `common/mkosi.extra/`:

| File | Purpose |
|------|---------|
| `etc/resolv.conf` | Symlink to systemd-resolved |
| `etc/nsswitch.conf` | Name service switch (passwd, group, hosts) |
| `etc/ssh/sshd_config.d/50-hardened.conf` | Disable password auth, restrict root login (only takes effect in `dev` builds — production images contain no SSH daemon) |
| `etc/sysctl.d/60-apparmor-userns.conf` | Allow container runtime user namespaces |
| `etc/systemd/network/10-dhcp.network` | DHCP networking on en* interfaces |
| `etc/tmpfiles.d/readwrite.conf` | Runtime directories on tmpfs |
| `usr/lib/systemd/system/tmp.mount` | Volatile /tmp (256 MB tmpfs) |
| `usr/lib/systemd/system/var-log.mount` | Volatile /var/log (64 MB tmpfs) |
| `usr/lib/systemd/system/var-tmp.mount` | Volatile /var/tmp (64 MB tmpfs) |

Cloud-specific additions (GCP guest agent, OS Login, SSH metadata keys) are applied via **mkosi profiles**. See [Cloud profiles](#cloud-profiles).

GPU images add NVIDIA driver packages, CUDA toolkit, container runtime integration, and kernel command line parameters for Confidential Computing mode.

**Downstream consumers:** [Enclave OS Virtual](https://docs.privasys.org/solutions/enclave-os/presentation/) imports from this repository for both base and GPU images. The base image imports `common/mkosi.extra/` and `tdx-base/mkosi.conf.d/boot.conf`. The GPU image additionally imports from `tdx-gpu/` (NVIDIA repos, prepare scripts, persistenced overlay).

The images are cloud-agnostic at their core, a standard GPT disk with a GRUB-booted kernel, erofs root, and dm-verity hash tree. They can run on any capable hypervisor (GCP, Azure, bare-metal QEMU/KVM). See [Deployment guides](#deployment-guides) for platform-specific instructions.

This is the base OS image used by [Enclave OS Virtual](https://docs.privasys.org/solutions/enclave-os/presentation/). Application-specific layers (containers, services) are deployed through the platform, not built directly on top of these images.

## Trust chain

The images use the same trust chain architecture regardless of the TEE platform (TDX or SEV-SNP):

```
Silicon (TEE hardware root of trust)
  └─ Firmware measurement - measures the VM firmware loaded by the hypervisor
      └─ Boot measurement - measures bootloader, kernel, initrd, and command line into TEE registers
          └─ dm-verity - every block of the rootfs verified against a Merkle hash tree
              └─ All userland binaries - any modification = I/O error + kernel panic
```

Every byte of code that executes on the machine is either measured by TEE hardware or verified by dm-verity. A tampered bootloader, kernel, or rootfs produces different measurement values, fails remote attestation, and is never released any secrets.

**Why measured boot instead of UEFI Secure Boot?** Secure Boot only proves that *someone on the platform's certificate list* signed the boot chain — and ties you to the cloud provider's and OS vendor's keys. TEE measured boot proves the *exact bytes* that booted, with the root of trust in the CPU silicon rather than a certificate database the hypervisor owner controls. Our images use the CVM Guard patched kernel (not Canonical-signed), so VMs are deployed with Secure Boot disabled and integrity is enforced end-to-end through attestation. This keeps the images fully cloud-agnostic. For platform-specific measurement details, see [TDX](docs/tdx.md).

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
| Kernel | CVM Guard patched Ubuntu HWE (BadAML mitigation, [patches/](patches/)), ABI-pinned, built by `build-kernel.sh` and shipped as `kernel-v*` GitHub releases. All images install the patched kernel; it is unsigned, so boot integrity comes from TEE measured boot rather than UEFI Secure Boot. |
| Root filesystem | erofs (read-only) |
| Integrity | dm-verity hash tree |
| Boot | shim → GRUB → kernel + initrd + dm-verity roothash in cmdline; every stage measured into TEE registers (RTMR/PCR) |
| Boot integrity | **TEE measured boot** (attestation-enforced). UEFI Secure Boot is disabled at deploy time: the CVM Guard patched kernel is not Canonical-signed, and the trust model intentionally does not depend on cloud/vendor certificate databases |
| Partitions | ESP (512 MB) + root erofs (~940 MB) + verity hash (~63 MB) + (GPU images only) 2 GB `data` placeholder |
| Persistent data | **Not on the boot disk.** Provided by a separate cloud persistent disk attached as `device-name=data` at deploy time, formatted LUKS2+AEAD by [Enclave OS Virtual](https://docs.privasys.org/solutions/enclave-os/presentation/). Survives image upgrades and Spot preemption. |
| Networking | systemd-networkd with DHCP |
| SSH | **None in production images.** `--profile dev` adds openssh-server (password auth disabled) plus debugging tools |
| Attestation support | tpm2-tools, clevis, cryptsetup |
| Cloud integration | Optional via `--profile gcp` (google-compute-engine, google-guest-agent, OS Login) |

## Pre-built images

Download the latest `.tar.gz` from [Releases](https://github.com/Privasys/cvm-images/releases). Releases are tagged per image: `tdx-base-v*`, `tdx-gpu-v*`, `sev-snp-base-v*`, `sev-snp-gpu-v*`. Each release contains a raw disk image (`disk.raw` inside the archive) that can be imported into any capable platform.

### Published measurements

Every release publishes, next to each artifact:

| File | Contents |
|------|----------|
| `<artifact>.sha256` | SHA-256 of the artifact (download integrity) |
| `<artifact>.roothash` | dm-verity root hash — the code identity of the rootfs, recomputed from the artifact in CI |
| `<artifact>.measurements.json` | **Predicted TDX RTMR[1] and RTMR[2]** plus the per-event digest manifest, computed from the artifact by [`predict-measurements.py`](predict-measurements.py) (TDX images only) |

The RTMR predictor derives every measured boot event from the image
itself — GPT, shim/GRUB PE Authenticode digests, the grub.cfg command
sequence, kernel, command line (including the verity roothash), and
initrds — and replays the SHA-384 extend chain. The values match what
TDX hardware reports at boot; no "golden boot" is required to obtain
reference measurements. (MRTD measures the platform's TD firmware and
is pinned per platform; SEV-SNP launch-measurement prediction is
tracked separately.)

Builds are made deterministic in inputs by pinning the apt universe to
a dated [snapshot.ubuntu.com](https://snapshot.ubuntu.com) timestamp in
each image's `mkosi.conf` (`Mirror=`), the kernel to an exact ABI from
our own `kernel-v*` releases, and mkosi plus all CI actions to commit
SHAs.

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

# Stage the patched CVM Guard kernel for the image you are building
# (CI does this automatically). For tdx-gpu, also stage the signed
# NVIDIA CC bundle under mkosi.extra.nvidia-cc/ - see
# .github/workflows/build-tdx-gpu.yml for the exact layout.
gh release download kernel-v0.4.0 -R Privasys/cvm-images \
    --pattern 'linux-*.deb' --dir images/tdx-base/kernel-debs

# Build a cloud-agnostic image (no cloud-specific packages):
cd images/tdx-base && sudo mkosi build

# Build with GCP support (adds google-guest-agent, OS Login, metadata SSH keys):
cd images/tdx-base && sudo mkosi --profile gcp build

# Other images:
# cd images/tdx-gpu && sudo mkosi [--profile gcp] build
# cd images/sev-snp-base && sudo mkosi [--profile gcp] build
# cd images/sev-snp-gpu && sudo mkosi [--profile gcp] build
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

## Cloud profiles

The base images are **cloud-agnostic** - they contain no cloud-provider-specific packages or configuration. Cloud-specific additions are applied via [mkosi profiles](https://github.com/systemd/mkosi):

| Profile | Adds | Use case |
|---------|------|----------|
| `gcp` | `google-compute-engine`, `google-guest-agent`, `google-compute-engine-oslogin`, GCE SSH key lookup, OS Login nsswitch | Google Cloud Platform |
| `dev` | `openssh-server`, `openssh-client`, `strace`, `tcpdump`, `curl`, `jq`. Changes `ImageId` to `*-dev` so dev artifacts (and their measurements) are unambiguous | Development and debugging **only** — never production |
| *(none)* | Nothing extra | Bare metal, QEMU/KVM, OVHcloud, or any other platform |

Production images contain **no SSH daemon and no interactive entry point**: every code path that can execute in a production CVM is measured at build time, and a runtime shell would break that guarantee. Workloads are deployed and managed through [Enclave OS Virtual](https://docs.privasys.org/solutions/enclave-os/presentation/) over the attested API. CI enforces this — the production image build fails if `sshd` is present in the rootfs.

To build with profiles:

```bash
cd images/tdx-base && sudo mkosi --profile gcp build

# Development build (adds SSH + debug tools, ImageId gets a -dev suffix):
cd images/tdx-base && sudo mkosi --profile gcp --profile dev build
```

Profile files live in `mkosi.profiles/<name>/mkosi.conf` within each image directory. The shared GCP overlay files (SSH metadata key script, OS Login nsswitch, runtime directories) live in `common/mkosi.extra.gcp/`.

Adding a new cloud provider (e.g. AWS, Azure) requires:

1. Create `common/mkosi.extra.<cloud>/` with provider-specific overlay files
2. Add `mkosi.profiles/<cloud>/mkosi.conf` in each image directory with the relevant packages and `ExtraTrees=`

## Deployment guides

| Platform | TEE | Guide |
|----------|-----|-------|
| Google Cloud Platform | TDX | [docs/deploy-gcp.md](docs/deploy-gcp.md) |
| Google Cloud Platform | TDX + GPU | [docs/deploy-gcp-gpu.md](docs/deploy-gcp-gpu.md) |
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
    mkosi.profiles/gcp/       # GCP profile (packages + overlay)
    mkosi.repart/             # Partition layout
  tdx-gpu/                    # Intel TDX + NVIDIA H100
    mkosi.conf                # Adds NVIDIA 595 server-open modules + minimal userspace (nvidia-smi, libcuda), container toolkit. No CUDA toolkit: workload containers ship their own CUDA runtime
    mkosi.conf.d/boot.conf    # GPU CC mode (iommu=pt, NVreg_ConfidentialComputing)
    mkosi.extra/              # NVIDIA service enables
    mkosi.profiles/gcp/       # GCP profile
    mkosi.pkgmanager/         # NVIDIA/CUDA apt repos + GPG keys + driver pinning
    mkosi.prepare             # Fix stray depmod directory from nvidia-kernel-source
    mkosi.postinst.chroot     # vmlinuz symlink, signed GRUB, vfat cleanup
    mkosi.repart/             # 2 GB on-disk `data` placeholder; real persistent data lives on a dedicated cloud PD attached at deploy time
  sev-snp-base/               # AMD SEV-SNP base image
    mkosi.conf
    mkosi.conf.d/boot.conf    # SEV kernel command line (mem_encrypt=on)
    mkosi.profiles/gcp/       # GCP profile
    mkosi.repart/
  sev-snp-gpu/                # AMD SEV-SNP + NVIDIA H100
    mkosi.conf                # Same NVIDIA 595 server-open stack as tdx-gpu + fabric manager (NVLink)
    mkosi.conf.d/boot.conf    # GPU CC mode (iommu=nopt, NVreg_ConfidentialComputing)
    mkosi.extra/              # NVIDIA service enables
    mkosi.profiles/gcp/       # GCP profile
    mkosi.prepare             # Fix stray depmod directory from nvidia-kernel-source
    mkosi.repart/             # 2 GB on-disk `data` placeholder; real persistent data lives on a dedicated cloud PD attached at deploy time
common/
  mkosi.extra/                # Shared cloud-agnostic overlay files
    etc/
      resolv.conf
      systemd/
        network/10-dhcp.network
        system/ (service enables)
      ssh/sshd_config.d/50-hardened.conf
      tmpfiles.d/readwrite.conf
  mkosi.extra.gcp/            # GCP-specific overlay (layered on top by profile)
    etc/
      nsswitch.conf           # Adds oslogin to passwd/group
      ssh/sshd_config.d/60-gce.conf
      tmpfiles.d/gcp.conf
    usr/bin/gce-authorized-keys
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
5. Create a new VM from the image, **re-attach the existing `data` PD**, delete the old VM

The `data` PD is a **separate cloud persistent disk** (attached as `device-name=data`), not a partition on the boot disk. The boot disk carries only ESP + erofs root + verity hash (and, for GPU images, a 2 GB on-disk `data` placeholder kept for legacy / first-boot bootstrap). All operator state — CA cert/key, manager configuration, container volumes, model weights — lives on the separate PD, formatted LUKS2+AEAD by [Enclave OS Virtual](https://docs.privasys.org/solutions/enclave-os/presentation/) on first attach. This decouples image lifecycle from data lifecycle: a new measurement (new dm-verity root hash) does not require migrating data, and Spot preemption never destroys it.

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
- **Why GRUB instead of UKI?** Historical: with Secure Boot enabled, cloud TDX firmware silently rejected unsigned EFI binaries including systemd-boot and unsigned UKIs, so GRUB's signed chain was the only workable option. Now that the trust model is measured-boot-only (Secure Boot off), a UKI becomes viable and is attractive for measurement prediction (a single PE binary measured into one RTMR event). Candidate for a future change.
- **Why `linux-image-generic-hwe-24.04`?** The HWE (Hardware Enablement) kernel tracks the latest LTS-backported kernel on Noble, currently the **6.17 series**. TDX and SEV guest support has been upstream since 6.7.
- **Why mkosi.extra symlinks instead of mkosi.postinst?** With erofs, the filesystem is already read-only when postinst runs. `systemctl enable` writes symlinks to `/etc`, which fails on a read-only filesystem.
- **Why `Repositories=universe`?** Required for packages like `clevis` that aren't in Ubuntu's `main` repository.
- **Why `CopyFiles=/:/` in the root partition config?** erofs requires explicit file population - without this directive, the root partition is empty.

## License

[GNU Affero General Public License v3.0](LICENSE)

## Security

See [SECURITY.md](SECURITY.md) for vulnerability reporting.
