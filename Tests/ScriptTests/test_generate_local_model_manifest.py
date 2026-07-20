import importlib.util
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
import urllib.request


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("generator", ROOT / "script/generate_local_model_manifest.py")
generator = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
sys.modules[SPEC.name] = generator
SPEC.loader.exec_module(generator)


class FixtureResponse:
    def __init__(self, url, payload, headers=None, *, clock=None, advance_per_read=0.0, maximum_chunk=None):
        self.url = url
        self.payload = payload
        self.headers = headers or {}
        self.status = 200
        self.offset = 0
        self.timeouts = []
        self.clock = clock
        self.advance_per_read = advance_per_read
        self.maximum_chunk = maximum_chunk
        self.closed = False

    def __enter__(self): return self
    def __exit__(self, *_): self.close(); return False
    def geturl(self): return self.url
    def read(self, size=-1):
        if size < 0:
            size = len(self.payload) - self.offset
        if self.maximum_chunk is not None:
            size = min(size, self.maximum_chunk)
        chunk = self.payload[self.offset:self.offset + size]
        self.offset += len(chunk)
        if self.clock is not None:
            self.clock.now += self.advance_per_read
        return chunk
    def settimeout(self, timeout): self.timeouts.append(timeout)
    def close(self): self.closed = True


class FixtureClock:
    def __init__(self, now=0.0): self.now = now
    def __call__(self): return self.now


