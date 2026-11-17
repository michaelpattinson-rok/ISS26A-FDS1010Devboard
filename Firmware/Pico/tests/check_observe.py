"""Validate raw observation policy using the actual firmware C fake-SDK peer."""
from pathlib import Path
import io
import json
import struct
import subprocess
import sys
import zlib

root = Path(__file__).resolve().parents[1]
out = Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)
subprocess.run([sys.executable, "-B", str(root / "tests/check_burst.py"), str(out / "Burst")], check=True)
checks = []
for sanitized in (False, True):
    executable = out / "Burst/Protocol" / ("protocol-sanitized" if sanitized else "protocol")
    result = subprocess.run([str(executable), "--burst"], capture_output=True, check=True)
    assert b"PASS: observation after rejected calibration" in result.stdout
    unwired = result.stdout.split(b"OBSERVE_UNWIRED_BINARY_START\n", 1)[1].split(b"OBSERVE_UNWIRED_BINARY_END\n", 1)[0]
    unwired_header = unwired.split(b"\n", 1)[0]
    assert b" gain_confirmed=0" in unwired_header and b" calibrated=0 " in unwired_header and b" observation_only=1 " in unwired_header
    record = result.stdout.split(b"OBSERVE_BINARY_START\n", 1)[1].split(b"OBSERVE_BINARY_END\n", 1)[0]
    stream = io.BytesIO(record)
    metadata = bytearray()
    raw = bytearray()
    events = []
    info = None
    while line := stream.readline():
        fields = line.decode("ascii").strip().split()
        if fields[1] in ("BEGIN", "EVENT"):
            metadata.extend(line)
            values = dict(item.split("=", 1) for item in fields[3:])
            if fields[1] == "BEGIN":
                info = values
            else:
                events.append(values)
        elif fields[1] == "BINARY":
            token, offset, count, checksum = fields[2], int(fields[3]), int(fields[4]), int(fields[5], 16)
            assert offset == len(raw) // 2 and 1 <= count <= 128
            payload = stream.read(count * 2)
            assert len(payload) == count * 2 and stream.read(1) == b"\n"
            assert zlib.crc32(token.encode() + struct.pack("<IH", offset, count) + payload) == checksum
            raw.extend(payload)
        elif fields[1] == "META":
            assert zlib.crc32(metadata) == int(fields[-1], 16)
        elif fields[1] == "END":
            assert int(fields[-2]) == len(raw) // 2
            assert zlib.crc32(raw) == int(fields[-1], 16)
    assert info is not None
    assert info["tag"] == "SOURCE" and info["observation_only"] == "1"
    assert info["threshold_origin"] == "record_noise" and info["profile"] == "NEGATIVE"
    assert info["calibrated"] == "0" and info["calibration_id"] == "0" and info["usable"] == "0"
    assert info["candidates"] == "1" and info["stored"] == "1"
    assert info["gain_confirmed"] == "1"
    assert info["quality_flags"] == "0" and info["rate_exposure_valid"] == "0"
    assert len(events) == 1 and events[0]["qualified"] == "0" and events[0]["flags"] == "0"
    words = struct.unpack("<32768H", raw)
    assert words[0] == 2048 and words[6000] == 1948
    if not sanitized:
        (out / "observe-wire.bin").write_bytes(record)
        (out / "observe-unwired-wire.bin").write_bytes(unwired)
        before = result.stdout.split(b"OBSERVE_BINARY_START\n", 1)[0]
        if b"BURST_BINARY_START\n" in before:
            first, rest = before.split(b"BURST_BINARY_START\n", 1)
            before = first + rest.split(b"BURST_BINARY_END\n", 1)[1]
        control = [line for line in before.splitlines() if line.startswith((b"SB1 READY ", b"SB1 ERROR ", b"SB1 STATUS ", b"SB1 HELLO ", b"PASS:"))]
        (out / "observe-control.txt").write_bytes(b"\n".join(control) + b"\n")
    checks.append({"sanitized": sanitized, "raw_samples": len(words), "candidates": len(events), "qualified": 0,
                   "unknown_gain_raw_capture_verified": True, "record_crc_verified": True, "metadata_crc_verified": True, "hardware_tested": False})
    print(("sanitized" if sanitized else "optimized") + ": PASS observation metadata, raw negative waveform, diagnostic candidate and CRC integrity")
(out / "observe-checks.json").write_text(json.dumps(checks, indent=2) + "\n")
