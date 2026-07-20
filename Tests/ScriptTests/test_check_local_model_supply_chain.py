import json
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class SupplyChainGuardMutationTests(unittest.TestCase):
    def test_guard_rejects_a_resolved_pin_with_the_wrong_source_control_kind(self):
        with self.fixture() as root:
            self.assert_success(root)
            document = json.loads((root / "Package.resolved").read_text())
            document["pins"][0]["kind"] = "registry"
            (root / "Package.resolved").write_text(json.dumps(document))

            completed = self.run_guard(root)

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("Package.resolved", completed.stderr)

    def test_guard_semantic_manifest_mutations_rebase_the_fixture_digest(self):
        cases = (
            (self.mutate_revision, "[BLOCKED] Local model manifest revision drifted."),
            (self.mutate_license, "[BLOCKED] Local model manifest provenance tuple drifted."),
            (self.mutate_license_url, "[BLOCKED] Local model manifest provenance tuple drifted."),
            (self.mutate_source_host, "[BLOCKED] Local model source URL host drifted."),
            (self.mutate_source_path, "[BLOCKED] Local model manifest file identity drifted."),
            (self.mutate_feature, "[BLOCKED] Local model manifest provenance tuple drifted."),
            (self.mutate_version, "[BLOCKED] Local model manifest provenance tuple drifted."),
            (self.mutate_path, "[BLOCKED] Local model runtime layout drifted."),
            (self.mutate_file_set, "[BLOCKED] Local model manifest exact file set drifted."),
            (self.mutate_count, "[BLOCKED] Local model manifest selection count or total bytes drifted."),
            (self.mutate_bytes, "[BLOCKED] Local model manifest selection count or total bytes drifted."),
        )
        for mutation, expected in cases:
            with self.subTest(mutation=mutation.__name__), self.fixture() as root:
                self.assert_success(root)
                mutation(root)
                self.rebase_fixture_manifest_digest(root)
                self.assert_failure(root, expected)

    def test_guard_rejects_manifest_digest_drift_without_rebasing_the_fixture(self):
        with self.fixture() as root:
            self.assert_success(root)
            self.mutate_digest(root)
            self.assert_failure(root, "[BLOCKED] Local model manifest digest drifted.")

    def test_guard_rejects_every_package_pin_and_target_scope_mutation(self):
        cases = (
            (self.mutate_package_version, "[BLOCKED] Package.swift does not contain exactly the approved FluidAudio dependency."),
            (self.mutate_product, "[BLOCKED] Package.swift must link FluidAudio only inside MeetingVaultCore."),
            (self.mutate_resolved, "[BLOCKED] Package.resolved does not contain the approved FluidAudio source-control pin."),
            (self.mutate_resolved_version, "[BLOCKED] Package.resolved does not contain the approved FluidAudio source-control pin."),
            (self.mutate_resolved_kind, "[BLOCKED] Package.resolved does not contain the approved FluidAudio source-control pin."),
            (self.mutate_resolved_location, "[BLOCKED] Package.resolved does not contain the approved FluidAudio source-control pin."),
            (self.mutate_resolved_identity, "[BLOCKED] Package.resolved does not contain the approved FluidAudio source-control pin."),
        )
        for mutation, expected in cases:
            with self.subTest(mutation=mutation.__name__), self.fixture() as root:
                self.assert_success(root)
                mutation(root)
                self.assert_failure(root, expected)

    def test_guard_rejects_exact_content_drift_for_every_notice(self):
        for name in ("FluidAudio.txt", "LocalModels.txt", "fastcluster-LICENSE.md", "vbx-LICENSE.md"):
            with self.subTest(notice=name), self.fixture() as root:
                self.assert_success(root)
                (root / "Sources/MeetingVaultCore/Resources/ThirdPartyNotices" / name).write_text("changed")
                self.assert_failure(root, "[BLOCKED] A required third-party notice content drifted.")

    class fixture:
        def __init__(self): self.temporary = None
        def __enter__(self):
            self.temporary = tempfile.TemporaryDirectory(prefix="meetingvault-guard-")
            root = Path(self.temporary.name)
            (root / "script").mkdir()
            resources = root / "Sources/MeetingVaultCore/Resources"
            resources.parent.mkdir(parents=True)
            shutil.copy2(ROOT / "script/check_local_model_supply_chain.sh", root / "script/check_local_model_supply_chain.sh")
            shutil.copy2(
                ROOT / "script/test_local_transcription_forbidden_calls.py",
                root / "script/test_local_transcription_forbidden_calls.py",
            )
            services = root / "Sources/MeetingVaultCore/Services"
            services.mkdir(parents=True)
            for name in (
                "FluidAudioCoreMLBackend.swift",
                "FluidAudioLocalTranscriptionProvider.swift",
                "FluidAudioLocalFinalTranscriptionEngine.swift",
                "LocalFinalTranscriptionService.swift",
            ):
                shutil.copy2(ROOT / "Sources/MeetingVaultCore/Services" / name, services / name)
            shutil.copytree(ROOT / "Sources/MeetingVaultCore/Resources", resources)
            shutil.copy2(ROOT / "Package.resolved", root / "Package.resolved")
            shutil.copy2(ROOT / "Package.swift", root / "Package.swift")
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            return root
        def __exit__(self, *_): self.temporary.cleanup()

    def run_guard(self, root):
        return subprocess.run(["bash", "script/check_local_model_supply_chain.sh"], cwd=root, text=True, capture_output=True)

    def assert_success(self, root):
        completed = self.run_guard(root)
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)

    def assert_failure(self, root, expected):
        completed = self.run_guard(root)
        self.assertNotEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertEqual(completed.stderr.strip(), expected)

    def manifest(self, root): return root / "Sources/MeetingVaultCore/Resources/LocalModels.json"
    def save(self, root, document): self.manifest(root).write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
    def rebase_fixture_manifest_digest(self, root):
        digest = hashlib.sha256(self.manifest(root).read_bytes()).hexdigest()
        guard = root / "script/check_local_model_supply_chain.sh"
        text = guard.read_text()
        original = "e8fe1789f860edf1255226607a53de00569a494a3c770ae8ba67b7925c679c88"
        self.assertEqual(text.count(original), 1)
        guard.write_text(text.replace(original, digest))
    def mutate_revision(self, root):
        document = json.loads(self.manifest(root).read_text()); document["assets"][0]["sourceRevision"] = "a" * 40; self.save(root, document)
    def mutate_license(self, root):
        document = json.loads(self.manifest(root).read_text()); document["assets"][0]["licenseName"] = "Apache-2.0"; self.save(root, document)
    def mutate_license_url(self, root):
        document = json.loads(self.manifest(root).read_text()); document["assets"][0]["licenseURL"] = "https://example.com/license"; self.save(root, document)
    def mutate_source_host(self, root):
        document = json.loads(self.manifest(root).read_text()); document["assets"][0]["sourceURL"] = document["assets"][0]["sourceURL"].replace("huggingface.co", "example.com"); self.save(root, document)
    def mutate_source_path(self, root):
        document = json.loads(self.manifest(root).read_text()); document["assets"][0]["sourceURL"] += ".changed"; self.save(root, document)
    def mutate_feature(self, root):
        document = json.loads(self.manifest(root).read_text()); document["assets"][0]["feature"] = "other"; self.save(root, document)
    def mutate_version(self, root):
        document = json.loads(self.manifest(root).read_text()); document["assets"][0]["version"] = "other"; self.save(root, document)
    def mutate_path(self, root):
        document = json.loads(self.manifest(root).read_text()); document["assets"][0]["relativeInstallPath"] = "other/file"; self.save(root, document)
    def mutate_file_set(self, root):
        document = json.loads(self.manifest(root).read_text())
        asset = document["assets"][0]
        asset["id"] = asset["id"].replace("coremldata.bin", "changed.bin")
        asset["sourceURL"] = asset["sourceURL"].replace("coremldata.bin", "changed.bin")
        asset["relativeInstallPath"] = asset["relativeInstallPath"].replace("coremldata.bin", "changed.bin")
        self.save(root, document)
    def mutate_count(self, root):
        document = json.loads(self.manifest(root).read_text()); document["assets"].pop(); self.save(root, document)
    def mutate_bytes(self, root):
        document = json.loads(self.manifest(root).read_text()); document["assets"][0]["expectedBytes"] += 1; self.save(root, document)
    def mutate_digest(self, root):
        document = json.loads(self.manifest(root).read_text()); document["assets"][0]["sha256"] = "b" * 64; self.save(root, document)
    def mutate_package_version(self, root):
        (root / "Package.swift").write_text((root / "Package.swift").read_text().replace('exact: "0.15.5"', 'from: "0.15.5"'))
    def mutate_product(self, root):
        package = root / "Package.swift"
        text = package.read_text().replace('.product(name: "FluidAudio", package: "FluidAudio")', '')
        text = text.replace('dependencies: ["MeetingVaultCore", "MeetingVaultCaptureProviderSmoke"]', 'dependencies: ["MeetingVaultCore", "MeetingVaultCaptureProviderSmoke", .product(name: "FluidAudio", package: "FluidAudio")]')
        package.write_text(text)
    def mutate_resolved(self, root):
        document = json.loads((root / "Package.resolved").read_text()); document["pins"][0]["state"]["revision"] = "a" * 40; (root / "Package.resolved").write_text(json.dumps(document))
    def mutate_resolved_kind(self, root):
        document = json.loads((root / "Package.resolved").read_text()); document["pins"][0]["kind"] = "registry"; (root / "Package.resolved").write_text(json.dumps(document))
    def mutate_resolved_version(self, root):
        document = json.loads((root / "Package.resolved").read_text()); document["pins"][0]["state"]["version"] = "0.15.6"; (root / "Package.resolved").write_text(json.dumps(document))
    def mutate_resolved_location(self, root):
        document = json.loads((root / "Package.resolved").read_text()); document["pins"][0]["location"] = "https://example.com/FluidAudio.git"; (root / "Package.resolved").write_text(json.dumps(document))
    def mutate_resolved_identity(self, root):
        document = json.loads((root / "Package.resolved").read_text()); document["pins"][0]["identity"] = "other"; (root / "Package.resolved").write_text(json.dumps(document))


if __name__ == "__main__":
    unittest.main()
