#!/usr/bin/env python3
"""Lock exact AOSP Clang source revisions from a matching prebuilt manifest."""
import argparse
import base64
import hashlib
import json
import re
import subprocess
import sys
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
import xml.etree.ElementTree as ET

PREBUILTS = "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86"
BRANCHES = {
    "r450784e": ("master-kernel-build-2022", "llvm-r450784"),
    "r487747c": ("main-kernel-build-2023", "llvm-r487747"),
    "r510928": ("main-kernel-build-2024", "llvm-r510928"),
    "r536225": ("main", "llvm-r536225-release"),
    "r584948c": ("main-kernel-2026", "mirror-goog-llvm-r584948-release"),
}
REQUIRED = {
    "toolchain/llvm-project": "llvm_project",
    "toolchain/llvm_android": "llvm_android",
    "external/toolchain-utils": "toolchain_utils",
}


def fetch(url, decode_json=False, decode_base64=False):
    for attempt in range(4):
        try:
            request = Request(url, headers={"User-Agent": "AOSP-Clang-ARM64-Source-Lock/1.0"})
            with urlopen(request, timeout=55) as response:
                raw = response.read(16 * 1024 * 1024)
            if decode_json:
                return json.loads(raw.decode("utf-8").removeprefix(")]}'\n"))
            if decode_base64:
                return base64.b64decode(raw, validate=False)
            return raw
        except (HTTPError, URLError, ValueError) as e:
            if attempt == 3:
                raise RuntimeError(f"Gitiles request failed after 4 attempts: {url}: {e}") from e
            time.sleep(2 + attempt * 3)


def run(revision, out_dir):
    branch, _ = BRANCHES[revision]
    ref_name = "refs/heads/" + branch
    result = subprocess.check_output(
        ["git", "ls-remote", PREBUILTS, ref_name], text=True, timeout=90).strip()
    if not result:
        raise RuntimeError("Missing prebuilt branch: " + ref_name)
    commit = result.split()[0]
    assert re.fullmatch(r"[0-9a-f]{40}", commit)
    base_url = f"{PREBUILTS}/+/{commit}/clang-{revision}"
    tree = fetch(base_url + "/?format=JSON", decode_json=True)
    file_list = [x["name"] for x in tree.get("entries", []) if x.get("type") == "blob"]
    manifests = [s for s in file_list if re.fullmatch(r"manifest_[0-9]+\.xml", s)]
    if not manifests:
        raise RuntimeError(f"No release manifest in {ref_name}/clang-{revision}, found {file_list}")
    manifest_name = max(manifests, key=lambda s: int(re.search(r"\d+", s).group()))
    manifest_url = f"{base_url}/{manifest_name}?format=TEXT"
    xml = fetch(manifest_url, decode_base64=True)
    version_file = fetch(f"{base_url}/AndroidVersion.txt?format=TEXT", decode_base64=True)
    version_text = version_file.decode("utf-8")
    match = re.match(r"^(\d+\.\d+\.\d+)\s*$", version_text)
    if not match:
        raise RuntimeError("Could not identify version: " + version_text)
    clang_version = match.group(1)
    if f"based on {revision}" not in version_text:
        raise RuntimeError(f"Revision mismatch ({revision}): {version_text}")
    projects = {}
    for entry in ET.fromstring(xml).iter("project"):
        projects[entry.attrib.get("path", "")] = entry.attrib.get("revision", "")
    pinned = {key: projects.get(path) for path, key in REQUIRED.items()}
    for key, commit_sha in pinned.items():
        if not commit_sha or not re.fullmatch(r"[0-9a-f]{40}", commit_sha):
            raise RuntimeError(f"Manifest source SHA missing for {key}: {commit_sha}")
    record = {
        "aosp_revision": revision,
        "clang_version": clang_version,
        "llvm_revision": revision[1:].rstrip("abcdefghijklmnopqrstuvwxyz"),
        "build_id": manifest_name[len("manifest_"):-len(".xml")],
        "host": "Linux AArch64/glibc (rebuild target)",
        "prebuilt_branch": branch,
        "prebuilt_commit": commit,
        "manifest_name": manifest_name,
        "manifest_url": manifest_url,
        "manifest_sha256": hashlib.sha256(xml).hexdigest(),
        "version_txt_sha256": hashlib.sha256(version_file).hexdigest(),
        "sources": pinned,
    }
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / f"{revision}.json").write_text(json.dumps(record, indent=2) + "\n")
    (out_dir / f"{revision}-{manifest_name}").write_bytes(xml)
    print(json.dumps(record, indent=2), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("revision", choices=sorted(BRANCHES))
    parser.add_argument("--output", default="out/aosp-source-locks")
    args = parser.parse_args()
    run(args.revision, Path(args.output))
