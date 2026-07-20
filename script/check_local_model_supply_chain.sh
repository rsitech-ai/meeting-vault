#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOURCE_ROOT="$ROOT_DIR/Sources/MeetingVaultCore/Resources"
MANIFEST="$RESOURCE_ROOT/LocalModels.json"
RESOLVED="$ROOT_DIR/Package.resolved"

if [[ ! -f "$MANIFEST" ]]; then
  printf '[BLOCKED] Local model manifest is missing.\n' >&2
  exit 1
fi
if [[ ! -f "$RESOLVED" ]]; then
  printf '[BLOCKED] Package.resolved is missing.\n' >&2
  exit 1
fi

unexpected_resource="$(
  find "$RESOURCE_ROOT" -type f \
    ! -path "$MANIFEST" \
    ! -path "$RESOURCE_ROOT/ThirdPartyNotices/*" \
    -print -quit
)"
if [[ -n "$unexpected_resource" ]]; then
  printf '[BLOCKED] Model binary or unexpected file reached core resources.\n' >&2
  exit 1
fi

tracked_model_binary="$(
  git -C "$ROOT_DIR" ls-files | awk '
    BEGIN { IGNORECASE = 1 }
    /(^|\/)(modeldownloads|localmodels)\// ||
    /\.mlmodelc\// || /\.mlpackage\// ||
    /\.(bin|mlmodel|onnx|safetensors|pt|pth|ckpt)$/ { print; exit }
  '
)"
if [[ -n "$tracked_model_binary" ]]; then
  printf '[BLOCKED] A model binary is tracked by Git.\n' >&2
  exit 1
fi

lfs_pointer="$(
  git -C "$ROOT_DIR" grep -Il -- 'version https://git-lfs.github.com/spec/v1' -- \
    '*.bin' '*.mlmodel' '*.onnx' '*.safetensors' '*.pt' '*.pth' '*.ckpt' 2>/dev/null | head -n 1 || true
)"
if [[ -n "$lfs_pointer" ]]; then
  printf '[BLOCKED] A Git LFS pointer is tracked where model content was expected.\n' >&2
  exit 1
fi

python3 - "$MANIFEST" "$RESOLVED" "$ROOT_DIR/Package.swift" "$RESOURCE_ROOT/ThirdPartyNotices" <<'PY'
import hashlib
import json
from pathlib import Path
import re
import sys
from urllib.parse import unquote, urlparse

manifest_path, resolved_path, package_path, notices_path = map(Path, sys.argv[1:])
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
if set(manifest) != {"schemaVersion", "assets"} or manifest.get("schemaVersion") != 1 or not manifest.get("assets"):
    raise SystemExit("[BLOCKED] Local model manifest schema or assets are invalid.")
if len(manifest["assets"]) != 47 or sum(asset.get("expectedBytes", 0) for asset in manifest["assets"]) != 549329361:
    raise SystemExit("[BLOCKED] Local model manifest selection count or total bytes drifted.")
if hashlib.sha256(manifest_path.read_bytes()).hexdigest() != "e8fe1789f860edf1255226607a53de00569a494a3c770ae8ba67b7925c679c88":
    raise SystemExit("[BLOCKED] Local model manifest digest drifted.")

private_markers = ("authorization", "bearer ", "api_key", "api-key", "token=", "password=")
serialized = json.dumps(manifest, sort_keys=True).lower()
if any(marker in serialized for marker in private_markers):
    raise SystemExit("[BLOCKED] Local model manifest contains a credential-shaped value.")

