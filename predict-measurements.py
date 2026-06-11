#!/usr/bin/env python3
"""Predict TDX RTMR[1] and RTMR[2] from a built CVM image, without booting it.

On the GCP TDX boot chain (TDVF -> shim -> GRUB -> kernel) every event
extended into CC MR 2 (RTMR[1]) and CC MR 3 (RTMR[2]) is derived from the
image contents or from fixed strings defined by the TCG PC Client spec:

  RTMR[1]  "Calling EFI Application from Boot Option"   (spec string)
           EV_SEPARATOR                                  (00000000)
           UEFI_GPT_DATA                                 (image GPT)
           shim PE/COFF Authenticode digest              (ESP file)
           GRUB PE/COFF Authenticode digest              (ESP file)
           "Exit Boot Services Invocation"               (spec string)
           "Exit Boot Services Returned with Success"    (spec string)

  RTMR[2]  MokList / MokListX / MokListTrusted           (shim, no MOK)
           stub grub.cfg contents (measured twice)       (ESP file)
           one grub_cmd event per executed command       (grub.cfg)
           main grub.cfg contents                        (ESP file)
           kernel image contents                         (ESP file)
           kernel_cmdline                                (grub.cfg)
           initrd contents (one event per initrd file)   (ESP files)

Every digest rule below was validated byte-for-byte against the CCEL
event log of a live GCP TDX instance (2026-06-11, shim 15.8, GRUB 2.12,
Ubuntu 24.04). Replay: RTMR = SHA384(RTMR || event_digest), starting at
48 zero bytes.

The MokList* digests depend on the shim build and MOK state. Our images
enroll no MOK keys, so the values are constants for a given shim binary;
they can be overridden with --mok-digests if shim is ever updated and
the values change (recapture from any boot's event log).

Usage:
  predict-measurements.py --image disk.raw --esp /mnt/esp [--json out.json]

  --image  raw disk image or block device (for the GPT event)
  --esp    mounted (or extracted) ESP directory tree
"""

import argparse
import hashlib
import json
import struct
import sys
from pathlib import Path

SECTOR = 512

# Captured from shim 15.8 (Ubuntu noble, no MOK keys enrolled), validated
# against a live boot. Recapture from any CCEL event log if shim changes:
# they are the EV_IPL digests whose event data is the variable name.
DEFAULT_MOK_DIGESTS = [
    # MokList
    "053357ea65185f010b8caa1fc265cfd5e80c7cc781254fa3f1e5ea9d345a87003cf761472a2f0423f15297f55cfe248f",
    # MokListX
    "80ee2571334a57bf90238d21964447e542079d4805fa87887817a97dcb720906683a09b1ac634c76c0c0be1177f76110",
    # MokListTrusted
    "8d2ce87d86f55fcfab770a047b090da23270fa206832dfea7e0c946fff451f819add242374be551b0d6318ed6c7d41d8",
]

SPEC_STRINGS_RTMR1_PRE = ["Calling EFI Application from Boot Option"]
SPEC_STRINGS_RTMR1_POST = [
    "Exit Boot Services Invocation",
    "Exit Boot Services Returned with Success",
]


def sha384(b: bytes) -> bytes:
    return hashlib.sha384(b).digest()


def extend(rtmr: bytes, digest: bytes) -> bytes:
    return sha384(rtmr + digest)


# --- PE/COFF Authenticode (MS PE spec section "Calculating the PE Image Hash")


