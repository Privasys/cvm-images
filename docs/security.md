# Security overview

This document describes the security architecture, threat model, and guarantees provided by the Privasys Confidential VM Images. All images in this repository share the same foundational security properties.

These images are the base OS layer used by [Enclave OS Virtual](https://docs.privasys.org/solutions/enclave-os/presentation/). They are published here for transparency and reproducibility. For deploying confidential workloads, use [Enclave OS Virtual](https://docs.privasys.org/solutions/enclave-os/presentation/) which builds on these images and provides [RA-TLS](https://docs.privasys.org/technology/attestation/attested-connections/), container orchestration, and attestation out of the box.

## Security goals

**Confidentiality.** All data processed inside the VM remains protected. Memory is encrypted by the CPU's TEE hardware (Intel TDX or AMD SEV-SNP). Persistent data is encrypted at rest with LUKS. Network traffic between attested components is protected using [RA-TLS](https://docs.privasys.org/technology/attestation/attested-connections/) (Remote Attestation TLS), where the server's X.509 certificate embeds a hardware attestation quote proving its identity.

**Integrity.** Every byte of code that executes is either measured by TEE hardware or verified by dm-verity. The root filesystem is read-only (erofs) and any modification causes an I/O error and kernel panic. Kernel lockdown prevents unsigned code from running in ring 0.

**Verifiability.** A remote party can cryptographically verify exactly what code is running inside the VM by checking TEE attestation reports against known-good measurement values. The image is built from source in this repository, producing a deterministic dm-verity root hash. Enclave OS Virtual extends this further with configuration attestation, where additional X.509 extensions prove the complete runtime configuration, not just the code identity.

**Isolation.** The TEE hardware isolates the VM from the hypervisor, the cloud provider, and other tenants. The cloud operator has no access to the guest's memory, registers, or disk encryption keys.

## Trust chain

```
Silicon (TEE hardware: TDX SEAM module / AMD PSP)
  |
  +-- Firmware measurement (MRTD / launch digest)
  |     Measures the TD/SEV firmware loaded by the hypervisor
  |
  +-- Firmware config measurement (RTMR[0] / VMSA)
  |     Measures vCPU count, memory layout, firmware configuration
  |
  +-- Secure Boot (UEFI -> shim -> GRUB -> kernel)
  |     UEFI firmware verifies each stage cryptographically
  |     shim (Microsoft-signed) -> GRUB (Canonical-signed) -> kernel
  |
  +-- Boot measurement (RTMR[1-2] / PCR[4-8])
  |     Measures the EFI boot path, kernel, initrd, command line
  |     The dm-verity root hash is embedded in the kernel command line
  |
  +-- dm-verity (root filesystem integrity)
  |     Every 4K block of the erofs rootfs is verified against a Merkle tree
  |     Any tampered block -> I/O error -> kernel panic
  |
  +-- Kernel lockdown (integrity mode)
  |     Prevents loading unsigned kernel modules
  |     Prevents direct memory access from userspace
  |     Prevents writing to /dev/mem, /dev/kmem, /proc/kcore
  |
  +-- Application layer
        All binaries are part of the verified rootfs
        Writable paths limited to tmpfs and encrypted data partition
```

Every layer verifies the next. There are no gaps where unverified code can execute.

## Threat model

### What we protect against

| Threat actor | Description | Capabilities |
|---|---|---|
| **Malicious cloud insider** | Cloud provider employee or contractor with physical or administrative access to the infrastructure | Access to hypervisor, physical memory (via bus probes), storage backend, network fabric. Can snapshot VMs, clone disks, inspect metadata. |
| **Malicious co-tenant** | Another cloud tenant on the same physical host | May attempt VM escape, side-channel attacks, or network interception on shared infrastructure. |
| **Compromised host OS** | Hypervisor or host kernel with a vulnerability or implant | Full control over VM lifecycle, virtual devices, disk I/O, and network. Cannot read TEE-protected memory. |
| **Network attacker** | Adversary with access to the network path between VMs or between a VM and external services | Can intercept, modify, replay, or drop network traffic. |
| **Malicious operator** | DevOps engineer or administrator with SSH access or deployment credentials | Can attempt to modify the running system, install software, exfiltrate data, or deploy unauthorized workloads. |

### What we do NOT protect against

- **Application logic bugs.** If your application has a SQL injection or broken access control, TEE hardware will not save you. Confidential computing protects the infrastructure layer, not the application layer.
- **Undiscovered microarchitectural vulnerabilities.** We proactively close all known security gaps, including firmware-level vectors like BadAML where we maintain a custom kernel patch. However, as a software-only solution running on third-party silicon, we inherit any undiscovered microarchitectural side-channel vulnerabilities in the CPU hardware itself. We monitor published research and TEE vendor advisories and will issue updated images when new vulnerabilities are disclosed.
- **Denial of service.** The cloud provider can always stop, throttle, or refuse to run your VM. Confidential computing provides confidentiality and integrity, not availability.
- **Supply chain compromise of Ubuntu packages.** We use Ubuntu's signed packages from official repositories. A compromise of Canonical's build infrastructure would affect us. We mitigate this with a minimal package set (~40 packages instead of ~2000+).

### Attack surfaces and mitigations

| Attack vector | Threat | Mitigation |
|---|---|---|
| **Physical memory access** | Cloud insider dumps VM memory via bus probes or hypervisor snapshot | TEE hardware encrypts all VM memory with a per-VM key. Memory is never stored in plaintext outside the CPU. |
| **Disk inspection** | Attacker reads the raw disk image or storage backend | Root filesystem is read-only erofs with dm-verity. Persistent data partition uses LUKS encryption with a key derived from TEE attestation. The disk can be read but not decrypted. |
| **Rootfs modification** | Attacker modifies a binary on the root filesystem | erofs is read-only. Any modification to a dm-verity protected block causes a hash mismatch, I/O error, and kernel panic. |
| **Kernel module injection** | Attacker loads a malicious kernel module (rootkit) | `module.sig_enforce=1` rejects unsigned modules. `lockdown=integrity` prevents loading modules via /dev/mem or other bypass paths. |
| **Boot chain tampering** | Attacker replaces GRUB, kernel, or initrd | Secure Boot verifies the full chain: UEFI -> shim (Microsoft) -> GRUB (Canonical) -> kernel. A modified bootloader fails signature verification and the VM refuses to boot. |
| **Network interception** | Attacker intercepts traffic between VMs or to external services | Enclave OS Virtual uses [RA-TLS](https://docs.privasys.org/technology/attestation/attested-connections/) where the server's X.509 certificate contains an embedded TEE attestation quote. Clients verify the quote during the TLS handshake, confirming the server is running inside a genuine TEE with the expected measurements. |
| **Runtime software installation** | Operator runs `apt install` or drops a binary | The root filesystem is read-only erofs. There is no package manager at runtime. Writable paths are limited to tmpfs (lost on reboot) and the encrypted data partition. |
| **ACPI/firmware injection** | Hypervisor injects malicious ACPI bytecode to access private memory | CVM Guard kernel patch (BadAML) blocks AML bytecode from accessing pages marked as private/encrypted. See [patches/](../patches/). |
| **Attestation forgery** | Attacker fabricates a TEE attestation report | Attestation reports are signed by the CPU's hardware key, rooted in the silicon manufacturer's PKI. Forgery requires breaking the CPU's cryptographic root of trust. |

## Security guarantees

When a remote verifier checks the TEE attestation report and confirms the measurement values match the expected image, the following is guaranteed:

1. **The VM is running inside a genuine TEE.** The attestation report is signed by the CPU's hardware key. It cannot be produced by software alone.
2. **The firmware is unmodified.** The firmware measurement (MRTD / launch digest) matches the expected OVMF/TDVF build.
3. **The boot chain is intact.** Secure Boot verified every stage. The kernel, initrd, and command line (including dm-verity root hash) are measured into RTMR/PCR registers.
4. **The root filesystem is exactly the one built from this repository.** The dm-verity root hash is part of the measured kernel command line. Any modification to any file on the rootfs will cause a verification failure.
5. **No unsigned code runs in kernel space.** Kernel lockdown and module signature enforcement prevent loading arbitrary kernel modules.
6. **The CVM Guard kernel patch is active.** ACPI bytecode cannot access TEE-private memory, closing the firmware-level attack vector documented in BadAML research.

When using [Enclave OS Virtual](https://docs.privasys.org/solutions/enclave-os/presentation/), additional guarantees are provided through RA-TLS configuration attestation: the exact set of loaded containers, their digests, and the runtime configuration are all embedded in the server certificate's X.509 extensions and verified during the TLS handshake.

## Per-image security notes

### tdx-base and sev-snp-base

These images have the smallest attack surface: ~40 Ubuntu packages, no GUI, no package manager at runtime, no unnecessary services. The only writable paths are tmpfs mounts and the LUKS-encrypted data partition.

### sev-snp-gpu

The GPU image includes additional packages for NVIDIA Confidential Computing:

- **nvidia-driver-550-server**: The NVIDIA kernel module is signed by NVIDIA and Canonical for Ubuntu. It runs in kernel space and is part of the TCB.
- **CUDA toolkit**: Runs in userspace. Large attack surface (~5 GB) but does not have kernel-level access.
- **Confidential Computing mode**: Enabled via `nvidia.NVreg_ConfidentialComputing=1`. The GPU encrypts data in transit between CPU and GPU memory over the PCIe bus. The GPU has its own attestation capability (NVIDIA NRAS) for verifying the GPU firmware.
- **Larger TCB**: The GPU image has a significantly larger trusted computing base than the non-GPU images. This is an inherent trade-off of confidential AI inference.
- **Data partition**: A 500 GB data partition is included for model weights (supporting multiple models via vLLM). This partition is encrypted with LUKS, with the key derived from TEE attestation.

## Further reading

- [Hardening guide](hardening.md) - Security architecture and design decisions
- [Encrypted storage](encrypted-storage.md) - LUKS-encrypted persistent volumes with TEE-bound keys
- [Image integrity](image-integrity.md) - Supply chain security and reproducible builds
- [GCP comparison](gcp-comparison.md) - Why we build our own images instead of using Google's
- [Enclave OS Virtual](https://docs.privasys.org/solutions/enclave-os/presentation/) - The developer platform built on these images
- [RA-TLS](https://docs.privasys.org/technology/attestation/attested-connections/) - How attested connections work
