# Intel TDX

This document covers the TDX-specific aspects of the Privasys Confidential VM Images, including the trust chain, measurement registers, and where these images fit in the TDX software stack.

For a general overview of the security architecture, see [security.md](security.md).

## TDX trust chain

The trust chain for TDX-based images ties every layer of software to the hardware root of trust in the CPU's SEAM module:

```
Silicon (TDX SEAM module inside the CPU)
  └─ MRTD - measures the TD firmware (OVMF/TDVF) loaded by the hypervisor
      └─ RTMR[0] - measures the firmware configuration (vCPU count, memory layout)
          └─ Secure Boot - UEFI verifies shimx64.efi (Microsoft) -> grubx64.efi (Canonical) -> kernel
              └─ RTMR[1] - measures the EFI boot path: shim and GRUB binaries (CC MR 2)
                  └─ RTMR[2] - measures OS boot: kernel, initrd, cmdline with dm-verity root hash (CC MR 3)
                      └─ dm-verity - every block of the rootfs verified against the hash tree
                          └─ All userland binaries - any modification = I/O error + kernel panic
```

Every byte of code that executes on the machine is either measured by TDX hardware or verified by dm-verity. No gaps.

## TDX measurement registers

| Register | Alias | What it measures |
|----------|-------|-----------------|
| **MRTD** | Launch measurement | The initial TD firmware (OVMF/TDVF) contents. Set at VM creation, immutable. |
| **RTMR[0]** | CC MR 1 | Firmware configuration: vCPU count, memory regions, ACPI tables. |
| **RTMR[1]** | CC MR 2 | EFI boot path: shim and GRUB binaries loaded by UEFI. |
| **RTMR[2]** | CC MR 3 | OS boot: the kernel, initrd, and kernel command line (which includes the dm-verity root hash). |

The dm-verity root hash in the kernel command line is the link between hardware measurements and filesystem integrity. A remote verifier checks RTMR[2], extracts the expected command line, and confirms the dm-verity root hash matches a known-good image build. If it matches, every file on the rootfs is guaranteed to be correct.

## Where this fits in the TDX stack

These images are the **guest OS** layer. They sit on top of the host-side TDX stack and below the application layer:

```
┌─────────────────────────────────────────────────────────────┐
│  intel/tdx-module                         Silicon firmware  │
│  TDX SEAM module running inside the CPU                     │
│  Creates & isolates Trust Domains, manages memory keys      │
│  Ships in CPU microcode - not user-serviceable              │
└──────────────────────────┬──────────────────────────────────┘
                           │ creates / measures
┌──────────────────────────▼──────────────────────────────────┐
│  canonical/tdx                          Host OS / hypervisor│
│  Modified kernel, QEMU, OVMF/TDVF, libvirt patches         │
│  Enables the host to launch TDX guests                      │
│  Only needed on bare metal (cloud providers handle this)    │
└──────────────────────────┬──────────────────────────────────┘
                           │ launches
┌──────────────────────────▼──────────────────────────────────┐
│  Privasys CVM Images (this repo)            Guest OS image  │
│  GRUB boot, erofs root, dm-verity, attestation tools        │
│  The workload runs here                                     │
└──────────────────────────┬──────────────────────────────────┘
                           │ deployed via Enclave OS Virtual
┌──────────────────────────▼──────────────────────────────────┐
│  Application layer                                          │
│  OCI containers, reverse proxies, databases, AI models      │
│  Managed by Enclave OS Virtual with RA-TLS attestation      │
└─────────────────────────────────────────────────────────────┘
```

| | [intel/tdx-module](https://github.com/intel/tdx-module) | [canonical/tdx](https://github.com/canonical/tdx) | Privasys CVM Images |
|---|---|---|---|
| **What** | CPU firmware (SEAM module) | Host-side Linux + QEMU patches | Guest VM disk image |
| **Runs where** | Inside the CPU | On the bare-metal host OS | Inside the Trust Domain |
| **On managed cloud** | Managed by provider | Managed by provider | **This repo** |
| **On bare metal** | In the CPU | **Operator installs** | **This repo** |
| **Licence** | Intel proprietary | GPL-2.0 (Ubuntu/kernel) | AGPL-3.0 |

## TDX attestation flow

1. The VM requests an attestation report by writing to `configfs-tsm` (or via the vTPM).
2. The TDX module produces a **TD Quote** signed by the CPU's attestation key.
3. The quote contains MRTD, RTMR[0-3], and the ReportData field (typically a hash of the RA-TLS certificate's public key).
4. A remote verifier checks the quote signature against Intel's attestation PKI and compares measurement values against expected reference values.
5. If all measurements match, the verifier knows the VM is running the exact image built from this repository.

When deployed through [Enclave OS Virtual](https://docs.privasys.org/solutions/enclave-os/presentation/), this flow is handled automatically via [RA-TLS](https://docs.privasys.org/technology/attestation/attested-connections/). The TD Quote is embedded in the server's X.509 certificate and verified during the standard TLS handshake.

## Deployment guides

| Platform | Guide | TDX host managed by |
|----------|-------|---------------------|
| Google Cloud Platform | [deploy-gcp.md](deploy-gcp.md) | Google |
| OVHcloud bare metal (Scale-i1) | [deploy-ovhcloud.md](deploy-ovhcloud.md) | Operator (via [canonical/tdx](https://github.com/canonical/tdx)) |

## TDX-specific design decisions

- **Why GRUB instead of UKI?** GCP's TDX firmware (TDVF) enforces Secure Boot, which silently rejects unsigned EFI binaries including systemd-boot and unsigned UKIs. GRUB is the proven boot chain for TDX on GCP and other cloud platforms. TDX still measures the full boot chain (kernel, initrd, cmdline) into RTMR registers regardless of the bootloader used.
- **Why `linux-image-generic-hwe-24.04`?** The HWE (Hardware Enablement) kernel tracks the latest LTS-backported kernel on Noble, currently 6.19. TDX guest support has been upstream since 6.7, so this works on any TDX-capable cloud or bare-metal platform.
- **MRTD is fixed at VM creation.** The MRTD value depends on the OVMF/TDVF firmware provided by the cloud platform (or installed via canonical/tdx on bare metal). You cannot control this value from the guest image. Verification policies should match MRTD against the known firmware version.
