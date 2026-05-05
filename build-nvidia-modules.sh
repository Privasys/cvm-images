#!/bin/bash
# Build patched NVIDIA open kernel modules for TDX Confidential Computing.
#
# This script:
#   1. Downloads the NVIDIA open-gpu-kernel-modules source (595.58.03)
#   2. Applies the TDX CC patches from patches/nvidia/
#   3. Builds kernel modules against the specified kernel headers
#   4. Packages the modules + GSP firmware into a tarball
#
# The resulting nvidia-cc-bundle contains:
#   modules/nvidia.ko, nvidia-uvm.ko, nvidia-modeset.ko
#   firmware/nvidia/595.58.03/gsp_ga10x.bin, gsp_tu10x.bin
#
# Requirements:
#   - Ubuntu 24.04 build environment
#   - ~10 GB disk, ~15 min build time on 8 cores
#   - Kernel headers matching the target kernel
#
# Usage:
#   ./build-nvidia-modules.sh [--output-dir /path/to/output]
#   ./build-nvidia-modules.sh --kernel-version 6.17.0-23-generic

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCH_DIR="$SCRIPT_DIR/patches/nvidia"
OUTPUT_DIR="${1:-$SCRIPT_DIR/nvidia-cc-bundle}"
NVIDIA_VERSION="595.58.03"
NVIDIA_URL="https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/${NVIDIA_VERSION}.tar.gz"
BUILD_DIR="/tmp/privasys-nvidia-build-$$"
JOBS="$(nproc)"

# Parse arguments
KERNEL_VERSION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --kernel-version) KERNEL_VERSION="$2"; shift 2 ;;
        *) shift ;;
    esac
done

echo "=== Privasys NVIDIA Module Builder (TDX CC) ==="
echo "NVIDIA:     $NVIDIA_VERSION"
echo "Patches:    $PATCH_DIR"
echo "Output:     $OUTPUT_DIR"
echo "Scratch:    $BUILD_DIR"
echo "Parallel:   $JOBS"

cleanup() {
    local rc=$?
    if [ $rc -ne 0 ]; then
        echo ""
        echo "=== BUILD FAILED (exit $rc) ==="
    fi
    rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

# -- Step 0: Build dependencies --
echo ""
echo "=== Installing build dependencies ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
    build-essential wget ca-certificates \
    linux-headers-generic-hwe-24.04 2>/dev/null || true

# -- Step 1: Determine kernel version --
if [ -z "$KERNEL_VERSION" ]; then
    # Find the installed HWE kernel headers
    KERNEL_VERSION=$(ls -1 /usr/src/ | grep -oP 'linux-headers-\K\d[\d.]+\d-\d+-generic' | sort -V | tail -1)
    if [ -z "$KERNEL_VERSION" ]; then
        echo "ERROR: No kernel headers found. Install linux-headers-generic-hwe-24.04 or use --kernel-version"
        exit 1
    fi
fi
HEADERS_DIR="/usr/src/linux-headers-$KERNEL_VERSION"
if [ ! -d "$HEADERS_DIR" ]; then
    echo "ERROR: Kernel headers not found at $HEADERS_DIR"
    exit 1
fi
echo "Kernel:     $KERNEL_VERSION"
echo "Headers:    $HEADERS_DIR"

# -- Step 2: Download NVIDIA source --
echo ""
echo "=== Downloading NVIDIA open-gpu-kernel-modules $NVIDIA_VERSION ==="
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

TARBALL="nvidia-open-${NVIDIA_VERSION}.tar.gz"
if [ ! -f "$TARBALL" ]; then
    wget -q -O "$TARBALL" "$NVIDIA_URL"
fi

echo "Extracting..."
tar xzf "$TARBALL"
SRC_DIR="$BUILD_DIR/open-gpu-kernel-modules-${NVIDIA_VERSION}"
cd "$SRC_DIR"

# -- Step 3: Apply TDX CC patches --
echo ""
echo "=== Applying TDX CC patches (full set) ==="
PATCH_GLOB="$PATCH_DIR/00*.patch"
for patch_file in $PATCH_GLOB; do
    [ -f "$patch_file" ] || continue
    name=$(basename "$patch_file")
    if patch -p1 --dry-run < "$patch_file" >/dev/null 2>&1; then
        patch -p1 < "$patch_file"
        echo "  Applied: $name"
    else
        echo "ERROR: Failed to apply $name"
        patch -p1 --dry-run < "$patch_file" || true
        exit 1
    fi
done

# -- Step 4: Build kernel modules --
echo ""
echo "=== Building NVIDIA kernel modules ==="
make -j"$JOBS" modules \
    SYSSRC="$HEADERS_DIR" \
    SYSOUT="$HEADERS_DIR" \
    2>&1 | tail -5

echo ""
echo "Built modules:"
ls -lh kernel-open/nvidia.ko kernel-open/nvidia-uvm.ko kernel-open/nvidia-modeset.ko

# -- Step 5: Package bundle --
echo ""
echo "=== Packaging nvidia-cc-bundle ==="
mkdir -p "$OUTPUT_DIR/modules" "$OUTPUT_DIR/firmware/nvidia/${NVIDIA_VERSION}"

cp kernel-open/nvidia.ko "$OUTPUT_DIR/modules/"
cp kernel-open/nvidia-uvm.ko "$OUTPUT_DIR/modules/"
cp kernel-open/nvidia-modeset.ko "$OUTPUT_DIR/modules/"

# GSP firmware is shipped in the source tree
cp kernel-open/nvidia/gsp_ga10x.bin "$OUTPUT_DIR/firmware/nvidia/${NVIDIA_VERSION}/" 2>/dev/null || \
    cp firmware/gsp_ga10x.bin "$OUTPUT_DIR/firmware/nvidia/${NVIDIA_VERSION}/" 2>/dev/null || \
    echo "WARNING: gsp_ga10x.bin not found in source tree"
cp kernel-open/nvidia/gsp_tu10x.bin "$OUTPUT_DIR/firmware/nvidia/${NVIDIA_VERSION}/" 2>/dev/null || \
    cp firmware/gsp_tu10x.bin "$OUTPUT_DIR/firmware/nvidia/${NVIDIA_VERSION}/" 2>/dev/null || \
    echo "WARNING: gsp_tu10x.bin not found in source tree"

# Create metadata
cat > "$OUTPUT_DIR/BUILD-INFO" <<EOF
nvidia_version=$NVIDIA_VERSION
kernel_version=$KERNEL_VERSION
build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)
patches=$(ls -1 $PATCH_GLOB 2>/dev/null | xargs -I{} basename {} | tr '\n' ' ')
EOF

# Create tarball
BUNDLE_TAR="$(dirname "$OUTPUT_DIR")/nvidia-cc-bundle-${NVIDIA_VERSION}-${KERNEL_VERSION}.tar.gz"
tar -czf "$BUNDLE_TAR" -C "$(dirname "$OUTPUT_DIR")" "$(basename "$OUTPUT_DIR")"
echo ""
echo "Bundle: $BUNDLE_TAR"
ls -lh "$BUNDLE_TAR"

echo ""
echo "=== Done ==="
echo "Modules:  $OUTPUT_DIR/modules/"
echo "Firmware: $OUTPUT_DIR/firmware/"
echo "Tarball:  $BUNDLE_TAR"
