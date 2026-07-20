#!/usr/bin/env python3
"""Generate the pinned MeetingVault local-model manifest without retaining model bytes.

Large Hugging Face files use Git LFS OIDs. An LFS OID is the SHA-256 of the
actual file contents, not the pointer file; the exact-revision tree API also
reports the corresponding content size. Small non-LFS files are streamed into
an anonymous temporary file outside the repository, hashed, and removed.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import tempfile
import time
from dataclasses import dataclass
from typing import Any, Callable, Iterable
import urllib.error
import urllib.parse
import urllib.request


ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "Sources/MeetingVaultCore/Resources/LocalModels.json"
API_HOST = "huggingface.co"
ALLOWED_REDIRECT_HOSTS = frozenset(
    {
        API_HOST,
        "cdn-lfs.hf.co",
        "cdn-lfs-us-1.hf.co",
        "cas-bridge.xethub.hf.co",
    }
)
REQUEST_TIMEOUT_SECONDS = 30
READ_CHUNK_BYTES = 64 * 1024
MAX_METADATA_BYTES = 16 * 1024 * 1024
MAX_NON_LFS_FILE_BYTES = 128 * 1024 * 1024
MAX_TREE_ENTRIES = 4_096
MAX_PAGES = 128
MAX_TOTAL_PROCESSED_ENTRIES = 8_192
MAX_TOTAL_METADATA_BYTES = 16 * 1024 * 1024
MAX_UNIQUE_PAGINATION_URLS = 512
GENERATION_DEADLINE_SECONDS = 120
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
REVISION_RE = re.compile(r"^[0-9a-f]{40}$")
LFS_POINTER_PREFIX = b"version https://git-lfs.github.com/spec/v1\n"
LFS_POINTER_PREFIX_CRLF = b"version https://git-lfs.github.com/spec/v1\r\n"


REPOSITORIES: tuple[dict[str, Any], ...] = (
    {
        "repository": "FluidInference/parakeet-tdt-0.6b-v3-coreml",
        "revision": "aed02740059203c4a87495924f685de3722ae9ce",
        "feature": "automatic-speech-recognition",
        "version": "parakeet-tdt-0.6b-v3-coreml",
        "license_slug": "cc-by-4.0",
        "license_name": "CC-BY-4.0",
        "license_url": "https://creativecommons.org/licenses/by/4.0/legalcode.txt",
        "install_root": "parakeet-tdt-0.6b-v3",
        "directories": (
            "Decoder.mlmodelc",
            "Encoder.mlmodelc",
            "JointDecisionv3.mlmodelc",
            "Preprocessor.mlmodelc",
        ),
        "files": (
            "parakeet_vocab.json",
        ),
    },
    {
        "repository": "FluidInference/ls-eend-coreml",
        "revision": "28ce1b1f8ef186729df63b3886fbaae7bc10c4a1",
        "feature": "streaming-speaker-diarization",
        "version": "ls-eend-coreml-dihard3-100ms",
        "license_slug": "mit",
        "license_name": "MIT",
        "license_url": "https://opensource.org/license/mit",
        "install_root": "ls-eend/dih3",
        "directories": (
            "optimized/dih3/100ms/ls_eend_dih3_100ms.mlmodelc",
        ),
        "files": (),
    },
    {
        "repository": "FluidInference/speaker-diarization-coreml",
        "revision": "1ed7a662fdc7109e36d822db793ee6eebdaf8594",
        "feature": "offline-speaker-diarization",
        "version": "speaker-diarization-coreml",
        "license_slug": "cc-by-4.0",
        "license_name": "CC-BY-4.0",
        "license_url": "https://creativecommons.org/licenses/by/4.0/legalcode.txt",
        "install_root": "speaker-diarization",
        "directories": (
            "Embedding.mlmodelc",
            "FBank.mlmodelc",
            "PldaRho.mlmodelc",
            "Segmentation.mlmodelc",
        ),
        "files": (
            "plda-parameters.json",
        ),
    },
)


class ManifestGenerationError(RuntimeError):
    pass


@dataclass(frozen=True)
class GenerationLimits:
    max_pages: int = MAX_PAGES
    max_processed_entries: int = MAX_TOTAL_PROCESSED_ENTRIES
    max_total_metadata_bytes: int = MAX_TOTAL_METADATA_BYTES
    max_unique_pagination_urls: int = MAX_UNIQUE_PAGINATION_URLS
    deadline_seconds: float = GENERATION_DEADLINE_SECONDS


class GenerationBudget:
    """One monotonic, run-wide budget shared by every metadata request."""

    def __init__(
        self,
        *,
        limits: GenerationLimits = GenerationLimits(),
        clock: Callable[[], float] = time.monotonic,
        transport: Callable[..., Any] | None = None,
    ) -> None:
        self.limits = limits
        self.clock = clock
        self.transport = transport
        self.started_at = clock()
        self.pages = 0
        self.processed_entries = 0
        self.metadata_bytes = 0
        self.urls: set[str] = set()

    def check_deadline(self) -> None:
        if self.clock() - self.started_at >= self.limits.deadline_seconds:
            raise ManifestGenerationError("generation deadline exceeded")

    def remaining_timeout(self) -> float:
        """Return the only timeout a new open/read may use for this run."""
        remaining = self.limits.deadline_seconds - (self.clock() - self.started_at)
        if remaining <= 0:
            raise ManifestGenerationError("generation deadline exceeded")
        return min(float(REQUEST_TIMEOUT_SECONDS), remaining)

    def open(self, url: str, *, allow_content_hosts: bool) -> Any:
        timeout = self.remaining_timeout()
        try:
            if self.transport is not None:
                response = self.transport(
                    url, allow_content_hosts=allow_content_hosts, timeout=timeout
                )
            else:
                response = open_request(
                    url, allow_content_hosts=allow_content_hosts, timeout=timeout
                )
        except ManifestGenerationError:
            raise
        except (OSError, TimeoutError, urllib.error.URLError) as error:
            raise ManifestGenerationError("upstream request failed") from error
        try:
            self.check_deadline()
        except ManifestGenerationError:
            close = getattr(response, "close", None)
            if callable(close):
                close()
            raise
        return response

    def read(self, response: Any, size: int) -> bytes:
        """Bound one blocking read by the remaining monotonic budget."""
        timeout = self.remaining_timeout()
        set_response_timeout(response, timeout)
        try:
            chunk = response.read(size)
        except (OSError, TimeoutError, urllib.error.URLError) as error:
            raise ManifestGenerationError("upstream response read failed") from error
        self.check_deadline()
        if not isinstance(chunk, bytes):
            raise ManifestGenerationError("upstream response has an invalid body")
        return chunk

    def note_metadata(self, url: str, byte_count: int) -> None:
        self.check_deadline()
        self.urls.add(url)
        if len(self.urls) > self.limits.max_unique_pagination_urls:
            raise ManifestGenerationError("upstream metadata uses too many unique URLs")
        self.metadata_bytes += byte_count
        if self.metadata_bytes > self.limits.max_total_metadata_bytes:
            raise ManifestGenerationError("upstream metadata exceeds the total size limit")

    def note_page(self, entry_count: int) -> None:
        self.check_deadline()
        self.pages += 1
        self.processed_entries += entry_count
        if self.pages > self.limits.max_pages:
            raise ManifestGenerationError("upstream pagination exceeds the page limit")
        if self.processed_entries > self.limits.max_processed_entries:
            raise ManifestGenerationError("upstream tree processing exceeds the entry limit")


class AllowlistedRedirectHandler(urllib.request.HTTPRedirectHandler):
    def __init__(self, allow_content_hosts: bool) -> None:
        super().__init__()
        self.allow_content_hosts = allow_content_hosts

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # type: ignore[no-untyped-def]
        validate_network_url(newurl, allow_content_hosts=self.allow_content_hosts)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def validate_network_url(url: str, *, allow_content_hosts: bool) -> None:
    parsed = urllib.parse.urlparse(url)
    allowed = ALLOWED_REDIRECT_HOSTS if allow_content_hosts else {API_HOST}
    try:
        port = parsed.port
    except ValueError as error:
        raise ManifestGenerationError("network destination is not allowlisted") from error
    if parsed.scheme != "https" or parsed.hostname not in allowed or port not in (None, 443):
        raise ManifestGenerationError("network destination is not allowlisted")
    if parsed.username is not None or parsed.password is not None or parsed.fragment:
        raise ManifestGenerationError("network destination contains forbidden URL components")


def open_request(url: str, *, allow_content_hosts: bool, timeout: float) -> Any:
    validate_network_url(url, allow_content_hosts=allow_content_hosts)
    request = urllib.request.Request(
        url,
        headers={"Accept": "application/json", "User-Agent": "MeetingVault-manifest-generator/1"},
        method="GET",
    )
    try:
        opener = urllib.request.build_opener(AllowlistedRedirectHandler(allow_content_hosts))
        response = opener.open(request, timeout=timeout)
    except (urllib.error.URLError, TimeoutError) as error:
        raise ManifestGenerationError("upstream request failed") from error
    validate_network_url(response.geturl(), allow_content_hosts=allow_content_hosts)
    if getattr(response, "status", 200) != 200:
        response.close()
        raise ManifestGenerationError("upstream returned an unexpected status")
    return response


def set_response_timeout(response: Any, timeout: float) -> None:
    """Refresh every accessible response/socket timeout without trusting a fixture shape."""
    candidates = [response]
    seen: set[int] = set()
    while candidates:
        candidate = candidates.pop()
        if id(candidate) in seen:
            continue
        seen.add(id(candidate))
        setter = getattr(candidate, "settimeout", None)
        if callable(setter):
            try:
                setter(timeout)
            except OSError:
                pass
        for name in ("fp", "raw", "_fp", "sock", "socket", "_sock"):
            nested = getattr(candidate, name, None)
            if nested is not None:
                candidates.append(nested)


def read_bounded_response(response: Any, *, maximum_bytes: int, budget: GenerationBudget, kind: str) -> bytes:
    data = bytearray()
    while True:
        remaining = maximum_bytes + 1 - len(data)
        if remaining <= 0:
            raise ManifestGenerationError(f"{kind} exceeds the size limit")
        chunk = budget.read(response, min(READ_CHUNK_BYTES, remaining))
        if not chunk:
            return bytes(data)
        data.extend(chunk)
        if len(data) > maximum_bytes:
            raise ManifestGenerationError(f"{kind} exceeds the size limit")


def read_bounded_json(url: str, *, budget: GenerationBudget) -> tuple[Any, Any]:
    with budget.open(url, allow_content_hosts=False) as response:
        declared = response.headers.get("Content-Length")
        try:
            declared_size = int(declared) if declared is not None else None
        except (TypeError, ValueError) as error:
            raise ManifestGenerationError("upstream metadata has an invalid size") from error
        if declared_size is not None and (declared_size < 0 or declared_size > MAX_METADATA_BYTES):
            raise ManifestGenerationError("upstream metadata exceeds the size limit")
        data = read_bounded_response(
            response,
            maximum_bytes=MAX_METADATA_BYTES,
            budget=budget,
            kind="upstream metadata",
        )
        budget.note_metadata(url, len(data))
        try:
            return json.loads(data), response.headers
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ManifestGenerationError("upstream metadata is not valid JSON") from error


def validate_repository_record(config: dict[str, Any], *, budget: GenerationBudget) -> None:
    repository = config["repository"]
    revision = config["revision"]
    if not REVISION_RE.fullmatch(revision):
        raise ManifestGenerationError("configured revision is not an exact Git commit")
    quoted_repo = urllib.parse.quote(repository, safe="/")
    record, _ = read_bounded_json(
        f"https://{API_HOST}/api/models/{quoted_repo}/revision/{revision}", budget=budget
    )
    if not isinstance(record, dict):
        raise ManifestGenerationError("repository metadata has an invalid shape")
    if record.get("id") != repository or record.get("sha") != revision:
        raise ManifestGenerationError("repository metadata does not match the allowlist")
    if record.get("private") is not False or record.get("gated") not in (False, None):
        raise ManifestGenerationError("repository is private or gated")
    card_data = record.get("cardData")
    if not isinstance(card_data, dict):
        raise ManifestGenerationError("repository license metadata is missing")
    license_value = card_data.get("license")
    if not isinstance(license_value, str) or license_value != config["license_slug"]:
        raise ManifestGenerationError("repository license is missing, ambiguous, or incompatible")


def normalized_url_path(path: str) -> str:
    decoded = urllib.parse.unquote(path)
    if not decoded.startswith("/") or "\\" in decoded:
        raise ManifestGenerationError("upstream pagination path is unsafe")
    parts = decoded.split("/")
    if not parts or parts[0] != "" or any(part in ("", ".", "..") for part in parts[1:]):
        raise ManifestGenerationError("upstream pagination path is unsafe")
    if any(ord(character) < 32 or ord(character) == 127 for character in decoded):
        raise ManifestGenerationError("upstream pagination path is unsafe")
    return "/" + "/".join(parts[1:])


def expected_tree_path(config: dict[str, Any], selection_path: str = "") -> str:
    validate_relative_path(config["repository"])
    validate_relative_path(config["revision"])
    if selection_path:
        validate_relative_path(selection_path)
    suffix = f"/{selection_path}" if selection_path else ""
    return normalized_url_path(f"/api/models/{config['repository']}/tree/{config['revision']}{suffix}")


def next_page_url(headers: Any, config: dict[str, Any], *, expected_path: str | None = None) -> str | None:
    link = headers.get("Link")
    if not link:
        return None
    for part in link.split(","):
        if 'rel="next"' not in part:
            continue
        match = re.search(r"<([^>]+)>", part)
        if match is None:
            raise ManifestGenerationError("upstream pagination link is malformed")
        url = match.group(1)
        validate_network_url(url, allow_content_hosts=False)
        actual_path = normalized_url_path(urllib.parse.urlparse(url).path)
        if actual_path != (expected_path or expected_tree_path(config)):
            raise ManifestGenerationError("upstream pagination escaped the pinned repository")
        return url
    return None


def list_selected_files(config: dict[str, Any], *, budget: GenerationBudget) -> list[dict[str, Any]]:
    repository = urllib.parse.quote(config["repository"], safe="/")
    revision = config["revision"]
    selected: dict[str, dict[str, Any]] = {}
    selections = [
        *((path, True) for path in config["directories"]),
        *((path, False) for path in config["files"]),
    ]
    for configured_path, is_directory in selections:
        validate_relative_path(configured_path)
        parent = str(PurePosixPath(configured_path).parent)
        query_path = configured_path if is_directory else ("" if parent == "." else parent)
        path = urllib.parse.quote(query_path, safe="/")
        path_suffix = f"/{path}" if path else ""
        expected_path = expected_tree_path(config, query_path)
        url: str | None = (
            f"https://{API_HOST}/api/models/{repository}/tree/{revision}{path_suffix}"
            "?recursive=true&expand=true"
        )
        visited: set[str] = set()
        found = False
        while url is not None:
            if url in visited:
                raise ManifestGenerationError("upstream pagination repeated a page")
            visited.add(url)
            page, headers = read_bounded_json(url, budget=budget)
            if not isinstance(page, list):
                raise ManifestGenerationError("repository tree metadata has an invalid shape")
            budget.note_page(len(page))
            for entry in page:
                if not isinstance(entry, dict) or entry.get("type") != "file":
                    continue
                file_path = entry.get("path")
                if not isinstance(file_path, str):
                    raise ManifestGenerationError("repository tree entry is missing a path")
                validate_relative_path(file_path)
                matches = (
                    file_path.startswith(configured_path + "/")
                    if is_directory
                    else file_path == configured_path
                )
                if matches:
                    if file_path in selected:
                        raise ManifestGenerationError("repository tree contains a duplicate file")
                    selected[file_path] = entry
                    found = True
                    if len(selected) > MAX_TREE_ENTRIES:
                        raise ManifestGenerationError("repository tree exceeds the entry limit")
            url = next_page_url(headers, config, expected_path=expected_path)
        if not found:
            raise ManifestGenerationError("a required model path is absent at the pinned revision")
    return [selected[path] for path in sorted(selected)]


def validate_relative_path(path: str) -> None:
    if not path or path.startswith("/") or path.endswith("/") or "\\" in path:
        raise ManifestGenerationError("upstream path is unsafe")
    if any(ord(character) < 32 or ord(character) == 127 for character in path):
        raise ManifestGenerationError("upstream path is unsafe")
    parts = PurePosixPath(path).parts
    if any(part in ("", ".", "..") for part in parts) or "//" in path:
        raise ManifestGenerationError("upstream path is unsafe")


def digest_from_lfs(entry: dict[str, Any]) -> tuple[int, str] | None:
    lfs = entry.get("lfs")
    if lfs is None:
        return None
    if not isinstance(lfs, dict):
        raise ManifestGenerationError("Git LFS metadata has an invalid shape")
    oid = lfs.get("oid")
    size = lfs.get("size")
    entry_size = entry.get("size")
    if not isinstance(oid, str) or not SHA256_RE.fullmatch(oid):
        raise ManifestGenerationError("Git LFS metadata lacks a SHA-256 content OID")
    if not isinstance(size, int) or size <= 0 or size != entry_size:
        raise ManifestGenerationError("Git LFS metadata has an invalid content size")
    return size, oid


def stream_and_hash(repository: str, revision: str, file_path: str, *, budget: GenerationBudget) -> tuple[int, str]:
    quoted_path = urllib.parse.quote(file_path, safe="/")
    source_url = f"https://{API_HOST}/{repository}/resolve/{revision}/{quoted_path}?download=true"
    with budget.open(source_url, allow_content_hosts=True) as response:
        declared = response.headers.get("Content-Length")
        try:
            declared_size = int(declared) if declared is not None else None
        except (TypeError, ValueError) as error:
            raise ManifestGenerationError("non-LFS model metadata has an invalid size") from error
        if declared_size is not None and (declared_size < 0 or declared_size > MAX_NON_LFS_FILE_BYTES):
            raise ManifestGenerationError("non-LFS model metadata exceeds the size limit")
        hasher = hashlib.sha256()
        total = 0
        prefix = bytearray()
        with tempfile.TemporaryFile(prefix="MeetingVault-model-metadata-") as temporary:
            while True:
                chunk = budget.read(response, READ_CHUNK_BYTES)
                if not chunk:
                    break
                total += len(chunk)
                if total > MAX_NON_LFS_FILE_BYTES:
                    raise ManifestGenerationError("non-LFS model metadata exceeds the size limit")
                required_prefix_bytes = len(LFS_POINTER_PREFIX_CRLF)
                if len(prefix) < required_prefix_bytes:
                    prefix.extend(chunk[: required_prefix_bytes - len(prefix)])
                hasher.update(chunk)
                temporary.write(chunk)
        if bytes(prefix).startswith((LFS_POINTER_PREFIX, LFS_POINTER_PREFIX_CRLF)):
            raise ManifestGenerationError("download returned Git LFS pointer bytes")
        if total <= 0:
            raise ManifestGenerationError("download returned an empty file")
        return total, hasher.hexdigest()


def make_assets(
    config: dict[str, Any], entries: Iterable[dict[str, Any]], *, budget: GenerationBudget
) -> list[dict[str, Any]]:
    repository = config["repository"]
    revision = config["revision"]
    slug = repository.split("/", 1)[1]
    install_root = config["install_root"]
    assets: list[dict[str, Any]] = []
    for entry in entries:
        file_path = entry["path"]
        verified = digest_from_lfs(entry)
        if verified is None:
            verified = stream_and_hash(repository, revision, file_path, budget=budget)
            if entry.get("size") != verified[0]:
                raise ManifestGenerationError("download size disagrees with repository metadata")
        expected_bytes, sha256 = verified
        quoted_path = urllib.parse.quote(file_path, safe="/")
        assets.append(
            {
                "expectedBytes": expected_bytes,
                "feature": config["feature"],
                "id": f"{slug}/{file_path}",
                "licenseName": config["license_name"],
                "licenseURL": config["license_url"],
                "relativeInstallPath": f"{install_root}/{file_path}",
                "sha256": sha256,
                "sourceRevision": revision,
                "sourceURL": f"https://{API_HOST}/{repository}/resolve/{revision}/{quoted_path}",
                "version": config["version"],
            }
        )
    return assets


def atomic_write_manifest(manifest: dict[str, Any]) -> None:
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    payload = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")
    temporary_path: str | None = None
    try:
        descriptor, temporary_path = tempfile.mkstemp(prefix=".LocalModels.", dir=OUTPUT.parent)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, OUTPUT)
        temporary_path = None
    finally:
        if temporary_path is not None:
            try:
                os.unlink(temporary_path)
            except FileNotFoundError:
                pass


def main() -> int:
    all_assets: list[dict[str, Any]] = []
    budget = GenerationBudget()
    for config in REPOSITORIES:
        validate_repository_record(config, budget=budget)
        all_assets.extend(make_assets(config, list_selected_files(config, budget=budget), budget=budget))
    all_assets.sort(key=lambda asset: (asset["id"], asset["relativeInstallPath"], asset["sourceURL"]))
    atomic_write_manifest({"assets": all_assets, "schemaVersion": 1})
    total_bytes = sum(asset["expectedBytes"] for asset in all_assets)
    print(f"[OK] wrote {len(all_assets)} pinned files ({total_bytes} bytes) to {OUTPUT}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ManifestGenerationError as error:
        print(f"[BLOCKED] {error}", file=os.sys.stderr)
        raise SystemExit(1)