ids = set()
paths = set()
sources = set()
for asset in manifest["assets"]:
    if set(asset) != {"id", "feature", "version", "sourceURL", "sourceRevision", "licenseName", "licenseURL", "expectedBytes", "sha256", "relativeInstallPath"}:
        raise SystemExit("[BLOCKED] Local model manifest has an unexpected asset key.")
    for key in ("id", "feature", "version", "sourceRevision", "licenseName", "sha256", "relativeInstallPath"):
        if not isinstance(asset.get(key), str) or not asset[key].strip():
            raise SystemExit("[BLOCKED] Local model manifest has a missing required value.")
    if not re.fullmatch(r"[0-9a-f]{64}", asset["sha256"]):
        raise SystemExit("[BLOCKED] Local model manifest has an invalid digest.")
    if not re.fullmatch(r"[0-9a-f]{40}", asset["sourceRevision"]):
        raise SystemExit("[BLOCKED] Local model manifest has an invalid revision.")
    if not isinstance(asset.get("expectedBytes"), int) or not 0 < asset["expectedBytes"] <= 4 * 1024**3:
        raise SystemExit("[BLOCKED] Local model manifest has an invalid size.")
    for key in ("sourceURL", "licenseURL"):
        parsed = urlparse(asset.get(key, ""))
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise SystemExit("[BLOCKED] Local model manifest has an unsafe URL.")
    source = urlparse(asset["sourceURL"])
    try:
        source_port = source.port
    except ValueError:
        raise SystemExit("[BLOCKED] Local model source URL host drifted.")
    if source.hostname != "huggingface.co" or source_port not in (None, 443):
        raise SystemExit("[BLOCKED] Local model source URL host drifted.")
    if asset["id"] in ids or asset["relativeInstallPath"] in paths or asset["sourceURL"] in sources:
        raise SystemExit("[BLOCKED] Local model manifest contains a duplicate entry.")
    ids.add(asset["id"])
    paths.add(asset["relativeInstallPath"])
    sources.add(asset["sourceURL"])

expected_repositories = {
    "FluidInference/parakeet-tdt-0.6b-v3-coreml": {
        "revision": "aed02740059203c4a87495924f685de3722ae9ce",
        "feature": "automatic-speech-recognition",
        "version": "parakeet-tdt-0.6b-v3-coreml",
        "licenseName": "CC-BY-4.0",
        "licenseURL": "https://creativecommons.org/licenses/by/4.0/legalcode.txt",
        "runtimeRoot": "parakeet-tdt-0.6b-v3",
        "sourcePrefix": "",
        "count": 21,
        "bytes": 483105645,
        "fileSetDigest": "6ef1a36ebb3f2aee46a9da65d8abb013389e42fbac58bab89d8f789f6d932685",
    },
    "FluidInference/ls-eend-coreml": {
        "revision": "28ce1b1f8ef186729df63b3886fbaae7bc10c4a1",
        "feature": "streaming-speaker-diarization",
        "version": "ls-eend-coreml-dihard3-100ms",
        "licenseName": "MIT",
        "licenseURL": "https://opensource.org/license/mit",
        "runtimeRoot": "ls-eend/dih3/optimized/dih3",
        "sourcePrefix": "optimized/dih3",
        "count": 5,
        "bytes": 44624299,
        "fileSetDigest": "42b6b691abce5f9cfdf58d41cbf25e250fb709edd0ada17594e6e3c0882f64af",
    },
    "FluidInference/speaker-diarization-coreml": {
        "revision": "1ed7a662fdc7109e36d822db793ee6eebdaf8594",
        "feature": "offline-speaker-diarization",
        "version": "speaker-diarization-coreml",
        "licenseName": "CC-BY-4.0",
        "licenseURL": "https://creativecommons.org/licenses/by/4.0/legalcode.txt",
        "runtimeRoot": "speaker-diarization",
        "sourcePrefix": "",
        "count": 21,
        "bytes": 21599417,
        "fileSetDigest": "1f732712ddfae50a104894f6f546e4e58b48fe13283a7b61683d4df3f52e7d63",
    },
}

assets_by_repository = {repository: [] for repository in expected_repositories}
for asset in manifest["assets"]:
    source = urlparse(asset["sourceURL"])
    decoded_path = unquote(source.path)
    segments = decoded_path.split("/")
    if len(segments) < 6 or segments[:2] != ["", "FluidInference"] or segments[3] != "resolve":
        raise SystemExit("[BLOCKED] Local model source URL path drifted.")
    repository = "/".join(segments[1:3])
    expected = expected_repositories.get(repository)
    if expected is None:
        raise SystemExit("[BLOCKED] Local model manifest repository drifted.")
    revision = segments[4]
    file_path = "/".join(segments[5:])
    if not file_path or any(part in ("", ".", "..") for part in file_path.split("/")):
        raise SystemExit("[BLOCKED] Local model source URL path drifted.")
    expected_source = f"https://huggingface.co/{repository}/resolve/{expected['revision']}/{file_path}"
    if asset["sourceURL"] != expected_source or revision != expected["revision"]:
        raise SystemExit("[BLOCKED] Local model source URL is not bound to the approved exact revision.")
    if any(asset[key] != expected[key] for key in ("feature", "version", "licenseName", "licenseURL")):
        raise SystemExit("[BLOCKED] Local model manifest provenance tuple drifted.")
    if asset["sourceRevision"] != expected["revision"]:
        raise SystemExit("[BLOCKED] Local model manifest revision drifted.")
    if asset["id"] != f"{repository.split('/', 1)[1]}/{file_path}":
        raise SystemExit("[BLOCKED] Local model manifest file identity drifted.")
    source_prefix = expected["sourcePrefix"]
    if source_prefix and not file_path.startswith(source_prefix + "/"):
        raise SystemExit("[BLOCKED] Local model source file set drifted.")
    install_suffix = file_path[len(source_prefix) + 1:] if source_prefix else file_path
    if asset["relativeInstallPath"] != f"{expected['runtimeRoot']}/{install_suffix}":
        raise SystemExit("[BLOCKED] Local model runtime layout drifted.")
    assets_by_repository[repository].append(asset)

