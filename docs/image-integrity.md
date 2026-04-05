# Image integrity and supply chain security

This document explains how the Privasys Confidential VM Images ensure that the code running inside a confidential VM is exactly the code from this repository, with no modifications. The images are published here for transparency and reproducibility, and are used as the base OS layer by [Enclave OS Virtual](https://docs.privasys.org/solutions/enclave-os/presentation/).

## The problem

Confidential computing hardware (TDX, SEV-SNP) provides memory encryption and attestation. But attestation only answers one question: "what is running?" It does not answer "is what is running correct?" unless you have a reference value to compare against.

If the image that boots inside the CVM is opaque (built by someone else, no source available, no reproducible build), then the attestation report is a meaningless hash. You can prove the VM is running *something*, but you cannot prove it is running *the right thing*.

## How these images solve this

### 1. Source-available build

Every image is built from the configuration files in this repository using mkosi. The inputs are:

- `mkosi.conf` - package list, image metadata, build options
- `mkosi.conf.d/boot.conf` - kernel command line (includes security parameters)
- `mkosi.repart/*.conf` - partition layout (erofs, dm-verity, ESP)
- `mkosi.extra/` and `common/mkosi.extra/` - overlay files (systemd units, SSH config, sysctl)
- `mkosi.prepare` - (GPU image only) adds NVIDIA apt repositories

There are no binary blobs checked into this repository. All packages come from Ubuntu's official signed repositories (or NVIDIA's signed repository for the GPU image).

### 2. dm-verity binds the rootfs to a single hash

When mkosi builds the image, it:

1. Creates an erofs filesystem containing all packages and overlay files.
2. Computes a dm-verity Merkle tree over every 4 KB block of the filesystem.
3. Embeds the dm-verity **root hash** in the kernel command line.
4. Writes the hash tree to a separate verity partition.

At boot time, the kernel verifies every block read from the rootfs against the Merkle tree. The root hash is a single SHA-256 value that uniquely identifies the entire filesystem contents. Change one byte in any file, and the root hash changes.

### 3. The root hash is measured by TEE hardware

The kernel command line (which contains the dm-verity root hash) is measured into the TEE's measurement registers:

- **TDX**: RTMR[2] (CC MR 3) contains the hash of the kernel command line
- **SEV-SNP**: The VMSA and launch measurement cover the initial memory contents

This creates an unbroken chain:

```
TEE hardware measurement
  -> includes kernel command line
    -> includes dm-verity root hash
      -> uniquely identifies every file on the rootfs
```

A remote verifier checks the TEE attestation report, extracts the measurement values, and compares them against the expected values for a known image build. If they match, every file on the rootfs is guaranteed to be correct.

### 4. Signed packages

All packages installed in the image come from Ubuntu's official APT repositories with signature verification enabled:

- Canonical signs each `.deb` package with their GPG key
- `apt` verifies the signature before installation
- mkosi runs `apt` inside a sandboxed build environment

The CVM Guard kernel patch is built from source in this repository (`build-kernel.sh` + `patches/`) and published as `.deb` packages on GitHub Releases. The build workflow runs on GitHub Actions with a reproducible environment.

### 5. Minimal package set

A smaller image is easier to audit. The base images include approximately 40 packages:

- Kernel and boot infrastructure (linux-image, grub, shim)
- Core system (systemd, udev, dbus, bash)
- Network (systemd-networkd, openssh-server)
- Attestation and encryption (tpm2-tools, clevis, cryptsetup)
- Cloud integration (google-compute-engine, google-guest-agent)

There is no:
- Package manager at runtime (no apt, no snap, no pip)
- Desktop environment (no X11, no Wayland)
- Build tools (no gcc, no make)
- Interpreters beyond bash (no Python, no Node.js, no Ruby)
- Container runtime in the base image (added by Enclave OS Virtual)

Each additional package increases the attack surface and the difficulty of auditing the image.

## Verification

### Remote attestation via Enclave OS Virtual

When deployed through [Enclave OS Virtual](https://docs.privasys.org/solutions/enclave-os/presentation/), remote verification is handled automatically. The platform's [RA-TLS](https://docs.privasys.org/technology/attestation/attested-connections/) implementation embeds the TEE attestation quote in the server's X.509 certificate. Any connecting client can verify the attestation during the TLS handshake, confirming the server is running the expected measured code.

Enclave OS Virtual extends this with configuration attestation: the complete set of loaded containers, their digests, and the runtime configuration are measured into additional X.509 extensions. [Client verification libraries](https://docs.privasys.org/solutions/platform/verification-libraries/) are available for Go, Python, Rust, TypeScript, and C#.

### Reproducible builds

The image can be rebuilt from source by cloning this repository and running `mkosi build` in the appropriate image directory. The dm-verity root hash of a locally built image can be compared against the published reference value for that release.

## Container image integrity

Container images running inside the CVM (deployed through Enclave OS Virtual) are not part of the base rootfs and are not covered by dm-verity. Instead, Enclave OS Virtual provides container integrity through its attestation layer:

- Container images are pinned by `sha256` digest, not mutable tags
- The complete set of container digests and runtime configuration is measured into the RA-TLS certificate's X.509 extensions
- Remote verifiers can confirm both the base OS identity (via TEE measurements) and the application identity (via configuration attestation) in a single TLS handshake

## Known limitations

- **Reproducible builds are not yet fully deterministic.** Ubuntu package builds are not bit-for-bit reproducible. Two builds from the same mkosi configuration may produce different erofs images (different timestamps, package build IDs). The dm-verity root hash will differ between builds. We are working toward fully reproducible builds.
- **Ubuntu package repository is a point-in-time snapshot.** Packages are pulled from Ubuntu's live repositories at build time. A build today and a build next week may include different package versions. Pin specific package versions in `mkosi.conf` for critical reproducibility.
- **The kernel is part of the TCB.** The Ubuntu HWE kernel is a large codebase. We mitigate this by using Canonical's signed builds and applying only a minimal patch (CVM Guard). We do not maintain a custom kernel fork.