def authenticode_sha384(data: bytes) -> bytes:
    h = hashlib.sha384()
    pe_off = struct.unpack_from("<I", data, 0x3C)[0]
    coff = pe_off + 4
    num_sections = struct.unpack_from("<H", data, coff + 2)[0]
    opt_size = struct.unpack_from("<H", data, coff + 16)[0]
    opt = coff + 20
    magic = struct.unpack_from("<H", data, opt)[0]
    cksum_off = opt + 64
    ddir_off = opt + (112 if magic == 0x20B else 96)
    cert_entry_off = ddir_off + 4 * 8
    cert_rva, cert_size = struct.unpack_from("<II", data, cert_entry_off)
    size_of_headers = struct.unpack_from("<I", data, opt + 60)[0]

    h.update(data[:cksum_off])
    h.update(data[cksum_off + 4 : cert_entry_off])
    h.update(data[cert_entry_off + 8 : size_of_headers])

    sec_off = opt + opt_size
    secs = []
    for i in range(num_sections):
        o = sec_off + i * 40
        size_raw, ptr_raw = struct.unpack_from("<II", data, o + 16)
        if size_raw:
            secs.append((ptr_raw, size_raw))
    sum_hashed = size_of_headers
    for ptr, size in sorted(secs):
        h.update(data[ptr : ptr + size])
        sum_hashed += size
    if len(data) > sum_hashed:
        extra = len(data) - sum_hashed - (cert_size if cert_rva else 0)
        if extra > 0:
            h.update(data[sum_hashed : sum_hashed + extra])
    return h.digest()


# --- GPT event (TCG UEFI_GPT_DATA: header + UINT64 count + in-use entries)


def gpt_event_data(image: Path) -> bytes:
    with open(image, "rb") as f:
        f.seek(SECTOR)  # LBA 1: primary GPT header
        hdr = f.read(92)
        if hdr[:8] != b"EFI PART":
            raise SystemExit(f"no GPT header at LBA1 of {image}")
        entry_lba = struct.unpack_from("<Q", hdr, 72)[0]
        num_entries = struct.unpack_from("<I", hdr, 80)[0]
        entry_size = struct.unpack_from("<I", hdr, 84)[0]
        f.seek(entry_lba * SECTOR)
        raw = f.read(num_entries * entry_size)
    used = [
        raw[i : i + entry_size]
        for i in range(0, len(raw), entry_size)
        if raw[i : i + 16] != b"\x00" * 16
    ]
    return hdr + struct.pack("<Q", len(used)) + b"".join(used)


# --- grub.cfg -> measured grub_cmd sequence -------------------------------
#
# GRUB measures each executed command (after variable expansion, quotes
# removed) as "grub_cmd: <cmd>" with the digest computed over <cmd> alone,
# plus "kernel_cmdline: <args>" over <args>, plus the contents of every
# file it reads. Our mkosi-generated grub.cfg has a fixed shape; anything
# unrecognised is a hard error so the predictor can never silently drift
# from what GRUB will actually measure.


def parse_grub_cfg(text: str):
    """Yield (kind, payload) where kind is 'cmd', 'file' or 'cmdline'."""
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            i += 1
            continue
        if stripped == "fi" or stripped == "}":
            i += 1
            continue
        if stripped.startswith("set "):
            yield ("cmd", stripped)
            i += 1
            continue
        if stripped.startswith("if [") and stripped.endswith("; then"):
            cond = stripped[len("if ") : -len("; then")].strip()
            cond = cond.replace('"${grub_platform}"', "efi")
            cond = cond.replace("${grub_platform}", "efi")
            cond = cond.replace('"', "")
            yield ("cmd", cond)
            i += 1
            continue
        if stripped.startswith("menuentry "):
            # measured text: full menuentry block, quotes around the
            # title removed, body lines verbatim, closing brace included
            title = stripped[len("menuentry ") :].rstrip("{").strip().strip('"')
            body = []
            i += 1
            while i < len(lines) and lines[i].strip() != "}":
                body.append(lines[i])
                i += 1
            i += 1  # consume "}"
            menused = "menuentry " + title + " {\n" + "\n".join(body) + "\n}"
            yield ("cmd", menused)
            yield ("cmd", "setparams " + title)
            for bline in body:
                b = bline.strip()
                if b.startswith("linux "):
                    yield ("cmd", b)
                    parts = b.split()
                    yield ("file", parts[1])
                    yield ("cmdline", b[len("linux ") :])
                elif b.startswith("initrd "):
                    yield ("cmd", b)
                    for p in b.split()[1:]:
                        yield ("file", p)
                elif b:
                    raise SystemExit(f"unhandled menuentry body line: {b!r}")
            continue
        if stripped.startswith("configfile "):
            yield ("cmd", stripped)
            i += 1
            continue
        raise SystemExit(f"unhandled grub.cfg line: {stripped!r}")


