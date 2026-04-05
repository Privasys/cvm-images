# Encrypted persistent storage

This document explains the architecture of LUKS-encrypted persistent storage in the Privasys Confidential VM Images. The root filesystem is read-only (erofs + dm-verity), so any data that must survive a reboot is stored on a separate encrypted partition.

[Enclave OS Virtual](https://docs.privasys.org/solutions/enclave-os/presentation/) handles encrypted storage setup automatically. This document describes the underlying architecture for transparency.

## Why encrypt the data partition?

TEE hardware (TDX/SEV-SNP) encrypts VM memory at runtime, but data at rest on disk is outside this protection:

- Cloud storage backends are controlled by the provider. An insider can snapshot your disk.
- If the VM is stopped, the memory encryption keys are destroyed, but the disk persists.
- Without disk encryption, a stolen or cloned disk image exposes all persistent data.

LUKS encryption with a TEE-attested key closes this gap. The disk is encrypted with a key that only exists inside a VM with the correct measurements. No attestation, no key, no data.

## Architecture

```
+------------------------------------------+
|  Application                             |
|  Reads/writes to /data/ as normal        |
+------------------------------------------+
|  ext4 filesystem                         |
+------------------------------------------+
|  dm-crypt (LUKS2)                        |
|  AES-256-XTS, authenticated with AEAD    |
+------------------------------------------+
|  Block device (persistent disk / volume) |
|  Visible to cloud provider, but          |
|  contents are encrypted ciphertext       |
+------------------------------------------+
```

The application does not need to be aware of the encryption layer. It reads and writes to `/data/` as normal. The kernel handles encryption transparently.

## TEE-attested key binding

The encryption key is bound to the VM's TEE identity through one of two mechanisms:

### Attestation-gated key release (recommended)

A remote key management service (KMS) holds the LUKS key material and releases it only to VMs that pass attestation:

1. On boot, the VM generates a TEE attestation report containing its measurements.
2. The VM sends the attestation report to the KMS over an [RA-TLS](https://docs.privasys.org/technology/attestation/attested-connections/) channel.
3. The KMS verifies the report against a policy (expected firmware hash, kernel hash, dm-verity root hash).
4. If the policy passes, the KMS releases the key.
5. The VM uses the key to unlock the LUKS partition.

This means:
- The key never exists on disk. It is held remotely and released only to VMs that pass attestation.
- A modified or compromised image will fail attestation and never receive the key.
- The cloud provider cannot obtain the key, even with full access to the infrastructure.

### TPM/configfs-tsm binding

The LUKS key can alternatively be bound to the VM's TPM PCR or RTMR measurements using clevis. The images include `clevis`, `cryptsetup`, and `tpm2-tools` for this purpose. When the VM boots with the correct firmware and kernel (matching the expected measurement values), the partition unlocks automatically.

## Key rotation on image updates

When the image is updated (new dm-verity root hash), the TEE measurement values change. This requires:

- **KMS approach**: Update the KMS policy with the new expected measurements before deploying the updated image.
- **TPM/clevis approach**: Re-bind clevis to the new PCR/RTMR values before the old image is replaced.

The KMS-based approach is more flexible because it checks attestation report fields directly rather than depending on specific PCR values.

## Security considerations

- **The data partition is not covered by dm-verity.** Only the root filesystem is integrity-protected. Data on the LUKS partition is encrypted and authenticated (AEAD), but a sophisticated attacker with persistent disk access could perform rollback attacks (restoring an older ciphertext). Application-level sequence counters can mitigate this if needed.
- **LUKS header is visible.** The LUKS header (containing metadata about the encryption scheme) is not encrypted. It reveals that the partition is LUKS-encrypted but does not leak the key or plaintext.
- **Memory contains the decryption key.** While the VM is running, the LUKS master key is in memory. This is protected by the TEE's memory encryption.
- **No executable code on the data partition.** The data partition is mounted with `noexec`. All executable code lives on the dm-verity protected rootfs. The data partition stores only data: database files, model weights, configuration.

## Per-image data partitions

### tdx-base and sev-snp-base

These images include a data partition defined in their `mkosi.repart/` configuration. The partition is formatted as ext4 and intended for LUKS encryption.

### sev-snp-gpu

The `sev-snp-gpu` image includes a 500 GB data partition for AI model weights, supporting multiple models via vLLM. Model weights are often proprietary and their confidentiality is a primary motivation for confidential AI inference. This partition is LUKS-encrypted using the same TEE-attested key mechanisms described above.

## Further reading

- [Security overview](security.md) - Threat model and security guarantees
- [Image integrity](image-integrity.md) - Supply chain security and reproducible builds
- [Enclave OS Virtual](https://docs.privasys.org/solutions/enclave-os/presentation/) - The developer platform that automates encrypted storage setup
- [RA-TLS](https://docs.privasys.org/technology/attestation/attested-connections/) - How attested connections protect key release
