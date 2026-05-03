# Deploy tdx-gpu on Google Cloud Platform

Deploy a TDX Confidential VM with NVIDIA H100 GPU on GCP. Uses an `a3-highgpu-1g` instance with Intel TDX and 1x H100 80GB in Confidential Computing (CC) mode.

## Prerequisites

- GCP project with Confidential VM API enabled
- `gcloud` CLI configured
- A3 quota in the target zone (europe-west4-c recommended)
- A pre-built `tdx-gpu` image imported as a GCP Compute Image

## Import the image

Build the image with the GCP profile (see [Building from source](../README.md#building-from-source)):

```bash
cd images/tdx-gpu && sudo mkosi --profile gcp build
```

Package and import to GCP:

```bash
# Package as disk.raw in a tar.gz
cp privasys-tdx-gpu_0.1.0.raw disk.raw
tar -czf privasys-tdx-gpu.tar.gz disk.raw
rm disk.raw

# Upload to GCS
gsutil cp privasys-tdx-gpu.tar.gz gs://YOUR_BUCKET/privasys-tdx-gpu.tar.gz

# Create GCP Compute Image
gcloud compute images create privasys-tdx-gpu \
    --source-uri=gs://YOUR_BUCKET/privasys-tdx-gpu.tar.gz \
    --guest-os-features=UEFI_COMPATIBLE,TDX_CAPABLE,GVNIC \
    --project=YOUR_PROJECT
```

## Create the VM

```bash
gcloud compute instances create ai-gpu \
    --zone=europe-west4-c \
    --machine-type=a3-highgpu-1g \
    --confidential-compute-type=TDX \
    --provisioning-model=SPOT \
    --no-shielded-secure-boot \
    --image=privasys-tdx-gpu \
    --image-project=YOUR_PROJECT \
    --boot-disk-size=30GB \
    --boot-disk-type=pd-ssd \
    --local-ssd=interface=NVME \
    --local-ssd=interface=NVME \
    --service-account=YOUR_SA@developer.gserviceaccount.com \
    --scopes=cloud-platform \
    --project=YOUR_PROJECT
```

Key flags:
- `a3-highgpu-1g`: Intel Sapphire Rapids + 1x H100 80GB. The only machine type supporting TDX + GPU on GCP.
- `--confidential-compute-type=TDX`: Enables Intel TDX.
- `--provisioning-model=SPOT`: Required for A3 instances (no on-demand for <8 GPU configs).
- `--no-shielded-secure-boot`: Secure Boot is disabled because the NVIDIA kernel modules use module.sig_enforce with Canonical's key, not the Shielded VM key.
- `--local-ssd=interface=NVME`: Local NVMe SSDs for fast model weight storage.

## Verify

```bash
# Check TDX
dmesg | grep -i tdx

# Check GPU
nvidia-smi
# Expected: H100 80GB, driver 595.58.03, CUDA 13.0

# Check CC mode
nvidia-smi -q | grep -A5 "Confidential Compute"
# Expected: Mode: Enabled, Environment: PRODUCTION
```

## Notes

- **Spot VM**: The a3-highgpu-1g instance will be preempted. Plan for graceful shutdown.
- **Local SSDs are ephemeral**: Data on NVMe local SSDs is lost on VM stop/preemption. Use persistent disks or GCS for data that must survive restarts.
- **CC mode overhead**: H100 CC mode reserves ~1.3 GB for firmware, leaving 78.72 GiB usable of 80 GB.
- **Module signing**: The kernel command line includes `module.sig_enforce=1`. Only Canonical-signed kernel modules load. DKMS modules will be rejected.

## Enclave OS Virtual

For a production deployment with container orchestration, RA-TLS, and LUKS-encrypted storage, use [Enclave OS Virtual](https://docs.privasys.org/solutions/enclave-os/presentation/) which builds on this image. The enclave-os-virtual GPU variant references cvm-images/tdx-gpu configs at build time and adds the workload layer (containerd, manager, caddy).
