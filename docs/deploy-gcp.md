# Deploying to Google Cloud Platform

Import and launch the tdx-image-base image on GCP Confidential VMs with Intel TDX.

## Prerequisites

- A GCP project with Confidential VM access
- `gcloud` CLI authenticated
- A GCS bucket for image storage
- The built image (`privasys-tdx-base_0.1.0.raw`) built with `--profile gcp` - see [Building from source](../README.md#building-from-source)

## Package and upload

```bash
# GCP expects disk.raw inside a tar.gz
cp privasys-tdx-base_0.1.0.raw disk.raw
tar -czf privasys-tdx-base-0.1.0.tar.gz disk.raw
rm disk.raw

# Upload to your GCS bucket
gcloud storage cp privasys-tdx-base-0.1.0.tar.gz gs://YOUR_BUCKET/
```

> **Note:** If uploading from a GCE VM, the VM must have `storage-rw` scope (set at creation time with `--scopes=storage-rw`, or added later via `gcloud compute instances set-service-account` after stopping the VM).

## Create a GCP image

```bash
gcloud compute images create privasys-tdx-base-0-1-0 \
    --source-uri=gs://YOUR_BUCKET/privasys-tdx-base-0.1.0.tar.gz \
    --guest-os-features=TDX_CAPABLE,UEFI_COMPATIBLE,GVNIC,VIRTIO_SCSI_MULTIQUEUE \
    --family=privasys-tdx \
    --description="Privasys TDX base image v0.1.0 - Ubuntu 24.04, erofs root, dm-verity, unsigned UKI"
```

`--family=privasys-tdx` lets you always reference the latest image without hardcoding version numbers.

## Launch a TDX VM

```bash
gcloud compute instances create my-tdx-vm \
    --zone=europe-west9-a \
    --machine-type=c3-standard-4 \
    --network-interface=nic-type=GVNIC \
    --maintenance-policy=TERMINATE \
    --create-disk=auto-delete=yes,boot=yes,image=projects/YOUR_PROJECT/global/images/family/privasys-tdx,size=10,type=pd-balanced \
    --no-shielded-secure-boot \
    --shielded-vtpm \
    --shielded-integrity-monitoring \
    --confidential-compute-type=TDX
```

**Why `--no-shielded-secure-boot`?** The images use the CVM Guard patched
kernel, which is not signed by Canonical, so it cannot pass UEFI Secure
Boot's certificate check. Integrity does not depend on Secure Boot here:
TDX measures the firmware, bootloader, kernel, initrd, and command line
(including the dm-verity root hash) into RTMR registers regardless, and a
tampered boot chain produces different measurements that fail remote
attestation and receive no secrets. This keeps the images cloud-agnostic —
the same trust model works on any TDX/SEV-SNP host without depending on a
cloud provider's or OS vendor's signing keys.

## Verify

Production images have no SSH daemon — verification happens through
attestation (RA-TLS via Enclave OS Virtual) or the serial console. For
interactive inspection, deploy a **dev build** (`--profile gcp --profile
dev`) instead:

```bash
gcloud compute ssh my-tdx-vm        # dev image only

ls -l /dev/tdx_guest          # TDX device present
mount | grep verity            # dm-verity on root
touch /test 2>&1               # Read-only file system
tpm2_pcrread sha256:0,1,2,3,4,5,7,11
```

## GCP-specific notes

- **Machine types:** TDX is available on C3 machines (`c3-standard-*`). Not all zones support TDX — check [GCP Confidential VM docs](https://cloud.google.com/confidential-computing/confidential-vm/docs/os-and-machine-type#machine_type) for availability.
- **Attestation:** GCP wraps TDX attestation in its [Confidential Computing API](https://cloud.google.com/confidential-computing/confidential-vm/docs/attestation). You can also do raw TDX attestation via `/dev/tdx_guest`.
- **Guest agent:** The GCP profile (`--profile gcp`) includes `google-guest-agent` for metadata and startup scripts. Metadata-based SSH key injection only exists in dev builds (`--profile gcp --profile dev`); production images have no SSH daemon.
- **Networking:** GCP uses gVNIC (`--network-interface=nic-type=GVNIC`). The kernel includes the `gve` driver. systemd-networkd handles DHCP automatically.
