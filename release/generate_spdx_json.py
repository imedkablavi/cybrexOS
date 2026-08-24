#!/usr/bin/env python3
import csv
import datetime as dt
import json
import os
import re
import sys
from pathlib import Path

manifest = Path(sys.argv[1] if len(sys.argv) > 1 else "artifacts/packages.tsv")
out = Path(sys.argv[2] if len(sys.argv) > 2 else "artifacts/cybrexOS.spdx.json")
if not manifest.is_file():
    raise SystemExit(f"missing package manifest: {manifest}")

sha = os.environ.get("GITHUB_SHA", "unknown")
epoch = os.environ.get("SOURCE_DATE_EPOCH")
if epoch:
    created = dt.datetime.fromtimestamp(int(epoch), tz=dt.timezone.utc)
else:
    created = dt.datetime.now(dt.timezone.utc)
created_s = created.replace(microsecond=0).isoformat().replace("+00:00", "Z")
namespace = f"https://github.com/imedkablavi/cybrexOS/sbom/{re.sub(r'[^A-Za-z0-9._-]', '_', sha)}/{epoch or 'unfixed'}"

packages = []
relationships = []
with manifest.open(newline="", encoding="utf-8") as fh:
    for idx, row in enumerate(csv.reader(fh, delimiter="\t"), start=1):
        if len(row) != 3:
            raise SystemExit(f"invalid manifest row {idx}: expected 3 tab-separated fields")
        name, version, arch = row
        spdx_id = "SPDXRef-Package-" + re.sub(r"[^A-Za-z0-9.-]", "-", f"{name}-{arch}-{idx}")
        packages.append({
            "SPDXID": spdx_id,
            "name": name,
            "versionInfo": version,
            "downloadLocation": "NOASSERTION",
            "filesAnalyzed": False,
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": "NOASSERTION",
            "copyrightText": "NOASSERTION",
            "comment": f"Debian architecture: {arch}",
        })
        relationships.append({
            "spdxElementId": "SPDXRef-DOCUMENT",
            "relationshipType": "DESCRIBES",
            "relatedSpdxElement": spdx_id,
        })

doc = {
    "spdxVersion": "SPDX-2.3",
    "dataLicense": "CC0-1.0",
    "SPDXID": "SPDXRef-DOCUMENT",
    "name": "cybrexOS-rootfs",
    "documentNamespace": namespace,
    "creationInfo": {
        "created": created_s,
        "creators": ["Tool: cybrexOS-release/generate_spdx_json.py"],
    },
    "packages": packages,
    "relationships": relationships,
}
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(out)