for repository, expected in expected_repositories.items():
    assets = assets_by_repository[repository]
    if len(assets) != expected["count"] or sum(asset["expectedBytes"] for asset in assets) != expected["bytes"]:
        raise SystemExit("[BLOCKED] Local model manifest repository count or byte total drifted.")
    file_set = "\n".join(sorted(asset["id"] for asset in assets)) + "\n"
    if hashlib.sha256(file_set.encode("utf-8")).hexdigest() != expected["fileSetDigest"]:
        raise SystemExit("[BLOCKED] Local model manifest exact file set drifted.")
all_file_set = "\n".join(sorted(asset["id"] for asset in manifest["assets"])) + "\n"
if hashlib.sha256(all_file_set.encode("utf-8")).hexdigest() != "8c849f220955acc574d72d09bbb8be2925634ae37b7e6b9582223dcc633935d9":
    raise SystemExit("[BLOCKED] Local model manifest exact file set drifted.")

expected_pin = {
    "identity": "fluidaudio",
    "kind": "remoteSourceControl",
    "location": "https://github.com/FluidInference/FluidAudio.git",
    "state": {
        "version": "0.15.5",
        "revision": "19600a485baa4998812e4654b70d2bab8f2c9949",
    },
}
resolved = json.loads(resolved_path.read_text(encoding="utf-8"))
pins = [pin for pin in resolved.get("pins", []) if pin.get("identity") == "fluidaudio"]
if len(pins) != 1 or any(pins[0].get(key) != value for key, value in expected_pin.items()):
    raise SystemExit("[BLOCKED] Package.resolved does not contain the approved FluidAudio source-control pin.")

package = package_path.read_text(encoding="utf-8")
dependency = '.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5")'
product = '.product(name: "FluidAudio", package: "FluidAudio")'
if package.count('.package(') != 1 or package.count(dependency) != 1:
    raise SystemExit("[BLOCKED] Package.swift does not contain exactly the approved FluidAudio dependency.")
core_start = package.find('.target(\n            name: "MeetingVaultCore",')
core_end = package.find('\n        .executableTarget(', core_start)
if core_start < 0 or core_end < 0 or package[core_start:core_end].count(product) != 1 or package.count(product) != 1:
    raise SystemExit("[BLOCKED] Package.swift must link FluidAudio only inside MeetingVaultCore.")
expected_notices = {
    "FluidAudio.txt": "78d8e46e5f7ca23346086abb1c00a058374938154ecec1edce628fadcdee731c",
    "LocalModels.txt": "4944eceabf3c85db30212803c9a6112e9a9ca22bce2e1537f2382342847e2d14",
    "fastcluster-LICENSE.md": "67594dbe4a7477719c8160373e7767c2c319ef966a6042f76846a18af02cde0a",
    "vbx-LICENSE.md": "08e57fdb5187c816e937916f1e176aadb400ca76f4b3b493d69730ec8f10dd80",
}
if {path.name for path in notices_path.iterdir() if path.is_file()} != set(expected_notices):
    raise SystemExit("[BLOCKED] Third-party notice file set drifted.")
for name, digest in expected_notices.items():
    path = notices_path / name
    if not path.is_file() or path.stat().st_size == 0:
        raise SystemExit("[BLOCKED] A required third-party notice is missing.")
    if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        raise SystemExit("[BLOCKED] A required third-party notice content drifted.")
PY

python3 "$ROOT_DIR/script/test_local_transcription_forbidden_calls.py"

printf '[OK] Local model supply-chain guard passed.\n'
