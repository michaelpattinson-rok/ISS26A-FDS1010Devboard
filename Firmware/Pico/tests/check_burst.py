"""Burst wire and profile regressions. Uses fabricated SDK registers, no device."""
from pathlib import Path
import io
import json
import os
import struct
import subprocess
import sys
import zlib

root = Path(__file__).resolve().parents[1]
out = Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)
subprocess.run([sys.executable, "-B", str(root / "tests/check_signal_bench.py"), str(out / "Protocol")], check=True)
checks = []
for sanitized in (False, True):
    name = "protocol-sanitized" if sanitized else "protocol"
    result = subprocess.run([str(out / "Protocol" / name), "--burst"], capture_output=True, check=True)
    record = result.stdout.split(b"BURST_BINARY_START\n", 1)[1].split(b"BURST_BINARY_END\n", 1)[0]
    stream = io.BytesIO(record)
    samples = bytearray()
    metadata = bytearray()
    frames = 0
    while line := stream.readline():
        fields = line.decode("ascii").strip().split()
        if fields[1] in ("BEGIN", "EVENT"):
            metadata.extend(line)
        elif fields[1] == "BINARY":
            token = fields[2]
            offset, count, checksum = int(fields[3]), int(fields[4]), int(fields[5], 16)
            assert offset == len(samples) // 2 and 0 < count <= 128
            payload = stream.read(count * 2)
            assert len(payload) == count * 2 and stream.read(1) == b"\n"
            covered = token.encode() + struct.pack("<IH", offset, count) + payload
            assert zlib.crc32(covered) == checksum
            samples.extend(payload)
            frames += 1
        elif fields[1] == "META":
            assert zlib.crc32(metadata) == int(fields[-1], 16)
        elif fields[1] == "END":
            assert len(samples) // 2 == int(fields[-2])
            assert zlib.crc32(samples) == int(fields[-1], 16)
    assert frames == 256 and len(samples) == 65536
    assert samples[:6] == b"\x0a\x80?\x00\r\x00" and samples[-2:] == b"\x01\x80"
    ascii_record = result.stdout.split(b"BURST_ASCII_START\n", 1)[1].split(b"BURST_ASCII_END\n", 1)[0]
    ascii_samples = b"".join(bytes.fromhex(line.split()[4].decode()) for line in ascii_record.splitlines() if line.startswith(b"SB1 DATA "))
    assert ascii_samples == samples
    assert b"PASS: burst multi-window calibration" in result.stdout
    if not sanitized:
        (out / "burst-wire.bin").write_bytes(record)
        (out / "burst-wire-ascii.txt").write_bytes(ascii_record)
        (out / "burst-control.txt").write_bytes(result.stdout.split(b"BURST_BINARY_START\n", 1)[0])
    executable = out / ("profiles-sanitized" if sanitized else "profiles")
    command = ["clang", "-std=c11", "-O1" if sanitized else "-O2", "-Wall", "-Wextra", "-Werror", "-pedantic", str(root / "pulse_estimator.c"), str(root / "tests/test_profiles.c"), "-lm", "-o", str(executable)]
    if sanitized:
        command += ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
    subprocess.run(command, check=True)
    profile = subprocess.run([str(executable)], capture_output=True, text=True, check=True)
    checks.append({"sanitized": sanitized, "frames": frames, "raw_bytes": len(samples), "profile": profile.stdout.strip(), "hardware_tested": False})
    print(name, "PASS binary framing, raw control bytes, CRC, calibration, mode restrictions and profiles")
(out / "burst-checks.json").write_text(json.dumps(checks, indent=2) + "\n")
