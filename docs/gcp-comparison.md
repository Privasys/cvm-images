# Why not use Google's Confidential VM image?

Google provides ready-made Confidential VM images such as **"Confidential image (Ubuntu 24.04 LTS NVIDIA version: 580)"**. They boot on TDX, they come pre-installed with NVIDIA drivers, and they require zero mkosi knowledge. So why does Privasys build its own?

The answer is the [trust chain](../README.md#trust-chain). A confidential VM is only as trustworthy as the code running inside it. Google's images are **general-purpose** - designed to run any workload - and that generality is fundamentally at odds with verifiability.

## Comparison

| | Google Confidential VM image | Privasys Confidential VM Images |
|---|---|---|
| **Root filesystem** | ext4 (read-write) | erofs (read-only) |
| **dm-verity** | Not enabled | Enabled - every block verified |
| **Installed packages** | ~2000+ (full Ubuntu Desktop/Server stack, NVIDIA drivers, CUDA, cloud agents, snap, apt) | ~40 (minimal: kernel, systemd, openssh, attestation tools) |
| **Image size** | ~30 GB | ~1.5 GB |
| **Can modify rootfs at runtime** | Yes (`apt install`, write anywhere) | No (I/O error -> kernel panic) |
| **Kernel modules** | All Ubuntu modules, unsigned third-party NVIDIA `.ko` | Ubuntu-signed modules only (`module.sig_enforce=1`) |
| **Kernel lockdown** | Not enforced | `lockdown=integrity` - no unsigned code in ring 0 |
| **Attack surface** | Large: writable FS, NVIDIA blob drivers, snap daemon, update services, package managers | Minimal: read-only FS, no package manager at runtime, no writable paths except tmpfs and data partition |
| **Reproducibility** | Opaque - Google builds the image, you trust their pipeline | Source-available - `mkosi build` produces the image from this repo |
| **What TDX actually attests** | "Some Ubuntu 24.04 image that Google built, with an unknown set of packages and configs" | "This exact erofs image, with this exact dm-verity root hash, bit-for-bit" |

## The core problem

TDX measures the initial memory contents of the VM (MRTD) and the boot chain (RTMRs). But measurements are only useful if you know **what was measured**. With a general-purpose image:

1. The rootfs is writable - software can be installed, patched, or replaced after boot. The TDX measurement covers the initial state, but the running state can drift arbitrarily.
2. There is no dm-verity - nothing prevents a compromised process from modifying binaries on disk. A rootkit that replaces `/usr/bin/sshd` would survive reboot.
3. The package set is enormous - thousands of packages means thousands of potential CVEs. Even if today's image is secure, the attack surface is orders of magnitude larger.
4. Unsigned kernel modules (e.g. NVIDIA blobs) can be loaded - any code running in ring 0 has full access to the guest's memory, which TDX is supposed to protect.

With the Privasys Confidential VM Images, the dm-verity root hash is baked into the kernel command line and measured by the TEE hardware. A remote verifier can check the measurement registers against the expected hash and know, cryptographically, that the VM is running **exactly** the code in this repository.

## How Enclave OS Virtual builds on this

[Enclave OS Virtual](https://docs.privasys.org/solutions/enclave-os/presentation/) uses these hardened images as its base OS layer and adds:

- [RA-TLS](https://docs.privasys.org/technology/attestation/attested-connections/) for attested connections - the server's TLS certificate embeds a hardware attestation quote
- Container orchestration via containerd with digest-pinned images
- Configuration attestation - container digests and runtime config measured into X.509 extensions
- Automated encrypted storage with TEE-attested key release

This gives adopters end-to-end verifiability from silicon to application without needing to build or manage CVM images directly.
