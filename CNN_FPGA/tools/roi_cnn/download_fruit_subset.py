#!/usr/bin/env python3
"""Download a small, pinned Fruits-360 subset; leave source train/test splits intact."""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import time
import urllib.parse
import urllib.request

REPOSITORY = "fruits-360/fruits-360-100x100"
REVISION = "cd2921eed66223cc1e5dc6a6cc089b8e9cd4ab21"
GROUPS = {
    "Apple Red 1": 0, "Apple Granny Smith 1": 0,
    "Banana 1": 1, "Orange 1": 2,
    "Kiwi 1": 3, "Lemon 1": 3, "Pear 1": 3,
}
CLASSES = ["APPLE", "BANANA", "ORANGE", "OTHER"]


def fetch(url):
    for attempt in range(5):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "fpga-roi-cnn-reproducible-dataset"})
            with urllib.request.urlopen(request, timeout=45) as response:
                return response.read()
        except Exception:
            if attempt == 4:
                raise
            time.sleep(1 + attempt)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--workers", type=int, default=12)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    entries = []
    for split in ("Training", "Test"):
        for group, label in GROUPS.items():
            relative = f"{split}/{group}"
            listing_path = args.output / "listings" / (relative.replace("/", "_") + ".json")
            listing_path.parent.mkdir(exist_ok=True)
            if not listing_path.exists():
                url = f"https://api.github.com/repos/{REPOSITORY}/contents/{urllib.parse.quote(relative)}?ref={REVISION}"
                listing_path.write_bytes(fetch(url))
            listing = sorted((x for x in json.loads(listing_path.read_text()) if x["name"].lower().endswith(".jpg")), key=lambda x: x["name"])
            # Uniform coverage of the filenames instead of taking only the first rotation.
            limit = (250 if label in (0, 3) else 500) if split == "Training" else 120
            count = min(limit, len(listing))
            chosen = [listing[i * len(listing) // count] for i in range(count)]
            for item in chosen:
                path = relative + "/" + item["name"]
                entries.append({"path": path, "label": label, "source_blob": item["sha"],
                                "url": f"https://raw.githubusercontent.com/{REPOSITORY}/{REVISION}/{urllib.parse.quote(path)}"})
            print(relative, len(chosen), flush=True)

    def download(entry):
        path = args.output / entry["path"]
        path.parent.mkdir(parents=True, exist_ok=True)
        data = path.read_bytes() if path.exists() else fetch(entry["url"])
        blob_sha = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
        if blob_sha != entry["source_blob"]:
            raise RuntimeError(f"Source hash mismatch: {entry['path']}")
        if not path.exists():
            path.write_bytes(data)
        return dict(entry, sha256=hashlib.sha256(data).hexdigest())

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as executor:
        verified = list(executor.map(download, entries))
    manifest = {"repository": REPOSITORY, "revision": REVISION, "license": "CC-BY-SA-4.0",
                "attribution": "Mihai Oltean, Fruits-360 dataset, 2017-", "classes": CLASSES,
                "entries": verified}
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Verified {len(verified)} images; manifest: {args.output / 'manifest.json'}", flush=True)


if __name__ == "__main__":
    main()