def find_one(esp: Path, candidates) -> Path:
    for c in candidates:
        p = esp / c
        if p.is_file():
            return p
    raise SystemExit(f"none of {candidates} found under {esp}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", required=True, help="raw image or block device")
    ap.add_argument("--esp", required=True, help="mounted/extracted ESP dir")
    ap.add_argument("--json", help="write full event manifest to this file")
    ap.add_argument(
        "--mok-digests",
        help="comma-separated hex SHA-384 digests for MokList,MokListX,"
        "MokListTrusted (defaults: shim 15.8, no MOK enrolled)",
    )
    args = ap.parse_args()
    esp = Path(args.esp)

    shim = find_one(esp, ["EFI/BOOT/BOOTX64.EFI", "EFI/boot/bootx64.efi"])
    grub = find_one(esp, ["EFI/BOOT/grubx64.EFI", "EFI/BOOT/grubx64.efi"])
    stub_cfg = find_one(esp, ["EFI/ubuntu/grub.cfg"])
    main_cfg = find_one(esp, ["grub/grub.cfg"])
    mok = (
        [bytes.fromhex(x) for x in args.mok_digests.split(",")]
        if args.mok_digests
        else [bytes.fromhex(x) for x in DEFAULT_MOK_DIGESTS]
    )

    events1 = []  # (label, digest)
    for s in SPEC_STRINGS_RTMR1_PRE:
        events1.append((f"action:{s}", sha384(s.encode())))
    events1.append(("separator", sha384(b"\x00\x00\x00\x00")))
    events1.append(("gpt", sha384(gpt_event_data(Path(args.image)))))
    events1.append(("authenticode:shim", authenticode_sha384(shim.read_bytes())))
    events1.append(("authenticode:grub", authenticode_sha384(grub.read_bytes())))
    for s in SPEC_STRINGS_RTMR1_POST:
        events1.append((f"action:{s}", sha384(s.encode())))

    events2 = []
    for name, d in zip(["MokList", "MokListX", "MokListTrusted"], mok):
        events2.append((f"shim:{name}", d))
    stub_bytes = stub_cfg.read_bytes()
    events2.append(("file:EFI/ubuntu/grub.cfg", sha384(stub_bytes)))
    events2.append(("file:EFI/ubuntu/grub.cfg", sha384(stub_bytes)))
    for kind, payload in parse_grub_cfg(stub_bytes.decode()):
        if kind != "cmd":
            raise SystemExit("stub grub.cfg must contain only commands")
        events2.append((f"grub_cmd:{payload[:60]}", sha384(payload.encode())))
    main_bytes = main_cfg.read_bytes()
    events2.append(("file:grub/grub.cfg", sha384(main_bytes)))
    for kind, payload in parse_grub_cfg(main_bytes.decode()):
        if kind == "cmd":
            events2.append((f"grub_cmd:{payload[:60]}", sha384(payload.encode())))
        elif kind == "cmdline":
            events2.append((f"kernel_cmdline:{payload[:60]}", sha384(payload.encode())))
        elif kind == "file":
            p = esp / payload.lstrip("/")
            events2.append((f"file:{payload}", sha384(p.read_bytes())))

    rtmr1 = b"\x00" * 48
    for _, d in events1:
        rtmr1 = extend(rtmr1, d)
    rtmr2 = b"\x00" * 48
    for _, d in events2:
        rtmr2 = extend(rtmr2, d)

    print(f"RTMR[1] = {rtmr1.hex()}")
    print(f"RTMR[2] = {rtmr2.hex()}")
    if args.json:
        manifest = {
            "rtmr1": rtmr1.hex(),
            "rtmr2": rtmr2.hex(),
            "rtmr1_events": [{"event": l, "digest": d.hex()} for l, d in events1],
            "rtmr2_events": [{"event": l, "digest": d.hex()} for l, d in events2],
        }
        Path(args.json).write_text(json.dumps(manifest, indent=2) + "\n")
        print(f"manifest written to {args.json}")


if __name__ == "__main__":
    main()
