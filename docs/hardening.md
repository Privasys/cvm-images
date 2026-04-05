# Hardening guide

This document describes the security architecture and design decisions in the Privasys Confidential VM Images. It explains how the images are hardened at each layer and what properties they provide as a foundation for [Enclave OS Virtual](https://docs.privasys.org/solutions/enclave-os/presentation/).

These images are published for transparency and reproducibility. They are not intended to be used directly in production - use [Enclave OS Virtual](https://docs.privasys.org/solutions/enclave-os/presentation/) to deploy confidential workloads with RA-TLS, container orchestration, and attestation handled automatically.

## The trust boundary

Everything inside the confidential VM is trusted. Everything outside - the hypervisor, the cloud provider's network, the storage backend, the management plane - is untrusted. This is the fundamental assumption of confidential computing.

```
  TRUSTED (inside the CVM)              UNTRUSTED (outside the CVM)
  +--------------------------+          +---------------------------+
  | Kernel (measured)        |          | Hypervisor / VMM          |
  | Root filesystem (dm-     |  <---->  | Cloud control plane       |
  |   verity verified)       |          | Storage backend           |
  | Application binaries     |          | Network fabric            |
  | In-memory secrets        |          | Other tenants             |
  | Encrypted data partition |          | Cloud provider employees  |
  +--------------------------+          +---------------------------+
```

Any data or signal that crosses from right to left must be treated as potentially hostile.

## Network security

The network is controlled by the hypervisor. The cloud provider can intercept, modify, replay, or drop any packet. The images are built with this assumption in mind:

- **RA-TLS for attested connections.** [Enclave OS Virtual](https://docs.privasys.org/solutions/enclave-os/presentation/) uses [RA-TLS](https://docs.privasys.org/technology/attestation/attested-connections/) (Remote Attestation TLS) to protect all connections between attested components. The server's X.509 certificate embeds a hardware attestation quote, allowing any client (including plain web browsers) to verify the server is running inside a genuine TEE. RA-TLS also supports mutual attestation when both endpoints are CVMs.
- **DNS is untrusted.** The host controls `/etc/resolv.conf` and can redirect DNS queries. For security-critical name resolution, the remote endpoint's RA-TLS certificate must always be verified, regardless of how the connection was established.
- **Loopback via `127.0.0.1`, not `localhost`.** The host can manipulate `/etc/hosts`. Intra-VM communication uses the loopback IP directly.
- **Hostile network topology assumed.** Even "private" VPC networks are routed through the cloud provider's fabric. All external communication should be encrypted.

### Firewall and listening services

The images ship with a minimal set of listening services. The only default listener is `sshd` (port 22, password authentication disabled, key-based only). When deployed through Enclave OS Virtual, additional services (such as the RA-TLS reverse proxy) are configured automatically with attested endpoints.

## Authentication and identity

### TEE-rooted identity via RA-TLS

The primary identity of a CVM is its TEE attestation report. Traditional PKI says "a CA I trust says this is server X". RA-TLS says "the CPU hardware says this server is running exactly this measured code".

In [RA-TLS](https://docs.privasys.org/technology/attestation/attested-connections/), the CVM generates a TLS certificate where the public key is cryptographically bound to a TEE attestation quote via the ReportData field. Remote peers verify the attestation quote during the standard TLS handshake. This works transparently with any TLS client, including web browsers, which verify the server's attestation without requiring any special client-side software.

Enclave OS Virtual manages the full RA-TLS lifecycle: certificate generation, quote embedding, renewal, and optional mutual attestation between CVMs. [Client verification libraries](https://docs.privasys.org/solutions/platform/verification-libraries/) are available for Go, Python, Rust, TypeScript, and C#.

### SSH hardening

SSH is configured with hardened defaults (`50-hardened.conf`):
- Password authentication disabled
- Only key-based authentication accepted
- Root login disabled by default

For production deployments through Enclave OS Virtual, SSH can be disabled entirely as workloads are managed through the container orchestration layer.

## Secrets management

### No secrets in the image

The root filesystem is measured by dm-verity, which means its contents are deterministic and reproducible from source. Secrets must never be embedded in:

- Files under `mkosi.extra/`
- Packages or configuration baked into `mkosi.conf`
- Environment variables in systemd unit files on the rootfs

### Runtime secret injection

Secrets are injected at runtime through attestation-gated mechanisms:

- **Attestation-gated key release.** A remote key management service verifies the VM's attestation report and releases secrets only to VMs with the expected measurements. This is the strongest approach.
- **Encrypted data partition.** Secrets are stored on the LUKS-encrypted data partition. The LUKS key is derived from TEE attestation. See [encrypted-storage.md](encrypted-storage.md).
- **Instance metadata (with caution).** Cloud instance metadata can provide non-sensitive bootstrap configuration. It should never carry secrets, as the cloud provider has full access to the metadata service.

Enclave OS Virtual handles secret injection through its attestation-gated key release flow, removing the need to build custom secret delivery pipelines.

### Memory-only secrets

The TEE hardware encrypts all VM memory, so secrets held in RAM are protected from the host. The images are configured to minimize accidental secret leakage:

- Console output (`ttyS0`) is available for boot diagnostics but should not contain sensitive data
- Core dumps are restricted
- Writable paths are backed by tmpfs (lost on reboot) and the encrypted data partition

## Persistent storage

### Read-only root filesystem

The erofs root filesystem cannot be modified at runtime. This means:

- No rootkits can persist across reboots
- No attacker can modify system binaries
- The dm-verity root hash fully describes the entire rootfs

### Encrypted data partition

The data partition (`/data/`) is the only persistent writable storage and is LUKS-encrypted with a key derived from TEE attestation. See [encrypted-storage.md](encrypted-storage.md) for the architecture.

Executable code should not be stored on the data partition. All executable code lives on the dm-verity protected rootfs. The data partition is for data only: database files, model weights, configuration.

### Tmpfs

Writable directories on the rootfs (e.g. `/var/log`, `/tmp`, `/run`) are backed by tmpfs and exist only in encrypted memory. They are lost on reboot.

## Container workloads

When deployed through [Enclave OS Virtual](https://docs.privasys.org/solutions/enclave-os/presentation/), containers run inside the CVM via containerd. The platform handles:

- **Image pinning by digest.** Container images are referenced by `sha256` digest, not mutable tags. This ensures the image content is deterministic and can be included in the attestation measurement.
- **Attestation of container configuration.** The complete set of container images, their digests, and the runtime configuration are measured into the RA-TLS certificate's X.509 extensions, providing end-to-end verifiability from silicon to application.
- **Minimal container capabilities.** Containers run with dropped Linux capabilities and read-only rootfs where possible.
- **TLS termination via RA-TLS.** The attested reverse proxy (ra-tls-caddy) handles TLS termination at the edge, so containers serve plain HTTP internally while all external traffic is RA-TLS protected.

## GPU workloads (sev-snp-gpu)

The `sev-snp-gpu` image includes the NVIDIA H100 Confidential Computing stack:

- **GPU attestation.** The GPU has its own attestation mechanism (via NVIDIA's Remote Attestation Service). CPU attestation proves the VM code is correct. GPU attestation proves the GPU firmware is genuine and CC mode is active.
- **Encrypted GPU memory.** With Confidential Computing mode enabled, the GPU encrypts data in transit between CPU and GPU memory over the PCIe bus.
- **NVIDIA driver in the TCB.** The kernel module runs in ring 0 with full access to VM memory. NVIDIA signs the driver, and Canonical co-signs it for Ubuntu. This is an inherent trade-off of confidential GPU computing.
- **500 GB data partition.** Sized for multiple AI models (vLLM). The partition is LUKS-encrypted with a TEE-attested key.

## Security properties summary

| Property | How it is achieved |
|---|---|
| Read-only rootfs | erofs filesystem, dm-verity integrity |
| No runtime code modification | No package manager, no writable system paths |
| Kernel integrity | `lockdown=integrity`, `module.sig_enforce=1` |
| Measured boot chain | Secure Boot + TEE measurement registers (RTMR/PCR) |
| Memory encryption | TEE hardware (TDX/SEV-SNP) per-VM keys |
| Disk encryption | LUKS2 with TEE-attested key |
| Attested connections | [RA-TLS](https://docs.privasys.org/technology/attestation/attested-connections/) via Enclave OS Virtual |
| Firmware protection | CVM Guard kernel patch (BadAML) |
| Minimal attack surface | ~40 packages, no desktop, no interpreters beyond bash |
| Container attestation | Digests and config measured into RA-TLS X.509 extensions |
- [ ] Serial console is disabled if not needed
