#!/usr/bin/env python3
"""Fail if production local transcription gains a download/device-owning call."""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
FILES = [
    ROOT / "Sources/MeetingVaultCore/Services/FluidAudioCoreMLBackend.swift",
    ROOT / "Sources/MeetingVaultCore/Services/FluidAudioLocalTranscriptionProvider.swift",
    ROOT / "Sources/MeetingVaultCore/Services/FluidAudioLocalFinalTranscriptionEngine.swift",
    ROOT / "Sources/MeetingVaultCore/Services/LocalFinalTranscriptionService.swift",
]
FORBIDDEN = {
    r"\bModelHub\s*\.": "ModelHub",
    r"\bAsrModels\s*\.\s*load\s*\(": "AsrModels.load",
    r"\bOfflineDiarizerModels\s*\.\s*load\s*\(": "OfflineDiarizerModels.load",
    r"\.\s*prepareModels\s*\(": "prepareModels",
    r"\bAVAudioEngine\s*\(": "provider AVAudioEngine",
    r"\b(download|downloadAnd|forceRedownload|prepareCache)\w*\s*\(": "download/cache preparation",
}


def executable_text(source: str) -> str:
    # Remove block/line comments and quoted literals before matching call syntax.
    source = re.sub(r"/\*.*?\*/", "", source, flags=re.S)
    source = re.sub(r"//[^\n]*", "", source)
    source = re.sub(r'"(?:\\.|[^"\\])*"', '""', source)
    return source


def main() -> int:
    failures: list[str] = []
    for path in FILES:
        text = executable_text(path.read_text(encoding="utf-8"))
        for pattern, label in FORBIDDEN.items():
            if re.search(pattern, text):
                failures.append(f"{path.relative_to(ROOT)}: forbidden executable call {label}")
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print(f"local transcription forbidden-call guard passed ({len(FILES)} production files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
