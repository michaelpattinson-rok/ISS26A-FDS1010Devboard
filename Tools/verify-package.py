"""Validate the checked-in handbook, manufacturing files, binary checksums and local links."""
import csv
import hashlib
import json
from pathlib import Path
import re
import urllib.parse
import zipfile

root = Path(__file__).resolve().parents[1]


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


for manifest in (root / "RELEASE-SHA256SUMS.txt", root / "Firmware/Images/SHA256SUMS.txt",
                 root / "Software/Signal Bench/SHA256SUMS.txt"):
    for line in manifest.read_text().splitlines():
        digest, name = line.split("  ", 1)
        assert sha256(manifest.parent / name) == digest, name

manufacturing = root / "Manufacturing"
with zipfile.ZipFile(manufacturing / "FDS1010-Rev-E1-Budget-JLCPCB.zip") as archive:
    assert archive.testzip() is None
    suffixes = {Path(name).suffix.lower() for name in archive.namelist()}
    assert {".gbl", ".gtl", ".gts", ".gbs", ".gto", ".gbo", ".gm1", ".drl"} <= suffixes

with (manufacturing / "Complete DigiKey Order.csv").open(newline="") as stream:
    basket = {row["DigiKey Part Number"]: int(row["Quantity"]) for row in csv.DictReader(stream)}
with (manufacturing / "UPLOAD TO DIGIKEY.txt").open(newline="") as stream:
    upload = {row["DigiKey Part Number"]: int(row["Quantity"]) for row in csv.DictReader(stream, delimiter="\t")}
assert basket == upload and len(basket) == 22 and sum(basket.values()) == 65

pcb = root / "CAD/FDS1010_Budget_E.kicad_pcb"
models = re.findall(r'\(model "\$\{KIPRJMOD\}/([^"]+)"', pcb.read_text())
assert len(models) == 27 and all((pcb.parent / model).is_file() for model in models)

for catalog in (root / "Software/Signal Bench/Signal Bench/Assets.xcassets").rglob("Contents.json"):
    for item in json.loads(catalog.read_text()).get("images", []):
        if "filename" in item:
            assert (catalog.parent / item["filename"]).is_file(), catalog

for document in root.rglob("*.md"):
    if any(part.startswith(".") for part in document.relative_to(root).parts):
        continue
    for raw in re.findall(r"\]\(([^\s)]+)\)", document.read_text()):
        parsed = urllib.parse.urlsplit(raw)
        if parsed.scheme or not parsed.path:
            continue
        target = (document.parent / urllib.parse.unquote(parsed.path)).resolve()
        assert target.is_relative_to(root) and target.exists(), (document.relative_to(root), raw)

print("PASS: release hashes, Gerbers, DigiKey basket, all 27 PCB models, app images and local Markdown links")
