from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SERVICE_NAMES = (
    "FluidAudioCoreMLBackend.swift",
    "FluidAudioLocalTranscriptionProvider.swift",
    "FluidAudioLocalFinalTranscriptionEngine.swift",
    "LocalFinalTranscriptionService.swift",
)


class LocalTranscriptionForbiddenCallGuardTests(unittest.TestCase):
    def test_guard_accepts_current_production_sources(self):
        completed = subprocess.run(
            ["python3", "script/test_local_transcription_forbidden_calls.py"],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)

    def test_guard_rejects_each_forbidden_executable_call(self):
        calls = (
            "ModelHub.download()",
            "AsrModels.load()",
            "OfflineDiarizerModels.load()",
            "provider.prepareModels()",
            "AVAudioEngine()",
            "provider.forceRedownload()",
        )
        for call in calls:
            with self.subTest(call=call), self.fixture() as root:
                target = root / "Sources/MeetingVaultCore/Services/LocalFinalTranscriptionService.swift"
                target.write_text(f"func forbidden() {{ _ = {call} }}\n")
                completed = self.run_guard(root)
                self.assertNotEqual(completed.returncode, 0, completed.stdout + completed.stderr)
                self.assertIn("forbidden executable call", completed.stderr)

    def test_guard_ignores_comments_and_quoted_diagnostics(self):
        with self.fixture() as root:
            target = root / "Sources/MeetingVaultCore/Services/LocalFinalTranscriptionService.swift"
            target.write_text(
                '// ModelHub.download()\n'
                'let message = "AVAudioEngine() and prepareModels() are forbidden"\n'
            )
            completed = self.run_guard(root)
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)

    class fixture:
        def __init__(self):
            self.temporary = None

        def __enter__(self):
            self.temporary = tempfile.TemporaryDirectory(prefix="meetingvault-forbidden-calls-")
            root = Path(self.temporary.name)
            script = root / "script"
            script.mkdir(parents=True)
            shutil.copy2(
                ROOT / "script/test_local_transcription_forbidden_calls.py",
                script / "test_local_transcription_forbidden_calls.py",
            )
            services = root / "Sources/MeetingVaultCore/Services"
            services.mkdir(parents=True)
            for name in SERVICE_NAMES:
                shutil.copy2(ROOT / "Sources/MeetingVaultCore/Services" / name, services / name)
            return root

        def __exit__(self, *_):
            self.temporary.cleanup()

    def run_guard(self, root):
        return subprocess.run(
            ["python3", "script/test_local_transcription_forbidden_calls.py"],
            cwd=root,
            text=True,
            capture_output=True,
        )


if __name__ == "__main__":
    unittest.main()