class GeneratorBoundsTests(unittest.TestCase):
    def test_open_uses_the_remaining_global_deadline_as_its_transport_timeout(self):
        time_values = iter([0.0, 0.25, 0.25]).__next__
        observed = []
        budget = generator.GenerationBudget(
            limits=generator.GenerationLimits(deadline_seconds=1),
            clock=time_values,
            transport=lambda url, **arguments: observed.append(arguments["timeout"]) or FixtureResponse(url, b"[]"),
        )

        with budget.open("https://huggingface.co/api/models/x", allow_content_hosts=False):
            pass

        self.assertEqual(observed, [0.75])

    def test_trickle_reads_share_one_monotonic_deadline_and_refresh_socket_timeout(self):
        clock = FixtureClock()
        response = FixtureResponse(
            "https://huggingface.co/api/models/x", b"[]", clock=clock,
            advance_per_read=0.6, maximum_chunk=1,
        )
        budget = generator.GenerationBudget(
            limits=generator.GenerationLimits(deadline_seconds=1),
            clock=clock,
            transport=lambda *_args, **_kwargs: response,
        )

        with self.assertRaisesRegex(generator.ManifestGenerationError, "^generation deadline exceeded$"):
            generator.read_bounded_json(response.url, budget=budget)

        self.assertEqual(response.timeouts, [1.0, 0.4])
        self.assertEqual(response.offset, 2)
        self.assertTrue(response.closed)

    def test_metadata_is_read_in_bounded_chunks_and_reaches_eof(self):
        response = FixtureResponse(
            "https://huggingface.co/api/models/x", b'{"id":"fixture"}', maximum_chunk=2,
        )
        document, _ = generator.read_bounded_json(
            response.url,
            budget=generator.GenerationBudget(transport=lambda *_args, **_kwargs: response),
        )

        self.assertEqual(document, {"id": "fixture"})
        self.assertEqual(response.offset, len(response.payload))
        self.assertTrue(response.closed)

    def test_page_cap_counts_a_single_page(self):
        config = dict(generator.REPOSITORIES[0])
        config.update(directories=("required",), files=())
        with self.assertRaisesRegex(generator.ManifestGenerationError, "^upstream pagination exceeds the page limit$"):
            generator.list_selected_files(
                config,
                budget=generator.GenerationBudget(
                    limits=generator.GenerationLimits(max_pages=0),
                    transport=lambda url, **_: FixtureResponse(url, b"[]"),
                ),
            )

    def test_entry_cap_counts_unselected_tree_entries(self):
        config = dict(generator.REPOSITORIES[0])
        config.update(directories=("required",), files=())
        payload = b'[{"type":"file","path":"unselected.bin","size":1}]'
        with self.assertRaisesRegex(generator.ManifestGenerationError, "^upstream tree processing exceeds the entry limit$"):
            generator.list_selected_files(
                config,
                budget=generator.GenerationBudget(
                    limits=generator.GenerationLimits(max_processed_entries=0),
                    transport=lambda url, **_: FixtureResponse(url, payload),
                ),
            )

    def test_metadata_byte_budget_has_an_exact_error(self):
        with self.assertRaisesRegex(generator.ManifestGenerationError, "^upstream metadata exceeds the total size limit$"):
            generator.read_bounded_json(
                "https://huggingface.co/api/models/x",
                budget=generator.GenerationBudget(
                    limits=generator.GenerationLimits(max_total_metadata_bytes=1),
                    transport=lambda url, **_: FixtureResponse(url, b"[]"),
                ),
            )

    def test_oversized_metadata_response_has_an_exact_error(self):
        response = FixtureResponse(
            "https://huggingface.co/api/models/x", b"[]",
            {"Content-Length": str(generator.MAX_METADATA_BYTES + 1)},
        )
        with self.assertRaisesRegex(generator.ManifestGenerationError, "^upstream metadata exceeds the size limit$"):
            generator.read_bounded_json(
                response.url,
                budget=generator.GenerationBudget(transport=lambda *_args, **_kwargs: response),
            )

    def test_oversized_non_lfs_response_has_an_exact_error(self):
        config = generator.REPOSITORIES[0]
        response = FixtureResponse(
            "https://huggingface.co/content", b"x",
            {"Content-Length": str(generator.MAX_NON_LFS_FILE_BYTES + 1)},
        )
        with self.assertRaisesRegex(generator.ManifestGenerationError, "^non-LFS model metadata exceeds the size limit$"):
            generator.stream_and_hash(
                config["repository"], config["revision"], "config.json",
                budget=generator.GenerationBudget(transport=lambda *_args, **_kwargs: response),
            )

    def test_non_lfs_file_that_exceeds_the_stream_limit_has_an_exact_error(self):
        config = generator.REPOSITORIES[0]
        original_limit = generator.MAX_NON_LFS_FILE_BYTES
        generator.MAX_NON_LFS_FILE_BYTES = 1
        try:
            with self.assertRaisesRegex(generator.ManifestGenerationError, "^non-LFS model metadata exceeds the size limit$"):
                generator.stream_and_hash(
                    config["repository"], config["revision"], "config.json",
                    budget=generator.GenerationBudget(
                        transport=lambda url, **_: FixtureResponse(url, b"ab")
                    ),
                )
        finally:
            generator.MAX_NON_LFS_FILE_BYTES = original_limit

    def test_unique_pagination_urls_have_a_global_cap(self):
        config = dict(generator.REPOSITORIES[0])
        config.update(directories=("required",), files=())
        root = generator.expected_tree_path(config, "required")
        first = f"https://huggingface.co{root}?recursive=true&expand=true"
        second = f"https://huggingface.co{root}?recursive=true&expand=true&cursor=next"
        payload = b'[{"type":"file","path":"required/file.bin","size":1,"lfs":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":1}}]'
        def transport(url, **_):
            return FixtureResponse(url, payload, {"Link": f"<{second}>; rel=\"next\""} if url == first else {})
        with self.assertRaisesRegex(generator.ManifestGenerationError, "^upstream metadata uses too many unique URLs$"):
            generator.list_selected_files(
                config,
                budget=generator.GenerationBudget(
                    limits=generator.GenerationLimits(max_unique_pagination_urls=1), transport=transport
                ),
            )

    def test_repeated_page_url_is_rejected_as_a_cycle(self):
        config = dict(generator.REPOSITORIES[0])
        config.update(directories=("required",), files=())
        root = generator.expected_tree_path(config, "required")
        url = f"https://huggingface.co{root}?recursive=true&expand=true"
        payload = b'[{"type":"file","path":"required/file.bin","size":1,"lfs":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":1}}]'
        with self.assertRaisesRegex(generator.ManifestGenerationError, "^upstream pagination repeated a page$"):
            generator.list_selected_files(
                config,
                budget=generator.GenerationBudget(
                    transport=lambda request_url, **_: FixtureResponse(request_url, payload, {"Link": f"<{url}>; rel=\"next\""})
                ),
            )

    def test_deadline_before_open_has_an_exact_error(self):
        clock = iter([0.0, 2.0]).__next__
        budget = generator.GenerationBudget(
            limits=generator.GenerationLimits(deadline_seconds=1), clock=clock,
            transport=lambda *_args, **_kwargs: self.fail("deadline must reject before transport"),
        )

        with self.assertRaisesRegex(generator.ManifestGenerationError, "^generation deadline exceeded$"):
            budget.open("https://huggingface.co/api/models/x", allow_content_hosts=False)

    def test_page_host_drift_has_an_exact_error(self):
        config = generator.REPOSITORIES[0]
        with self.assertRaisesRegex(generator.ManifestGenerationError, "^network destination is not allowlisted$"):
            generator.next_page_url({"Link": '<https://example.com/page>; rel="next"'}, config)

    def test_lfs_pointer_has_an_exact_error(self):
        config = generator.REPOSITORIES[0]
        budget = generator.GenerationBudget(
            transport=lambda url, **_: FixtureResponse(url, generator.LFS_POINTER_PREFIX + b"x")
        )
        with self.assertRaisesRegex(generator.ManifestGenerationError, "^download returned Git LFS pointer bytes$"):
            generator.stream_and_hash(config["repository"], config["revision"], "config.json", budget=budget)

    def test_page_link_accepts_the_exact_selected_revision_path(self):
        config = generator.REPOSITORIES[0]
        expected = generator.expected_tree_path(config, "Decoder.mlmodelc")
        valid = f"https://huggingface.co{expected}?cursor=next"
        self.assertEqual(
            generator.next_page_url({"Link": f"<{valid}>; rel=\"next\""}, config, expected_path=expected),
            valid,
        )

    def test_page_link_rejects_revision_drift(self):
        config = generator.REPOSITORIES[0]
        expected = generator.expected_tree_path(config, "Decoder.mlmodelc")
        revision_drift = expected.replace(config["revision"], config["revision"] + "-suffix")
        with self.assertRaisesRegex(generator.ManifestGenerationError, "^upstream pagination escaped the pinned repository$"):
            generator.next_page_url(
                {"Link": f"<https://huggingface.co{revision_drift}?cursor=next>; rel=\"next\""},
                config, expected_path=expected,
            )

    def test_page_link_rejects_selected_path_drift(self):
        config = generator.REPOSITORIES[0]
        expected = generator.expected_tree_path(config, "Decoder.mlmodelc")
        path_drift = expected + "/suffix"
        with self.assertRaisesRegex(generator.ManifestGenerationError, "^upstream pagination escaped the pinned repository$"):
            generator.next_page_url(
                {"Link": f"<https://huggingface.co{path_drift}?cursor=next>; rel=\"next\""},
                config, expected_path=expected,
            )

    def test_page_link_rejects_encoded_traversal(self):
        config = generator.REPOSITORIES[0]
        expected = generator.expected_tree_path(config, "Decoder.mlmodelc")
        traversal = expected.replace("Decoder.mlmodelc", "%2e%2e/escape")
        with self.assertRaisesRegex(generator.ManifestGenerationError, "^upstream pagination path is unsafe$"):
            generator.next_page_url(
                {"Link": f"<https://huggingface.co{traversal}?cursor=next>; rel=\"next\""},
                config, expected_path=expected,
            )

    def test_page_link_rejects_encoded_dot_path_component(self):
        config = generator.REPOSITORIES[0]
        expected = generator.expected_tree_path(config, "Decoder.mlmodelc")
        encoded_dot = expected.replace("Decoder.mlmodelc", "%2E")
        with self.assertRaisesRegex(generator.ManifestGenerationError, "^upstream pagination path is unsafe$"):
            generator.next_page_url(
                {"Link": f"<https://huggingface.co{encoded_dot}?cursor=next>; rel=\"next\""},
                config, expected_path=expected,
            )

    def test_page_links_reject_host_drift(self):
        config = generator.REPOSITORIES[0]
        expected = generator.expected_tree_path(config, "Decoder.mlmodelc")
        with self.assertRaisesRegex(generator.ManifestGenerationError, "^network destination is not allowlisted$"):
            generator.next_page_url(
                {"Link": f"<https://example.com{expected}>; rel=\"next\""}, config, expected_path=expected
            )

    def test_page_links_reject_scheme_drift(self):
        config = generator.REPOSITORIES[0]
        expected = generator.expected_tree_path(config, "Decoder.mlmodelc")
        with self.assertRaisesRegex(generator.ManifestGenerationError, "^network destination is not allowlisted$"):
            generator.next_page_url(
                {"Link": f"<http://huggingface.co{expected}>; rel=\"next\""}, config, expected_path=expected
            )

    def test_redirects_reject_host_drift(self):
        config = generator.REPOSITORIES[0]
        expected = generator.expected_tree_path(config, "Decoder.mlmodelc")
        request = urllib.request.Request(f"https://huggingface.co{expected}")
        with self.assertRaisesRegex(generator.ManifestGenerationError, "^network destination is not allowlisted$"):
            generator.AllowlistedRedirectHandler(False).redirect_request(
                request, None, 302, "Found", {}, f"https://example.com{expected}"
            )

    def test_redirects_reject_scheme_drift(self):
        config = generator.REPOSITORIES[0]
        expected = generator.expected_tree_path(config, "Decoder.mlmodelc")
        request = urllib.request.Request(f"https://huggingface.co{expected}")
        with self.assertRaisesRegex(generator.ManifestGenerationError, "^network destination is not allowlisted$"):
            generator.AllowlistedRedirectHandler(False).redirect_request(
                request, None, 302, "Found", {}, f"http://huggingface.co{expected}"
            )

    def test_repository_license_is_required(self):
        config = dict(generator.REPOSITORIES[0])
        record = {
            "id": config["repository"], "sha": config["revision"], "private": False,
            "gated": False, "cardData": {"license": config["license_slug"]}
        }
        payload = __import__("json").dumps(record).encode()
        record["cardData"] = {}
        bad = generator.GenerationBudget(transport=lambda url, **_: FixtureResponse(url, __import__("json").dumps(record).encode()))
        with self.assertRaisesRegex(generator.ManifestGenerationError, "^repository license is missing, ambiguous, or incompatible$"):
            generator.validate_repository_record(config, budget=bad)

    def test_directory_and_file_selection_are_fixture_deterministic(self):
        config = dict(generator.REPOSITORIES[0])
        config["directories"] = ("required",)
        config["files"] = ("config.json",)
        def transport(url, **_):
            if "/required?" in url:
                payload = b'[{"type":"file","path":"required/model.bin","size":1,"lfs":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":1}}]'
            else:
                payload = b'[{"type":"file","path":"config.json","size":1,"lfs":{"oid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","size":1}}]'
            return FixtureResponse(url, payload)
        entries = generator.list_selected_files(config, budget=generator.GenerationBudget(transport=transport))
        self.assertEqual([entry["path"] for entry in entries], ["config.json", "required/model.bin"])
        self.assertEqual(
            generator.make_assets(config, entries, budget=generator.GenerationBudget(transport=transport)),
            generator.make_assets(config, entries, budget=generator.GenerationBudget(transport=transport)),
        )
    def test_missing_lfs_metadata_has_an_exact_error(self):
        with self.assertRaisesRegex(generator.ManifestGenerationError, "^Git LFS metadata lacks a SHA-256 content OID$"):
            generator.digest_from_lfs({"size": 1, "lfs": {"size": 1}})

    def test_unexpected_selection_has_an_exact_error(self):
        config = dict(generator.REPOSITORIES[0])
        config.update(directories=("required",), files=())
        payload = b'[{"type":"file","path":"other/model.bin","size":1}]'
        with self.assertRaisesRegex(generator.ManifestGenerationError, "^a required model path is absent at the pinned revision$"):
            generator.list_selected_files(
                config, budget=generator.GenerationBudget(transport=lambda url, **_: FixtureResponse(url, payload))
            )

    def test_non_lfs_hash_is_complete_and_the_temporary_handle_is_closed(self):
        config = generator.REPOSITORIES[0]
        payload = b"small metadata file"
        response = FixtureResponse("https://huggingface.co/content", payload, maximum_chunk=2)
        created = []

        class Temporary:
            def __init__(self): self.handle = io.BytesIO(); self.closed = False
            def __enter__(self): return self.handle
            def __exit__(self, *_): self.handle.close(); self.closed = True; return False

        original = generator.tempfile.TemporaryFile
        generator.tempfile.TemporaryFile = lambda **_: created.append(Temporary()) or created[-1]
        try:
            size, digest = generator.stream_and_hash(
                config["repository"], config["revision"], "config.json",
                budget=generator.GenerationBudget(transport=lambda *_args, **_kwargs: response),
            )
        finally:
            generator.tempfile.TemporaryFile = original

        self.assertEqual((size, digest), (len(payload), hashlib.sha256(payload).hexdigest()))
        self.assertEqual(response.offset, len(payload))
        self.assertTrue(response.closed)
        self.assertTrue(created[0].closed)

    def test_lfs_pointer_is_detected_after_the_response_reaches_eof(self):
        config = generator.REPOSITORIES[0]
        payload = generator.LFS_POINTER_PREFIX + b"oid sha256:" + b"a" * 64
        response = FixtureResponse("https://huggingface.co/content", payload, maximum_chunk=3)
        with self.assertRaisesRegex(generator.ManifestGenerationError, "^download returned Git LFS pointer bytes$"):
            generator.stream_and_hash(
                config["repository"], config["revision"], "config.json",
                budget=generator.GenerationBudget(transport=lambda *_args, **_kwargs: response),
            )
        self.assertEqual(response.offset, len(payload))
        self.assertTrue(response.closed)

    def test_atomic_write_replaces_only_the_final_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            previous_output = generator.OUTPUT
            generator.OUTPUT = Path(directory) / "LocalModels.json"
            generator.OUTPUT.write_text("old", encoding="utf-8")
            try:
                generator.atomic_write_manifest({"schemaVersion": 1, "assets": []})
            finally:
                output = generator.OUTPUT
                generator.OUTPUT = previous_output
            self.assertEqual(json.loads(output.read_text(encoding="utf-8")), {"schemaVersion": 1, "assets": []})
            self.assertEqual(list(Path(directory).glob(".LocalModels.*")), [])


if __name__ == "__main__":
    unittest.main()
